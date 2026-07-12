//! 最小 mock MCP server。读 stdin 的 JSON-RPC，按方法返回固定响应。
//! 用作 M5.5 的集成测试 fixture。
//!
//! 响应的方法：
//! - initialize → 返回 capabilities / serverInfo
//! - tools/list → 返回 1 个工具 "echo"（接受 message 参数）
//! - tools/call → 如果 name="echo"，返回 content [{type:"text",text:<message>}]

const std = @import("std");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    var chunk: [4096]u8 = undefined;
    outer: while (true) {
        // 按行读 stdin（阻塞）
        while (std.mem.indexOfScalar(u8, buf.items, '\n') == null) {
            const n = std.c.read(0, &chunk, chunk.len);
            if (n <= 0) break :outer;
            try buf.appendSlice(alloc, chunk[0..@as(usize, @intCast(n))]);
        }
        const nl = std.mem.indexOfScalar(u8, buf.items, '\n').?;
        const line = buf.items[0..nl];

        try handleLine(alloc, line);

        // 消费这行
        std.mem.copyForwards(u8, buf.items, buf.items[nl + 1 ..]);
        buf.items.len -= nl + 1;
    }
}

// elicitation 往返:tools/call name="elicit" → 挂起,发 elicitation/create;收 client 回复后据 action 应答。
var pending_elicit_id: ?u64 = null;

fn handleLine(alloc: std.mem.Allocator, line: []const u8) !void {
    // notifications 无 id 也不需回复
    if (std.mem.indexOf(u8, line, "\"method\":\"notifications/") != null) return;

    const method_opt = extractStringField(line, "method");
    if (method_opt == null) {
        // 无 method = client→server 响应(elicitation 回复)。据 action 完成挂起的 tools/call。
        if (pending_elicit_id) |eid| {
            const action = extractStringField(line, "action") orelse "decline";
            const payload = try std.fmt.allocPrint(alloc,
                \\{{"content":[{{"type":"text","text":"elicited:{s}"}}]}}
            , .{action});
            defer alloc.free(payload);
            try writeResponse(alloc, eid, payload);
            pending_elicit_id = null;
        }
        return;
    }
    const method = method_opt.?;
    const id = parseId(line) orelse return;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeResponse(alloc, id,
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"mock-mcp","version":"0.1.0"}}
        );
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try writeResponse(alloc, id,
            \\{"tools":[{"name":"echo","description":"echo back input","inputSchema":{"type":"object"}},{"name":"elicit","description":"asks user via elicitation","inputSchema":{"type":"object"}}]}
        );
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const tool = extractStringField(line, "name") orelse "";
        if (std.mem.eql(u8, tool, "elicit")) {
            // 挂起 tools/call,发 server→client elicitation/create;等 client 回复(下一行处理)。
            pending_elicit_id = id;
            // requestedSchema 故意含名为 "result"/"error" 的属性 + 嵌套 "id":任 → 触发 client 分类器的
            // 陷阱:全文子串扫会把本请求误当响应(死锁)。正确分类器按顶层 method 判 → 仍识别为请求。
            const req =
                \\{"jsonrpc":"2.0","id":9001,"method":"elicitation/create","params":{"message":"need input","requestedSchema":{"type":"object","properties":{"result":{"type":"string","default":"id"},"error":{"type":"string"}}}}}
            ;
            const wbuf = try std.fmt.allocPrint(alloc, "{s}\n", .{req});
            defer alloc.free(wbuf);
            _ = std.c.write(1, wbuf.ptr, wbuf.len);
            return;
        }
        const msg = extractNestedStringField(line, "message") orelse "<nothing>";
        const payload = try std.fmt.allocPrint(alloc,
            \\{{"content":[{{"type":"text","text":"{s}"}}]}}
        , .{msg});
        defer alloc.free(payload);
        try writeResponse(alloc, id, payload);
    } else {
        try writeError(alloc, id, -32601, "Method not found");
    }
}

fn writeResponse(alloc: std.mem.Allocator, id: u64, result_json: []const u8) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}\n", .{ id, result_json });
    defer alloc.free(resp);
    _ = std.c.write(1, resp.ptr, resp.len);
}

fn writeError(alloc: std.mem.Allocator, id: u64, code: i32, message: []const u8) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n", .{ id, code, message });
    defer alloc.free(resp);
    _ = std.c.write(1, resp.ptr, resp.len);
}

fn parseId(data: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, data, "\"id\":") orelse return null;
    var start = idx + 5;
    while (start < data.len and data[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, data[start..end], 10) catch null;
}

fn extractStringField(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    buf[3 + field.len] = '"';
    const pat = buf[0 .. 4 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    const s = idx + pat.len;
    var e = s;
    while (e < data.len) : (e += 1) {
        if (data[e] == '"' and data[e - 1] != '\\') break;
    }
    return data[s..e];
}

fn extractNestedStringField(data: []const u8, field: []const u8) ?[]const u8 {
    // 最后一次出现的 field 字段——arguments 内部
    var result: ?[]const u8 = null;
    var search_pos: usize = 0;
    while (search_pos < data.len) {
        const v = extractStringFieldFrom(data, search_pos, field) orelse break;
        result = v.value;
        search_pos = v.end;
    }
    return result;
}

const Found = struct { value: []const u8, end: usize };

fn extractStringFieldFrom(data: []const u8, from: usize, field: []const u8) ?Found {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    buf[3 + field.len] = '"';
    const pat = buf[0 .. 4 + field.len];
    const idx = std.mem.indexOfPos(u8, data, from, pat) orelse return null;
    const s = idx + pat.len;
    var e = s;
    while (e < data.len) : (e += 1) {
        if (data[e] == '"' and data[e - 1] != '\\') break;
    }
    return Found{ .value = data[s..e], .end = e + 1 };
}
