//! A prepared provider login on a worker thread (#67).
//!
//! `provider_login.Prepared.run` blocks until the browser calls back (or the
//! device grant is approved); the TUI's render loop must not. The worker runs
//! the flow on its own thread, points the flow's `AbortSignal` at its own so
//! `Esc` can end it, and keeps a bounded transcript of what the flow asks the
//! user to do — the URL to open, the device code — for the picker to draw in
//! place of the route list.
//!
//! Two channels cross the thread boundary: the transcript, under a mutex, and
//! the state, an atomic. The worker stores its result (`failure_name`,
//! `diagnostic`) before the `.release` store of the state; a reader loads the
//! state with `.acquire` first and may then read the result. The `Prepared`
//! copy is mutated only before `start`.
const std = @import("std");
const provider_login = @import("provider_login.zig");
const oauth_login = @import("oauth_login.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const sync = @import("platform").sync;

pub const State = enum(u8) { idle, running, succeeded, failed, cancelled };

/// Enough for the loopback instructions (a few lines and one URL) or a device
/// code; a flow that says more is cut, and `transcriptTruncated` says so.
pub const TRANSCRIPT_CAPACITY: usize = 1024;

pub const LoginWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// A copy; `start` points its `abort_signal` at ours and moves every string
    /// it reads into `owned` before the thread runs.
    flow: provider_login.Flow,
    /// The flow's own copies of what it reads (endpoints, client, state root):
    /// a sign-in cancelled while inside a request finishes on its thread after
    /// its dialog has closed, and the registry and configuration it was
    /// prepared from may have changed by then.
    owned: std.heap.ArenaAllocator,
    abort_signal: AbortSignal = AbortSignal.init(),
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
    thread: ?std.Thread = null,
    diagnostic: provider_login.ImportDiagnostic = .{},
    failure_name: [64]u8 = undefined,
    failure_len: usize = 0,
    transcript_mutex: sync.Mutex = .{},
    transcript: [TRANSCRIPT_CAPACITY]u8 = undefined,
    transcript_len: usize = 0,
    transcript_truncated: bool = false,
    /// The pasted key now points into `owned` (set by `ownFlow`); only then
    /// is it this worker's to zero.
    owns_secret: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, prepared: provider_login.Prepared) LoginWorker {
        return initFlow(allocator, io, .{ .oauth = prepared });
    }

    /// Any sign-in flow, including Metask's own device grant (`/login`).
    pub fn initFlow(allocator: std.mem.Allocator, io: std.Io, flow: provider_login.Flow) LoginWorker {
        return .{ .allocator = allocator, .io = io, .flow = flow, .owned = std.heap.ArenaAllocator.init(allocator) };
    }

    /// Point the flow at copies it owns (see `owned`).
    fn ownFlow(self: *LoginWorker) error{OutOfMemory}!void {
        const a = self.owned.allocator();
        const options = self.flow.options();
        options.state_root = try a.dupe(u8, options.state_root);
        if (options.client_id) |id| options.client_id = try a.dupe(u8, id);
        switch (self.flow) {
            .metask => {},
            .api_key => |*prepared| {
                prepared.provider_label = try a.dupe(u8, prepared.provider_label);
                prepared.secret = try a.dupe(u8, prepared.secret);
                self.owns_secret = true;
                const page = &prepared.page;
                page.label = try a.dupe(u8, page.label);
                page.url = try a.dupe(u8, page.url);
                if (page.check_url) |url| page.check_url = try a.dupe(u8, url);
                if (page.region) |region| page.region = try a.dupe(u8, region);
            },
            .oauth => |*prepared| {
                const source = prepared.profile;
                const copy = try a.create(provider_profile.ProviderProfile);
                copy.* = .{
                    .id = source.id,
                    .implementation_id = source.implementation_id,
                    .display_name = try a.dupe(u8, source.display_name),
                    .channels = &.{},
                    .accepted_credential_kinds = try a.dupe(provider_profile.CredentialKind, source.accepted_credential_kinds),
                    .oauth_token_url = if (source.oauth_token_url) |url| try a.dupe(u8, url) else null,
                    .oauth_authorize_url = if (source.oauth_authorize_url) |url| try a.dupe(u8, url) else null,
                    .oauth_device_authorization_url = if (source.oauth_device_authorization_url) |url| try a.dupe(u8, url) else null,
                    .oauth_client_id = if (source.oauth_client_id) |id| try a.dupe(u8, id) else null,
                    .oauth_scope = try a.dupe(u8, source.oauth_scope),
                };
                prepared.profile = copy;
                prepared.client_id = try a.dupe(u8, prepared.client_id);
            },
        }
    }

    /// Idle → running. From here on the worker thread owns the flow until the
    /// state settles and `join` returns.
    pub fn start(self: *LoginWorker) error{ AlreadyStarted, ThreadSpawnFailed }!void {
        const idle = @intFromEnum(State.idle);
        const running = @intFromEnum(State.running);
        if (self.state.cmpxchgStrong(idle, running, .acq_rel, .acquire) != null) return error.AlreadyStarted;
        // A worker that never starts is destroyed without `join`: release the
        // copies on every failure here.
        self.ownFlow() catch {
            self.wipeSecret();
            _ = self.owned.reset(.free_all);
            self.state.store(idle, .release);
            return error.ThreadSpawnFailed;
        };
        self.flow.options().abort_signal = &self.abort_signal;
        self.thread = @import("platform").thread.spawn(.full, run, .{self}) catch {
            self.wipeSecret();
            _ = self.owned.reset(.free_all);
            self.state.store(idle, .release);
            return error.ThreadSpawnFailed;
        };
    }

    fn run(self: *LoginWorker) void {
        _ = self.flow.run(self.allocator, self.io, self.notify(), &self.diagnostic) catch |err| {
            if (err == error.Aborted) {
                self.state.store(@intFromEnum(State.cancelled), .release);
                return;
            }
            const name = @errorName(err);
            const len = @min(name.len, self.failure_name.len);
            @memcpy(self.failure_name[0..len], name[0..len]);
            self.failure_len = len;
            self.state.store(@intFromEnum(State.failed), .release);
            return;
        };
        self.state.store(@intFromEnum(State.succeeded), .release);
    }

    /// Ends the flow at its next 100 ms check; the state becomes `cancelled`.
    pub fn cancel(self: *LoginWorker) void {
        self.abort_signal.abort(.user_interrupt);
    }

    pub fn currentState(self: *const LoginWorker) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    pub fn isSettled(self: *const LoginWorker) bool {
        return switch (self.currentState()) {
            .succeeded, .failed, .cancelled => true,
            .idle, .running => false,
        };
    }

    /// Waits for the thread once; a worker that never started has nothing to
    /// join.
    pub fn join(self: *LoginWorker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        // The thread no longer reads the copies.
        self.wipeSecret();
        _ = self.owned.reset(.free_all);
    }

    /// A pasted key is zeroed before its copy is released, as every other
    /// secret buffer here is.
    fn wipeSecret(self: *LoginWorker) void {
        if (!self.owns_secret) return;
        switch (self.flow) {
            .api_key => |prepared| std.crypto.secureZero(u8, @constCast(prepared.secret)),
            else => {},
        }
        self.owns_secret = false;
    }

    /// Valid after the state read `failed`.
    pub fn failureName(self: *const LoginWorker) []const u8 {
        return self.failure_name[0..self.failure_len];
    }

    /// Valid after the state read `failed`: the failing import step's own
    /// error, when the import refused on a failure rather than a decision.
    pub fn failureCause(self: *const LoginWorker) ?[]const u8 {
        return if (self.diagnostic.cause) |cause| @errorName(cause) else null;
    }

    /// The transcript so far, copied into `out`.
    pub fn copyTranscript(self: *LoginWorker, out: []u8) []const u8 {
        _ = self.transcript_mutex.lock();
        defer _ = self.transcript_mutex.unlock();
        const len = @min(out.len, self.transcript_len);
        @memcpy(out[0..len], self.transcript[0..len]);
        return out[0..len];
    }

    pub fn transcriptTruncated(self: *LoginWorker) bool {
        _ = self.transcript_mutex.lock();
        defer _ = self.transcript_mutex.unlock();
        return self.transcript_truncated;
    }

    /// The sink the flow writes its instructions to.
    pub fn notify(self: *LoginWorker) oauth_login.Notify {
        return .{ .ctx = self, .write = appendTranscript };
    }

    fn appendTranscript(ctx: *anyopaque, text: []const u8) void {
        const self: *LoginWorker = @ptrCast(@alignCast(ctx));
        _ = self.transcript_mutex.lock();
        defer _ = self.transcript_mutex.unlock();
        const room = self.transcript.len - self.transcript_len;
        const len = @min(room, text.len);
        @memcpy(self.transcript[self.transcript_len..][0..len], text[0..len]);
        self.transcript_len += len;
        if (len < text.len) self.transcript_truncated = true;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const util_time = @import("../util/time.zig");
const provider_profile = @import("../provider/profile.zig");
const Slug = @import("../provider/ids.zig").Slug;

fn testProfile(comptime id: []const u8, token_url: []const u8, authorize_url: ?[]const u8, device_url: ?[]const u8) provider_profile.ProviderProfile {
    return .{
        .id = Slug.lit(id),
        .implementation_id = Slug.lit(id),
        .display_name = "Login worker test",
        .channels = &.{},
        .accepted_credential_kinds = &.{.openai_oauth},
        .oauth_token_url = token_url,
        .oauth_authorize_url = authorize_url,
        .oauth_device_authorization_url = device_url,
    };
}

/// Spin (10 ms steps, bounded) until `predicate` holds.
fn waitUntil(worker: *LoginWorker, comptime predicate: fn (*LoginWorker) bool) bool {
    var spins: usize = 0;
    while (spins < 1_000) : (spins += 1) {
        if (predicate(worker)) return true;
        util_time.sleepMs(10);
    }
    return false;
}

fn transcriptNamesUrl(worker: *LoginWorker) bool {
    var buffer: [TRANSCRIPT_CAPACITY]u8 = undefined;
    return std.mem.indexOf(u8, worker.copyTranscript(&buffer), "Open this URL") != null;
}

fn settled(worker: *LoginWorker) bool {
    return worker.isSettled();
}

test "login worker: a loopback login that never gets its callback is cancelled through the signal" {
    const a = std.testing.allocator;
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const profile = testProfile("worker-loopback", "http://127.0.0.1:1/token", "http://127.0.0.1:1/authorize", null);
    // A test must never launch a browser; port 0 keeps a developer's real
    // login server out of the way.
    const prepared = try provider_login.prepareProfile(&profile, .{ .open_browser = false, .port = 0, .client_id = "worker-client", .state_root = "" });

    var worker = LoginWorker.init(a, io_runtime.io(), prepared);
    try worker.start();
    defer worker.join();
    try std.testing.expectError(error.AlreadyStarted, worker.start());
    try std.testing.expect(waitUntil(&worker, transcriptNamesUrl));
    try std.testing.expectEqual(State.running, worker.currentState());

    worker.cancel();
    try std.testing.expect(waitUntil(&worker, settled));
    try std.testing.expectEqual(State.cancelled, worker.currentState());
    try std.testing.expect(!worker.transcriptTruncated());
}

// The failed path (a token endpoint that answers garbage) is the component
// test in tests/component/provider_oauth_login_test.zig: it needs a mock
// server, and a refused connection would print std's `error.Unexpected`
// stack trace on Windows into a passing test's log.
test "login worker: the transcript is bounded and says when it was cut" {
    const a = std.testing.allocator;
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const profile = testProfile("worker-bounded", "http://127.0.0.1:1/token", "http://127.0.0.1:1/authorize", null);
    const prepared = try provider_login.prepareProfile(&profile, .{ .open_browser = false, .port = 0, .client_id = "worker-client", .state_root = "" });
    var worker = LoginWorker.init(a, io_runtime.io(), prepared);

    const sink = worker.notify();
    sink.say("first line\n");
    const filler = [_]u8{'x'} ** (TRANSCRIPT_CAPACITY * 2);
    sink.say(&filler);
    var buffer: [TRANSCRIPT_CAPACITY + 16]u8 = undefined;
    const text = worker.copyTranscript(&buffer);
    try std.testing.expectEqual(TRANSCRIPT_CAPACITY, text.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "first line\n"));
    try std.testing.expect(worker.transcriptTruncated());
    try std.testing.expectEqual(State.idle, worker.currentState());
}
