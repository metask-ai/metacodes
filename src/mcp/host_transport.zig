//! The Host Connector transport adapter: a connection whose owner (an embedding
//! Host, reached through the AgentCore ABI) performs each exchange and returns
//! its one response. The Host owns credentials, processes and sockets; the
//! shared client (`client.zig`) owns ordering, protocol state and correlation.
//!
//! The adapter presents that exchange as the client's message stream: `send`
//! holds the request, and the first read performs it. A Host connection has
//! exactly one response per request and no server-initiated frames, which is
//! what `Transport.singleResponse` tells the client.

const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const Capture = @import("../core/tool_result_artifact.zig").Capture;
const SendMeta = @import("transport_http.zig").SendMeta;
const canonical = @import("canonical.zig");
const negotiation = @import("negotiation.zig");

pub const ConnectionPurpose = enum(u8) { disposable_probe, actual };

pub const Cancellation = struct {
    ctx: ?*const anyopaque = null,
    is_cancelled_fn: *const fn (?*const anyopaque) bool = neverCancelled,

    pub fn isCancelled(self: Cancellation) bool {
        return self.is_cancelled_fn(self.ctx);
    }

    fn neverCancelled(_: ?*const anyopaque) bool {
        return false;
    }
};

pub const ExchangeResponse = struct {
    http_status: u32,
    body: []u8,
};

pub const ExchangeOutcome = union(enum) {
    /// Allocated by the allocator passed to `Connection.request`.
    response: ExchangeResponse,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    /// The request may have reached the server. Callers must not replay it.
    indeterminate,
    /// The Host callback contract failed. The connection must never be reused.
    fatal,
};

pub const ToolResponseSinkError = error{
    Cancelled,
    ResourceLimit,
    IoFailure,
    Closed,
};

/// Borrowed response-frame sink. The kernel creates the private capture before
/// invoking a streaming connector, so the first Host-produced byte is already
/// subject to Session quota, cancellation and rollback.
pub const ToolResponseSink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) ToolResponseSinkError!void,

    pub fn write(self: ToolResponseSink, chunk: []const u8) ToolResponseSinkError!void {
        return self.write_fn(self.ctx, chunk);
    }
};

pub const ToolStreamExchangeOutcome = enum {
    response,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    indeterminate,
    /// The connector contract failed. The connection must never be reused.
    fatal,
};

pub const ToolRequestExecutor = union(enum) {
    /// Source-only compatibility/testing adapter. Production public AgentCore
    /// connectors are admitted only through the streaming branch.
    completed: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!ExchangeOutcome,
    streaming: *const fn (
        ctx: *anyopaque,
        request: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
        sink: ToolResponseSink,
    ) anyerror!ToolStreamExchangeOutcome,
};

pub const ToolRequestOutcome = union(enum) {
    completed_response: ExchangeResponse,
    streamed_response,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    indeterminate,
    fatal,
};

pub const Connection = struct {
    ctx: *anyopaque,
    request_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!ExchangeOutcome,
    tool_request: ToolRequestExecutor,
    notify_fn: *const fn (
        ctx: *anyopaque,
        notification: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!void,
    close_fn: *const fn (ctx: *anyopaque) void,

    pub fn request(
        self: Connection,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!ExchangeOutcome {
        return self.request_fn(self.ctx, allocator, encoded, timeout_ms, cancellation);
    }

    pub fn notify(
        self: Connection,
        encoded: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!void {
        return self.notify_fn(self.ctx, encoded, timeout_ms, cancellation);
    }

    pub fn requestTool(
        self: Connection,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
        sink: ToolResponseSink,
    ) anyerror!ToolRequestOutcome {
        return switch (self.tool_request) {
            .completed => |callback| switch (try callback(
                self.ctx,
                allocator,
                encoded,
                timeout_ms,
                cancellation,
            )) {
                .response => |bytes| .{ .completed_response = bytes },
                .timeout => .timeout,
                .network_error => .network_error,
                .auth_error => .auth_error,
                .server_error => .server_error,
                .child_exit => .child_exit,
                .cancelled => .cancelled,
                .indeterminate => .indeterminate,
                .fatal => .fatal,
            },
            .streaming => |callback| switch (try callback(
                self.ctx,
                encoded,
                timeout_ms,
                cancellation,
                sink,
            )) {
                .response => .streamed_response,
                .timeout => .timeout,
                .network_error => .network_error,
                .auth_error => .auth_error,
                .server_error => .server_error,
                .child_exit => .child_exit,
                .cancelled => .cancelled,
                .indeterminate => .indeterminate,
                .fatal => .fatal,
            },
        };
    }

    pub fn close(self: Connection) void {
        self.close_fn(self.ctx);
    }
};

pub const OpenOutcome = union(enum) {
    connection: Connection,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
};

pub const Connector = struct {
    ctx: *anyopaque,
    open_fn: *const fn (
        ctx: *anyopaque,
        purpose: ConnectionPurpose,
        requested_era: canonical.Era,
    ) anyerror!OpenOutcome,
    retain_fn: *const fn (ctx: *anyopaque) anyerror!void = retainNoop,
    release_fn: *const fn (ctx: *anyopaque) void = releaseNoop,

    pub fn open(
        self: Connector,
        purpose: ConnectionPurpose,
        era: canonical.Era,
    ) anyerror!OpenOutcome {
        return self.open_fn(self.ctx, purpose, era);
    }

    pub fn retain(self: Connector) anyerror!void {
        return self.retain_fn(self.ctx);
    }

    pub fn release(self: Connector) void {
        self.release_fn(self.ctx);
    }

    fn retainNoop(_: *anyopaque) anyerror!void {}
    fn releaseNoop(_: *anyopaque) void {}
};

/// Latches the first failure of a streaming response, so what the connector
/// was told and what the client reports cannot differ.
const CaptureSink = struct {
    capture: *Capture,
    cancellation: Cancellation,
    failure: ?ToolResponseSinkError = null,
    closed: bool = false,

    fn interface(self: *CaptureSink) ToolResponseSink {
        return .{ .ctx = self, .write_fn = writeAdapter };
    }

    fn writeAdapter(raw: *anyopaque, chunk: []const u8) ToolResponseSinkError!void {
        const self: *CaptureSink = @ptrCast(@alignCast(raw));
        return self.write(chunk);
    }

    fn write(self: *CaptureSink, chunk: []const u8) ToolResponseSinkError!void {
        if (self.failure) |failure| return failure;
        if (self.closed) return self.latch(error.Closed);
        if (self.cancellation.isCancelled()) return self.latch(error.Cancelled);
        self.capture.write(chunk) catch |err| return self.latch(switch (err) {
            error.ArtifactTooLarge => error.ResourceLimit,
            else => error.IoFailure,
        });
    }

    fn latch(self: *CaptureSink, failure: ToolResponseSinkError) ToolResponseSinkError {
        if (self.failure == null) self.failure = failure;
        return self.failure.?;
    }

    fn failureError(self: *const CaptureSink) anyerror {
        return switch (self.failure orelse error.IoFailure) {
            error.Cancelled => error.Aborted,
            error.ResourceLimit, error.IoFailure, error.Closed => error.McpResourceLimit,
        };
    }
};

pub const HostTransport = struct {
    allocator: std.mem.Allocator,
    connection: Connection,
    kind: negotiation.Transport,
    timeout_ms: u32,
    abort: ?*const AbortSignal = null,
    /// The request `send` holds until the first read performs it.
    pending: ?[]u8 = null,
    pending_is_tool: bool = false,
    /// A disposable probe accepts HTTP 400 as evidence; other requests do not.
    probing: bool = false,
    last_http_status: ?u32 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        connection: Connection,
        kind: negotiation.Transport,
        timeout_ms: u32,
    ) error{OutOfMemory}!*HostTransport {
        const self = try allocator.create(HostTransport);
        self.* = .{
            .allocator = allocator,
            .connection = connection,
            .kind = kind,
            .timeout_ms = timeout_ms,
        };
        return self;
    }

    /// Closes the connection and destroys the adapter.
    pub fn close(self: *HostTransport) void {
        if (self.pending) |request| self.allocator.free(request);
        self.connection.close();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn cancellation(self: *const HostTransport) Cancellation {
        return .{ .ctx = self.abort, .is_cancelled_fn = abortCancelled };
    }

    fn abortCancelled(raw: ?*const anyopaque) bool {
        const abort: *const AbortSignal = @ptrCast(@alignCast(raw orelse return false));
        return abort.isAborted();
    }

    pub fn send(self: *HostTransport, json: []const u8, meta: SendMeta) !void {
        switch (meta.kind) {
            .notification => self.connection.notify(json, self.timeout_ms, self.cancellation()) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return error.McpConnectionFatal;
            },
            // A Host connection carries no server-initiated requests to answer.
            .response => {},
            .request => {
                const owned = try self.allocator.dupe(u8, json);
                if (self.pending) |previous| self.allocator.free(previous);
                self.pending = owned;
                self.pending_is_tool = std.mem.eql(u8, meta.method, "tools/call");
            },
        }
    }

    fn takePending(self: *HostTransport) error{Eof}![]u8 {
        const request = self.pending orelse return error.Eof;
        self.pending = null;
        return request;
    }

    /// The bounded control-plane exchange: one owned response frame.
    pub fn recvLine(self: *HostTransport) ![]u8 {
        const request = try self.takePending();
        defer self.allocator.free(request);
        const outcome = self.connection.request(
            self.allocator,
            request,
            self.timeout_ms,
            self.cancellation(),
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.McpConnectionFatal;
        };
        return switch (outcome) {
            .response => |response| self.admit(response),
            .timeout => error.Timeout,
            .network_error => error.McpConnectFailed,
            .auth_error => error.McpAuthRequired,
            .server_error => error.McpServerError,
            .child_exit => error.McpServerCrashed,
            .cancelled => error.Aborted,
            .indeterminate => error.McpOutcomeIndeterminate,
            .fatal => error.McpConnectionFatal,
        };
    }

    /// Only `tools/call` may use the much larger artifact data plane, with the
    /// connector's bytes entering the private capture from the first one.
    pub fn recvLineCapture(self: *HostTransport, capture: *Capture) !void {
        if (!self.pending_is_tool) {
            const frame = try self.recvLine();
            defer self.allocator.free(frame);
            return capture.write(frame);
        }
        const request = try self.takePending();
        defer self.allocator.free(request);
        var sink = CaptureSink{ .capture = capture, .cancellation = self.cancellation() };
        const outcome = self.connection.requestTool(
            self.allocator,
            request,
            self.timeout_ms,
            self.cancellation(),
            sink.interface(),
        ) catch return error.McpConnectionFatal;
        switch (outcome) {
            .completed_response => |response| {
                const body = try self.admit(response);
                defer self.allocator.free(body);
                sink.write(body) catch return sink.failureError();
            },
            .streamed_response => {},
            .timeout => return error.Timeout,
            .network_error => return error.McpConnectFailed,
            .auth_error => return error.McpAuthRequired,
            .server_error => return error.McpServerError,
            .child_exit => return error.McpServerCrashed,
            .cancelled => return error.Aborted,
            .indeterminate => return error.McpOutcomeIndeterminate,
            .fatal => return error.McpConnectionFatal,
        }
        sink.closed = true;
        if (sink.failure != null) return sink.failureError();
    }

    /// A response's HTTP status is classified before its body is parsed. On
    /// failure the body, allocated with `self.allocator`, is released here.
    fn admit(self: *HostTransport, response: ExchangeResponse) ![]u8 {
        self.last_http_status = response.http_status;
        errdefer self.allocator.free(response.body);
        switch (self.kind) {
            .stdio => if (response.http_status != 0)
                return if (self.probing) error.McpMalformedResponse else error.McpServerError,
            .streamable_http => switch (response.http_status) {
                200...299 => {},
                400 => if (!self.probing) return error.McpServerError,
                401, 403 => return error.McpAuthRequired,
                else => return error.McpServerError,
            },
        }
        return response.body;
    }
};
