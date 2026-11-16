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

pub const Stage = enum { provider, model, offer, options, credential };

/// What the credential stage can show of the flow's transcript.
pub const MAX_CREDENTIAL_LINES: usize = 512;

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
    /// The commit needs a credential the provider can be signed in for:
    /// the host starts that login and the picker shows it (#67).
    login: Slug,
    /// Esc in the credential stage: the host aborts the running login.
    cancel_login,
    /// Enter on a pasted key (`credential_mode == .paste_key`): the host checks
    /// and stores `keyText()` for `credential_provider`, then retries the
    /// pending commit.
    submit_key,
    /// Tab on the key step: the host opens the chosen key page.
    open_key_page,
};

/// A page an API key is created on, as the credential stage shows it. The
/// host maps its provider's key pages to these; the strings are borrowed from
/// the provider registry for as long as the stage is shown.
pub const KeyChoice = struct {
    label: []const u8,
    url: []const u8,
};

pub const MAX_KEY_CHOICES: usize = 8;
pub const MAX_KEY_LEN: usize = 512;

/// What the credential stage is doing: following an OAuth sign-in, or taking
/// a pasted API key for a provider that has no OAuth grant.
pub const CredentialMode = enum { sign_in, paste_key };

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
    /// The credential stage (#67): the commit that wanted a credential, the
    /// provider being signed in to, where Esc returns, and the flow's
    /// transcript (a bounded copy the host refreshes on its idle tick).
    pending_commit: ?Commit = null,
    credential_provider: ?Slug = null,
    credential_return_stage: Stage = .model,
    credential_failed: bool = false,
    credential_lines: [MAX_CREDENTIAL_LINES]u8 = undefined,
    credential_lines_len: usize = 0,
    credential_mode: CredentialMode = .sign_in,
    key_choices: [MAX_KEY_CHOICES]KeyChoice = undefined,
    key_choice_count: usize = 0,
    key_choice: usize = 0,
    /// What the provider asks the user to know before creating a key.
    key_note: ?[]const u8 = null,
    key_buffer: [MAX_KEY_LEN]u8 = undefined,
    key_len: usize = 0,
    /// The pasted key is being checked; typing waits for the answer.
    key_checking: bool = false,

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
        self.preset_controls = .{};
        self.scope = .session;
        self.pending_commit = null;
        self.credential_provider = null;
        self.credential_return_stage = .model;
        self.credential_failed = false;
        self.credential_lines_len = 0;
        self.leaveKeyMode();
    }

    /// A commit that needs an API key the provider has no OAuth grant for:
    /// show its key pages and take the pasted key in place of the list. The
    /// choices are copied (at most `MAX_KEY_CHOICES`); their strings are
    /// borrowed.
    pub fn enterKeyStage(
        self: *Picker,
        provider: Slug,
        commit: Commit,
        choices: []const KeyChoice,
        default_choice: usize,
        note: ?[]const u8,
    ) Outcome {
        _ = self.enterCredentialStage(provider, commit);
        self.credential_mode = .paste_key;
        self.key_choice_count = @min(choices.len, MAX_KEY_CHOICES);
        @memcpy(self.key_choices[0..self.key_choice_count], choices[0..self.key_choice_count]);
        self.key_choice = @min(default_choice, self.key_choice_count -| 1);
        self.key_note = note;
        self.clearKey();
        return .redraw;
    }

    pub fn keyText(self: *const Picker) []const u8 {
        return self.key_buffer[0..self.key_len];
    }

    pub fn keyChoices(self: *const Picker) []const KeyChoice {
        return self.key_choices[0..self.key_choice_count];
    }

    /// The key is handed to the host (which copies it); the field is wiped.
    pub fn clearKey(self: *Picker) void {
        std.crypto.secureZero(u8, self.key_buffer[0..self.key_len]);
        self.key_len = 0;
    }

    fn leaveKeyMode(self: *Picker) void {
        self.clearKey();
        self.credential_mode = .sign_in;
        self.key_choice_count = 0;
        self.key_choice = 0;
        self.key_note = null;
        self.key_checking = false;
    }

    /// Keys on the paste-a-key step.
    fn onKeyStep(self: *Picker, key: Key) Outcome {
        if (key == .escape) return self.back();
        // While the key is being checked, only Esc (above) does anything.
        if (self.key_checking) return .ignored;
        switch (key) {
            .up, .down => {
                if (self.key_choice_count == 0) return .ignored;
                self.key_choice = if (key == .down)
                    (self.key_choice + 1) % self.key_choice_count
                else if (self.key_choice == 0) self.key_choice_count - 1 else self.key_choice - 1;
                return .redraw;
            },
            .cycle_scope => return if (self.key_choice_count == 0) .ignored else .open_key_page,
            .backspace => {
                if (self.key_len == 0) return .ignored;
                self.key_len -= 1;
                self.key_buffer[self.key_len] = 0;
                return .redraw;
            },
            .char => |byte| {
                // A paste arrives as characters; whitespace and controls a
                // terminal adds around it are not part of a key.
                if (byte <= ' ' or byte == 0x7f) return .ignored;
                if (self.key_len == self.key_buffer.len) return .ignored;
                if (self.credential_failed) {
                    // A new attempt after a refused key starts clean.
                    self.credential_failed = false;
                    self.notice_len = 0;
                    self.credential_lines_len = 0;
                }
                self.key_buffer[self.key_len] = byte;
                self.key_len += 1;
                return .redraw;
            },
            .enter => {
                if (self.key_len == 0) return .ignored;
                return .submit_key;
            },
            else => return .ignored,
        }
    }

    /// The host started checking the key: show the check, not the field.
    pub fn keySubmitted(self: *Picker) void {
        self.clearKey();
        self.key_checking = true;
        self.credential_failed = false;
        self.credential_lines_len = 0;
    }

    /// A commit the host could not perform for want of a credential (#67):
    /// remember it, and show the sign-in the host starts in place of the list.
    pub fn enterCredentialStage(self: *Picker, provider: Slug, commit: Commit) Outcome {
        self.pending_commit = commit;
        self.credential_provider = provider;
        self.credential_return_stage = self.stage;
        self.credential_failed = false;
        self.credential_lines_len = 0;
        self.notice_len = 0;
        self.stage = .credential;
        self.cursor = 0;
        self.window_top = 0;
        return .{ .login = provider };
    }

    /// The flow's transcript so far (bounded copy). True when it changed, so
    /// the host redraws only then.
    pub fn setCredentialLines(self: *Picker, text: []const u8) bool {
        const len = @min(text.len, self.credential_lines.len);
        if (len == self.credential_lines_len and std.mem.eql(u8, self.credential_lines[0..len], text[0..len])) return false;
        @memcpy(self.credential_lines[0..len], text[0..len]);
        self.credential_lines_len = len;
        return true;
    }

    pub fn credentialLines(self: *const Picker) []const u8 {
        return self.credential_lines[0..self.credential_lines_len];
    }

    /// The login ended without a credential; the stage stays so the user can
    /// read why, and Esc returns without a further notice.
    pub fn credentialFailed(self: *Picker, error_name: []const u8) void {
        self.credential_failed = true;
        if (self.credential_mode == .paste_key) {
            self.key_checking = false;
            if (std.mem.eql(u8, error_name, "KeyRefused")) {
                self.setNotice("the provider refused that key; paste another, or Esc returns to the route list", .{});
            } else {
                self.setNotice("the key was not stored ({s}); paste it again, or Esc returns to the route list", .{error_name});
            }
            return;
        }
        self.setNotice("sign-in failed ({s}); Esc returns to the route list", .{error_name});
    }

    /// After the login landed: the commit to retry, with the picker back on
    /// the stage the user came from.
    pub fn takePendingCommit(self: *Picker) ?Commit {
        const commit = self.pending_commit;
        self.leaveCredentialStage();
        return commit;
    }

    fn leaveCredentialStage(self: *Picker) void {
        self.stage = self.credential_return_stage;
        self.pending_commit = null;
        self.credential_provider = null;
        self.credential_failed = false;
        self.credential_lines_len = 0;
        self.leaveKeyMode();
        self.cursor = 0;
        self.window_top = 0;
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
            .credential => {},
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
        // By pointer: a provider id is an inline `Slug`, so the label of a by-value
        // capture points into the loop variable. Every stored label then read the
        // offer being visited, and providers whose ids had the same length
        // (metask, openai, gemini) folded into the first one's row.
        for (self.offers.items, 0..) |*offer, index| {
            const label = offer.provider_id.slice();
            // The filter also matches what the provider *serves*. The first
            // stage is the one where the user knows least: someone looking for
            // GLM should not have to already know it lives behind
            // `zai-coding-plan`.
            if (!matches(self.filter(), label) and
                !matches(self.filter(), offer.display_name) and
                !matches(self.filter(), canonicalKey(offer.*))) continue;
            if (findGroup(buffer.list.items, label, self)) |existing| {
                bumpGroup(&buffer.list.items[existing], index, self.isCurrent(offer.*));
                continue;
            }
            try buffer.list.append(buffer.gpa, .{ .provider = .{
                .offer_index = index,
                .offer_count = 1,
                .label = label,
                .is_current = self.isCurrent(offer.*),
            } });
        }
    }

    fn modelRows(self: *const Picker, buffer: *RowBuffer) error{OutOfMemory}!void {
        const wanted = self.provider orelse return;
        for (self.offers.items, 0..) |offer, index| {
            if (!offer.provider_id.eql(wanted)) continue;
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
        // The credential stage has no list to move in: a sign-in takes only
        // Esc; the paste-a-key step takes the key.
        if (self.stage == .credential) {
            if (self.credential_mode == .paste_key) return self.onKeyStep(key);
            return if (key == .escape) self.back() else .ignored;
        }
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
            .credential => {
                // Esc ends the sign-in: the host aborts the worker on
                // `.cancel_login`; the draft route stays selectable.
                if (self.credential_failed) {
                    self.notice_len = 0;
                } else if (self.credential_mode == .paste_key) {
                    self.setNotice("no key was stored; the previous route is still active", .{});
                } else {
                    self.setNotice("sign-in cancelled; the previous route is still active", .{});
                }
                self.leaveCredentialStage();
                return .cancel_login;
            },
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

test "a commit refused for want of a credential enters the credential stage and Esc brings it back" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter); // provider
    const outcome = picker.onKey(.enter); // one route → commit
    try testing.expect(outcome == .commit);
    const came_from = picker.stage;

    const login = picker.enterCredentialStage(Slug.lit("metask"), outcome.commit);
    try testing.expect(login == .login);
    try testing.expect(login.login.eqlText("metask"));
    try testing.expectEqual(Stage.credential, picker.stage);
    var scratch = Picker.RowBuffer.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectEqual(@as(usize, 0), (try picker.rows(&scratch)).len);
    try testing.expect(picker.onKey(.down) == .ignored);
    try testing.expect(picker.onKey(.{ .char = 'q' }) == .ignored);
    try testing.expect(picker.onKey(.enter) == .ignored);
    try testing.expectEqual(Stage.credential, picker.stage);

    const transcript = "Open this URL to authorize:\nhttps://example.test/authorize?state=s\n";
    try testing.expect(picker.setCredentialLines(transcript));
    try testing.expect(!picker.setCredentialLines(transcript));
    try testing.expectEqualStrings(transcript, picker.credentialLines());

    try testing.expect(picker.onKey(.escape) == .cancel_login);
    try testing.expectEqual(came_from, picker.stage);
    try testing.expect(picker.pending_commit == null);
    try testing.expectEqual(@as(usize, 0), picker.credentialLines().len);
    try testing.expect(std.mem.indexOf(u8, picker.notice(), "sign-in cancelled") != null);
}

test "a landed login hands the pending commit back and restores the stage" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter);
    const outcome = picker.onKey(.enter);
    const came_from = picker.stage;
    _ = picker.enterCredentialStage(Slug.lit("metask"), outcome.commit);

    const taken = picker.takePendingCommit() orelse return error.NoPendingCommit;
    try testing.expect(taken.offer_id.eql(outcome.commit.offer_id));
    try testing.expectEqual(came_from, picker.stage);
    try testing.expect(picker.takePendingCommit() == null);
    try testing.expectEqual(@as(usize, 0), picker.notice_len);
}

test "a failed sign-in explains itself and Esc then leaves no notice" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("metask", "default", "Claude Opus 4.6", "anthropic/claude-opus-4-6", "claude-opus-4-6", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter);
    const outcome = picker.onKey(.enter);
    _ = picker.enterCredentialStage(Slug.lit("metask"), outcome.commit);

    picker.credentialFailed("ConnectionRefused");
    try testing.expect(std.mem.indexOf(u8, picker.notice(), "sign-in failed (ConnectionRefused)") != null);
    try testing.expect(picker.onKey(.escape) == .cancel_login);
    try testing.expectEqual(@as(usize, 0), picker.notice_len);
    try testing.expect(!picker.credential_failed);
}

test "a pasted key is typed blind, chosen per plan, and handed over once" {
    var picker = Picker.init(testing.allocator);
    defer picker.deinit();
    const offers = [_]OfferSummary{
        fixtureOffer("zai-coding-plan", "cn-anthropic", "GLM-5.3", "zai/glm-5.3", "glm-5.3", "anthropic_messages"),
    };
    try loadFixture(&picker, &offers, null);
    _ = picker.onKey(.enter);
    const outcome = picker.onKey(.enter);
    try testing.expect(outcome == .commit);
    const came_from = picker.stage;
    const choices = [_]KeyChoice{
        .{ .label = "China · Personal", .url = "https://example.test/cn" },
        .{ .label = "Global · Personal", .url = "https://example.test/global" },
    };
    try testing.expect(picker.enterKeyStage(Slug.lit("zai-coding-plan"), outcome.commit, &choices, 1, "plan keys only") == .redraw);
    try testing.expectEqual(Stage.credential, picker.stage);
    try testing.expectEqual(CredentialMode.paste_key, picker.credential_mode);
    try testing.expectEqual(@as(usize, 1), picker.key_choice);

    // Nothing to submit yet; Tab opens the chosen page; arrows choose a plan.
    try testing.expect(picker.onKey(.enter) == .ignored);
    try testing.expect(picker.onKey(.cycle_scope) == .open_key_page);
    try testing.expect(picker.onKey(.down) == .redraw);
    try testing.expectEqual(@as(usize, 0), picker.key_choice);
    try testing.expect(picker.onKey(.up) == .redraw);
    try testing.expectEqual(@as(usize, 1), picker.key_choice);

    // Characters are the key, not a filter; whitespace from a paste is dropped.
    for (" plan-key\t") |byte| _ = picker.onKey(.{ .char = byte });
    try testing.expectEqualStrings("plan-key", picker.keyText());
    try testing.expectEqual(@as(usize, 0), picker.filter_len);
    try testing.expect(picker.onKey(.backspace) == .redraw);
    try testing.expectEqualStrings("plan-ke", picker.keyText());
    try testing.expect(picker.onKey(.enter) == .submit_key);

    // Handed over: the field is wiped and only Esc acts while it is checked.
    picker.keySubmitted();
    try testing.expectEqual(@as(usize, 0), picker.key_len);
    for (picker.key_buffer[0..7]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expect(picker.onKey(.{ .char = 'x' }) == .ignored);
    try testing.expect(picker.onKey(.enter) == .ignored);

    // A refused key asks for another on the same plan.
    picker.credentialFailed("KeyRefused");
    try testing.expect(!picker.key_checking);
    try testing.expect(std.mem.indexOf(u8, picker.notice(), "refused that key") != null);
    try testing.expect(picker.onKey(.{ .char = 'k' }) == .redraw);
    try testing.expect(!picker.credential_failed);
    try testing.expectEqual(@as(usize, 1), picker.key_choice);

    // Esc gives up: nothing stored, the previous route kept, key mode left.
    try testing.expect(picker.onKey(.escape) == .cancel_login);
    try testing.expectEqual(came_from, picker.stage);
    try testing.expectEqual(CredentialMode.sign_in, picker.credential_mode);
    try testing.expectEqual(@as(usize, 0), picker.key_len);
    try testing.expect(std.mem.indexOf(u8, picker.notice(), "no key was stored") != null);
}
