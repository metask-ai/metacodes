//! `RuntimeSelection`, `RoutePolicy`, and route resolution
//! (issue #16, delivery slices P0 and P1).
//!
//! Selection is separated from model identity. A model name never identifies a
//! route; a `RuntimeSelection` names either one exact offer (`PinnedOffer`,
//! reproducible, no implicit fallback) or a selector plus a policy
//! (`AutoRoute`, which may pick among qualifying offers and records which one
//! it used).
//!
//! Everything here is a copyable value: a selection is written to a config
//! document, snapshotted at a turn boundary, compared across revisions, and
//! replayed after a restart. Bounded arrays keep that possible without an
//! allocator, and every bound is an explicit error rather than truncation.

const std = @import("std");
const ids = @import("ids.zig");
const offer_mod = @import("offer.zig");
const controls_mod = @import("controls.zig");
const registry_mod = @import("registry.zig");

pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const OfferRevision = ids.OfferRevision;
pub const CatalogRevision = ids.CatalogRevision;
pub const ConfigRevision = ids.ConfigRevision;
pub const ModelOffer = offer_mod.ModelOffer;
pub const ControlValues = controls_mod.ControlValues;
pub const OfferCatalog = registry_mod.OfferCatalog;

pub const MAX_ROUTE_CHANNELS: usize = 8;
pub const MAX_CANDIDATES: usize = 16;
pub const MAX_SELECTOR_LEN: usize = 128;
pub const MAX_AMBIGUITY_SAMPLES: usize = 4;

pub const Selector = controls_mod.Bounded(MAX_SELECTOR_LEN);
pub const RegionText = controls_mod.Bounded(32);
pub const QuantizationText = controls_mod.Bounded(32);

pub const Scope = enum {
    /// Applies to the next turn only, then expires.
    once,
    /// One session.
    session,
    /// Durable for future sessions; requires an explicit user action.
    global,
};

// ── route policy ─────────────────────────────────────────────────────────────

pub const ChannelList = struct {
    entries: [MAX_ROUTE_CHANNELS]Slug = undefined,
    len: u8 = 0,

    pub fn items(self: *const ChannelList) []const Slug {
        return self.entries[0..self.len];
    }

    pub fn append(self: *ChannelList, id: Slug) error{TooManyChannels}!void {
        if (self.len == MAX_ROUTE_CHANNELS) return error.TooManyChannels;
        self.entries[self.len] = id;
        self.len += 1;
    }

    pub fn contains(self: *const ChannelList, id: Slug) bool {
        for (self.items()) |candidate| if (candidate.eql(id)) return true;
        return false;
    }

    /// Position in the preference order, or null when unlisted.
    pub fn indexOf(self: *const ChannelList, id: Slug) ?u8 {
        for (self.items(), 0..) |candidate, index| {
            if (candidate.eql(id)) return @intCast(index);
        }
        return null;
    }

    pub fn of(list: []const Slug) error{TooManyChannels}!ChannelList {
        var out = ChannelList{};
        for (list) |id| try out.append(id);
        return out;
    }
};

/// Every numeric constraint carries its units. A bare number would make
/// "max price 3" ambiguous across currencies and billing units, and comparing
/// across them silently is worse than refusing.
pub const PriceConstraint = struct {
    currency: offer_mod.Currency,
    billing_unit: offer_mod.BillingUnit,
    max_micros: u64,
};

pub const SortPreference = enum { price, throughput, latency, provider_defined };

pub const DataCollection = enum { unspecified, allow, deny };

pub const RoutePolicy = struct {
    only_channels: ChannelList = .{},
    ignore_channels: ChannelList = .{},
    preferred_order: ChannelList = .{},
    /// Fallback beyond the primary candidate is opt-in. A pinned selection can
    /// never fall back at all.
    fallback_allowed: bool = false,
    /// Route only to offers declaring every control the selection carries.
    require_parameters: bool = false,
    hard_max_price: ?PriceConstraint = null,
    hard_min_context_window: ?u32 = null,
    hard_max_latency_ms: ?u32 = null,
    hard_min_throughput_tps: ?u32 = null,
    sort_preference: SortPreference = .provider_defined,
    data_collection: DataCollection = .unspecified,
    /// Zero data retention required.
    zdr: ?bool = null,
    region: ?RegionText = null,
    quantization: ?QuantizationText = null,
};

// ── selection ────────────────────────────────────────────────────────────────

pub const SelectionTarget = union(enum) {
    pinned_offer: Pinned,
    auto_route: Auto,

    pub const Pinned = struct {
        offer_id: OfferId,
        /// Revision at pin time. A later metadata refresh does not move the
        /// pin; it is reported so a UI can show that the offer changed.
        offer_revision: OfferRevision = 1,
    };

    pub const Auto = struct {
        selector: Selector,
        policy: RoutePolicy = .{},
    };

    pub fn isPinned(self: SelectionTarget) bool {
        return self == .pinned_offer;
    }
};

pub const RuntimeSelection = struct {
    target: SelectionTarget,
    /// Recorded after each resolution so an `AutoRoute` selection can report
    /// what it actually used.
    resolved_offer_id: ?OfferId = null,
    resolved_offer_revision: ?OfferRevision = null,
    controls: ControlValues = .{},
    scope: Scope = .session,
    catalog_revision: CatalogRevision = .initial,
    config_revision: ConfigRevision = .initial,

    pub fn pinned(offer_id: OfferId, revision: OfferRevision, scope: Scope) RuntimeSelection {
        return .{
            .target = .{ .pinned_offer = .{ .offer_id = offer_id, .offer_revision = revision } },
            .scope = scope,
        };
    }

    pub fn auto(selector: []const u8, policy: RoutePolicy, scope: Scope) error{ControlTextTooLong}!RuntimeSelection {
        return .{
            .target = .{ .auto_route = .{
                .selector = try Selector.parse(selector),
                .policy = policy,
            } },
            .scope = scope,
        };
    }
};

// ── resolution ───────────────────────────────────────────────────────────────

pub const ResolveError = error{
    /// The pinned offer is not in the current catalog. Reported as such; the
    /// kernel never remaps a pin to a "similar" offer.
    PinnedOfferUnavailable,
    NoMatchingOffer,
    /// Every candidate was rejected by a hard constraint.
    AllCandidatesRejected,
};

pub const RejectionReason = enum {
    channel_excluded,
    context_window_too_small,
    latency_too_high,
    throughput_too_low,
    price_above_hard_max,
    price_unknown_under_hard_max,
    price_incomparable_units,
    controls_unsupported,
    region_mismatch,
    quantization_mismatch,
    unavailable,
};

pub const Resolution = struct {
    /// Ordered candidates; index 0 is the route the turn will use.
    candidates: [MAX_CANDIDATES]*const ModelOffer = undefined,
    len: u8 = 0,
    /// True when the pinned offer is still present but its metadata moved.
    revision_changed: bool = false,
    rejected: u16 = 0,
    /// Qualifying offers beyond `MAX_CANDIDATES`, which this resolution could
    /// not carry. Reported rather than dropped silently: a truncated candidate
    /// list would otherwise read as "these are all the routes".
    dropped: u16 = 0,

    pub fn primary(self: *const Resolution) *const ModelOffer {
        std.debug.assert(self.len > 0);
        return self.candidates[0];
    }

    pub fn items(self: *const Resolution) []const *const ModelOffer {
        return self.candidates[0..self.len];
    }
};

pub fn resolve(catalog: *const OfferCatalog, selection: RuntimeSelection) ResolveError!Resolution {
    return switch (selection.target) {
        .pinned_offer => |pin| resolvePinned(catalog, pin),
        .auto_route => |route| resolveAuto(catalog, route, selection.controls),
    };
}

fn resolvePinned(catalog: *const OfferCatalog, pin: SelectionTarget.Pinned) ResolveError!Resolution {
    const found = catalog.find(pin.offer_id) orelse return error.PinnedOfferUnavailable;
    var out = Resolution{ .revision_changed = found.offer_revision != pin.offer_revision };
    out.candidates[0] = found;
    out.len = 1;
    return out;
}

fn resolveAuto(
    catalog: *const OfferCatalog,
    route: SelectionTarget.Auto,
    control_values: ControlValues,
) ResolveError!Resolution {
    var out = Resolution{};
    var matched_selector = false;

    for (catalog.items()) |*candidate| {
        if (!registry_mod.matchesSelector(candidate.*, route.selector.slice())) continue;
        matched_selector = true;
        if (rejectionFor(candidate, route.policy, control_values) != null) {
            out.rejected +|= 1;
            continue;
        }
        if (out.len == MAX_CANDIDATES) {
            out.dropped +|= 1;
            continue;
        }
        out.candidates[out.len] = candidate;
        out.len += 1;
    }

    if (!matched_selector) return error.NoMatchingOffer;
    if (out.len == 0) return error.AllCandidatesRejected;

    sortCandidates(out.candidates[0..out.len], route.policy);
    // Without explicit fallback permission the resolution exposes exactly the
    // route that will be used, so no caller can improvise a second attempt.
    if (!route.policy.fallback_allowed) out.len = 1;
    return out;
}

/// Hard-constraint evaluation. Anything that cannot be *proved* to qualify is
/// rejected: an unknown price under a price ceiling, an unknown context window
/// under a minimum, mismatched currencies. Soft preferences never reject.
pub fn rejectionFor(
    candidate: *const ModelOffer,
    policy: RoutePolicy,
    control_values: ControlValues,
) ?RejectionReason {
    if (candidate.availability == .unavailable) return .unavailable;

    if (policy.only_channels.len > 0 and !policy.only_channels.contains(candidate.channel_id))
        return .channel_excluded;
    if (policy.ignore_channels.contains(candidate.channel_id)) return .channel_excluded;

    if (policy.region) |wanted| {
        const region = candidate.region orelse return .region_mismatch;
        if (!wanted.eqlText(region)) return .region_mismatch;
    }

    if (policy.quantization) |wanted| {
        // No offer field carries quantization yet; a hard requirement for it
        // therefore cannot be proved and must reject rather than pass.
        _ = wanted;
        return .quantization_mismatch;
    }

    if (policy.hard_min_context_window) |minimum| {
        const window = candidate.limits.context_window orelse return .context_window_too_small;
        if (window < minimum) return .context_window_too_small;
    }

    if (policy.hard_max_latency_ms) |maximum| {
        const latency = candidate.health.latency_ms_p50 orelse return .latency_too_high;
        if (latency > maximum) return .latency_too_high;
    }

    if (policy.hard_min_throughput_tps) |minimum| {
        const throughput = candidate.health.throughput_tokens_per_second orelse return .throughput_too_low;
        if (throughput < minimum) return .throughput_too_low;
    }

    if (policy.hard_max_price) |constraint| {
        const price = candidate.quote.priced() orelse return .price_unknown_under_hard_max;
        if (!price.currency.eql(constraint.currency)) return .price_incomparable_units;
        if (price.billing_unit != constraint.billing_unit) return .price_incomparable_units;
        const input_rate = price.input_price_micros orelse return .price_unknown_under_hard_max;
        const output_rate = price.output_price_micros orelse return .price_unknown_under_hard_max;
        if (@max(input_rate, output_rate) > constraint.max_micros) return .price_above_hard_max;
    }

    if (policy.require_parameters) {
        for (control_values.items()) |entry| {
            if (controls_mod.findSpec(candidate.controls, entry.id.slice()) == null)
                return .controls_unsupported;
        }
    }

    return null;
}

fn sortCandidates(candidates: []*const ModelOffer, policy: RoutePolicy) void {
    const Context = struct {
        policy: RoutePolicy,

        fn lessThan(ctx: @This(), left: *const ModelOffer, right: *const ModelOffer) bool {
            // An explicit order always beats a soft preference.
            if (ctx.policy.preferred_order.len > 0) {
                const left_rank = ctx.policy.preferred_order.indexOf(left.channel_id);
                const right_rank = ctx.policy.preferred_order.indexOf(right.channel_id);
                if (left_rank != null or right_rank != null) {
                    const l = left_rank orelse return false;
                    const r = right_rank orelse return true;
                    if (l != r) return l < r;
                }
            }
            return switch (ctx.policy.sort_preference) {
                .provider_defined => false,
                .price => lessByOptional(referencePriceMicros(left), referencePriceMicros(right), .ascending),
                .latency => lessByOptional(optionalU64(left.health.latency_ms_p50), optionalU64(right.health.latency_ms_p50), .ascending),
                .throughput => lessByOptional(
                    optionalU64(left.health.throughput_tokens_per_second),
                    optionalU64(right.health.throughput_tokens_per_second),
                    .descending,
                ),
            };
        }
    };
    std.sort.block(*const ModelOffer, candidates, Context{ .policy = policy }, Context.lessThan);
}

const Direction = enum { ascending, descending };

/// Unknown always sorts last, in both directions: a missing observation is not
/// evidence of a good value.
fn lessByOptional(left: ?u64, right: ?u64, direction: Direction) bool {
    const l = left orelse return false;
    const r = right orelse return true;
    return switch (direction) {
        .ascending => l < r,
        .descending => l > r,
    };
}

fn optionalU64(value: ?u32) ?u64 {
    return if (value) |inner| @as(u64, inner) else null;
}

/// Comparable price signal for sorting only. Uses the declared output rate,
/// which is the dominant term for generation workloads, and refuses to compare
/// unit-incompatible quotes by treating them as unknown.
fn referencePriceMicros(candidate: *const ModelOffer) ?u64 {
    const price = candidate.quote.priced() orelse return null;
    return switch (price.billing_unit) {
        .per_million_tokens, .per_thousand_tokens, .per_token => price.output_price_micros,
        .per_request, .provider_defined => null,
    };
}

// ── legacy migration ─────────────────────────────────────────────────────────

pub const LegacySelection = struct {
    /// Legacy configurations may not name a provider at all.
    provider_id: ?Slug = null,
    model_id: []const u8,
};

pub const Ambiguity = struct {
    match_count: u16,
    samples: [MAX_AMBIGUITY_SAMPLES]Sample = undefined,
    sample_len: u8 = 0,

    pub const Sample = struct {
        offer_id: OfferId,
        provider_id: Slug,
        channel_id: Slug,
        protocol: []const u8,
    };

    pub fn samplesSlice(self: *const Ambiguity) []const Sample {
        return self.samples[0..self.sample_len];
    }
};

/// Legacy `(provider, model)` state is a migration *input*, never an authority.
/// It is accepted only when it identifies exactly one offer; anything else
/// returns enough detail for an actionable message.
pub const MigrationOutcome = union(enum) {
    migrated: SelectionTarget.Pinned,
    ambiguous: Ambiguity,
    unknown_model,
};

pub fn migrateLegacy(catalog: *const OfferCatalog, legacy: LegacySelection) MigrationOutcome {
    var ambiguity = Ambiguity{ .match_count = 0 };
    var only: ?*const ModelOffer = null;
    for (catalog.items()) |*candidate| {
        if (legacy.provider_id) |wanted| {
            if (!candidate.provider_id.eql(wanted)) continue;
        }
        if (!registry_mod.matchesSelector(candidate.*, legacy.model_id)) continue;
        ambiguity.match_count +|= 1;
        if (ambiguity.sample_len < MAX_AMBIGUITY_SAMPLES) {
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
    if (ambiguity.match_count == 0) return .unknown_model;
    if (ambiguity.match_count > 1) return .{ .ambiguous = ambiguity };
    return .{ .migrated = .{
        .offer_id = only.?.offer_id,
        .offer_revision = only.?.offer_revision,
    } };
}

// ── actual-route feedback ────────────────────────────────────────────────────

pub const RouteStatus = enum { ok, failed, fell_back };

pub const RequestedRoute = union(enum) {
    pinned: OfferId,
    selector: Selector,
};

/// Redacted record of what a turn actually used. Ids and numbers only: no
/// prompt, no response body, no credential material.
pub const ActualRouteEvent = struct {
    requested: RequestedRoute,
    actual_offer_id: OfferId,
    actual_offer_revision: OfferRevision,
    provider_id: Slug,
    channel_id: Slug,
    protocol: []const u8,
    fallback_attempts: u8 = 0,
    usage: offer_mod.Usage = .{},
    cost_micros: ?u64 = null,
    latency_ms: ?u32 = null,
    status: RouteStatus = .ok,

    pub fn forResolution(
        selection: RuntimeSelection,
        resolution: *const Resolution,
        used: *const ModelOffer,
    ) ActualRouteEvent {
        const attempts = attemptsBefore(resolution, used);
        return .{
            .requested = switch (selection.target) {
                .pinned_offer => |pin| .{ .pinned = pin.offer_id },
                .auto_route => |route| .{ .selector = route.selector },
            },
            .actual_offer_id = used.offer_id,
            .actual_offer_revision = used.offer_revision,
            .provider_id = used.provider_id,
            .channel_id = used.channel_id,
            .protocol = used.protocol,
            .fallback_attempts = attempts,
            .status = if (attempts > 0) .fell_back else .ok,
        };
    }
};

fn attemptsBefore(resolution: *const Resolution, used: *const ModelOffer) u8 {
    for (resolution.items(), 0..) |candidate, index| {
        if (candidate.offer_id.eql(used.offer_id)) return @intCast(index);
    }
    return 0;
}

// ── tests ────────────────────────────────────────────────────────────────────

const ProviderRegistry = registry_mod.ProviderRegistry;

fn zaiCatalog(allocator: std.mem.Allocator, registry: *ProviderRegistry) !OfferCatalog {
    return registry.buildCatalog(allocator, .{ .only_provider = Slug.lit("zai-coding-plan") });
}

test "a pinned selection resolves to exactly one reproducible route" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    const target = catalog.items()[0];
    const selection = RuntimeSelection.pinned(target.offer_id, target.offer_revision, .session);
    const resolution = try resolve(&catalog, selection);
    try std.testing.expectEqual(@as(u8, 1), resolution.len);
    try std.testing.expect(resolution.primary().offer_id.eql(target.offer_id));
    try std.testing.expect(!resolution.revision_changed);
}

test "a pinned offer that disappears is reported, never remapped" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    const ghost = OfferId.derive(.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .channel_id = Slug.lit("cn-openai"),
        .protocol = "openai_chat",
        .endpoint_url = "https://retired.example/v1/chat/completions",
        .request_model_id = "glm-retired",
    });
    try std.testing.expectError(
        error.PinnedOfferUnavailable,
        resolve(&catalog, RuntimeSelection.pinned(ghost, 1, .session)),
    );
}

test "a metadata refresh moves the revision without moving the pin" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    const target = catalog.items()[0];
    const selection = RuntimeSelection.pinned(target.offer_id, target.offer_revision + 3, .session);
    const resolution = try resolve(&catalog, selection);
    try std.testing.expect(resolution.revision_changed);
    try std.testing.expect(resolution.primary().offer_id.eql(target.offer_id));
}

test "auto route without fallback exposes exactly the route it will use" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    const selection = try RuntimeSelection.auto("zai/glm-4.6", .{}, .session);
    const resolution = try resolve(&catalog, selection);
    try std.testing.expectEqual(@as(u8, 1), resolution.len);

    var with_fallback = selection;
    with_fallback.target.auto_route.policy.fallback_allowed = true;
    const wide = try resolve(&catalog, with_fallback);
    try std.testing.expectEqual(@as(u8, 4), wide.len);
}

test "only/ignore channel lists are hard constraints" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    var policy = RoutePolicy{ .fallback_allowed = true };
    policy.only_channels = try ChannelList.of(&.{ Slug.lit("cn-openai"), Slug.lit("cn-anthropic") });
    const only = try resolve(&catalog, try RuntimeSelection.auto("zai/glm-4.6", policy, .session));
    try std.testing.expectEqual(@as(u8, 2), only.len);
    for (only.items()) |candidate| {
        try std.testing.expectEqualStrings("cn", candidate.region.?);
    }

    var ignoring = RoutePolicy{ .fallback_allowed = true };
    ignoring.ignore_channels = try ChannelList.of(&.{Slug.lit("cn-openai")});
    const rest = try resolve(&catalog, try RuntimeSelection.auto("zai/glm-4.6", ignoring, .session));
    try std.testing.expectEqual(@as(u8, 3), rest.len);
}

test "preferred order wins over the soft sort preference" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    var policy = RoutePolicy{ .fallback_allowed = true, .sort_preference = .latency };
    policy.preferred_order = try ChannelList.of(&.{ Slug.lit("global-openai"), Slug.lit("cn-anthropic") });
    const resolution = try resolve(&catalog, try RuntimeSelection.auto("zai/glm-4.6", policy, .session));
    try std.testing.expect(resolution.primary().channel_id.eqlText("global-openai"));
    try std.testing.expect(resolution.items()[1].channel_id.eqlText("cn-anthropic"));
}

test "hard constraints reject what cannot be proved to qualify" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    // glm-4.5-air has unknown limits: a context-window floor must reject it.
    const air_policy = RoutePolicy{ .hard_min_context_window = 100_000, .fallback_allowed = true };
    try std.testing.expectError(
        error.AllCandidatesRejected,
        resolve(&catalog, try RuntimeSelection.auto("zai/glm-4.5-air", air_policy, .session)),
    );

    // Unknown price under a hard price ceiling is a rejection, not a pass.
    const price_policy = RoutePolicy{
        .hard_max_price = .{
            .currency = offer_mod.Currency.lit("USD"),
            .billing_unit = .per_million_tokens,
            .max_micros = 10_000_000,
        },
        .fallback_allowed = true,
    };
    try std.testing.expectError(
        error.AllCandidatesRejected,
        resolve(&catalog, try RuntimeSelection.auto("zai/glm-4.6", price_policy, .session)),
    );

    // A latency ceiling with no health observation likewise rejects.
    const latency_policy = RoutePolicy{ .hard_max_latency_ms = 500, .fallback_allowed = true };
    try std.testing.expectError(
        error.AllCandidatesRejected,
        resolve(&catalog, try RuntimeSelection.auto("zai/glm-4.6", latency_policy, .session)),
    );
}

test "incomparable currencies fail closed instead of comparing numbers" {
    var priced = ModelOffer{
        .offer_id = OfferId.derive(.{
            .provider_id = Slug.lit("relay-a"),
            .channel_id = Slug.lit("c1"),
            .protocol = "openai_chat",
            .endpoint_url = "https://relay.test/v1/chat/completions",
            .request_model_id = "m",
        }),
        .provider_id = Slug.lit("relay-a"),
        .channel_id = Slug.lit("c1"),
        .request_model_id = "m",
        .protocol = "openai_chat",
        .endpoint_ref = "https://relay.test/v1/chat/completions",
        .display_name = "M",
        .quote = .{ .known = .{
            .currency = offer_mod.Currency.lit("CNY"),
            .billing_unit = .per_million_tokens,
            .input_price_micros = 1,
            .output_price_micros = 1,
        } },
    };
    const usd_ceiling = RoutePolicy{ .hard_max_price = .{
        .currency = offer_mod.Currency.lit("USD"),
        .billing_unit = .per_million_tokens,
        .max_micros = 1_000_000,
    } };
    try std.testing.expectEqual(
        RejectionReason.price_incomparable_units,
        rejectionFor(&priced, usd_ceiling, .{}).?,
    );

    // Same currency, different billing unit is equally incomparable.
    const per_token_ceiling = RoutePolicy{ .hard_max_price = .{
        .currency = offer_mod.Currency.lit("CNY"),
        .billing_unit = .per_token,
        .max_micros = 1_000_000,
    } };
    try std.testing.expectEqual(
        RejectionReason.price_incomparable_units,
        rejectionFor(&priced, per_token_ceiling, .{}).?,
    );

    // Matching units compare normally.
    const cny_ceiling = RoutePolicy{ .hard_max_price = .{
        .currency = offer_mod.Currency.lit("CNY"),
        .billing_unit = .per_million_tokens,
        .max_micros = 1_000_000,
    } };
    try std.testing.expect(rejectionFor(&priced, cny_ceiling, .{}) == null);
    priced.quote.known.output_price_micros = 9_000_000;
    try std.testing.expectEqual(
        RejectionReason.price_above_hard_max,
        rejectionFor(&priced, cny_ceiling, .{}).?,
    );
}

test "require_parameters routes only to offers declaring the controls" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    var selection = try RuntimeSelection.auto(
        "zai/glm-4.6",
        .{ .require_parameters = true, .fallback_allowed = true },
        .session,
    );
    try selection.controls.set("reasoning_effort", try controls_mod.Value.fromText("high"));
    // The built-in profile declares no controls yet, so a hard requirement for
    // one cannot be satisfied.
    try std.testing.expectError(error.AllCandidatesRejected, resolve(&catalog, selection));

    // Without the hard requirement the same selection still routes.
    selection.target.auto_route.policy.require_parameters = false;
    const relaxed = try resolve(&catalog, selection);
    try std.testing.expect(relaxed.len > 0);
}

test "an unknown selector is distinguishable from an over-constrained one" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();
    try std.testing.expectError(
        error.NoMatchingOffer,
        resolve(&catalog, try RuntimeSelection.auto("zai/does-not-exist", .{}, .session)),
    );
}

test "legacy model-only state migrates when unambiguous" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("metask"),
    });
    defer catalog.deinit();

    const outcome = migrateLegacy(&catalog, .{ .model_id = "claude-sonnet-4-6" });
    try std.testing.expect(outcome == .migrated);
    const resolved = catalog.find(outcome.migrated.offer_id).?;
    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolved.request_model_id);
}

test "ambiguous legacy state fails with actionable candidates" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    const outcome = migrateLegacy(&catalog, .{ .model_id = "glm-4.6" });
    try std.testing.expect(outcome == .ambiguous);
    try std.testing.expectEqual(@as(u16, 4), outcome.ambiguous.match_count);
    try std.testing.expectEqual(@as(u8, 4), outcome.ambiguous.sample_len);
    for (outcome.ambiguous.samplesSlice()) |sample| {
        try std.testing.expect(sample.provider_id.eqlText("zai-coding-plan"));
    }

    // Narrowing by channel is what makes it unambiguous again.
    const unknown = migrateLegacy(&catalog, .{ .model_id = "glm-9.9" });
    try std.testing.expect(unknown == .unknown_model);
}

test "actual-route events carry ids and no payload" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();

    const selection = try RuntimeSelection.auto(
        "zai/glm-4.6",
        .{ .fallback_allowed = true },
        .session,
    );
    const resolution = try resolve(&catalog, selection);
    const primary = ActualRouteEvent.forResolution(selection, &resolution, resolution.primary());
    try std.testing.expectEqual(RouteStatus.ok, primary.status);
    try std.testing.expectEqual(@as(u8, 0), primary.fallback_attempts);
    try std.testing.expect(primary.requested == .selector);

    const second = ActualRouteEvent.forResolution(selection, &resolution, resolution.items()[1]);
    try std.testing.expectEqual(RouteStatus.fell_back, second.status);
    try std.testing.expectEqual(@as(u8, 1), second.fallback_attempts);
    // Requested identity is preserved alongside the actual one.
    try std.testing.expect(!second.actual_offer_id.eql(resolution.primary().offer_id));
}

test "scope values are explicit and survive a copy" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try zaiCatalog(std.testing.allocator, &registry);
    defer catalog.deinit();
    const target = catalog.items()[0];
    const once = RuntimeSelection.pinned(target.offer_id, target.offer_revision, .once);
    const copy = once;
    try std.testing.expectEqual(Scope.once, copy.scope);
    try std.testing.expect(copy.target.isPinned());
}
