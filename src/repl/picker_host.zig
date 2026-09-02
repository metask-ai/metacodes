//! Host side of the cross-UI model picker (issue #16, delivery slice P1).
//!
//! The state machine in `model_picker.zig` decides *what* the user asked for;
//! this module performs it against the session — refresh a snapshot, commit
//! through the kernel, rebind the live route. Both phases share it: the input
//! loop and the streaming watcher call the same two entry points, so a picker
//! opened mid-reply behaves exactly like one opened at the prompt.

const std = @import("std");
const app_mod = @import("../app.zig");
const ui_state = @import("tui/ui_state.zig");
const picker_mod = @import("model_picker.zig");
const view_mod = @import("model_picker_view.zig");

pub const Key = picker_mod.Key;

/// Rows the list may occupy. Kept well inside the fixed region so the picker
/// never pushes the input box off a short terminal.
fn pageRowsFor(rows: u16) usize {
    if (rows <= 12) return 3;
    const third = rows / 3;
    return @min(@as(usize, @intCast(third)), 12);
}

pub fn open(app: *app_mod.App, ui: *ui_state.UiState) void {
    app.refreshModelPicker() catch {
        // A catalog that cannot be built is shown as a failed picker rather
        // than as silence: the user pressed a key and deserves an answer.
        app.model_picker.markFailed();
    };
    app.model_picker.restart();
    app.model_picker.page_rows = pageRowsFor(ui.rows);
    ui.picker_open = true;
}

pub fn close(app: *app_mod.App, ui: *ui_state.UiState) void {
    ui.picker_open = false;
    app.model_picker.clearNotice();
}

/// One line describing the last commit. Stable until the picker is reopened,
/// so the caller can put it into the transcript after the overlay is gone.
pub fn lastNotice(app: *const app_mod.App) []const u8 {
    return app.model_picker.notice();
}

pub const Result = enum {
    /// The key changed nothing; the caller may skip the redraw.
    ignored,
    /// State changed; redraw.
    redraw,
    /// A commit landed and the picker closed. `app.model_picker.notice()` holds
    /// one line the caller should put into the transcript — a picker that
    /// vanishes without saying which of several same-named routes it chose
    /// leaves the user unable to tell.
    committed,
};

/// Feed one key.
pub fn onKey(app: *app_mod.App, ui: *ui_state.UiState, key: Key) Result {
    // The window can have changed since the picker opened; recompute before
    // the key moves the cursor so scrolling uses the current geometry.
    app.model_picker.page_rows = pageRowsFor(ui.rows);
    switch (app.model_picker.onKey(key)) {
        .ignored => return .ignored,
        .redraw => return .redraw,
        .closed => {
            close(app, ui);
            return .redraw;
        },
        .commit => |commit| return apply(app, ui, commit),
    }
}

fn apply(app: *app_mod.App, ui: *ui_state.UiState, commit: picker_mod.Commit) Result {
    const outcome = app.commitModelSelection(commit) catch |err| {
        app.model_picker.setNotice("switch failed ({s}); the previous route is still active", .{@errorName(err)});
        return .redraw;
    };
    switch (outcome) {
        .committed => |accepted| {
            if (app.last_persist_error) |why| {
                // The route is live; what failed is making it survive a
                // `/resume`. Saying "switched" alone would be true and
                // misleading.
                app.model_picker.setNotice("switched to {s}, but it was not saved ({s})", .{
                    app.activeModel(),
                    why,
                });
            } else {
                app.model_picker.setNotice("switched to {s} for {s}", .{
                    app.activeModel(),
                    view_mod.scopeWord(accepted.scope),
                });
            }
            ui.picker_open = false;
            return .committed;
        },
        .rejected => |reason| {
            app.model_picker.setNotice("{s}; the previous route is still active", .{rejectionText(reason)});
            return .redraw;
        },
        .conflict => {
            // Another writer moved the configuration under us. Re-read rather
            // than overwrite: last-writer-wins is exactly what the revision
            // check exists to prevent.
            app.refreshModelPicker() catch app.model_picker.markFailed();
            app.model_picker.setNotice("configuration changed elsewhere; the list was reloaded", .{});
            return .redraw;
        },
    }
}

fn rejectionText(outcome: @import("../provider/control_plane.zig").ValidationOutcome) []const u8 {
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

const registry_mod = @import("../provider/registry.zig");
const ids_mod = @import("../provider/ids.zig");

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
    if (out.ambiguous.total > 1) return out;

    return commitOffer(app, only.?);
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
