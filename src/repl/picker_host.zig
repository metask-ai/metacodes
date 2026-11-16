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
//! reads need no lock. Committing a route, a sign-in, opening a browser and
//! listing the catalog all run outside it.

const std = @import("std");
const app_mod = @import("../app.zig");
const ui_state = @import("tui/ui_state.zig");
const picker_mod = @import("model_picker.zig");
const view_mod = @import("model_picker_view.zig");
const provider_login = @import("../api/provider_login.zig");
const provider_host_mod = @import("../provider/host.zig");
const login_worker_mod = @import("../api/login_worker.zig");
const state_env = @import("../app/state_env.zig");
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
    guard.lock();
    defer guard.unlock();
    app.model_picker.restart();
    // The level the session runs with starts selected on any route that
    // offers it, so applying a route does not quietly drop it.
    if (app.config.reasoning_effort) |effort| {
        if (effort.active()) app.model_picker.presetControl("reasoning_effort", effort.name());
    }
    app.model_picker.page_rows = pageRowsFor(ui.rows);
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
    setOpen(ui, true);
}

pub fn close(app: *app_mod.App, ui: *ui_state.UiState, guard: Guard) void {
    // A picker that closes mid sign-in must not leave a thread waiting on
    // a socket.
    cancelLogin(app);
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
            return .redraw;
        },
        .commit => |commit| return apply(app, ui, commit, guard),
        // Only `enterCredentialStage` produces `.login`, never a key.
        .login => unreachable,
        .cancel_login => {
            cancelLogin(app);
            return .redraw;
        },
        .submit_key => return submitKey(app, guard),
        .open_key_page => {
            const choices = app.model_picker.keyChoices();
            if (app.model_picker.key_choice < choices.len) {
                @import("../core/auth.zig").openBrowser(app.allocator, choices[app.model_picker.key_choice].url) catch {};
            }
            return .ignored;
        },
    }
}

/// Called from the input loops' idle tick while the picker is open (#67):
/// moves the worker's transcript into the picker and settles a finished
/// login. A landed login refreshes the catalog and retries the pending commit,
/// so the route the user chose is the one that becomes active.
pub fn poll(app: *app_mod.App, ui: *ui_state.UiState, guard: Guard) Result {
    const worker = app.login_worker orelse return .ignored;
    var transcript: [login_worker_mod.TRANSCRIPT_CAPACITY]u8 = undefined;
    const lines = worker.copyTranscript(&transcript);
    const changed = shown: {
        guard.lock();
        defer guard.unlock();
        break :shown app.model_picker.setCredentialLines(lines);
    };
    switch (worker.currentState()) {
        .idle => return .ignored,
        .running => return if (changed) .redraw else .ignored,
        .failed => {
            {
                guard.lock();
                defer guard.unlock();
                app.model_picker.credentialFailed(worker.failureName());
            }
            finishLogin(app);
            return .redraw;
        },
        .cancelled => {
            finishLogin(app);
            return .redraw;
        },
        .succeeded => {
            finishLogin(app);
            // The catalog is rebuilt so the route's credential is seen, then
            // the commit the user asked for goes through the normal path.
            refresh(app, guard);
            const pending = taken: {
                guard.lock();
                defer guard.unlock();
                break :taken app.model_picker.takePendingCommit();
            };
            if (pending) |commit| return apply(app, ui, commit, guard);
            return .redraw;
        },
    }
}

/// A commit refused for want of a credential on an OAuth-capable provider
/// becomes a sign-in inside the picker (#67): the kernel prepares the same
/// login `/login` runs (so every refusal is the typed one), a worker thread
/// runs it, and the picker enters its credential stage with the commit
/// pending. Returns false when nothing was started and no notice was set.
fn startLogin(app: *app_mod.App, commit: picker_mod.Commit, guard: Guard) bool {
    const host = app.providerHost() catch return false;
    const provider = missingCredentialPointer(host, commit.offer_id) orelse return false;
    const profile = host.registry.findById(provider) orelse return false;
    const prepared = provider_login.prepareProfileWith(profile, .{ .state_root = app.stateRoot() }, host.oauthClientIdFor(provider)) catch |err| {
        guard.lock();
        defer guard.unlock();
        app.model_picker.setNotice("no credential for {s}, and /login {s} cannot start: {s}; the previous route is still active", .{
            provider.slice(),
            provider.slice(),
            provider_login.refusalText(err, .loopback),
        });
        return true;
    };
    const worker = app.allocator.create(login_worker_mod.LoginWorker) catch return false;
    worker.* = login_worker_mod.LoginWorker.init(app.allocator, app.io, prepared);
    worker.start() catch {
        app.allocator.destroy(worker);
        return false;
    };
    app.login_worker = worker;
    guard.lock();
    defer guard.unlock();
    switch (app.model_picker.enterCredentialStage(provider, commit)) {
        .login => {},
        else => unreachable,
    }
    return true;
}

/// A commit refused for want of a credential on a provider that has no OAuth
/// grant but declares where its API keys are created
/// (`ProviderProfile.api_key_setup`): the picker shows those pages and takes
/// the pasted key, with the commit pending. False when the provider declares
/// no such pages.
fn startKeyEntry(app: *app_mod.App, commit: picker_mod.Commit, guard: Guard) bool {
    const host = app.providerHost() catch return false;
    const offer = host.kernel.catalogSnapshot().find(commit.offer_id) orelse return false;
    const profile = host.registry.findById(offer.provider_id) orelse return false;
    const setup = profile.api_key_setup orelse return false;
    var choices: [picker_mod.MAX_KEY_CHOICES]picker_mod.KeyChoice = undefined;
    const count = @min(setup.pages.len, choices.len);
    // The plan page for the region of the channel the user picked.
    const default = profile.defaultKeyPage(offer.channel_id);
    var default_index: usize = 0;
    for (setup.pages[0..count], 0..) |page, index| {
        choices[index] = .{ .label = page.label, .url = page.url };
        if (default) |wanted| if (wanted.id.eql(page.id)) {
            default_index = index;
        };
    }
    guard.lock();
    defer guard.unlock();
    _ = app.model_picker.enterKeyStage(profile.id, commit, choices[0..count], default_index, setup.note);
    return true;
}

/// Enter on a pasted key: check and store it on the login worker. `poll`
/// then retries the pending commit, which finds the stored key.
fn submitKey(app: *app_mod.App, guard: Guard) Result {
    const picker = &app.model_picker;
    const provider = picker.credential_provider orelse return .ignored;
    const host = app.providerHost() catch return .ignored;
    const profile = host.registry.findById(provider) orelse return .ignored;
    const setup = profile.api_key_setup orelse return .ignored;
    if (picker.key_choice >= setup.pages.len) return .ignored;
    const prepared = provider_login.prepareApiKey(profile, setup.pages[picker.key_choice].id.slice(), null, picker.keyText(), .{
        .state_root = app.stateRoot(),
        .open_browser = false,
    }) catch |err| {
        guard.lock();
        defer guard.unlock();
        picker.credentialFailed(@errorName(err));
        return .redraw;
    };
    cancelLogin(app);
    const worker = app.allocator.create(login_worker_mod.LoginWorker) catch {
        guard.lock();
        defer guard.unlock();
        picker.credentialFailed("OutOfMemory");
        return .redraw;
    };
    worker.* = login_worker_mod.LoginWorker.initFlow(app.allocator, app.io, .{ .api_key = prepared });
    // `start` copies the key into the worker; only then is the field wiped.
    worker.start() catch |err| {
        app.allocator.destroy(worker);
        guard.lock();
        defer guard.unlock();
        picker.credentialFailed(@errorName(err));
        return .redraw;
    };
    app.login_worker = worker;
    guard.lock();
    defer guard.unlock();
    picker.keySubmitted();
    return .redraw;
}

fn finishLogin(app: *app_mod.App) void {
    const worker = app.login_worker orelse return;
    worker.join();
    app.allocator.destroy(worker);
    app.login_worker = null;
}

/// Esc must not wait on the network: a key check is one GET that does not
/// watch the abort signal, so a worker still inside it is parked on the App
/// (cancelled, joined once it settles) instead of joined here.
fn cancelLogin(app: *app_mod.App) void {
    const worker = app.login_worker orelse return;
    if (worker.isSettled()) return finishLogin(app);
    app.login_worker = null;
    app.parkLoginWorker(worker);
}

/// Commit through the kernel (IO, outside the guard), then say how it went
/// in the picker (under it).
fn apply(app: *app_mod.App, ui: *ui_state.UiState, commit: picker_mod.Commit, guard: Guard) Result {
    const outcome = app.commitModelSelection(commit) catch |err| {
        // issue #33: the route resolved; what is missing is a credential for
        // its provider. When the provider can be signed in to, say how.
        if (err == error.MissingCredentials) {
            if (startLogin(app, commit, guard)) return .redraw;
            if (startKeyEntry(app, commit, guard)) return .redraw;
            const host = app.providerHost() catch null;
            if (host) |value| if (missingCredentialPointer(value, commit.offer_id)) |provider| {
                guard.lock();
                defer guard.unlock();
                app.model_picker.setNotice("no credential for {s}; sign in with /login {s}; the previous route is still active", .{ provider.slice(), provider.slice() });
                return .redraw;
            };
            // #483: no sign-in and no key page (Kimi, Gemini, Qwen, MiniMax):
            // the key goes into this install's .env, so say which variable
            // and where, instead of the bare error name.
            if (host) |value| if (missingKeyFor(value, commit.offer_id)) |missing| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const env_path = localConfigPath(app, &path_buf);
                guard.lock();
                defer guard.unlock();
                app.model_picker.setNotice("{s} has no key; the previous route is still active\nSet {s} in {s}, then restart\nHow to: {s}", .{
                    missing.provider.slice(),
                    missing.variable,
                    env_path,
                    state_env.guide_url,
                });
                return .redraw;
            };
        }
        guard.lock();
        defer guard.unlock();
        app.model_picker.setNotice("switch failed ({s}); the previous route is still active", .{@errorName(err)});
        return .redraw;
    };
    switch (outcome) {
        .committed => |accepted| {
            guard.lock();
            defer guard.unlock();
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

/// The provider a commit that failed for want of a credential can be signed
/// in to: the offer's provider, if a login could be stored for it at all
/// (`provider_login.requireOAuthCapable`). Null means the notice has nothing
/// better than the error to say.
pub fn missingCredentialPointer(host: *provider_host_mod.Host, offer_id: ids_mod.OfferId) ?picker_mod.Slug {
    const offer = host.kernel.catalogSnapshot().find(offer_id) orelse return null;
    const profile = host.registry.findById(offer.provider_id) orelse return null;
    provider_login.requireOAuthCapable(profile) catch return null;
    return profile.id;
}

/// The provider of an offer whose commit found no credential, and the
/// variable its key is read from: the canonical alias, else the first one
/// (#483). Null when the offer is gone or the provider reads no variable.
pub const MissingKey = struct {
    provider: picker_mod.Slug,
    /// Borrowed from the provider registry.
    variable: []const u8,
};

pub fn missingKeyFor(host: *provider_host_mod.Host, offer_id: ids_mod.OfferId) ?MissingKey {
    const offer = host.kernel.catalogSnapshot().find(offer_id) orelse return null;
    const profile = host.registry.findById(offer.provider_id) orelse return null;
    for (profile.env_aliases) |alias| {
        if (alias.canonical) return .{ .provider = profile.id, .variable = alias.name };
    }
    if (profile.env_aliases.len == 0) return null;
    return .{ .provider = profile.id, .variable = profile.env_aliases[0].name };
}

/// This install's `<state root>/.env`, written as `state_env.load` names it
/// (`Loaded.path`), into `buf`.
fn localConfigPath(app: *const app_mod.App, buf: []u8) []const u8 {
    var fixed = std.heap.FixedBufferAllocator.init(buf);
    return std.fs.path.join(fixed.allocator(), &.{ app.stateRoot(), state_env.file_name }) catch state_env.file_name;
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
