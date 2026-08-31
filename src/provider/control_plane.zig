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
const sync = @import("platform").sync;

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
    /// Correlation key echoed onto emitted events. At most 64 bytes; a longer
    /// id is not recorded on the event (it never affects the decision, only
    /// the annotation).
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
    /// Borrowed from the caller-owned buffer passed to `modelList`, so two
    /// concurrent readers never share it and a page stays valid for as long as
    /// its owner keeps the buffer alive.
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
        /// Ids dropped because the resolved offer does not declare them. A
        /// picker has to name them; a count alone cannot be rendered.
        cleared: [controls_mod.MAX_CONTROLS]controls_mod.ControlId = undefined,
        /// A provider-declared control on this selection needs the user to
        /// confirm before it takes effect.
        requires_confirmation: bool = false,
        /// Provider-declared cost/latency notes for the selected controls,
        /// borrowed from the offer's `ControlSpec`s. The kernel does not write
        /// this text; it carries what the provider declared.
        warnings: [controls_mod.MAX_CONTROLS][]const u8 = undefined,
        warnings_len: u8 = 0,

        pub fn warningsSlice(self: *const Accepted) []const []const u8 {
            return self.warnings[0..self.warnings_len];
        }

        pub fn clearedSlice(self: *const Accepted) []const controls_mod.ControlId {
            return self.cleared[0..self.cleared_controls];
        }
    };

    pub const ControlRejection = struct {
        control_id: controls_mod.ControlId,
        reason: Reason,

        pub const Reason = enum {
            /// The selected offer does not declare this control at all.
            unsupported_by_offer,
            /// The offer declares it, but refuses this value and its declared
            /// normalization policy cannot map it onto a legal one.
            invalid_value,
        };
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
        /// A `global` commit is durable state. The kernel does not invent a
        /// revision for it: the embedder writes the selection through
        /// `config_store` and feeds the resulting revision back with
        /// `adoptConfigRevision`. Two counters both called `config_revision`
        /// would make `expected_config_revision` meaningless.
        requires_persist: bool = false,
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

    /// Events dropped per eviction. Compacting in blocks keeps `items()` a
    /// contiguous slice (so replay stays a plain subslice) while making append
    /// amortised O(1) instead of memmoving the whole ring on every event.
    /// Retention therefore varies between `MAX_EVENTS - EVICT_BLOCK` and
    /// `MAX_EVENTS`; a cursor older than that is reported as a gap.
    pub const EVICT_BLOCK: usize = MAX_EVENTS / 4;

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
        if (self.len == MAX_EVENTS) {
            const kept = MAX_EVENTS - EVICT_BLOCK;
            std.mem.copyForwards(
                ControlPlaneEvent,
                self.entries[0..kept],
                self.entries[EVICT_BLOCK..MAX_EVENTS],
            );
            self.len = kept;
            self.oldest_sequence += EVICT_BLOCK;
        }
        self.entries[self.len] = event;
        self.len += 1;
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
        const gap = self.len > 0 and (cursor +| 1) < self.oldest_sequence;
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

pub const KernelError = error{
    OutOfMemory,
    /// The caller's envelope declares an API version this kernel does not
    /// implement. Answering anyway would let an incompatible client read a
    /// response shape it cannot interpret.
    UnsupportedApiVersion,
};

/// The single source of truth every client reads through.
///
/// Holds the catalog, the three selection scopes, the per-turn snapshot, and
/// the event journal. Persistence is the caller's: `config_store.zig` writes
/// what `globalSelection()` returns.
///
/// **Concurrency.** The requirement is that one kernel serves the TUI, the Web
/// UI, and the CLI, and a Web host answers on its own threads — so mutable
/// state here is guarded rather than left to a convention nobody can enforce.
/// The catalog itself is immutable once built and is read without the lock;
/// selection scopes, the turn snapshot, and the journal are guarded. Reads
/// return values, not borrowed internals, so a caller can hold a result while
/// another thread commits.
pub const Kernel = struct {
    allocator: std.mem.Allocator,
    catalog: *const OfferCatalog,
    /// Optional profile registry, needed only for provider-owned hooks such as
    /// pricing. Borrowed; it must outlive the kernel.
    registry: ?*const registry_mod.ProviderRegistry = null,

    mutex: sync.Mutex = .{},
    config_revision: ConfigRevision = .initial,

    global_selection: ?RuntimeSelection = null,
    session_selection: ?RuntimeSelection = null,
    /// Applies to the next turn only, then expires.
    once_selection: ?RuntimeSelection = null,
    /// Frozen at the start of an in-flight turn; a mid-stream commit cannot
    /// change it.
    turn_snapshot: ?RuntimeSelection = null,

    journal: EventJournal = .{},

    pub fn init(allocator: std.mem.Allocator, catalog: *const OfferCatalog) Kernel {
        return .{ .allocator = allocator, .catalog = catalog };
    }

    pub fn deinit(self: *Kernel) void {
        self.* = undefined;
    }

    /// Publish-safe read of the catalog pointer.
    ///
    /// `adoptCatalog` can replace it, so an unsynchronized read could observe a
    /// stale or torn pointer. The catalog *contents* are immutable once built,
    /// so iteration after the snapshot needs no lock. The previous catalog must
    /// outlive in-flight readers; its owner controls that.
    pub fn catalogSnapshot(self: *Kernel) *const OfferCatalog {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.catalog;
    }

    pub fn catalogRevision(self: *Kernel) CatalogRevision {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.catalog.revision;
    }

    fn catalogRevisionLocked(self: *const Kernel) CatalogRevision {
        return self.catalog.revision;
    }

    /// Swap in a refreshed catalog and announce it.
    ///
    /// `catalog.updated` exists so clients re-read after a refresh; an event
    /// type with no producer is decoration, so the swap emits it.
    pub fn adoptCatalog(self: *Kernel, catalog: *const OfferCatalog) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.catalog = catalog;
        _ = self.journal.append(.catalog_updated, .{ .catalog_updated = .{
            .offer_count = @intCast(catalog.items().len),
        } }, .{
            .config_revision = self.config_revision,
            .catalog_revision = catalog.revision,
        });
    }

    /// Adopt the durable configuration revision.
    ///
    /// `config_store` is the sole authority for this number; the kernel mirrors
    /// it so `expected_config_revision` means the same thing on both sides.
    /// Call it at bootstrap after loading the document, and after every durable
    /// commit.
    pub fn adoptConfigRevision(self: *Kernel, revision: ConfigRevision) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.config_revision = revision;
        if (self.global_selection) |*value| value.config_revision = revision;
    }

    fn requireSupportedEnvelope(envelope: ApiEnvelope) KernelError!void {
        if (envelope.api_version != API_VERSION) return error.UnsupportedApiVersion;
        if (envelope.schema_version > SCHEMA_VERSION) return error.UnsupportedApiVersion;
    }

    fn meta(self: *Kernel, envelope: ApiEnvelope) ResponseMeta {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.metaLocked(envelope);
    }

    fn metaLocked(self: *const Kernel, envelope: ApiEnvelope) ResponseMeta {
        return .{
            .request_id = envelope.request_id,
            .config_revision = self.config_revision,
            .catalog_revision = self.catalogRevisionLocked(),
        };
    }

    /// `model.list`. Every client — TUI, Web, CLI — gets the same page.
    ///
    /// The caller owns `out`; the returned page borrows it. A shared buffer
    /// inside the kernel would make one client's next call invalidate another
    /// client's page, which is exactly the aliasing a multi-client control
    /// plane must not have.
    /// Takes a mutable receiver because it reads guarded selection state under
    /// the kernel lock. That is the whole reason — the offer data it returns
    /// comes from the immutable catalog and goes into the caller's buffer.
    pub fn modelList(
        self: *Kernel,
        envelope: ApiEnvelope,
        query: ListQuery,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(OfferSummary),
    ) KernelError!ListPage {
        try requireSupportedEnvelope(envelope);
        const catalog = self.catalogSnapshot();
        const current = self.currentOfferId();
        out.clearRetainingCapacity();
        var total: usize = 0;
        var skipped: usize = 0;
        for (catalog.items()) |*offer| {
            if (!matchesQuery(offer, query)) continue;
            total += 1;
            if (skipped < query.offset) {
                skipped += 1;
                continue;
            }
            if (query.limit != 0 and out.items.len >= query.limit) continue;
            const is_current = if (current) |id| id.eql(offer.offer_id) else false;
            try out.append(gpa, OfferSummary.from(offer, is_current));
        }
        return .{
            .meta = self.meta(envelope),
            .offers = out.items,
            .total = total,
            .truncated = out.items.len + query.offset < total,
        };
    }

    /// `quote.estimate` — provider-owned pricing for one usage sample on one
    /// offer.
    ///
    /// The provider's hook is asked first: rate lookup, discounts, and currency
    /// conversion are its business, not the kernel's. Without a hook the
    /// offer's catalog quote stands, and with neither the answer is `unknown` —
    /// never a fabricated zero.
    pub fn quoteEstimate(
        self: *Kernel,
        offer_id: OfferId,
        usage: offer_mod.Usage,
    ) offer_mod.Quote {
        return self.quoteAgainst(self.catalogSnapshot(), offer_id, usage);
    }

    /// Never acquires the lock: callers that already hold it price in place,
    /// and `quoteEstimate` snapshots first.
    fn quoteAgainst(
        self: *const Kernel,
        catalog: *const OfferCatalog,
        offer_id: OfferId,
        usage: offer_mod.Usage,
    ) offer_mod.Quote {
        const offer = catalog.find(offer_id) orelse return .unknown;
        if (self.registry) |registry| {
            if (registry.findById(offer.provider_id)) |profile| {
                const hooked = profile.quote(offer.request_model_id, offer.channel_id, usage);
                if (hooked.isKnown()) return hooked;
            }
        }
        return offer.quote;
    }

    /// `model.describe`.
    pub fn modelDescribe(self: *Kernel, offer_id: OfferId) ?OfferSummary {
        const offer = self.catalogSnapshot().find(offer_id) orelse return null;
        const current = self.currentOfferId();
        const is_current = if (current) |id| id.eql(offer.offer_id) else false;
        return OfferSummary.from(offer, is_current);
    }

    /// The selection in force for the *next* turn: `once`, else session, else
    /// global.
    pub fn effectiveSelection(self: *Kernel) ?RuntimeSelection {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.effectiveSelectionLocked();
    }

    fn effectiveSelectionLocked(self: *const Kernel) ?RuntimeSelection {
        if (self.once_selection) |value| return value;
        if (self.session_selection) |value| return value;
        return self.global_selection;
    }

    pub fn currentOfferId(self: *Kernel) ?OfferId {
        const selection = self.effectiveSelection() orelse return null;
        return offerIdOf(selection);
    }

    fn offerIdOf(selection: RuntimeSelection) ?OfferId {
        return switch (selection.target) {
            .pinned_offer => |pin| pin.offer_id,
            .auto_route => selection.resolved_offer_id,
        };
    }

    /// `selection.validate` — resolve the route and check the controls against
    /// the resolved offer. Runs before any commit and before any network I/O.
    ///
    /// Strict: a control the offer does not declare, or a value the provider
    /// refuses and cannot normalize, is a rejection. Explicitly asking for an
    /// unsupported service tier or reasoning value must fail rather than be
    /// silently dropped — `rebaseSelection` is the separate, lenient path for
    /// carrying an existing control set to a different offer.
    pub fn selectionValidate(self: *Kernel, candidate: RuntimeSelection) ValidationOutcome {
        return validateAgainstOffer(self.catalogSnapshot(), candidate, .strict);
    }

    /// `selection.rebase` — the offer-switch path.
    ///
    /// Controls the new offer cannot honor are cleared or normalized instead of
    /// rejected, so a picker can show the user what a switch would keep before
    /// committing it. The result is a complete replacement set, applied
    /// atomically by `selectionCommit`.
    pub fn rebaseSelection(self: *Kernel, candidate: RuntimeSelection) ValidationOutcome {
        return validateAgainstOffer(self.catalogSnapshot(), candidate, .lenient);
    }

    const ControlMode = enum { strict, lenient };

    fn validateAgainstOffer(
        catalog: *const OfferCatalog,
        candidate: RuntimeSelection,
        mode: ControlMode,
    ) ValidationOutcome {
        const resolution = selection_mod.resolve(catalog, candidate) catch |err|
            return .{ .unavailable = err };
        const offer = resolution.primary();

        var accepted = ValidationOutcome.Accepted{
            .offer_id = offer.offer_id,
            .offer_revision = offer.offer_revision,
            .effective_controls = .{},
            .cleared_controls = 0,
            .normalized_controls = 0,
            .revision_changed = resolution.revision_changed,
        };

        if (mode == .strict) {
            for (candidate.controls.items()) |entry| {
                const spec = controls_mod.findSpec(offer.controls, entry.id.slice()) orelse
                    return .{ .control_rejected = .{
                        .control_id = entry.id,
                        .reason = .unsupported_by_offer,
                    } };
                const checked = controls_mod.validate(spec, entry.value) catch
                    return .{ .control_rejected = .{
                        .control_id = entry.id,
                        .reason = .invalid_value,
                    } };
                if (checked.confirmation_required) accepted.requires_confirmation = true;
                if (checked.warning) |text| {
                    if (accepted.warnings_len < controls_mod.MAX_CONTROLS) {
                        accepted.warnings[accepted.warnings_len] = text;
                        accepted.warnings_len += 1;
                    }
                }
            }
        }

        const outcome = controls_mod.revalidate(candidate.controls, offer.controls);
        accepted.effective_controls = outcome.effective;
        accepted.cleared_controls = outcome.cleared_len;
        @memcpy(
            accepted.cleared[0..outcome.cleared_len],
            outcome.clearedItems(),
        );
        accepted.normalized_controls = outcome.normalized_len;
        return .{ .ok = accepted };
    }

    /// `selection.resolve` — the current effective selection, resolved.
    pub fn selectionResolve(self: *Kernel) ?ValidationOutcome {
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
        // One lock for the whole commit: the conflict check, the validation,
        // and the scope write must be one transaction, or two writers both see
        // a matching revision and both win.
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.revisionConflict(envelope)) |conflict| {
            _ = self.journal.append(.runtime_switch_failed, .{ .runtime_switch_failed = .{
                .scope = scope,
                .reason = .revision_conflict,
            } }, self.eventContext(envelope));
            return .{ .conflict = conflict };
        }

        // The lock is already held for the whole transaction, so validate
        // against the catalog directly: going through `selectionValidate`
        // would re-enter `catalogSnapshot` and deadlock on a non-reentrant
        // mutex.
        const validation = validateAgainstOffer(self.catalog, candidate, .strict);
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
        committed.catalog_revision = self.catalogRevisionLocked();

        switch (scope) {
            .once => self.once_selection = committed,
            .session => self.session_selection = committed,
            .global => {
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
            .catalog_revision = self.catalogRevisionLocked(),
            .requires_persist = scope == .global,
        } };
    }

    /// Install a selection that a *previous* process committed, read back from
    /// the durable document at startup.
    ///
    /// Deliberately not a commit: it writes no event, bumps no revision, and
    /// skips validation, because nothing changed — this is the kernel catching
    /// up to state that already exists. Validating here would also be wrong,
    /// since a pin whose offer has since vanished must surface at the point the
    /// route is resolved, with the actionable message, rather than being
    /// silently dropped during boot.
    pub fn seedGlobalSelection(self: *Kernel, selection: RuntimeSelection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var seeded = selection;
        seeded.scope = .global;
        self.global_selection = seeded;
    }

    /// Freeze the selection for one turn. A commit during the turn changes the
    /// scope state but not this snapshot, so it takes effect next turn.
    pub fn beginTurn(self: *Kernel) ?RuntimeSelection {
        self.mutex.lock();
        defer self.mutex.unlock();
        const selection = self.effectiveSelectionLocked();
        self.turn_snapshot = selection;
        // `once` is consumed by the turn it applies to.
        self.once_selection = null;
        return selection;
    }

    pub fn turnSelection(self: *Kernel) ?RuntimeSelection {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.turn_snapshot;
    }

    pub fn endTurn(self: *Kernel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.turn_snapshot = null;
    }

    /// `events.replay` — events after `cursor`, copied into a caller-owned
    /// buffer under the lock.
    ///
    /// `EventJournal.since` hands back a slice into the ring, and the ring
    /// memmoves on eviction; a client reading it while another thread commits
    /// would walk moved memory. Copying is what makes the replay contract
    /// usable from more than one thread.
    pub fn replayEvents(
        self: *Kernel,
        cursor: u64,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(ControlPlaneEvent),
    ) KernelError!EventJournal.Replay {
        self.mutex.lock();
        defer self.mutex.unlock();
        const view = self.journal.since(cursor);
        out.clearRetainingCapacity();
        try out.appendSlice(gpa, view.events);
        return .{ .events = out.items, .gap = view.gap };
    }

    /// Record what a completed turn actually routed to.
    ///
    /// Cost is filled in from the provider's quote when the caller did not
    /// price the turn itself; latency stays caller-supplied because only the
    /// transport can measure it.
    pub fn recordActualRoute(self: *Kernel, observed: selection_mod.ActualRouteEvent) void {
        var event = observed;
        if (event.cost_micros == null) {
            // Pricing calls a provider-supplied hook. Doing that under the
            // kernel lock would let a slow or misbehaving vendor callback stall
            // every other client, so it runs first and the journal write takes
            // the lock afterwards.
            event.cost_micros = self.quoteEstimate(event.actual_offer_id, event.usage)
                .estimateMicros(event.usage);
        }
        self.appendRouteEvents(event);
    }

    /// Split out so neither half mixes locking with a locking call: this body
    /// takes the lock and uses only `…Locked` helpers, while its caller runs
    /// the provider hook with no lock held.
    fn appendRouteEvents(self: *Kernel, event: selection_mod.ActualRouteEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const context = EventContext{
            .config_revision = self.config_revision,
            .catalog_revision = self.catalogRevisionLocked(),
        };
        _ = self.journal.append(.route_actual, .{ .route_actual = event }, context);
        // A turn that did not use its first candidate is a failover; the
        // requested and actual identities are both preserved.
        if (event.fallback_attempts > 0) {
            if (self.effectiveSelectionLocked()) |selection| {
                if (offerIdOf(selection)) |requested| {
                    _ = self.journal.append(.failover, .{ .failover = .{
                        .from_offer = requested,
                        .to_offer = event.actual_offer_id,
                        .attempt = event.fallback_attempts,
                    } }, context);
                }
            }
        }
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
            expected.value() != self.catalogRevisionLocked().value()
        else
            false;
        if (!config_stale and !catalog_stale) return null;
        return .{
            .expected_config_revision = envelope.expected_config_revision,
            .actual_config_revision = self.config_revision,
            .expected_catalog_revision = envelope.expected_catalog_revision,
            .actual_catalog_revision = self.catalogRevisionLocked(),
        };
    }

    /// Called with the kernel lock already held.
    fn eventContext(self: *const Kernel, envelope: ApiEnvelope) EventContext {
        return .{
            .config_revision = self.config_revision,
            .catalog_revision = self.catalogRevisionLocked(),
            // Over-long ids are dropped from the annotation rather than
            // truncated: a truncated correlation key silently points at the
            // wrong operation.
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

    var buffer: std.ArrayList(OfferSummary) = .empty;
    defer buffer.deinit(a);
    const all = try kernel.modelList(.{}, .{}, a, &buffer);
    try std.testing.expect(all.total > 10);
    try std.testing.expect(!all.truncated);
    try std.testing.expectEqual(CatalogRevision.initial, all.meta.catalog_revision);

    const zai = try kernel.modelList(.{}, .{ .provider_id = Slug.lit("zai-coding-plan") }, a, &buffer);
    try std.testing.expectEqual(@as(usize, 12), zai.total);

    const anthropic_wire = try kernel.modelList(.{}, .{
        .provider_id = Slug.lit("zai-coding-plan"),
        .protocol = "anthropic_messages",
    }, a, &buffer);
    try std.testing.expectEqual(@as(usize, 6), anthropic_wire.total);

    const searched = try kernel.modelList(.{}, .{ .search = "glm-4.6" }, a, &buffer);
    try std.testing.expectEqual(@as(usize, 4), searched.total);

    const with_vision = try kernel.modelList(.{}, .{ .requires_capability = .vision }, a, &buffer);
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

    var buffer: std.ArrayList(OfferSummary) = .empty;
    defer buffer.deinit(a);
    const page = try kernel.modelList(.{}, .{ .limit = 3 }, a, &buffer);
    try std.testing.expectEqual(@as(usize, 3), page.offers.len);
    try std.testing.expect(page.truncated);
    try std.testing.expect(page.total > 3);

    var rest_buffer: std.ArrayList(OfferSummary) = .empty;
    defer rest_buffer.deinit(a);
    const rest = try kernel.modelList(.{}, .{ .offset = 3, .limit = 1000 }, a, &rest_buffer);
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

    var buffer: std.ArrayList(OfferSummary) = .empty;
    defer buffer.deinit(a);
    const page = try kernel.modelList(.{}, .{ .search = "GLM-4.6" }, a, &buffer);
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

    const durable = kernel.selectionCommit(
        .{},
        RuntimeSelection.pinned(first.offer_id, first.offer_revision, .global),
        .global,
    );
    try std.testing.expect(kernel.currentOfferId().?.eql(first.offer_id));
    // The kernel does not invent a durable revision: the store owns that
    // number and the embedder feeds it back after persisting.
    try std.testing.expect(durable.committed.requires_persist);
    try std.testing.expectEqual(@as(u64, 1), kernel.config_revision.value());
    kernel.adoptConfigRevision(@enumFromInt(7));
    try std.testing.expectEqual(@as(u64, 7), kernel.config_revision.value());
    try std.testing.expectEqual(@as(u64, 7), kernel.global_selection.?.config_revision.value());

    const scoped = kernel.selectionCommit(
        .{},
        RuntimeSelection.pinned(second.offer_id, second.offer_revision, .session),
        .session,
    );
    try std.testing.expect(kernel.currentOfferId().?.eql(second.offer_id));
    // A session commit is not durable state and needs no persistence.
    try std.testing.expect(!scoped.committed.requires_persist);
    try std.testing.expectEqual(@as(u64, 7), kernel.config_revision.value());

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
    // Writer A persists through the store and feeds the durable revision back;
    // that is what moves the number both clients compare against.
    kernel.adoptConfigRevision(seen.next());

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
    const clean = kernel.selectionCommit(.{}, selection, .session);
    try std.testing.expect(clean == .committed);
    try std.testing.expect(clean.committed.selection.controls.get("reasoning_effort").?.text.eqlText("high"));

    // Explicitly asking for a control this offer does not declare is a
    // rejection, not a silent drop, and it leaves the committed state alone.
    var stray = selection;
    try stray.controls.set("not_supported_here", .{ .number = 5 });
    const rejected = kernel.selectionCommit(.{}, stray, .session);
    try std.testing.expect(rejected == .rejected);
    try std.testing.expect(rejected.rejected == .control_rejected);
    try std.testing.expect(rejected.rejected.control_rejected.control_id.eqlText("not_supported_here"));
    try std.testing.expectEqual(
        ValidationOutcome.ControlRejection.Reason.unsupported_by_offer,
        rejected.rejected.control_rejected.reason,
    );
    try std.testing.expect(kernel.session_selection.?.controls.get("not_supported_here") == null);

    // An out-of-vocabulary value for a declared control is rejected too.
    var bad_value = RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .session);
    try bad_value.controls.set("reasoning_effort", try controls_mod.Value.fromText("ultra"));
    const invalid = kernel.selectionCommit(.{}, bad_value, .session);
    try std.testing.expect(invalid == .rejected);
    try std.testing.expectEqual(
        ValidationOutcome.ControlRejection.Reason.invalid_value,
        invalid.rejected.control_rejected.reason,
    );

    // The offer-switch path is the lenient one: it clears what the new offer
    // cannot honor so a picker can preview the switch.
    const rebased = kernel.rebaseSelection(stray);
    try std.testing.expect(rebased == .ok);
    try std.testing.expectEqual(@as(u8, 1), rebased.ok.cleared_controls);
    try std.testing.expect(rebased.ok.effective_controls.get("not_supported_here") == null);
    try std.testing.expect(rebased.ok.effective_controls.get("reasoning_effort") != null);

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

    // Clients replay through the kernel, which copies under the lock; the ring
    // itself is internal and memmoves on eviction.
    var events: std.ArrayList(ControlPlaneEvent) = .empty;
    defer events.deinit(a);
    const replay = try kernel.replayEvents(cursor, a, &events);
    try std.testing.expect(!replay.gap);
    try std.testing.expectEqual(@as(usize, 1), replay.events.len);
    try std.testing.expectEqual(EventType.runtime_selection_changed, replay.events[0].event_type);
    try std.testing.expect(replay.events[0].payload.runtime_selection_changed.offer_id.?.eql(second.offer_id));

    // The copy stays valid across further commits that evict from the ring.
    var churn: usize = 0;
    while (churn < MAX_EVENTS + 8) : (churn += 1) {
        _ = kernel.selectionCommit(
            .{},
            RuntimeSelection.pinned(first.offer_id, first.offer_revision, .session),
            .session,
        );
    }
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
    // Eviction happens in blocks, so retention sits inside a known band rather
    // than at exactly MAX_EVENTS.
    try std.testing.expect(kernel.journal.len <= MAX_EVENTS);
    try std.testing.expect(kernel.journal.len > MAX_EVENTS - EventJournal.EVICT_BLOCK);

    const replay = kernel.journal.since(1);
    try std.testing.expect(replay.gap);
    const fresh = kernel.journal.since(kernel.journal.next_sequence - 2);
    try std.testing.expect(!fresh.gap);
    try std.testing.expectEqual(@as(usize, 1), fresh.events.len);

    // Sequences stay strictly increasing and contiguous across an eviction.
    var previous: u64 = kernel.journal.oldest_sequence - 1;
    for (kernel.journal.items()) |event| {
        try std.testing.expectEqual(previous + 1, event.stream_sequence);
        previous = event.stream_sequence;
    }
    // A cursor at the maximum value cannot overflow the gap computation.
    const saturated = kernel.journal.since(std.math.maxInt(u64));
    try std.testing.expect(!saturated.gap);
    try std.testing.expectEqual(@as(usize, 0), saturated.events.len);
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

    const events = kernel.journal.items();
    // A fallback emits both the route record and a failover event; the
    // requested and actual identities survive in each.
    const route = events[events.len - 2];
    try std.testing.expectEqual(EventType.route_actual, route.event_type);
    try std.testing.expectEqual(selection_mod.RouteStatus.fell_back, route.payload.route_actual.status);
    try std.testing.expect(route.payload.route_actual.requested == .selector);

    const failover = events[events.len - 1];
    try std.testing.expectEqual(EventType.failover, failover.event_type);
    try std.testing.expect(failover.payload.failover.to_offer.eql(used.offer_id));
    try std.testing.expect(!failover.payload.failover.from_offer.eql(used.offer_id));
    try std.testing.expectEqual(@as(u8, 1), failover.payload.failover.attempt);
}

test "concurrent readers and a writer do not corrupt kernel state" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const Worker = struct {
        kernel: *Kernel,
        catalog: *const OfferCatalog,
        seed: usize,
        failures: *std.atomic.Value(u32),

        fn read(self: *@This()) void {
            var buffer: std.ArrayList(OfferSummary) = .empty;
            defer buffer.deinit(std.heap.c_allocator);
            var round: usize = 0;
            while (round < 200) : (round += 1) {
                const page = self.kernel.modelList(
                    .{},
                    .{},
                    std.heap.c_allocator,
                    &buffer,
                ) catch {
                    _ = self.failures.fetchAdd(1, .monotonic);
                    return;
                };
                // Each reader owns its buffer, so the page it holds cannot be
                // rewritten by the other reader.
                if (page.offers.len != page.total) _ = self.failures.fetchAdd(1, .monotonic);
                if (page.offers.len != self.catalog.items().len) {
                    _ = self.failures.fetchAdd(1, .monotonic);
                }
                _ = self.kernel.modelDescribe(self.catalog.items()[0].offer_id);
                _ = self.kernel.catalogRevision();
                var replay: std.ArrayList(ControlPlaneEvent) = .empty;
                defer replay.deinit(std.heap.c_allocator);
                _ = self.kernel.replayEvents(0, std.heap.c_allocator, &replay) catch {
                    _ = self.failures.fetchAdd(1, .monotonic);
                    return;
                };
            }
        }

        fn write(self: *@This()) void {
            var round: usize = 0;
            while (round < 200) : (round += 1) {
                const offer = &self.catalog.items()[(self.seed + round) % self.catalog.items().len];
                _ = self.kernel.selectionCommit(
                    .{},
                    RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .session),
                    .session,
                );
                // Exercise every locked path, not just commit: a lock taken
                // twice on one of these hangs here instead of surfacing as an
                // unrelated test timing out ten minutes later.
                _ = self.kernel.beginTurn();
                self.kernel.endTurn();
                _ = self.kernel.selectionResolve();
                _ = self.kernel.quoteEstimate(offer.offer_id, .{ .input_tokens = 10 });
                self.kernel.recordActualRoute(.{
                    .requested = .{ .pinned = offer.offer_id },
                    .actual_offer_id = offer.offer_id,
                    .actual_offer_revision = offer.offer_revision,
                    .provider_id = offer.provider_id,
                    .channel_id = offer.channel_id,
                    .protocol = offer.protocol,
                    .usage = .{ .input_tokens = 10, .output_tokens = 5 },
                });
                self.kernel.adoptConfigRevision(@enumFromInt(round + 1));
            }
        }
    };

    var failures = std.atomic.Value(u32).init(0);
    var readers = [_]Worker{
        .{ .kernel = &kernel, .catalog = &catalog, .seed = 0, .failures = &failures },
        .{ .kernel = &kernel, .catalog = &catalog, .seed = 1, .failures = &failures },
    };
    var writer = Worker{ .kernel = &kernel, .catalog = &catalog, .seed = 2, .failures = &failures };

    const threads = [_]std.Thread{
        try std.Thread.spawn(.{}, Worker.read, .{&readers[0]}),
        try std.Thread.spawn(.{}, Worker.read, .{&readers[1]}),
        try std.Thread.spawn(.{}, Worker.write, .{&writer}),
    };
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
    // The writer's last commit is intact and the journal stayed consistent.
    try std.testing.expect(kernel.currentOfferId() != null);
    try std.testing.expect(kernel.journal.len > 0);
    var previous: u64 = kernel.journal.oldest_sequence - 1;
    for (kernel.journal.items()) |event| {
        try std.testing.expectEqual(previous + 1, event.stream_sequence);
        previous = event.stream_sequence;
    }
}

const HOOKED_MODELS = [_]@import("profile.zig").ModelEntry{.{
    .request_model_id = "priced-m1",
    .display_name = "Priced M1",
}};
const HOOKED_ROUTES = [_]@import("profile.zig").ProtocolRoute{.{ .protocol = .openai_chat }};
const HOOKED_CHANNELS = [_]@import("profile.zig").ChannelDescriptor{.{
    .id = Slug.lit("only"),
    .display_name = "Only",
    .base_url = "https://priced.test/v1",
    .routes = &HOOKED_ROUTES,
}};
const HOOKED_KINDS = [_]credential.CredentialKind{.api_key};

fn hookedQuote(
    request_model_id: []const u8,
    channel_id: Slug,
    usage: offer_mod.Usage,
) offer_mod.Quote {
    _ = channel_id;
    _ = usage;
    if (!std.mem.eql(u8, request_model_id, "priced-m1")) return .unknown;
    return .{ .known = .{
        .currency = offer_mod.Currency.lit("USD"),
        .billing_unit = .per_million_tokens,
        .input_price_micros = 3_000_000,
        .output_price_micros = 15_000_000,
        .provenance = offer_mod.Provenance.known(.provider_catalog, 1),
    } };
}

test "quote.estimate reaches the provider-owned pricing hook" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    try registry.register(.{
        .id = Slug.lit("priced"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Priced provider",
        .channels = &HOOKED_CHANNELS,
        .models = &HOOKED_MODELS,
        .accepted_credential_kinds = &HOOKED_KINDS,
        .quote_hook = hookedQuote,
    });
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("priced") });
    defer catalog.deinit();

    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    // Without the registry the kernel can only report the catalog's own quote,
    // which this profile leaves unknown.
    try std.testing.expect(!kernel.quoteEstimate(catalog.items()[0].offer_id, .{}).isKnown());

    kernel.registry = &registry;
    const quote = kernel.quoteEstimate(catalog.items()[0].offer_id, .{});
    try std.testing.expect(quote.isKnown());
    try std.testing.expect(quote.priced().?.currency.eql(offer_mod.Currency.lit("USD")));
    const cost = quote.estimateMicros(.{ .input_tokens = 1_000_000, .output_tokens = 1_000_000 }).?;
    try std.testing.expectEqual(@as(u64, 18_000_000), cost);

    // An offer that is not in the catalog prices as unknown, not as free.
    const ghost = OfferId.derive(.{
        .provider_id = Slug.lit("priced"),
        .channel_id = Slug.lit("only"),
        .protocol = "openai_chat",
        .endpoint_url = "https://priced.test/v1/chat/completions",
        .request_model_id = "gone",
    });
    try std.testing.expect(!kernel.quoteEstimate(ghost, .{}).isKnown());
}

test "validation surfaces provider warnings and confirmation requirements" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();

    const EFFORT = [_][]const u8{ "low", "high" };
    const TIER = [_][]const u8{ "standard", "priority" };
    const SPECS = [_]controls_mod.ControlSpec{
        .{
            .id = "reasoning_effort",
            .label = "Reasoning effort",
            .kind = .enumeration,
            .allowed_values = &EFFORT,
            .cost_latency_warning = "higher effort costs more and responds slower",
        },
        .{
            .id = "service_tier",
            .label = "Service tier",
            .kind = .enumeration,
            .allowed_values = &TIER,
            .confirmation_required = true,
        },
    };
    const models = [_]@import("profile.zig").ModelEntry{.{
        .request_model_id = "warned-m1",
        .display_name = "Warned M1",
        .controls = &SPECS,
    }};
    try registry.register(.{
        .id = Slug.lit("warned"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Warned provider",
        .channels = &HOOKED_CHANNELS,
        .models = &models,
        .accepted_credential_kinds = &HOOKED_KINDS,
    });
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("warned") });
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    const offer = catalog.items()[0];
    var selection = RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .session);
    try selection.controls.set("reasoning_effort", try controls_mod.Value.fromText("high"));
    try selection.controls.set("service_tier", try controls_mod.Value.fromText("priority"));

    const outcome = kernel.selectionValidate(selection);
    try std.testing.expect(outcome == .ok);
    // The provider declared both; the kernel carries them to the client rather
    // than discarding them.
    try std.testing.expect(outcome.ok.requires_confirmation);
    try std.testing.expectEqual(@as(u8, 1), outcome.ok.warnings_len);
    try std.testing.expectEqualStrings(
        "higher effort costs more and responds slower",
        outcome.ok.warningsSlice()[0],
    );
}

test "an incompatible api version is refused instead of answered" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    var buffer: std.ArrayList(OfferSummary) = .empty;
    defer buffer.deinit(a);
    try std.testing.expectError(error.UnsupportedApiVersion, kernel.modelList(
        .{ .api_version = API_VERSION + 1 },
        .{},
        a,
        &buffer,
    ));
    try std.testing.expectError(error.UnsupportedApiVersion, kernel.modelList(
        .{ .schema_version = SCHEMA_VERSION + 1 },
        .{},
        a,
        &buffer,
    ));
    // An older schema is still answerable.
    _ = try kernel.modelList(.{}, .{}, a, &buffer);
}

test "adopting a refreshed catalog announces it and re-points reads" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var first = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("metask") });
    defer first.deinit();
    var second = try registry.buildCatalog(a, .{
        .only_provider = Slug.lit("zai-coding-plan"),
        .revision = CatalogRevision.initial.next(),
    });
    defer second.deinit();

    var kernel = Kernel.init(a, &first);
    defer kernel.deinit();
    var buffer: std.ArrayList(OfferSummary) = .empty;
    defer buffer.deinit(a);
    const before = try kernel.modelList(.{}, .{}, a, &buffer);
    try std.testing.expectEqual(first.items().len, before.total);

    kernel.adoptCatalog(&second);
    const after = try kernel.modelList(.{}, .{}, a, &buffer);
    try std.testing.expectEqual(second.items().len, after.total);
    try std.testing.expectEqual(second.revision, after.meta.catalog_revision);

    const last = kernel.journal.items()[kernel.journal.len - 1];
    try std.testing.expectEqual(EventType.catalog_updated, last.event_type);
    try std.testing.expectEqual(
        @as(u32, @intCast(second.items().len)),
        last.payload.catalog_updated.offer_count,
    );
}

test "selection.resolve reports the effective selection and names cleared controls" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try buildCatalog(a, &registry);
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();

    // Nothing selected yet.
    try std.testing.expect(kernel.selectionResolve() == null);

    const offer = catalog.items()[0];
    _ = kernel.selectionCommit(
        .{},
        RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .session),
        .session,
    );
    const resolved = kernel.selectionResolve().?;
    try std.testing.expect(resolved == .ok);
    try std.testing.expect(resolved.ok.offer_id.eql(offer.offer_id));

    // The lenient path names what a switch would drop, not just how many.
    var stray = RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .session);
    try stray.controls.set("nonexistent_knob", .{ .number = 1 });
    const rebased = kernel.rebaseSelection(stray);
    try std.testing.expectEqual(@as(u8, 1), rebased.ok.cleared_controls);
    try std.testing.expect(rebased.ok.clearedSlice()[0].eqlText("nonexistent_knob"));
}

test "a recorded route carries the cost its provider quote implies" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    try registry.register(.{
        .id = Slug.lit("priced-route"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Priced route",
        .channels = &HOOKED_CHANNELS,
        .models = &HOOKED_MODELS,
        .accepted_credential_kinds = &HOOKED_KINDS,
        .quote_hook = hookedQuote,
    });
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("priced-route") });
    defer catalog.deinit();
    var kernel = Kernel.init(a, &catalog);
    kernel.registry = &registry;
    defer kernel.deinit();

    const offer = catalog.items()[0];
    kernel.recordActualRoute(.{
        .requested = .{ .pinned = offer.offer_id },
        .actual_offer_id = offer.offer_id,
        .actual_offer_revision = offer.offer_revision,
        .provider_id = offer.provider_id,
        .channel_id = offer.channel_id,
        .protocol = offer.protocol,
        .usage = .{ .input_tokens = 1_000_000, .output_tokens = 1_000_000 },
    });
    const recorded = kernel.journal.items()[kernel.journal.len - 1];
    try std.testing.expectEqual(@as(?u64, 18_000_000), recorded.payload.route_actual.cost_micros);

    // A caller that priced the turn itself is not overwritten.
    kernel.recordActualRoute(.{
        .requested = .{ .pinned = offer.offer_id },
        .actual_offer_id = offer.offer_id,
        .actual_offer_revision = offer.offer_revision,
        .provider_id = offer.provider_id,
        .channel_id = offer.channel_id,
        .protocol = offer.protocol,
        .usage = .{ .input_tokens = 1_000_000 },
        .cost_micros = 42,
    });
    const explicit = kernel.journal.items()[kernel.journal.len - 1];
    try std.testing.expectEqual(@as(?u64, 42), explicit.payload.route_actual.cost_micros);
}

test "a built-in price reaches model.list and quote.estimate, and unknown stays unknown" {
    const a = std.testing.allocator;
    var registry = try registry_mod.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{});
    defer catalog.deinit();

    var kernel = Kernel.init(a, &catalog);
    defer kernel.deinit();
    kernel.registry = &registry;

    var page: std.ArrayList(OfferSummary) = .empty;
    defer page.deinit(a);
    const listed = try kernel.modelList(.{}, .{}, a, &page);

    var priced: usize = 0;
    var unpriced: usize = 0;
    for (listed.offers) |summary| {
        if (summary.quote.isKnown()) {
            priced += 1;
            // A price a client can render must carry its currency and unit;
            // a bare number is not comparable across providers.
            const value = summary.quote.priced().?;
            try std.testing.expectEqual(offer_mod.BillingUnit.per_million_tokens, value.billing_unit);
            try std.testing.expect(value.input_price_micros != null);
        } else {
            unpriced += 1;
        }
    }
    // Both halves must exist: a provider that prices, and one that says it
    // cannot. A run where everything is unknown would pass a weaker assertion.
    try std.testing.expect(priced > 0);
    try std.testing.expect(unpriced > 0);

    for (listed.offers) |summary| {
        const estimate = kernel.quoteEstimate(summary.offer_id, .{
            .input_tokens = 1_000_000,
            .output_tokens = 1_000_000,
        });
        try std.testing.expectEqual(summary.quote.isKnown(), estimate.isKnown());
    }
}
