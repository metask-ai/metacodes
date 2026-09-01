//! `ModelOffer` — the smallest selectable route — and its conservative,
//! source-aware metadata (issue #16, delivery slice P0/P1).
//!
//! Every metadata rule here exists because the opposite default is dangerous:
//!
//! - an unknown limit must never read as "unlimited" (it would let a request
//!   past admission and fail at the provider, or silently truncate);
//! - an unknown capability must never read as "supported" (it would emit wire
//!   fields the channel rejects);
//! - a missing price must never read as zero (it would under-report spend).
//!
//! So every optional field means *unknown*, `Tri` is three-valued, and `Quote`
//! is a tagged union rather than a number that defaults to `0`.
//!
//! This module is intentionally dependency-free (`std` only) so the contract
//! can be unit-tested in isolation from the transport stack.

const std = @import("std");
const ids = @import("ids.zig");
const controls_mod = @import("controls.zig");

pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const OfferRevision = ids.OfferRevision;
pub const CatalogRevision = ids.CatalogRevision;

// ── provenance ───────────────────────────────────────────────────────────────

/// How current a value is. Attached to every metadata group so a UI can render
/// "stale" instead of pretending a cached number is authoritative.
pub const Freshness = enum {
    /// No value was ever obtained.
    unknown,
    /// Directly stated by the recorded source.
    known,
    /// Narrowed or copied from a broader scope (canonical model → channel).
    inherited,
    /// Was known, but the TTL for its source has expired.
    stale,
};

pub const Source = enum {
    unknown,
    /// Compiled provider profile shipped with metacodes.
    builtin_profile,
    /// Fetched from the provider's own catalog endpoint.
    provider_catalog,
    /// Declared by the user in the versioned configuration document.
    user_config,
    /// Derived from local observations (health, latency, throughput).
    observed,
};

pub const Provenance = struct {
    freshness: Freshness = .unknown,
    source: Source = .unknown,
    /// Unix seconds. Null when never observed.
    observed_at: ?i64 = null,

    pub fn known(source: Source, observed_at: ?i64) Provenance {
        return .{ .freshness = .known, .source = source, .observed_at = observed_at };
    }

    /// Demote to `inherited` when a value is carried down a scope boundary.
    pub fn inherit(self: Provenance) Provenance {
        return switch (self.freshness) {
            .unknown => self,
            else => .{ .freshness = .inherited, .source = self.source, .observed_at = self.observed_at },
        };
    }

    pub fn isUsable(self: Provenance) bool {
        return self.freshness != .unknown;
    }
};

// ── tri-state capabilities ───────────────────────────────────────────────────

/// Three-valued capability. `unknown` is a distinct state that must never be
/// promoted to `supported` by inference — only by a provider declaration.
pub const Tri = enum {
    unknown,
    supported,
    unsupported,

    /// The only admitted read for "may I emit this wire feature?".
    pub fn isSupported(self: Tri) bool {
        return self == .supported;
    }

    /// Narrow a canonical-model capability by a channel-specific declaration.
    /// A channel may *remove* a capability; it may confirm one; it can never
    /// resurrect one the canonical model declares unsupported, and an absent
    /// channel declaration leaves the base untouched.
    pub fn narrow(base: Tri, channel: Tri) Tri {
        return switch (channel) {
            .unsupported => .unsupported,
            .supported => if (base == .unsupported) .unsupported else .supported,
            .unknown => base,
        };
    }
};

/// Offer-level capability vocabulary. Broader than the runtime
/// `api/provider.zig` `Capability` query enum because an offer also describes
/// wire-shape facts (streaming, tool calling) that the runtime never queries.
pub const Capability = enum {
    tools,
    vision,
    /// Native document (PDF) input. Deliberately **not** folded into `vision`:
    /// a model that can see an image is not thereby able to read a PDF, and
    /// conflating them is exactly what issue #25 forbids.
    documents,
    reasoning,
    /// Provider returns a peer `reasoning_content` field rather than a
    /// thinking block.
    reasoning_content,
    caching,
    streaming,
    structured_output,
    web_search,
    server_tool,
};

/// Compile-time coverage check for the runtime capability enum.
///
/// Call sites that bridge `api/provider.zig` capabilities into offer
/// capabilities pass that enum here; adding a runtime capability without a
/// mapping becomes a compile error instead of a silent `unknown`.
pub fn assertRuntimeCoverage(comptime RuntimeCapability: type) void {
    comptime {
        for (@typeInfo(RuntimeCapability).@"enum".fields) |field| {
            if (mapRuntimeName(field.name) == null) {
                @compileError("runtime capability '" ++ field.name ++
                    "' has no ModelOffer capability mapping");
            }
        }
    }
}

pub fn fromRuntimeCapability(runtime_capability: anytype) Capability {
    comptime assertRuntimeCoverage(@TypeOf(runtime_capability));
    inline for (@typeInfo(@TypeOf(runtime_capability)).@"enum".fields) |field| {
        if (runtime_capability == @field(@TypeOf(runtime_capability), field.name)) {
            return comptime mapRuntimeName(field.name).?;
        }
    }
    unreachable;
}

fn mapRuntimeName(comptime name: []const u8) ?Capability {
    const eql = std.mem.eql;
    if (eql(u8, name, "web_search")) return .web_search;
    if (eql(u8, name, "extended_thinking")) return .reasoning;
    if (eql(u8, name, "prompt_cache")) return .caching;
    if (eql(u8, name, "structured_output")) return .structured_output;
    if (eql(u8, name, "server_tool")) return .server_tool;
    if (eql(u8, name, "reasoning_content")) return .reasoning_content;
    if (eql(u8, name, "image_input")) return .vision;
    if (eql(u8, name, "pdf_input")) return .documents;
    return null;
}

/// Dense tri-state map over `Capability`, plus one provenance record for the
/// whole matrix (capabilities are refreshed as a set, not per entry).
pub const CapabilityMatrix = struct {
    entries: std.EnumArray(Capability, Tri) = std.EnumArray(Capability, Tri).initFill(.unknown),
    provenance: Provenance = .{},

    pub fn get(self: CapabilityMatrix, capability: Capability) Tri {
        return self.entries.get(capability);
    }

    pub fn supports(self: CapabilityMatrix, capability: Capability) bool {
        return self.entries.get(capability).isSupported();
    }

    pub fn with(self: CapabilityMatrix, capability: Capability, value: Tri) CapabilityMatrix {
        var out = self;
        out.entries.set(capability, value);
        return out;
    }

    /// Channel-specific narrowing of a canonical matrix. Provenance becomes
    /// `inherited` unless the channel itself declared the values.
    pub fn narrow(base: CapabilityMatrix, channel: CapabilityMatrix) CapabilityMatrix {
        var out = CapabilityMatrix{
            .provenance = if (channel.provenance.isUsable())
                channel.provenance
            else
                base.provenance.inherit(),
        };
        for (std.enums.values(Capability)) |capability| {
            out.entries.set(capability, Tri.narrow(base.entries.get(capability), channel.entries.get(capability)));
        }
        return out;
    }
};

// ── limits and admission ─────────────────────────────────────────────────────

pub const TokenCounting = struct {
    mode: Mode = .unknown,
    unit: Unit = .unknown,

    pub const Mode = enum {
        unknown,
        /// The provider reports usage in the same unit the limits use.
        provider_reported,
        /// metacodes estimates locally; limits still come from the provider.
        local_estimate,
    };

    pub const Unit = enum { unknown, tokens, characters };

    /// Two limit sets can only be intersected when their units agree. Mixed
    /// units fail closed: silently comparing tokens against characters would
    /// produce an admission decision with no meaning.
    pub fn compatible(left: TokenCounting, right: TokenCounting) bool {
        if (left.unit == .unknown or right.unit == .unknown) return true;
        return left.unit == right.unit;
    }

    pub fn merge(left: TokenCounting, right: TokenCounting) TokenCounting {
        return .{
            .mode = if (right.mode != .unknown) right.mode else left.mode,
            .unit = if (right.unit != .unknown) right.unit else left.unit,
        };
    }
};

pub const LimitsError = error{IncomparableTokenUnits};

/// All four limits stay distinct. Collapsing `context_window` into
/// `max_input_tokens` is the classic bug: a 200K window with a 64K per-request
/// input cap is a real provider shape, and merging them silently admits
/// requests the channel rejects.
pub const EffectiveLimits = struct {
    context_window: ?u32 = null,
    max_input_tokens: ?u32 = null,
    max_output_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    token_counting: TokenCounting = .{},
    provenance: Provenance = .{},

    /// Intersection of all applicable known constraints. Unknown ∩ known keeps
    /// the known value but demotes provenance to `inherited`, so a UI never
    /// claims a channel confirmed a number it merely inherited.
    pub fn intersect(base: EffectiveLimits, other: EffectiveLimits) LimitsError!EffectiveLimits {
        if (!TokenCounting.compatible(base.token_counting, other.token_counting))
            return error.IncomparableTokenUnits;
        return .{
            .context_window = minOptional(base.context_window, other.context_window),
            .max_input_tokens = minOptional(base.max_input_tokens, other.max_input_tokens),
            .max_output_tokens = minOptional(base.max_output_tokens, other.max_output_tokens),
            .max_completion_tokens = minOptional(base.max_completion_tokens, other.max_completion_tokens),
            .token_counting = TokenCounting.merge(base.token_counting, other.token_counting),
            .provenance = mergeProvenance(base.provenance, other.provenance),
        };
    }

    pub fn admit(
        self: EffectiveLimits,
        request: AdmissionRequest,
        policy: AdmissionPolicy,
    ) Admission {
        return admitAgainst(self, request, policy);
    }
};

fn minOptional(left: ?u32, right: ?u32) ?u32 {
    const l = left orelse return right;
    const r = right orelse return l;
    return @min(l, r);
}

fn mergeProvenance(base: Provenance, other: Provenance) Provenance {
    if (!other.isUsable()) return base.inherit();
    if (!base.isUsable()) return other;
    // Both sides contributed; the result is narrower than either source.
    return .{
        .freshness = if (base.freshness == .stale or other.freshness == .stale) .stale else .inherited,
        .source = other.source,
        .observed_at = other.observed_at orelse base.observed_at,
    };
}

pub const AdmissionRequest = struct {
    input_tokens: u64,
    requested_output_tokens: u64,
};

/// Behaviour when a required limit is unknown.
///
/// The requirement is explicit: admission must use an explicit conservative cap
/// or fail closed, and must never treat unknown as unlimited. Both caps default
/// to null, i.e. fail closed — a caller has to opt into a cap deliberately.
pub const AdmissionPolicy = struct {
    unknown_context_window_cap: ?u32 = null,
    unknown_max_output_cap: ?u32 = null,
};

pub const RejectionReason = enum {
    input_exceeds_limit,
    output_exceeds_limit,
    total_exceeds_context_window,
    unknown_limit_fail_closed,
    incomparable_token_units,
};

pub const Admission = union(enum) {
    admitted: Admitted,
    rejected: Rejection,

    pub const Admitted = struct {
        input_budget: u64,
        output_budget: u64,
        /// True when a conservative cap stood in for an unknown provider limit.
        /// Surfaced so a UI can say "estimated" rather than implying certainty.
        used_conservative_cap: bool,
    };

    pub const Rejection = struct {
        reason: RejectionReason,
        limit: ?u64 = null,
        requested: u64 = 0,
    };

    pub fn isAdmitted(self: Admission) bool {
        return self == .admitted;
    }
};

fn admitAgainst(
    limits: EffectiveLimits,
    request: AdmissionRequest,
    policy: AdmissionPolicy,
) Admission {
    if (limits.token_counting.unit == .characters)
        return .{ .rejected = .{ .reason = .incomparable_token_units, .requested = request.input_tokens } };

    var used_cap = false;

    const context_window: u64 = blk: {
        if (limits.context_window) |value| break :blk value;
        const cap = policy.unknown_context_window_cap orelse
            return .{ .rejected = .{ .reason = .unknown_limit_fail_closed, .requested = request.input_tokens } };
        used_cap = true;
        break :blk cap;
    };

    // An explicit per-request input cap narrows the window; when absent the
    // window itself is the only input bound (never "unlimited").
    const input_limit: u64 = if (limits.max_input_tokens) |value|
        @min(@as(u64, value), context_window)
    else
        context_window;

    const output_limit: u64 = blk: {
        const declared = minOptional(limits.max_output_tokens, limits.max_completion_tokens);
        if (declared) |value| break :blk value;
        const cap = policy.unknown_max_output_cap orelse
            return .{ .rejected = .{ .reason = .unknown_limit_fail_closed, .requested = request.requested_output_tokens } };
        used_cap = true;
        break :blk cap;
    };

    if (request.input_tokens > input_limit)
        return .{ .rejected = .{
            .reason = .input_exceeds_limit,
            .limit = input_limit,
            .requested = request.input_tokens,
        } };

    if (request.requested_output_tokens > output_limit)
        return .{ .rejected = .{
            .reason = .output_exceeds_limit,
            .limit = output_limit,
            .requested = request.requested_output_tokens,
        } };

    const total = request.input_tokens +| request.requested_output_tokens;
    if (total > context_window)
        return .{ .rejected = .{
            .reason = .total_exceeds_context_window,
            .limit = context_window,
            .requested = total,
        } };

    return .{ .admitted = .{
        .input_budget = input_limit - request.input_tokens,
        .output_budget = output_limit,
        .used_conservative_cap = used_cap,
    } };
}

// ── pricing ──────────────────────────────────────────────────────────────────

pub const Currency = struct {
    code: [3]u8,

    pub fn parse(text: []const u8) error{InvalidCurrency}!Currency {
        if (text.len != 3) return error.InvalidCurrency;
        var out: Currency = .{ .code = undefined };
        for (text, 0..) |byte, index| {
            if (byte < 'A' or byte > 'Z') return error.InvalidCurrency;
            out.code[index] = byte;
        }
        return out;
    }

    pub fn lit(comptime text: []const u8) Currency {
        return comptime blk: {
            break :blk parse(text) catch @compileError("invalid currency literal: " ++ text);
        };
    }

    pub fn slice(self: *const Currency) []const u8 {
        return &self.code;
    }

    pub fn eql(self: Currency, other: Currency) bool {
        return std.mem.eql(u8, &self.code, &other.code);
    }
};

pub const BillingUnit = enum {
    per_million_tokens,
    per_thousand_tokens,
    per_token,
    per_request,
    provider_defined,
};

pub const Priced = struct {
    currency: Currency,
    billing_unit: BillingUnit,
    /// Micro-units of `currency` per `billing_unit`. Null = unknown, which is
    /// never the same as free.
    input_price_micros: ?u64 = null,
    output_price_micros: ?u64 = null,
    cached_input_price_micros: ?u64 = null,
    /// Rate for tokens written into the provider's cache. Null = unknown, and
    /// unknown makes an estimate that needs it unknown rather than cheap.
    cache_write_price_micros: ?u64 = null,
    /// Multiplier applied by an active discount, in basis points (10000 = no
    /// discount). Null = unknown.
    discount_basis_points: ?u16 = null,
    estimated: bool = false,
    /// Unix seconds after which the quote must be refreshed before reuse.
    valid_until: ?i64 = null,
    provenance: Provenance = .{},
};

/// Provider-owned quote. `unknown` is a first-class result: a provider hook
/// that cannot price a route says so rather than returning zero.
pub const Quote = union(enum) {
    unknown,
    known: Priced,

    pub fn isKnown(self: Quote) bool {
        return self == .known;
    }

    pub fn priced(self: Quote) ?Priced {
        return switch (self) {
            .unknown => null,
            .known => |value| value,
        };
    }

    /// Cost of one usage sample, in micro-units of the quote currency.
    ///
    /// Any unknown component makes the whole cost unknown — and so does an
    /// arithmetic overflow. Saturating here would report a wrong number that
    /// reads exactly like a real one, which is the failure mode the whole
    /// "missing price is unknown, never zero" rule exists to prevent.
    pub fn estimateMicros(self: Quote, usage: Usage) ?u64 {
        const price = self.priced() orelse return null;
        const input_rate = price.input_price_micros orelse return null;
        const output_rate = price.output_price_micros orelse return null;
        const divisor: u64 = switch (price.billing_unit) {
            .per_million_tokens => 1_000_000,
            .per_thousand_tokens => 1_000,
            .per_token => 1,
            .per_request, .provider_defined => return null,
        };
        // `input_tokens` is the total; `cached_input_tokens` and
        // `cache_write_tokens` are the subsets the provider served from cache
        // and wrote into it. Billing either at the fresh rate misreports the
        // cost in one direction or the other, so an unknown rate for a subset
        // that is actually present makes the estimate unknown.
        const cached = @min(usage.cached_input_tokens, usage.input_tokens);
        const written = @min(usage.cache_write_tokens, usage.input_tokens - cached);
        const fresh = usage.input_tokens - cached - written;
        const cached_rate = if (cached == 0)
            @as(u64, 0)
        else
            price.cached_input_price_micros orelse return null;
        const write_rate = if (written == 0)
            @as(u64, 0)
        else
            price.cache_write_price_micros orelse return null;

        const fresh_cost = std.math.mul(u64, fresh, input_rate) catch return null;
        const cached_cost = std.math.mul(u64, cached, cached_rate) catch return null;
        const write_cost = std.math.mul(u64, written, write_rate) catch return null;
        const output_cost = std.math.mul(u64, usage.output_tokens, output_rate) catch return null;
        const input_total = std.math.add(u64, fresh_cost, cached_cost) catch return null;
        const with_writes = std.math.add(u64, input_total, write_cost) catch return null;
        const gross = std.math.add(u64, with_writes / divisor, output_cost / divisor) catch return null;
        const basis = price.discount_basis_points orelse return gross;
        const discounted = std.math.mul(u64, gross, basis) catch return null;
        return discounted / 10_000;
    }
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    /// Subset of `input_tokens` the provider served from an existing cache.
    cached_input_tokens: u64 = 0,
    /// Subset of `input_tokens` the provider wrote into its cache. Several
    /// vendors bill this above the fresh-input rate, so it cannot be folded
    /// into `input_tokens` without under-reporting the cost.
    cache_write_tokens: u64 = 0,
};

// ── capacity and health ──────────────────────────────────────────────────────

pub const Capacity = struct {
    concurrent_requests: ?u32 = null,
    requests_per_minute: ?u32 = null,
    tokens_per_minute: ?u32 = null,
    provenance: Provenance = .{},
};

pub const HealthStatus = enum { unknown, healthy, degraded, unavailable };

/// Per-offer operational observation. Deliberately not a canonical-model
/// property: two channels serving the same model have independent health.
pub const Health = struct {
    status: HealthStatus = .unknown,
    latency_ms_p50: ?u32 = null,
    throughput_tokens_per_second: ?u32 = null,
    error_rate_ppm: ?u32 = null,
    provenance: Provenance = .{},
};

// ── the offer ────────────────────────────────────────────────────────────────

pub const Availability = enum { available, deprecated, unavailable, unknown };

pub const ControlSpec = controls_mod.ControlSpec;

/// One concrete, selectable route.
///
/// String fields are borrowed from the catalog arena that produced the offer;
/// ids are values so a selection snapshot can outlive that arena.
pub const ModelOffer = struct {
    offer_id: OfferId,
    provider_id: Slug,
    channel_id: Slug,

    /// Logical upstream identity when known. Grouping/analytics only — it is
    /// never sent on the wire in place of `request_model_id`.
    canonical_model_id: ?[]const u8 = null,
    /// Canonical model + protocol + revision, for grouping only.
    model_variant: ?[]const u8 = null,
    /// The exact string the channel accepts. Always what the adapter emits.
    request_model_id: []const u8,
    /// Backend model name exposed by the channel; may be opaque or absent.
    upstream_model_id: ?[]const u8 = null,

    protocol: []const u8,
    /// The wire this protocol speaks, carried alongside its id so the transport
    /// can be chosen without parsing the id back into a built-in enum. A
    /// declarative custom protocol has its own id and a real wire; re-parsing
    /// the id would lose that and report "no transport" for a route that has
    /// one. Null is a genuinely novel wire, which fails closed.
    wire: ?@import("profile.zig").Protocol.Wire = null,
    /// Fully constructed request endpoint for this protocol on this channel.
    endpoint_ref: []const u8,
    credential_ref: ?Slug = null,

    display_name: []const u8,
    region: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    account: ?[]const u8 = null,

    limits: EffectiveLimits = .{},
    capabilities: CapabilityMatrix = .{},
    quote: Quote = .unknown,
    capacity: Capacity = .{},
    health: Health = .{},
    availability: Availability = .unknown,
    /// Controls this exact offer accepts. A UI must expose only these, and a
    /// value outside them fails before the request is built.
    controls: []const controls_mod.ControlSpec = &.{},

    offer_revision: OfferRevision = 1,
    catalog_revision: CatalogRevision = .initial,

    /// Two offers are the same *route* when their ids match. Metadata equality
    /// is deliberately not part of this: a refresh bumps `offer_revision` and
    /// must keep the identity.
    pub fn sameRoute(self: ModelOffer, other: ModelOffer) bool {
        return self.offer_id.eql(other.offer_id);
    }

    /// Grouping key for a picker. Falls back to the request id only when the
    /// provider exposes no canonical identity — never to a name prefix guess.
    pub fn groupKey(self: ModelOffer) []const u8 {
        return self.canonical_model_id orelse self.request_model_id;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

test "Tri: unknown never becomes supported by inference" {
    try std.testing.expect(!Tri.unknown.isSupported());
    try std.testing.expectEqual(Tri.unknown, Tri.narrow(.unknown, .unknown));
    // A channel declaration is a provider statement, not an inference.
    try std.testing.expectEqual(Tri.supported, Tri.narrow(.unknown, .supported));
    // A channel may remove a canonical capability.
    try std.testing.expectEqual(Tri.unsupported, Tri.narrow(.supported, .unsupported));
    // A channel cannot resurrect one the canonical model rules out.
    try std.testing.expectEqual(Tri.unsupported, Tri.narrow(.unsupported, .supported));
    try std.testing.expectEqual(Tri.supported, Tri.narrow(.supported, .unknown));
}

test "CapabilityMatrix narrowing keeps channel removals and demotes provenance" {
    const base = (CapabilityMatrix{ .provenance = Provenance.known(.provider_catalog, 100) })
        .with(.tools, .supported)
        .with(.vision, .supported)
        .with(.reasoning, .unsupported);
    const channel = (CapabilityMatrix{})
        .with(.vision, .unsupported);
    const merged = CapabilityMatrix.narrow(base, channel);
    try std.testing.expectEqual(Tri.supported, merged.get(.tools));
    try std.testing.expectEqual(Tri.unsupported, merged.get(.vision));
    try std.testing.expectEqual(Tri.unsupported, merged.get(.reasoning));
    try std.testing.expectEqual(Tri.unknown, merged.get(.caching));
    try std.testing.expectEqual(Freshness.inherited, merged.provenance.freshness);
}

test "EffectiveLimits intersect takes the tightest known bound per field" {
    const canonical = EffectiveLimits{
        .context_window = 200_000,
        .max_output_tokens = 64_000,
        .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
        .provenance = Provenance.known(.provider_catalog, 10),
    };
    const channel = EffectiveLimits{
        .context_window = 128_000,
        .max_input_tokens = 96_000,
        .provenance = Provenance.known(.user_config, 20),
    };
    const merged = try canonical.intersect(channel);
    try std.testing.expectEqual(@as(?u32, 128_000), merged.context_window);
    try std.testing.expectEqual(@as(?u32, 96_000), merged.max_input_tokens);
    try std.testing.expectEqual(@as(?u32, 64_000), merged.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, null), merged.max_completion_tokens);
    try std.testing.expectEqual(TokenCounting.Unit.tokens, merged.token_counting.unit);
}

test "EffectiveLimits intersect fails closed on incomparable units" {
    const tokens = EffectiveLimits{ .token_counting = .{ .unit = .tokens } };
    const characters = EffectiveLimits{ .token_counting = .{ .unit = .characters } };
    try std.testing.expectError(error.IncomparableTokenUnits, tokens.intersect(characters));
}

test "admission never treats an unknown limit as unlimited" {
    const unknown_limits = EffectiveLimits{};
    const decision = unknown_limits.admit(
        .{ .input_tokens = 10, .requested_output_tokens = 10 },
        .{},
    );
    try std.testing.expect(!decision.isAdmitted());
    try std.testing.expectEqual(RejectionReason.unknown_limit_fail_closed, decision.rejected.reason);
}

test "admission accepts an explicit conservative cap and flags it" {
    const decision = (EffectiveLimits{}).admit(
        .{ .input_tokens = 1_000, .requested_output_tokens = 500 },
        .{ .unknown_context_window_cap = 8_000, .unknown_max_output_cap = 1_000 },
    );
    try std.testing.expect(decision.isAdmitted());
    try std.testing.expect(decision.admitted.used_conservative_cap);
    try std.testing.expectEqual(@as(u64, 7_000), decision.admitted.input_budget);
}

test "admission separates input cap, output cap, and total window" {
    const limits = EffectiveLimits{
        .context_window = 10_000,
        .max_input_tokens = 6_000,
        .max_output_tokens = 2_000,
        .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
    };
    const over_input = limits.admit(.{ .input_tokens = 6_001, .requested_output_tokens = 10 }, .{});
    try std.testing.expectEqual(RejectionReason.input_exceeds_limit, over_input.rejected.reason);

    const over_output = limits.admit(.{ .input_tokens = 10, .requested_output_tokens = 2_001 }, .{});
    try std.testing.expectEqual(RejectionReason.output_exceeds_limit, over_output.rejected.reason);

    const fits = limits.admit(.{ .input_tokens = 5_000, .requested_output_tokens = 2_000 }, .{});
    try std.testing.expect(fits.isAdmitted());
    try std.testing.expect(!fits.admitted.used_conservative_cap);

    // A narrower window than input+output rejects even though each cap passes.
    const narrow = EffectiveLimits{
        .context_window = 6_000,
        .max_input_tokens = 6_000,
        .max_output_tokens = 2_000,
        .token_counting = .{ .unit = .tokens },
    };
    const over_total = narrow.admit(.{ .input_tokens = 5_000, .requested_output_tokens = 2_000 }, .{});
    try std.testing.expectEqual(RejectionReason.total_exceeds_context_window, over_total.rejected.reason);
}

test "quote: missing price is unknown, never zero" {
    try std.testing.expectEqual(@as(?u64, null), (Quote{ .unknown = {} }).estimateMicros(.{ .input_tokens = 1000 }));
    const half_known = Quote{ .known = .{
        .currency = Currency.lit("USD"),
        .billing_unit = .per_million_tokens,
        .input_price_micros = 3_000_000,
    } };
    try std.testing.expectEqual(@as(?u64, null), half_known.estimateMicros(.{ .input_tokens = 1000 }));
}

test "cached input tokens are billed at the declared cached rate" {
    var quote = Quote{ .known = .{
        .currency = Currency.lit("USD"),
        .billing_unit = .per_million_tokens,
        .input_price_micros = 3_000_000,
        .output_price_micros = 15_000_000,
    } };
    // A cached portion with no declared cached rate cannot be priced; saying
    // "unknown" beats billing it at the full input rate.
    try std.testing.expectEqual(@as(?u64, null), quote.estimateMicros(.{
        .input_tokens = 1_000_000,
        .cached_input_tokens = 400_000,
    }));

    quote.known.cached_input_price_micros = 300_000;
    // 600k fresh @3.0 + 400k cached @0.3 = 1_800_000 + 120_000
    try std.testing.expectEqual(@as(?u64, 1_920_000), quote.estimateMicros(.{
        .input_tokens = 1_000_000,
        .cached_input_tokens = 400_000,
    }));
    // A cached count larger than the total is clamped, never negative.
    try std.testing.expectEqual(@as(?u64, 300_000), quote.estimateMicros(.{
        .input_tokens = 1_000_000,
        .cached_input_tokens = 5_000_000,
    }));
}

test "an overflowing cost estimate is unknown, not a saturated number" {
    const quote = Quote{ .known = .{
        .currency = Currency.lit("USD"),
        .billing_unit = .per_token,
        .input_price_micros = std.math.maxInt(u64) / 2,
        .output_price_micros = 1,
    } };
    try std.testing.expectEqual(
        @as(?u64, null),
        quote.estimateMicros(.{ .input_tokens = 1_000_000 }),
    );
}

test "quote applies billing unit and discount basis points" {
    const quote = Quote{ .known = .{
        .currency = Currency.lit("CNY"),
        .billing_unit = .per_million_tokens,
        .input_price_micros = 2_000_000,
        .output_price_micros = 8_000_000,
        .discount_basis_points = 5_000,
    } };
    // (1M * 2 + 1M * 8) currency units in micros, halved by the 50% discount.
    const cost = quote.estimateMicros(.{ .input_tokens = 1_000_000, .output_tokens = 1_000_000 }).?;
    try std.testing.expectEqual(@as(u64, 5_000_000), cost);
    // per_request pricing cannot be derived from token usage.
    var per_request = quote;
    per_request.known.billing_unit = .per_request;
    try std.testing.expectEqual(@as(?u64, null), per_request.estimateMicros(.{ .input_tokens = 1 }));
}

test "offer identity survives a metadata-only refresh" {
    const binding = OfferId.Binding{
        .provider_id = Slug.lit("zai-coding-plan"),
        .channel_id = Slug.lit("cn-openai"),
        .protocol = "openai_chat",
        .endpoint_url = "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions",
        .request_model_id = "glm-4.6",
    };
    var before = ModelOffer{
        .offer_id = OfferId.derive(binding),
        .provider_id = binding.provider_id,
        .channel_id = binding.channel_id,
        .request_model_id = binding.request_model_id,
        .protocol = binding.protocol,
        .endpoint_ref = binding.endpoint_url,
        .display_name = "GLM-4.6",
        .offer_revision = 7,
    };
    var after = before;
    after.offer_revision = 8;
    after.quote = .{ .known = .{ .currency = Currency.lit("CNY"), .billing_unit = .per_million_tokens } };
    try std.testing.expect(before.sameRoute(after));
    try std.testing.expect(before.offer_revision != after.offer_revision);
}

test "group key prefers canonical identity over the wire model name" {
    const offer = ModelOffer{
        .offer_id = OfferId.derive(.{
            .provider_id = Slug.lit("relay-a"),
            .channel_id = Slug.lit("channel-1"),
            .protocol = "openai_chat",
            .endpoint_url = "https://relay.test/v1/chat/completions",
            .request_model_id = "relay-glm-pro",
        }),
        .provider_id = Slug.lit("relay-a"),
        .channel_id = Slug.lit("channel-1"),
        .canonical_model_id = "zai/glm-5.3",
        .request_model_id = "relay-glm-pro",
        .protocol = "openai_chat",
        .endpoint_ref = "https://relay.test/v1/chat/completions",
        .display_name = "GLM-5.3 (relay-a)",
    };
    try std.testing.expectEqualStrings("zai/glm-5.3", offer.groupKey());
    try std.testing.expectEqualStrings("relay-glm-pro", offer.request_model_id);
}
