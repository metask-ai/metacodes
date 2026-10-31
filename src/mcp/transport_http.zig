//! MCP Streamable HTTP transport (one endpoint, a POST per message).
//!
//! The client sees the same message stream as over stdio: `send` POSTs a
//! JSON-RPC message, `recvLine` yields the messages the server answered with —
//! the single JSON body, or each SSE `data` event of a `text/event-stream`
//! response, read lazily so a Classic server's mid-stream request can be
//! answered (on its own POST) before the stream delivers the final response.
//!
//! Headers (basic/transports/streamable-http.mdx):
//! - every POST: `Content-Type: application/json`,
//!   `Accept: application/json, text/event-stream`, configured headers and
//!   `Authorization: Bearer $bearer_token_env_var`;
//! - 2026-07-28: `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name` for
//!   `tools/call` / `resources/read` / `prompts/get` (base64 sentinel when the
//!   value is not header-safe); no session;
//! - Classic: `MCP-Protocol-Version` after the handshake and the
//!   `MCP-Session-Id` the `initialize` response assigned; DELETE on close.
//!
//! Authentication: configured headers, or a stored OAuth login
//! (`metacodes mcp login`, mcp/oauth.zig) whose bearer is refreshed before
//! it expires and once after a 401 before the request is retried. A 401
//! that survives that, and any 403, is `error.McpAuthRequired`.
//! Cancellation and deadlines shut the connection down through the provider
//! client's request registry, which also wakes a read blocked in the kernel.
//!
//! An SSE response that ends before the awaited answer is resumed (2025-03-26
//! through 2025-11-25 "Resumability and Redelivery"): when the stream carried
//! event ids, a GET with `Last-Event-ID` reopens it after the server's
//! `retry` delay, and the server replays what followed. 2026-07-28 drops
//! resumption: there the request is lost and the caller re-issues it.
//!
//! Connections are kept alive and reused while requests come in quick
//! succession (the handshake, a burst of tool calls): one TLS handshake
//! instead of one per message. `Connection: close` is never sent — some
//! servers (Vercel's edge, developers.openai.com) drop such a request
//! unanswered. A connection is reused only after its response was read to
//! the end (std.http marks it closing otherwise), only within
//! `reuse_idle_ms` of its last use (servers close idle ones; Node's default
//! is 5 s), and a request that finds the reused connection already closed,
//! before a single response byte, is sent again on a new one.

const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const provider = @import("../api/provider.zig");
const http_status = @import("../api/http_status.zig");
const http_connection = @import("../api/http_connection.zig");
const util_time = @import("../util/time.zig");
const Capture = @import("../core/tool_result_artifact.zig").Capture;
const oauth = @import("oauth.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const SendMeta = struct {
    /// JSON-RPC method of the message ("" for a response or unknown).
    method: []const u8 = "",
    /// `params.name` / `params.uri` for the 2026-07-28 `Mcp-Name` header.
    name: ?[]const u8 = null,
    /// `Mcp-Param-*` headers mirrored from `x-mcp-header` tool arguments.
    param_headers: []const Header = &.{},
};

const MAX_MESSAGE_BYTES: usize = 128 * 1024 * 1024 + 1024 * 1024;

/// How long an idle pooled connection stays reusable (below Node's 5 s
/// keep-alive default).
pub const REUSE_IDLE_MS: i64 = 4_000;
/// How long the next request waits, in silence, for an answered SSE stream
/// to end so its connection can be reused (the monitor ticks every 250 ms).
const SETTLE_IDLE_MS: u64 = 250;
/// Fresh attempts after a reused connection turned out closed.
const MAX_STALE_RETRIES: usize = 3;
/// Consecutive resumptions of one response that bring no new event.
const MAX_RESUME_ATTEMPTS: usize = 3;
/// The reconnection delay when the server sets none, and the longest one
/// honored (a `retry:` field is the server's request, not a contract).
const DEFAULT_RETRY_MS: u64 = 1_000;
const MAX_RETRY_MS: u64 = 10_000;

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    url: []u8,
    uri: std.Uri,
    /// Configured headers plus Authorization, owned.
    headers: []Header,
    /// A stored OAuth login's bearer (none when headers authenticate).
    bearer: oauth.Bearer = .{},
    /// Negotiated revision for `MCP-Protocol-Version` (null before a Classic
    /// handshake completes). Static string.
    protocol_version: ?[]const u8 = null,
    modern: bool = false,
    session_id: ?[]u8 = null,
    deadline_ms: ?i64 = null,
    abort: ?*const AbortSignal = null,
    registry: provider.RequestAbortRegistry = .{},
    /// Messages already received but not yet consumed.
    queue: std.ArrayList([]u8) = .empty,
    /// The open SSE response, read lazily by `recvLine`.
    stream: ?*Exchange = null,
    /// The client has its response from `stream`: what is left of it is the
    /// end of the body, finished before the next request (`settleStream`).
    stream_answered: bool = false,
    /// When a response last finished arriving: the pooled connections have
    /// been idle since.
    last_used_ms: i64 = 0,
    reuse_idle_ms: i64 = REUSE_IDLE_MS,
    /// The last SSE event id seen on the open response, for `Last-Event-ID`.
    last_event_id: ?[]u8 = null,
    /// The server's `retry:` delay for that stream (ms).
    retry_ms: ?u64 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        headers: []const Header,
    ) !*HttpTransport {
        return createWithAuth(allocator, io, url, headers, null);
    }

    /// `create` with a stored OAuth login, consumed (destroyed with the
    /// transport, or here on failure).
    pub fn createWithAuth(
        allocator: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        headers: []const Header,
        auth: ?*oauth.TokenSource,
    ) !*HttpTransport {
        var bearer: oauth.Bearer = .{ .source = auth };
        errdefer bearer.deinit(allocator);
        const self = try allocator.create(HttpTransport);
        errdefer allocator.destroy(self);
        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const uri = std.Uri.parse(owned_url) catch return error.McpInvalidUrl;
        const owned_headers = try allocator.alloc(Header, headers.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_headers[0..initialized]) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(owned_headers);
        }
        for (headers, owned_headers) |header, *slot| {
            slot.* = .{ .name = try allocator.dupe(u8, header.name), .value = undefined };
            slot.value = allocator.dupe(u8, header.value) catch |err| {
                allocator.free(slot.name);
                return err;
            };
            initialized += 1;
        }
        self.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
            .url = owned_url,
            .uri = uri,
            .headers = owned_headers,
            .bearer = bearer,
        };
        bearer = .{};
        return self;
    }

    pub fn close(self: *HttpTransport) void {
        self.closeStream();
        if (self.session_id != null and !self.modern) {
            // Classic: end the session (SHOULD); failures are irrelevant now.
            self.deleteSession() catch {};
        }
        for (self.queue.items) |message| self.allocator.free(message);
        self.queue.deinit(self.allocator);
        if (self.session_id) |id| self.allocator.free(id);
        self.forgetEventId();
        self.bearer.deinit(self.allocator);
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.url);
        self.client.deinit();
        self.registry.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// POST one JSON-RPC message. Responses the server sends back (if any)
    /// become available to `recvLine`.
    pub fn send(self: *HttpTransport, json: []const u8, meta: SendMeta) !void {
        // A reply posted while a request's SSE stream is still open (Classic
        // server→client request) uses its own connection; the open stream
        // keeps its place. A stream whose request was answered is finished
        // first, so its connection can carry this message.
        if (self.stream_answered) self.settleStream();
        var exchange = try self.post(json, meta);
        errdefer exchange.destroy(self);
        switch (exchange.kind) {
            .empty => {
                exchange.drainEmpty();
                exchange.destroy(self);
                self.last_used_ms = util_time.nowMs();
            },
            .json => {
                const body = try exchange.readAll(self, MAX_MESSAGE_BYTES);
                exchange.destroy(self);
                self.last_used_ms = util_time.nowMs();
                errdefer self.allocator.free(body);
                if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
                    self.allocator.free(body);
                    return;
                }
                try self.queue.append(self.allocator, body);
            },
            .sse => {
                self.forgetEventId();
                self.retry_ms = null;
                if (self.stream) |previous| {
                    // Only one request is in flight per client (request
                    // mutex), so an older stream has nothing left we need.
                    previous.destroy(self);
                }
                self.stream = exchange;
                self.stream_answered = false;
            },
        }
    }

    /// The client read the response it was waiting for. An SSE stream still
    /// open is then only the rest of that response's body.
    pub fn markAnswered(self: *HttpTransport) void {
        self.stream_answered = self.stream != null;
        self.last_used_ms = util_time.nowMs();
    }

    /// Read the rest of an answered SSE stream. Servers end it right after
    /// the response (the spec says they SHOULD), so this normally reads only
    /// the closing chunk and the connection goes back to the pool; a server
    /// that keeps it open costs SETTLE_IDLE_MS of silence and the connection.
    /// Late messages wait in the queue for the next reader.
    fn settleStream(self: *HttpTransport) void {
        self.stream_answered = false;
        const exchange = self.stream orelse return;
        // An SSE body; this registry never learns keepalives (no touchKeepalive caller), so
        // only the settle limit applies, never the transport-dead rule.
        self.registry.setIdleLimit(@ptrCast(&exchange.request), SETTLE_IDLE_MS, .sse);
        while (exchange.nextEvent(self, MAX_MESSAGE_BYTES) catch null) |message| {
            self.queue.append(self.allocator, message) catch {
                self.allocator.free(message);
                break;
            };
        }
        self.closeStream();
    }

    pub fn recvLine(self: *HttpTransport) ![]u8 {
        if (self.queue.items.len != 0) return self.queue.orderedRemove(0);
        var resumes: usize = 0;
        while (true) {
            const exchange = self.stream orelse return error.Eof;
            const failure: anyerror = blk: {
                const maybe = exchange.nextEvent(self, MAX_MESSAGE_BYTES) catch |err| break :blk err;
                if (maybe) |message| return message;
                break :blk error.Eof;
            };
            self.closeStream();
            // Interrupted, or not a dropped connection: nothing to resume.
            if (failure != error.Eof and failure != error.McpConnectFailed) return failure;
            // The stream ended without the awaited response. Classic servers
            // that numbered their events replay the rest on a GET with
            // `Last-Event-ID`; in 2026-07-28 the request is lost and must be
            // re-issued by the caller.
            if (self.modern or self.last_event_id == null or resumes >= MAX_RESUME_ATTEMPTS) return failure;
            resumes += 1;
            const delay = @min(self.retry_ms orelse DEFAULT_RETRY_MS, MAX_RETRY_MS);
            try self.sleepInterruptible(delay);
            const resumed = self.resume_() catch |err| retry: switch (err) {
                error.McpUnauthorized => {
                    if (!self.bearer.recover(self.allocator, self.interruptOf())) return error.McpAuthRequired;
                    break :retry self.resume_() catch |again| switch (again) {
                        error.McpUnauthorized => return error.McpAuthRequired,
                        error.Aborted, error.Timeout, error.McpAuthRequired => return again,
                        else => return failure,
                    };
                },
                error.Aborted, error.Timeout, error.McpAuthRequired => return err,
                else => return failure,
            };
            self.stream = resumed;
            self.stream_answered = false;
        }
    }

    /// GET the stream again from the last event id (the server replays
    /// what followed it on this stream only).
    fn resume_(self: *HttpTransport) !*Exchange {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.append(scratch.allocator(), .{ .name = "Accept", .value = "text/event-stream" });
        try extra.append(scratch.allocator(), .{ .name = "Last-Event-ID", .value = self.last_event_id.? });
        {
            var common: std.ArrayList(std.http.Header) = .empty;
            defer common.deinit(self.allocator);
            try self.appendCommonHeaders(&common, .{});
            try extra.appendSlice(scratch.allocator(), common.items);
        }
        const exchange = try self.openMethod(.GET, extra.items);
        errdefer exchange.destroy(self);
        http_connection.sendBodiless(&exchange.request) catch return self.transportError();
        var redirect: [1024]u8 = undefined;
        exchange.response = exchange.request.receiveHead(&redirect) catch return self.transportError();
        exchange.has_response = true;
        const status = http_status.ResponseStatus.capture(&exchange.response).code;
        exchange.status = status;
        const content_type = exchange.response.head.content_type orelse "";
        switch (status) {
            200 => if (!std.mem.startsWith(u8, content_type, "text/event-stream")) return error.McpConnectFailed,
            401 => return error.McpUnauthorized,
            403 => return error.McpAuthRequired,
            else => return error.McpConnectFailed,
        }
        exchange.kind = .sse;
        return exchange;
    }

    fn sleepInterruptible(self: *HttpTransport, delay_ms: u64) !void {
        const until = util_time.nowMs() + @as(i64, @intCast(delay_ms));
        while (util_time.nowMs() < until) {
            if (self.abort) |abort| if (abort.isAborted()) return error.Aborted;
            if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;
            util_time.sleepMs(@min(50, delay_ms));
        }
    }

    fn noteEventId(self: *HttpTransport, id: []const u8) void {
        if (self.last_event_id) |old| {
            if (std.mem.eql(u8, old, id)) return;
        }
        const owned = self.allocator.dupe(u8, id) catch return;
        self.forgetEventId();
        self.last_event_id = owned;
    }

    fn forgetEventId(self: *HttpTransport) void {
        if (self.last_event_id) |old| self.allocator.free(old);
        self.last_event_id = null;
    }

    pub fn recvLineCapture(self: *HttpTransport, capture: *Capture) !void {
        const message = try self.recvLine();
        defer self.allocator.free(message);
        try capture.write(message);
    }

    fn closeStream(self: *HttpTransport) void {
        if (self.stream) |exchange| exchange.destroy(self);
        self.stream = null;
        self.stream_answered = false;
    }

    /// Close the pooled connections (none is in use): they have been idle
    /// long enough for the server to have closed them.
    fn dropIdleConnections(self: *HttpTransport) void {
        const pool = &self.client.connection_pool;
        const io = self.client.io;
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);
        while (pool.free.popFirst()) |node| {
            pool.free_len -= 1;
            const connection: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
            connection.destroy(io);
        }
    }

    fn idleConnections(self: *HttpTransport) usize {
        const pool = &self.client.connection_pool;
        pool.mutex.lockUncancelable(self.client.io);
        defer pool.mutex.unlock(self.client.io);
        return pool.free_len;
    }

    fn deleteSession(self: *HttpTransport) !void {
        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(self.allocator);
        try self.appendCommonHeaders(&extra, .{});
        var request = try self.client.request(.DELETE, self.uri, .{
            .headers = .{ .accept_encoding = .omit },
            .redirect_behavior = http_status.no_redirects,
            .extra_headers = extra.items,
        });
        defer request.deinit();
        try http_connection.sendBodiless(&request);
        var redirect: [1024]u8 = undefined;
        _ = try request.receiveHead(&redirect);
    }

    fn appendCommonHeaders(self: *HttpTransport, list: *std.ArrayList(std.http.Header), meta: SendMeta) !void {
        for (self.headers) |header| try list.append(self.allocator, .{ .name = header.name, .value = header.value });
        if (self.bearer.header()) |header| try list.append(self.allocator, header);
        if (self.protocol_version) |version| try list.append(self.allocator, .{ .name = "MCP-Protocol-Version", .value = version });
        if (self.session_id) |id| try list.append(self.allocator, .{ .name = "MCP-Session-Id", .value = id });
        if (self.modern and meta.method.len != 0) {
            try list.append(self.allocator, .{ .name = "Mcp-Method", .value = meta.method });
            if (meta.name) |name| try list.append(self.allocator, .{ .name = "Mcp-Name", .value = name });
            for (meta.param_headers) |header| try list.append(self.allocator, .{ .name = header.name, .value = header.value });
        }
    }

    /// POST, retried once with a refreshed token when a stored OAuth login's
    /// bearer is refused with 401.
    fn post(self: *HttpTransport, json: []const u8, meta: SendMeta) !*Exchange {
        self.bearer.sync(self.allocator, self.interruptOf());
        return self.postOnce(json, meta) catch |err| {
            if (err != error.McpUnauthorized) return err;
            if (!self.bearer.recover(self.allocator, self.interruptOf())) return error.McpAuthRequired;
            return self.postOnce(json, meta) catch |retry_err|
                if (retry_err == error.McpUnauthorized) error.McpAuthRequired else retry_err;
        };
    }

    fn postOnce(self: *HttpTransport, json: []const u8, meta: SendMeta) !*Exchange {
        if (self.abort) |abort| if (abort.isAborted()) return error.Aborted;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.append(scratch.allocator(), .{ .name = "Accept", .value = "application/json, text/event-stream" });
        var encoded_meta = meta;
        if (meta.name) |name| encoded_meta.name = try headerSafe(scratch.allocator(), name);
        var encoded_params: std.ArrayList(Header) = .empty;
        for (meta.param_headers) |header| {
            try encoded_params.append(scratch.allocator(), .{ .name = header.name, .value = try headerSafe(scratch.allocator(), header.value) });
        }
        encoded_meta.param_headers = encoded_params.items;
        {
            // appendCommonHeaders allocates with self.allocator; copy into scratch.
            var common: std.ArrayList(std.http.Header) = .empty;
            defer common.deinit(self.allocator);
            try self.appendCommonHeaders(&common, encoded_meta);
            try extra.appendSlice(scratch.allocator(), common.items);
        }

        if (util_time.nowMs() - self.last_used_ms > self.reuse_idle_ms and self.idleConnections() != 0)
            self.dropIdleConnections();

        var redirect: [4096]u8 = undefined;
        var stale_retries: usize = 0;
        const exchange = while (true) {
            const reusing = self.idleConnections() != 0;
            const exchange = try self.open(extra.items);
            if (exchange.exchangeHead(json, &redirect)) |_| break exchange else |err| {
                // This connection cannot carry another request either.
                if (exchange.request.connection) |connection| connection.closing = true;
                exchange.destroy(self);
                // Closed before a single response byte: the server dropped an
                // idle connection we reused and never read this request.
                const stale = err == error.HttpConnectionClosing or err == error.WriteFailed;
                if (reusing and stale and stale_retries < MAX_STALE_RETRIES and !self.interrupted()) {
                    stale_retries += 1;
                    continue;
                }
                return self.transportError();
            }
        };
        errdefer exchange.destroy(self);
        const status = http_status.ResponseStatus.capture(&exchange.response).code;
        exchange.status = status;
        const head = exchange.response.head;

        // Classic: the server assigns its session on the initialize response.
        var headers = head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id") and !self.modern) {
                if (self.session_id) |old| self.allocator.free(old);
                self.session_id = try self.allocator.dupe(u8, std.mem.trim(u8, header.value, " "));
            }
        }
        const content_type = head.content_type orelse "";
        const is_sse = std.mem.startsWith(u8, content_type, "text/event-stream");

        switch (status) {
            200...201 => exchange.kind = if (is_sse) .sse else .json,
            202, 204 => exchange.kind = .empty,
            401 => return error.McpUnauthorized,
            403 => return error.McpAuthRequired,
            404 => {
                // A Classic session the server no longer knows (404 with a
                // session id) must be re-initialized. A JSON-RPC body (e.g.
                // 2026-07-28 method-not-found) is still delivered.
                if (self.session_id != null and !self.modern) return error.McpSessionExpired;
                exchange.kind = if (is_sse) .sse else .json;
            },
            400, 402, 405...499 => exchange.kind = if (is_sse) .sse else .json,
            // Not followed (`http_status.no_redirects`): the configured headers
            // would go to wherever it points.
            300...399 => return error.McpRedirected,
            else => return error.McpServerError,
        }
        // Keep only the abort routing for the body; a deadline still applies.
        return exchange;
    }

    /// A POST exchange on a pooled or new connection, registered for abort
    /// and deadline.
    fn open(self: *HttpTransport, extra_headers: []const std.http.Header) !*Exchange {
        return self.openMethod(.POST, extra_headers);
    }

    fn openMethod(self: *HttpTransport, method: std.http.Method, extra_headers: []const std.http.Header) !*Exchange {
        const exchange = try self.allocator.create(Exchange);
        errdefer self.allocator.destroy(exchange);
        exchange.* = .{ .request = undefined };
        exchange.request = self.client.request(method, self.uri, .{
            .headers = .{
                .accept_encoding = .omit,
                .content_type = if (method == .POST) .{ .override = "application/json" } else .default,
            },
            // The configured headers (often an Authorization) go wherever a
            // redirect points; a 3xx is the server's answer.
            .redirect_behavior = http_status.no_redirects,
            .extra_headers = extra_headers,
        }) catch return error.McpConnectFailed;
        errdefer exchange.request.deinit();
        const remaining: u64 = if (self.deadline_ms) |deadline| @intCast(@max(deadline - util_time.nowMs(), 1)) else 0;
        try self.registry.registerMonitored(self.allocator, self.abort, @ptrCast(&exchange.request), shutdownRequest, remaining);
        exchange.registered = true;
        return exchange;
    }

    fn interruptOf(self: *const HttpTransport) oauth.Interrupt {
        return .{ .abort = self.abort, .deadline_ms = self.deadline_ms };
    }

    fn interrupted(self: *const HttpTransport) bool {
        if (self.abort) |abort| if (abort.isAborted()) return true;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return true;
        return false;
    }

    fn transportError(self: *HttpTransport) anyerror {
        if (self.abort) |abort| if (abort.isAborted()) return error.Aborted;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;
        return error.McpConnectFailed;
    }
};

fn shutdownRequest(raw: *anyopaque) void {
    const request: *std.http.Client.Request = @ptrCast(@alignCast(raw));
    provider.abortHttpRequest(request);
}

const Exchange = struct {
    request: std.http.Client.Request,
    response: std.http.Client.Response = undefined,
    has_response: bool = false,
    /// The captured HTTP status (`http_status.ResponseStatus`), 0 before.
    status: u16 = 0,
    registered: bool = false,
    kind: Kind = .empty,
    transfer: [16 * 1024]u8 = undefined,
    body: ?*std.Io.Reader = null,
    /// Bytes of an SSE line carried over between reads.
    pending: std.ArrayList(u8) = .empty,
    finished: bool = false,

    const Kind = enum { empty, json, sse };

    fn destroy(self: *Exchange, transport: *HttpTransport) void {
        if (self.registered) transport.registry.unregister(@ptrCast(&self.request));
        self.pending.deinit(transport.allocator);
        // Back to the pool when its response was read to the end, closed
        // otherwise: by std.http.Client.Request.deinit when the response was
        // cut short, by http_connection when the send failed.
        self.request.deinit();
        transport.allocator.destroy(self);
    }

    /// Send `json` and read the response head.
    fn exchangeHead(self: *Exchange, json: []const u8, redirect: []u8) !void {
        try http_connection.sendBodyComplete(&self.request, @constCast(json));
        self.response = try self.request.receiveHead(redirect);
        self.has_response = true;
    }

    /// Read a 202/204 answer's body when it is framed, so the connection is
    /// reusable; an unframed body ends only when the server closes, and that
    /// connection is closed instead.
    fn drainEmpty(self: *Exchange) void {
        if (!self.has_response) return;
        if (self.status == 204 or self.status == 304) return; // no body by definition
        const head = self.response.head;
        if (head.transfer_encoding != .chunked and head.content_length == null) return;
        _ = self.reader().discardRemaining() catch {};
    }

    fn reader(self: *Exchange) *std.Io.Reader {
        if (self.body) |body| return body;
        self.body = self.response.reader(&self.transfer);
        return self.body.?;
    }

    fn readAll(self: *Exchange, transport: *HttpTransport, limit: usize) ![]u8 {
        return self.reader().allocRemaining(transport.allocator, .limited(limit)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.McpLineTooLarge,
            else => transport.transportError(),
        };
    }

    /// Next SSE `data` payload, or null at the end of the stream. Comments
    /// (keep-alives), empty priming events and non-message fields are skipped.
    fn nextEvent(self: *Exchange, transport: *HttpTransport, limit: usize) !?[]u8 {
        if (self.finished) return null;
        const allocator = transport.allocator;
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(allocator);
        var has_data = false;
        // WHATWG: an event's `id` becomes the last event id only when the
        // event is dispatched (its blank line), so a stream cut inside an
        // event resumes from the event before it.
        var event_id: std.ArrayList(u8) = .empty;
        defer event_id.deinit(allocator);
        var has_id = false;
        const input = self.reader();
        while (true) {
            const line = readLine(input, allocator, &self.pending, limit) catch |err| switch (err) {
                error.EndOfStream => {
                    self.finished = true;
                    if (has_data and data.items.len != 0) return try data.toOwnedSlice(allocator);
                    data.deinit(allocator);
                    return null;
                },
                error.OutOfMemory => return error.OutOfMemory,
                error.McpLineTooLarge => return error.McpLineTooLarge,
                else => return transport.transportError(),
            };
            defer allocator.free(line);
            if (line.len == 0) {
                if (has_id) {
                    if (event_id.items.len == 0) transport.forgetEventId() else transport.noteEventId(event_id.items);
                    has_id = false;
                }
                if (has_data and data.items.len != 0) return try data.toOwnedSlice(allocator);
                data.clearRetainingCapacity();
                has_data = false;
                continue;
            }
            if (line[0] == ':') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            const field = line[0..colon];
            var value = if (colon < line.len) line[colon + 1 ..] else "";
            if (value.len != 0 and value[0] == ' ') value = value[1..];
            if (std.mem.eql(u8, field, "id")) {
                // WHATWG: an id containing NUL is ignored.
                if (std.mem.indexOfScalar(u8, value, 0) == null) {
                    event_id.clearRetainingCapacity();
                    try event_id.appendSlice(allocator, value);
                    has_id = true;
                }
                continue;
            }
            if (std.mem.eql(u8, field, "retry")) {
                if (std.fmt.parseInt(u64, value, 10)) |ms| transport.retry_ms = ms else |_| {}
                continue;
            }
            if (!std.mem.eql(u8, field, "data")) continue;
            if (has_data) try data.append(allocator, '\n');
            try data.appendSlice(allocator, value);
            has_data = true;
            if (data.items.len > limit) return error.McpLineTooLarge;
        }
    }
};

/// One line (without its CR/LF) from `input`, accumulating partial bytes in
/// `pending` across calls.
pub fn readLine(input: *std.Io.Reader, allocator: std.mem.Allocator, pending: *std.ArrayList(u8), limit: usize) ![]u8 {
    while (true) {
        if (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            const line = try allocator.dupe(u8, std.mem.trimEnd(u8, pending.items[0..newline], "\r"));
            const rest = pending.items.len - newline - 1;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[newline + 1 ..]);
            pending.items.len = rest;
            return line;
        }
        if (pending.items.len > limit) return error.McpLineTooLarge;
        // Take whatever has arrived (at least one byte): an SSE server sends a
        // short event and then waits, so filling a fixed-size chunk would block.
        const available = input.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => {
                if (pending.items.len == 0) return error.EndOfStream;
                // A final line without a newline.
                const line = try allocator.dupe(u8, std.mem.trimEnd(u8, pending.items, "\r"));
                pending.items.len = 0;
                return line;
            },
            else => return err,
        };
        try pending.appendSlice(allocator, available);
        input.toss(available.len);
    }
}

/// `Mcp-Name` / `Mcp-Param-*` values that are not printable ASCII (or that
/// look like the sentinel) travel as `=?base64?<b64 of UTF-8>?=`.
pub fn headerSafe(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var safe = !std.mem.startsWith(u8, value, "=?base64?");
    for (value) |byte| {
        if (byte < 0x20 or byte > 0x7e) safe = false;
    }
    if (value.len != 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) safe = false;
    if (safe) return value;
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(value.len));
    _ = encoder.encode(encoded, value);
    return std.fmt.allocPrint(allocator, "=?base64?{s}?=", .{encoded});
}

const testing = std.testing;

test "header values that are not header-safe use the base64 sentinel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("get_weather", try headerSafe(a, "get_weather"));
    try testing.expectEqualStrings("=?base64?5Zyw5Z2A?=", try headerSafe(a, "地址"));
    try testing.expectEqualStrings("=?base64?ID1sZWFkaW5n?=", try headerSafe(a, " =leading"));
    try testing.expect(std.mem.startsWith(u8, try headerSafe(a, "=?base64?x?="), "=?base64?PT9"));
}

test "SSE lines split across reads are reassembled" {
    var input = std.Io.Reader.fixed("data: {\"a\":\r\ndata: 1}\r\n\r\n: keep-alive\n\nevent: x\ndata: two\n");
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(testing.allocator);
    const first = try readLine(&input, testing.allocator, &pending, 1024);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("data: {\"a\":", first);
}
