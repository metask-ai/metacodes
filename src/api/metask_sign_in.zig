//! `/login` and `/login metask` (#485, #527): the Metask sign-in, off the
//! TUI's thread.
//!
//! `metacodes login` signs in in the browser and then asks, line by line,
//! which model and reasoning level to use. The TUI asks the same in a dialog
//! that keeps drawing while the network works, so the network work runs here,
//! on a worker thread, in one step the dialog starts (`startSignIn`): the
//! authorization-code + PKCE flow of `auth.loginWithBrowserTokenJson` against
//! `www.metask-ai.com`, or with `Options.device_code` the device code of
//! `metask_oauth` (either way the instructions go to the transcript, and
//! `cancel` ends the wait), then the models the sign-in may use: the
//! gateway's `/v1/models`, asked with the sign-in's own access token. The
//! token response names that gateway (`gateway_url`); the sign-in is used
//! there with its token, so there is no API key to choose.
//!
//! Nothing is stored here: the caller stores the token response as the Metask
//! session (`provider_login.importTokenResponse`) once a model and reasoning
//! level are chosen, so a sign-in cancelled at any step changes nothing. The
//! state is an atomic; the step's results are written before its `.release`
//! store and read after an `.acquire` load, as in `LoginWorker`.
//!
//! The worker lives on the heap and has two owners while the step runs: the
//! dialog and the step's thread. `release` gives up the dialog's share; the
//! last owner frees it. Closing the dialog therefore never waits on a request
//! the step cannot abandon (the code exchange, the model list): that thread
//! frees the worker when it is done.

const std = @import("std");
const sync = @import("platform").sync;
const auth = @import("../core/auth.zig");
const oauth_login = @import("oauth_login.zig");
const metask_oauth = @import("metask_oauth.zig");
const catalog_fetch = @import("catalog_fetch.zig");
const provider_oauth = @import("../provider/oauth.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

/// The gateway a Metask sign-in's token response names, unless
/// `METASK_GATEWAY_URL` (the documented local-development override, as at
/// startup) names another origin. Borrowed from `token_json` or the
/// environment; null when neither names a gateway origin.
pub fn gatewayOf(arena: std.mem.Allocator, token_json: []const u8) ?[]const u8 {
    if (std.c.getenv("METASK_GATEWAY_URL")) |raw| {
        const gateway = std.mem.trimEnd(u8, std.mem.span(raw), "/");
        return if (metask_oauth.isGatewayOrigin(gateway)) gateway else null;
    }
    const outcome = provider_oauth.parseTokenResponse(arena, token_json) catch return null;
    const gateway = std.mem.trimEnd(u8, outcome.gateway_url orelse return null, "/");
    return if (metask_oauth.isGatewayOrigin(gateway)) gateway else null;
}

pub const State = enum(u8) {
    idle,
    /// Waiting for the browser, exchanging the code, listing the models.
    signing_in,
    /// Signed in; `models_json` holds the gateway's `/v1/models` answer.
    models_ready,
    failed,
    cancelled,
};

/// Room for the loopback instructions: a few lines and one long URL.
pub const TRANSCRIPT_CAPACITY: usize = 2048;

pub const Options = struct {
    open_browser: bool = true,
    /// The loopback port the browser returns to (0 lets the system pick one).
    port: u16 = 1455,
    /// The device code instead (`/login metask`, #527): a code confirmed in
    /// a browser on any device, for a machine the browser cannot come back
    /// to. The models and the rest of the dialog are the same.
    device_code: bool = false,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The dialog's share, plus one while a step's thread runs.
    owners: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
    open_browser: bool,
    port: u16,
    device_code: bool,
    abort_signal: AbortSignal = AbortSignal.init(),
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
    thread: ?std.Thread = null,

    /// The token endpoint's answer (owned, zeroed on release): what the
    /// caller stores as the Metask session (`takeTokenJson`).
    token_json: ?[]u8 = null,
    /// The gateway origin the tokens are for (owned).
    gateway: ?[]u8 = null,
    /// The gateway's `/v1/models` answer for the sign-in (owned).
    models_json: ?[]u8 = null,
    /// The name the account goes by (`metask_oauth.accountName`), for the
    /// line that says who signed in (owned); null when it could not be had.
    account_name: ?[]u8 = null,

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
            .open_browser = options.open_browser,
            .port = options.port,
            .device_code = options.device_code,
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
        if (self.token_json) |body| {
            std.crypto.secureZero(u8, body);
            allocator.free(body);
        }
        if (self.gateway) |origin| allocator.free(origin);
        if (self.models_json) |body| allocator.free(body);
        if (self.account_name) |name| allocator.free(name);
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

    fn begin(self: *Worker, from: State, to: State) error{AlreadyStarted}!void {
        if (self.state.cmpxchgStrong(@intFromEnum(from), @intFromEnum(to), .acq_rel, .acquire) != null) return error.AlreadyStarted;
    }

    fn runSignIn(self: *Worker) void {
        defer self.finishStep();
        self.signIn();
    }

    /// The token endpoint's answer: by the device code (`device_code`), or
    /// by the browser coming back to the loopback server.
    fn acquireToken(self: *Worker) ![]u8 {
        if (self.device_code) return metask_oauth.acquireDeviceTokenWith(
            self.allocator,
            self.io,
            metask_oauth.siteUrl(),
            self.open_browser,
            .{ .ctx = self, .show = showDeviceCode },
            &self.abort_signal,
        );
        return auth.loginWithBrowserTokenJson(self.allocator, .{
            .open_browser = self.open_browser,
            .port = self.port,
            .abort_signal = &self.abort_signal,
            .notify = .{ .ctx = self, .write = appendTranscript },
        });
    }

    fn showDeviceCode(ctx: ?*anyopaque, uri: []const u8, code: []const u8) void {
        const self: *Worker = @ptrCast(@alignCast(ctx.?));
        var buffer: [1024]u8 = undefined;
        self.notify().say(std.fmt.bufPrint(&buffer, "Open {s} and enter the code {s}\n", .{ uri, code }) catch
            "Open the Metask device page and enter the code it shows.\n");
    }

    fn signIn(self: *Worker) void {
        const allocator = self.allocator;
        const token_json = self.acquireToken() catch |err| return self.settleError(err);
        var kept = false;
        defer if (!kept) {
            std.crypto.secureZero(u8, token_json);
            allocator.free(token_json);
        };
        if (self.abort_signal.isAborted()) return self.settle(.cancelled);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const outcome = provider_oauth.parseTokenResponse(arena.allocator(), token_json) catch |err|
            return self.settleError(err);
        // What the session store requires too (`importTokenResponse`): a
        // sign-in that cannot be kept is not worth choosing a model for.
        if (outcome.refresh_token == null) return self.settleError(error.MissingRefreshToken);
        const gateway = gatewayOf(arena.allocator(), token_json) orelse return self.settleError(error.MetaskGatewayMissing);

        self.notify().say("Signed in. Listing your models…\n");
        const models_url = std.fmt.allocPrint(arena.allocator(), "{s}/v1/models", .{gateway}) catch |err|
            return self.settleError(err);
        const fetched = catalog_fetch.fetchModelPages(allocator, self.io, .{ .url = models_url, .bearer = outcome.access_token }) catch |err|
            return self.settleError(err);
        var models_kept = false;
        defer if (!models_kept) allocator.free(fetched.body);
        if (self.abort_signal.isAborted()) return self.settle(.cancelled);
        // Who signed in, said on the line that ends the sign-in; best effort.
        self.account_name = metask_oauth.accountName(allocator, metask_oauth.siteUrl(), outcome.access_token, metask_oauth.ACCOUNT_NAME_WAIT_MS);
        if (self.abort_signal.isAborted()) return self.settle(.cancelled);
        const gateway_copy = allocator.dupe(u8, gateway) catch |err| return self.settleError(err);

        self.token_json = token_json;
        self.gateway = gateway_copy;
        self.models_json = fetched.body;
        kept = true;
        models_kept = true;
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
        return self.currentState() != .signing_in;
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

    /// The name the signed-in account goes by (valid from `models_ready`);
    /// null when it could not be had. Borrowed.
    pub fn accountName(self: *const Worker) ?[]const u8 {
        return self.account_name;
    }

    /// The sign-in's token response, handed over (valid from
    /// `models_ready`); the caller zeroes and frees it.
    pub fn takeTokenJson(self: *Worker) ?[]u8 {
        defer self.token_json = null;
        return self.token_json;
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
    const worker = try Worker.create(a, io_runtime.io(), .{ .open_browser = false, .port = 0 });
    defer worker.release();
    try worker.startSignIn();
    try std.testing.expectError(error.AlreadyStarted, worker.startSignIn());

    var spins: usize = 0;
    var buffer: [TRANSCRIPT_CAPACITY]u8 = undefined;
    // The instructions arrive in several writes, the URL to open after the
    // line that introduces it: wait for the URL itself. Its redirect is the
    // loopback callback, form-encoded like every query value.
    const callback = "redirect_uri=http%3A%2F%2Flocalhost%3A";
    while (std.mem.indexOf(u8, worker.copyTranscript(&buffer), callback) == null and spins < 1_000) : (spins += 1)
        @import("../util/time.zig").sleepMs(10);
    const transcript = worker.copyTranscript(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Open this URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, callback) != null);
    // The path registered for the `metacodes` client (#527).
    try std.testing.expect(std.mem.indexOf(u8, transcript, "%2Fauth%2Fmetask%2Fcallback") != null);
    try std.testing.expectEqual(State.signing_in, worker.currentState());

    worker.cancel();
    spins = 0;
    // Settled, and the step's thread has let go (so `release` reaps it).
    while ((!worker.isSettled() or worker.owners.load(.acquire) != 1) and spins < 1_000) : (spins += 1) @import("../util/time.zig").sleepMs(10);
    try std.testing.expectEqual(State.cancelled, worker.currentState());
    try std.testing.expect(worker.takeTokenJson() == null);
    try std.testing.expect(worker.models_json == null);
}
