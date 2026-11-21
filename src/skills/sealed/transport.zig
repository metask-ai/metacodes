//! SSP/1 transport (doc/SEALED_SKILL_PROTOCOL.md §2): one JSON-RPC request
//! per HTTP POST, the answer as `application/json` or as a `text/event-stream`
//! whose last message is the response.
//!
//! The gateway never initiates requests, so this is a plain request/response
//! client. In-flight requests are registered in a `RequestAbortRegistry` so
//! the user's abort signal and the liveness monitor can shut a socket read
//! down, exactly as the model transports do.

const std = @import("std");
const protocol = @import("protocol.zig");
const log = @import("../../util/log.zig");
const util_time = @import("../../util/time.zig");
const provider = @import("../../api/provider.zig");
const http_status = @import("../../api/http_status.zig");
const http_connection = @import("../../api/http_connection.zig");
const AbortSignal = @import("../../util/abort.zig").AbortSignal;

/// Silence allowed on one gateway call before the liveness monitor gives up.
/// A gateway step is one model call or one workflow transition; two minutes
/// covers a long model generation without letting a dead socket hang a fork.
pub const DEFAULT_IDLE_LIMIT_MS: u64 = 120_000;

pub const Error = error{
    OutOfMemory,
    InvalidUrl,
    ConnectFailed,
    Aborted,
    Stalled,
    /// HTTP 503: the gateway refused the request before reading it (§2
    /// admission); `last_retry_after_ms` says when to resend it unchanged.
    Overloaded,
    Unauthorized,
    /// A non-2xx status that carried no JSON-RPC body.
    HttpError,
    ResponseTooLarge,
    InvalidResponse,
    /// The stream ended without a response for our request id.
    NoResponse,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,
    url: []u8,
    uri: std.Uri,
    /// `Authorization: Bearer <token>`; empty = no header (tests, public listing).
    token: []u8,
    /// §8.1: the client's provider credential, sent as
    /// `Sealed-Provider-Credential` on every request while non-empty. Borrowed
    /// from the provider it belongs to; the caller sets it for the call.
    provider_credential: []const u8 = "",
    registry: provider.RequestAbortRegistry = .{},
    next_id: u64 = 1,
    idle_limit_ms: u64 = DEFAULT_IDLE_LIMIT_MS,
    /// Last HTTP status seen, for diagnostics and the ledger.
    last_http_status: u16 = 0,
    /// From the last 503's `Retry-After` (seconds on the wire), in ms.
    last_retry_after_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: []const u8, token: []const u8) Error!Client {
        const owned_url = allocator.dupe(u8, url) catch return error.OutOfMemory;
        errdefer allocator.free(owned_url);
        const uri = std.Uri.parse(owned_url) catch return error.InvalidUrl;
        const owned_token = allocator.dupe(u8, token) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .http = .{ .allocator = allocator, .io = io },
            .url = owned_url,
            .uri = uri,
            .token = owned_token,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.registry.deinit(self.allocator);
        self.allocator.free(self.token);
        self.allocator.free(self.url);
        self.* = undefined;
    }

    /// Interrupt the request registered against `signal`, if any.
    pub fn cancel(self: *Client, signal: *const AbortSignal) void {
        self.registry.cancel(signal);
    }

    /// Send one request and return its parsed JSON-RPC response (result or
    /// error object). Transport failures are `Error`; a JSON-RPC error is a
    /// successful call whose response is `.err`.
    pub fn call(
        self: *Client,
        method: protocol.Method,
        params_json: []const u8,
        abort: ?*const AbortSignal,
    ) Error!protocol.ParsedResponse {
        const id = self.next_id;
        self.next_id += 1;
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        protocol.writeRequest(&body.writer, id, method, params_json) catch return error.OutOfMemory;
        // The client's own trace of the protocol exchange (§9.1 "Transport"):
        // method, request id, bytes each way, HTTP status and latency — never
        // the parameters, which carry the user's prompt and results.
        const started_ms = util_time.nowMs();
        const raw = self.post(body.written(), abort) catch |err| {
            log.warn("sealed", "{s} id={d} failed: {s} (http {d}, {d} B out, {d} ms)", .{ method.wire(), id, @errorName(err), self.last_http_status, body.written().len, util_time.nowMs() - started_ms });
            return err;
        };
        defer self.allocator.free(raw.bytes);
        log.info("sealed", "{s} id={d} -> http {d} {s} ({d} B out, {d} B in, {d} ms)", .{ method.wire(), id, self.last_http_status, @tagName(raw.kind), body.written().len, raw.bytes.len, util_time.nowMs() - started_ms });
        return switch (raw.kind) {
            .json => parseOne(self.allocator, raw.bytes, id),
            .sse => parseStream(self.allocator, raw.bytes, id),
        };
    }

    const Raw = struct {
        kind: enum { json, sse },
        bytes: []u8,
    };

    fn post(self: *Client, json: []const u8, abort: ?*const AbortSignal) Error!Raw {
        if (abort) |signal| if (signal.isAborted()) return error.Aborted;
        var auth_buf: [4096]u8 = undefined;
        var extra: [4]std.http.Header = undefined;
        var extra_len: usize = 0;
        extra[extra_len] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
        extra_len += 1;
        extra[extra_len] = .{ .name = protocol.VERSION_HEADER, .value = protocol.VERSION_HEADER_VALUE };
        extra_len += 1;
        if (self.token.len != 0) {
            const value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.token}) catch return error.OutOfMemory;
            extra[extra_len] = .{ .name = "Authorization", .value = value };
            extra_len += 1;
        }
        if (self.provider_credential.len != 0) {
            extra[extra_len] = .{ .name = protocol.PROVIDER_CREDENTIAL_HEADER, .value = self.provider_credential };
            extra_len += 1;
        }
        var request = self.http.request(.POST, self.uri, .{
            .keep_alive = false,
            // Bearer and provider credential ride in headers.
            .redirect_behavior = http_status.no_redirects,
            .headers = .{
                .accept_encoding = .omit,
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = extra[0..extra_len],
        }) catch return error.ConnectFailed;
        defer request.deinit();
        self.registry.registerMonitored(self.allocator, abort, @ptrCast(&request), shutdownRequest, self.idle_limit_ms) catch
            return error.OutOfMemory;
        defer self.registry.unregister(@ptrCast(&request));

        http_connection.sendBodyComplete(&request, @constCast(json)) catch return self.transportError(abort, &request);
        var redirect: [4096]u8 = undefined;
        const response = http_connection.receiveHead(&request, &redirect) catch return self.transportError(abort, &request);
        const status = http_status.ResponseStatus.capture(&response).code;
        self.last_http_status = status;
        const content_type = response.head.content_type orelse "";
        const is_sse = std.mem.startsWith(u8, content_type, "text/event-stream");
        // Headers are read now, before the body reader reuses their buffer.
        if (status == 503) {
            self.last_retry_after_ms = 1000;
            var headers = response.head.iterateHeaders();
            while (headers.next()) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
                const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " "), 10) catch continue;
                self.last_retry_after_ms = seconds * 1000;
            }
        }
        var transfer: [16 * 1024]u8 = undefined;
        const reader = http_connection.bodyReader(&response, &transfer);
        const bytes = reader.allocRemaining(self.allocator, .limited(protocol.MAX_MESSAGE_BYTES)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.ResponseTooLarge,
            else => return self.transportError(abort, &request),
        };
        errdefer self.allocator.free(bytes);
        switch (status) {
            200...299 => {},
            401, 403 => return error.Unauthorized,
            // A JSON-RPC error body (e.g. unsupported_version on 400) is still
            // delivered to the caller as a parsed error response.
            400, 402, 404...499 => if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return error.HttpError,
            503 => return error.Overloaded,
            else => return error.HttpError,
        }
        return .{ .kind = if (is_sse) .sse else .json, .bytes = bytes };
    }

    fn transportError(self: *Client, abort: ?*const AbortSignal, request: *std.http.Client.Request) Error {
        if (abort) |signal| if (signal.isAborted()) return error.Aborted;
        if (self.registry.stalled(@ptrCast(request)) != null) return error.Stalled;
        return error.ConnectFailed;
    }
};

fn shutdownRequest(raw: *anyopaque) void {
    const request: *std.http.Client.Request = @ptrCast(@alignCast(raw));
    provider.abortHttpRequest(request);
}

fn parseOne(allocator: std.mem.Allocator, bytes: []const u8, id: u64) Error!protocol.ParsedResponse {
    return protocol.parseResponse(allocator, bytes, id) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MessageTooLarge => error.ResponseTooLarge,
        error.NotOurResponse => error.NoResponse,
        else => error.InvalidResponse,
    };
}

/// Walk an SSE body: each event's `data:` lines (joined with `\n`) form one
/// JSON-RPC message; the one answering `id` is returned, others are skipped.
pub fn parseStream(allocator: std.mem.Allocator, body: []const u8, id: u64) Error!protocol.ParsedResponse {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var has_data = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (true) {
        const raw_line = lines.next();
        const line = if (raw_line) |l| std.mem.trimEnd(u8, l, "\r") else "";
        const end_of_event = raw_line == null or line.len == 0;
        if (end_of_event) {
            if (has_data and data.items.len != 0) {
                if (protocol.parseResponse(allocator, data.items, id)) |parsed| {
                    return parsed;
                } else |err| switch (err) {
                    error.NotOurResponse => {},
                    error.OutOfMemory => return error.OutOfMemory,
                    error.MessageTooLarge => return error.ResponseTooLarge,
                    else => return error.InvalidResponse,
                }
            }
            data.clearRetainingCapacity();
            has_data = false;
            if (raw_line == null) return error.NoResponse;
            continue;
        }
        if (line[0] == ':') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const field = line[0..colon];
        var value = if (colon < line.len) line[colon + 1 ..] else "";
        if (value.len != 0 and value[0] == ' ') value = value[1..];
        if (!std.mem.eql(u8, field, "data")) continue;
        if (has_data) data.append(allocator, '\n') catch return error.OutOfMemory;
        data.appendSlice(allocator, value) catch return error.OutOfMemory;
        has_data = true;
        if (data.items.len > protocol.MAX_MESSAGE_BYTES) return error.ResponseTooLarge;
    }
}

test "SSE body yields the response for our id and skips others" {
    const a = std.testing.allocator;
    const body =
        ": keepalive\n\n" ++
        "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n" ++
        "data: {\"jsonrpc\":\"2.0\",\n" ++
        "data:  \"id\":5,\"result\":{\"ok\":true}}\n\n";
    var parsed = try parseStream(a, body, 5);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", parsed.response.result);
    try std.testing.expectError(error.NoResponse, parseStream(a, body, 6));
}
