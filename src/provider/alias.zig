//! Local model aliases (issue #16, P2 follow-up).
//!
//! An alias is a name the user gives a route — "fast", "cheap", "review" — and
//! it is an **explicit record**, never a string heuristic. Two policies, and
//! the difference between them is the whole point:
//!
//! - **pinned** stores the resolved offer and its revision. It keeps meaning the
//!   same route across catalog refreshes, and when that offer is gone it says
//!   so rather than resolving to a neighbour. Reproducibility is the promise.
//! - **floating** stores the selector plus the offer it last resolved to and
//!   the catalog revision it resolved against. It re-resolves on a newer
//!   catalog — that is what "floating" means — but it still records what it
//!   landed on, so an actual route is always attributable.
//!
//! A floating alias whose selector matches several routes is an error listing
//! the candidates, not a guess: picking one would silently choose a protocol,
//! region, price, and credential the user never named.

const std = @import("std");
const ids = @import("ids.zig");
const config_doc = @import("config_doc.zig");
const registry_mod = @import("registry.zig");
const selection_mod = @import("selection.zig");

pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const AliasEntry = config_doc.AliasEntry;
pub const OfferCatalog = registry_mod.OfferCatalog;

pub const AliasError = error{
    /// A pinned alias whose offer is no longer in the catalog. Reported rather
    /// than remapped: a pin that quietly moves is not a pin.
    PinnedOfferUnavailable,
    NoMatchingOffer,
    /// A floating selector that matches several routes.
    AmbiguousSelector,
    /// The record has neither an offer id (pinned) nor a selector (floating).
    MalformedAlias,
};

pub const Resolution = struct {
    offer_id: OfferId,
    offer_revision: ids.OfferRevision,
    catalog_revision: ids.CatalogRevision,
    /// True when a floating alias landed on a different offer than last time.
    /// The caller persists the update; a floating alias that never records
    /// where it went cannot explain a route after the fact.
    moved: bool,
};

pub fn resolve(catalog: *const OfferCatalog, entry: AliasEntry) AliasError!Resolution {
    return switch (entry.policy) {
        .pinned => resolvePinned(catalog, entry),
        .floating => resolveFloating(catalog, entry),
    };
}

fn resolvePinned(catalog: *const OfferCatalog, entry: AliasEntry) AliasError!Resolution {
    const offer_id = entry.offer_id orelse return error.MalformedAlias;
    const found = catalog.find(offer_id) orelse return error.PinnedOfferUnavailable;
    if (found.availability == .unavailable) return error.PinnedOfferUnavailable;
    return .{
        .offer_id = found.offer_id,
        .offer_revision = found.offer_revision,
        .catalog_revision = catalog.revision,
        // A pinned alias never moves. A changed *revision* is metadata, and the
        // caller can notice it by comparing `offer_revision`.
        .moved = false,
    };
}

fn resolveFloating(catalog: *const OfferCatalog, entry: AliasEntry) AliasError!Resolution {
    const selector = entry.selector orelse return error.MalformedAlias;
    var only: ?*const registry_mod.ModelOffer = null;
    var ambiguity = selection_mod.Ambiguity{ .match_count = 0 };
    for (catalog.items()) |*candidate| {
        if (!registry_mod.matchesSelector(candidate.*, selector.slice())) continue;
        if (candidate.availability == .unavailable) continue;
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
    if (ambiguity.match_count == 0) return error.NoMatchingOffer;
    if (ambiguity.match_count > 1) return error.AmbiguousSelector;

    const chosen = only.?;
    const moved = if (entry.offer_id) |previous| !previous.eql(chosen.offer_id) else true;
    return .{
        .offer_id = chosen.offer_id,
        .offer_revision = chosen.offer_revision,
        .catalog_revision = catalog.revision,
        .moved = moved,
    };
}

/// The routes a floating selector matches, for reporting an ambiguity.
///
/// A separate traversal on purpose: it runs only on the error path, and
/// threading candidates through the success type would leave a field populated
/// with nothing useful on every ordinary resolution.
pub fn candidatesFor(catalog: *const OfferCatalog, entry: AliasEntry) selection_mod.Ambiguity {
    var out = selection_mod.Ambiguity{ .match_count = 0 };
    const selector = entry.selector orelse return out;
    for (catalog.items()) |*candidate| {
        if (!registry_mod.matchesSelector(candidate.*, selector.slice())) continue;
        if (candidate.availability == .unavailable) continue;
        out.match_count +|= 1;
        if (out.sample_len == selection_mod.MAX_AMBIGUITY_SAMPLES) continue;
        out.samples[out.sample_len] = .{
            .offer_id = candidate.offer_id,
            .provider_id = candidate.provider_id,
            .channel_id = candidate.channel_id,
            .protocol = candidate.protocol,
        };
        out.sample_len += 1;
    }
    return out;
}

/// The record to persist after resolving. A floating alias records where it
/// landed and against which catalog; a pinned one is unchanged.
pub fn updated(entry: AliasEntry, resolution: Resolution) AliasEntry {
    var out = entry;
    if (entry.policy == .floating) {
        out.offer_id = resolution.offer_id;
        out.offer_revision = resolution.offer_revision;
        out.catalog_revision = resolution.catalog_revision;
    }
    return out;
}

/// Turn a resolved alias into a runtime selection. Always pinned at this point:
/// the alias already decided which route, and re-deciding it inside the kernel
/// would make a floating alias re-resolve mid-turn.
pub fn selectionFor(resolution: Resolution, scope: selection_mod.Scope) selection_mod.RuntimeSelection {
    var out = selection_mod.RuntimeSelection.pinned(resolution.offer_id, resolution.offer_revision, scope);
    out.catalog_revision = resolution.catalog_revision;
    return out;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a pinned alias keeps meaning the same route across a refresh" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var first = try registry.buildCatalog(a, .{ .revision = .initial });
    defer first.deinit();
    const target = first.items()[2];

    const entry = AliasEntry{
        .name = try config_doc.AliasName.parse("review"),
        .policy = .pinned,
        .offer_id = target.offer_id,
        .offer_revision = target.offer_revision,
    };

    var second = try registry.buildCatalog(a, .{ .revision = first.revision.next() });
    defer second.deinit();
    const resolution = try resolve(&second, entry);
    // Offer ids come from the stable binding, so a rebuild reproduces them —
    // that is what makes a pin durable rather than merely recorded.
    try testing.expect(resolution.offer_id.eql(target.offer_id));
    try testing.expect(!resolution.moved);
    // And the record is unchanged: a pin does not drift.
    const after = updated(entry, resolution);
    try testing.expect(after.offer_id.?.eql(target.offer_id));
}

test "a pinned alias whose offer is gone says so instead of resolving nearby" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{});
    defer catalog.deinit();

    const entry = AliasEntry{
        .name = try config_doc.AliasName.parse("gone"),
        .policy = .pinned,
        .offer_id = OfferId{ .digest = @splat(0x7C) },
        .offer_revision = 1,
    };
    try testing.expectError(error.PinnedOfferUnavailable, resolve(&catalog, entry));
}

test "a floating alias re-resolves and records where it landed" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    // One channel per model, so the selector is unambiguous — which is the
    // only shape a floating alias may have.
    var catalog = try registry.buildCatalog(a, .{
        .only_provider = Slug.lit("metask"),
        .revision = @enumFromInt(9),
    });
    defer catalog.deinit();

    var entry = AliasEntry{
        .name = try config_doc.AliasName.parse("fast"),
        .policy = .floating,
        .selector = try selection_mod.Selector.parse("claude-haiku-4-5-20251001"),
    };
    // First resolution: nothing recorded yet, so it "moved".
    const first = try resolve(&catalog, entry);
    try testing.expect(first.moved);
    entry = updated(entry, first);
    try testing.expectEqual(@as(?ids.CatalogRevision, @enumFromInt(9)), entry.catalog_revision);
    try testing.expect(entry.offer_id.?.eql(first.offer_id));

    // Same catalog: it lands on the same offer and reports no move, so a UI can
    // tell "re-resolved to the same thing" from "re-resolved elsewhere".
    const second = try resolve(&catalog, entry);
    try testing.expect(!second.moved);
}

test "a floating selector matching several routes is an error with candidates" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();

    const entry = AliasEntry{
        .name = try config_doc.AliasName.parse("glm"),
        .policy = .floating,
        // "glm-4.6" is served by four channels: choosing one would silently
        // pick a protocol, region, price, and credential the user never named.
        .selector = try selection_mod.Selector.parse("glm-4.6"),
    };
    try testing.expectError(error.AmbiguousSelector, resolve(&catalog, entry));

    // The candidates are recoverable, so the command can say *which* routes
    // rather than only that there were several.
    const candidates = candidatesFor(&catalog, entry);
    try testing.expectEqual(@as(u16, 4), candidates.match_count);
    try testing.expect(candidates.samplesSlice().len > 1);
    for (candidates.samplesSlice()) |sample| {
        try testing.expect(sample.provider_id.eqlText("zai-coding-plan"));
    }
}

test "a malformed record is rejected rather than half-resolved" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{});
    defer catalog.deinit();

    try testing.expectError(error.MalformedAlias, resolve(&catalog, .{
        .name = try config_doc.AliasName.parse("broken"),
        .policy = .pinned,
    }));
    try testing.expectError(error.MalformedAlias, resolve(&catalog, .{
        .name = try config_doc.AliasName.parse("broken"),
        .policy = .floating,
    }));
}

test "a resolved alias becomes a pinned selection, not a re-resolving one" {
    const a = testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("metask") });
    defer catalog.deinit();

    const entry = AliasEntry{
        .name = try config_doc.AliasName.parse("air"),
        .policy = .floating,
        .selector = try selection_mod.Selector.parse("claude-haiku-4-5-20251001"),
    };
    const resolution = try resolve(&catalog, entry);
    const selection = selectionFor(resolution, .session);
    // The alias already decided the route. Leaving it auto would let it
    // re-resolve inside the kernel, mid-turn, against a catalog the user never
    // saw.
    try testing.expect(selection.target.isPinned());
    const resolved = try selection_mod.resolve(&catalog, selection);
    try testing.expect(resolved.primary().offer_id.eql(resolution.offer_id));
}
