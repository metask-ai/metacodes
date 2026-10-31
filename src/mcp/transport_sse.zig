//! MCP HTTP+SSE transport (protocol revision 2024-11-05; Claude Code's
//! `type: "sse"`), still the only transport of many hosted servers.
//!
//! The client opens one long-lived `GET <url>` with
//! `Accept: text/event-stream`. The server's first event is `endpoint`,
//! whose data is the URI to POST messages to (relative references resolve
//! against the stream URL; another origin is refused, as the TypeScript SDK
//! does, because every POST carries the configured headers). Each client
//! message is one POST (answered 202 Accepted); every server message —
//! responses, requests, notifications — arrives as a `message` event on the
//! stream.
//!
//! A reader thread owns the stream and queues its messages, so a request
//! that is interrupted or times out leaves the session intact: its late
//! response is queued and discarded by id like any stale answer, and the
//! client sends `notifications/cancelled` as over stdio. Closing shuts the
//! stream's socket down, which wakes the reader, and joins it.
//!
//! Authentication is the Streamable HTTP transport's: configured headers,
//! or a stored OAuth login whose token is refreshed once after a 401.

const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const provider = @import("../api/provider.zig");
const http_status = @import("../api/http_status.zig");
const http_connection = @import("../api/http_connection.zig");
const util_time = @import("../util/time.zig");
const sync = @import("platform").sync;
const Capture = @import("../core/tool_result_artifact.zig").Capture;
const http = @import("transport_http.zig");
const oauth = @import("oauth.zig");
const url_util = @import("url.zig");

pub const Header = http.Header;

const MAX_MESSAGE_BYTES: usize = 128 * 1024 * 1024 + 1024 * 1024;
/// How often a waiting reader re-checks its interrupt and deadline.
const WAIT_SLICE_NS: u64 = 50 * std.time.ns_per_ms;

pub const SseTransport = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    /// Configured headers, owned.
    headers: []const Header,
    bearer: oauth.Bearer = .{},
    /// Negotiated revision for `MCP-Protocol-Version` (static string).
    protocol_version: ?[]const u8 = null,
    deadline_ms: ?i64 = null,
    abort: ?*const AbortSignal = null,

    /// POSTs; the stream has a client of its own, used only by the reader.
    post_client: std.http.Client,
    registry: provider.RequestAbortRegistry = .{},

    stream_client: std.http.Client,
    stream_request: std.http.Client.Request = undefined,
    stream_open: bool = false,
    stream_response: std.http.Client.Response = undefined,
    stream_transfer: [16 * 1024]u8 = undefined,
    stream_pending: std.ArrayList(u8) = .empty,
    reader: ?std.Thread = null,

    // Shared with the reader, under `mutex`.
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    /// The absolute POST endpoint, once the `endpoint` event arrived.
    endpoint: ?[]u8 = null,
    endpoint_uri: std.Uri = undefined,
    queue: std.ArrayList([]u8) = .empty,
    /// The stream ended; `stream_error` says why when it was not a clean end.
    ended: bool = false,
    stream_error: ?anyerror = null,

    pub const Options = struct {
        /// Bounds the GET and the wait for the `endpoint` event.
        deadline_ms: ?i64 = null,
        abort: ?*const AbortSignal = null,
        /// A stored OAuth login (consumed: destroyed with the transport,
        /// or here on failure).
        auth: ?*oauth.TokenSource = null,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        headers: []const Header,
        options: Options,
    ) !*SseTransport {
        const self = allocator.create(SseTransport) catch |err| {
            if (options.auth) |source| source.destroy();
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .url = "",
            .headers = &.{},
            .bearer = .{ .source = options.auth },
            .post_client = .{ .allocator = allocator, .io = io },
            .stream_client = .{ .allocator = allocator, .io = io },
            .deadline_ms = options.deadline_ms,
            .abort = options.abort,
        };
        // From here every part is the transport's; `close` releases
        // whatever was acquired.
        errdefer self.close();
        self.url = try allocator.dupe(u8, url);
        _ = std.Uri.parse(self.url) catch return error.McpInvalidUrl;
        self.headers = try dupeHeaders(allocator, headers);
        try self.openStream();
        self.reader = try std.Thread.spawn(.{}, readerMain, .{self});
        try self.waitEndpoint();
        self.deadline_ms = null;
        self.abort = null;
        return self;
    }

    pub fn close(self: *SseTransport) void {
        self.stopReader();
        self.destroyParts();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn stopReader(self: *SseTransport) void {
        if (self.stream_open) provider.abortHttpRequest(&self.stream_request);
        if (self.reader) |thread| thread.join();
        self.reader = null;
    }

    fn destroyParts(self: *SseTransport) void {
        const allocator = self.allocator;
        if (self.stream_open) self.stream_request.deinit();
        self.stream_open = false;
        self.stream_pending.deinit(allocator);
        for (self.queue.items) |message| allocator.free(message);
        self.queue.deinit(allocator);
        if (self.endpoint) |endpoint| allocator.free(endpoint);
        self.endpoint = null;
        freeHeaders(allocator, self.headers);
        allocator.free(self.url);
        self.bearer.deinit(allocator);
        self.post_client.deinit();
        self.stream_client.deinit();
        self.registry.deinit(allocator);
    }

    // ------------------------------------------------------------------
    // The stream
    // ------------------------------------------------------------------

    fn openStream(self: *SseTransport) !void {
        const uri = std.Uri.parse(self.url) catch return error.McpInvalidUrl;
        var retried = false;
        while (true) {
            self.bearer.sync(self.allocator, self.interruptOf());
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            var extra: std.ArrayList(std.http.Header) = .empty;
            try extra.append(scratch.allocator(), .{ .name = "Accept", .value = "text/event-stream" });
            try extra.append(scratch.allocator(), .{ .name = "Cache-Control", .value = "no-cache" });
            try self.appendCommonHeaders(scratch.allocator(), &extra);

            self.stream_request = self.stream_client.request(.GET, uri, .{
                .headers = .{ .accept_encoding = .omit },
                .redirect_behavior = http_status.no_redirects,
                .extra_headers = extra.items,
                .keep_alive = false,
            }) catch return error.McpConnectFailed;
            self.stream_open = true;
            const ctx: *anyopaque = @ptrCast(&self.stream_request);
            try self.registry.registerMonitored(self.allocator, self.abort, ctx, shutdownRequest, self.remainingMs());
            const status = head: {
                defer self.registry.unregister(ctx);
                http_connection.sendBodiless(&self.stream_request) catch return self.transportError();
                var redirect: [4096]u8 = undefined;
                self.stream_response = self.stream_request.receiveHead(&redirect) catch return self.transportError();
                break :head http_status.ResponseStatus.capture(&self.stream_response).code;
            };
            const content_type = self.stream_response.head.content_type orelse "";
            switch (status) {
                200 => {
                    if (!std.mem.startsWith(u8, content_type, "text/event-stream")) return error.McpNotEventStream;
                    return;
                },
                401 => if (!retried and self.bearer.recover(self.allocator, self.interruptOf())) {
                    retried = true;
                    self.stream_request.deinit();
                    self.stream_open = false;
                    continue;
                } else return error.McpAuthRequired,
                403 => return error.McpAuthRequired,
                300...399 => return error.McpRedirected,
                500...599 => return error.McpServerError,
                else => return error.McpNotEventStream,
            }
        }
    }

    fn waitEndpoint(self: *SseTransport) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.endpoint == null) {
            if (self.ended) return self.stream_error orelse error.McpConnectFailed;
            try self.checkInterrupt();
            _ = self.cond.timedWait(&self.mutex, WAIT_SLICE_NS);
        }
    }

    fn readerMain(self: *SseTransport) void {
        const allocator = self.allocator;
        const input = self.stream_response.reader(&self.stream_transfer);
        var event: std.ArrayList(u8) = .empty;
        defer event.deinit(allocator);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        var has_data = false;
        const failure: ?anyerror = while (true) {
            const line = http.readLine(input, allocator, &self.stream_pending, MAX_MESSAGE_BYTES) catch |err| switch (err) {
                error.EndOfStream => break null,
                error.OutOfMemory => break error.OutOfMemory,
                error.McpLineTooLarge => break error.McpLineTooLarge,
                else => break error.McpConnectFailed,
            };
            defer allocator.free(line);
            if (line.len == 0) {
                // Dispatch (WHATWG SSE: an event with no data is dropped).
                if (has_data) {
                    if (self.dispatch(event.items, data.items)) |err| break err;
                }
                event.clearRetainingCapacity();
                data.clearRetainingCapacity();
                has_data = false;
                continue;
            }
            if (line[0] == ':') continue; // comment / keep-alive
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            const field = line[0..colon];
            var value = if (colon < line.len) line[colon + 1 ..] else "";
            if (value.len != 0 and value[0] == ' ') value = value[1..];
            if (std.mem.eql(u8, field, "event")) {
                event.clearRetainingCapacity();
                event.appendSlice(allocator, value) catch break error.OutOfMemory;
            } else if (std.mem.eql(u8, field, "data")) {
                if (has_data) data.append(allocator, '\n') catch break error.OutOfMemory;
                data.appendSlice(allocator, value) catch break error.OutOfMemory;
                has_data = true;
                if (data.items.len > MAX_MESSAGE_BYTES) break error.McpLineTooLarge;
            }
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ended = true;
        self.stream_error = failure;
        self.cond.broadcast();
    }

    /// One complete event. Returns an error that ends the stream.
    fn dispatch(self: *SseTransport, event: []const u8, data: []const u8) ?anyerror {
        if (std.mem.eql(u8, event, "endpoint")) {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const resolved = url_util.resolve(scratch.allocator(), self.url, std.mem.trim(u8, data, " \t\r\n")) catch return error.McpInvalidUrl;
            if (!url_util.sameOrigin(resolved, self.url)) return error.McpEndpointOriginMismatch;
            const owned = self.allocator.dupe(u8, resolved) catch return error.OutOfMemory;
            const uri = std.Uri.parse(owned) catch {
                self.allocator.free(owned);
                return error.McpInvalidUrl;
            };
            self.mutex.lock();
            defer self.mutex.unlock();
            // 2024-11-05 sends exactly one; `send` reads the first without
            // the lock once it is set, so it is never replaced.
            if (self.endpoint != null) {
                self.allocator.free(owned);
                return null;
            }
            self.endpoint = owned;
            self.endpoint_uri = uri;
            self.cond.broadcast();
            return null;
        }
        if (event.len != 0 and !std.mem.eql(u8, event, "message")) return null;
        if (std.mem.trim(u8, data, " \t\r\n").len == 0) return null;
        const message = self.allocator.dupe(u8, data) catch return error.OutOfMemory;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.queue.append(self.allocator, message) catch {
            self.allocator.free(message);
            return error.OutOfMemory;
        };
        self.cond.broadcast();
        return null;
    }

    // ------------------------------------------------------------------
    // Messages
    // ------------------------------------------------------------------

    /// POST one JSON-RPC message to the endpoint. Its answer, if any,
    /// arrives on the stream.
    pub fn send(self: *SseTransport, json: []const u8, meta: http.SendMeta) !void {
        _ = meta; // 2024-11-05 has no per-message routing headers
        try self.checkInterrupt();
        const endpoint_uri = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.endpoint == null) return error.McpConnectFailed;
            if (self.ended and self.queue.items.len == 0) return self.stream_error orelse error.McpStreamClosed;
            break :blk self.endpoint_uri;
        };
        var retried = false;
        while (true) {
            self.bearer.sync(self.allocator, self.interruptOf());
            const status = try self.post(endpoint_uri, json);
            switch (status) {
                200...299 => return,
                401 => if (!retried and self.bearer.recover(self.allocator, self.interruptOf())) {
                    retried = true;
                    continue;
                } else return error.McpAuthRequired,
                403 => return error.McpAuthRequired,
                // The server forgot the session the endpoint named.
                404 => return error.McpSessionExpired,
                300...399 => return error.McpRedirected,
                else => return error.McpServerError,
            }
        }
    }

    fn post(self: *SseTransport, endpoint_uri: std.Uri, json: []const u8) !u16 {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.append(scratch.allocator(), .{ .name = "Accept", .value = "application/json, text/event-stream" });
        try self.appendCommonHeaders(scratch.allocator(), &extra);
        var request = self.post_client.request(.POST, endpoint_uri, .{
            .headers = .{
                .accept_encoding = .omit,
                .content_type = .{ .override = "application/json" },
            },
            .redirect_behavior = http_status.no_redirects,
            .extra_headers = extra.items,
        }) catch return error.McpConnectFailed;
        defer request.deinit();
        const ctx: *anyopaque = @ptrCast(&request);
        try self.registry.registerMonitored(self.allocator, self.abort, ctx, shutdownRequest, self.remainingMs());
        defer self.registry.unregister(ctx);
        http_connection.sendBodyComplete(&request, @constCast(json)) catch return self.transportError();
        var redirect: [1024]u8 = undefined;
        var response = request.receiveHead(&redirect) catch return self.transportError();
        const status = http_status.ResponseStatus.capture(&response).code;
        // "Accepted" and the like: read it so the connection can be reused.
        var transfer: [1024]u8 = undefined;
        const head = response.head;
        if (status != 204 and (head.transfer_encoding == .chunked or head.content_length != null)) {
            _ = response.reader(&transfer).discardRemaining() catch {};
        }
        return status;
    }

    pub fn recvLine(self: *SseTransport) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.queue.items.len != 0) return self.queue.orderedRemove(0);
            if (self.ended) return self.stream_error orelse error.McpStreamClosed;
            try self.checkInterrupt();
            _ = self.cond.timedWait(&self.mutex, WAIT_SLICE_NS);
        }
    }

    pub fn recvLineCapture(self: *SseTransport, capture: *Capture) !void {
        const message = try self.recvLine();
        defer self.allocator.free(message);
        try capture.write(message);
    }

    // ------------------------------------------------------------------

    fn appendCommonHeaders(self: *SseTransport, arena: std.mem.Allocator, list: *std.ArrayList(std.http.Header)) !void {
        for (self.headers) |header| try list.append(arena, .{ .name = header.name, .value = header.value });
        if (self.bearer.header()) |header| try list.append(arena, header);
        if (self.protocol_version) |version| try list.append(arena, .{ .name = "MCP-Protocol-Version", .value = version });
    }

    fn interruptOf(self: *const SseTransport) oauth.Interrupt {
        return .{ .abort = self.abort, .deadline_ms = self.deadline_ms };
    }

    fn remainingMs(self: *const SseTransport) u64 {
        const deadline = self.deadline_ms orelse return 0;
        return @intCast(@max(deadline - util_time.nowMs(), 1));
    }

    fn checkInterrupt(self: *SseTransport) !void {
        if (self.abort) |signal| if (signal.isAborted()) return error.Aborted;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;
    }

    fn transportError(self: *SseTransport) anyerror {
        if (self.abort) |signal| if (signal.isAborted()) return error.Aborted;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;
        return error.McpConnectFailed;
    }
};

fn shutdownRequest(raw: *anyopaque) void {
    const request: *std.http.Client.Request = @ptrCast(@alignCast(raw));
    provider.abortHttpRequest(request);
}

fn dupeHeaders(allocator: std.mem.Allocator, headers: []const Header) ![]const Header {
    const owned = try allocator.alloc(Header, headers.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(owned);
    }
    for (headers, owned) |header, *slot| {
        const name = try allocator.dupe(u8, header.name);
        const value = allocator.dupe(u8, header.value) catch |err| {
            allocator.free(name);
            return err;
        };
        slot.* = .{ .name = name, .value = value };
        initialized += 1;
    }
    return owned;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}
