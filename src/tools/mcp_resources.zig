//! 统一的 MCP resources 工具:跨所有连接的 MCP server fan-out。
//!
//! Claude Code 官方有 ListMcpResourcesTool / ReadMcpResourceTool 两个统一工具
//! (与 per-server `<server>__list_resources` 区别:用户不必记 namespace)。
//!
//! ListMcpResourcesTool(server?):
//!   - 无 server:聚合所有 session 的 resources
//!   - 有 server:只列那个 server 的
//!   返回:[{server, uri, name, description, mimeType}, ...]
//!
//! ReadMcpResourceTool(uri, server?):
//!   - uri 必填
//!   - server 指定时只查那个;否则尝试所有,第一个匹配的胜
//!   返回:被读的 resource 内容

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;
const ToolResultBody = @import("context.zig").ToolResultBody;
const artifact_store = @import("../core/tool_result_artifact.zig");
const result_spool = @import("result_spool.zig");

pub fn listExecuteBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    if (ctx.artifact_root.len == 0)
        return ToolResultBody.initInline(try listExecute(ctx, args));
    const allocator = ctx.allocator;
    const sessions = ctx.mcp_sessions orelse return error.NoMcpSessions;
    const server_filter = common.extractJsonArg(args, "server");
    var capture = try artifact_store.Capture.begin(
        allocator,
        ctx.artifact_root,
        artifact_store.MAX_ARTIFACT_BYTES,
    );
    defer capture.deinit();
    var output = result_spool.CaptureWriter.init(&capture);
    try output.writer.writeAll("{\"resources\":[");
    var first = true;
    for (sessions.*) |*entry| {
        if (server_filter) |filter| if (!std.mem.eql(u8, filter, entry.name)) continue;
        var body = entry.client.listResourcesBodyAbortable(ctx.artifact_root, ctx.result_budget, ctx.abort) catch |err| {
            @import("../util/log.zig").warn("mcp", "list_resources failed for {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        defer body.deinit(allocator);
        switch (body) {
            .@"inline" => |inline_result| {
                const array = findArrayField(inline_result.bytes, "resources") orelse continue;
                var iter = jsonArrayIter(array);
                while (iter.next()) |object| {
                    if (!first) try output.writer.writeByte(',');
                    first = false;
                    try output.writer.writeAll("{\"server\":");
                    try std.json.Stringify.encodeJsonString(entry.name, .{}, &output.writer);
                    if (object.len > 2) {
                        try output.writer.writeByte(',');
                        try output.writer.writeAll(object[1 .. object.len - 1]);
                    }
                    try output.writer.writeByte('}');
                }
            },
            .artifact => {
                var rendered = try body.render(allocator);
                defer rendered.deinit(allocator);
                if (!first) try output.writer.writeByte(',');
                first = false;
                try output.writer.writeAll("{\"server\":");
                try std.json.Stringify.encodeJsonString(entry.name, .{}, &output.writer);
                try output.writer.writeAll(",\"resource_list_artifact\":");
                try output.writer.writeAll(rendered.bytes);
                try output.writer.writeByte('}');
            },
            .structured_error => continue,
        }
    }
    try output.writer.writeAll("]}");
    try output.check();
    try capture.seal();
    return result_spool.finishCaptureAsBody(
        allocator,
        ctx.artifact_root,
        &capture,
        .json,
        true,
        ctx.result_budget,
    );
}

pub fn readExecuteBody(ctx: *const ToolContext, args: []const u8) anyerror!ToolResultBody {
    if (ctx.artifact_root.len == 0)
        return ToolResultBody.initInline(try readExecute(ctx, args));
    const allocator = ctx.allocator;
    const sessions = ctx.mcp_sessions orelse return error.NoMcpSessions;
    const uri = common.extractJsonArg(args, "uri") orelse return error.MissingUri;
    if (uri.len == 0) return error.EmptyUri;
    const server_hint = common.extractJsonArg(args, "server");

    if (server_hint) |hint| {
        for (sessions.*) |*entry| if (std.mem.eql(u8, hint, entry.name)) {
            return entry.client.readResourceBodyAbortable(uri, ctx.artifact_root, ctx.result_budget, ctx.abort) catch |err|
                ToolResultBody.initInline(try std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"read_failed\",\"server\":\"{s}\",\"message\":\"{s}\"}}",
                    .{ hint, @errorName(err) },
                ));
        };
        return ToolResultBody.initInline(try std.fmt.allocPrint(
            allocator,
            "{{\"error\":\"server_not_found\",\"server\":\"{s}\"}}",
            .{hint},
        ));
    }

    var last_error: ?[]const u8 = null;
    for (sessions.*) |*entry| {
        var body = entry.client.readResourceBodyAbortable(uri, ctx.artifact_root, ctx.result_budget, ctx.abort) catch |err| {
            last_error = @errorName(err);
            continue;
        };
        if (body == .structured_error) {
            body.deinit(allocator);
            last_error = "remote_error";
            continue;
        }
        return body;
    }
    return ToolResultBody.initInline(try std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"resource_not_found\",\"uri\":\"{s}\",\"last_err\":\"{s}\"}}",
        .{ uri, last_error orelse "none" },
    ));
}

pub fn listExecute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const sessions = ctx.mcp_sessions orelse return error.NoMcpSessions;
    const server_filter = common.extractJsonArg(args, "server");

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("{\"resources\":[");

    var first = true;
    for (sessions.*) |*entry| {
        if (server_filter) |sf| {
            if (!std.mem.eql(u8, sf, entry.name)) continue;
        }
        const list_json = entry.client.listResources() catch |err| {
            @import("../util/log.zig").warn("mcp", "list_resources failed for {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        defer a.free(list_json);

        // list_json 形如 {"resources":[{...},{...}]}
        // 简单提取 resources 数组里的对象,加 server 字段后追加
        const arr = findArrayField(list_json, "resources") orelse continue;
        var iter = jsonArrayIter(arr);
        while (iter.next()) |obj| {
            if (!first) try out.writer.writeByte(',');
            first = false;
            // 把 server 字段注入对象前
            try out.writer.writeAll("{\"server\":");
            try std.json.Stringify.encodeJsonString(entry.name, .{}, &out.writer);
            // 再把原对象内容(去掉外层 {} 的)拼接
            if (obj.len > 2) {
                try out.writer.writeAll(",");
                try out.writer.writeAll(obj[1 .. obj.len - 1]);
            }
            try out.writer.writeByte('}');
        }
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

pub fn readExecute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const sessions = ctx.mcp_sessions orelse return error.NoMcpSessions;
    const uri = common.extractJsonArg(args, "uri") orelse return error.MissingUri;
    if (uri.len == 0) return error.EmptyUri;
    const server_hint = common.extractJsonArg(args, "server");

    // 优先查 hint 的 server
    if (server_hint) |sh| {
        for (sessions.*) |*entry| {
            if (std.mem.eql(u8, sh, entry.name)) {
                return entry.client.readResource(uri) catch |err| {
                    return try std.fmt.allocPrint(a, "{{\"error\":\"read_failed\",\"server\":\"{s}\",\"message\":\"{s}\"}}", .{ sh, @errorName(err) });
                };
            }
        }
        return try std.fmt.allocPrint(a, "{{\"error\":\"server_not_found\",\"server\":\"{s}\"}}", .{sh});
    }

    // 无 hint:依次尝试所有 server,第一个成功的
    var last_err: ?[]const u8 = null;
    for (sessions.*) |*entry| {
        const res = entry.client.readResource(uri) catch |err| {
            last_err = @errorName(err);
            continue;
        };
        return res;
    }
    return try std.fmt.allocPrint(a, "{{\"error\":\"resource_not_found\",\"uri\":\"{s}\",\"last_err\":\"{s}\"}}", .{ uri, last_err orelse "none" });
}

// ============================================================================
// 小工具:JSON 数组+字段解析(简化,够用)
// ============================================================================

fn findArrayField(data: []const u8, field: []const u8) ?[]const u8 {
    var pat_buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    var p = idx + pat.len;
    while (p < data.len and (data[p] == ' ' or data[p] == '\t')) : (p += 1) {}
    if (p >= data.len or data[p] != '[') return null;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i = p;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (c == '\\') {
            esc = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return data[p .. i + 1];
        }
    }
    return null;
}

const ArrayIter = struct {
    data: []const u8,
    pos: usize,

    pub fn next(self: *ArrayIter) ?[]const u8 {
        while (self.pos < self.data.len and (self.data[self.pos] == ' ' or self.data[self.pos] == ',' or self.data[self.pos] == '[' or self.data[self.pos] == '\n' or self.data[self.pos] == '\t')) {
            self.pos += 1;
        }
        if (self.pos >= self.data.len or self.data[self.pos] == ']') return null;
        if (self.data[self.pos] != '{') return null;
        const start = self.pos;
        var depth: i32 = 0;
        var in_str = false;
        var esc = false;
        while (self.pos < self.data.len) : (self.pos += 1) {
            const c = self.data[self.pos];
            if (esc) {
                esc = false;
                continue;
            }
            if (c == '\\') {
                esc = true;
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
                if (depth == 0) {
                    self.pos += 1;
                    return self.data[start..self.pos];
                }
            }
        }
        return null;
    }
};

fn jsonArrayIter(arr: []const u8) ArrayIter {
    return .{ .data = arr, .pos = 0 };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "findArrayField: nested" {
    const data = "{\"resources\":[{\"uri\":\"file://a\"},{\"uri\":\"file://b\"}]}";
    const arr = findArrayField(data, "resources").?;
    try testing.expect(std.mem.indexOf(u8, arr, "file://a") != null);
    try testing.expect(std.mem.indexOf(u8, arr, "file://b") != null);
    try testing.expect(arr[0] == '[' and arr[arr.len - 1] == ']');
}

test "ArrayIter: iterates objects" {
    const arr = "[{\"a\":1},{\"b\":2}]";
    var it = jsonArrayIter(arr);
    const o1 = it.next().?;
    try testing.expect(std.mem.indexOf(u8, o1, "\"a\":1") != null);
    const o2 = it.next().?;
    try testing.expect(std.mem.indexOf(u8, o2, "\"b\":2") != null);
    try testing.expect(it.next() == null);
}

test "list: missing mcp_sessions errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.NoMcpSessions, listExecute(&ctx, "{}"));
}

test "read: missing uri errors" {
    var sessions: []@import("../core/mcp_session.zig").McpSessionEntry = &.{};
    var ctx = ToolContext.simple(testing.allocator);
    ctx.mcp_sessions = &sessions;
    try testing.expectError(error.MissingUri, readExecute(&ctx, "{}"));
}
