//! The MCP transports behind one message-stream interface: stdio,
//! Streamable HTTP, and the 2024-11-05 HTTP+SSE transport.

const std = @import("std");
const StdioTransport = @import("transport_stdio.zig").StdioTransport;
const http = @import("transport_http.zig");
const sse = @import("transport_sse.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const Capture = @import("../core/tool_result_artifact.zig").Capture;

pub const HttpTransport = http.HttpTransport;
pub const SseTransport = sse.SseTransport;
pub const SendMeta = http.SendMeta;
pub const Header = http.Header;

pub const Transport = union(enum) {
    stdio: StdioTransport,
    http: *HttpTransport,
    sse: *SseTransport,

    pub fn send(self: *Transport, json: []const u8, meta: SendMeta) !void {
        return switch (self.*) {
            .stdio => |*stdio| stdio.send(json),
            .http => |transport| transport.send(json, meta),
            .sse => |transport| transport.send(json, meta),
        };
    }

    pub fn recvLine(self: *Transport) ![]u8 {
        return switch (self.*) {
            .stdio => |*stdio| stdio.recvLine(),
            .http => |transport| transport.recvLine(),
            .sse => |transport| transport.recvLine(),
        };
    }

    pub fn recvLineCapture(self: *Transport, capture: *Capture) !void {
        return switch (self.*) {
            .stdio => |*stdio| stdio.recvLineCapture(capture),
            .http => |transport| transport.recvLineCapture(capture),
            .sse => |transport| transport.recvLineCapture(capture),
        };
    }

    /// The awaited response has been read. Over HTTP the rest of its SSE
    /// stream is then finished before the next request, so the connection
    /// can be reused; stdio has nothing to do.
    pub fn markAnswered(self: *Transport) void {
        switch (self.*) {
            .stdio, .sse => {},
            .http => |transport| transport.markAnswered(),
        }
    }

    pub fn setDeadline(self: *Transport, deadline_ms: ?i64) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.deadline_ms = deadline_ms,
            .http => |transport| transport.deadline_ms = deadline_ms,
            .sse => |transport| transport.deadline_ms = deadline_ms,
        }
    }

    pub fn setAbort(self: *Transport, abort: ?*const AbortSignal) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.abort = abort,
            .http => |transport| transport.abort = abort,
            .sse => |transport| transport.abort = abort,
        }
    }

    pub fn close(self: *Transport) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.close(),
            .http => |transport| transport.close(),
            .sse => |transport| transport.close(),
        }
    }

    /// Streamable HTTP: a request is cancelled by closing its response
    /// stream, and a probe that gets no answer is not evidence of an older
    /// server. (HTTP+SSE cancels with `notifications/cancelled`, as stdio
    /// does: its one stream outlives every request.)
    pub fn isHttp(self: *const Transport) bool {
        return self.* == .http;
    }

    /// The negotiated revision, sent as `MCP-Protocol-Version` over HTTP.
    pub fn setProtocolVersion(self: *Transport, version: ?[]const u8) void {
        switch (self.*) {
            .stdio => {},
            .http => |transport| transport.protocol_version = version,
            .sse => |transport| transport.protocol_version = version,
        }
    }
};
