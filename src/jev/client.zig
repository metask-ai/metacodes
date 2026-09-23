//! HTTP transport for a TypeSafe-Jev-compatible System-One service
//! (`POST /v1/systemone`, see `question.zig` for the typed payload).
//!
//! A System-One judgment is advisory: every caller keeps a deterministic
//! baseline and falls back to it on any error. The transport's job is to make
//! that fallback cheap and bounded:
//!
//! - Every call has a hard end-to-end deadline. `std.http.Client` exposes no
//!   request timeout in Zig 0.16, so the complete exchange (connect, send,
//!   head, body) races an awake-clock deadline and the caller's abort signal
//!   in one `std.Io.Select`, the same shape as the TinyKG web transport.
//!   Cancelation interrupts and joins the losing task, so nothing outlives
//!   the call.
//! - A service failure opens a breaker, so a dead or black-holed service costs
//!   one deadline per cooldown instead of one per call. A user abort or a
//!   refused request is not the service's fault and leaves the breaker alone.
//! - Nothing is retried: the questions are pure functions of the state and
//!   the caller's baseline is always available.
//! - A host abort is reported as `Aborted`, never folded into `Unavailable`:
//!   a cancellation must stop the caller, not be absorbed as "the advisor was
//!   down, use the baseline and carry on".
//! - There is no spend accounting for System-One calls, so only a service
//!   that declares itself free (`usage.tariff == "none"`) is accepted; a
//!   priced or silent service is refused until a budget account exists.

const std = @import("std");
const sync = @import("platform").sync;
const question = @import("question.zig");
const ResponseStatus = @import("../api/http_status.zig").ResponseStatus;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const ENDPOINT_PATH = "/v1/systemone";
/// An eight-candidate recall judgment against the self-hosted service took
/// 0.91 s at the median and 1.06 s at p99 from one client, but 2.4 s at the
/// median with three clients sharing it (2026-09-24). A miss falls back and
/// opens the breaker, so the deadline leaves room for a shared service.
pub const DEFAULT_TIMEOUT_MS: u32 = 2_500;
pub const MIN_TIMEOUT_MS: u32 = 100;
pub const MAX_TIMEOUT_MS: u32 = 30_000;
/// The service renders `state` plus the questions into at most 4096 tokens
/// and answers 422 instead of truncating. Callers budget their excerpts
/// against this byte cap so a 422 is a bug, not a routine event.
pub const MAX_STATE_BYTES: usize = 6 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 64 * 1024;
pub const BREAKER_INITIAL_MS: u64 = 30_000;
pub const BREAKER_MAX_MS: u64 = 5 * 60_000;
/// How often the abort watcher re-checks the caller's signal.
const ABORT_POLL_MS: i64 = 50;

pub const Config = struct {
    /// Service origin: `http://host:port` or `https://host[:port]`, no path.
    origin: []const u8,
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
    /// When set, an answer from any other model is refused, so an alias that
    /// moves under a frozen evaluation cannot change the judge silently.
    expected_model: ?[]const u8 = null,
};

pub const ConfigError = error{ OutOfMemory, InvalidOrigin, InvalidTimeout, InvalidModel };

pub const AskError = error{
    OutOfMemory,
    /// The question set or the state violated the documented bounds; a
    /// caller bug, never sent.
    InvalidRequest,
    /// The caller's abort signal fired. Propagate it; do not treat it as an
    /// advisor outage.
    Aborted,
    /// Timed out, breaker open, transport failure or 5xx.
    Unavailable,
    /// The service refused the request (non-2xx other than 5xx, or an
    /// `error`/`partial_errors` body).
    Rejected,
    /// A 200 answer that is not the documented shape.
    MalformedResponse,
    /// The service did not declare `usage.tariff == "none"`.
    PricedService,
    /// The answering model differs from `Config.expected_model`.
    ModelMismatch,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    /// `origin ++ ENDPOINT_PATH`, owned.
    url: []u8,
    timeout_ms: u32,
    /// Owned copy of `Config.expected_model`.
    expected_model: ?[]u8,
    mutex: sync.Mutex = .{},
    breaker_until_ms: i64 = 0,
    breaker_backoff_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) ConfigError!Client {
        if (config.timeout_ms < MIN_TIMEOUT_MS or config.timeout_ms > MAX_TIMEOUT_MS) return error.InvalidTimeout;
        const origin = std.mem.trimEnd(u8, config.origin, "/");
        if (!validOrigin(origin)) return error.InvalidOrigin;
        if (config.expected_model) |model| {
            if (std.mem.trim(u8, model, " \t\r\n").len == 0) return error.InvalidModel;
        }
        const url = try std.mem.concat(allocator, u8, &.{ origin, ENDPOINT_PATH });
        errdefer allocator.free(url);
        const expected_model = if (config.expected_model) |model| try allocator.dupe(u8, model) else null;
        return .{
            .allocator = allocator,
            .http_client = .{ .allocator = allocator, .io = io },
            .url = url,
            .timeout_ms = config.timeout_ms,
            .expected_model = expected_model,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.allocator.free(self.url);
        if (self.expected_model) |model| self.allocator.free(model);
        self.* = undefined;
    }

    /// Ask `questions` about `state`. The answers are allocated from
    /// `allocator`, which must stay valid for the returned `Answers`.
    pub fn ask(
        self: *Client,
        allocator: std.mem.Allocator,
        abort: ?*const AbortSignal,
        state: []const u8,
        questions: []const question.Named,
    ) AskError!question.Answers {
        question.validate(questions) catch return error.InvalidRequest;
        if (state.len == 0 or state.len > MAX_STATE_BYTES) return error.InvalidRequest;
        if (abort) |signal| if (signal.isAborted()) return error.Aborted;
        if (self.breakerOpen()) {
            log.debug("jev", "breaker open; skipping {d} question(s)", .{questions.len});
            return error.Unavailable;
        }

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        try question.writeRequest(&body, allocator, state, questions);

        const started_ms = util_time.nowMs();
        const exchange = self.exchangeBeforeDeadline(allocator, body.items, abort) catch |err| {
            const elapsed_ms = util_time.nowMs() - started_ms;
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Aborted => {
                    log.info("jev", "aborted after {d}ms", .{elapsed_ms});
                    return error.Aborted;
                },
                error.TimedOut => {
                    self.openBreaker();
                    log.warn("jev", "no answer within {d}ms; falling back", .{self.timeout_ms});
                },
                error.TransportFailed => {
                    self.openBreaker();
                    log.warn("jev", "transport failure after {d}ms; falling back", .{elapsed_ms});
                },
            }
            return error.Unavailable;
        };
        defer allocator.free(exchange.body);
        const elapsed_ms = util_time.nowMs() - started_ms;

        if (exchange.status >= 500) {
            self.openBreaker();
            log.warn("jev", "service error status={d} after {d}ms", .{ exchange.status, elapsed_ms });
            return error.Unavailable;
        }
        if (exchange.status != 200) {
            log.warn("jev", "request refused status={d}", .{exchange.status});
            return error.Rejected;
        }
        var answers = question.parseResponse(allocator, questions, exchange.body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ServiceRejected => {
                log.warn("jev", "service rejected a validated question set", .{});
                return error.Rejected;
            },
            else => {
                self.openBreaker();
                log.warn("jev", "malformed answer: {s}", .{@errorName(err)});
                return error.MalformedResponse;
            },
        };
        errdefer answers.deinit();
        // Both refusals are configuration facts, not transient faults; the
        // breaker keeps a misconfigured service from being asked every turn.
        if (!std.mem.eql(u8, answers.tariff, "none")) {
            self.openBreaker();
            log.warn("jev", "service tariff '{s}' is not 'none'; System-One calls have no spend accounting", .{answers.tariff});
            return error.PricedService;
        }
        if (self.expected_model) |expected| {
            if (!std.mem.eql(u8, answers.model, expected)) {
                self.openBreaker();
                log.warn("jev", "answered by model '{s}', pinned '{s}'", .{ answers.model, expected });
                return error.ModelMismatch;
            }
        }
        self.closeBreaker();
        log.info("jev", "answered {d} question(s) state_bytes={d} in {d}ms model={s}", .{ questions.len, state.len, elapsed_ms, answers.model });
        return answers;
    }

    const Exchange = struct {
        status: u16,
        /// Owned by the `allocator` passed to `ask`.
        body: []u8,
    };

    const ExchangeError = error{ OutOfMemory, TransportFailed, TimedOut, Aborted };

    const Race = union(enum) {
        response: ExchangeError!Exchange,
        deadline: std.Io.Cancelable!void,
        aborted: std.Io.Cancelable!void,
    };

    fn exchangeBeforeDeadline(
        self: *Client,
        allocator: std.mem.Allocator,
        body: []const u8,
        abort: ?*const AbortSignal,
    ) ExchangeError!Exchange {
        const io = self.http_client.io;
        var results: [3]Race = undefined;
        var race = std.Io.Select(Race).init(io, &results);
        errdefer race.cancelDiscard();
        race.concurrent(.response, exchangeTask, .{ self, allocator, body }) catch return error.TransportFailed;
        race.concurrent(.deadline, deadlineTask, .{ io, self.timeout_ms }) catch return error.TransportFailed;
        if (abort) |signal| race.concurrent(.aborted, abortTask, .{ io, signal }) catch return error.TransportFailed;

        const first = race.await() catch return error.TransportFailed;
        switch (first) {
            .response => |response| {
                race.cancelDiscard();
                return response;
            },
            .deadline, .aborted => {
                // The exchange can finish at the boundary: drain a successful
                // late result instead of leaking its body.
                while (race.cancel()) |late| switch (late) {
                    .response => |response| if (response) |exchange| allocator.free(exchange.body) else |_| {},
                    .deadline, .aborted => {},
                };
                return if (first == .deadline) error.TimedOut else error.Aborted;
            },
        }
    }

    fn exchangeTask(self: *Client, allocator: std.mem.Allocator, body: []const u8) ExchangeError!Exchange {
        const uri = std.Uri.parse(self.url) catch return error.TransportFailed;
        var request = self.http_client.request(.POST, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "application/json" },
            },
        }) catch return error.TransportFailed;
        defer request.deinit();
        request.sendBodyComplete(@constCast(body)) catch return error.TransportFailed;
        var redirect_buffer: [1024]u8 = undefined;
        const response = request.receiveHead(&redirect_buffer) catch return error.TransportFailed;
        const status = ResponseStatus.capture(&response);
        var transfer_buffer: [8192]u8 = undefined;
        const reader = request.reader.bodyReader(
            &transfer_buffer,
            response.head.transfer_encoding,
            response.head.content_length,
        );
        const bytes = reader.allocRemaining(allocator, .limited(MAX_RESPONSE_BYTES)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransportFailed,
        };
        return .{ .status = status.code, .body = bytes };
    }

    fn deadlineTask(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
        return std.Io.Timeout.sleep(.{ .duration = .{
            .raw = .fromMilliseconds(@as(i64, timeout_ms)),
            .clock = .awake,
        } }, io);
    }

    fn abortTask(io: std.Io, signal: *const AbortSignal) std.Io.Cancelable!void {
        while (!signal.isAborted()) {
            try std.Io.Timeout.sleep(.{ .duration = .{
                .raw = .fromMilliseconds(ABORT_POLL_MS),
                .clock = .awake,
            } }, io);
        }
    }

    fn breakerOpen(self: *Client) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return util_time.nowMs() < self.breaker_until_ms;
    }

    fn openBreaker(self: *Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.breaker_backoff_ms = if (self.breaker_backoff_ms == 0)
            BREAKER_INITIAL_MS
        else
            @min(self.breaker_backoff_ms * 2, BREAKER_MAX_MS);
        self.breaker_until_ms = util_time.nowMs() + @as(i64, @intCast(self.breaker_backoff_ms));
    }

    fn closeBreaker(self: *Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.breaker_backoff_ms = 0;
        self.breaker_until_ms = 0;
    }
};

fn validOrigin(origin: []const u8) bool {
    const uri = std.Uri.parse(origin) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return false;
    if (uri.host == null) return false;
    if (!uri.path.isEmpty() or uri.query != null or uri.fragment != null or uri.user != null) return false;
    return true;
}

// ============================================================================
// Tests (transport behavior against a live socket lives in
// tests/component/jev_client_test.zig; these cover configuration only)
// ============================================================================

const testing = std.testing;

const probe_question = [_]question.Named{.{ .name = "q", .question = .{ .boolean = .{
    .description = "d",
    .when_true = "t",
    .when_false = "f",
} } }};

test "init accepts a bare origin and appends the endpoint path" {
    var client = try Client.init(testing.allocator, testing.io, .{ .origin = "http://127.0.0.1:10420/" });
    defer client.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:10420/v1/systemone", client.url);
    try testing.expectEqual(DEFAULT_TIMEOUT_MS, client.timeout_ms);
}

test "init rejects origins that would send the payload somewhere unexpected" {
    const bad = [_][]const u8{
        "",
        "58.211.6.133:10420",
        "ftp://example.com",
        "http://example.com/v1/systemone",
        "http://example.com?x=1",
        "http://user@example.com",
        "http://",
    };
    for (bad) |origin| {
        try testing.expectError(error.InvalidOrigin, Client.init(testing.allocator, testing.io, .{ .origin = origin }));
    }
    try testing.expectError(error.InvalidTimeout, Client.init(testing.allocator, testing.io, .{ .origin = "http://h", .timeout_ms = 1 }));
    try testing.expectError(error.InvalidTimeout, Client.init(testing.allocator, testing.io, .{ .origin = "http://h", .timeout_ms = MAX_TIMEOUT_MS + 1 }));
    try testing.expectError(error.InvalidModel, Client.init(testing.allocator, testing.io, .{ .origin = "http://h", .expected_model = " " }));
}

test "ask refuses an oversized or empty state before touching the network" {
    var client = try Client.init(testing.allocator, testing.io, .{ .origin = "http://127.0.0.1:9" });
    defer client.deinit();
    try testing.expectError(error.InvalidRequest, client.ask(testing.allocator, null, "", &probe_question));
    const big = [_]u8{'x'} ** (MAX_STATE_BYTES + 1);
    try testing.expectError(error.InvalidRequest, client.ask(testing.allocator, null, &big, &probe_question));
    try testing.expectError(error.InvalidRequest, client.ask(testing.allocator, null, "state", &.{}));
}

test "an open breaker fails fast and backs off exponentially" {
    var client = try Client.init(testing.allocator, testing.io, .{ .origin = "http://127.0.0.1:9" });
    defer client.deinit();
    client.openBreaker();
    try testing.expectEqual(BREAKER_INITIAL_MS, client.breaker_backoff_ms);
    try testing.expectError(error.Unavailable, client.ask(testing.allocator, null, "state", &probe_question));
    client.openBreaker();
    try testing.expectEqual(BREAKER_INITIAL_MS * 2, client.breaker_backoff_ms);
    var i: usize = 0;
    while (i < 16) : (i += 1) client.openBreaker();
    try testing.expectEqual(BREAKER_MAX_MS, client.breaker_backoff_ms);
    client.closeBreaker();
    try testing.expect(!client.breakerOpen());
}
