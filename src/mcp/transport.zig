//! The MCP transports behind one message-stream interface: stdio,
//! Streamable HTTP, the 2024-11-05 HTTP+SSE transport, and a Host connection
//! (`host_transport.zig`).

const std = @import("std");
const StdioTransport = @import("transport_stdio.zig").StdioTransport;
const http = @import("transport_http.zig");
const sse = @import("transport_sse.zig");
const host = @import("host_transport.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const Capture = @import("../core/tool_result_artifact.zig").Capture;

pub const HttpTransport = http.HttpTransport;
pub const SseTransport = sse.SseTransport;
pub const HostTransport = host.HostTransport;
pub const SendMeta = http.SendMeta;
pub const Header = http.Header;

pub const Transport = union(enum) {
    stdio: StdioTransport,
    http: *HttpTransport,
    sse: *SseTransport,
    host: *HostTransport,

    pub fn send(self: *Transport, json: []const u8, meta: SendMeta) !void {
        return switch (self.*) {
            .stdio => |*stdio| stdio.send(json),
            .http => |transport| transport.send(json, meta),
            .sse => |transport| transport.send(json, meta),
            .host => |transport| transport.send(json, meta),
        };
    }

    pub fn recvLine(self: *Transport) ![]u8 {
        return switch (self.*) {
            .stdio => |*stdio| stdio.recvLine(),
            .http => |transport| transport.recvLine(),
            .sse => |transport| transport.recvLine(),
            .host => |transport| transport.recvLine(),
        };
    }

    pub fn recvLineCapture(self: *Transport, capture: *Capture) !void {
        return switch (self.*) {
            .stdio => |*stdio| stdio.recvLineCapture(capture),
            .http => |transport| transport.recvLineCapture(capture),
            .sse => |transport| transport.recvLineCapture(capture),
            .host => |transport| transport.recvLineCapture(capture),
        };
    }

    /// The awaited response has been read. Over HTTP the rest of its SSE
    /// stream is then finished before the next request, so the connection
    /// can be reused; stdio has nothing to do.
    pub fn markAnswered(self: *Transport) void {
        switch (self.*) {
            .stdio, .sse, .host => {},
            .http => |transport| transport.markAnswered(),
        }
    }

    pub fn setDeadline(self: *Transport, deadline_ms: ?i64) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.deadline_ms = deadline_ms,
            .http => |transport| transport.deadline_ms = deadline_ms,
            .sse => |transport| transport.deadline_ms = deadline_ms,
            // A Host exchange is bounded by the timeout it is handed.
            .host => {},
        }
    }

    pub fn setAbort(self: *Transport, abort: ?*const AbortSignal) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.abort = abort,
            .http => |transport| transport.abort = abort,
            .sse => |transport| transport.abort = abort,
            .host => |transport| transport.abort = abort,
        }
    }

    pub fn close(self: *Transport) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.close(),
            .http => |transport| transport.close(),
            .sse => |transport| transport.close(),
            .host => |transport| transport.close(),
        }
    }

    /// Streamable HTTP: a probe that gets no answer is not evidence of an
    /// older server.
    pub fn isHttp(self: *const Transport) bool {
        return self.* == .http;
    }

    /// The transport itself ends a request that is interrupted or times out:
    /// Streamable HTTP closes the response stream, a Host connection polls the
    /// cancellation it was handed. stdio and HTTP+SSE have one stream that
    /// outlives every request, so the client says `notifications/cancelled`.
    pub fn cancelsItself(self: *const Transport) bool {
        return switch (self.*) {
            .http, .host => true,
            .stdio, .sse => false,
        };
    }

    /// Exactly one frame answers a request and none arrives unasked, so a
    /// frame that does not match is a protocol failure, not a stale answer.
    pub fn singleResponse(self: *const Transport) bool {
        return self.* == .host;
    }

    /// The request reached the wire whole (or may have), so a failure from
    /// here on says nothing about whether the server acted on it. A stdio
    /// `send` writes the terminating newline last, and a message without it is
    /// not a message, so its failure always means nothing was delivered.
    pub fn requestWritten(self: *const Transport) bool {
        return switch (self.*) {
            .stdio => false,
            .http => |transport| transport.request_written,
            .sse => |transport| transport.request_written,
            .host => true,
        };
    }

    /// The HTTP status a Host connection reported for its last response.
    pub fn lastHttpStatus(self: *const Transport) ?u32 {
        return switch (self.*) {
            .host => |transport| transport.last_http_status,
            .stdio, .http, .sse => null,
        };
    }

    /// The negotiated revision, sent as `MCP-Protocol-Version` over HTTP.
    pub fn setProtocolVersion(self: *Transport, version: ?[]const u8) void {
        switch (self.*) {
            .stdio, .host => {},
            .http => |transport| transport.protocol_version = version,
            .sse => |transport| transport.protocol_version = version,
        }
    }

    /// Whether requests carry the 2026-07-28 routing headers. Set for a
    /// discovery probe too, which is itself a 2026-07-28 request.
    pub fn setModern(self: *Transport, modern: bool, version: []const u8) void {
        if (self.* == .http) {
            self.http.modern = modern;
            self.http.protocol_version = if (modern) version else null;
        }
    }

    /// Mark the open request as a disposable probe (see `HostTransport.probing`).
    pub fn setProbing(self: *Transport, probing: bool) void {
        if (self.* == .host) self.host.probing = probing;
    }
};
