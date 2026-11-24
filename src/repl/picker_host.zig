//! Host side of the cross-UI model picker (issue #16, delivery slice P1).
//!
//! The state machine in `model_picker.zig` decides *what* the user asked for;
//! this module performs it against the session — refresh a snapshot, commit
//! through the kernel, rebind the live route. Both phases share it: the input
//! loop and the streaming watcher call the same two entry points, so a picker
//! opened mid-reply behaves exactly like one opened at the prompt.
//!
//! Threads: the picker has one writer, the thread running the phase's key loop
//! (the input loop, or a reply's keyboard watcher). Frames other threads draw
//! (a reply's agent thread, the merge window's timer, #328) only read it. So
//! every write to `app.model_picker` and to `picker_open` happens under the
//! caller's `Guard`, the region lock: held for an in-memory update, never
//! across IO and never with another lock taken inside it. The writer's own
//! reads need no lock. Committing a route and listing the catalog (with the
//! file reads that judge which routes have a credential) run outside it.
//!
//! The picker starts no sign-in and takes no key (#488): `/login <provider>`
//! is where that happens. A provider with no credential is not listed; a
//! commit whose credential went away after the list was drawn says where it
//! goes.

const std = @import("std");
const app_mod = @import("../app.zig");
const ui_state = @import("tui/ui_state.zig");
const picker_mod = @import("model_picker.zig");
const view_mod = @import("model_picker_view.zig");
const provider_host_mod = @import("metacodes-internal").provider.host;
const state_env = @import("../app/state_env.zig");
const util_time = @import("metacodes-internal").util.time;
const RenderRegion = @import("tui/render_region.zig").RenderRegion;

pub const Key = picker_mod.Key;

/// The lock a picker write takes so that no frame drawn on another thread
/// reads the picker halfway through it (see the module header).
pub const Guard = struct {
    region: ?*RenderRegion = null,

    /// No other thread draws the picker (component tests driving it alone).
    pub const unguarded: Guard = .{};

    pub fn of(region: *RenderRegion) Guard {
        return .{ .region = region };
    }

    fn lock(guard: Guard) void {
        if (guard.region) |region| region.lockUi();
    }

    fn unlock(guard: Guard) void {
        if (guard.region) |region| region.unlockUi();
    }
};

/// Rows the list may occupy. Kept well inside the fixed region so the picker
/// never pushes the input box off a short terminal.
fn pageRowsFor(rows: u16) usize {
    if (rows <= 12) return 3;
    const third = rows / 3;
    return @min(@as(usize, @intCast(third)), 12);
}

pub fn open(app: *app_mod.App, ui: *ui_state.UiState, guard: Guard) void {
    refresh(app, guard);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const env_path = localConfigPath(app, &path_buf);
    guard.lock();
    defer guard.unlock();
    app.model_picker.restart();
    // Where a credential goes: for a commit that finds none, and for a list
    // no provider is configured for (#488).
    app.model_picker.setLocalConfig(env_path, state_env.guide_url);
    // The level the session runs with starts selected on any route that
    // offers it, so applying a route does not quietly drop it. `none` and
    // `minimal` too: a level chosen to keep thinking off is a choice, and a
    // route's declared default (DeepSeek's `high`) must not replace it.
    if (app.config.reasoning_effort) |effort| app.model_picker.presetControl("reasoning_effort", effort.name());
    app.model_picker.page_rows = pageRowsFor(ui.rows);
    // A sign-in that goes on to choosing a model (`/login openrouter`) said
    // how; the user's own `/model` and Ctrl+O open as they always have.
    if (app.pending_picker_preset) |preset| {
        app.pending_picker_preset = null;
        app.model_picker.presetScope(preset.scope);
        if (preset.filter_len > 0) app.model_picker.presetFilter(preset.filter());
    }
    _ = app.model_picker.setListNote(app.openRouterListNote(util_time.nowMs()));
    setOpen(ui, true);
}

/// Show a picker the previous phase left open (#220). Unlike `open` it keeps
/// the snapshot and the half-finished browse; only the page height, which
/// belongs to the new region, is recomputed. The overlay itself died with
/// that phase (#330), so this is what carries it across the boundary.
pub fn keep(app: *app_mod.App, ui: *ui_state.UiState, guard: Guard) void {
    guard.lock();
    defer guard.unlock();
    app.model_picker.page_rows = pageRowsFor(ui.rows);
    _ = app.model_picker.setListNote(app.openRouterListNote(util_time.nowMs()));
    setOpen(ui, true);
}

pub fn relist(app: *app_mod.App, guard: Guard) void {
    refresh(app, guard);
    _ = renote(app, guard);
}

pub fn renote(app: *app_mod.App, guard: Guard) bool {
    const now = util_time.nowMs();
    app.sampleOpenRouterProgress(now);
    const note = app.openRouterListNote(now);
    guard.lock();
    defer guard.unlock();
    return app.model_picker.setListNote(note);
}

fn retryList(app: *app_mod.App, provider: picker_mod.Slug, guard: Guard) Result {
    if (!provider.eqlText("openrouter")) return .ignored;
    app.startOpenRouterRefresh(true) catch |err| {
        guard.lock();
        defer guard.unlock();
        app.model_picker.setNotice("the download did not start ({s})", .{@errorName(err)});
        return .redraw;
    };
    _ = renote(app, guard);
    return .redraw;
}

pub fn close(app: *app_mod.App, ui: *ui_state.UiState, guard: Guard) void {
    guard.lock();
    defer guard.unlock();
    setOpen(ui, false);
    app.model_picker.clearNotice();
}

/// The overlay is owned by the interactive phase it is shown in. Outside one
/// (idle) there is no region to show it in, so there is nothing to set.
fn setOpen(ui: *ui_state.UiState, open_now: bool) void {
    const ix = ui.interaction() orelse return;
    ix.picker_open = open_now;
}

/// Rebuild the snapshot from the kernel: the listing (which may first build
/// the provider host) outside the guard, the snapshot swap under it.
fn refresh(app: *app_mod.App, guard: Guard) void {
    var listing = app.listModelOffers() catch {
        guard.lock();
        defer guard.unlock();
        // A catalog that cannot be built is shown as a failed picker rather
        // than as silence: the user pressed a key and deserves an answer.
        app.model_picker.markFailed();
        return;
    };
    defer listing.deinit(app.allocator);
    publishListing(app, &listing, guard);
}

/// The locked half of a refresh: `listing` becomes the picker's snapshot.
/// This swap is what a frame must not see halfway: `adopt` clears the offer
/// list and refills it, possibly into a new buffer, while the view indexes
/// it by the rows it grouped.
pub fn publishListing(app: *app_mod.App, listing: *const app_mod.App.ModelListing, guard: Guard) void {
    guard.lock();
    defer guard.unlock();
    app.adoptModelListing(listing) catch app.model_picker.markFailed();
}

/// What the last commit did, a line or two. Stable until the picker is
/// reopened, so the caller can put it into the transcript after the overlay
/// is gone.
pub fn lastNotice(app: *const app_mod.App) []const u8 {
    return app.model_picker.notice();
}

pub const Result = enum {
    /// The key changed nothing; the caller may skip the redraw.
    ignored,
    /// State changed; redraw.
    redraw,
    /// A commit landed and the picker closed. `app.model_picker.notice()` holds
    /// the line the caller should put into the transcript — a picker that
    /// vanishes without saying which of several same-named routes it chose
    /// leaves the user unable to tell — and a second one naming who bills
    /// the session from now on when that changed (#488).
    committed,
    /// The picker was closed without a commit (Esc, q). The notice says so
    /// and names the model the session stays on, for the transcript: "kept
    /// glm-5.3 · reasoning high".
    cancelled,
};

/// Feed one key.
pub fn onKey(app: *app_mod.App, ui: *ui_state.UiState, key: Key, guard: Guard) Result {
    const outcome = step: {
        guard.lock();
        defer guard.unlock();
        // The window can have changed since the picker opened; recompute before
        // the key moves the cursor so scrolling uses the current geometry.
        app.model_picker.page_rows = pageRowsFor(ui.rows);
        break :step app.model_picker.onKey(key);
    };
    switch (outcome) {
        .ignored => return .ignored,
        .redraw => return .redraw,
        .closed => {
            close(app, ui, guard);
            guard.lock();
            defer guard.unlock();
            var level_buf: [48]u8 = undefined;
            app.model_picker.setNotice("kept {s}{s}", .{ app.activeModel(), levelNote(app.config.reasoning_effort, &level_buf) });
            return .cancelled;
        },
        .commit => |commit| return apply(app, ui, commit, guard),
        .retry_list => |provider| return retryList(app, provider, guard),
    }
}

pub fn onPaste(app: *app_mod.App, ui: *ui_state.UiState, text: []const u8, guard: Guard) void {
    guard.lock();
    defer guard.unlock();
    app.model_picker.page_rows = pageRowsFor(ui.rows);
    app.model_picker.onPaste(text);
}

/// Commit through the kernel (IO, outside the guard), then say how it went
/// in the picker (under it).
fn apply(app: *app_mod.App, ui: *ui_state.UiState, commit: picker_mod.Commit, guard: Guard) Result {
    // Who bills the session before the commit, to say so when it changes.
    const before = currentProvider(app);
    const outcome = app.commitModelSelection(commit) catch |err| {
        // issue #33: the route resolved; what is missing is a credential for
        // its provider. The picker listed it as ready, so the credential went
        // away since it opened: show where it goes (#483, #488). No sign-in
        // starts here.
        if (err == error.MissingCredentials) if (app.providerHost() catch null) |host| {
            if (host.kernel.catalogSnapshot().find(commit.offer_id)) |offer| {
                const setup = app_mod.App.providerSetup(host, offer.provider_id);
                guard.lock();
                defer guard.unlock();
                app.model_picker.setNotice("no credential for {s}; the previous route is still active", .{offer.provider_id.slice()});
                app.model_picker.enterSetup(setup);
                return .redraw;
            }
        };
        guard.lock();
        defer guard.unlock();
        app.model_picker.setNotice("switch failed ({s}); the previous route is still active", .{@errorName(err)});
        return .redraw;
    };
    switch (outcome) {
        .committed => |accepted| {
            // Switching to another provider moves the bill: say to whom
            // (target state section ten, point 2).
            var billed_buf: [160]u8 = undefined;
            const billed = billingNote(app, before, commit.offer_id, &billed_buf);
            guard.lock();
            defer guard.unlock();
            if (app.last_persist_error) |why| {
                // The route is live; what failed is making it survive a
                // `/resume`. Saying "switched" alone would be true and
                // misleading.
                app.model_picker.setNotice("switched to {s}, but it was not saved ({s}){s}", .{
                    app.activeModel(),
                    why,
                    billed,
                });
            } else {
                var level_buf: [48]u8 = undefined;
                app.model_picker.setNotice("switched to {s} {s}{s}{s}", .{
                    app.activeModel(),
                    view_mod.scopePhrase(accepted.scope),
                    levelNote(committedLevel(commit), &level_buf),
                    billed,
                });
            }
            setOpen(ui, false);
            return .committed;
        },
        .rejected => |reason| {
            guard.lock();
            defer guard.unlock();
            app.model_picker.setNotice("{s}; the previous route is still active", .{rejectionText(reason)});
            return .redraw;
        },
        .conflict => {
            // Another writer moved the configuration under us. Re-read rather
            // than overwrite: last-writer-wins is exactly what the revision
            // check exists to prevent.
            refresh(app, guard);
            guard.lock();
            defer guard.unlock();
            app.model_picker.setNotice("configuration changed elsewhere; the list was reloaded", .{});
            return .redraw;
        },
    }
}

/// " · reasoning high" for a level a route was committed with or the
/// session runs at, "" for none.
fn levelNote(level: ?@import("metacodes-internal").types.ReasoningEffort, buf: []u8) []const u8 {
    const effort = level orelse return "";
    if (!effort.active()) return "";
    return std.fmt.bufPrint(buf, " · reasoning {s}", .{effort.name()}) catch "";
}

/// The reasoning level a commit carries, if any.
fn committedLevel(commit: picker_mod.Commit) ?@import("metacodes-internal").types.ReasoningEffort {
    const value = commit.controls.get("reasoning_effort") orelse return null;
    if (value != .text) return null;
    return @import("metacodes-internal").types.ReasoningEffort.parse(value.text.slice());
}

/// The provider of the route the session is on, as the kernel knows it;
/// null when it knows none.
fn currentProvider(app: *app_mod.App) ?picker_mod.Slug {
    const host = app.providerHost() catch return null;
    const current = host.kernel.currentOfferId() orelse return null;
    const offer = host.kernel.catalogSnapshot().find(current) orelse return null;
    return offer.provider_id;
}

/// A second line, "from now on billed to your <provider> account", when the
/// commit of `committed` moved the session to another provider (or from one
/// the kernel did not know), else "": a switch inside one provider does not
/// change who bills it. A line of its own, so the transcript line it follows
/// stays inside an ordinary terminal's width.
fn billingNote(app: *app_mod.App, before: ?picker_mod.Slug, committed: ids_mod.OfferId, buf: []u8) []const u8 {
    const host = app.providerHost() catch return "";
    const offer = host.kernel.catalogSnapshot().find(committed) orelse return "";
    if (before) |previous| if (previous.eql(offer.provider_id)) return "";
    const profile = host.registry.findById(offer.provider_id) orelse return "";
    return std.fmt.bufPrint(buf, "\nfrom now on billed to your {s} account", .{profile.display_name}) catch "";
}

/// This install's `<state root>/.env`, written as `state_env.load` names it
/// (`Loaded.path`), into `buf`.
fn localConfigPath(app: *const app_mod.App, buf: []u8) []const u8 {
    var fixed = std.heap.FixedBufferAllocator.init(buf);
    return std.fs.path.join(fixed.allocator(), &.{ app.stateRoot(), state_env.file_name }) catch state_env.file_name;
}

fn rejectionText(outcome: @import("metacodes-internal").provider.control_plane.ValidationOutcome) []const u8 {
    return switch (outcome) {
        .ok => "accepted",
        .unavailable => |err| switch (err) {
            error.PinnedOfferUnavailable => "that route is no longer offered",
            error.NoMatchingOffer => "no route matches that selection",
            error.AllCandidatesRejected => "every candidate route was rejected by the route policy",
        },
        .control_rejected => "the selected options are not supported by that route",
    };
}

// ── `/model use <id>` compatibility ──────────────────────────────────────────

const registry_mod = @import("metacodes-internal").provider.registry;
const ids_mod = @import("metacodes-internal").provider.ids;

pub const MAX_CANDIDATES: usize = 6;

/// Result of resolving a `/model use <id>` selector against the offer catalog.
pub const UseOutcome = union(enum) {
    /// Exactly one route matched and the session is now on it.
    switched,
    /// Several routes carry that name. Reported with their offer ids rather
    /// than resolved by guessing, because picking one would silently choose a
    /// protocol, region, price, and credential the user never named.
    ambiguous: struct {
        ids: [MAX_CANDIDATES][ids_mod.OFFER_ID_TEXT_LEN]u8,
        len: usize,
        total: usize,
    },
    /// No offer declares that name. The caller falls back to the historical
    /// path, which still serves proxies and server-catalog models.
    not_in_catalog,
    failed: []const u8,
};

/// Resolve and commit `selector` through the kernel, session-scoped.
pub fn useSelector(app: *app_mod.App, selector: []const u8) UseOutcome {
    const host = app.providerHost() catch |err| return .{ .failed = @errorName(err) };
    const catalog = host.kernel.catalogSnapshot();

    // An offer id is the unambiguous form the ambiguity message hands back, so
    // it has to be accepted verbatim on the way in.
    if (ids_mod.OfferId.parse(selector)) |parsed| {
        if (catalog.find(parsed)) |found| return commitOffer(app, found);
    } else |_| {}

    var only: ?*const registry_mod.ModelOffer = null;
    var out = UseOutcome{ .ambiguous = .{ .ids = undefined, .len = 0, .total = 0 } };
    for (catalog.items()) |*candidate| {
        if (!registry_mod.matchesSelector(candidate.*, selector)) continue;
        out.ambiguous.total += 1;
        if (out.ambiguous.len < MAX_CANDIDATES) {
            out.ambiguous.ids[out.ambiguous.len] = candidate.offer_id.render();
            out.ambiguous.len += 1;
        }
        if (only == null) only = candidate;
    }

    if (out.ambiguous.total == 0) return .not_in_catalog;
    if (out.ambiguous.total > 1) {
        // A name several providers serve means the one the session is on:
        // `/model use glm-5.3-flash` in a Metask session is Metask's route,
        // not a question about Z.AI's four. Then the current channel. Only
        // a choice neither settles is reported.
        const current_id = host.kernel.currentOfferId() orelse return out;
        const current = catalog.find(current_id) orelse return out;
        if (soleMatch(catalog, selector, current, false)) |chosen| return commitOffer(app, chosen);
        if (soleMatch(catalog, selector, current, true)) |chosen| return commitOffer(app, chosen);
        return out;
    }

    return commitOffer(app, only.?);
}

/// The one offer matching `selector` on `current`'s provider (and, when
/// `same_channel`, its channel too); null when there is none or several.
fn soleMatch(
    catalog: anytype,
    selector: []const u8,
    current: *const registry_mod.ModelOffer,
    same_channel: bool,
) ?*const registry_mod.ModelOffer {
    var found: ?*const registry_mod.ModelOffer = null;
    for (catalog.items()) |*candidate| {
        if (!candidate.provider_id.eql(current.provider_id)) continue;
        if (same_channel and !candidate.channel_id.eql(current.channel_id)) continue;
        if (!registry_mod.matchesSelector(candidate.*, selector)) continue;
        if (found != null) return null;
        found = candidate;
    }
    return found;
}

fn commitOffer(app: *app_mod.App, chosen: *const registry_mod.ModelOffer) UseOutcome {
    const outcome = app.commitModelSelection(.{
        .offer_id = chosen.offer_id,
        .offer_revision = chosen.offer_revision,
        .controls = .{},
        // `/model use` has always been session-scoped; making it durable would
        // change what an existing script does.
        .scope = .session,
    }) catch |err| return .{ .failed = @errorName(err) };
    return switch (outcome) {
        .committed => .switched,
        .rejected => |reason| .{ .failed = rejectionText(reason) },
        .conflict => .{ .failed = "the configuration changed while committing; try again" },
    };
}
