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

pub const McpLate = struct {
    name: []const u8,
    change: Change,

    pub const Change = enum { added };
};

pub const McpLateProbe = struct {
    ctx: *anyopaque,
    list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) []const McpLate,

    pub fn late(self: McpLateProbe, arena: std.mem.Allocator) []const McpLate {
        return self.list(self.ctx, arena);
    }
};

pub fn writeUnavailable(w: *std.Io.Writer, servers: []const McpUnavailable) std.Io.Writer.Error!void {
    return writeNotice(w, servers, &.{});
}

pub fn writeNotice(w: *std.Io.Writer, unavailable: []const McpUnavailable, late: []const McpLate) std.Io.Writer.Error!void {
    var listed: usize = 0;
    var unlisted: usize = 0;
    for (unavailable) |server| {
        if (lateChange(late, server.name) != null) continue;
        if (listed == MAX_LISTED_UNAVAILABLE) {
            unlisted += 1;
            continue;
        }
        if (listed == 0) try w.writeAll(" MCP servers configured for this session that did not connect, so none of their tools exist here:");
        const detail = server.detail[0..@min(server.detail.len, MAX_DETAIL_BYTES)];
        try w.print(" '{s}' ({s});", .{ server.name, detail });
        listed += 1;
    }
    if (unlisted != 0) try w.print(" and {d} more;", .{unlisted});
    if (listed != 0) try w.writeAll(" One is connected automatically once a login is stored for it or its configuration changes; `/mcp reconnect <name>` retries one at once.");
    if (late.len != 0) {
        try w.writeAll(" MCP servers that changed after this session started, so their tools are not here yet:");
        for (late[0..@min(late.len, MAX_LISTED_UNAVAILABLE)]) |server| try w.print(" '{s}' ({s});", .{ server.name, switch (server.change) {
            .added => "added to the configuration",
        } });
        if (late.len > MAX_LISTED_UNAVAILABLE) try w.print(" and {d} more;", .{late.len - MAX_LISTED_UNAVAILABLE});
        try w.writeAll(" Each is connected before the next request (a system reminder then lists its tools), unless it is defined inside the working directories: then the user loads it with `/mcp reconnect <name>`.");
    }
    if (listed != 0 or late.len != 0)
        try w.writeAll(" Tell the user what each one needs; do not reach these servers another way (hand-written requests, tokens copied from other programs or credential stores).");
}

fn lateChange(late: []const McpLate, name: []const u8) ?McpLate.Change {
    for (late) |server| {
        if (std.mem.eql(u8, server.name, name)) return server.change;
    }
    return null;
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

test "servers added after the session started are named with what happens to them, and an unavailable one listed again is not repeated" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeNotice(&out.writer, &.{
        .{ .name = "fresh", .detail = "spawn failed" },
        .{ .name = "local", .detail = "spawn failed" },
    }, &.{
        .{ .name = "fresh", .change = .added },
    });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "'local' (spawn failed);") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "'fresh'"));
    try std.testing.expect(std.mem.indexOf(u8, text, "'fresh' (added to the configuration);") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "connected before the next request") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`/mcp reconnect <name>`") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Tell the user what each one needs"));

    var only_late: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer only_late.deinit();
    try writeNotice(&only_late.writer, &.{}, &.{.{ .name = "fresh", .change = .added }});
    try std.testing.expect(std.mem.indexOf(u8, only_late.written(), "did not connect") == null);
    try std.testing.expect(std.mem.indexOf(u8, only_late.written(), "'fresh' (added to the configuration);") != null);
}
