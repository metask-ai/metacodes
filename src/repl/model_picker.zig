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

pub const Stage = enum { provider, model, offer, options };

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

    /// One line of feedback from the last commit attempt. Bounded and owned by
    /// the picker so the host never has to keep a matching allocation alive.
    notice_buffer: [160]u8 = undefined,
    notice_len: usize = 0,

    provider: ?Slug = null,
    group_key_buffer: [MAX_GROUP_KEY]u8 = undefined,
    group_key_len: usize = 0,
    offer_id: ?OfferId = null,
    controls: controls_mod.ControlValues = .{},
    scope: Scope = .session,

    pub fn init(allocator: std.mem.Allocator) Picker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Picker) void {
        self.offers.deinit(self.allocator);
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
        self.catalog_revision = page.meta.catalog_revision;
        self.config_revision = page.meta.config_revision;
        self.current_offer = current_offer;
        self.status = if (self.offers.items.len == 0) .empty else .ready;

        // A refresh can remove the offer a half-finished draft was built on:
        // the options stage would then render nothing and Enter would silently
        // do nothing, because there is no offer left to commit. Step back to
        // where a choice is still possible and say why.
        if (self.offer_id != null and self.currentOfferIndex() == null) {
            self.offer_id = null;
            self.controls = .{};
            if (self.stage == .options or self.stage == .offer) self.stage = .model;
            self.cursor = 0;
            self.window_top = 0;
            self.setNotice("that route is no longer offered; pick another", .{});
        }
        self.clampCursor();
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
        self.scope = .session;
    }

    // ── row construction ────────────────────────────────────────────────────

    /// Fill `out` with the rows of the current stage. Returns the used prefix.
    /// Rows are recomputed rather than cached: the filter changes them on every
    /// keystroke, and a cache that missed one keystroke would highlight a row
    /// the user is not looking at.
    pub fn rows(self: *const Picker, out: []Row) []const Row {
        return switch (self.stage) {
            .provider => self.providerRows(out),
            .model => self.modelRows(out),
            .offer => self.offerRows(out),
            .options => self.controlRows(out),
        };
    }

    pub fn rowCount(self: *const Picker) usize {
        var scratch: [MAX_ROWS]Row = undefined;
        return self.rows(&scratch).len;
    }

    /// Upper bound for a stage's row count. Sized to the largest catalog the
    /// kernel will page out at once.
    pub const MAX_ROWS: usize = 256;

    fn providerRows(self: *const Picker, out: []Row) []const Row {
        var len: usize = 0;
        for (self.offers.items, 0..) |offer, index| {
            const label = offer.provider_id.slice();
            if (!matches(self.filter(), label)) continue;
            if (findGroup(out[0..len], label, self)) |existing| {
                bumpGroup(&out[existing], index, self.isCurrent(offer));
                continue;
            }
            if (len == out.len) break;
            out[len] = .{ .provider = .{
                .offer_index = index,
                .offer_count = 1,
                .label = label,
                .is_current = self.isCurrent(offer),
            } };
            len += 1;
        }
        return out[0..len];
    }

    fn modelRows(self: *const Picker, out: []Row) []const Row {
        const wanted = self.provider orelse return out[0..0];
        var len: usize = 0;
        for (self.offers.items, 0..) |offer, index| {
            if (!offer.provider_id.eql(wanted)) continue;
            const key = canonicalKey(offer);
            if (!matches(self.filter(), offer.display_name) and
                !matches(self.filter(), key) and
                !matches(self.filter(), offer.request_model_id)) continue;
            if (findGroupByKey(out[0..len], key, self)) |existing| {
                bumpGroup(&out[existing], index, self.isCurrent(offer));
                continue;
            }
            if (len == out.len) break;
            out[len] = .{ .model = .{
                .offer_index = index,
                .offer_count = 1,
                .label = key,
                .is_current = self.isCurrent(offer),
            } };
            len += 1;
        }
        return out[0..len];
    }

    fn offerRows(self: *const Picker, out: []Row) []const Row {
        const wanted = self.provider orelse return out[0..0];
        const key = self.groupKey();
        var len: usize = 0;
        for (self.offers.items, 0..) |offer, index| {
            if (!offer.provider_id.eql(wanted)) continue;
            if (!std.mem.eql(u8, canonicalKey(offer), key)) continue;
            // Deliberately no filter on this stage: it exists precisely to show
            // every route behind one visible name, and a filter over names
            // would hide the ones that share it.
            if (len == out.len) break;
            out[len] = .{ .offer = .{ .offer_index = index, .is_current = self.isCurrent(offer) } };
            len += 1;
        }
        return out[0..len];
    }

    fn controlRows(self: *const Picker, out: []Row) []const Row {
        const index = self.currentOfferIndex() orelse return out[0..0];
        const specs = self.offers.items[index].controls;
        var len: usize = 0;
        for (specs, 0..) |_, spec_index| {
            if (len == out.len) break;
            out[len] = .{ .control = .{ .spec_index = spec_index, .offer_index = index } };
            len += 1;
        }
        return out[0..len];
    }

    fn currentOfferIndex(self: *const Picker) ?usize {
        const wanted = self.offer_id orelse return null;
        for (self.offers.items, 0..) |offer, index| {
            if (offer.offer_id.eql(wanted)) return index;
        }
        return null;
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
        var scratch: [MAX_ROWS]Row = undefined;
        const visible = self.rows(&scratch);
        switch (key) {
            .up => return self.move(visible.len, false),
            .down => return self.move(visible.len, true),
            .page_up => return self.pageMove(visible.len, false),
            .page_down => return self.pageMove(visible.len, true),
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
        }
        self.cursor = 0;
        self.window_top = 0;
        return .redraw;
    }

    fn offerCountForGroup(self: *const Picker) usize {
        var scratch: [MAX_ROWS]Row = undefined;
        var probe = self.*;
        probe.stage = .offer;
        probe.filter_len = 0;
        return probe.offerRows(&scratch).len;
    }

    fn advance(self: *Picker, visible: []const Row) Outcome {
        if (visible.len == 0) return .ignored;
        const row = visible[@min(self.cursor, visible.len - 1)];
        switch (row) {
            .provider => |group| {
                self.provider = self.offers.items[group.offer_index].provider_id;
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
            .control => return self.cycleControl(row.control),
        }
    }

    fn afterOfferChosen(self: *Picker) Outcome {
        const offer = self.selectedOffer() orelse return .ignored;
        if (offer.controls.len == 0) return self.commitNow();
        self.stage = .options;
        return .redraw;
    }

    /// Enter on a control cycles its value through the provider's declared
    /// vocabulary, ending on "unset". Nothing here invents a value: a control
    /// with no `allowed_values` cannot be edited from the picker at all.
    fn cycleControl(self: *Picker, row: anytype) Outcome {
        const offer = self.offers.items[row.offer_index];
        if (row.spec_index >= offer.controls.len) return .ignored;
        const spec = offer.controls[row.spec_index];
        if (spec.kind != .enumeration or spec.allowed_values.len == 0) return .ignored;

        const current = self.controls.get(spec.id);
        var next_index: ?usize = 0;
        if (current) |value| {
            next_index = null;
            for (spec.allowed_values, 0..) |candidate, index| {
                if (value == .text and value.text.eqlText(candidate)) {
                    next_index = if (index + 1 < spec.allowed_values.len) index + 1 else null;
                    break;
                }
            }
        }
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

    var scratch: [Picker.MAX_ROWS]Row = undefined;
    try testing.expectEqual(@as(usize, 1), picker.rows(&scratch).len);
    _ = picker.onKey(.enter); // provider

    const model_rows = picker.rows(&scratch);
    try testing.expectEqual(@as(usize, 1), model_rows.len);
    // One name, three routes. Collapsing them here is the failure this whole
    // grouping rule exists to prevent.
    try testing.expectEqual(@as(usize, 3), model_rows[0].model.offer_count);

    _ = picker.onKey(.enter); // model → offer stage, not a commit
    try testing.expectEqual(Stage.offer, picker.stage);
    try testing.expectEqual(@as(usize, 3), picker.rows(&scratch).len);
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

    var scratch: [Picker.MAX_ROWS]Row = undefined;
    try testing.expectEqual(@as(usize, 2), picker.rows(&scratch).len);

    for ("g46") |byte| _ = picker.onKey(.{ .char = byte });
    try testing.expectEqualStrings("g46", picker.filter());
    try testing.expectEqual(@as(usize, 1), picker.rows(&scratch).len);

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

    var scratch: [Picker.MAX_ROWS]Row = undefined;
    const provider_rows = picker.rows(&scratch);
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

    _ = picker.onKey(.enter);
    try testing.expect(picker.controls.get("reasoning_effort").?.text.eqlText("low"));
    _ = picker.onKey(.enter);
    try testing.expect(picker.controls.get("reasoning_effort").?.text.eqlText("high"));
    _ = picker.onKey(.enter);
    // Past the last declared value is "unset", not an invented one.
    try testing.expect(picker.controls.get("reasoning_effort") == null);

    _ = picker.onKey(.enter);
    const outcome = picker.commitNow();
    try testing.expect(outcome == .commit);
    try testing.expect(outcome.commit.controls.get("reasoning_effort").?.text.eqlText("low"));
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
    try testing.expect(picker.onKey(.enter) == .ignored);
    try testing.expectEqual(@as(u8, 0), picker.controls.len);
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
