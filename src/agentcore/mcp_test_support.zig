//! Test-only in-memory MCP peer shared by AgentCore conformance tests.

const std = @import("std");
const canonical = @import("mcp_canonical.zig");
const runtime = @import("mcp_runtime.zig");

pub const Server = struct {
    era: canonical.Era = .modern_2026_07_28,
    available: bool = true,
    tool_name: []const u8 = "weather",
    input_schema_json: []const u8 =
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"],\"additionalProperties\":false}",
    output_schema_json: []const u8 =
        "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"]}",
    result_padding_bytes: usize = 0,
    ttl_ms: u64 = 1000,
    paginate: bool = false,
    required_task: bool = false,
    opens: u32 = 0,
    closes: u32 = 0,
    calls: u32 = 0,

    const Connection = struct { owner: *Server };

    pub fn connector(self: *Server) runtime.Connector {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(
        raw: *anyopaque,
        _: runtime.ConnectionPurpose,
        requested_era: canonical.Era,
    ) anyerror!runtime.OpenOutcome {
        const self: *Server = @ptrCast(@alignCast(raw));
        if (!self.available or requested_era != self.era)
            return .network_error;
        const connection = try std.heap.c_allocator.create(Connection);
        connection.* = .{ .owner = self };
        self.opens += 1;
        return .{ .connection = .{
            .ctx = connection,
            .request_fn = request,
            .tool_request = .{ .completed = request },
            .notify_fn = notify,
            .close_fn = close,
        } };
    }

    fn request(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        _: u32,
        _: runtime.Cancellation,
    ) anyerror!runtime.ExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        const self = connection.owner;
        const id = requestId(encoded) orelse return .server_error;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{}},\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                .{ id, self.ttl_ms },
            )
        else if (std.mem.indexOf(u8, encoded, "initialize") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"agentcore-test\",\"version\":\"1\"}}}}}}",
                .{ id, self.era.version() },
            )
        else if (std.mem.indexOf(u8, encoded, "tools/list") != null) blk: {
            if (self.paginate) {
                if (self.era != .modern_2026_07_28) return .server_error;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"{s}\",\"inputSchema\":{s},\"outputSchema\":{s}}}],\"nextCursor\":\"again\",\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                    .{ id, self.tool_name, self.input_schema_json, self.output_schema_json, self.ttl_ms },
                );
            }
            if (self.required_task) {
                if (self.era != .modern_2026_07_28) return .server_error;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"tasked\",\"inputSchema\":{{\"type\":\"object\"}},\"execution\":{{\"taskSupport\":\"required\"}}}}],\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                    .{ id, self.ttl_ms },
                );
            }
            break :blk switch (self.era) {
                .modern_2026_07_28 => try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"{s}\",\"inputSchema\":{s},\"outputSchema\":{s}}}],\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                    .{ id, self.tool_name, self.input_schema_json, self.output_schema_json, self.ttl_ms },
                ),
                .classic_2025_11_25, .classic_2025_06_18 => try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"{s}\",\"inputSchema\":{s},\"outputSchema\":{s}}}]}}}}",
                    .{ id, self.tool_name, self.input_schema_json, self.output_schema_json },
                ),
            };
        } else if (std.mem.indexOf(u8, encoded, "tools/call") != null) blk: {
            self.calls += 1;
            const padding = try allocator.alloc(u8, self.result_padding_bytes);
            defer allocator.free(padding);
            @memset(padding, 'm');
            break :blk switch (self.era) {
                .modern_2026_07_28 => try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":{{\"ok\":true,\"padding\":\"{s}\"}}}}}}",
                    .{ id, padding },
                ),
                .classic_2025_11_25, .classic_2025_06_18 => try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[],\"structuredContent\":{{\"ok\":true,\"padding\":\"{s}\"}}}}}}",
                    .{ id, padding },
                ),
            };
        } else return .server_error;
        return .{ .response = .{ .http_status = 0, .body = response } };
    }

    fn notify(_: *anyopaque, _: []const u8, _: u32, _: runtime.Cancellation) anyerror!void {}

    fn close(raw: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw));
        connection.owner.closes += 1;
        std.heap.c_allocator.destroy(connection);
    }

    fn requestId(encoded: []const u8) ?u64 {
        const marker = "\"id\":";
        const start = (std.mem.indexOf(u8, encoded, marker) orelse return null) + marker.len;
        var end = start;
        while (end < encoded.len and std.ascii.isDigit(encoded[end])) : (end += 1) {}
        return std.fmt.parseInt(u64, encoded[start..end], 10) catch null;
    }
};
