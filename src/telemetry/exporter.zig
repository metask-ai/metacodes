//! OTLP/HTTP batch span exporter.
//!
//! The shape of the specification's BatchSpanProcessor + OTLP exporter:
//! a span is encoded the moment it ends (on the caller's thread, under the
//! exporter's content policy), queued, and a single worker thread posts
//! batches to the collector every `schedule_delay_ms`, or sooner once a full
//! batch is waiting. Nothing about the export can stall a Run:
//!
//! - The queue is bounded (`max_queue_size`); a span that does not fit is
//!   dropped and counted, never blocks the caller.
//! - Each POST races a deadline (`timeout_ms`) on the awake clock, the same
//!   pattern as the TinyKG and System-One transports: `std.http.Client` has
//!   no request timeout in Zig 0.16. A black-holed collector costs one
//!   timeout per batch, not a hung thread.
//! - A failed export is logged and its batch dropped; the specification
//!   allows retries, but a retry queue in front of a dead collector only
//!   delays the drop and holds memory.
//! - `shutdown` flushes what is queued with the same per-request deadline and
//!   joins the worker, so a headless `metacodes -p` exits with its spans sent.

const std = @import("std");
const platform = @import("platform");
const sync = platform.sync;
const otlp = @import("otlp.zig");
const span_mod = @import("span.zig");
const config_mod = @import("config.zig");
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");
const http_connection = @import("../api/http_connection.zig");

pub const Stats = struct {
    exported: u64 = 0,
    dropped: u64 = 0,
    failed_batches: u64 = 0,
};

pub const Exporter = struct {
    gpa: std.mem.Allocator,
    /// Owns every slice of `config`.
    arena: std.heap.ArenaAllocator,
    config: config_mod.Exporter,
    scope: otlp.Scope,
    /// `config.headers` plus the content type, as `std.http.Header`s.
    http_headers: []const std.http.Header,

    mutex: sync.Mutex = .{},
    /// Signalled on enqueue, flush request, stop and after every export.
    cond: sync.Condition = .{},
    queue: std.ArrayList([]u8) = .empty,
    stopping: bool = false,
    flush_requested: bool = false,
    in_flight: bool = false,
    stats: Stats = .{},
    warned_drop: bool = false,
    thread: std.Thread = undefined,

    /// Take ownership of `arena` (which holds `config`), on failure too, and
    /// start the worker. Allocate everything in `arena` before the call: the
    /// arena is copied.
    pub fn start(gpa: std.mem.Allocator, arena: std.heap.ArenaAllocator, config: config_mod.Exporter, scope_version: []const u8) !*Exporter {
        const self = gpa.create(Exporter) catch |err| {
            arena.deinit();
            return err;
        };
        errdefer {
            self.arena.deinit();
            gpa.destroy(self);
        }
        self.* = .{
            .gpa = gpa,
            .arena = arena,
            .config = config,
            .scope = .{ .version = scope_version },
            .http_headers = &.{},
        };
        const a = self.arena.allocator();
        const headers = try a.alloc(std.http.Header, config.headers.len + 1);
        headers[0] = .{ .name = "content-type", .value = config.protocol.contentType() };
        for (config.headers, 1..) |h, i| headers[i] = .{ .name = h.name, .value = h.value };
        self.http_headers = headers;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    /// Encode `s` under this exporter's content policy and queue it.
    /// Never blocks on the network; a full queue drops the span.
    pub fn enqueue(self: *Exporter, s: *const span_mod.Span) void {
        const bytes = otlp.encodeSpan(self.gpa, self.config.protocol, s, self.policy()) catch {
            self.countDrop();
            return;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping or self.queue.items.len >= self.config.max_queue_size) {
            self.gpa.free(bytes);
            self.dropLocked();
            return;
        }
        self.queue.append(self.gpa, bytes) catch {
            self.gpa.free(bytes);
            self.dropLocked();
            return;
        };
        if (self.queue.items.len >= self.config.max_export_batch_size) self.cond.broadcast();
    }

    pub fn policy(self: *const Exporter) otlp.ContentPolicy {
        return .{ .include = self.config.capture_content };
    }

    /// Ask the worker to export everything queued now, and wait until it has
    /// (or `timeout_ms` passes). True when the queue drained.
    pub fn forceFlush(self: *Exporter, timeout_ms: u32) bool {
        const deadline = util_time.nowMs() + timeout_ms;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flush_requested = true;
        self.cond.broadcast();
        while (self.queue.items.len > 0 or self.in_flight) {
            const now = util_time.nowMs();
            if (now >= deadline) return false;
            _ = self.cond.timedWait(&self.mutex, @as(u64, @intCast(deadline - now)) * std.time.ns_per_ms);
        }
        return true;
    }

    /// Flush, stop and join the worker, then free everything.
    pub fn shutdown(self: *Exporter) void {
        self.mutex.lock();
        self.stopping = true;
        self.cond.broadcast();
        self.mutex.unlock();
        self.thread.join();
        for (self.queue.items) |b| self.gpa.free(b);
        self.queue.deinit(self.gpa);
        if (self.stats.dropped > 0 or self.stats.failed_batches > 0)
            log.warn("otel", "exporter stopped: {d} spans exported, {d} dropped, {d} failed batches", .{ self.stats.exported, self.stats.dropped, self.stats.failed_batches });
        self.arena.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn snapshotStats(self: *Exporter) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    fn countDrop(self: *Exporter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.dropLocked();
    }

    fn dropLocked(self: *Exporter) void {
        self.stats.dropped += 1;
        if (!self.warned_drop) {
            self.warned_drop = true;
            log.warn("otel", "span queue full ({d}); dropping spans until the collector catches up", .{self.config.max_queue_size});
        }
    }

    fn worker(self: *Exporter) void {
        var threaded = platform.signal.threadedIo(self.gpa, .{});
        defer threaded.deinit();
        var client: std.http.Client = .{ .allocator = self.gpa, .io = threaded.io() };
        defer client.deinit();

        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (!self.stopping and !self.flush_requested and self.queue.items.len < self.config.max_export_batch_size) {
                _ = self.cond.timedWait(&self.mutex, @as(u64, self.config.schedule_delay_ms) * std.time.ns_per_ms);
            }
            if (self.queue.items.len == 0) {
                self.flush_requested = false;
                self.cond.broadcast();
                if (self.stopping) return;
                continue;
            }
            const n = @min(self.queue.items.len, self.config.max_export_batch_size);
            const batch = self.gpa.dupe([]u8, self.queue.items[0..n]) catch {
                self.cond.broadcast();
                continue;
            };
            self.queue.replaceRangeAssumeCapacity(0, n, &.{});
            self.in_flight = true;
            self.mutex.unlock();

            const ok = self.exportBatch(&client, batch);
            for (batch) |b| self.gpa.free(b);
            self.gpa.free(batch);

            self.mutex.lock();
            self.in_flight = false;
            if (ok) self.stats.exported += n else self.stats.failed_batches += 1;
            self.cond.broadcast();
            // A dead collector at shutdown: drop the rest instead of paying a
            // timeout per remaining batch.
            if (self.stopping and !ok) {
                self.stats.dropped += self.queue.items.len;
                for (self.queue.items) |b| self.gpa.free(b);
                self.queue.clearRetainingCapacity();
            }
        }
    }

    fn exportBatch(self: *Exporter, client: *std.http.Client, batch: []const []u8) bool {
        const body = otlp.encodeRequest(self.gpa, self.config.protocol, .{ .attributes = self.config.resource }, self.scope, batch) catch {
            log.warn("otel", "export request encoding failed (OOM); {d} spans dropped", .{batch.len});
            return false;
        };
        defer self.gpa.free(body);
        const status = post(client, self.config.endpoint, self.http_headers, body, self.config.timeout_ms) catch |err| {
            log.warn("otel", "export to {s} failed: {s}", .{ self.config.endpoint, @errorName(err) });
            return false;
        };
        if (status < 200 or status >= 300) {
            log.warn("otel", "collector {s} answered HTTP {d}; {d} spans dropped", .{ self.config.endpoint, status, batch.len });
            return false;
        }
        log.debug("otel", "exported {d} spans ({d} bytes)", .{ batch.len, body.len });
        return true;
    }
};

const PostError = error{ TransportFailed, TimedOut };

const Race = union(enum) {
    response: PostError!u16,
    deadline: std.Io.Cancelable!void,
};

/// POST `body` and return the status, or fail once `timeout_ms` has passed.
fn post(client: *std.http.Client, url: []const u8, headers: []const std.http.Header, body: []const u8, timeout_ms: u32) PostError!u16 {
    const io = client.io;
    var results: [2]Race = undefined;
    var race = std.Io.Select(Race).init(io, &results);
    errdefer race.cancelDiscard();
    race.concurrent(.response, postTask, .{ client, url, headers, body }) catch return error.TransportFailed;
    race.concurrent(.deadline, deadlineTask, .{ io, timeout_ms }) catch return error.TransportFailed;
    const first = race.await() catch return error.TransportFailed;
    switch (first) {
        .response => |response| {
            race.cancelDiscard();
            return response;
        },
        .deadline => {
            while (race.cancel()) |_| {}
            return error.TimedOut;
        },
    }
}

fn postTask(client: *std.http.Client, url: []const u8, headers: []const std.http.Header, body: []const u8) PostError!u16 {
    const uri = std.Uri.parse(url) catch return error.TransportFailed;
    var request = client.request(.POST, uri, .{
        .keep_alive = false,
        // An auth header must never follow a redirect (http_status.zig).
        .redirect_behavior = @import("../api/http_status.zig").no_redirects,
        .headers = .{ .user_agent = .{ .override = "metacodes-otlp" } },
        .extra_headers = headers,
    }) catch return error.TransportFailed;
    defer request.deinit();
    // A send that fails mid-body must close the connection (http_connection.zig).
    http_connection.sendBodyComplete(&request, @constCast(body)) catch return error.TransportFailed;
    var redirect_buffer: [1024]u8 = undefined;
    const response = request.receiveHead(&redirect_buffer) catch return error.TransportFailed;
    const status = @import("../api/http_status.zig").ResponseStatus.capture(&response).code;
    // Drain a short answer so the connection closes cleanly; its content
    // (a partial-success message at most) is not acted on.
    var transfer_buffer: [4096]u8 = undefined;
    const reader = request.reader.bodyReader(&transfer_buffer, response.head.transfer_encoding, response.head.content_length);
    _ = reader.discardRemaining() catch {};
    return status;
}

fn deadlineTask(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    return util_time.sleepAtLeast(io, .{ .raw = .fromMilliseconds(@as(i64, timeout_ms)), .clock = .awake });
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const net = platform.net;

/// A one-request-at-a-time HTTP collector on loopback that records bodies.
pub const TestCollector = struct {
    listener: net.Listener,
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    bodies: std.ArrayList([]u8) = .empty,
    content_types: std.ArrayList([]u8) = .empty,
    auth: std.ArrayList([]u8) = .empty,
    status_line: []const u8 = "200 OK",
    /// Accept but never answer (a black-holed collector).
    silent: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    pub fn start(gpa: std.mem.Allocator, self: *TestCollector) !void {
        self.* = .{ .listener = try net.listenLoopback(0, 8), .gpa = gpa };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    pub fn url(self: *const TestCollector, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/v1/traces", .{self.listener.port}) catch unreachable;
    }

    pub fn deinit(self: *TestCollector) void {
        self.stop.store(true, .release);
        if (net.connectLoopback(self.listener.port)) |s| net.closeSocket(s) else |_| {}
        self.thread.join();
        net.closeSocket(self.listener.sock);
        for (self.bodies.items) |b| self.gpa.free(b);
        self.bodies.deinit(self.gpa);
        for (self.content_types.items) |b| self.gpa.free(b);
        self.content_types.deinit(self.gpa);
        for (self.auth.items) |b| self.gpa.free(b);
        self.auth.deinit(self.gpa);
    }

    pub fn count(self: *TestCollector) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.bodies.items.len;
    }

    fn serve(self: *TestCollector) void {
        while (!self.stop.load(.acquire)) {
            const conn = net.acceptConn(self.listener.sock) orelse continue;
            defer net.closeSocket(conn);
            if (self.stop.load(.acquire)) return;
            self.handle(conn) catch {};
        }
    }

    fn handle(self: *TestCollector, conn: net.Socket) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        var chunk: [4096]u8 = undefined;
        net.setRecvTimeoutMs(conn, 2000);
        var head_end: ?usize = null;
        while (head_end == null) {
            const n = net.recv(conn, &chunk);
            if (n <= 0) return;
            try buf.appendSlice(self.gpa, chunk[0..@intCast(n)]);
            head_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n");
        }
        const head = buf.items[0..head_end.?];
        const http_util = @import("../util/http.zig");
        const len = http_util.parseContentLength(head) orelse 0;
        while (buf.items.len < head_end.? + 4 + len) {
            const n = net.recv(conn, &chunk);
            if (n <= 0) return;
            try buf.appendSlice(self.gpa, chunk[0..@intCast(n)]);
        }
        const ct = http_util.headerValue(buf.items[0..head_end.?], "content-type") orelse "";
        const auth = http_util.headerValue(buf.items[0..head_end.?], "authorization") orelse "";
        if (self.silent) {
            while (!self.stop.load(.acquire)) util_time.sleepMs(10);
            return;
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.bodies.append(self.gpa, try self.gpa.dupe(u8, buf.items[head_end.? + 4 ..][0..len]));
            try self.content_types.append(self.gpa, try self.gpa.dupe(u8, ct));
            try self.auth.append(self.gpa, try self.gpa.dupe(u8, auth));
        }
        var reply_buf: [128]u8 = undefined;
        const reply = try std.fmt.bufPrint(&reply_buf, "HTTP/1.1 {s}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}", .{self.status_line});
        _ = net.send(conn, reply);
    }
};

fn testSpan(name: []const u8, attrs: []const span_mod.Attribute) span_mod.Span {
    return .{
        .trace_id = span_mod.TraceId.random(),
        .span_id = span_mod.SpanId.random(),
        .name = name,
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = attrs,
    };
}

fn testConfig(a: std.mem.Allocator, collector: *const TestCollector, protocol: otlp.Protocol, capture: bool, timeout_ms: u32) !config_mod.Exporter {
    var url_buf: [64]u8 = undefined;
    const headers = try a.alloc(config_mod.Header, 1);
    headers[0] = .{ .name = "authorization", .value = "Bearer t0ken" };
    const resource = try a.alloc(span_mod.Attribute, 1);
    resource[0] = span_mod.Attribute.str("service.name", "metacodes-test");
    return .{
        .endpoint = try a.dupe(u8, collector.url(&url_buf)),
        .protocol = protocol,
        .headers = headers,
        .timeout_ms = timeout_ms,
        .schedule_delay_ms = 60_000,
        .capture_content = capture,
        .resource = resource,
    };
}

fn startFor(collector: *const TestCollector, protocol: otlp.Protocol, capture: bool, timeout_ms: u32) !*Exporter {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const cfg = testConfig(arena.allocator(), collector, protocol, capture, timeout_ms) catch |err| {
        arena.deinit();
        return err;
    };
    return Exporter.start(testing.allocator, arena, cfg, "0.0.0-test");
}

test "otel: exporter posts queued spans as OTLP/JSON with configured headers and content policy" {
    var collector: TestCollector = undefined;
    try TestCollector.start(testing.allocator, &collector);
    defer collector.deinit();
    const exp = try startFor(&collector, .http_json, false, 5_000);
    defer exp.shutdown();

    const attrs = [_]span_mod.Attribute{ span_mod.Attribute.str("gen_ai.operation.name", "chat"), span_mod.Attribute.text("gen_ai.output.messages", "private words") };
    const s = testSpan("chat m", &attrs);
    exp.enqueue(&s);
    try testing.expect(exp.forceFlush(5_000));
    try testing.expectEqual(@as(usize, 1), collector.count());
    const body = collector.bodies.items[0];
    try testing.expectEqualStrings("application/json", collector.content_types.items[0]);
    try testing.expectEqualStrings("Bearer t0ken", collector.auth.items[0]);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const rs = parsed.value.object.get("resourceSpans").?.array.items[0];
    const svc = rs.object.get("resource").?.object.get("attributes").?.array.items[0];
    try testing.expectEqualStrings("metacodes-test", svc.object.get("value").?.object.get("stringValue").?.string);
    const spans = rs.object.get("scopeSpans").?.array.items[0].object.get("spans").?.array.items;
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("chat m", spans[0].object.get("name").?.string);
    try testing.expect(std.mem.indexOf(u8, body, "private words") == null);
    try testing.expectEqual(@as(u64, 1), exp.snapshotStats().exported);
}

test "otel: exporter sends protobuf by default and includes content when captured" {
    var collector: TestCollector = undefined;
    try TestCollector.start(testing.allocator, &collector);
    defer collector.deinit();
    const exp = try startFor(&collector, .http_protobuf, true, 5_000);
    const attrs = [_]span_mod.Attribute{span_mod.Attribute.text("gen_ai.tool.call.result", "visible-result")};
    const s = testSpan("execute_tool Bash", &attrs);
    exp.enqueue(&s);
    // shutdown flushes what is queued.
    exp.shutdown();
    try testing.expectEqual(@as(usize, 1), collector.count());
    try testing.expectEqualStrings("application/x-protobuf", collector.content_types.items[0]);
    try testing.expect(std.mem.indexOf(u8, collector.bodies.items[0], "visible-result") != null);
    try testing.expect(std.mem.indexOf(u8, collector.bodies.items[0], "execute_tool Bash") != null);
}

test "otel: a collector error status counts a failed batch; a black hole times out instead of hanging" {
    var collector: TestCollector = undefined;
    try TestCollector.start(testing.allocator, &collector);
    defer collector.deinit();
    collector.status_line = "503 Service Unavailable";
    {
        const exp = try startFor(&collector, .http_json, false, 5_000);
        defer exp.shutdown();
        const s = testSpan("x", &.{});
        exp.enqueue(&s);
        try testing.expect(exp.forceFlush(5_000));
        try testing.expectEqual(@as(u64, 1), exp.snapshotStats().failed_batches);
    }

    var hole: TestCollector = undefined;
    try TestCollector.start(testing.allocator, &hole);
    defer hole.deinit();
    hole.silent = true;
    const exp = try startFor(&hole, .http_json, false, 200);
    const s = testSpan("y", &.{});
    exp.enqueue(&s);
    const started = util_time.nowMs();
    try testing.expect(exp.forceFlush(5_000));
    try testing.expect(util_time.nowMs() - started < 4_000);
    try testing.expectEqual(@as(u64, 1), exp.snapshotStats().failed_batches);
    exp.shutdown();
}

test "otel: a full queue drops instead of blocking" {
    var collector: TestCollector = undefined;
    try TestCollector.start(testing.allocator, &collector);
    defer collector.deinit();
    const exp = try startFor(&collector, .http_json, false, 5_000);
    defer exp.shutdown();
    exp.mutex.lock();
    exp.config.max_queue_size = 1;
    exp.config.max_export_batch_size = 100;
    exp.mutex.unlock();
    const s = testSpan("z", &.{});
    exp.enqueue(&s);
    exp.enqueue(&s);
    try testing.expectEqual(@as(u64, 1), exp.snapshotStats().dropped);
}
