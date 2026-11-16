//! Cross-UI model picker (issue #16, delivery slice P1 — TUI migration).
//!
//! Pure state over a control-plane snapshot. This module touches no fd, no
//! terminal, no environment, and no provider client: it reads a snapshot the
//! host took from the kernel and emits a `Commit` the host applies *through*
//! the kernel. That boundary is the point — a picker that resolved routes
//! itself would be a second place identity is decided, and the two would drift.
//!
//! The interaction is the one the requirement specifies:
//!
//! ```text
//! Provider → Canonical model → Channel/Offer (optional) → Options (optional) → Commit
//! ```
//!
//! The offer stage is skipped when a canonical model has exactly one offer, and
//! the options stage when the offer declares no controls. Offers are grouped by
//! *canonical id*, never by visible name: two channels serving "GLM-4.6" over
//! different protocols, regions, or prices are different routes, and collapsing
//! them by display name would hide the choice this whole model exists to give.
//!
//! Every route the list offers can be applied as it is (#488). The host says,
//! per offer, whether a commit would find a credential for it now
//! (`setReadiness`); an offer without one is not listed, and a provider with
//! none of its offers ready sits dimmed in a "Not configured" group under the
//! others. Choosing such a provider shows where its credential goes
//! (`Stage.setup`) and nothing else: no sign-in, no key field, no request.

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

pub const Stage = enum { provider, model, offer, options, setup };

/// Where a provider that is not configured gets its credential, as the setup
/// stage shows it (#488). The host derives it from the provider's profile.
pub const Setup = struct {
    provider: Slug,
    /// The variable its key is read from (the canonical alias, else the
    /// first), borrowed from the provider registry. Null: it declares none.
    variable: ?[]const u8 = null,
    /// Signing in with `/login` is the way in (Metask).
    sign_in: bool = false,
};

/// What the list is showing right now. `stale` and `failed` are states a client
/// must be able to render: a picker that silently shows an out-of-date catalog
/// invites committing to a route that no longer exists.
pub const Status = enum { loading, ready, empty, stale, failed };

pub const Group = struct {
    /// A representative offer for the row. Detail the renderer needs (limits,
    /// price, protocol) is read from the snapshot through this index.
    offer_index: usize,
    /// How many offers this row stands for. The offer stage is skipped when a
    /// model row's count is 1.
    offer_count: usize,
    label: []const u8,
    /// True when the committed selection is one of the offers behind this row.
    is_current: bool,
    /// False for a provider none of whose offers a commit could bind now: its
    /// row is in the "Not configured" group and opens its setup (#488).
    ready: bool = true,
};

pub const Row = union(enum) {
    provider: Group,
    model: Group,
    offer: struct { offer_index: usize, is_current: bool },
    control: struct { spec_index: usize, offer_index: usize },
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
    /// First and last row of the stage.
    home,
    end,
    /// On a control row: the previous / next value of its vocabulary.
    left,
    right,
    enter,
    /// Clears the filter, then walks back a stage, then closes.
    escape,
    backspace,
    /// Cycles session → global → once. Session is the default, so any other
    /// scope is always an explicit act.
    cycle_scope,
    char: u8,
};

pub const Picker = struct {
    allocator: std.mem.Allocator,
    offers: std.ArrayList(OfferSummary) = .empty,
    status: Status = .loading,
    /// Revisions the snapshot was taken at. A later kernel revision makes the
    /// snapshot `stale` rather than silently wrong.
    catalog_revision: ids.CatalogRevision = .initial,
    config_revision: ids.ConfigRevision = .initial,
    current_offer: ?OfferId = null,

    stage: Stage = .provider,
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
    /// Where each provider with no ready offer gets its credential.
    setups: std.ArrayList(Setup) = .empty,
    /// What the setup stage shows.
    setup: ?Setup = null,
    /// Where Esc leaves the setup stage for: the stage and row it was opened
    /// from.
    setup_return_stage: Stage = .provider,
    setup_return_cursor: usize = 0,
    /// This install's `<state root>/.env` and the guide to it, for the setup
    /// stage; the host sets both when it opens the picker.
    local_config_path_buffer: [MAX_LOCAL_CONFIG_PATH]u8 = undefined,
    local_config_path_len: usize = 0,
    guide_url: []const u8 = "",

    provider: ?Slug = null,
    group_key_buffer: [MAX_GROUP_KEY]u8 = undefined,
    group_key_len: usize = 0,
    offer_id: ?OfferId = null,
    controls: controls_mod.ControlValues = .{},
    /// Values the session already runs with (the host sets them on open). A
    /// control an offer declares starts at its preset when the vocabulary
    /// has it, so committing a route keeps the reasoning effort in use
    /// instead of silently dropping it.
    preset_controls: controls_mod.ControlValues = .{},
    scope: Scope = .session,

    pub fn init(allocator: std.mem.Allocator) Picker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Picker) void {
        self.offers.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.setups.deinit(self.allocator);
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

    pub fn groupKey(self: *const Picker) []const u8 {
        return self.group_key_buffer[0..self.group_key_len];
    }

    /// Replace the snapshot. The host calls this on open and whenever the
    /// kernel reports a newer catalog, which is what turns a stale list back
    /// into a live one instead of leaving the user staring at old routes.
    pub fn adopt(
        self: *Picker,
        page: control_plane.ListPage,
        current_offer: ?OfferId,
    ) error{OutOfMemory}!void {
        self.offers.clearRetainingCapacity();
        try self.offers.appendSlice(self.allocator, page.offers);
        // The verdicts were about the previous snapshot.
        self.ready.clearRetainingCapacity();
        self.setups.clearRetainingCapacity();
        self.catalog_revision = page.meta.catalog_revision;
        self.config_revision = page.meta.config_revision;
        self.current_offer = current_offer;
        self.status = if (self.offers.items.len == 0) .empty else .ready;
        self.stepBackFromLostDraft();
    }

    /// Which offers of the snapshot a commit could bind now (`ready`, in
    /// snapshot order), and where each provider with none of them gets its
    /// credential (#488). The host calls it right after `adopt`, under the
    /// same lock.
    pub fn setReadiness(self: *Picker, ready: []const bool, setups: []const Setup) error{OutOfMemory}!void {
        self.ready.clearRetainingCapacity();
        self.setups.clearRetainingCapacity();
        try self.ready.appendSlice(self.allocator, ready[0..@min(ready.len, self.offers.items.len)]);
        try self.setups.appendSlice(self.allocator, setups);
        self.stepBackFromLostDraft();
    }

    /// A refresh can take away the offer a half-finished draft was built on
    /// (it is gone, or no longer has a credential), or every ready offer of
    /// its provider: the stage would render nothing and Enter silently do
    /// nothing. Step back to where a choice is still possible and say why.
    fn stepBackFromLostDraft(self: *Picker) void {
        if (self.provider) |provider| if (self.stage != .provider and self.stage != .setup and !self.providerReady(provider)) {
            self.provider = null;
            self.group_key_len = 0;
            self.offer_id = null;
            self.controls = .{};
            self.stage = .provider;
            self.cursor = 0;
            self.window_top = 0;
            self.setNotice("{s} has no usable route now; pick another", .{provider.slice()});
        };
        if (self.offer_id != null) {
            const lost = if (self.currentOfferIndex()) |index| !self.isReady(index) else true;
            if (lost) {
                self.offer_id = null;
                self.controls = .{};
                if (self.stage == .options or self.stage == .offer) self.stage = .model;
                self.cursor = 0;
                self.window_top = 0;
                self.setNotice("that route is no longer offered; pick another", .{});
            }
        }
        self.clampCursor();
    }

    /// Whether a commit could bind the offer at `index` now.
    pub fn isReady(self: *const Picker, index: usize) bool {
        return index >= self.ready.items.len or self.ready.items[index];
    }

    /// Whether any offer of `provider` is ready.
    pub fn providerReady(self: *const Picker, provider: Slug) bool {
        for (self.offers.items, 0..) |offer, index| {
            if (offer.provider_id.eql(provider) and self.isReady(index)) return true;
        }
        return false;
    }

    /// Where `provider` gets its credential, as the host described it; just
    /// the provider when the host said nothing about it.
    pub fn setupFor(self: *const Picker, provider: Slug) Setup {
        for (self.setups.items) |entry| {
            if (entry.provider.eql(provider)) return entry;
        }
        return .{ .provider = provider };
    }

    /// This install's `<state root>/.env` (copied, cut at
    /// `MAX_LOCAL_CONFIG_PATH`) and the guide to it (borrowed; a static
    /// string), for the setup stage.
    pub fn setLocalConfig(self: *Picker, path: []const u8, guide: []const u8) void {
        const len = @min(path.len, MAX_LOCAL_CONFIG_PATH);
        @memcpy(self.local_config_path_buffer[0..len], path[0..len]);
        self.local_config_path_len = len;
        self.guide_url = guide;
    }

    pub fn localConfigPath(self: *const Picker) []const u8 {
        return self.local_config_path_buffer[0..self.local_config_path_len];
    }

    /// Show where `setup.provider` gets its credential in place of the list:
    /// Enter on a provider in the "Not configured" group, or a commit the
    /// host found no credential for (#488). Esc goes back to where the user
    /// was, filter and row included.
    pub fn enterSetup(self: *Picker, setup: Setup) void {
        if (self.stage != .setup) {
            self.setup_return_stage = self.stage;
            self.setup_return_cursor = self.cursor;
        }
        self.setup = setup;
        self.stage = .setup;
    }

    fn leaveSetup(self: *Picker) void {
        self.stage = self.setup_return_stage;
        self.setup = null;
        self.notice_len = 0;
        self.cursor = self.setup_return_cursor;
        // A refresh while the setup was shown may have taken the draft away.
        self.stepBackFromLostDraft();
    }

    /// Mark the snapshot out of date without discarding it: the user keeps
    /// seeing something while the refresh runs, and the footer says it is old.
    pub fn markStale(self: *Picker) void {
        if (self.status == .ready) self.status = .stale;
    }

    pub fn markFailed(self: *Picker) void {
        self.status = .failed;
    }

    /// Reset to the first stage, keeping the snapshot. Used when the picker is
    /// reopened: an abandoned half-finished path should not come back.
    pub fn restart(self: *Picker) void {
        self.notice_len = 0;
        self.stage = .provider;
        self.filter_len = 0;
        self.cursor = 0;
        self.window_top = 0;
        self.provider = null;
        self.group_key_len = 0;
        self.offer_id = null;
        self.controls = .{};
        self.preset_controls = .{};
        self.scope = .session;
        self.setup = null;
        self.setup_return_stage = .provider;
        self.setup_return_cursor = 0;
    }

    // ── row construction ────────────────────────────────────────────────────

    /// Storage for one stage's rows, owned by the caller and sized by the
    /// catalog. There is deliberately no fixed capacity: a stage capped at a
    /// constant silently dropped every model past it (a gateway listing 300
    /// models showed `[1/256]`, and the last 44 could not be reached).
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
            .provider => try self.providerRows(buffer),
            .model => try self.modelRows(buffer),
            .offer => try self.offerRows(buffer),
            .options => try self.controlRows(buffer),
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

    fn providerRows(self: *const Picker, buffer: *RowBuffer) error{OutOfMemory}!void {
        // The providers a commit can use, counting their ready offers; then,
        // as the "Not configured" group below them, those with no ready offer
        // at all (#488), each in catalog order.
        for ([_]bool{ true, false }) |configured| {
            const group_start = buffer.list.items.len;
            // By pointer: a provider id is an inline `Slug`, so the label of a by-value
            // capture points into the loop variable. Every stored label then read the
            // offer being visited, and providers whose ids had the same length
            // (metask, openai, gemini) folded into the first one's row.
            for (self.offers.items, 0..) |*offer, index| {
                if (configured) {
                    if (!self.isReady(index)) continue;
                } else if (self.providerReady(offer.provider_id)) continue;
                const label = offer.provider_id.slice();
                // The filter also matches what the provider *serves*. The first
                // stage is the one where the user knows least: someone looking for
                // GLM should not have to already know it lives behind
                // `zai-coding-plan`.
                if (!matches(self.filter(), label) and
                    !matches(self.filter(), offer.display_name) and
                    !matches(self.filter(), canonicalKey(offer.*))) continue;
                if (findGroup(buffer.list.items[group_start..], label, self)) |existing| {
                    bumpGroup(&buffer.list.items[group_start + existing], index, self.isCurrent(offer.*));
                    continue;
                }
                try buffer.list.append(buffer.gpa, .{ .provider = .{
                    .offer_index = index,
                    .offer_count = 1,
                    .label = label,
                    .is_current = self.isCurrent(offer.*),
                    .ready = configured,
                } });
            }
        }
    }

    fn modelRows(self: *const Picker, buffer: *RowBuffer) error{OutOfMemory}!void {
        const wanted = self.provider orelse return;
        for (self.offers.items, 0..) |offer, index| {
            if (!offer.provider_id.eql(wanted)) continue;
            // Listed only when a commit could bind it now (#488).
            if (!self.isReady(index)) continue;
            const key = canonicalKey(offer);
            if (!matches(self.filter(), offer.display_name) and
                !matches(self.filter(), key) and
                !matches(self.filter(), offer.request_model_id)) continue;
            if (findGroupByKey(buffer.list.items, key, self)) |existing| {
                bumpGroup(&buffer.list.items[existing], index, self.isCurrent(offer));
                continue;
            }
            try buffer.list.append(buffer.gpa, .{ .model = .{
                .offer_index = index,
                .offer_count = 1,
                .label = key,
                .is_current = self.isCurrent(offer),
            } });
        }
    }

    fn offerRows(self: *const Picker, buffer: *RowBuffer) error{OutOfMemory}!void {
        const wanted = self.provider orelse return;
        const key = self.groupKey();
        for (self.offers.items, 0..) |offer, index| {
            if (!offer.provider_id.eql(wanted)) continue;
            if (!std.mem.eql(u8, canonicalKey(offer), key)) continue;
            if (!self.isReady(index)) continue;
            // Deliberately no filter on this stage: it exists precisely to show
            // every route behind one visible name, and a filter over names
            // would hide the ones that share it.
            try buffer.list.append(buffer.gpa, .{ .offer = .{ .offer_index = index, .is_current = self.isCurrent(offer) } });
        }
    }

    fn controlRows(self: *const Picker, buffer: *RowBuffer) error{OutOfMemory}!void {
        const index = self.currentOfferIndex() orelse return;
        for (self.offers.items[index].controls, 0..) |_, spec_index| {
            try buffer.list.append(buffer.gpa, .{ .control = .{ .spec_index = spec_index, .offer_index = index } });
        }
    }

    fn currentOfferIndex(self: *const Picker) ?usize {
        const wanted = self.offer_id orelse return null;
        for (self.offers.items, 0..) |offer, index| {
            if (offer.offer_id.eql(wanted)) return index;
        }
        return null;
    }

    /// Record a value the session runs with, for `preset_controls`. Ignored when
    /// it does not fit: the control then simply starts unset.
    pub fn presetControl(self: *Picker, id: []const u8, text: []const u8) void {
        const value = controls_mod.Value.fromText(text) catch return;
        self.preset_controls.set(id, value) catch {};
    }

    /// The offer the picker would commit right now, if any.
    pub fn selectedOffer(self: *const Picker) ?*const OfferSummary {
        const index = self.currentOfferIndex() orelse return null;
        return &self.offers.items[index];
    }

    fn isCurrent(self: *const Picker, offer: OfferSummary) bool {
        const current = self.current_offer orelse return false;
        return current.eql(offer.offer_id);
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
            .up => return self.move(visible.len, false),
            .down => return self.move(visible.len, true),
            .page_up => return self.pageMove(visible.len, false),
            .page_down => return self.pageMove(visible.len, true),
            .home => return self.jump(visible.len, false),
            .end => return self.jump(visible.len, true),
            .left, .right => {
                if (self.stage != .options or visible.len == 0) return .ignored;
                const row = visible[@min(self.cursor, visible.len - 1)];
                return switch (row) {
                    .control => |control| self.cycleControl(control, key == .right),
                    else => .ignored,
                };
            },
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
                self.cursor = 0;
                self.window_top = 0;
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
                self.cursor = 0;
                self.window_top = 0;
                return .redraw;
            },
            .enter => return self.advance(visible),
        }
    }

    fn move(self: *Picker, count: usize, down: bool) Outcome {
        if (count == 0) return .ignored;
        if (down) {
            self.cursor = (self.cursor + 1) % count;
        } else {
            self.cursor = if (self.cursor == 0) count - 1 else self.cursor - 1;
        }
        self.scrollTo(count);
        return .redraw;
    }

    fn pageMove(self: *Picker, count: usize, down: bool) Outcome {
        if (count == 0) return .ignored;
        const step = @max(self.page_rows, 1);
        if (down) {
            self.cursor = @min(self.cursor + step, count - 1);
        } else {
            self.cursor -|= step;
        }
        self.scrollTo(count);
        return .redraw;
    }

    fn jump(self: *Picker, count: usize, to_end: bool) Outcome {
        if (count == 0) return .ignored;
        self.cursor = if (to_end) count - 1 else 0;
        self.scrollTo(count);
        return .redraw;
    }

    /// Keep the cursor inside the visible window, scrolling by the minimum
    /// needed so a long list does not jump under the user.
    fn scrollTo(self: *Picker, count: usize) void {
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
        const max_top = count - rows_visible;
        if (self.window_top > max_top) self.window_top = max_top;
    }

    fn clampCursor(self: *Picker) void {
        const count = self.rowCount();
        if (count == 0) {
            self.cursor = 0;
            self.window_top = 0;
            return;
        }
        if (self.cursor >= count) self.cursor = count - 1;
        self.scrollTo(count);
    }

    fn back(self: *Picker) Outcome {
        // The setup stage keeps the filter it was opened under: Esc returns to
        // that list, on the row it was opened from.
        if (self.stage == .setup) {
            self.leaveSetup();
            return .redraw;
        }
        if (self.filter_len > 0) {
            self.filter_len = 0;
            self.cursor = 0;
            self.window_top = 0;
            return .redraw;
        }
        switch (self.stage) {
            .provider => return .closed,
            .model => {
                self.stage = .provider;
                self.provider = null;
            },
            .offer => {
                self.stage = .model;
                self.group_key_len = 0;
                self.offer_id = null;
            },
            .options => {
                // Returning to the offer stage is only meaningful when there
                // was a choice there; otherwise it was skipped on the way in
                // and would be skipped again on the way out, trapping the user.
                self.stage = if (self.offerCountForGroup() > 1) .offer else .model;
                if (self.stage == .model) self.group_key_len = 0;
                self.offer_id = null;
                self.controls = .{};
            },
            .setup => unreachable, // handled above
        }
        self.cursor = 0;
        self.window_top = 0;
        return .redraw;
    }

    fn offerCountForGroup(self: *const Picker) usize {
        var probe = self.*;
        probe.stage = .offer;
        probe.filter_len = 0;
        return probe.rowCount();
    }

    fn advance(self: *Picker, visible: []const Row) Outcome {
        if (visible.len == 0) return .ignored;
        const row = visible[@min(self.cursor, visible.len - 1)];
        switch (row) {
            .provider => |group| {
                const provider = self.offers.items[group.offer_index].provider_id;
                if (!group.ready) {
                    // Not configured: where its credential goes, and nothing
                    // more (#488).
                    self.enterSetup(self.setupFor(provider));
                    return .redraw;
                }
                self.provider = provider;
                self.stage = .model;
                self.filter_len = 0;
                self.cursor = 0;
                self.window_top = 0;
                return .redraw;
            },
            .model => |group| {
                self.setGroupKey(group.label);
                self.filter_len = 0;
                self.cursor = 0;
                self.window_top = 0;
                if (group.offer_count == 1) {
                    // One route behind this name: the channel step would be a
                    // list of one, so it is skipped rather than shown.
                    self.offer_id = self.offers.items[group.offer_index].offer_id;
                    return self.afterOfferChosen();
                }
                self.stage = .offer;
                return .redraw;
            },
            .offer => |chosen| {
                self.offer_id = self.offers.items[chosen.offer_index].offer_id;
                self.cursor = 0;
                self.window_top = 0;
                return self.afterOfferChosen();
            },
            // Enter on the options step applies the route with the values
            // shown; ←/→ change them. Enter used to cycle a value, which left
            // no key that committed a route declaring any control.
            .control => return self.commitNow(),
        }
    }

    fn afterOfferChosen(self: *Picker) Outcome {
        const offer = self.selectedOffer() orelse return .ignored;
        if (offer.controls.len == 0) return self.commitNow();
        self.controls = .{};
        for (offer.controls) |spec| {
            const preset = self.preset_controls.get(spec.id) orelse continue;
            if (!vocabularyHas(spec, preset)) continue;
            self.controls.set(spec.id, preset) catch {};
        }
        self.stage = .options;
        return .redraw;
    }

    /// Enter on a control cycles its value through the provider's declared
    /// vocabulary, ending on "unset". Nothing here invents a value: a control
    /// with no `allowed_values` cannot be edited from the picker at all.
    fn cycleControl(self: *Picker, row: anytype, forward: bool) Outcome {
        const offer = self.offers.items[row.offer_index];
        if (row.spec_index >= offer.controls.len) return .ignored;
        const spec = offer.controls[row.spec_index];
        if (spec.kind != .enumeration or spec.allowed_values.len == 0) return .ignored;

        // The cycle is unset → each declared value in order → unset; ← walks
        // it the other way.
        const count = spec.allowed_values.len;
        var position: ?usize = null; // null = unset
        if (self.controls.get(spec.id)) |value| {
            for (spec.allowed_values, 0..) |candidate, index| {
                if (value == .text and value.text.eqlText(candidate)) position = index;
            }
        }
        const next_index: ?usize = if (forward)
            (if (position) |at| (if (at + 1 < count) at + 1 else null) else 0)
        else
            (if (position) |at| (if (at > 0) at - 1 else null) else count - 1);
        if (next_index) |index| {
            const value = controls_mod.Value{
                .text = controls_mod.ControlText.parse(spec.allowed_values[index]) catch return .ignored,
            };
            self.controls.set(spec.id, value) catch return .ignored;
        } else {
            _ = self.controls.remove(spec.id);
        }
        return .redraw;
    }

    /// Commit the current draft. Exposed so the options stage can finish
    /// without cycling back through the offer list.
    pub fn commitNow(self: *Picker) Outcome {
        const offer = self.selectedOffer() orelse return .ignored;
        return .{ .commit = .{
            .offer_id = offer.offer_id,
            .offer_revision = offer.offer_revision,
            .controls = self.controls,
            .scope = self.scope,
        } };
    }

    fn setGroupKey(self: *Picker, key: []const u8) void {
        const len = @min(key.len, MAX_GROUP_KEY);
        @memcpy(self.group_key_buffer[0..len], key[0..len]);
        self.group_key_len = len;
    }
};

/// Grouping key. `canonical_model_id` when the provider declares one, otherwise
/// the request id — never the display name, which several distinct routes
/// legitimately share.
pub fn canonicalKey(offer: OfferSummary) []const u8 {
    return offer.canonical_model_id orelse offer.request_model_id;
}

fn findGroup(existing: []const Row, label: []const u8, self: *const Picker) ?usize {
    _ = self;
    for (existing, 0..) |row, index| {
        const current = switch (row) {
            .provider => |group| group.label,
            .model => |group| group.label,
            else => continue,
        };
        if (std.mem.eql(u8, current, label)) return index;
    }
    return null;
}

fn vocabularyHas(spec: controls_mod.ControlSpec, value: controls_mod.Value) bool {
    if (spec.kind != .enumeration or value != .text) return false;
    for (spec.allowed_values) |candidate| {
        if (value.text.eqlText(candidate)) return true;
    }
    return false;
}

fn findGroupByKey(existing: []const Row, key: []const u8, self: *const Picker) ?usize {
    return findGroup(existing, key, self);
}

fn bumpGroup(row: *Row, offer_index: usize, is_current: bool) void {
    _ = offer_index;
    switch (row.*) {
        .provider => |*group| {
            group.offer_count += 1;
            group.is_current = group.is_current or is_current;
        },
        .model => |*group| {
            group.offer_count += 1;
            group.is_current = group.is_current or is_current;
        },
        else => {},
    }
}

/// Case-insensitive subsequence match: "g46" finds "GLM-4.6". An empty needle
/// matches everything, so an untouched filter never hides a route.
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

test "offers sharing a visible name stay distinct routes" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("zai", "cn-anthropic", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "anthropic_messages"),
        fixtureOffer("zai", "cn-openai", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "openai_chat"),
        fixtureOffer("zai", "global-openai", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);

    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectEqual(@as(usize, 1), (try picker.rows(&scratch)).len);
    _ = picker.onKey(.enter); // provider

    const model_rows = (try picker.rows(&scratch));
    try testing.expectEqual(@as(usize, 1), model_rows.len);
    // One name, three routes. Collapsing them here is the failure this whole
    // grouping rule exists to prevent.
    try testing.expectEqual(@as(usize, 3), model_rows[0].model.offer_count);

    _ = picker.onKey(.enter); // model → offer stage, not a commit
    try testing.expectEqual(Stage.offer, picker.stage);
    try testing.expectEqual(@as(usize, 3), (try picker.rows(&scratch)).len);
}

test "providers whose ids have the same length stay separate rows" {
    // metask, openai and gemini are all six bytes: the compiled catalog once
    // showed one "metask 16 models" row, and Enter on it listed only metask's
    // models, so the other two providers could not be chosen at all.
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
        fixtureOffer("metask", "default", "Claude Opus 4.5", "anthropic/claude-opus-4-5", "claude-opus-4-5", "anthropic_messages"),
        fixtureOffer("openai", "default", "GPT-4o", null, "gpt-4o", "openai_chat"),
        fixtureOffer("openai", "default", "o3", null, "o3", "openai_chat"),
        fixtureOffer("openai", "default", "GPT-4o mini", null, "gpt-4o-mini", "openai_chat"),
        fixtureOffer("gemini", "default", "Gemini 2.5 Pro", null, "gemini-2.5-pro", "gemini_generate"),
    };
    try loadFixture(&picker, &offers, null);

    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    const provider_rows = (try picker.rows(&scratch));
    try testing.expectEqual(@as(usize, 3), provider_rows.len);
    const expected = [_]struct { id: []const u8, count: usize }{
        .{ .id = "metask", .count = 2 },
        .{ .id = "openai", .count = 3 },
        .{ .id = "gemini", .count = 1 },
    };
    for (provider_rows, expected) |row, want| {
        try testing.expectEqualStrings(want.id, picker.offers.items[row.provider.offer_index].provider_id.slice());
        // The label outlives the call that built it: it is what the next
        // offer is grouped against, and what a caller reads afterwards.
        try testing.expectEqualStrings(want.id, row.provider.label);
        try testing.expectEqual(want.count, row.provider.offer_count);
    }

    // Enter on the second row reaches openai's models, not metask's.
    _ = picker.onKey(.down);
    _ = picker.onKey(.enter);
    try testing.expectEqual(Stage.model, picker.stage);
    const model_rows = (try picker.rows(&scratch));
    try testing.expectEqual(@as(usize, 3), model_rows.len);
    for (model_rows) |row| {
        try testing.expectEqualStrings("openai", picker.offers.items[row.model.offer_index].provider_id.slice());
    }
}

test "a stage lists every model however large the catalog, and Home/End reach both ends" {
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
    _ = picker.onKey(.enter); // provider
    picker.page_rows = 8;

    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    const model_rows = try picker.rows(&scratch);
    try testing.expectEqual(@as(usize, count), model_rows.len);
    try testing.expectEqualStrings("m-300", model_rows[count - 1].model.label);

    try testing.expect(picker.onKey(.end) == .redraw);
    try testing.expectEqual(@as(usize, count - 1), picker.cursor);
    try testing.expectEqual(@as(usize, count - 8), picker.window_top);
    try testing.expect(picker.onKey(.home) == .redraw);
    try testing.expectEqual(@as(usize, 0), picker.cursor);
    try testing.expectEqual(@as(usize, 0), picker.window_top);
    // Up from the first row wraps to the last, not to the 256th.
    _ = picker.onKey(.up);
    try testing.expectEqual(@as(usize, count - 1), picker.cursor);
    // And Enter on it commits the 300th model.
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome == .commit);
    try testing.expect(outcome.commit.offer_id.eql(offers[count - 1].offer_id));
}

test "a model with one route skips the channel step and commits" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);

    _ = picker.onKey(.enter); // provider
    const outcome = picker.onKey(.enter); // model — one offer, so straight to commit
    try testing.expect(outcome == .commit);
    try testing.expect(outcome.commit.offer_id.eql(offers[0].offer_id));
    // Session is the default; nothing was typed to choose it.
    try testing.expectEqual(Scope.session, outcome.commit.scope);
}

test "scope is session unless the user explicitly cycles it" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);

    try testing.expectEqual(Scope.session, picker.scope);
    _ = picker.onKey(.cycle_scope);
    try testing.expectEqual(Scope.global, picker.scope);
    _ = picker.onKey(.cycle_scope);
    try testing.expectEqual(Scope.once, picker.scope);
    _ = picker.onKey(.cycle_scope);
    try testing.expectEqual(Scope.session, picker.scope);

    _ = picker.onKey(.cycle_scope); // global
    _ = picker.onKey(.enter);
    const outcome = picker.onKey(.enter);
    try testing.expectEqual(Scope.global, outcome.commit.scope);
}

test "the filter is a subsequence match and Esc clears it before walking back" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("zai", "cn-anthropic", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "anthropic_messages"),
        fixtureOffer("zai", "cn-anthropic", "GLM-4.5-Air", "zai/glm-4.5-air", "glm-4.5-air", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter); // provider

    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectEqual(@as(usize, 2), (try picker.rows(&scratch)).len);

    for ("g46") |byte| _ = picker.onKey(.{ .char = byte });
    try testing.expectEqualStrings("g46", picker.filter());
    try testing.expectEqual(@as(usize, 1), (try picker.rows(&scratch)).len);

    // Esc clears the filter first; it does not jump back a stage and lose the
    // provider the user already chose.
    _ = picker.onKey(.escape);
    try testing.expectEqual(@as(usize, 0), picker.filter_len);
    try testing.expectEqual(Stage.model, picker.stage);

    _ = picker.onKey(.escape);
    try testing.expectEqual(Stage.provider, picker.stage);
    try testing.expect(picker.onKey(.escape) == .closed);
}

test "q types into a non-empty filter and closes only when the filter is empty" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("qwen", "default", "Qwen Max", "qwen/qwen-max", "qwen-max", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);

    _ = picker.onKey(.{ .char = 'w' });
    try testing.expect(picker.onKey(.{ .char = 'q' }) == .redraw);
    try testing.expectEqualStrings("wq", picker.filter());

    picker.restart();
    try testing.expect(picker.onKey(.{ .char = 'q' }) == .closed);
}

test "navigation wraps, pages, and keeps the cursor inside the window" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offers: [40]OfferSummary = undefined;
    var names: [40][8]u8 = undefined;
    for (&offers, 0..) |*slot, index| {
        names[index] = undefined;
        const text = std.fmt.bufPrint(&names[index], "m{d:0>2}", .{index}) catch unreachable;
        slot.* = fixtureOffer("metask", "default", text, text, text, "anthropic_messages");
    }
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter);
    picker.page_rows = 10;

    try testing.expectEqual(@as(usize, 40), picker.rowCount());
    _ = picker.onKey(.up); // wraps to the last row
    try testing.expectEqual(@as(usize, 39), picker.cursor);
    try testing.expect(picker.cursor >= picker.window_top);
    try testing.expect(picker.cursor < picker.window_top + picker.page_rows);

    _ = picker.onKey(.down); // wraps back to the first
    try testing.expectEqual(@as(usize, 0), picker.cursor);
    try testing.expectEqual(@as(usize, 0), picker.window_top);

    _ = picker.onKey(.page_down);
    try testing.expectEqual(@as(usize, 10), picker.cursor);
    try testing.expect(picker.cursor < picker.window_top + picker.page_rows);
    _ = picker.onKey(.page_up);
    try testing.expectEqual(@as(usize, 0), picker.cursor);
}

test "a smaller terminal reflows the window instead of stranding the cursor" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offers: [30]OfferSummary = undefined;
    var names: [30][8]u8 = undefined;
    for (&offers, 0..) |*slot, index| {
        const text = std.fmt.bufPrint(&names[index], "m{d:0>2}", .{index}) catch unreachable;
        slot.* = fixtureOffer("metask", "default", text, text, text, "anthropic_messages");
    }
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter);
    picker.page_rows = 12;
    for (0..20) |_| _ = picker.onKey(.down);
    try testing.expectEqual(@as(usize, 20), picker.cursor);

    // The terminal shrinks: the same cursor must still be on screen.
    picker.page_rows = 4;
    _ = picker.onKey(.down);
    try testing.expect(picker.cursor >= picker.window_top);
    try testing.expect(picker.cursor < picker.window_top + picker.page_rows);
}

test "the current selection is marked through its group" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
        fixtureOffer("zai", "cn-anthropic", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, offers[1].offer_id);

    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    const provider_rows = (try picker.rows(&scratch));
    try testing.expectEqual(@as(usize, 2), provider_rows.len);
    try testing.expect(!provider_rows[0].provider.is_current);
    try testing.expect(provider_rows[1].provider.is_current);
}

test "a stale snapshot keeps its rows and says it is stale" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    try testing.expectEqual(Status.ready, picker.status);

    picker.markStale();
    try testing.expectEqual(Status.stale, picker.status);
    // Still usable: a blank list would be a worse answer than an old one that
    // says so.
    try testing.expectEqual(@as(usize, 1), picker.rowCount());

    picker.markFailed();
    try testing.expectEqual(Status.failed, picker.status);
}

test "controls cycle through the provider vocabulary and end unset" {
    const specs = [_]controls_mod.ControlSpec{.{
        .id = "reasoning_effort",
        .label = "Reasoning",
        .kind = .enumeration,
        .allowed_values = &.{ "low", "high" },
    }};
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    offers[0].controls = &specs;
    try loadFixture(&picker, &offers, null);

    _ = picker.onKey(.enter); // provider
    _ = picker.onKey(.enter); // model — one offer, but it declares controls
    try testing.expectEqual(Stage.options, picker.stage);
    try testing.expectEqual(@as(usize, 1), picker.rowCount());

    _ = picker.onKey(.right);
    try testing.expect(picker.controls.get("reasoning_effort").?.text.eqlText("low"));
    _ = picker.onKey(.right);
    try testing.expect(picker.controls.get("reasoning_effort").?.text.eqlText("high"));
    _ = picker.onKey(.right);
    // Past the last declared value is "unset", not an invented one.
    try testing.expect(picker.controls.get("reasoning_effort") == null);
    // ← walks the same cycle backwards.
    _ = picker.onKey(.left);
    try testing.expect(picker.controls.get("reasoning_effort").?.text.eqlText("high"));
    _ = picker.onKey(.left);
    try testing.expect(picker.controls.get("reasoning_effort").?.text.eqlText("low"));

    // Enter applies the route with the value shown.
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome == .commit);
    try testing.expect(outcome.commit.controls.get("reasoning_effort").?.text.eqlText("low"));
}

test "an offer's controls start at the value the session already runs with" {
    const specs = [_]controls_mod.ControlSpec{.{
        .id = "reasoning_effort",
        .label = "Reasoning",
        .kind = .enumeration,
        .allowed_values = &.{ "low", "high", "max" },
    }};
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offers = [_]OfferSummary{
        fixtureOffer("zai-coding-plan", "cn-anthropic", "GLM-5.3", "zai/glm-5.3", "glm-5.3", "anthropic_messages"),
    };
    offers[0].controls = &specs;
    try loadFixture(&picker, &offers, null);

    picker.presetControl("reasoning_effort", "high");
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter);
    try testing.expectEqual(Stage.options, picker.stage);
    try testing.expect(picker.controls.get("reasoning_effort").?.text.eqlText("high"));
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome.commit.controls.get("reasoning_effort").?.text.eqlText("high"));

    // A preset outside the vocabulary starts unset rather than sending a
    // value the route refuses.
    picker.restart();
    picker.presetControl("reasoning_effort", "medium");
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter);
    try testing.expect(picker.controls.get("reasoning_effort") == null);
}

test "a control the provider did not enumerate cannot be edited from the picker" {
    const specs = [_]controls_mod.ControlSpec{.{
        .id = "temperature",
        .label = "Temperature",
        .kind = .range,
        .range = .{ .min = 0, .max = 2 },
    }};
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    offers[0].controls = &specs;
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter);
    try testing.expectEqual(Stage.options, picker.stage);
    // The kernel owns no control vocabulary, and neither does the picker.
    try testing.expect(picker.onKey(.right) == .ignored);
    try testing.expectEqual(@as(u8, 0), picker.controls.len);
    // Enter still applies the route, without a value for the control.
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome == .commit);
    try testing.expectEqual(@as(u8, 0), outcome.commit.controls.len);
}

test "backing out of options returns to the stage the user actually saw" {
    const specs = [_]controls_mod.ControlSpec{.{
        .id = "reasoning_effort",
        .label = "Reasoning",
        .kind = .enumeration,
        .allowed_values = &.{"low"},
    }};
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    var offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    offers[0].controls = &specs;
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter);
    try testing.expectEqual(Stage.options, picker.stage);

    // The offer stage was skipped on the way in (one route), so going back
    // must not drop the user into a list of one they cannot leave.
    _ = picker.onKey(.escape);
    try testing.expectEqual(Stage.model, picker.stage);
}

test "fuzzy matching is case-insensitive and an empty needle hides nothing" {
    try testing.expect(matches("", "anything"));
    try testing.expect(matches("g46", "GLM-4.6"));
    try testing.expect(matches("GLM", "glm-4.5-air"));
    try testing.expect(!matches("gpt", "GLM-4.6"));
    try testing.expect(!matches("64", "GLM-4.6"));
}

test "a refresh that removes the chosen offer steps back instead of dead-ending" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const specs = [_]controls_mod.ControlSpec{.{
        .id = "reasoning_effort",
        .label = "Reasoning",
        .kind = .enumeration,
        .allowed_values = &.{"low"},
    }};
    var offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
        fixtureOffer("metask", "default", "Claude Sonnet 4.6", "anthropic/claude-sonnet-4-6", "claude-sonnet-4-6", "anthropic_messages"),
    };
    offers[0].controls = &specs;
    try loadFixture(&picker, &offers, null);

    _ = picker.onKey(.enter); // provider
    _ = picker.onKey(.enter); // model → options (one offer, declares a control)
    try testing.expectEqual(Stage.options, picker.stage);
    try testing.expect(picker.offer_id != null);

    // The catalog refreshes and that offer is gone.
    try loadFixture(&picker, offers[1..], null);

    // Without the step-back the options stage renders nothing and Enter is a
    // no-op — the user presses it and the picker simply does not respond.
    try testing.expectEqual(Stage.model, picker.stage);
    try testing.expect(picker.offer_id == null);
    try testing.expectEqual(@as(u8, 0), picker.controls.len);
    try testing.expect(std.mem.indexOf(u8, picker.notice(), "no longer offered") != null);
    // And the stage it landed on is usable.
    try testing.expect(picker.rowCount() > 0);
}

test "a refresh that keeps the chosen offer leaves the draft alone" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("zai", "cn-anthropic", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "anthropic_messages"),
        fixtureOffer("zai", "cn-openai", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter); // provider
    _ = picker.onKey(.enter); // model → offer stage
    _ = picker.onKey(.down);
    _ = picker.onKey(.enter); // pick the second channel
    const chosen = picker.offer_id.?;

    // Same offers, new revision: a refresh must not throw away a draft that is
    // still valid.
    try loadFixture(&picker, &offers, null);
    try testing.expect(picker.offer_id.?.eql(chosen));
    try testing.expectEqual(@as(usize, 0), picker.notice_len);
}

test "the provider stage is searchable by what a provider serves" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
        fixtureOffer("zai-coding-plan", "cn-anthropic", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "anthropic_messages"),
        fixtureOffer("zai-coding-plan", "cn-openai", "GLM-4.6", "zai/glm-4.6", "glm-4.6", "openai_chat"),
    };
    try loadFixture(&picker, &offers, null);

    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectEqual(@as(usize, 2), (try picker.rows(&scratch)).len);

    // "glm" names no provider, but it is what the user is looking for — and
    // the provider stage is the one where they know least.
    for ("glm") |byte| _ = picker.onKey(.{ .char = byte });
    const filtered = (try picker.rows(&scratch));
    try testing.expectEqual(@as(usize, 1), filtered.len);
    try testing.expect(picker.offers.items[filtered[0].provider.offer_index].provider_id.eqlText("zai-coding-plan"));
    // The count reflects the offers that matched, so the row does not promise
    // routes the filter has hidden.
    try testing.expectEqual(@as(usize, 2), filtered[0].provider.offer_count);

    // Filtering by provider id still works.
    picker.restart();
    for ("metask") |byte| _ = picker.onKey(.{ .char = byte });
    try testing.expectEqual(@as(usize, 1), (try picker.rows(&scratch)).len);
}

/// The offers of `fixtureOffer`'s three providers: metask (two models),
/// kimi (one model on two channels), deepseek (one model).
fn readinessFixture() [5]OfferSummary {
    return .{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
        fixtureOffer("kimi", "cn-openai", "Kimi K3", "moonshotai/kimi-k3", "kimi-k3", "openai_chat"),
        fixtureOffer("kimi", "cn-anthropic", "Kimi K3", "moonshotai/kimi-k3", "kimi-k3", "anthropic_messages"),
        fixtureOffer("metask", "default", "Claude Sonnet 4.6", "anthropic/claude-sonnet-4-6", "claude-sonnet-4-6", "anthropic_messages"),
        fixtureOffer("deepseek", "openai", "DeepSeek V4 Pro", "deepseek/deepseek-v4-pro", "deepseek-v4-pro", "openai_chat"),
    };
}

/// A provider row as (id, ready, offer count).
const ProviderLine = struct { []const u8, bool, usize };

/// The provider rows in display order, into `out`.
fn providerSummary(picker: *const Picker, scratch: *Picker.RowBuffer, out: []ProviderLine) ![]const ProviderLine {
    const listed = try picker.rows(scratch);
    for (listed, 0..) |row, index| out[index] = .{ row.provider.label, row.provider.ready, row.provider.offer_count };
    return out[0..listed.len];
}

test "providers with no ready offer sit last, as the not-configured group, and their offers are not listed (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = readinessFixture();
    try loadFixture(&picker, &offers, null);
    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    var lines: [8]ProviderLine = undefined;

    // No verdict yet: everything is listed, in catalog order.
    const before = try providerSummary(&picker, &scratch, &lines);
    try testing.expectEqual(@as(usize, 3), before.len);
    try testing.expectEqualStrings("kimi", before[1][0]);

    // Kimi has no key; the second Metask model has no credential either (an
    // offer pinned to a pool member that is gone).
    try picker.setReadiness(&.{ true, false, false, false, true }, &.{
        .{ .provider = Slug.lit("kimi"), .variable = "MOONSHOT_API_KEY" },
    });
    const after = try providerSummary(&picker, &scratch, &lines);
    try testing.expectEqual(@as(usize, 3), after.len);
    try testing.expectEqualStrings("metask", after[0][0]);
    try testing.expect(after[0][1]);
    // Only the offer a commit can use is counted.
    try testing.expectEqual(@as(usize, 1), after[0][2]);
    try testing.expectEqualStrings("deepseek", after[1][0]);
    try testing.expect(after[1][1]);
    try testing.expectEqualStrings("kimi", after[2][0]);
    try testing.expect(!after[2][1]);
    try testing.expectEqual(@as(usize, 2), after[2][2]);

    // Into Metask: the model without a credential is not there.
    _ = picker.onKey(.enter);
    try testing.expectEqual(Stage.model, picker.stage);
    const models = try picker.rows(&scratch);
    try testing.expectEqual(@as(usize, 1), models.len);
    try testing.expectEqualStrings("anthropic/claude-opus-4-6", models[0].model.label);

    // A filter that matches only the not-configured provider still finds it.
    picker.restart();
    for ("kimi") |byte| _ = picker.onKey(.{ .char = byte });
    const filtered = try providerSummary(&picker, &scratch, &lines);
    try testing.expectEqual(@as(usize, 1), filtered.len);
    try testing.expect(!filtered[0][1]);
}

test "Enter on a not-configured provider shows its setup, starts nothing, and Esc returns to the same row (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = readinessFixture();
    try loadFixture(&picker, &offers, null);
    try picker.setReadiness(&.{ true, false, false, true, true }, &.{
        .{ .provider = Slug.lit("kimi"), .variable = "MOONSHOT_API_KEY" },
    });
    picker.setLocalConfig("/state/.env", "https://example.test/guide");

    _ = picker.onKey(.end); // the last row: kimi, not configured
    try testing.expectEqual(@as(usize, 2), picker.cursor);
    try testing.expect(picker.onKey(.enter) == .redraw);
    try testing.expectEqual(Stage.setup, picker.stage);
    const shown = picker.setup orelse return error.NoSetup;
    try testing.expect(shown.provider.eqlText("kimi"));
    try testing.expectEqualStrings("MOONSHOT_API_KEY", shown.variable.?);
    try testing.expectEqualStrings("/state/.env", picker.localConfigPath());

    // Nothing in the setup stage commits, signs in or takes a key.
    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectEqual(@as(usize, 0), (try picker.rows(&scratch)).len);
    for ([_]Key{ .enter, .down, .up, .cycle_scope, .backspace, .left, .right, .{ .char = 'x' } }) |key| {
        try testing.expect(picker.onKey(key) == .ignored);
    }
    try testing.expectEqual(Stage.setup, picker.stage);

    try testing.expect(picker.onKey(.escape) == .redraw);
    try testing.expectEqual(Stage.provider, picker.stage);
    try testing.expectEqual(@as(usize, 2), picker.cursor);
    try testing.expect(picker.setup == null);

    // q closes from the setup stage, as from a list with no filter.
    _ = picker.onKey(.enter);
    try testing.expect(picker.onKey(.{ .char = 'q' }) == .closed);
}

test "a setup opened under a filter returns to the filtered list" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = readinessFixture();
    try loadFixture(&picker, &offers, null);
    try picker.setReadiness(&.{ true, false, false, true, true }, &.{});
    for ("kimi") |byte| _ = picker.onKey(.{ .char = byte });
    _ = picker.onKey(.enter);
    try testing.expectEqual(Stage.setup, picker.stage);
    // A provider the host described no setup for still gets its own name.
    try testing.expect(picker.setup.?.provider.eqlText("kimi"));
    try testing.expect(picker.setup.?.variable == null);
    _ = picker.onKey(.escape);
    try testing.expectEqualStrings("kimi", picker.filter());
    try testing.expectEqual(Stage.provider, picker.stage);
}

test "a commit the host found no credential for shows the setup, and Esc returns to the draft (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = readinessFixture();
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.down); // kimi, ready until the commit finds otherwise
    _ = picker.onKey(.enter);
    _ = picker.onKey(.enter); // Kimi K3 → two channels
    try testing.expectEqual(Stage.offer, picker.stage);
    try testing.expect(picker.onKey(.enter) == .commit);

    picker.setNotice("kimi has no key; the previous route is still active", .{});
    picker.enterSetup(.{ .provider = Slug.lit("kimi"), .variable = "MOONSHOT_API_KEY" });
    try testing.expectEqual(Stage.setup, picker.stage);
    try testing.expect(picker.notice_len > 0);
    _ = picker.onKey(.escape);
    try testing.expectEqual(Stage.offer, picker.stage);
    try testing.expectEqual(@as(usize, 0), picker.notice_len);
}

test "a refresh that leaves the draft's provider with no ready offer steps back to the providers (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = readinessFixture();
    try loadFixture(&picker, &offers, null);
    try picker.setReadiness(&.{ true, true, true, true, true }, &.{});
    _ = picker.onKey(.down);
    _ = picker.onKey(.enter); // kimi
    _ = picker.onKey(.enter); // Kimi K3 → offer stage
    try testing.expectEqual(Stage.offer, picker.stage);

    try loadFixture(&picker, &offers, null);
    try picker.setReadiness(&.{ true, false, false, true, true }, &.{});
    try testing.expectEqual(Stage.provider, picker.stage);
    try testing.expect(picker.provider == null);
    try testing.expect(std.mem.indexOf(u8, picker.notice(), "kimi has no usable route now") != null);
    try testing.expect(picker.rowCount() > 0);
}

test "a refresh that takes the credential of the chosen offer only steps back to its models (#488)" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = readinessFixture();
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.down);
    _ = picker.onKey(.enter); // kimi
    _ = picker.onKey(.enter); // Kimi K3 → offer stage
    _ = picker.onKey(.down);
    _ = picker.onKey(.enter); // the cn-anthropic channel: a commit
    try testing.expect(picker.offer_id.?.eql(offers[2].offer_id));

    try picker.setReadiness(&.{ true, true, false, true, true }, &.{});
    try testing.expectEqual(Stage.model, picker.stage);
    try testing.expect(picker.offer_id == null);
    try testing.expect(std.mem.indexOf(u8, picker.notice(), "no longer offered") != null);
}
