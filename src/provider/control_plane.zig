//! UI-independent control plane (issue #16, "UI-independent control plane").
//!
//! One kernel API serves the TUI, the Web UI, the CLI, and any future client.
//! Clients never read provider environment variables, probe endpoints, refresh
//! tokens, instantiate provider clients, infer identity from prefixes, or
//! rewrite a request model id — they call these operations and render what
//! comes back.
//!
//! Deliberately free of I/O: persistence is `config_store.zig`, transport is
//! whatever the embedder chooses (in-process call, local HTTP, JSON-RPC). That
//! keeps scope semantics and revision conflicts testable without a filesystem
//! or a socket.
//!
//! Redaction is structural: the response types below carry ids, numbers, and
//! provenance. There is no field a secret, prompt, or raw provider response
//! could travel in.

const std = @import("std");
const ids = @import("ids.zig");
const offer_mod = @import("offer.zig");
const controls_mod = @import("controls.zig");
const selection_mod = @import("selection.zig");
const registry_mod = @import("registry.zig");
const credential = @import("credential.zig");

pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const CatalogRevision = ids.CatalogRevision;
pub const ConfigRevision = ids.ConfigRevision;
pub const ModelOffer = offer_mod.ModelOffer;
pub const RuntimeSelection = selection_mod.RuntimeSelection;
pub const Scope = selection_mod.Scope;
pub const OfferCatalog = registry_mod.OfferCatalog;

pub const API_VERSION: u16 = 1;
pub const SCHEMA_VERSION: u16 = 1;

pub const MAX_EVENTS: usize = 256;

/// Common request envelope. Every mutation carries the caller's expected
/// revisions so a stale write is a deterministic conflict rather than a
/// last-writer-wins overwrite.
pub const ApiEnvelope = struct {
    api_version: u16 = API_VERSION,
    schema_version: u16 = SCHEMA_VERSION,
    request_id: u64 = 0,
    operation_id: ?[]const u8 = null,
    expected_config_revision: ?ConfigRevision = null,
    expected_catalog_revision: ?CatalogRevision = null,
};

/// Every response reports the revisions it was computed against.
pub const ResponseMeta = struct {
    api_version: u16 = API_VERSION,
    schema_version: u16 = SCHEMA_VERSION,
    request_id: u64 = 0,
    config_revision: ConfigRevision,
    catalog_revision: CatalogRevision,
};

// ── read models ──────────────────────────────────────────────────────────────

/// Redacted per-offer view. Everything a picker needs; nothing a picker must
/// not see.
pub const OfferSummary = struct {
    offer_id: OfferId,
    provider_id: Slug,
    channel_id: Slug,
    display_name: []const u8,
    request_model_id: []const u8,
    canonical_model_id: ?[]const u8,
    upstream_model_id: ?[]const u8,
    protocol: []const u8,
    /// Endpoint host and path only; a channel base URL never carries a secret,
    /// but the field is documented as display-only so no client dials it.
    endpoint_ref: []const u8,
    credential_ref: ?Slug,
    region: ?[]const u8,
    plan: ?[]const u8,
    limits: offer_mod.EffectiveLimits,
    capabilities: offer_mod.CapabilityMatrix,
    quote: offer_mod.Quote,
    health: offer_mod.Health,
    availability: offer_mod.Availability,
    controls: []const controls_mod.ControlSpec,
    offer_revision: ids.OfferRevision,
    is_current: bool = false,

    pub fn from(offer: *const ModelOffer, is_current: bool) OfferSummary {
        return .{
            .offer_id = offer.offer_id,
            .provider_id = offer.provider_id,
            .channel_id = offer.channel_id,
            .display_name = offer.display_name,
            .request_model_id = offer.request_model_id,
            .canonical_model_id = offer.canonical_model_id,
            .upstream_model_id = offer.upstream_model_id,
            .protocol = offer.protocol,
            .endpoint_ref = offer.endpoint_ref,
            .credential_ref = offer.credential_ref,
            .region = offer.region,
            .plan = offer.plan,
            .limits = offer.limits,
            .capabilities = offer.capabilities,
            .quote = offer.quote,
            .health = offer.health,
            .availability = offer.availability,
            .controls = offer.controls,
            .offer_revision = offer.offer_revision,
            .is_current = is_current,
        };
    }
};

/// Filters for `model.list`. Absent fields do not filter.
pub const ListQuery = struct {
    provider_id: ?Slug = null,
    /// Substring match over display name, request id, and canonical id. Used
    /// for the picker's fuzzy filter; never for identity resolution.
    search: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    requires_capability: ?offer_mod.Capability = null,
    offset: usize = 0,
    limit: usize = 0,
};

pub const ListPage = struct {
    meta: ResponseMeta,
    /// Borrowed from the kernel's reusable summary buffer: it is valid until
    /// the next `modelList` call on the same kernel. A client that keeps the
    /// page across calls must copy it (a remote transport serializes it, which
    /// copies by construction).
    offers: []const OfferSummary,
    total: usize,
    /// True when `total` exceeds what this page returned, so a client can page
    /// rather than silently show a truncated catalog.
    truncated: bool,
};

// ── selection results ────────────────────────────────────────────────────────

pub const ValidationOutcome = union(enum) {
    ok: Accepted,
    unavailable: selection_mod.ResolveError,
    control_rejected: ControlRejection,

    pub const Accepted = struct {
        offer_id: OfferId,
        offer_revision: ids.OfferRevision,
        /// Controls after provider normalization.
        effective_controls: controls_mod.ControlValues,
        cleared_controls: u8,
        normalized_controls: u8,
        revision_changed: bool,
    };

    pub const ControlRejection = struct {
        control_id: controls_mod.ControlId,
        reason: enum { unsupported_by_offer, invalid_value },
    };
};

pub const CommitOutcome = union(enum) {
    committed: Committed,
    conflict: Conflict,
    rejected: ValidationOutcome,

    pub const Committed = struct {
        selection: RuntimeSelection,
        scope: Scope,
        config_revision: ConfigRevision,
        catalog_revision: CatalogRevision,
    };

    pub const Conflict = struct {
        expected_config_revision: ?ConfigRevision,
        actual_config_revision: ConfigRevision,
        expected_catalog_revision: ?CatalogRevision,
        actual_catalog_revision: CatalogRevision,
    };
};

// ── events ───────────────────────────────────────────────────────────────────

pub const EventType = enum {
    catalog_updated,
    pricing_updated,
    auth_changed,
    runtime_selection_changed,
    runtime_switch_failed,
    credential_expiring,
    provider_degraded,
    route_actual,
    failover,
};

/// Event payloads are ids and enums only. There is intentionally no free-form
/// string field: a payload cannot carry a prompt, a token, or a provider body.
pub const EventPayload = union(EventType) {
    catalog_updated: struct { offer_count: u32 },
    pricing_updated: struct { provider_id: Slug },
    auth_changed: struct { provider_id: Slug, credential_ref: Slug, status: credential.CredentialStatus },
    runtime_selection_changed: struct { scope: Scope, offer_id: ?OfferId },
    runtime_switch_failed: struct { scope: Scope, reason: SwitchFailure },
    credential_expiring: struct { provider_id: Slug, credential_ref: Slug, expires_at: i64 },
    provider_degraded: struct { provider_id: Slug, status: offer_mod.HealthStatus },
    route_actual: selection_mod.ActualRouteEvent,
    failover: struct { from_offer: OfferId, to_offer: OfferId, attempt: u8 },
};

pub const SwitchFailure = enum {
    pinned_offer_unavailable,
    no_matching_offer,
    all_candidates_rejected,
    control_rejected,
    revision_conflict,
};

pub const ControlPlaneEvent = struct {
    event_id: u64,
    stream_sequence: u64,
    event_type: EventType,
    session_id: ?Slug = null,
    config_revision: ?ConfigRevision = null,
    catalog_revision: ?CatalogRevision = null,
    operation_id: ?controls_mod.Bounded(64) = null,
    payload: EventPayload,
};

/// Bounded, replayable event ring.
///
/// Eviction is explicit: a client whose cursor has fallen behind the retained
/// window is told so, and re-reads a fresh snapshot instead of receiving a
/// silently incomplete replay.
pub const EventJournal = struct {
    entries: [MAX_EVENTS]ControlPlaneEvent = undefined,
    len: usize = 0,
    next_sequence: u64 = 1,
    /// Sequence of the oldest retained event.
    oldest_sequence: u64 = 1,

    pub fn append(self: *EventJournal, event_type: EventType, payload: EventPayload, context: EventContext) u64 {
        const sequence = self.next_sequence;
        const event = ControlPlaneEvent{
            .event_id = sequence,
            .stream_sequence = sequence,
            .event_type = event_type,
            .session_id = context.session_id,
            .config_revision = context.config_revision,
            .catalog_revision = context.catalog_revision,
            .operation_id = context.operation_id,
            .payload = payload,
        };
        if (self.len < MAX_EVENTS) {
            self.entries[self.len] = event;
            self.len += 1;
        } else {
            var index: usize = 0;
            while (index + 1 < MAX_EVENTS) : (index += 1) self.entries[index] = self.entries[index + 1];
            self.entries[MAX_EVENTS - 1] = event;
            self.oldest_sequence += 1;
        }
        self.next_sequence += 1;
        return sequence;
    }

    pub fn items(self: *const EventJournal) []const ControlPlaneEvent {
        return self.entries[0..self.len];
    }

    pub const Replay = struct {
        events: []const ControlPlaneEvent,
        /// True when the cursor predates the retained window.
        gap: bool,
    };

    /// Events strictly after `cursor`. A cursor of 0 replays everything held.
    pub fn since(self: *const EventJournal, cursor: u64) Replay {
        const gap = self.len > 0 and cursor + 1 < self.oldest_sequence;
        for (self.items(), 0..) |event, index| {
            if (event.stream_sequence > cursor) return .{ .events = self.entries[index..self.len], .gap = gap };
        }
        return .{ .events = self.entries[self.len..self.len], .gap = gap };
    }
};

pub const EventContext = struct {
    session_id: ?Slug = null,
    config_revision: ?ConfigRevision = null,
    catalog_revision: ?CatalogRevision = null,
    operation_id: ?controls_mod.Bounded(64) = null,
};

// ── kernel ───────────────────────────────────────────────────────────────────

pub const KernelError = error{OutOfMemory};

/// The single source of truth every client reads through.
///
/// Holds the catalog, the three selection scopes, the per-turn snapshot, and
/// the event journal. Persistence is the caller's: `config_store.zig` writes
/// what `globalSelection()` returns.
pub const Kernel = struct {
    allocator: std.mem.Allocator,
    catalog: *const OfferCatalog,
    config_revision: ConfigRevision = .initial,

    global_selection: ?RuntimeSelection = null,
    session_selection: ?RuntimeSelection = null,
    /// Applies to the next turn only, then expires.
    once_selection: ?RuntimeSelection = null,
    /// Frozen at the start of an in-flight turn; a mid-stream commit cannot
    /// change it.
    turn_snapshot: ?RuntimeSelection = null,

    journal: EventJournal = .{},
    summaries: std.ArrayList(OfferSummary) = .empty,

    pub fn init(allocator: std.mem.Allocator, catalog: *const OfferCatalog) Kernel {
        return .{ .allocator = allocator, .catalog = catalog };
    }

    pub fn deinit(self: *Kernel) void {
        self.summaries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn catalogRevision(self: *const Kernel) CatalogRevision {
        return self.catalog.revision;
    }

    fn meta(self: *const Kernel, envelope: ApiEnvelope) ResponseMeta {
        return .{
            .request_id = envelope.request_id,
            .config_revision = self.config_revision,
            .catalog_revision = self.catalogRevision(),
        };
    }

    /// `model.list`. Every client — TUI, Web, CLI — gets the same page.
    pub fn modelList(self: *Kernel, envelope: ApiEnvelope, query: ListQuery) KernelError!ListPage {
        const current = self.currentOfferId();
        self.summaries.clearRetainingCapacity();
        var total: usize = 0;
        var skipped: usize = 0;
        for (self.catalog.items()) |*offer| {
            if (!matchesQuery(offer, query)) continue;
            total += 1;
            if (skipped < query.offset) {
                skipped += 1;
                continue;
            }
            if (query.limit != 0 and self.summaries.items.len >= query.limit) continue;
            const is_current = if (current) |id| id.eql(offer.offer_id) else false;
            try self.summaries.append(self.allocator, OfferSummary.from(offer, is_current));
        }
        return .{
            .meta = self.meta(envelope),
            .offers = self.summaries.items,
            .total = total,
            .truncated = self.summaries.items.len + query.offset < total,
        };
    }

    /// `model.describe`.
    pub fn modelDescribe(self: *const Kernel, offer_id: OfferId) ?OfferSummary {
        const offer = self.catalog.find(offer_id) orelse return null;
        const current = self.currentOfferId();
        const is_current = if (current) |id| id.eql(offer.offer_id) else false;
        return OfferSummary.from(offer, is_current);
    }

    /// The selection in force for the *next* turn: `once`, else session, else
    /// global.
    pub fn effectiveSelection(self: *const Kernel) ?RuntimeSelection {
        if (self.once_selection) |value| return value;
        if (self.session_selection) |value| return value;
        return self.global_selection;
    }

    pub fn currentOfferId(self: *const Kernel) ?OfferId {
        const selection = self.effectiveSelection() orelse return null;
        return switch (selection.target) {
            .pinned_offer => |pin| pin.offer_id,
            .auto_route => selection.resolved_offer_id,
        };
    }

    /// `selection.validate` — resolve the route, revalidate controls against
    /// the resolved offer, and report requested versus effective values. Runs
    /// before any commit and before any network I/O.
    pub fn selectionValidate(self: *const Kernel, candidate: RuntimeSelection) ValidationOutcome {
        const resolution = selection_mod.resolve(self.catalog, candidate) catch |err|
            return .{ .unavailable = err };
        const offer = resolution.primary();
        const outcome = controls_mod.revalidate(candidate.controls, offer.controls);
        return .{ .ok = .{
            .offer_id = offer.offer_id,
            .offer_revision = offer.offer_revision,
            .effective_controls = outcome.effective,
            .cleared_controls = outcome.cleared_len,
            .normalized_controls = outcome.normalized_len,
            .revision_changed = resolution.revision_changed,
        } };
    }

    /// `selection.resolve` — the current effective selection, resolved.
    pub fn selectionResolve(self: *const Kernel) ?ValidationOutcome {
        const selection = self.effectiveSelection() orelse return null;
        return self.selectionValidate(selection);
    }

    /// `selection.commit`. Model identity and controls commit together: a
    /// rejected combination leaves every scope untouched, so the old runtime
    /// stays active and no partial state is written.
    pub fn selectionCommit(
        self: *Kernel,
        envelope: ApiEnvelope,
        candidate: RuntimeSelection,
        scope: Scope,
    ) CommitOutcome {
        if (self.revisionConflict(envelope)) |conflict| {
            _ = self.journal.append(.runtime_switch_failed, .{ .runtime_switch_failed = .{
                .scope = scope,
                .reason = .revision_conflict,
            } }, self.eventContext(envelope));
            return .{ .conflict = conflict };
        }

        const validation = self.selectionValidate(candidate);
        switch (validation) {
            .ok => {},
            .unavailable => |err| {
                _ = self.journal.append(.runtime_switch_failed, .{ .runtime_switch_failed = .{
                    .scope = scope,
                    .reason = switch (err) {
                        error.PinnedOfferUnavailable => .pinned_offer_unavailable,
                        error.NoMatchingOffer => .no_matching_offer,
                        error.AllCandidatesRejected => .all_candidates_rejected,
                    },
                } }, self.eventContext(envelope));
                return .{ .rejected = validation };
            },
            .control_rejected => {
                _ = self.journal.append(.runtime_switch_failed, .{ .runtime_switch_failed = .{
                    .scope = scope,
                    .reason = .control_rejected,
                } }, self.eventContext(envelope));
                return .{ .rejected = validation };
            },
        }

        var committed = candidate;
        committed.scope = scope;
        committed.controls = validation.ok.effective_controls;
        committed.resolved_offer_id = validation.ok.offer_id;
        committed.resolved_offer_revision = validation.ok.offer_revision;
        committed.catalog_revision = self.catalogRevision();

        switch (scope) {
            .once => self.once_selection = committed,
            .session => self.session_selection = committed,
            .global => {
                self.config_revision = self.config_revision.next();
                committed.config_revision = self.config_revision;
                self.global_selection = committed;
            },
        }

        _ = self.journal.append(.runtime_selection_changed, .{ .runtime_selection_changed = .{
            .scope = scope,
            .offer_id = validation.ok.offer_id,
        } }, self.eventContext(envelope));

        return .{ .committed = .{
            .selection = committed,
            .scope = scope,
            .config_revision = self.config_revision,
            .catalog_revision = self.catalogRevision(),
        } };
    }

    /// Freeze the selection for one turn. A commit during the turn changes the
    /// scope state but not this snapshot, so it takes effect next turn.
    pub fn beginTurn(self: *Kernel) ?RuntimeSelection {
        const selection = self.effectiveSelection();
        self.turn_snapshot = selection;
        // `once` is consumed by the turn it applies to.
        self.once_selection = null;
        return selection;
    }

    pub fn turnSelection(self: *const Kernel) ?RuntimeSelection {
        return self.turn_snapshot;
    }

    pub fn endTurn(self: *Kernel) void {
        self.turn_snapshot = null;
    }

    /// Record what a completed turn actually routed to.
    pub fn recordActualRoute(self: *Kernel, event: selection_mod.ActualRouteEvent) void {
        _ = self.journal.append(.route_actual, .{ .route_actual = event }, .{
            .config_revision = self.config_revision,
            .catalog_revision = self.catalogRevision(),
        });
        // An AutoRoute selection remembers the offer it used, so a restart can
        // report the last actual route rather than guessing.
        if (self.session_selection) |*value| {
            if (value.target == .auto_route) {
                value.resolved_offer_id = event.actual_offer_id;
                value.resolved_offer_revision = event.actual_offer_revision;
            }
        }
    }

    fn revisionConflict(self: *const Kernel, envelope: ApiEnvelope) ?CommitOutcome.Conflict {
        const config_stale = if (envelope.expected_config_revision) |expected|
            expected.value() != self.config_revision.value()
        else
            false;
        const catalog_stale = if (envelope.expected_catalog_revision) |expected|
            expected.value() != self.catalogRevision().value()
        else
            false;
        if (!config_stale and !catalog_stale) return null;
        return .{
            .expected_config_revision = envelope.expected_config_revision,
            .actual_config_revision = self.config_revision,
            .expected_catalog_revision = envelope.expected_catalog_revision,
            .actual_catalog_revision = self.catalogRevision(),
        };
    }

    fn eventContext(self: *const Kernel, envelope: ApiEnvelope) EventContext {
        return .{
            .config_revision = self.config_revision,
            .catalog_revision = self.catalogRevision(),
            .operation_id = if (envelope.operation_id) |value|
                controls_mod.Bounded(64).parse(value) catch null
            else
                null,
        };
    }
};

fn matchesQuery(offer: *const ModelOffer, query: ListQuery) bool {
    if (query.provider_id) |wanted| {
        if (!offer.provider_id.eql(wanted)) return false;
    }
    if (query.protocol) |wanted| {
        if (!std.mem.eql(u8, offer.protocol, wanted)) return false;
    }
    if (query.requires_capability) |capability| {
        if (!offer.capabilities.supports(capability)) return false;
    }
    if (query.search) |needle| {
        if (needle.len != 0) {
            const in_display = containsIgnoreCase(offer.display_name, needle);
            const in_request = containsIgnoreCase(offer.request_model_id, needle);
            const in_canonical = if (offer.canonical_model_id) |value|
                containsIgnoreCase(value, needle)
            else
                false;
            if (!in_display and !in_request and !in_canonical) return false;
        }
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const ProviderRegistry = registry_mod.ProviderRegistry;

fn buildCatalog(allocator: std.mem.Allocator, registry: *ProviderRegistry) !OfferCatalog {
    return registry.buildCatalog(allocator, .{});
}

test "model.list serves every client the same catalog with filters" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const all = try kernel.modelList(.{}, .{});
    try std.testing.expect(all.total > 10);
    try std.testing.expect(!all.truncated);
    try std.testing.expectEqual(CatalogRevision.initial, all.meta.catalog_revision);

    const zai = try kernel.modelList(.{}, .{ .provider_id = Slug.lit("zai-coding-plan") });
    try std.testing.expectEqual(@as(usize, 12), zai.total);

    const anthropic_wire = try kernel.modelList(.{}, .{
        .provider_id = Slug.lit("zai-coding-plan"),
        .protocol = "anthropic_messages",
    });
    try std.testing.expectEqual(@as(usize, 6), anthropic_wire.total);

    const searched = try kernel.modelList(.{}, .{ .search = "glm-4.6" });
    try std.testing.expectEqual(@as(usize, 4), searched.total);

    const with_vision = try kernel.modelList(.{}, .{ .requires_capability = .vision });
    for (with_vision.offers) |summary| {
        try std.testing.expect(summary.capabilities.supports(.vision));
    }
    // Unknown capabilities never satisfy a capability filter.
    for (with_vision.offers) |summary| {
        try std.testing.expect(!summary.provider_id.eqlText("zai-coding-plan"));
    }
}

test "paging reports truncation instead of silently shortening the catalog" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const page = try kernel.modelList(.{}, .{ .limit = 3 });
    try std.testing.expectEqual(@as(usize, 3), page.offers.len);
    try std.testing.expect(page.truncated);
    try std.testing.expect(page.total > 3);

    const rest = try kernel.modelList(.{}, .{ .offset = 3, .limit = 1000 });
    try std.testing.expectEqual(page.total - 3, rest.offers.len);
    try std.testing.expect(!rest.truncated);
}

test "offers with the same visible model stay distinct in the client view" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const page = try kernel.modelList(.{}, .{ .search = "GLM-4.6" });
    try std.testing.expectEqual(@as(usize, 4), page.offers.len);
    var seen: [4]OfferId = undefined;
    for (page.offers, 0..) |summary, index| {
        try std.testing.expectEqualStrings("GLM-4.6", summary.display_name);
        for (seen[0..index]) |previous| try std.testing.expect(!previous.eql(summary.offer_id));
        seen[index] = summary.offer_id;
    }
}

test "session, global, and once scopes are isolated with once expiring" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const first = catalog.items()[0];
    const second = catalog.items()[1];
    const third = catalog.items()[2];

    _ = kernel.selectionCommit(.{}, RuntimeSelection.pinned(first.offer_id, first.offer_revision, .global), .global);
    try std.testing.expect(kernel.currentOfferId().?.eql(first.offer_id));
    try std.testing.expectEqual(@as(u64, 2), kernel.config_revision.value());

    _ = kernel.selectionCommit(.{}, RuntimeSelection.pinned(second.offer_id, second.offer_revision, .session), .session);
    try std.testing.expect(kernel.currentOfferId().?.eql(second.offer_id));
    // A session commit does not touch the durable global revision.
    try std.testing.expectEqual(@as(u64, 2), kernel.config_revision.value());

    _ = kernel.selectionCommit(.{}, RuntimeSelection.pinned(third.offer_id, third.offer_revision, .once), .once);
    try std.testing.expect(kernel.currentOfferId().?.eql(third.offer_id));

    const turn = kernel.beginTurn().?;
    try std.testing.expect(turn.target.pinned_offer.offer_id.eql(third.offer_id));
    kernel.endTurn();
    // `once` expired with the turn it applied to; session takes over again.
    try std.testing.expect(kernel.currentOfferId().?.eql(second.offer_id));
    // Global survived underneath.
    try std.testing.expect(kernel.global_selection.?.target.pinned_offer.offer_id.eql(first.offer_id));
}

test "a mid-turn commit affects only the next turn" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const first = catalog.items()[0];
    const second = catalog.items()[1];
    _ = kernel.selectionCommit(.{}, RuntimeSelection.pinned(first.offer_id, first.offer_revision, .session), .session);

    const snapshot = kernel.beginTurn().?;
    _ = kernel.selectionCommit(.{}, RuntimeSelection.pinned(second.offer_id, second.offer_revision, .session), .session);
    try std.testing.expect(kernel.turnSelection().?.target.pinned_offer.offer_id.eql(snapshot.target.pinned_offer.offer_id));
    try std.testing.expect(kernel.turnSelection().?.target.pinned_offer.offer_id.eql(first.offer_id));
    kernel.endTurn();

    const next = kernel.beginTurn().?;
    try std.testing.expect(next.target.pinned_offer.offer_id.eql(second.offer_id));
}

test "a stale expected revision is a deterministic conflict, not a last write" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const first = catalog.items()[0];
    const second = catalog.items()[1];
    // Two clients read the same revision.
    const seen: ConfigRevision = kernel.config_revision;

    const writer_a = kernel.selectionCommit(
        .{ .expected_config_revision = seen },
        RuntimeSelection.pinned(first.offer_id, first.offer_revision, .global),
        .global,
    );
    try std.testing.expect(writer_a == .committed);

    const writer_b = kernel.selectionCommit(
        .{ .expected_config_revision = seen },
        RuntimeSelection.pinned(second.offer_id, second.offer_revision, .global),
        .global,
    );
    try std.testing.expect(writer_b == .conflict);
    try std.testing.expectEqual(seen.value(), writer_b.conflict.expected_config_revision.?.value());
    try std.testing.expect(writer_b.conflict.actual_config_revision.value() > seen.value());
    // The losing write changed nothing.
    try std.testing.expect(kernel.currentOfferId().?.eql(first.offer_id));
}

test "a failed switch leaves the old runtime active and writes no partial state" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const good = catalog.items()[0];
    _ = kernel.selectionCommit(.{}, RuntimeSelection.pinned(good.offer_id, good.offer_revision, .session), .session);
    const before = kernel.config_revision;

    const ghost = OfferId.derive(.{
        .provider_id = Slug.lit("metask"),
        .channel_id = Slug.lit("default"),
        .protocol = "anthropic_messages",
        .endpoint_url = "https://retired.example/v1/messages",
        .request_model_id = "gone",
    });
    const outcome = kernel.selectionCommit(.{}, RuntimeSelection.pinned(ghost, 1, .session), .session);
    try std.testing.expect(outcome == .rejected);
    try std.testing.expectEqual(before.value(), kernel.config_revision.value());
    try std.testing.expect(kernel.currentOfferId().?.eql(good.offer_id));

    const last = kernel.journal.items()[kernel.journal.len - 1];
    try std.testing.expectEqual(EventType.runtime_switch_failed, last.event_type);
    try std.testing.expectEqual(SwitchFailure.pinned_offer_unavailable, last.payload.runtime_switch_failed.reason);
}

test "committing revalidates controls against the resolved offer" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();

    const REASONING = [_][]const u8{ "low", "high" };
    const SPECS = [_]controls_mod.ControlSpec{.{
        .id = "reasoning_effort",
        .label = "Reasoning effort",
        .kind = .enumeration,
        .allowed_values = &REASONING,
    }};
    const models = [_]@import("profile.zig").ModelEntry{.{
        .request_model_id = "ctl-model",
        .display_name = "Controlled",
        .controls = &SPECS,
    }};
    const routes = [_]@import("profile.zig").ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]@import("profile.zig").ChannelDescriptor{.{
        .id = Slug.lit("only"),
        .display_name = "Only",
        .base_url = "https://controls.test/v1",
        .routes = &routes,
    }};
    const kinds = [_]credential.CredentialKind{.api_key};
    try registry.register(.{
        .id = Slug.lit("ctl"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Controlled provider",
        .channels = &channels,
        .models = &models,
        .accepted_credential_kinds = &kinds,
    });

    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("ctl") });
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const offer = catalog.items()[0];
    var selection = RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .session);
    try selection.controls.set("reasoning_effort", try controls_mod.Value.fromText("high"));
    try selection.controls.set("not_supported_here", .{ .number = 5 });

    const outcome = kernel.selectionCommit(.{}, selection, .session);
    try std.testing.expect(outcome == .committed);
    const effective = outcome.committed.selection.controls;
    try std.testing.expect(effective.get("reasoning_effort").?.text.eqlText("high"));
    // A control the offer does not declare is cleared, never carried over.
    try std.testing.expect(effective.get("not_supported_here") == null);

    // The picker only ever sees the offer's own controls.
    const described = kernel.modelDescribe(offer.offer_id).?;
    try std.testing.expectEqual(@as(usize, 1), described.controls.len);
    try std.testing.expect(described.is_current);
}

test "events are ordered, resumable, and carry no payload text" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const first = catalog.items()[0];
    const second = catalog.items()[1];
    _ = kernel.selectionCommit(.{ .request_id = 1 }, RuntimeSelection.pinned(first.offer_id, first.offer_revision, .session), .session);
    const cursor = kernel.journal.next_sequence - 1;
    _ = kernel.selectionCommit(.{ .request_id = 2 }, RuntimeSelection.pinned(second.offer_id, second.offer_revision, .session), .session);

    const replay = kernel.journal.since(cursor);
    try std.testing.expect(!replay.gap);
    try std.testing.expectEqual(@as(usize, 1), replay.events.len);
    try std.testing.expectEqual(EventType.runtime_selection_changed, replay.events[0].event_type);
    try std.testing.expect(replay.events[0].payload.runtime_selection_changed.offer_id.?.eql(second.offer_id));
    // Sequences are strictly increasing, so a reconnecting client can resume.
    var previous: u64 = 0;
    for (kernel.journal.items()) |event| {
        try std.testing.expect(event.stream_sequence > previous);
        previous = event.stream_sequence;
    }
}

test "an evicted cursor is reported as a gap, not replayed incompletely" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    var index: usize = 0;
    while (index < MAX_EVENTS + 5) : (index += 1) {
        _ = kernel.journal.append(.pricing_updated, .{ .pricing_updated = .{
            .provider_id = Slug.lit("metask"),
        } }, .{});
    }
    try std.testing.expectEqual(MAX_EVENTS, kernel.journal.len);
    const replay = kernel.journal.since(1);
    try std.testing.expect(replay.gap);
    const fresh = kernel.journal.since(kernel.journal.next_sequence - 2);
    try std.testing.expect(!fresh.gap);
    try std.testing.expectEqual(@as(usize, 1), fresh.events.len);
}

test "an auto route records the offer it actually used" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const selection = try RuntimeSelection.auto("zai/glm-4.6", .{ .fallback_allowed = true }, .session);
    const outcome = kernel.selectionCommit(.{}, selection, .session);
    try std.testing.expect(outcome == .committed);
    const resolution = try selection_mod.resolve(&catalog, selection);

    const used = resolution.items()[1];
    kernel.recordActualRoute(selection_mod.ActualRouteEvent.forResolution(selection, &resolution, used));
    try std.testing.expect(kernel.session_selection.?.resolved_offer_id.?.eql(used.offer_id));

    const last = kernel.journal.items()[kernel.journal.len - 1];
    try std.testing.expectEqual(EventType.route_actual, last.event_type);
    try std.testing.expectEqual(selection_mod.RouteStatus.fell_back, last.payload.route_actual.status);
    // Requested identity survives alongside the actual one.
    try std.testing.expect(last.payload.route_actual.requested == .selector);
}
