//! Cross-UI model picker (issue #16; one screen since the follow-up to #527).
//!
//! Pure state over a control-plane snapshot. This module touches no fd, no
//! terminal, no environment, and no provider client: it reads a snapshot the
//! host took from the kernel and emits a `Commit` the host applies *through*
//! the kernel. That boundary is the point — a picker that resolved routes
//! itself would be a second place identity is decided, and the two would drift.
//!
//! One screen, models first:
//!
//! ```text
//!   Model                                  apply to  [this session]  from now on  this turn   tab
//!   Metask · signed in · billed to your Metask account
//!   >* glm-5.3-flash                    200K
//!      glm-5.3                          200K   2 routes
//!   DeepSeek · key from .env · billed to your DeepSeek account
//!      DeepSeek V4 Pro                    1M   2 routes
//!   Reasoning effort   default  low  medium  [high]  max          ←/→
//! ```
//!
//! - A row per model, grouped by *canonical id*, never by visible name: two
//!   channels serving "GLM-4.6" over different protocols, regions, or prices
//!   are different routes, and collapsing them by display name would hide the
//!   choice this whole model exists to give. The providers are headings (the
//!   one in use first), each saying where its credential comes from and who
//!   bills it, filtered or not.
//! - A model served on several routes shows them under it while the cursor is
//!   on it. Enter on the model takes its preferred route (the one in use, else
//!   the first in catalog order); Enter on a route takes that route.
//! - The controls the focused route declares (in practice the reasoning
//!   effort) are a line under the list, changed with ←/→ from any row. The
//!   value is remembered as the one wanted, and each model shows and commits
//!   the nearest value its vocabulary has, so moving the cursor never drops it.
//!   With nothing wanted, a control that declares its provider's default
//!   (DeepSeek's reasoning effort: `high`) shows and commits that value, and
//!   has no unnamed default before it.
//! - Every route the list offers can be applied as it is (#488). The host
//!   says, per offer, whether a commit would find a credential for it now
//!   (`setReadiness`); a provider with none of its offers ready is not
//!   listed, and a filter does not find its models. A commit that finds the
//!   credential gone since the list was drawn shows where it goes
//!   (`Stage.setup`) and nothing else: no sign-in, no key field, no request.

const std = @import("std");
const control_plane = @import("../provider/control_plane.zig");
const offer_mod = @import("../provider/offer.zig");
const controls_mod = @import("../provider/controls.zig");
const selection_mod = @import("../provider/selection.zig");
const ids = @import("../provider/ids.zig");

pub const OfferSummary = control_plane.OfferSummary;
pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const Scope = selection_mod.Scope;

pub const MAX_FILTER: usize = 64;
/// Canonical grouping keys are model ids, which are short; a longer one is
/// truncated for grouping only and never for routing.
pub const MAX_GROUP_KEY: usize = 128;
/// Room for this install's `<state root>/.env`, as the setup stage shows it.
pub const MAX_LOCAL_CONFIG_PATH: usize = 1024;
/// Room for a provider's display name in its heading.
pub const MAX_PROVIDER_NAME: usize = 64;

pub const Stage = enum {
    /// Every configured provider's models, on one screen.
    list,
    /// Where the provider of a route gets its credential, after a commit
    /// found none for it (#488).
    setup,
};

/// Where a provider gets its credential, as the setup stage shows it (#488).
/// The host derives it from the provider's profile.
pub const Setup = struct {
    provider: Slug,
    /// The variable its key is read from (the canonical alias, else the
    /// first), borrowed from the provider registry. Null: it declares none.
    variable: ?[]const u8 = null,
    /// Signing in with `/login` is the way in (Metask).
    sign_in: bool = false,
};

/// What a provider's heading says, as the host found it when it judged the
/// offers ready: the provider's name and where the credential a commit would
/// use comes from. Copied: a catalog refresh may free what it was read from.
pub const ProviderNote = struct {
    provider: Slug,
    name_buffer: [MAX_PROVIDER_NAME]u8 = undefined,
    name_len: usize = 0,
    origin: Origin = .unknown,

    pub const Origin = enum {
        unknown,
        /// The provider's own sign-in (the Metask session, a provider OAuth).
        signed_in,
        /// A key signed in by other means (`METASK_API_KEY`, a key in
        /// `auth.json`).
        key,
        /// `<state root>/.env`.
        local_config,
        /// A variable exported in the shell.
        environment,
        /// A key `/login <provider>` stored.
        saved_key,
        /// `--api-key`.
        flag,
    };

    pub fn init(provider: Slug, display_name: []const u8, origin: Origin) ProviderNote {
        var note = ProviderNote{ .provider = provider, .origin = origin };
        const len = @min(display_name.len, MAX_PROVIDER_NAME);
        @memcpy(note.name_buffer[0..len], display_name[0..len]);
        note.name_len = len;
        return note;
    }

    pub fn name(self: *const ProviderNote) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// The heading's words for where the credential comes from; null when
    /// the host could not tell.
    pub fn originText(self: ProviderNote) ?[]const u8 {
        return switch (self.origin) {
            .unknown => null,
            .signed_in => "signed in",
            .key => "key",
            .local_config => "key from .env",
            .environment => "key from shell",
            .saved_key => "saved key",
            .flag => "--api-key",
        };
    }
};

/// What the list is showing right now. `stale` and `failed` are states a client
/// must be able to render: a picker that silently shows an out-of-date catalog
/// invites committing to a route that no longer exists.
pub const Status = enum { loading, ready, empty, stale, failed };

pub const Group = struct {
    /// A representative offer for the row: for a model, its preferred route
    /// (the one Enter applies). Detail the renderer needs (limits, price,
    /// protocol) is read from the snapshot through this index.
    offer_index: usize,
    /// How many offers this row stands for: the model's routes.
    offer_count: usize,
    label: []const u8,
    /// True when the committed selection is one of the offers behind this row.
    is_current: bool,
};

pub const Row = union(enum) {
    /// A provider heading. The cursor never rests on it.
    heading: struct { offer_index: usize },
    model: Group,
    /// One route of the model above it, listed while the cursor is on that
    /// model or one of its routes.
    route: struct { offer_index: usize, is_current: bool, preferred: bool, last: bool },

    pub fn focusable(self: Row) bool {
        return self != .heading;
    }
};

pub const Commit = struct {
    offer_id: OfferId,
    offer_revision: ids.OfferRevision,
    controls: controls_mod.ControlValues,
    scope: Scope,
};

pub const Outcome = union(enum) {
    /// State changed; the host redraws.
    redraw,
    /// Nothing changed; the host may skip the redraw.
    ignored,
    closed,
    commit: Commit,
};

pub const Key = union(enum) {
    up,
    down,
    page_up,
    page_down,
    /// First and last row of the list.
    home,
    end,
    /// The previous / next value of the focused route's first control (the
    /// reasoning effort).
    left,
    right,
    enter,
    /// Clears the filter, then walks back a step, then closes.
    escape,
    backspace,
    /// Cycles session → global → once. Session is the default, so any other
    /// scope is always an explicit act.
    cycle_scope,
    char: u8,
};

/// Which row the cursor is on, by identity rather than position: listing a
/// model's routes under it moves the rows below, and a refresh can reorder
/// them, but the cursor stays on the same model or route.
const RowId = struct {
    kind: Kind = .none,
    provider: ?Slug = null,
    key_buffer: [MAX_GROUP_KEY]u8 = undefined,
    key_len: usize = 0,
    offer: ?OfferId = null,

    const Kind = enum { none, model, route };

    fn key(self: *const RowId) []const u8 {
        return self.key_buffer[0..self.key_len];
    }

    fn eql(self: *const RowId, other: *const RowId) bool {
        if (self.kind != other.kind) return false;
        return switch (self.kind) {
            .none => true,
            .model => sameSlug(self.provider, other.provider) and std.mem.eql(u8, self.key(), other.key()),
            .route => if (self.offer) |mine| (if (other.offer) |theirs| mine.eql(theirs) else false) else false,
        };
    }
};

fn sameSlug(a: ?Slug, b: ?Slug) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return left.eql(right);
}

pub const Picker = struct {
    allocator: std.mem.Allocator,
    offers: std.ArrayList(OfferSummary) = .empty,
    status: Status = .loading,
    /// Revisions the snapshot was taken at. A later kernel revision makes the
    /// snapshot `stale` rather than silently wrong.
    catalog_revision: ids.CatalogRevision = .initial,
    config_revision: ids.ConfigRevision = .initial,
    current_offer: ?OfferId = null,

    stage: Stage = .list,
    filter_buffer: [MAX_FILTER]u8 = undefined,
    filter_len: usize = 0,
    cursor: usize = 0,
    window_top: usize = 0,
    page_rows: usize = 10,

    /// Feedback from the last commit attempt: one line, or a few separated by
    /// '\n' when it names a variable, a path and a link (#483). Bounded and
    /// owned by the picker so the host never has to keep a matching
    /// allocation alive.
    notice_buffer: [512]u8 = undefined,
    notice_len: usize = 0,

    /// Per offer of `offers`: a commit could bind it now (#488). An offer past
    /// its end counts as ready, so a snapshot no verdict came with hides
    /// nothing (`adopt` empties it; `setReadiness` fills it).
    ready: std.ArrayList(bool) = .empty,
    /// What each configured provider's heading says.
    notes: std.ArrayList(ProviderNote) = .empty,
    /// What the setup stage shows.
    setup: ?Setup = null,
    /// Where Esc leaves the setup stage for: the row of the list it was
    /// opened from.
    setup_return_row: RowId = .{},
    /// This install's `<state root>/.env` and the guide to it, for the setup
    /// stage and for a list no provider is configured for; the host sets
    /// both when it opens the picker.
    local_config_path_buffer: [MAX_LOCAL_CONFIG_PATH]u8 = undefined,
    local_config_path_len: usize = 0,
    guide_url: []const u8 = "",

    /// The model whose routes are listed under it: the one the cursor is on.
    expanded_provider: ?Slug = null,
    expanded_key_buffer: [MAX_GROUP_KEY]u8 = undefined,
    expanded_key_len: usize = 0,
    /// Set when the picker is (re)opened: the cursor goes to the model in use
    /// as soon as there is a snapshot to find it in.
    focus_current: bool = true,

    /// The control values wanted, by control id (`reasoning_effort`): what
    /// the session already runs with (`presetControl`), then whatever ←/→
    /// chose. Each route shows and commits the nearest value it takes
    /// (`effectiveValue`), so a model with fewer levels never drops the
    /// choice for the next one.
    intents: controls_mod.ControlValues = .{},
    scope: Scope = .session,

    pub fn init(allocator: std.mem.Allocator) Picker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Picker) void {
        self.offers.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.notes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn filter(self: *const Picker) []const u8 {
        return self.filter_buffer[0..self.filter_len];
    }

    pub fn notice(self: *const Picker) []const u8 {
        return self.notice_buffer[0..self.notice_len];
    }

    pub fn setNotice(self: *Picker, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.notice_buffer, fmt, args) catch {
            // A truncated notice still beats none: the user needs to know the
            // commit did not land.
            self.notice_len = self.notice_buffer.len;
            return;
        };
        self.notice_len = written.len;
    }

    pub fn clearNotice(self: *Picker) void {
        self.notice_len = 0;
    }

    fn expandedKey(self: *const Picker) []const u8 {
        return self.expanded_key_buffer[0..self.expanded_key_len];
    }

    /// Replace the snapshot. The host calls this on open and whenever the
    /// kernel reports a newer catalog, which is what turns a stale list back
    /// into a live one instead of leaving the user staring at old routes.
    pub fn adopt(
        self: *Picker,
        page: control_plane.ListPage,
        current_offer: ?OfferId,
    ) error{OutOfMemory}!void {
        const keep = self.cursorRow();
        self.offers.clearRetainingCapacity();
        try self.offers.appendSlice(self.allocator, page.offers);
        // The verdicts were about the previous snapshot.
        self.ready.clearRetainingCapacity();
        self.notes.clearRetainingCapacity();
        self.catalog_revision = page.meta.catalog_revision;
        self.config_revision = page.meta.config_revision;
        self.current_offer = current_offer;
        self.status = if (self.offers.items.len == 0) .empty else .ready;
        self.refocus(keep);
    }

    /// Which offers of the snapshot a commit could bind now (`ready`, in
    /// snapshot order; the others are not listed, #488), and what each
    /// configured provider's heading says. The host calls it right after
    /// `adopt`, under the same lock.
    pub fn setReadiness(
        self: *Picker,
        ready: []const bool,
        notes: []const ProviderNote,
    ) error{OutOfMemory}!void {
        const keep = self.cursorRow();
        self.ready.clearRetainingCapacity();
        self.notes.clearRetainingCapacity();
        try self.ready.appendSlice(self.allocator, ready[0..@min(ready.len, self.offers.items.len)]);
        try self.notes.appendSlice(self.allocator, notes);
        self.refocus(keep);
    }

    /// Whether a commit could bind the offer at `index` now.
    pub fn isReady(self: *const Picker, index: usize) bool {
        return index >= self.ready.items.len or self.ready.items[index];
    }

    /// What `provider`'s heading says, as the host described it; null when
    /// it said nothing.
    pub fn noteFor(self: *const Picker, provider: Slug) ?*const ProviderNote {
        for (self.notes.items) |*entry| {
            if (entry.provider.eql(provider)) return entry;
        }
        return null;
    }

    /// This install's `<state root>/.env` (copied, cut at
    /// `MAX_LOCAL_CONFIG_PATH`) and the guide to it (borrowed; a static
    /// string), for the setup stage and for a list no provider is
    /// configured for.
    pub fn setLocalConfig(self: *Picker, path: []const u8, guide: []const u8) void {
        const len = @min(path.len, MAX_LOCAL_CONFIG_PATH);
        @memcpy(self.local_config_path_buffer[0..len], path[0..len]);
        self.local_config_path_len = len;
        self.guide_url = guide;
    }

    pub fn localConfigPath(self: *const Picker) []const u8 {
        return self.local_config_path_buffer[0..self.local_config_path_len];
    }

    /// Show where `setup.provider` gets its credential in place of the list,
    /// after a commit the host found no credential for: the list showed the
    /// route, so the credential went away since (#483, #488). Esc goes back
    /// to where the user was, filter and row included.
    pub fn enterSetup(self: *Picker, setup: Setup) void {
        if (self.stage != .setup) self.setup_return_row = self.cursorRow();
        self.setup = setup;
        self.stage = .setup;
    }

    fn leaveSetup(self: *Picker) void {
        self.stage = .list;
        self.setup = null;
        self.notice_len = 0;
        // A refresh while the setup was shown may have taken the row away.
        self.refocus(self.setup_return_row);
    }

    /// Mark the snapshot out of date without discarding it: the user keeps
    /// seeing something while the refresh runs, and the footer says it is old.
    pub fn markStale(self: *Picker) void {
        if (self.status == .ready) self.status = .stale;
    }

    pub fn markFailed(self: *Picker) void {
        self.status = .failed;
    }

    /// Back to the top of the list, keeping the snapshot, with the cursor on
    /// the model in use. Used when the picker is reopened: an abandoned
    /// browse should not come back.
    pub fn restart(self: *Picker) void {
        self.notice_len = 0;
        self.stage = .list;
        self.filter_len = 0;
        self.cursor = 0;
        self.window_top = 0;
        self.collapse();
        self.intents = .{};
        self.scope = .session;
        self.setup = null;
        self.setup_return_row = .{};
        self.focus_current = true;
        self.refocus(.{});
    }

    /// Record a value the session runs with, as the value wanted: every
    /// route starts at it, or at the nearest value it takes. Ignored when it
    /// does not fit.
    pub fn presetControl(self: *Picker, id: []const u8, text: []const u8) void {
        const value = controls_mod.Value.fromText(text) catch return;
        self.intents.set(id, value) catch {};
    }

    /// Open on `text` as if the user had typed it, with the cursor on the
    /// first model it shows (a sign-in whose account has no credits opens on
    /// `:free`). Call after `restart`, with the snapshot in place.
    pub fn presetFilter(self: *Picker, text: []const u8) void {
        const n = @min(text.len, MAX_FILTER);
        @memcpy(self.filter_buffer[0..n], text[0..n]);
        self.filter_len = n;
        self.focusFirst();
    }

    /// Open applying `scope` (Tab still cycles it): a sign-in that goes on to
    /// choosing a model applies it `from now on`, as `/login` does for Metask.
    pub fn presetScope(self: *Picker, scope: Scope) void {
        self.scope = scope;
    }

    // ── row construction ────────────────────────────────────────────────────

    /// Storage for the rows, owned by the caller and sized by the catalog.
    /// There is deliberately no fixed capacity: a list capped at a constant
    /// silently dropped every model past it (a gateway listing 300 models
    /// showed `[1/256]`, and the last 44 could not be reached).
    pub const RowBuffer = struct {
        gpa: std.mem.Allocator,
        list: std.ArrayList(Row) = .empty,

        pub fn init(gpa: std.mem.Allocator) RowBuffer {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *RowBuffer) void {
            self.list.deinit(self.gpa);
            self.* = undefined;
        }
    };

    /// The rows of the current stage, rebuilt into `buffer` (its previous rows
    /// are dropped). Rows are recomputed rather than cached: the filter changes
    /// them on every keystroke, and a cache that missed one keystroke would
    /// highlight a row the user is not looking at.
    pub fn rows(self: *const Picker, buffer: *RowBuffer) error{OutOfMemory}![]const Row {
        buffer.list.clearRetainingCapacity();
        switch (self.stage) {
            .list => {
                var providers: std.ArrayList(usize) = .empty;
                defer providers.deinit(buffer.gpa);
                try self.readyProviders(buffer.gpa, &providers);
                if (self.filter_len == 0) {
                    for (providers.items) |first| {
                        const start = buffer.list.items.len;
                        try buffer.list.append(buffer.gpa, .{ .heading = .{ .offer_index = first } });
                        try self.modelRows(buffer, self.offers.items[first].provider_id, null);
                        // A heading over no model is dropped with it.
                        if (buffer.list.items.len == start + 1) buffer.list.shrinkRetainingCapacity(start);
                    }
                } else {
                    // Across the configured providers, each under its
                    // heading: someone looking for GLM should not have to
                    // know it lives behind `zai-coding-plan`. The providers
                    // with a model that holds the typed text whole come
                    // first, the ones whose models only hold its letters in
                    // order after them, and so do the models within each:
                    // `glm` lists GLM-5.3 before `google/gemini-…`.
                    // Otherwise in the list's order.
                    for ([_]Match{ .whole, .scattered }) |best| {
                        for (providers.items) |first| {
                            const provider = self.offers.items[first].provider_id;
                            const match = self.providerMatch(provider) orelse continue;
                            if (match != best) continue;
                            const start = buffer.list.items.len;
                            try buffer.list.append(buffer.gpa, .{ .heading = .{ .offer_index = first } });
                            try self.modelRows(buffer, provider, .whole);
                            try self.modelRows(buffer, provider, .scattered);
                            if (buffer.list.items.len == start + 1) buffer.list.shrinkRetainingCapacity(start);
                        }
                    }
                }
            },
            .setup => {},
        }
        return buffer.list.items;
    }

    /// Row count of the current stage; 0 when the rows cannot be built.
    pub fn rowCount(self: *const Picker) usize {
        var buffer = RowBuffer.init(self.allocator);
        defer buffer.deinit();
        return (self.rows(&buffer) catch return 0).len;
    }

    /// The first offer of each provider a commit can use, the provider in use
    /// first and the rest in catalog order.
    fn readyProviders(self: *const Picker, gpa: std.mem.Allocator, out: *std.ArrayList(usize)) error{OutOfMemory}!void {
        for (self.offers.items, 0..) |offer, index| {
            if (!self.isReady(index)) continue;
            const seen = for (out.items) |first| {
                if (self.offers.items[first].provider_id.eql(offer.provider_id)) break true;
            } else false;
            if (!seen) try out.append(gpa, index);
        }
        const current = self.currentIndex() orelse return;
        const provider = self.offers.items[current].provider_id;
        for (out.items, 0..) |first, position| {
            if (!self.offers.items[first].provider_id.eql(provider)) continue;
            std.mem.rotate(usize, out.items[0 .. position + 1], position);
            return;
        }
    }

    /// The ready models of `provider` that match the filter, a row each in
    /// catalog order. With a `tier`, only the models the filter matches that
    /// well. The routes of the expanded model follow it.
    fn modelRows(self: *const Picker, buffer: *RowBuffer, provider: Slug, tier: ?Match) error{OutOfMemory}!void {
        const start = buffer.list.items.len;
        // By pointer: the label of a model row is read from the offer, and a
        // by-value capture would leave it pointing into the loop variable.
        for (self.offers.items, 0..) |*offer, index| {
            if (!offer.provider_id.eql(provider)) continue;
            if (!self.isReady(index)) continue;
            if (!self.matchesOffer(offer)) continue;
            const key = canonicalKey(offer.*);
            if (tier) |wanted| if (self.modelMatch(provider, key) != wanted) continue;
            const current = self.isCurrent(offer.*);
            if (findModel(buffer.list.items[start..], key)) |existing| {
                const group = &buffer.list.items[start + existing].model;
                group.offer_count += 1;
                // The route in use is the one Enter keeps.
                if (current and !group.is_current) group.offer_index = index;
                group.is_current = group.is_current or current;
                continue;
            }
            try buffer.list.append(buffer.gpa, .{ .model = .{
                .offer_index = index,
                .offer_count = 1,
                .label = key,
                .is_current = current,
            } });
        }
        const expanded = self.expanded_provider orelse return;
        if (!expanded.eql(provider)) return;
        const at = findModel(buffer.list.items[start..], self.expandedKey()) orelse return;
        const group = buffer.list.items[start + at].model;
        if (group.offer_count < 2) return;
        var insert_at = start + at + 1;
        var listed: usize = 0;
        for (self.offers.items, 0..) |offer, index| {
            if (!offer.provider_id.eql(provider) or !self.isReady(index)) continue;
            if (!std.mem.eql(u8, canonicalKey(offer), group.label)) continue;
            listed += 1;
            try buffer.list.insert(buffer.gpa, insert_at, .{ .route = .{
                .offer_index = index,
                .is_current = self.isCurrent(offer),
                .preferred = index == group.offer_index,
                .last = listed == group.offer_count,
            } });
            insert_at += 1;
        }
    }

    /// How the filter matches the model `key` of `provider`: `.whole` when
    /// one of its routes holds the typed text whole (case aside) in its name,
    /// its canonical id, its request id or its provider's id, else
    /// `.scattered`. Per model rather than per route, so a model is listed
    /// once whatever its routes' request ids hold.
    fn modelMatch(self: *const Picker, provider: Slug, key: []const u8) Match {
        const needle = self.filter();
        for (self.offers.items) |*offer| {
            if (!offer.provider_id.eql(provider)) continue;
            if (!std.mem.eql(u8, canonicalKey(offer.*), key)) continue;
            if (holds(offer.display_name, needle) or holds(key, needle) or
                holds(offer.request_model_id, needle) or holds(offer.provider_id.slice(), needle)) return .whole;
        }
        return .scattered;
    }

    fn providerMatch(self: *const Picker, provider: Slug) ?Match {
        var best: ?Match = null;
        for (self.offers.items, 0..) |*offer, index| {
            if (!offer.provider_id.eql(provider) or !self.isReady(index)) continue;
            if (!self.matchesOffer(offer)) continue;
            if (self.modelMatch(provider, canonicalKey(offer.*)) == .whole) return .whole;
            best = .scattered;
        }
        return best;
    }

    fn matchesOffer(self: *const Picker, offer: *const OfferSummary) bool {
        const needle = self.filter();
        return matches(needle, offer.display_name) or
            matches(needle, canonicalKey(offer.*)) or
            matches(needle, offer.request_model_id) or
            matches(needle, offer.provider_id.slice());
    }

    fn currentIndex(self: *const Picker) ?usize {
        const current = self.current_offer orelse return null;
        for (self.offers.items, 0..) |offer, index| {
            if (offer.offer_id.eql(current) and self.isReady(index)) return index;
        }
        return null;
    }

    fn isCurrent(self: *const Picker, offer: OfferSummary) bool {
        const current = self.current_offer orelse return false;
        return current.eql(offer.offer_id);
    }

    // ── focus ───────────────────────────────────────────────────────────────

    fn idOf(self: *const Picker, row: Row) RowId {
        var id = RowId{};
        switch (row) {
            .heading => {},
            .model => |group| {
                id.kind = .model;
                id.provider = self.offers.items[group.offer_index].provider_id;
                const len = @min(group.label.len, MAX_GROUP_KEY);
                @memcpy(id.key_buffer[0..len], group.label[0..len]);
                id.key_len = len;
            },
            .route => |route| {
                id.kind = .route;
                id.offer = self.offers.items[route.offer_index].offer_id;
            },
        }
        return id;
    }

    /// The row the cursor is on, by identity; `.none` when there is none.
    fn cursorRow(self: *const Picker) RowId {
        if (self.stage == .setup) return self.setup_return_row;
        var buffer = RowBuffer.init(self.allocator);
        defer buffer.deinit();
        const list = self.rows(&buffer) catch return .{};
        if (list.len == 0) return .{};
        return self.idOf(list[@min(self.cursor, list.len - 1)]);
    }

    fn collapse(self: *Picker) void {
        self.expanded_provider = null;
        self.expanded_key_len = 0;
    }

    /// Put the cursor on the row `id` names: a model lists its routes, a
    /// route keeps its model's listed, anything else lists none. A row that
    /// is gone leaves the cursor on the nearest row that can take it.
    fn focus(self: *Picker, id: RowId) void {
        switch (id.kind) {
            .model => {
                self.expanded_provider = id.provider;
                const key = id.key();
                @memcpy(self.expanded_key_buffer[0..key.len], key);
                self.expanded_key_len = key.len;
            },
            .route => {},
            else => self.collapse(),
        }
        var buffer = RowBuffer.init(self.allocator);
        defer buffer.deinit();
        const list = self.rows(&buffer) catch return;
        const at = for (list, 0..) |row, index| {
            // A heading is never a place to land, whatever it is compared to.
            if (!row.focusable()) continue;
            const candidate = self.idOf(row);
            if (candidate.eql(&id)) break index;
        } else null;
        const near = @min(self.cursor, list.len -| 1);
        self.cursor = at orelse focusableNear(list, near, false) orelse focusableNear(list, near, true) orelse 0;
        if (at == null and list.len > 0) {
            // The expansion followed a row that is gone: follow the one the
            // cursor landed on instead.
            const landed = self.idOf(list[self.cursor]);
            if (landed.kind != id.kind or landed.kind == .model) return self.focus(landed);
        }
        self.scrollTo(list);
    }

    /// After a new snapshot or verdicts: the model in use when the picker was
    /// just opened, else the row the cursor was on.
    fn refocus(self: *Picker, keep: RowId) void {
        if (self.stage == .setup) return;
        if (self.focus_current) {
            if (self.currentIndex()) |current| {
                const offer = self.offers.items[current];
                var id = RowId{ .kind = .model, .provider = offer.provider_id };
                const key = canonicalKey(offer);
                const len = @min(key.len, MAX_GROUP_KEY);
                @memcpy(id.key_buffer[0..len], key[0..len]);
                id.key_len = len;
                self.focus_current = false;
                return self.focus(id);
            }
            // Nothing in use to find (yet): the first row will do until a
            // snapshot names one.
            if (self.offers.items.len > 0) self.focus_current = false;
        }
        if (keep.kind == .none) {
            var buffer = RowBuffer.init(self.allocator);
            defer buffer.deinit();
            const list = self.rows(&buffer) catch return;
            if (list.len == 0) {
                self.cursor = 0;
                self.window_top = 0;
                return;
            }
            const first = focusableNear(list, 0, true) orelse 0;
            self.cursor = first;
            return self.focus(self.idOf(list[first]));
        }
        self.focus(keep);
    }

    /// The offer the controls line describes and Enter applies: the route
    /// the cursor is on, or the preferred route of its model; null on a row
    /// that applies nothing.
    pub fn focusedOffer(self: *const Picker) ?*const OfferSummary {
        if (self.stage != .list) return null;
        var buffer = RowBuffer.init(self.allocator);
        defer buffer.deinit();
        const list = self.rows(&buffer) catch return null;
        if (list.len == 0) return null;
        return switch (list[@min(self.cursor, list.len - 1)]) {
            .model => |group| &self.offers.items[group.offer_index],
            .route => |route| &self.offers.items[route.offer_index],
            .heading => null,
        };
    }

    /// The value `spec` takes on the focused route: the value wanted when the
    /// vocabulary has it; for the reasoning effort, the nearest level it has
    /// (`nearestLevel`). With nothing wanted, or nothing that fits, the
    /// default the provider declares (`declaredDefault`); null for unset, the
    /// provider's own default, unnamed.
    pub fn effectiveValue(self: *const Picker, spec: controls_mod.ControlSpec) ?[]const u8 {
        if (spec.kind != .enumeration or spec.allowed_values.len == 0) return null;
        return self.wantedValue(spec) orelse declaredDefault(spec);
    }

    /// The value wanted as `spec`'s vocabulary has it, or, for the reasoning
    /// effort, its nearest level; null when nothing is wanted or nothing fits.
    fn wantedValue(self: *const Picker, spec: controls_mod.ControlSpec) ?[]const u8 {
        const wanted = self.intents.get(spec.id) orelse return null;
        if (wanted != .text) return null;
        const text = wanted.text.slice();
        for (spec.allowed_values) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, text)) return candidate;
        }
        if (!std.mem.eql(u8, spec.id, "reasoning_effort")) return null;
        return nearestLevel(spec.allowed_values, text);
    }

    /// The value wanted, when the focused route shows another (the nearest
    /// its vocabulary has); null when it shows the one wanted.
    pub fn wantedInstead(self: *const Picker, spec: controls_mod.ControlSpec) ?[]const u8 {
        const wanted = self.intents.get(spec.id) orelse return null;
        if (wanted != .text) return null;
        const shown = self.effectiveValue(spec) orelse return null;
        if (std.ascii.eqlIgnoreCase(shown, wanted.text.slice())) return null;
        // `xhigh` and `max` are one level under two names.
        const level = levelRank(wanted.text.slice()) orelse return null;
        if (levelRank(shown)) |shown_level| {
            if (topLevel(shown_level) and topLevel(level)) return null;
        }
        // The level's own name, not the text held in `wanted`: that is a copy
        // on this stack frame, gone when this returns.
        return LEVELS[level];
    }

    // ── key handling ────────────────────────────────────────────────────────

    pub fn onKey(self: *Picker, key: Key) Outcome {
        // The setup stage has no list: Esc goes back, q closes, and nothing
        // else does anything — it starts no sign-in and takes no key (#488).
        if (self.stage == .setup) return switch (key) {
            .escape => self.back(),
            .char => |byte| if (byte == 'q') .closed else .ignored,
            else => .ignored,
        };
        var buffer = RowBuffer.init(self.allocator);
        defer buffer.deinit();
        // Without its rows a key cannot be interpreted; nothing changes.
        const visible = self.rows(&buffer) catch return .ignored;
        switch (key) {
            .up => return self.move(visible, false),
            .down => return self.move(visible, true),
            .page_up => return self.pageMove(visible, false),
            .page_down => return self.pageMove(visible, true),
            .home => return self.jump(visible, false),
            .end => return self.jump(visible, true),
            .left, .right => return self.adjust(key == .right),
            .cycle_scope => {
                self.scope = switch (self.scope) {
                    .session => .global,
                    .global => .once,
                    .once => .session,
                };
                return .redraw;
            },
            .backspace => {
                if (self.filter_len == 0) return .ignored;
                self.filter_len -= 1;
                self.focusFirst();
                return .redraw;
            },
            .escape => return self.back(),
            .char => |byte| {
                // `q` closes only on an empty filter, so it stays typeable in a
                // model name. Same rule the `?` help key already uses.
                if (byte == 'q' and self.filter_len == 0) return .closed;
                if (byte < 0x20 or byte == 0x7f) return .ignored;
                if (self.filter_len == MAX_FILTER) return .ignored;
                self.filter_buffer[self.filter_len] = byte;
                self.filter_len += 1;
                self.focusFirst();
                return .redraw;
            },
            .enter => return self.advance(visible),
        }
    }

    fn focusFirst(self: *Picker) void {
        self.collapse();
        self.window_top = 0;
        var buffer = RowBuffer.init(self.allocator);
        defer buffer.deinit();
        const list = self.rows(&buffer) catch return;
        if (list.len == 0) {
            self.cursor = 0;
            return;
        }
        self.cursor = focusableNear(list, 0, true) orelse 0;
        self.focus(self.idOf(list[self.cursor]));
    }

    fn move(self: *Picker, visible: []const Row, down: bool) Outcome {
        const count = visible.len;
        if (count == 0) return .ignored;
        var index = @min(self.cursor, count - 1);
        var steps: usize = 0;
        while (steps < count) : (steps += 1) {
            index = if (down) (index + 1) % count else (if (index == 0) count - 1 else index - 1);
            if (visible[index].focusable()) break;
        } else return .ignored;
        self.cursor = index;
        self.focus(self.idOf(visible[index]));
        return .redraw;
    }

    fn pageMove(self: *Picker, visible: []const Row, down: bool) Outcome {
        const count = visible.len;
        if (count == 0) return .ignored;
        const step = @max(self.page_rows, 1);
        const target = if (down) @min(self.cursor + step, count - 1) else self.cursor -| step;
        const index = focusableNear(visible, target, !down) orelse focusableNear(visible, target, down) orelse return .ignored;
        self.cursor = index;
        self.focus(self.idOf(visible[index]));
        return .redraw;
    }

    fn jump(self: *Picker, visible: []const Row, to_end: bool) Outcome {
        const count = visible.len;
        if (count == 0) return .ignored;
        // Home from the top down (past the first heading), End from the bottom up.
        const index = focusableNear(visible, if (to_end) count - 1 else 0, to_end) orelse return .ignored;
        self.cursor = index;
        self.focus(self.idOf(visible[index]));
        if (to_end) {
            // The last model's routes are listed under it now: End means the
            // last row there is.
            var buffer = RowBuffer.init(self.allocator);
            defer buffer.deinit();
            const list = self.rows(&buffer) catch return .redraw;
            if (list.len > 0 and self.cursor < list.len - 1) {
                self.cursor = focusableNear(list, list.len - 1, false) orelse self.cursor;
                self.scrollTo(list);
            }
        }
        return .redraw;
    }

    /// Keep the cursor inside the visible window, scrolling by the minimum
    /// needed so a long list does not jump under the user, with a row above
    /// it once scrolled.
    fn scrollTo(self: *Picker, list: []const Row) void {
        const count = list.len;
        const rows_visible = @max(self.page_rows, 1);
        if (count <= rows_visible) {
            self.window_top = 0;
            return;
        }
        if (self.cursor < self.window_top) {
            self.window_top = self.cursor;
        } else if (self.cursor >= self.window_top + rows_visible) {
            self.window_top = self.cursor - rows_visible + 1;
        }
        if (self.window_top > 0 and self.window_top == self.cursor and rows_visible > 1) {
            self.window_top -= 1;
        }
        const max_top = count - rows_visible;
        if (self.window_top > max_top) self.window_top = max_top;
    }

    fn back(self: *Picker) Outcome {
        // The setup stage keeps the filter it was opened under: Esc returns to
        // that list, on the row it was opened from.
        if (self.stage == .setup) {
            self.leaveSetup();
            return .redraw;
        }
        if (self.filter_len > 0) {
            const keep = self.cursorRow();
            self.filter_len = 0;
            self.window_top = 0;
            self.focus(keep);
            return .redraw;
        }
        return .closed;
    }

    fn advance(self: *Picker, visible: []const Row) Outcome {
        if (visible.len == 0) return .ignored;
        return switch (visible[@min(self.cursor, visible.len - 1)]) {
            .heading => .ignored,
            .model, .route => self.commitNow(),
        };
    }

    /// ←/→: the previous / next value of the focused route's first control,
    /// from the one it shows. Unset (the provider's default) sits before the
    /// first value, unless the control declares its default: that default is
    /// then a value of the vocabulary, and nothing sits before the first. The
    /// ends do not wrap, like a slider. Nothing here invents a value: a
    /// control with no `allowed_values` cannot be changed here.
    fn adjust(self: *Picker, forward: bool) Outcome {
        const offer = self.focusedOffer() orelse return .ignored;
        const spec = firstEnumeration(offer.controls) orelse return .ignored;
        const shown = self.effectiveValue(spec);
        var position: ?usize = null;
        if (shown) |value| {
            for (spec.allowed_values, 0..) |candidate, index| {
                if (std.mem.eql(u8, candidate, value)) position = index;
            }
        }
        const last = spec.allowed_values.len - 1;
        const unset_first = declaredDefault(spec) == null;
        const next: ?usize = if (forward)
            (if (position) |at| @min(at + 1, last) else 0)
        else if (position) |at|
            (if (at > 0) at - 1 else if (unset_first) null else at)
        else
            null;
        if (next == null and position == null) return .ignored;
        if (next != null and position != null and next.? == position.?) return .ignored;
        if (next) |index| {
            const text = controls_mod.ControlText.parse(spec.allowed_values[index]) catch return .ignored;
            self.intents.set(spec.id, .{ .text = text }) catch return .ignored;
        } else {
            _ = self.intents.remove(spec.id);
        }
        return .redraw;
    }

    /// Commit the focused route with the values its controls show.
    pub fn commitNow(self: *Picker) Outcome {
        const offer = self.focusedOffer() orelse return .ignored;
        var values: controls_mod.ControlValues = .{};
        for (offer.controls) |spec| {
            const value = self.effectiveValue(spec) orelse continue;
            const text = controls_mod.ControlText.parse(value) catch continue;
            values.set(spec.id, .{ .text = text }) catch {};
        }
        return .{ .commit = .{
            .offer_id = offer.offer_id,
            .offer_revision = offer.offer_revision,
            .controls = values,
            .scope = self.scope,
        } };
    }
};

/// Grouping key. `canonical_model_id` when the provider declares one, otherwise
/// the request id — never the display name, which several distinct routes
/// legitimately share.
pub fn canonicalKey(offer: OfferSummary) []const u8 {
    return offer.canonical_model_id orelse offer.request_model_id;
}

fn findModel(existing: []const Row, key: []const u8) ?usize {
    for (existing, 0..) |row, index| {
        switch (row) {
            .model => |group| if (std.mem.eql(u8, group.label, key)) return index,
            else => {},
        }
    }
    return null;
}

/// The focusable row at `from`, else the nearest one before it (`backward`)
/// or after it.
fn focusableNear(list: []const Row, from: usize, backward: bool) ?usize {
    if (list.len == 0) return null;
    var index = @min(from, list.len - 1);
    while (true) {
        if (list[index].focusable()) return index;
        if (backward) {
            if (index == 0) return null;
            index -= 1;
        } else {
            if (index + 1 >= list.len) return null;
            index += 1;
        }
    }
}

/// The first control with a vocabulary the picker can walk.
pub fn firstEnumeration(specs: []const controls_mod.ControlSpec) ?controls_mod.ControlSpec {
    for (specs) |spec| {
        if (spec.kind == .enumeration and spec.allowed_values.len > 0) return spec;
    }
    return null;
}

/// The default `spec` declares for its provider, as its vocabulary spells
/// it; null when it declares none, or one the vocabulary lacks (a value the
/// picker could not show among the others, nor the kernel accept).
pub fn declaredDefault(spec: controls_mod.ControlSpec) ?[]const u8 {
    const declared = spec.default_value orelse return null;
    if (declared != .text) return null;
    for (spec.allowed_values) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, declared.text.slice())) return candidate;
    }
    return null;
}

/// The reasoning levels, in the order `types.ReasoningEffort` declares them.
/// The picker may not import `types.zig` (its import boundary is the provider
/// kernel, `scripts/subsystem_boundary_gate.zig`), so the order is kept here;
/// `levelRank` reads the same aliases `ReasoningEffort.parse` does.
const LEVELS = [_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh", "max" };

/// A level's place in `LEVELS`; null for a word that is not a level.
fn levelRank(text: []const u8) ?usize {
    if (std.ascii.eqlIgnoreCase(text, "off")) return 0;
    if (std.ascii.eqlIgnoreCase(text, "med")) return 3;
    for (LEVELS, 0..) |name, rank| {
        if (std.ascii.eqlIgnoreCase(text, name)) return rank;
    }
    return null;
}

/// `xhigh` and `max`.
fn topLevel(rank: usize) bool {
    return rank >= 5;
}

/// The reasoning level of `allowed` nearest to `wanted`, by `LEVELS`' order.
/// `xhigh` and `max` stand for each other: a route whose top level is called
/// "max" sends the neutral `xhigh` as `max` (`api/dialects/claude.zig`). A tie
/// goes to the lower level: a model that cannot think as hard as asked spends
/// less, not more. Null when nothing parses.
fn nearestLevel(allowed: []const []const u8, wanted_text: []const u8) ?[]const u8 {
    const wanted_rank = levelRank(wanted_text) orelse return null;
    if (topLevel(wanted_rank)) {
        for (allowed) |candidate| {
            const rank = levelRank(candidate) orelse continue;
            if (topLevel(rank)) return candidate;
        }
    }
    var best: ?[]const u8 = null;
    var best_rank: usize = 0;
    var best_distance: usize = std.math.maxInt(usize);
    for (allowed) |candidate| {
        const rank = levelRank(candidate) orelse continue;
        const distance = if (rank > wanted_rank) rank - wanted_rank else wanted_rank - rank;
        if (distance < best_distance or (distance == best_distance and rank < best_rank)) {
            best = candidate;
            best_rank = rank;
            best_distance = distance;
        }
    }
    return best;
}

/// Case-insensitive subsequence match: "g46" finds "GLM-4.6". An empty needle
/// matches everything, so an untouched filter never hides a route.
/// How well a typed filter matches a model (`Picker.modelMatch`).
const Match = enum { whole, scattered };

/// `needle` appears in `haystack` as it was typed, case aside.
fn holds(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

pub fn matches(needle: []const u8, haystack: []const u8) bool {
    if (needle.len == 0) return true;
    var cursor: usize = 0;
    for (haystack) |byte| {
        if (cursor == needle.len) break;
        if (std.ascii.toLower(byte) == std.ascii.toLower(needle[cursor])) cursor += 1;
    }
    return cursor == needle.len;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn fixtureOffer(
    provider: []const u8,
    channel: []const u8,
    display: []const u8,
    canonical: ?[]const u8,
    request: []const u8,
    protocol: []const u8,
) OfferSummary {
    const provider_id = Slug.parse(provider) catch unreachable;
    const channel_id = Slug.parse(channel) catch unreachable;
    return .{
        .offer_id = OfferId.derive(.{
            .provider_id = provider_id,
            .channel_id = channel_id,
            .protocol = protocol,
            .endpoint_url = "https://example.invalid",
            .request_model_id = request,
        }),
        .provider_id = provider_id,
        .channel_id = channel_id,
        .display_name = display,
        .request_model_id = request,
        .canonical_model_id = canonical,
        .upstream_model_id = null,
        .protocol = protocol,
        .endpoint_ref = "https://example.invalid",
        .credential_ref = null,
        .region = null,
        .plan = null,
        .limits = .{},
        .capabilities = .{},
        .quote = .unknown,
        .health = .{},
        .availability = .available,
        .controls = &.{},
        .offer_revision = 1,
    };
}

fn loadFixture(picker: *Picker, offers: []const OfferSummary, current: ?OfferId) !void {
    try picker.adopt(.{
        .meta = .{ .config_revision = .initial, .catalog_revision = .initial },
        .offers = offers,
        .total = offers.len,
        .truncated = false,
    }, current);
}

/// The rows as a test reads them: the kind of each, a letter apiece.
fn shape(picker: *const Picker, out: []u8) ![]const u8 {
    var buffer = Picker.RowBuffer.init(testing.allocator);
    defer buffer.deinit();
    const list = try picker.rows(&buffer);
    for (list, 0..) |row, index| out[index] = switch (row) {
        .heading => 'H',
        .model => 'M',
        .route => 'R',
    };
    return out[0..list.len];
}

fn rowAt(picker: *const Picker, buffer: *Picker.RowBuffer, index: usize) !Row {
    const list = try picker.rows(buffer);
    return list[index];
}

const REASONING = [_]controls_mod.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &.{ "low", "medium", "high", "max" },
}};
const REASONING_SHORT = [_]controls_mod.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &.{ "low", "high" },
}};

test "an empty catalog reports empty rather than looking ready" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    try testing.expectEqual(Status.loading, picker.status);
    try loadFixture(&picker, &.{}, null);
    try testing.expectEqual(Status.empty, picker.status);
    try testing.expectEqual(@as(usize, 0), picker.rowCount());
    // Enter on nothing must not commit a route that does not exist.
    try testing.expect(picker.onKey(.enter) == .ignored);
}

test "one screen: a heading per provider, a row per model, the cursor on the model in use" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("deepseek", "default", "DeepSeek V4 Pro", "deepseek/v4-pro", "deepseek-v4-pro", "openai_chat"),
        fixtureOffer("metask", "default", "glm-5.3", null, "glm-5.3", "anthropic_messages"),
        fixtureOffer("metask", "default", "glm-5.3-flash", null, "glm-5.3-flash", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, offers[2].offer_id);
    picker.restart();
    var letters: [16]u8 = undefined;
    // The provider in use first, then the others in catalog order.
    try testing.expectEqualStrings("HMMHM", try shape(&picker, &letters));
    var buffer = Picker.RowBuffer.init(testing.allocator);
    defer buffer.deinit();
    const first = try rowAt(&picker, &buffer, 0);
    try testing.expectEqualStrings("metask", picker.offers.items[first.heading.offer_index].provider_id.slice());
    // The cursor starts on the model in use, and Enter keeps it.
    try testing.expectEqual(@as(usize, 2), picker.cursor);
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome.commit.offer_id.eql(offers[2].offer_id));
    try testing.expectEqual(Scope.session, outcome.commit.scope);
}

test "offers sharing a visible name stay distinct routes, listed under their model while the cursor is on it" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("zai", "cn-anthropic", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "anthropic_messages"),
        fixtureOffer("zai", "cn-openai", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "openai_chat"),
        fixtureOffer("zai", "global-openai", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "openai_chat"),
        fixtureOffer("zai", "cn-openai", "GLM-4.5", "zai/glm-4.5", "glm-4.5", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    var letters: [16]u8 = undefined;
    // On the first model: one name, three routes, listed under it.
    try testing.expectEqualStrings("HMRRRM", try shape(&picker, &letters));
    var buffer = Picker.RowBuffer.init(testing.allocator);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 3), (try rowAt(&picker, &buffer, 1)).model.offer_count);
    try testing.expect((try rowAt(&picker, &buffer, 2)).route.preferred);
    try testing.expect((try rowAt(&picker, &buffer, 4)).route.last);
    // Down walks into the routes; Enter there takes that route.
    _ = picker.onKey(.down);
    _ = picker.onKey(.down);
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome.commit.offer_id.eql(offers[1].offer_id));
    // On the next model the routes of the first are put away.
    _ = picker.onKey(.down);
    _ = picker.onKey(.down);
    try testing.expectEqualStrings("HMM", try shape(&picker, &letters));
    try testing.expectEqual(@as(usize, 2), picker.cursor);
    // Up again lists them, the cursor on the model.
    _ = picker.onKey(.up);
    try testing.expectEqualStrings("HMRRRM", try shape(&picker, &letters));
    try testing.expectEqual(@as(usize, 1), picker.cursor);
}

test "Enter on a model with several routes takes the one in use, else the first" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("deepseek", "default", "DeepSeek V4 Pro", "deepseek/v4-pro", "deepseek-v4-pro", "openai_chat"),
        fixtureOffer("deepseek", "anthropic", "DeepSeek V4 Pro", "deepseek/v4-pro", "deepseek-v4-pro", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    try testing.expect(picker.onKey(.enter).commit.offer_id.eql(offers[0].offer_id));
    try loadFixture(&picker, &offers, offers[1].offer_id);
    picker.restart();
    try testing.expect(picker.onKey(.enter).commit.offer_id.eql(offers[1].offer_id));
}

test "providers whose ids have the same length stay separate headings" {
    // metask, openai and gemini are all six bytes: the compiled catalog once
    // showed one "metask 16 models" row, and the other two providers could
    // not be chosen at all.
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
        fixtureOffer("openai", "default", "GPT-4o", null, "gpt-4o", "openai_chat"),
        fixtureOffer("openai", "default", "o3", null, "o3", "openai_chat"),
        fixtureOffer("gemini", "default", "Gemini 2.5 Pro", null, "gemini-2.5-pro", "gemini_generate"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    var letters: [16]u8 = undefined;
    try testing.expectEqualStrings("HMHMMHM", try shape(&picker, &letters));
    var buffer = Picker.RowBuffer.init(testing.allocator);
    defer buffer.deinit();
    const list = try picker.rows(&buffer);
    const want = [_][]const u8{ "metask", "openai", "gemini" };
    var seen: usize = 0;
    for (list) |row| {
        if (row != .heading) continue;
        try testing.expectEqualStrings(want[seen], picker.offers.items[row.heading.offer_index].provider_id.slice());
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "the list holds every model however large the catalog, and Home/End reach both ends" {
    // A fixed row buffer of 256 once capped every stage: a gateway listing 300
    // models showed `[1/256]`, and the last 44 could be reached only by name.
    const count = 300;
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var names: [count][8]u8 = undefined;
    var offers: [count]OfferSummary = undefined;
    for (&offers, 0..) |*slot, index| {
        const id = std.fmt.bufPrint(&names[index], "m-{d:0>3}", .{index + 1}) catch unreachable;
        slot.* = fixtureOffer("metask", "default", id, null, id, "anthropic_messages");
    }
    try loadFixture(&picker, &offers, null);
    picker.restart();
    picker.page_rows = 8;
    try testing.expectEqual(@as(usize, count + 1), picker.rowCount());

    try testing.expect(picker.onKey(.end) == .redraw);
    try testing.expectEqual(@as(usize, count), picker.cursor);
    try testing.expectEqual(@as(usize, count + 1 - 8), picker.window_top);
    try testing.expect(picker.onKey(.home) == .redraw);
    // The first model, with its heading in view.
    try testing.expectEqual(@as(usize, 1), picker.cursor);
    try testing.expectEqual(@as(usize, 0), picker.window_top);
    // Up from the first model wraps to the last, skipping the heading.
    _ = picker.onKey(.up);
    try testing.expectEqual(@as(usize, count), picker.cursor);
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome.commit.offer_id.eql(offers[count - 1].offer_id));
}

test "scope is session unless the user explicitly cycles it" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{fixtureOffer("metask", "default", "M", null, "m", "anthropic_messages")};
    try loadFixture(&picker, &offers, null);
    picker.restart();
    try testing.expectEqual(Scope.session, picker.scope);
    _ = picker.onKey(.cycle_scope);
    try testing.expectEqual(Scope.global, picker.scope);
    _ = picker.onKey(.cycle_scope);
    try testing.expectEqual(Scope.once, picker.scope);
    _ = picker.onKey(.cycle_scope);
    try testing.expectEqual(Scope.session, picker.scope);
    _ = picker.onKey(.cycle_scope);
    try testing.expectEqual(Scope.global, picker.onKey(.enter).commit.scope);
    // Reopening forgets an explicit scope: it was a choice for that commit.
    picker.restart();
    try testing.expectEqual(Scope.session, picker.scope);
}

test "a sign-in's preset opens on its filter and scope, as if typed and cycled, and Esc clears the filter" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("openrouter", "auto", "Inkling (free)", null, "thinkingmachines/inkling-2-small:free", "openai_chat"),
        fixtureOffer("openrouter", "auto", "DeepSeek V4.1 Flash", null, "deepseek/deepseek-v4.1-flash", "openai_chat"),
        fixtureOffer("openrouter", "auto", "Ling 3.2 Flash (free)", null, "inclusionai/ling-3.2-flash:free", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    picker.presetScope(.global);
    picker.presetFilter(":free");
    try testing.expectEqualStrings(":free", picker.filter());
    var letters: [16]u8 = undefined;
    // The two free models under OpenRouter's heading; not the paid one.
    try testing.expectEqualStrings("HMM", try shape(&picker, &letters));
    try testing.expectEqual(Scope.global, picker.scope);
    // Enter applies the one under the cursor from now on.
    const committed = picker.onKey(.enter).commit;
    try testing.expectEqual(Scope.global, committed.scope);
    // The preset is the user's to undo: Esc clears the filter like a typed one.
    picker.restart();
    picker.presetFilter(":free");
    try testing.expect(picker.onKey(.escape) == .redraw);
    try testing.expectEqual(@as(usize, 0), picker.filter_len);
    // And a plain reopening knows nothing of it.
    picker.restart();
    try testing.expectEqual(Scope.session, picker.scope);
}

test "a typed filter keeps the matches under their providers' headings, and Esc clears it, then closes" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "GLM-4.6", null, "glm-4.6", "anthropic_messages"),
        fixtureOffer("metask", "default", "Kimi K3", null, "kimi-k3", "anthropic_messages"),
        fixtureOffer("zai", "default", "GLM-4.5", null, "glm-4.5", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    for ("g46") |byte| _ = picker.onKey(.{ .char = byte });
    var letters: [16]u8 = undefined;
    try testing.expectEqualStrings("HM", try shape(&picker, &letters));
    _ = picker.onKey(.backspace);
    _ = picker.onKey(.backspace);
    // "g" matches across providers, each under its heading.
    try testing.expectEqualStrings("HMHM", try shape(&picker, &letters));
    try testing.expect(picker.onKey(.escape) == .redraw);
    try testing.expectEqual(@as(usize, 0), picker.filter_len);
    try testing.expectEqualStrings("HMMHM", try shape(&picker, &letters));
    try testing.expect(picker.onKey(.escape) == .closed);
}

test "a typed filter lists the models that hold it whole before the ones that only hold its letters in order" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        // Catalog order puts the scattered match first: google/gemini holds
        // g…l…m.
        fixtureOffer("google", "default", "Gemini 4 Argon", "google/gemini-4-argon", "gemini-4-argon", "openai_chat"),
        fixtureOffer("zai", "default", "GLM-5.3", "zai/glm-5.3", "glm-5.3", "openai_chat"),
        fixtureOffer("zai", "anthropic", "GLM-5.3", "zai/glm-5.3", "glm-5.3", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    for ("glm") |byte| _ = picker.onKey(.{ .char = byte });
    var buffer = Picker.RowBuffer.init(testing.allocator);
    defer buffer.deinit();
    const listed = try picker.rows(&buffer);
    var labels: [4][]const u8 = undefined;
    var count: usize = 0;
    for (listed) |row| if (row == .model) {
        labels[count] = row.model.label;
        count += 1;
    };
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("zai/glm-5.3", labels[0]);
    try testing.expectEqualStrings("google/gemini-4-argon", labels[1]);
    var letters: [16]u8 = undefined;
    try testing.expectEqualStrings("HMRRHM", try shape(&picker, &letters));
    try testing.expectEqualStrings("zai", picker.offers.items[listed[0].heading.offer_index].provider_id.slice());
    // The cursor starts on the whole match, and the model is listed once
    // though it has two routes.
    try testing.expectEqualStrings("glm-5.3", picker.focusedOffer().?.request_model_id);
}

test "a filter lists a model OpenRouter resells under OpenRouter's heading, apart from the provider's own (#600)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("openrouter", "auto", "Google: Vision 4o", null, "google/vision-4o", "openai_chat"),
        fixtureOffer("openrouter", "auto", "DeepSeek: DeepSeek V4 Pro", null, "deepseek/deepseek-v4-pro", "openai_chat"),
        fixtureOffer("openrouter", "auto", "Qwen: Qwen4 Max", null, "qwen/qwen4-max", "openai_chat"),
        fixtureOffer("kimi", "default", "Kimi Vision 4", null, "kimi-vision-4", "openai_chat"),
        fixtureOffer("deepseek", "default", "DeepSeek V4 Pro", "deepseek/deepseek-v4-pro", "deepseek-v4-pro", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    for ("v4") |byte| _ = picker.onKey(.{ .char = byte });
    var buffer = Picker.RowBuffer.init(testing.allocator);
    defer buffer.deinit();
    var letters: [16]u8 = undefined;
    try testing.expectEqualStrings("HMMHMHM", try shape(&picker, &letters));
    var list = try picker.rows(&buffer);
    const wanted = [_][]const u8{ "openrouter", "DeepSeek: DeepSeek V4 Pro", "Google: Vision 4o", "deepseek", "DeepSeek V4 Pro", "kimi", "Kimi Vision 4" };
    for (list, wanted) |row, want| {
        const offer = switch (row) {
            .heading => |heading| picker.offers.items[heading.offer_index],
            .model => |group| picker.offers.items[group.offer_index],
            .route => unreachable,
        };
        const seen = if (row == .heading) offer.provider_id.slice() else offer.display_name;
        try testing.expectEqualStrings(want, seen);
    }
    try testing.expectEqualStrings("deepseek/deepseek-v4-pro", picker.focusedOffer().?.request_model_id);

    try loadFixture(&picker, &offers, offers[4].offer_id);
    picker.restart();
    for ("v4") |byte| _ = picker.onKey(.{ .char = byte });
    list = try picker.rows(&buffer);
    try testing.expectEqualStrings("HMHMMHM", try shape(&picker, &letters));
    try testing.expectEqualStrings("deepseek", picker.offers.items[list[0].heading.offer_index].provider_id.slice());
}

test "a scrolled window keeps a row above the cursor, for the heading the view draws there (#600)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var names: [20][4]u8 = undefined;
    var offers: [20]OfferSummary = undefined;
    for (&offers, 0..) |*slot, index| {
        const id = std.fmt.bufPrint(&names[index], "m{d:0>2}", .{index}) catch unreachable;
        slot.* = fixtureOffer("openrouter", "auto", id, null, id, "openai_chat");
    }
    try loadFixture(&picker, &offers, null);
    picker.restart();
    picker.page_rows = 5;
    _ = picker.onKey(.end);
    try testing.expectEqual(@as(usize, 20), picker.cursor);
    try testing.expectEqual(@as(usize, 16), picker.window_top);
    for (0..14) |_| {
        _ = picker.onKey(.up);
        try testing.expect(picker.cursor < picker.window_top + picker.page_rows);
        try testing.expect(picker.window_top < picker.cursor);
    }
    try testing.expectEqual(@as(usize, 6), picker.cursor);
    try testing.expectEqual(@as(usize, 5), picker.window_top);
    for (0..3) |_| _ = picker.onKey(.down);
    try testing.expectEqual(@as(usize, 5), picker.window_top);
    _ = picker.onKey(.home);
    try testing.expectEqual(@as(usize, 1), picker.cursor);
    try testing.expectEqual(@as(usize, 0), picker.window_top);
}

test "q types into a non-empty filter and closes only when the filter is empty" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{fixtureOffer("qwen", "default", "Qwen3", null, "qwen3", "openai_chat")};
    try loadFixture(&picker, &offers, null);
    picker.restart();
    _ = picker.onKey(.{ .char = 'w' });
    try testing.expect(picker.onKey(.{ .char = 'q' }) == .redraw);
    try testing.expectEqualStrings("wq", picker.filter());
    _ = picker.onKey(.escape);
    try testing.expect(picker.onKey(.{ .char = 'q' }) == .closed);
}

test "navigation wraps, skips headings, pages, and keeps the cursor inside the window" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var names: [12][4]u8 = undefined;
    var offers: [12]OfferSummary = undefined;
    for (&offers, 0..) |*slot, index| {
        const id = std.fmt.bufPrint(&names[index], "m{d:0>2}", .{index}) catch unreachable;
        slot.* = fixtureOffer(if (index < 6) "alpha" else "bravo", "default", id, null, id, "openai_chat");
    }
    try loadFixture(&picker, &offers, null);
    picker.restart();
    picker.page_rows = 5;
    // H M M M M M M H M M M M M M
    try testing.expectEqual(@as(usize, 1), picker.cursor);
    for (0..6) |_| _ = picker.onKey(.down);
    // Past bravo's heading.
    try testing.expectEqual(@as(usize, 8), picker.cursor);
    try testing.expect(picker.cursor < picker.window_top + picker.page_rows);
    _ = picker.onKey(.page_down);
    try testing.expectEqual(@as(usize, 13), picker.cursor);
    _ = picker.onKey(.down);
    // Wraps to the first model, its heading in view.
    try testing.expectEqual(@as(usize, 1), picker.cursor);
    try testing.expectEqual(@as(usize, 0), picker.window_top);
    _ = picker.onKey(.page_up);
    try testing.expectEqual(@as(usize, 1), picker.cursor);
}

test "a stale snapshot keeps its rows and says it is stale" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{fixtureOffer("metask", "default", "M", null, "m", "anthropic_messages")};
    try loadFixture(&picker, &offers, null);
    picker.markStale();
    try testing.expectEqual(Status.stale, picker.status);
    try testing.expectEqual(@as(usize, 2), picker.rowCount());
    try loadFixture(&picker, &offers, null);
    try testing.expectEqual(Status.ready, picker.status);
}

test "←/→ walk the focused model's reasoning levels from any row, default first, and Enter commits the one shown" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offer = fixtureOffer("metask", "default", "glm-5.3", null, "glm-5.3", "anthropic_messages");
    offer.controls = &REASONING;
    const offers = [_]OfferSummary{offer};
    try loadFixture(&picker, &offers, null);
    picker.restart();
    const spec = REASONING[0];
    // Unset: the provider's default.
    try testing.expect(picker.effectiveValue(spec) == null);
    try testing.expect(picker.onKey(.left) == .ignored);
    _ = picker.onKey(.right);
    try testing.expectEqualStrings("low", picker.effectiveValue(spec).?);
    _ = picker.onKey(.right);
    _ = picker.onKey(.right);
    _ = picker.onKey(.right);
    try testing.expectEqualStrings("max", picker.effectiveValue(spec).?);
    // No wrap at the end.
    try testing.expect(picker.onKey(.right) == .ignored);
    _ = picker.onKey(.left);
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome.commit.controls.get("reasoning_effort").?.text.eqlText("high"));
    // Back to default commits no level.
    picker.restart();
    _ = picker.onKey(.right);
    _ = picker.onKey(.left);
    try testing.expect(picker.onKey(.enter).commit.controls.get("reasoning_effort") == null);
}

test "the level wanted is kept across models, each showing the nearest it takes" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var wide = fixtureOffer("metask", "default", "glm-5.3", null, "glm-5.3", "anthropic_messages");
    wide.controls = &REASONING;
    var narrow = fixtureOffer("metask", "default", "hy4", null, "hy4", "anthropic_messages");
    narrow.controls = &REASONING_SHORT;
    const offers = [_]OfferSummary{ wide, narrow };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    // The session ran at the neutral `xhigh`; this vocabulary calls it `max`.
    picker.presetControl("reasoning_effort", "xhigh");
    try testing.expectEqualStrings("max", picker.effectiveValue(REASONING[0]).?);
    try testing.expect(picker.wantedInstead(REASONING[0]) == null);
    // The next model tops out at high: shown, and said.
    _ = picker.onKey(.down);
    try testing.expectEqualStrings("high", picker.effectiveValue(REASONING_SHORT[0]).?);
    try testing.expectEqualStrings("xhigh", picker.wantedInstead(REASONING_SHORT[0]).?);
    try testing.expect(picker.onKey(.enter).commit.controls.get("reasoning_effort").?.text.eqlText("high"));
    // Back on the first model the level wanted is still there.
    _ = picker.onKey(.up);
    try testing.expectEqualStrings("max", picker.effectiveValue(REASONING[0]).?);
    // A tie goes to the lower level.
    picker.presetControl("reasoning_effort", "medium");
    _ = picker.onKey(.down);
    try testing.expectEqualStrings("low", picker.effectiveValue(REASONING_SHORT[0]).?);
}

/// DeepSeek's vocabulary, and the default it declares.
const REASONING_DECLARED = [_]controls_mod.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &.{ "none", "low", "high", "max" },
    .default_value = .{ .text = controls_mod.ControlText.parse("high") catch unreachable },
}};

fn declaredFixture(picker: *Picker) !void {
    var offer = fixtureOffer("deepseek", "default", "DeepSeek V4 Pro", null, "deepseek-v4-pro", "openai_chat");
    offer.controls = &REASONING_DECLARED;
    try loadFixture(picker, &.{offer}, null);
    picker.restart();
}

test "a declared default starts selected and is committed by name, and nothing sits before the first value" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    try declaredFixture(&picker);
    const spec = REASONING_DECLARED[0];
    // Nothing wanted: the provider's default, by name.
    try testing.expectEqualStrings("high", picker.effectiveValue(spec).?);
    try testing.expect(picker.wantedInstead(spec) == null);
    const first = picker.onKey(.enter).commit.controls.get("reasoning_effort").?;
    try testing.expect(first.text.eqlText("high"));
    // ← walks down to the first value and stops: no unset slot to step
    // into, from which the default would come back.
    _ = picker.onKey(.left);
    try testing.expectEqualStrings("low", picker.effectiveValue(spec).?);
    _ = picker.onKey(.left);
    try testing.expectEqualStrings("none", picker.effectiveValue(spec).?);
    try testing.expect(picker.onKey(.left) == .ignored);
    try testing.expectEqualStrings("none", picker.effectiveValue(spec).?);
    const off = picker.onKey(.enter).commit.controls.get("reasoning_effort").?;
    try testing.expect(off.text.eqlText("none"));
}

test "a level the session runs with wins over the declared default, none included" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    try declaredFixture(&picker);
    const spec = REASONING_DECLARED[0];
    for ([_][]const u8{ "none", "low", "max" }) |level| {
        picker.restart();
        picker.presetControl("reasoning_effort", level);
        try testing.expectEqualStrings(level, picker.effectiveValue(spec).?);
        const sent = picker.onKey(.enter).commit.controls.get("reasoning_effort").?;
        try testing.expect(sent.text.eqlText(level));
    }
    // A level the vocabulary lacks takes the nearest one it has, as on any
    // route: the default stands in only when nothing is wanted.
    picker.restart();
    picker.presetControl("reasoning_effort", "medium");
    try testing.expectEqualStrings("low", picker.effectiveValue(spec).?);
    try testing.expectEqualStrings("medium", picker.wantedInstead(spec).?);
}

test "a declared default the vocabulary lacks is not shown, and unset stays the default" {
    const odd = [_]controls_mod.ControlSpec{.{
        .id = "reasoning_effort",
        .label = "Reasoning effort",
        .kind = .enumeration,
        .allowed_values = &.{ "low", "high" },
        .default_value = .{ .text = controls_mod.ControlText.parse("turbo") catch unreachable },
    }};
    try testing.expect(declaredDefault(odd[0]) == null);
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offer = fixtureOffer("metask", "default", "M", null, "m", "anthropic_messages");
    offer.controls = &odd;
    try loadFixture(&picker, &.{offer}, null);
    picker.restart();
    try testing.expect(picker.effectiveValue(odd[0]) == null);
    try testing.expect(picker.onKey(.enter).commit.controls.get("reasoning_effort") == null);
}

test "a control the provider did not enumerate cannot be changed from the picker" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const free_form = [_]controls_mod.ControlSpec{.{ .id = "temperature", .label = "Temperature", .kind = .range }};
    var offer = fixtureOffer("metask", "default", "M", null, "m", "anthropic_messages");
    offer.controls = &free_form;
    const offers = [_]OfferSummary{offer};
    try loadFixture(&picker, &offers, null);
    picker.restart();
    try testing.expect(picker.onKey(.right) == .ignored);
    try testing.expect(picker.onKey(.enter).commit.controls.get("temperature") == null);
}

test "a refresh that removes the focused route leaves the cursor on a row that is still there" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const before = [_]OfferSummary{
        fixtureOffer("metask", "default", "A", null, "a", "anthropic_messages"),
        fixtureOffer("metask", "default", "B", null, "b", "anthropic_messages"),
    };
    try loadFixture(&picker, &before, null);
    picker.restart();
    _ = picker.onKey(.down);
    try testing.expectEqual(@as(usize, 2), picker.cursor);
    const after = [_]OfferSummary{before[0]};
    try loadFixture(&picker, &after, null);
    try testing.expectEqual(@as(usize, 1), picker.cursor);
    try testing.expect(picker.onKey(.enter).commit.offer_id.eql(before[0].offer_id));
}

test "a refresh that keeps the focused model leaves the cursor on it" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "A", null, "a", "anthropic_messages"),
        fixtureOffer("metask", "default", "B", null, "b", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    _ = picker.onKey(.down);
    const reordered = [_]OfferSummary{ offers[1], offers[0] };
    try loadFixture(&picker, &reordered, null);
    try testing.expect(picker.onKey(.enter).commit.offer_id.eql(offers[1].offer_id));
}

test "a provider with no ready offer is not listed, and no row leads to its setup (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("openai", "default", "GPT-4o", null, "gpt-4o", "openai_chat"),
        fixtureOffer("deepseek", "default", "DeepSeek", null, "deepseek-v4-pro", "openai_chat"),
        fixtureOffer("gemini", "default", "Gemini", null, "gemini-2.5-pro", "gemini_generate"),
    };
    try loadFixture(&picker, &offers, null);
    try picker.setReadiness(&.{ false, true, false }, &.{});
    picker.restart();
    var letters: [16]u8 = undefined;
    // DeepSeek's heading and model, and nothing below them.
    try testing.expectEqualStrings("HM", try shape(&picker, &letters));
    var buffer = Picker.RowBuffer.init(testing.allocator);
    defer buffer.deinit();
    const heading = (try rowAt(&picker, &buffer, 0)).heading;
    try testing.expectEqualStrings("deepseek", picker.offers.items[heading.offer_index].provider_id.slice());
    // End and ↓ stay on that model, and Enter applies it.
    _ = picker.onKey(.end);
    _ = picker.onKey(.down);
    try testing.expectEqual(@as(usize, 1), picker.cursor);
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome.commit.offer_id.eql(offers[1].offer_id));
    try testing.expectEqual(Stage.list, picker.stage);
}

test "a filter does not find the models of a provider with no ready offer (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "glm-5.3", null, "glm-5.3", "anthropic_messages"),
        fixtureOffer("zai-coding-plan", "default", "GLM-4.6", null, "glm-4.6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    try picker.setReadiness(&.{ true, false }, &.{});
    picker.restart();
    // `glm` matches both models; only the configured one is listed.
    for ("glm") |byte| _ = picker.onKey(.{ .char = byte });
    var letters: [16]u8 = undefined;
    try testing.expectEqualStrings("HM", try shape(&picker, &letters));
    try testing.expectEqualStrings("glm-5.3", picker.focusedOffer().?.request_model_id);
    // What only the other provider matches lists nothing, and Enter there
    // neither commits nor shows a setup.
    picker.restart();
    for ("zai") |byte| _ = picker.onKey(.{ .char = byte });
    try testing.expectEqual(@as(usize, 0), picker.rowCount());
    try testing.expect(picker.onKey(.enter) == .ignored);
    try testing.expectEqual(Stage.list, picker.stage);
    try testing.expect(picker.setup == null);
}

test "a commit the host found no credential for shows the setup, and Esc returns to the same model (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("kimi", "default", "K2", null, "k2", "openai_chat"),
        fixtureOffer("kimi", "default", "K3", null, "k3", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    _ = picker.onKey(.down);
    try testing.expect(picker.onKey(.enter) == .commit);
    picker.enterSetup(.{ .provider = Slug.lit("kimi"), .variable = "MOONSHOT_API_KEY" });
    try testing.expectEqual(Stage.setup, picker.stage);
    _ = picker.onKey(.escape);
    try testing.expectEqual(Stage.list, picker.stage);
    try testing.expectEqual(@as(usize, 2), picker.cursor);
}

test "a refresh that takes every credential away leaves no row and nothing to apply" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("kimi", "default", "K3", null, "k3", "openai_chat"),
        fixtureOffer("deepseek", "default", "DS", null, "ds", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);
    picker.restart();
    try picker.setReadiness(&.{ false, false }, &.{});
    try testing.expectEqual(@as(usize, 0), picker.rowCount());
    try testing.expectEqual(@as(usize, 0), picker.cursor);
    try testing.expect(picker.focusedOffer() == null);
    for ([_]Key{ .enter, .right, .down, .end }) |key| {
        try testing.expect(picker.onKey(key) == .ignored);
    }
    try testing.expectEqual(Stage.list, picker.stage);
    // The credentials come back, and so do the rows.
    try picker.setReadiness(&.{ true, true }, &.{});
    var letters: [16]u8 = undefined;
    try testing.expectEqualStrings("HMHM", try shape(&picker, &letters));
}

test "fuzzy matching is case-insensitive and an empty needle hides nothing" {
    try testing.expect(matches("g46", "GLM-4.6"));
    try testing.expect(matches("GLM", "glm-4.6"));
    try testing.expect(!matches("x", "GLM-4.6"));
    try testing.expect(matches("", "anything"));
}

test "a provider note keeps its name when what it was read from is freed" {
    var name = "DeepSeek".*;
    const note = ProviderNote.init(Slug.lit("deepseek"), &name, .local_config);
    @memset(&name, 'x');
    try testing.expectEqualStrings("DeepSeek", note.name());
    try testing.expectEqualStrings("key from .env", note.originText().?);
}
