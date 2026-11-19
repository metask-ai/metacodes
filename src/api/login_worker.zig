//! A prepared provider login on a worker thread (#67).
//!
//! `provider_login.Prepared.run` blocks until the browser calls back (or the
//! device grant is approved); the TUI's render loop must not. The worker runs
//! the flow on its own thread, points the flow's `AbortSignal` at its own so
//! `Esc` can end it, and keeps a bounded transcript of what the flow asks the
//! user to do — the URL to open, the device code — for `/login`'s pane to
//! draw.
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
                if (page.url) |url| page.url = try a.dupe(u8, url);
                if (page.check_url) |url| page.check_url = try a.dupe(u8, url);
                if (page.region) |region| page.region = try a.dupe(u8, region);
                // A configured provider's header name lives in its config.
                prepared.auth = switch (prepared.auth) {
                    .bearer => .bearer,
                    .api_key_header => |name| .{ .api_key_header = try a.dupe(u8, name) },
                    .custom_header => |custom| .{ .custom_header = .{
                        .name = try a.dupe(u8, custom.name),
                        .value_prefix = try a.dupe(u8, custom.value_prefix),
                    } },
                    .signed_adapter => |adapter| .{ .signed_adapter = try a.dupe(u8, adapter) },
                };
            },
            .oauth => |*prepared| {
                const source = prepared.profile;
                const copy = try a.create(provider_profile.ProviderProfile);
                // The whole profile, so whatever it declares reaches the
                // flow without being listed here. A list of fields left the
                // ones added later at their defaults: ChatGPT (Codex) then
                // waited on port 1456 instead of its registered 1455/1457,
                // sent none of its authorization parameters, and never said
                // its sign-in is unofficial (#550).
                copy.* = source.*;
                // What the flow reads on its thread moves into `owned`
                // (`owned_profile_fields` in the tests). The rest is never
                // read here and stays as the registry holds it.
                copy.display_name = try a.dupe(u8, source.display_name);
                copy.accepted_credential_kinds = try a.dupe(provider_profile.CredentialKind, source.accepted_credential_kinds);
                copy.oauth_token_url = if (source.oauth_token_url) |url| try a.dupe(u8, url) else null;
                copy.oauth_authorize_url = if (source.oauth_authorize_url) |url| try a.dupe(u8, url) else null;
                copy.oauth_device_authorization_url = if (source.oauth_device_authorization_url) |url| try a.dupe(u8, url) else null;
                copy.oauth_redirect_host = try a.dupe(u8, source.oauth_redirect_host);
                copy.oauth_callback_ports = try a.dupe(u16, source.oauth_callback_ports);
                const params = try a.alloc(provider_profile.OAuthParam, source.oauth_authorize_params.len);
                for (params, source.oauth_authorize_params) |*param, declared| param.* = .{
                    .name = try a.dupe(u8, declared.name),
                    .value = try a.dupe(u8, declared.value),
                };
                copy.oauth_authorize_params = params;
                copy.oauth_client_id = if (source.oauth_client_id) |id| try a.dupe(u8, id) else null;
                copy.oauth_scope = try a.dupe(u8, source.oauth_scope);
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

const chatgpt_codex = @import("../provider/profiles/chatgpt_codex.zig");

/// The profile fields `ownFlow` moves into the worker's memory: the strings
/// and lists the flow reads on its thread. Every other field of the copy is
/// the source's own value.
const owned_profile_fields = [_][]const u8{
    "display_name",
    "accepted_credential_kinds",
    "oauth_token_url",
    "oauth_authorize_url",
    "oauth_device_authorization_url",
    "oauth_redirect_host",
    "oauth_callback_ports",
    "oauth_authorize_params",
    "oauth_client_id",
    "oauth_scope",
};

fn isOwnedProfileField(comptime name: []const u8) bool {
    // Evaluated at comptime once per profile field, every name compared.
    @setEvalBranchQuota(20_000);
    for (owned_profile_fields) |owned| {
        if (std.mem.eql(u8, owned, name)) return true;
    }
    return false;
}

/// Equal by content, wherever it lives: how an owned field compares.
fn sameContent(a: anytype, b: @TypeOf(a)) bool {
    switch (@typeInfo(@TypeOf(a))) {
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return sameContent(a.?, b.?);
        },
        .pointer => {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!sameContent(x, y)) return false;
            return true;
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!sameContent(@field(a, field.name), @field(b, field.name))) return false;
            }
            return true;
        },
        else => return a == b,
    }
}

/// The source's content, in memory of the copy's own.
fn expectOwnedCopy(ours: anytype, theirs: @TypeOf(ours)) !void {
    switch (@typeInfo(@TypeOf(ours))) {
        .optional => {
            try std.testing.expectEqual(theirs == null, ours == null);
            if (theirs) |value| try expectOwnedCopy(ours.?, value);
        },
        .pointer => |pointer| {
            try std.testing.expectEqual(theirs.len, ours.len);
            if (theirs.len > 0) try std.testing.expect(ours.ptr != theirs.ptr);
            if (pointer.child == provider_profile.OAuthParam) {
                for (ours, theirs) |mine, declared| {
                    try expectOwnedCopy(mine.name, declared.name);
                    try expectOwnedCopy(mine.value, declared.value);
                }
            } else {
                try std.testing.expectEqualSlices(pointer.child, theirs, ours);
            }
        },
        else => @compileError("ownFlow moves strings and lists only, not " ++ @typeName(@TypeOf(ours))),
    }
}

fn workerTestQuote(request_model_id: []const u8, channel_id: Slug, usage: provider_profile.Usage) provider_profile.Quote {
    _ = request_model_id;
    _ = channel_id;
    _ = usage;
    return .unknown;
}

test "login worker: a sign-in runs on the profile it was given, every field, with the strings and lists it reads its own" {
    // Two comptime walks over every profile field, each naming the owned ones.
    @setEvalBranchQuota(100_000);
    const a = std.testing.allocator;
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();

    // ChatGPT (Codex), with every field moved off its default: a copy that
    // left any field at its default, as the field list before #550 left the
    // callback ports, the authorization parameters and the support level,
    // differs from it below.
    var source = chatgpt_codex.PROFILE;
    source.aliases = &.{"codex-worker-test"};
    source.env_aliases = &.{.{ .name = "CODEX_WORKER_TEST_TOKEN", .kind = chatgpt_codex.PROFILE.accepted_credential_kinds[0] }};
    source.auth = .{ .api_key_header = "x-worker-test" };
    source.endpoint_policy = .{ .require_tls = false };
    source.quote_hook = workerTestQuote;
    source.oauth_device_authorization_url = "http://127.0.0.1:1/device";
    source.oauth_redirect_host = "127.0.0.1";
    source.api_key_setup = .{
        .kind = chatgpt_codex.PROFILE.accepted_credential_kinds[0],
        .pages = &.{.{ .id = Slug.lit("worker"), .label = "Worker test", .url = "http://127.0.0.1:1/keys" }},
    };
    const fields = @typeInfo(provider_profile.ProviderProfile).@"struct".fields;
    // A field ProviderProfile gains fails here until this profile sets it, so
    // the check below covers it too.
    inline for (fields) |field| {
        const value = @field(source, field.name);
        if (comptime field.defaultValue()) |default| {
            const unchanged = if (comptime isOwnedProfileField(field.name)) sameContent(value, default) else std.meta.eql(value, default);
            if (unchanged) {
                std.debug.print("the test profile leaves `{s}` at its default: set it, so a copy that drops it fails here\n", .{field.name});
                return error.TestUnexpectedResult;
            }
        } else if (comptime @typeInfo(field.type) == .pointer) {
            try std.testing.expect(value.len > 0);
        }
    }

    var worker = LoginWorker.init(a, io_runtime.io(), .{
        .profile = &source,
        .client_id = "worker-client",
        .client_id_source = .explicit,
        .options = .{ .open_browser = false, .state_root = "" },
    });
    defer worker.join();
    try worker.ownFlow();

    const copy = worker.flow.oauth.profile;
    try std.testing.expect(copy != &source);
    inline for (fields) |field| {
        const ours = @field(copy.*, field.name);
        const theirs = @field(source, field.name);
        if (comptime isOwnedProfileField(field.name)) {
            expectOwnedCopy(ours, theirs) catch |err| {
                std.debug.print("the worker's copy of `{s}` is not the profile's, in memory of its own\n", .{field.name});
                return err;
            };
        } else if (!std.meta.eql(ours, theirs)) {
            std.debug.print("the worker's copy changed `{s}`\n", .{field.name});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqualStrings("worker-client", worker.flow.oauth.client_id);
}
