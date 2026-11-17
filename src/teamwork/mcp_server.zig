//! Manager MCP boundary (#522). The host starts an approved runtime.Run;
//! this server only drives its existing operations. See doc/TEAMWORK_MCP.md.
const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const runtime = @import("runtime.zig");
const types = @import("types.zig");

pub const max_message_bytes = 1024 * 1024;
pub const max_response_bytes = 4 * 1024 * 1024;
pub const protocol_version = "2025-11-25";
const empty_object: struct {} = .{};

pub const Server = struct {
    gpa: std.mem.Allocator,
    run: *runtime.Run,
    lifecycle: enum { fresh, negotiated, ready } = .fresh,

    /// Borrows run, which must outlive the server. No allocation or approval.
    /// One thread calls handle/serve; only run.abort may be used concurrently.
    pub fn init(gpa: std.mem.Allocator, run: *runtime.Run) Server {
        return .{ .gpa = gpa, .run = run };
    }

    /// One JSON-RPC message, without its newline. A response is owned by gpa
    /// (caller frees); null means notification/response, with no reply.
    /// Protocol and runtime errors are encoded, not thrown. OOM is propagated.
    pub fn handle(self: *Server, gpa: std.mem.Allocator, line: []const u8) error{OutOfMemory}!?[]u8 {
        if (line.len > max_message_bytes) return try rpcError(gpa, .null, -32600, "Message too large");
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{ .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return try rpcError(gpa, .null, -32700, "Parse error");
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return try rpcError(gpa, .null, -32600, "Invalid Request");
        const id = field(root, "id");
        if (id) |v| switch (v) {
            .integer, .string => {},
            else => return try rpcError(gpa, .null, -32600, "Invalid request id"),
        };
        const reply_id = id orelse .null;
        if (!stringEquals(field(root, "jsonrpc"), "2.0")) return try rpcError(gpa, reply_id, -32600, "Invalid JSON-RPC version");
        const method = string(field(root, "method")) orelse {
            // No server-initiated requests are issued; never answer responses.
            if (field(root, "result") != null or field(root, "error") != null) return null;
            return try rpcError(gpa, reply_id, -32600, "Missing method");
        };
        const params = field(root, "params");
        // Notifications never invoke a mutating runtime operation.
        if (id == null) {
            if (std.mem.eql(u8, method, "notifications/initialized") and self.lifecycle == .negotiated and
                (params == null or params.? == .object)) self.lifecycle = .ready;
            return null;
        }
        if (params) |p| if (p != .object) return try rpcError(gpa, reply_id, -32602, "Expected object params");
        if (std.mem.eql(u8, method, "ping")) return try response(gpa, reply_id, empty_object);
        if (std.mem.eql(u8, method, "initialize")) {
            if (self.lifecycle != .fresh) return try rpcError(gpa, reply_id, -32600, "Already initialized");
            const p = params orelse return try rpcError(gpa, reply_id, -32602, "Missing initialize params");
            const requested = string(field(p, "protocolVersion")) orelse return try rpcError(gpa, reply_id, -32602, "Missing protocolVersion");
            const info = field(p, "clientInfo") orelse return try rpcError(gpa, reply_id, -32602, "Missing clientInfo");
            if (string(field(info, "name")) == null or string(field(info, "version")) == null or
                (field(p, "capabilities") orelse .null) != .object)
                return try rpcError(gpa, reply_id, -32602, "Invalid clientInfo or capabilities");
            const version = for ([_][]const u8{ protocol_version, "2025-06-18", "2025-03-26", "2024-11-05" }) |v| {
                if (std.mem.eql(u8, requested, v)) break v;
            } else protocol_version;
            const out = try response(gpa, reply_id, .{
                .protocolVersion = version,
                .capabilities = .{ .tools = .{ .listChanged = false } },
                .serverInfo = .{ .name = "metacodes-teamwork", .version = "1.0.0" },
                .instructions = "Drive the host-approved run. Dispatch is synchronous. Completion requires runtime review, audit and merge. No tool grants approval or changes configuration.",
            });
            self.lifecycle = .negotiated;
            return out;
        }
        if (self.lifecycle != .ready) return try rpcError(gpa, reply_id, -32000, "Server not initialized");
        if (std.mem.eql(u8, method, "tools/list")) {
            if (params) |p| {
                if (!onlyFields(p, &.{ "cursor", "_meta" }) or field(p, "cursor") != null)
                    return try rpcError(gpa, reply_id, -32602, "No pagination cursor is supported");
            }
            return try response(gpa, reply_id, tool_list);
        }
        if (!std.mem.eql(u8, method, "tools/call")) return try rpcError(gpa, reply_id, -32601, "Method not found");
        const p = params orelse return try rpcError(gpa, reply_id, -32602, "Missing tool params");
        if (!onlyFields(p, &.{ "name", "arguments", "_meta" })) return try rpcError(gpa, reply_id, -32602, "Unknown tool parameter");
        const name = string(field(p, "name")) orelse return try rpcError(gpa, reply_id, -32602, "Missing tool name");
        const args = field(p, "arguments");
        if (args) |a| if (a != .object) return try rpcError(gpa, reply_id, -32602, "Expected object arguments");

        if (std.mem.eql(u8, name, "teamwork_dispatch")) {
            const a = args orelse return try rpcError(gpa, reply_id, -32602, "Missing dispatch arguments");
            if (!onlyFields(a, &.{ "role", "instructions" })) return try rpcError(gpa, reply_id, -32602, "Unknown dispatch argument");
            const role_text = string(field(a, "role")) orelse return try rpcError(gpa, reply_id, -32602, "Missing role");
            const role = types.Role.parse(role_text) orelse return try rpcError(gpa, reply_id, -32602, "Invalid role");
            if (role != .implementer and role != .reviewer) return try rpcError(gpa, reply_id, -32602, "Only implementer/reviewer can be dispatched");
            const instructions = if (field(a, "instructions")) |v|
                string(v) orelse return try rpcError(gpa, reply_id, -32602, "Expected string instructions")
            else
                "";
            const seat = self.run.dispatch(role, instructions) catch |err| return try self.runtimeError(gpa, reply_id, err);
            return try self.toolResult(gpa, reply_id, .{ .kind = "dispatch", .seat_id = seat.slice() }, false, null);
        }
        if (args) |a| if (!onlyFields(a, &.{})) return try rpcError(gpa, reply_id, -32602, "This tool accepts no arguments");
        if (std.mem.eql(u8, name, "teamwork_status"))
            return try self.toolResult(gpa, reply_id, .{ .kind = "status" }, false, null);
        if (std.mem.eql(u8, name, "teamwork_cancel")) {
            self.run.cancel() catch |err| return try self.runtimeError(gpa, reply_id, err);
            return try self.toolResult(gpa, reply_id, .{ .kind = "cancel" }, false, null);
        }
        if (std.mem.eql(u8, name, "teamwork_request_completion")) {
            const outcome = self.run.requestCompletion() catch |err| return try self.runtimeError(gpa, reply_id, err);
            const failed = switch (outcome) {
                .failed, .budget_exhausted, .cancelled => true,
                .done, .approval_stale, .repair_requested => false,
            };
            return try self.toolResult(gpa, reply_id, .{ .kind = "completion", .outcome = tagged(outcome) }, failed, null);
        }
        return try rpcError(gpa, reply_id, -32602, "Unknown tool");
    }

    fn runtimeError(self: *Server, gpa: std.mem.Allocator, id: std.json.Value, err: runtime.Error) error{OutOfMemory}![]u8 {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return self.toolResult(gpa, id, .{ .kind = "error" }, true, @errorName(err));
    }

    fn toolResult(self: *Server, gpa: std.mem.Allocator, id: std.json.Value, operation: anytype, failed: bool, err: ?[]const u8) error{OutOfMemory}![]u8 {
        const payload = .{ .snapshot = Snapshot{ .value = self.run.status() }, .operation = operation, .@"error" = err };
        const encoded = encode(gpa, payload) catch |encode_err| switch (encode_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResponseTooLarge => return rpcError(gpa, id, -32603, "Response too large; query status"),
        };
        defer gpa.free(encoded);
        // Text is the same JSON object as structuredContent, for older clients.
        return response(gpa, id, .{
            .content = .{.{ .type = "text", .text = encoded }},
            .structuredContent = payload,
            .isError = failed,
        });
    }

    /// Blocking NDJSON on stdin/stdout. Host diagnostics/drivers must use
    /// stderr, and the host owns SIGPIPE/interrupt policy. Does not close fds.
    pub fn serve(self: *Server) !void {
        return self.serveFds(0, 1);
    }

    /// Same transport on host-owned descriptors (also used by L2 tests).
    /// EOF cancels a live run, so subprocess shutdown cannot orphan it.
    pub fn serveFds(self: *Server, input: pfs.Fd, output: pfs.Fd) !void {
        errdefer self.run.cancel() catch {};
        const buffer = try self.gpa.alloc(u8, max_message_bytes);
        defer self.gpa.free(buffer);
        var len: usize = 0;
        var oversized = false;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = pfs.read(input, &chunk);
            if (n < 0) {
                if (builtin.os.tag != .windows and pfs.lastErrnoIs(.INTR)) continue;
                return error.ReadFailed;
            }
            if (n == 0) break;
            for (chunk[0..@intCast(n)]) |byte| {
                if (byte == '\n') {
                    const out = if (oversized)
                        try rpcError(self.gpa, .null, -32600, "Message too large")
                    else
                        try self.handle(self.gpa, std.mem.trimEnd(u8, buffer[0..len], "\r"));
                    if (out) |bytes| {
                        defer self.gpa.free(bytes);
                        if (!pfs.writeAll(output, bytes) or !pfs.writeAll(output, "\n")) return error.WriteFailed;
                    }
                    len = 0;
                    oversized = false;
                } else if (!oversized) {
                    if (len == buffer.len) {
                        oversized = true;
                    } else {
                        buffer[len] = byte;
                        len += 1;
                    }
                }
            }
        }
        // A partial final frame is never executed (it may be truncated).
        if (len != 0 or oversized) {
            const bytes = try rpcError(self.gpa, .null, -32700, "Unterminated message");
            defer self.gpa.free(bytes);
            if (!pfs.writeAll(output, bytes) or !pfs.writeAll(output, "\n")) return error.WriteFailed;
        }
        try self.run.cancel();
    }
};

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(name) else null;
}

fn string(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn stringEquals(value: ?std.json.Value, expected: []const u8) bool {
    return std.mem.eql(u8, string(value) orelse return false, expected);
}

fn onlyFields(value: std.json.Value, allowed: []const []const u8) bool {
    if (value != .object) return false;
    for (value.object.keys()) |key| {
        for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) break;
        } else return false;
    }
    return true;
}

fn encode(gpa: std.mem.Allocator, value: anytype) error{ OutOfMemory, ResponseTooLarge }![]u8 {
    const buffer = try gpa.alloc(u8, max_response_bytes);
    defer gpa.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(value, .{}, &writer) catch return error.ResponseTooLarge;
    return gpa.dupe(u8, writer.buffered());
}

fn response(gpa: std.mem.Allocator, id: std.json.Value, result: anytype) error{OutOfMemory}![]u8 {
    return encode(gpa, .{ .jsonrpc = "2.0", .id = id, .result = result }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResponseTooLarge => rpcError(gpa, id, -32603, "Response too large; query status"),
    };
}

fn rpcError(gpa: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) error{OutOfMemory}![]u8 {
    return encode(gpa, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResponseTooLarge => gpa.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Response too large\"}}"),
    };
}

/// Explicit discriminator even for void variants; never serialize ID backing
/// arrays (which contain undefined padding) or lose a union's active tag.
fn Tagged(comptime T: type) type {
    return struct {
        value: T,
        pub fn jsonStringify(self: @This(), writer: anytype) !void {
            try writer.beginObject();
            try writer.objectField("kind");
            try writer.write(@tagName(self.value));
            try writer.objectField("detail");
            switch (self.value) {
                inline else => |payload| {
                    if (@TypeOf(payload) == void) {
                        try writer.write(null);
                    } else if (@TypeOf(payload) == @import("reviewer.zig").TreeId) {
                        try writer.write(payload.slice());
                    } else try writer.write(payload);
                },
            }
            try writer.endObject();
        }
    };
}

fn tagged(value: anytype) Tagged(@TypeOf(value)) {
    return .{ .value = value };
}

const Snapshot = struct {
    value: runtime.RunSnapshot,
    pub fn jsonStringify(self: Snapshot, writer: anytype) !void {
        const s = self.value;
        try writer.beginObject();
        try writer.objectField("run_id");
        try writer.write(s.run_id.slice());
        try writer.objectField("goal");
        try writer.write(s.goal);
        try writer.objectField("state");
        try writer.write(tagged(s.state));
        try writer.objectField("seats");
        try writer.beginArray();
        for (s.seats) |seat| {
            try writer.beginObject();
            try writer.objectField("id");
            try writer.write(seat.id.slice());
            try writer.objectField("role");
            try writer.write(seat.role);
            try writer.objectField("harness");
            try writer.write(seat.harness);
            try writer.objectField("status");
            try writer.write(seat.status);
            if (@hasField(runtime.SeatSnapshot, "charter_sha256")) {
                try writer.objectField("charter_sha256");
                try writer.write(seat.charter_sha256);
            }
            try writer.objectField("result");
            if (seat.result) |result| {
                // ReviewResult and SeatError are unions too: retain both tags.
                switch (result) {
                    .review => |review| try writer.write(.{ .kind = "review", .detail = tagged(review) }),
                    .failed => |err| try writer.write(.{ .kind = "failed", .detail = tagged(err) }),
                    else => try writer.write(tagged(result)),
                }
            } else try writer.write(null);
            try writer.endObject();
        }
        try writer.endArray();
        inline for (.{ "budget", "open_issues", "audit", "max_rounds", "worktree", "merge_conflicts" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(s, name));
        }
        try writer.endObject();
    }
};

const empty_schema = .{ .type = "object", .properties = empty_object, .additionalProperties = false };
const tool_list = .{ .tools = .{
    .{ .name = "teamwork_status", .description = "Read the actual approved run snapshot.", .inputSchema = empty_schema },
    .{
        .name = "teamwork_dispatch",
        .description = "Synchronously run one implementer or reviewer seat under the host-approved configuration and budget.",
        .inputSchema = .{
            .type = "object",
            .properties = .{
                .role = .{ .type = "string", .@"enum" = .{ "implementer", "reviewer" } },
                .instructions = .{ .type = "string" },
            },
            .required = .{"role"},
            .additionalProperties = false,
        },
    },
    .{ .name = "teamwork_request_completion", .description = "Ask the runtime to verify review approval, audit independently and merge. Only the runtime can mark done.", .inputSchema = empty_schema },
    .{ .name = "teamwork_cancel", .description = "Cancel the run between calls, retaining its worktree. Idempotent for ended runs.", .inputSchema = empty_schema },
} };

test {
    _ = @import("mcp_server_test.zig");
}
