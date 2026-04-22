//! 把 MCP server 的 tools 注入到 DynRegistry。
//!
//! 命名空间：`<server_name>__<tool_name>`（双下划线分隔），避免与内建冲突。
//!
//! 每个 MCP tool 注册时：
//! - ctx_ptr 指向 McpToolBinding（含 *McpClient + original name）
//! - execute 函数从 ctx_ptr 恢复 client 调 callTool
//!
//! 注意：McpToolBinding 的生命周期 = McpSession 的生命周期（至少 process 级）。
//! McpSession.deinit 清理所有 binding。

const std = @import("std");
const McpClient = @import("client.zig").McpClient;
const protocol = @import("protocol.zig");
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const ToolContext = @import("../tools/context.zig").ToolContext;

/// 持有 MCP client + 它注入到 registry 的 tool bindings 的所有权。
pub const McpSession = struct {
    allocator: std.mem.Allocator,
    client: *McpClient,
    bindings: std.ArrayList(*McpToolBinding),

    pub fn init(allocator: std.mem.Allocator, client: *McpClient) McpSession {
        return .{ .allocator = allocator, .client = client, .bindings = .empty };
    }

    pub fn deinit(self: *McpSession) void {
        for (self.bindings.items) |b| {
            self.allocator.free(b.mcp_tool_name);
            self.allocator.destroy(b);
        }
        self.bindings.deinit(self.allocator);
    }

    /// 从 MCP server listTools → 注入到 DynRegistry。
    /// server_prefix 是命名空间前缀（如 "github"），最终 name 为 "github__search_issues"。
    pub fn registerTools(
        self: *McpSession,
        registry: *DynRegistry,
        server_prefix: []const u8,
    ) !void {
        const tools_json = try self.client.listTools();
        defer self.allocator.free(tools_json);

        // MCP tools/list result 结构：`{"tools":[{"name":"x","description":"...","inputSchema":{...}}, ...]}`
        const tools_arr = protocol.findObjectField(tools_json, "tools") orelse return error.MalformedMcpResponse;

        var pos: usize = 1; // 跳过开头 '['
        while (pos < tools_arr.len) {
            while (pos < tools_arr.len and (tools_arr[pos] == ' ' or tools_arr[pos] == ',')) : (pos += 1) {}
            if (pos >= tools_arr.len or tools_arr[pos] != '{') break;

            // 找本 tool object 的结束
            const obj_end = findObjectEnd(tools_arr, pos) orelse break;
            const obj = tools_arr[pos..obj_end];
            pos = obj_end;

            const name = extractStringField(obj, "name") orelse continue;
            const desc = extractStringField(obj, "description") orelse "";

            const binding = try self.allocator.create(McpToolBinding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{
                .client = self.client,
                .mcp_tool_name = try self.allocator.dupe(u8, name),
            };
            errdefer self.allocator.free(binding.mcp_tool_name);

            const full_name = try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ server_prefix, name });
            defer self.allocator.free(full_name);

            try registry.register(full_name, desc, &.{}, executeMcpTool, binding);
            try self.bindings.append(self.allocator, binding);
        }
    }
};

pub const McpToolBinding = struct {
    client: *McpClient,
    mcp_tool_name: []const u8, // owned
};

fn executeMcpTool(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror![]u8 {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    // args 应是 JSON object；直接透传
    _ = ctx; // abort 未在本版本传给 MCP 请求——future 扩展
    return try binding.client.callTool(binding.mcp_tool_name, args);
}

// 私有 helpers——和 protocol.zig 同逻辑但只处理 object
fn findObjectEnd(data: []const u8, start: usize) ?usize {
    if (start >= data.len or data[start] != '{') return null;
    var depth: i32 = 0;
    var in_str = false;
    var escaped = false;
    var i = start;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn extractStringField(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    buf[3 + field.len] = '"';
    const pattern = buf[0 .. 4 + field.len];
    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    const s = idx + pattern.len;
    var e = s;
    while (e < data.len) : (e += 1) {
        if (data[e] == '"' and data[e - 1] != '\\') break;
    }
    return data[s..e];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "findObjectEnd nested" {
    const data = "{\"a\":{\"b\":1}}";
    try testing.expect(findObjectEnd(data, 0).? == data.len);
}

test "findObjectEnd simple" {
    try testing.expect(findObjectEnd("{\"x\":1}", 0).? == 7);
}

test "extractStringField works" {
    try testing.expectEqualStrings("foo", extractStringField("{\"name\":\"foo\"}", "name").?);
}
