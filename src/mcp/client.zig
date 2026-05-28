//! MCP 高层客户端。
//!
//! 用途：代理 agent_loop 调用 MCP server 的 tools。
//! 生命周期：init → initialize → 反复 listTools / callTool → close。
//!
//! 本期简化：
//! - 同步请求/响应（不做并发 in-flight）—— 每次 send 后立即 recvLine，id 自增
//! - 无重试、无重连；server 崩溃返回 error.McpServerCrashed
//! - 只支持 stdio transport（future: sse/websocket）

const std = @import("std");
const protocol = @import("protocol.zig");
const StdioTransport = @import("transport_stdio.zig").StdioTransport;

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    transport: StdioTransport,
    next_id: u64 = 1,
    initialized: bool = false,

    pub fn connect(
        allocator: std.mem.Allocator,
        argv: []const ?[*:0]const u8,
    ) !McpClient {
        var t = try StdioTransport.spawn(allocator, argv);
        errdefer t.close();

        var client = McpClient{
            .allocator = allocator,
            .transport = t,
        };
        try client.initialize();
        return client;
    }

    pub fn close(self: *McpClient) void {
        self.transport.close();
    }

    fn initialize(self: *McpClient) !void {
        const params = try protocol.initializeParams(self.allocator);
        defer self.allocator.free(params);

        const resp = try self.request("initialize", params);
        defer self.allocator.free(resp);
        // 发 notifications/initialized 完成握手
        const notif = try protocol.serializeNotification(self.allocator, "notifications/initialized", "{}");
        defer self.allocator.free(notif);
        try self.transport.send(notif);

        self.initialized = true;
    }

    /// 发请求并返回 result_json（owned，caller free）。失败返 error.McpError。
    fn request(self: *McpClient, method: []const u8, params_json: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        const req = try protocol.serializeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(req);
        self.transport.send(req) catch return error.McpServerCrashed;

        const line = self.transport.recvLine() catch return error.McpServerCrashed;
        defer self.allocator.free(line);

        const resp = protocol.parseResponse(line) catch return error.McpMalformedResponse;
        if (!resp.isSuccess()) return error.McpError;
        if (resp.result_json) |r| return try self.allocator.dupe(u8, r);
        return try self.allocator.dupe(u8, "null");
    }

    /// 返回 tools 列表（owned JSON string，caller free）。
    pub fn listTools(self: *McpClient) ![]u8 {
        return try self.request("tools/list", protocol.EMPTY_PARAMS);
    }

    /// 调用某个 tool。arguments_json 必须是合法 JSON object。
    pub fn callTool(self: *McpClient, name: []const u8, arguments_json: []const u8) ![]u8 {
        const params = try protocol.callToolParams(self.allocator, name, arguments_json);
        defer self.allocator.free(params);
        return try self.request("tools/call", params);
    }

    /// 列出 server 暴露的 resources（resources/list）。返回原始 JSON-RPC result。
    pub fn listResources(self: *McpClient) ![]u8 {
        return try self.request("resources/list", protocol.EMPTY_PARAMS);
    }

    /// 读取一个 resource（resources/read）。uri 为 resource 标识。
    pub fn readResource(self: *McpClient, uri: []const u8) ![]u8 {
        const params = try protocol.readResourceParams(self.allocator, uri);
        defer self.allocator.free(params);
        return try self.request("resources/read", params);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "McpClient: connect to nonexistent command fails clean" {
    const argv = [_]?[*:0]const u8{ "/nonexistent/mcp-server", null };
    if (McpClient.connect(testing.allocator, argv[0..])) |_| {
        // 不应成功
        try testing.expect(false);
    } else |err| {
        try testing.expect(err == error.McpServerCrashed or err == error.McpMalformedResponse);
    }
}
