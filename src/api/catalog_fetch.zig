//! Provider catalog fetching (issue #16, delivery slice P1).
//!
//! `provider/host.zig` ingests catalog *documents* and deliberately cannot
//! fetch them: the provider subsystem must not depend on a transport, which is
//! what keeps `zig build test:provider` able to compile it from a root reaching
//! only `std`, `types.zig`, `util/model.zig`, and `platform`.
//!
//! This is the fetching half. It performs plain authenticated GETs and hands
//! the bytes back; the parsing, offer construction, and events are identical to
//! ingesting the same document from disk, so a catalog refreshed over the
//! network and one refreshed by `curl > file` produce the same offers.

const std = @import("std");
const http_status = @import("http_status.zig");
const http_connection = @import("http_connection.zig");
const models_pages = @import("models_pages.zig");
const auth_header = @import("auth_header.zig");
const platform = @import("platform");
const time = @import("../util/time.zig");

pub const FetchError = error{
    OutOfMemory,
    InvalidUrl,
    RequestFailed,
    /// The credential was refused. Distinct from the rest because it is the one
    /// a retry cannot fix and the user has to act on.
    Unauthorized,
    /// Throttled. A retry is the right response, later.
    RateLimited,
    /// Any other non-2xx answer.
    HttpError,
    /// Larger than a catalog has any business being. An unbounded read from a
    /// URL in a config file is a memory-exhaustion vector.
    TooLarge,
    Interrupted,
};

/// `Request.extra_headers` a GET carries at most.
pub const MAX_EXTRA_HEADERS = 2;

/// Documents above this are refused. OpenRouter's full `/models` is a few
/// hundred kilobytes; 8 MB is generous and still bounded.
pub const MAX_DOCUMENT_BYTES: usize = 8 * 1024 * 1024;

pub const Request = struct {
    url: []const u8,
    /// Optional bearer credential. Catalog endpoints are usually public;
    /// per-account pricing needs one. A request that carries one does not
    /// follow redirects (see `fetch`).
    bearer: ?[]const u8 = null,
    /// A credential placed the way its provider takes it (`AuthScheme`):
    /// Gemini's `x-goog-api-key`, a relay's `x-api-key`. The alternative to
    /// `bearer` (set one of the two); like it, it stops redirects.
    credential: ?Credential = null,
    /// Headers the endpoint needs besides the credential: an Anthropic model
    /// listing's `anthropic-version` (`provider/model_listing.zig`).
    extra_headers: []const std.http.Header = &.{},
    progress: ?*std.atomic.Value(u64) = null,

    /// The credential the request carries, whichever field holds it.
    fn carried(self: Request) ?Credential {
        if (self.credential) |value| return value;
        const secret = self.bearer orelse return null;
        return .{ .scheme = .bearer, .secret = secret };
    }
};

/// A secret and where the provider reads it (`provider/credential.zig`).
pub const Credential = struct {
    scheme: auth_header.AuthScheme,
    secret: []const u8,
};

/// The document. The status is not returned: a 2xx is the only success, and
/// every failure is already distinguished by the error itself.
pub const Response = struct {
    /// Owned by the caller.
    body: []u8,
};

/// What a GET answered, whatever the status: a key check reads why a key was
/// refused from the body (Gemini answers a wrong key with 400 and
/// `API_KEY_INVALID`), which `fetch` reduces to an error.
pub const Answer = struct {
    status: u16,
    /// Owned by the caller.
    body: []u8,
};

/// GET one catalog document.
pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) FetchError!Response {
    const answer = try fetchAnswer(allocator, io, request);
    if (answer.status >= 200 and answer.status < 300) return .{ .body = answer.body };
    allocator.free(answer.body);
    return switch (answer.status) {
        401, 403 => error.Unauthorized,
        429 => error.RateLimited,
        else => error.HttpError,
    };
}

/// GET `request.url` and return the status with the body, a refusal's
/// included. Errors are the ones no status explains: the URL, the transport,
/// the size, the credential's placement.
pub fn fetchAnswer(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) FetchError!Answer {
    const uri = std.Uri.parse(request.url) catch return error.InvalidUrl;

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const credential = request.carried();
    var authorization: ?auth_header.Header = null;
    defer if (authorization) |header| {
        std.crypto.secureZero(u8, header.value);
        allocator.free(header.value);
    };
    if (request.extra_headers.len > MAX_EXTRA_HEADERS) return error.RequestFailed;
    var headers: [2 + MAX_EXTRA_HEADERS]std.http.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "accept", .value = "application/json" };
    header_count += 1;
    for (request.extra_headers) |header| {
        headers[header_count] = header;
        header_count += 1;
    }
    if (credential) |value| {
        authorization = auth_header.build(allocator, value.scheme, value.secret) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A placement this GET cannot make (a signed request) or nothing
            // to place: it is not sent without the credential instead.
            error.SignedAdapterRequired, error.EmptyCredentialMaterial => return error.RequestFailed,
        };
        headers[header_count] = .{ .name = authorization.?.name, .value = authorization.?.value };
        header_count += 1;
    }

    var http_request = client.request(.GET, uri, .{
        .extra_headers = headers[0..header_count],
        // std's client re-sends `extra_headers` on every redirect hop,
        // whatever host it points at, and in 0.16 never sends
        // `privileged_headers` at all. A credential therefore never follows a
        // redirect: the 3xx is answered as the non-2xx it is (`HttpError`).
        // That also keeps a key check honest — a host that never saw the key
        // has nothing to say about it.
        .redirect_behavior = if (credential == null) @enumFromInt(3) else .unhandled,
    }) catch return error.RequestFailed;
    defer http_request.deinit();

    http_connection.sendBodiless(&http_request) catch return error.RequestFailed;
    var redirect_buffer: [4096]u8 = undefined;
    const response = http_connection.receiveHead(&http_request, &redirect_buffer) catch return error.RequestFailed;
    const status = http_status.ResponseStatus.capture(&response);
    const announced = response.head.content_length;

    var transfer_buffer: [16384]u8 = undefined;
    const reader = http_connection.bodyReader(&response, &transfer_buffer);
    var count_buffer: [4096]u8 = undefined;
    var counting: CountingReader = undefined;
    const source = if (request.progress) |counter| blk: {
        counting = .init(reader, counter, &count_buffer);
        break :blk &counting.interface;
    } else reader;
    const body = source.allocRemaining(allocator, std.Io.Limit.limited(MAX_DOCUMENT_BYTES)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        error.ReadFailed => error.Interrupted,
    };
    if (status.code >= 200 and status.code < 300) if (announced) |length| if (body.len < length) {
        allocator.free(body);
        return error.Interrupted;
    };
    return .{ .status = status.code, .body = body };
}

const CountingReader = struct {
    inner: *std.Io.Reader,
    counter: *std.atomic.Value(u64),
    interface: std.Io.Reader,

    fn init(inner: *std.Io.Reader, counter: *std.atomic.Value(u64), buffer: []u8) CountingReader {
        return .{
            .inner = inner,
            .counter = counter,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CountingReader = @fieldParentPtr("interface", r);
        const n = try self.inner.stream(w, limit);
        _ = self.counter.fetchAdd(n, .monotonic);
        return n;
    }
};

/// GET a `/v1/models` list and every page after it (`has_more` + `last_id`,
/// see `models_pages.zig`), as one document. A single-page list comes back
/// byte for byte; a continuation that fails keeps the pages already read
/// rather than discarding the whole list.
pub fn fetchModelPages(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) FetchError!Response {
    const first = try fetch(allocator, io, request);
    var pages: std.ArrayList([]u8) = .empty;
    defer {
        for (pages.items) |page| allocator.free(page);
        pages.deinit(allocator);
    }
    pages.append(allocator, first.body) catch {
        allocator.free(first.body);
        return error.OutOfMemory;
    };
    while (pages.items.len < models_pages.MAX_PAGES) {
        const cursor = (try models_pages.nextCursor(allocator, pages.items[pages.items.len - 1])) orelse break;
        defer allocator.free(cursor);
        const url = try models_pages.continuationUrl(allocator, request.url, cursor);
        defer allocator.free(url);
        const next = fetch(allocator, io, .{ .url = url, .bearer = request.bearer, .credential = request.credential, .extra_headers = request.extra_headers }) catch break;
        pages.append(allocator, next.body) catch {
            allocator.free(next.body);
            return error.OutOfMemory;
        };
    }
    if (pages.items.len == 1) {
        const only = pages.items[0];
        pages.clearRetainingCapacity();
        return .{ .body = only };
    }
    return .{ .body = try models_pages.merge(allocator, pages.items) };
}

pub const Detached = struct {
    refs: std.atomic.Value(u8) = .init(2),
    lock: platform.sync.Mutex = .{},
    settled: platform.sync.Condition = .{},
    outcome: Outcome = .running,
    url: []u8,
    bearer: []u8,

    const Outcome = union(enum) { running, fetched: []u8, failed: FetchError, taken };

    const gpa = std.heap.c_allocator;

    pub fn start(url: []const u8, bearer: []const u8) !*Detached {
        const self = try gpa.create(Detached);
        errdefer gpa.destroy(self);
        self.* = .{ .url = try gpa.dupe(u8, url), .bearer = undefined };
        errdefer gpa.free(self.url);
        self.bearer = try gpa.dupe(u8, bearer);
        errdefer secureFree(self.bearer);
        const thread = try platform.thread.spawn(.full, run, .{self});
        thread.detach();
        return self;
    }

    pub fn wait(self: *Detached, timeout_ms: u32) ?FetchError![]u8 {
        const deadline = time.nowMs() + timeout_ms;
        self.lock.lock();
        defer self.lock.unlock();
        while (self.outcome == .running) {
            const left = deadline - time.nowMs();
            if (left <= 0) return null;
            _ = self.settled.timedWait(&self.lock, @as(u64, @intCast(left)) * std.time.ns_per_ms);
        }
        const outcome = self.outcome;
        self.outcome = .taken;
        return switch (outcome) {
            .fetched => |body| body,
            .failed => |err| err,
            .running, .taken => error.RequestFailed,
        };
    }

    pub fn release(self: *Detached) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        switch (self.outcome) {
            .fetched => |body| gpa.free(body),
            .running, .failed, .taken => {},
        }
        gpa.free(self.url);
        secureFree(self.bearer);
        gpa.destroy(self);
    }

    fn run(self: *Detached) void {
        defer self.release();
        var threaded = platform.signal.threadedIo(gpa, .{});
        defer threaded.deinit();
        const outcome: Outcome = if (fetchModelPages(gpa, threaded.io(), .{ .url = self.url, .bearer = self.bearer })) |response|
            .{ .fetched = response.body }
        else |err|
            .{ .failed = err };
        self.lock.lock();
        defer self.lock.unlock();
        self.outcome = outcome;
        self.settled.broadcast();
    }

    fn secureFree(bytes: []u8) void {
        std.crypto.secureZero(u8, bytes);
        gpa.free(bytes);
    }
};
