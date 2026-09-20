//! One `tinykgd` child, spoken to over its versioned NDJSON stdio protocol.
//!
//! The daemon owns the Store exclusively and serves one request at a time, so
//! this bridge is deliberately serial: callers hold `mutex` for a complete
//! send/receive pair. Interleaving two requests on one pipe would correlate
//! responses to the wrong caller, and the protocol's `requestId` echo is the
//! only thing that would catch it.

const std = @import("std");
const StdioTransport = @import("../../mcp/transport_stdio.zig").StdioTransport;
const log = @import("../../util/log.zig");
const sync = @import("platform").sync;
const util_time = @import("../../util/time.zig");

/// The stdio protocol version `tinykgd` speaks. Unrelated to the HTTP envelope
/// version Metacodes clients use; confusing the two is the obvious mistake.
pub const DAEMON_PROTOCOL_VERSION: u32 = 1;
pub const DAEMON_IMPLEMENTATION = "tinykg-daemon";
/// A daemon response is a JSON line; the store can return large query results,
/// and anything past this is a broken frame rather than an answer.
pub const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

pub const Error = error{
    SpawnFailed,
    WriteFailed,
    ReadFailed,
    /// The child accepted the request and did not answer within its own
    /// timeout. Terminal for this bridge: the pipe is desynchronized, because
    /// a late answer would be read as the reply to a later request.
    ResponseTimedOut,
    ResponseTooLarge,
    ResponseInvalid,
    RequestIdMismatch,
    OutOfMemory,
};

/// Added to the request's own timeout before this side gives up, so the daemon
/// gets the chance to fail the request itself and stay usable.
pub const RESPONSE_GRACE_MS: i64 = 5_000;

pub const Request = struct {
    request_id: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    session_id: ?[]const u8 = null,
    content_digest: ?[]const u8 = null,
    timeout_ms: u64 = 180_000,
};

/// Borrowed from `parsed`; valid until `deinit`.
pub const Response = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
    }

    pub fn object(self: *const Response) std.json.ObjectMap {
        return self.parsed.value.object;
    }

    pub fn string(self: *const Response, name: []const u8) ?[]const u8 {
        const value = self.parsed.value.object.get(name) orelse return null;
        return if (value == .string) value.string else null;
    }

    pub fn integer(self: *const Response, name: []const u8) ?i64 {
        const value = self.parsed.value.object.get(name) orelse return null;
        return if (value == .integer) value.integer else null;
    }

    pub fn boolean(self: *const Response, name: []const u8) bool {
        const value = self.parsed.value.object.get(name) orelse return false;
        return value == .bool and value.bool;
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    transport: StdioTransport,
    /// Held across a complete send/receive pair, never only one half.
    /// (`platform.sync.Mutex`: the trimmed std this project builds against has
    /// no `Thread.Mutex`.)
    mutex: sync.Mutex = .{},
    /// Set once the child stops answering. A bridge never silently reconnects:
    /// a new child would own a different generation sequence, and the client's
    /// monotonic-generation check exists precisely to notice that.
    broken: bool = false,

    pub fn start(
        allocator: std.mem.Allocator,
        daemon_path: []const u8,
        store_path: []const u8,
    ) Error!Bridge {
        const daemon_z = allocator.dupeZ(u8, daemon_path) catch return Error.OutOfMemory;
        defer allocator.free(daemon_z);
        const store_z = allocator.dupeZ(u8, store_path) catch return Error.OutOfMemory;
        defer allocator.free(store_z);
        const argv = [_]?[*:0]const u8{ daemon_z.ptr, "--store", store_z.ptr, null };
        const transport = StdioTransport.spawn(allocator, &argv) catch return Error.SpawnFailed;
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn stop(self: *Bridge) void {
        self.transport.close();
    }

    pub fn isBroken(self: *const Bridge) bool {
        return self.broken;
    }

    /// Serialize, send, read one line, parse. The `requestId` echo is checked
    /// here so a desynchronized pipe can never be mistaken for an answer.
    pub fn run(self: *Bridge, request: Request) Error!Response {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        if (self.broken) return Error.ReadFailed;

        // Encoding happens before anything is written, so a failure here leaves
        // the pipe untouched and must not poison a healthy bridge.
        const body = try self.encode(request);
        defer self.allocator.free(body);

        // From here on the child has seen bytes: any failure desynchronizes the
        // stream, so the bridge is done.
        errdefer self.broken = true;
        self.transport.send(body) catch return Error.WriteFailed;

        const deadline: i64 = util_time.nowMs() +| @as(i64, @intCast(@min(request.timeout_ms, std.math.maxInt(i32)))) +| RESPONSE_GRACE_MS;
        self.transport.deadline_ms = deadline;
        defer self.transport.deadline_ms = null;
        const line = self.transport.recvLine() catch |err| return switch (err) {
            error.Timeout => Error.ResponseTimedOut,
            else => Error.ReadFailed,
        };
        defer self.allocator.free(line);
        if (line.len > MAX_RESPONSE_BYTES) return Error.ResponseTooLarge;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch
            return Error.ResponseInvalid;
        var response = Response{ .parsed = parsed };
        errdefer response.deinit();
        if (parsed.value != .object) return Error.ResponseInvalid;
        if (response.integer("protocolVersion") != @as(i64, DAEMON_PROTOCOL_VERSION)) return Error.ResponseInvalid;
        const implementation = response.string("implementation") orelse return Error.ResponseInvalid;
        if (!std.mem.eql(u8, implementation, DAEMON_IMPLEMENTATION)) return Error.ResponseInvalid;
        const echoed = response.string("requestId") orelse return Error.ResponseInvalid;
        if (!std.mem.eql(u8, echoed, request.request_id)) return Error.RequestIdMismatch;
        if (response.parsed.value.object.get("stdout") == null or
            response.parsed.value.object.get("generation") == null)
            return Error.ResponseInvalid;
        return response;
    }

    fn encode(self: *Bridge, request: Request) Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const envelope = .{
            .protocolVersion = DAEMON_PROTOCOL_VERSION,
            .requestId = request.request_id,
            .command = request.command,
            .args = request.args,
            .sessionId = request.session_id,
            .contentDigest = request.content_digest,
            // The store is the daemon's, chosen when it was started. A client
            // never selects one, and the daemon rejects the attempt anyway.
            .injectStore = true,
            .timeoutMs = request.timeout_ms,
        };
        std.json.Stringify.value(envelope, .{ .emit_null_optional_fields = false }, &out.writer) catch
            return Error.OutOfMemory;
        return out.toOwnedSlice() catch Error.OutOfMemory;
    }
};

const testing = std.testing;

test "KgdBridge: the request envelope names the daemon protocol and owns the store" {
    const a = testing.allocator;
    var bridge = Bridge{ .allocator = a, .transport = undefined };
    const body = try bridge.encode(.{
        .request_id = "metacodes-kgd-1",
        .command = "store-info",
        .timeout_ms = 1234,
    });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"protocolVersion\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"requestId\":\"metacodes-kgd-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"injectStore\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"timeoutMs\":1234") != null);
    // Absent optionals must not appear as nulls: the daemon validates its input.
    try testing.expect(std.mem.indexOf(u8, body, "sessionId") == null);
    try testing.expect(std.mem.indexOf(u8, body, "contentDigest") == null);
}

test "KgdBridge: a session and a content digest are carried through" {
    const a = testing.allocator;
    var bridge = Bridge{ .allocator = a, .transport = undefined };
    const body = try bridge.encode(.{
        .request_id = "metacodes-kgd-2",
        .command = "query",
        .args = &.{ "--limit", "5" },
        .session_id = "session-a",
        .content_digest = "sha256:" ++ ("a" ** 64),
    });
    defer a.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"sessionId\":\"session-a\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"args\":[\"--limit\",\"5\"]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"contentDigest\":\"sha256:aaaa") != null);
}
