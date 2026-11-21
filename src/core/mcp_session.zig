//! McpSessionEntry:一个已连接的 MCP server(McpClient + McpSession 一一对应)。
//!
//! 从 app.zig 移出到中立 core 位置:agent_loop.Options / ToolContext / mcp_resources 工具
//! 都引用它(ListMcpResourcesTool/ReadMcpResourceTool 用),原先经 `@import("../app.zig")`
//! 造成 core→app 泄漏。这里只依赖 mcp/(库内),无 app 依赖。
const std = @import("std");
const McpClient = @import("../mcp/client.zig").McpClient;
const McpSession = @import("../mcp/registry_bridge.zig").McpSession;

pub const McpSessionEntry = struct {
    name: []u8,
    client: *McpClient,
    session: McpSession,
};

pub const McpUnavailable = struct {
    name: []const u8,
    detail: []const u8,
};

const MAX_LISTED_UNAVAILABLE: usize = 8;
const MAX_DETAIL_BYTES: usize = 300;

pub fn writeUnavailable(w: *std.Io.Writer, servers: []const McpUnavailable) std.Io.Writer.Error!void {
    if (servers.len == 0) return;
    try w.writeAll(" MCP servers configured for this session that did not connect, so none of their tools exist here:");
    for (servers[0..@min(servers.len, MAX_LISTED_UNAVAILABLE)]) |server| {
        const detail = server.detail[0..@min(server.detail.len, MAX_DETAIL_BYTES)];
        try w.print(" '{s}' ({s});", .{ server.name, detail });
    }
    if (servers.len > MAX_LISTED_UNAVAILABLE) try w.print(" and {d} more;", .{servers.len - MAX_LISTED_UNAVAILABLE});
    try w.writeAll(" a new session picks them up once fixed. Tell the user what each one needs; do not reach these servers another way (hand-written requests, tokens copied from other programs or credential stores).");
}

test "unavailable servers are named with their cause and what the user should do" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeUnavailable(&out.writer, &.{});
    try std.testing.expectEqualStrings("", out.written());
    try writeUnavailable(&out.writer, &.{
        .{ .name = "suno", .detail = "the server requires authorization (401/403); run `metacodes mcp login suno`" },
        .{ .name = "local", .detail = "spawn failed" },
    });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "'suno' (the server requires authorization (401/403); run `metacodes mcp login suno`);") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "'local' (spawn failed);") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tell the user what each one needs") != null);
}

test "a long list of unavailable servers is bounded" {
    var servers: [MAX_LISTED_UNAVAILABLE + 3]McpUnavailable = undefined;
    for (&servers) |*server| server.* = .{ .name = "s", .detail = "x" ** (MAX_DETAIL_BYTES + 50) };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeUnavailable(&out.writer, &servers);
    const text = out.written();
    try std.testing.expectEqual(MAX_LISTED_UNAVAILABLE, std.mem.count(u8, text, "'s' ("));
    try std.testing.expect(std.mem.indexOf(u8, text, "x" ** (MAX_DETAIL_BYTES + 1)) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "and 3 more;") != null);
}
