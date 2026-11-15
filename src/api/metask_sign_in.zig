//! `/login` (#485): the Metask browser sign-in, off the TUI's thread.
//!
//! `metacodes login` signs in in the browser and then asks, line by line,
//! which API key, model and reasoning level to use. The TUI asks the same in
//! a dialog that keeps drawing while the network works, so the network work
//! runs here, on a worker thread, in two steps the dialog starts:
//!
//! 1. `startSignIn`: the authorization-code + PKCE flow of
//!    `auth.loginWithBrowser` (its instructions, the URL to open, go to the
//!    transcript; `cancel` ends the wait for the browser), then the account's
//!    API keys, listed with the sign-in's access token.
//! 2. `startModels`: the `/v1/models` answer for the key the user chose.
//!
//! Nothing is stored here: the caller writes `auth.json` once key, model and
//! reasoning level are chosen, so a sign-in cancelled at any step changes
//! nothing. The state is an atomic; a step's results are written before its
//! `.release` store and read after an `.acquire` load, as in `LoginWorker`.
//!
//! The worker lives on the heap and has two owners while a step runs: the
//! dialog and the step's thread. `release` gives up the dialog's share; the
//! last owner frees it. Closing the dialog therefore never waits on a request
//! the step cannot abandon (the code exchange, the key list): that thread
//! frees the worker when it is done.

const std = @import("std");
const sync = @import("platform").sync;
const auth = @import("../core/auth.zig");
const api_keys = @import("api_keys.zig");
const oauth_login = @import("oauth_login.zig");
const client_mod = @import("../client.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

/// The Messages endpoint a Metask sign-in's account and keys are reached
/// through: `METACODES_BASE_URL` (a local gateway, a test's mock), else
/// Metask's own. `metacodes login` and `/login` (#485) use the same one.
pub fn messagesUrl() []const u8 {
    if (std.c.getenv("METACODES_BASE_URL")) |u| {
        const value = std.mem.span(u);
        if (value.len > 0) return value;
    }
    return client_mod.ANTHROPIC_API_URL;
}

pub const State = enum(u8) {
    idle,
    /// Waiting for the browser, exchanging the code, listing the keys.
    signing_in,
    /// Signed in; `keys` lists the account's API keys (maybe none).
    keys_ready,
    /// Fetching the chosen key's models.
    loading_models,
    /// `models_json` holds the chosen key's `/v1/models` answer.
    models_ready,
    failed,
    cancelled,
};

/// Room for the loopback instructions: a few lines and one long URL.
pub const TRANSCRIPT_CAPACITY: usize = 2048;

pub const Options = struct {
    /// The Metask Messages endpoint (`auth.metaskMessagesUrl`): the account's
    /// key list and a key's models are reached through its origin.
    messages_url: []const u8,
    open_browser: bool = true,
    /// The loopback port the browser returns to (0 lets the system pick one).
    port: u16 = 1455,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The dialog's share, plus one while a step's thread runs.
    owners: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
    /// Owned copies of `Options`' strings: the thread outlives no caller,
    /// but a cancelled one may finish after its dialog has closed.
    messages_url: []u8,
    open_browser: bool,
    port: u16,
    abort_signal: AbortSignal = AbortSignal.init(),
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
    thread: ?std.Thread = null,

    /// Set by step 1; owned here until `takeOAuth`.
    oauth: ?auth.OAuthCredential = null,
    keys: api_keys.Catalog,
    /// The key step 2 lists the models of (owned, zeroed on release).
    chosen_key: ?[]u8 = null,
    /// Step 2's answer (owned).
    models_json: ?[]u8 = null,

    failure_name: [64]u8 = undefined,
    failure_len: usize = 0,
    transcript_mutex: sync.Mutex = .{},
    transcript: [TRANSCRIPT_CAPACITY]u8 = undefined,
    transcript_len: usize = 0,

    /// A new worker on the heap, owned by the caller until `release`.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) error{OutOfMemory}!*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .messages_url = try allocator.dupe(u8, options.messages_url),
            .open_browser = options.open_browser,
            .port = options.port,
            .keys = api_keys.Catalog.init(allocator),
        };
        return self;
    }

    /// Give up the caller's share: cancel any step, and free the worker now
    /// when none runs; a running step's thread frees it when it ends.
    pub fn release(self: *Worker) void {
        self.cancel();
        const thread = self.thread;
        self.thread = null;
        if (self.owners.fetchSub(1, .acq_rel) == 1) {
            // No step holds it (one that just ended is reaped here).
            if (thread) |running| running.join();
            self.destroy();
        } else if (thread) |running| {
            running.detach();
        }
    }

    /// Everything released, secrets zeroed.
    fn destroy(self: *Worker) void {
        const allocator = self.allocator;
        if (self.oauth) |*credential| credential.deinit(allocator);
        self.keys.deinit();
        if (self.chosen_key) |key| {
            std.crypto.secureZero(u8, key);
            allocator.free(key);
        }
        if (self.models_json) |body| allocator.free(body);
        allocator.free(self.messages_url);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// The end of a step's thread: its share goes; the last owner frees.
    fn finishStep(self: *Worker) void {
        if (self.owners.fetchSub(1, .acq_rel) == 1) self.destroy();
    }

    fn spawnStep(self: *Worker, comptime run: fn (*Worker) void) error{ThreadSpawnFailed}!void {
        _ = self.owners.fetchAdd(1, .acq_rel);
        self.thread = @import("platform").thread.spawn(.full, run, .{self}) catch {
            _ = self.owners.fetchSub(1, .acq_rel);
            return error.ThreadSpawnFailed;
        };
    }

    /// Step 1, from `idle`.
    pub fn startSignIn(self: *Worker) error{ AlreadyStarted, ThreadSpawnFailed }!void {
        try self.begin(.idle, .signing_in);
        self.spawnStep(runSignIn) catch |err| {
            self.state.store(@intFromEnum(State.idle), .release);
            return err;
        };
    }

    /// Step 2, from `keys_ready` or `models_ready` (another key): the models
    /// `key` can use.
    pub fn startModels(self: *Worker, key: []const u8) error{ AlreadyStarted, ThreadSpawnFailed, OutOfMemory }!void {
        const current = self.currentState();
        if (current != .keys_ready and current != .models_ready) return error.AlreadyStarted;
        self.join();
        const copy = try self.allocator.dupe(u8, key);
        if (self.chosen_key) |old| {
            std.crypto.secureZero(u8, old);
            self.allocator.free(old);
        }
        self.chosen_key = copy;
        if (self.models_json) |body| self.allocator.free(body);
        self.models_json = null;
        try self.begin(current, .loading_models);
        self.spawnStep(runModels) catch |err| {
            self.state.store(@intFromEnum(current), .release);
            return err;
        };
    }

    fn begin(self: *Worker, from: State, to: State) error{AlreadyStarted}!void {
        if (self.state.cmpxchgStrong(@intFromEnum(from), @intFromEnum(to), .acq_rel, .acquire) != null) return error.AlreadyStarted;
    }

    fn runSignIn(self: *Worker) void {
        defer self.finishStep();
        self.signIn();
    }

    fn signIn(self: *Worker) void {
        var stored = auth.loginWithBrowser(self.allocator, .{
            .open_browser = self.open_browser,
            .port = self.port,
            .abort_signal = &self.abort_signal,
            .notify = .{ .ctx = self, .write = appendTranscript },
        }) catch |err| return self.settleError(err);
        defer stored.deinit(self.allocator);
        const credential = stored.oauth orelse return self.settleError(error.MissingOAuth);
        if (self.abort_signal.isAborted()) return self.settle(.cancelled);
        self.notify().say("Signed in. Listing your API keys…\n");
        api_keys.fetchInto(&self.keys, self.allocator, self.io, self.messages_url, credential.access_token) catch |err|
            return self.settleError(err);
        if (self.abort_signal.isAborted()) return self.settle(.cancelled);
        self.oauth = credential;
        stored.oauth = null;
        self.settle(.keys_ready);
    }

    fn runModels(self: *Worker) void {
        defer self.finishStep();
        self.listModels();
    }

    fn listModels(self: *Worker) void {
        var client = client_mod.Client.initWithBaseUrl(self.allocator, self.io, self.chosen_key.?, "model-selection", self.messages_url);
        defer client.deinit();
        const body = client.fetchModelsList() catch |err| return self.settleError(err);
        if (self.abort_signal.isAborted()) {
            self.allocator.free(body);
            return self.settle(.cancelled);
        }
        self.models_json = body;
        self.settle(.models_ready);
    }

    fn settle(self: *Worker, to: State) void {
        self.state.store(@intFromEnum(to), .release);
    }

    fn settleError(self: *Worker, err: anyerror) void {
        if (err == error.Aborted or self.abort_signal.isAborted()) return self.settle(.cancelled);
        const name = @errorName(err);
        const len = @min(name.len, self.failure_name.len);
        @memcpy(self.failure_name[0..len], name[0..len]);
        self.failure_len = len;
        self.settle(.failed);
    }

    /// Ends the wait for the browser at its next check; a request already
    /// sent finishes first. The state becomes `cancelled`.
    pub fn cancel(self: *Worker) void {
        self.abort_signal.abort(.user_interrupt);
    }

    pub fn currentState(self: *const Worker) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    /// Whether no step is running.
    pub fn isSettled(self: *const Worker) bool {
        return switch (self.currentState()) {
            .signing_in, .loading_models => false,
            else => true,
        };
    }

    /// Wait for the last step's thread to end (it settled already, or will).
    fn join(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Valid after the state read `failed`.
    pub fn failureName(self: *const Worker) []const u8 {
        return self.failure_name[0..self.failure_len];
    }

    /// The sign-in's OAuth credential, handed over (valid from `keys_ready`).
    pub fn takeOAuth(self: *Worker) ?auth.OAuthCredential {
        defer self.oauth = null;
        return self.oauth;
    }

    /// The transcript so far, copied into `out`.
    pub fn copyTranscript(self: *Worker, out: []u8) []const u8 {
        self.transcript_mutex.lock();
        defer self.transcript_mutex.unlock();
        const len = @min(out.len, self.transcript_len);
        @memcpy(out[0..len], self.transcript[0..len]);
        return out[0..len];
    }

    pub fn notify(self: *Worker) oauth_login.Notify {
        return .{ .ctx = self, .write = appendTranscript };
    }

    fn appendTranscript(ctx: *anyopaque, text: []const u8) void {
        const self: *Worker = @ptrCast(@alignCast(ctx));
        self.transcript_mutex.lock();
        defer self.transcript_mutex.unlock();
        const room = self.transcript.len - self.transcript_len;
        const len = @min(room, text.len);
        @memcpy(self.transcript[self.transcript_len..][0..len], text[0..len]);
        self.transcript_len += len;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

test "a sign-in that never gets its callback is cancelled, and nothing is kept" {
    const a = std.testing.allocator;
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    // Port 0 keeps a developer's real login server out of the way; the
    // browser is never opened.
    const worker = try Worker.create(a, io_runtime.io(), .{ .messages_url = "http://127.0.0.1:9/v1/messages", .open_browser = false, .port = 0 });
    defer worker.release();
    try worker.startSignIn();
    try std.testing.expectError(error.AlreadyStarted, worker.startSignIn());

    var spins: usize = 0;
    var buffer: [TRANSCRIPT_CAPACITY]u8 = undefined;
    while (std.mem.indexOf(u8, worker.copyTranscript(&buffer), "Open this URL") == null and spins < 1_000) : (spins += 1)
        @import("../util/time.zig").sleepMs(10);
    try std.testing.expect(std.mem.indexOf(u8, worker.copyTranscript(&buffer), "/auth/callback") != null);
    try std.testing.expectEqual(State.signing_in, worker.currentState());

    worker.cancel();
    spins = 0;
    // Settled, and the step's thread has let go (so `release` reaps it).
    while ((!worker.isSettled() or worker.owners.load(.acquire) != 1) and spins < 1_000) : (spins += 1) @import("../util/time.zig").sleepMs(10);
    try std.testing.expectEqual(State.cancelled, worker.currentState());
    try std.testing.expect(worker.takeOAuth() == null);
    try std.testing.expectEqual(@as(usize, 0), worker.keys.entries.items.len);
}
