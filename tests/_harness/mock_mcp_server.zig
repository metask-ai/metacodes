//! 最小 mock MCP server。读 stdin 的 JSON-RPC，按方法返回固定响应。
//! 用作 M5.5 的集成测试 fixture。
//!
//! 响应的方法：
//! - initialize → 返回 capabilities / serverInfo
//! - tools/list → 返回 1 个工具 "echo"（接受 message 参数）
//! - tools/call → 如果 name="echo"，返回 content [{type:"text",text:<message>}]
//!
//! 模式(argv 旗标,协议双时代 / 连接行为测试用):
//! - `--modern`:2026-07-28 server。回 `server/discover`,拒 `initialize`(-32601),每个请求必须带
//!   `_meta` 协议版本(否则 -32602);结果带 `resultType`;工具 "mrtr" 先回 input_required。
//! - `--version <v>`:Classic initialize 回该版本(默认 2024-11-05)。
//! - `--paginate`:tools/list 第一页 nextCursor 为空串,带 cursor 的请求回第二页。
//! - `--ping`:回 tools/list 前先发 server→client `ping`,收到回复才给结果。
//! - `--die-on-discover`:收到 `server/discover` 立即退出(Rust SDK 一类 server 的行为)。
//! - `--silent-discover`:对 `server/discover` 不回复。
//! 工具 "env":回 arguments.name 指定环境变量的值;"cwd":回工作目录;"hang":永不回复,
//! 直到收到 notifications/cancelled;"cancelled":回最近一次被取消的请求 id。

const std = @import("std");
const pfs = @import("platform").fs;

var modern = false;
var paginate = false;
var ping_before_list = false;
var die_on_discover = false;
var silent_discover = false;
var classic_version: []const u8 = "2024-11-05";
var pending_list_id: ?u64 = null;
var hang_id: ?u64 = null;
var last_cancelled: ?u64 = null;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    var args = std.process.Args.iterateAllocator(init.minimal.args, alloc) catch std.process.exit(2);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--modern")) modern = true;
        if (std.mem.eql(u8, arg, "--paginate")) paginate = true;
        if (std.mem.eql(u8, arg, "--ping")) ping_before_list = true;
        if (std.mem.eql(u8, arg, "--die-on-discover")) die_on_discover = true;
        if (std.mem.eql(u8, arg, "--silent-discover")) silent_discover = true;
        if (std.mem.eql(u8, arg, "--version")) classic_version = try alloc.dupe(u8, args.next() orelse "2024-11-05");
    }
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    var chunk: [4096]u8 = undefined;
    outer: while (true) {
        // 按行读 stdin（阻塞）
        while (std.mem.indexOfScalar(u8, buf.items, '\n') == null) {
            const n = pfs.read(0, &chunk);
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
    if (std.mem.indexOf(u8, line, "\"method\":\"notifications/") != null) {
        if (std.mem.indexOf(u8, line, "\"method\":\"notifications/cancelled\"") != null) {
            last_cancelled = parseUintAfter(line, "\"requestId\":");
            if (hang_id != null and last_cancelled != null and hang_id.? == last_cancelled.?) hang_id = null;
        }
        return;
    }

    const method_opt = extractStringField(line, "method");
    if (method_opt == null) {
        // The client's answer to our ping: now finish the pending tools/list.
        if (pending_list_id) |list_id| {
            if (parseId(line) == 4242) {
                pending_list_id = null;
                try writeToolsList(alloc, list_id, null);
                return;
            }
        }
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

    if (std.mem.eql(u8, method, "server/discover")) {
        if (die_on_discover) std.process.exit(0);
        if (silent_discover) return;
        if (!modern) {
            try writeError(alloc, id, -32601, "Method not found");
            return;
        }
        try writeResponse(alloc, id,
            \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{}},"ttlMs":0,"cacheScope":"private"}
        );
        return;
    }
    if (modern) {
        if (std.mem.eql(u8, method, "initialize")) {
            try writeError(alloc, id, -32601, "Method not found");
            return;
        }
        if (std.mem.indexOf(u8, line, "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"") == null) {
            try writeError(alloc, id, -32602, "missing _meta protocolVersion");
            return;
        }
    }

    if (std.mem.eql(u8, method, "initialize")) {
        const result = try std.fmt.allocPrint(alloc,
            \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"mock-mcp","version":"0.1.0"}}}}
        , .{classic_version});
        defer alloc.free(result);
        try writeResponse(alloc, id, result);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        if (ping_before_list and !modern) {
            pending_list_id = id;
            _ = pfs.write(1, "{\"jsonrpc\":\"2.0\",\"id\":4242,\"method\":\"ping\"}\n");
            return;
        }
        try writeToolsList(alloc, id, extractStringField(line, "cursor"));
    } else if (std.mem.eql(u8, method, "resources/list")) {
        try writeResponse(alloc, id,
            \\{"resources":[{"uri":"mock://large","name":"large fixture","mimeType":"text/plain"}]}
        );
    } else if (std.mem.eql(u8, method, "resources/read")) {
        const uri = extractStringField(line, "uri") orelse "";
        const sized_prefix = "mock://sized/";
        if (std.mem.startsWith(u8, uri, sized_prefix)) {
            const payload_bytes = std.fmt.parseInt(usize, uri[sized_prefix.len..], 10) catch {
                try writeError(alloc, id, -32602, "Invalid sized resource URI");
                return;
            };
            var header_buffer: [256]u8 = undefined;
            const header = try std.fmt.bufPrint(
                &header_buffer,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":[{{\"uri\":\"{s}\",\"mimeType\":\"text/plain\",\"text\":\"",
                .{ id, uri },
            );
            try writeStdoutAll(header);
            var sized_block: [4096]u8 = undefined;
            @memset(&sized_block, 's');
            var sized_remaining = payload_bytes;
            while (sized_remaining != 0) {
                const count = @min(sized_remaining, sized_block.len);
                try writeStdoutAll(sized_block[0..count]);
                sized_remaining -= count;
            }
            try writeStdoutAll("\"}]}}\n");
            return;
        }
        var header_buffer: [192]u8 = undefined;
        const header = try std.fmt.bufPrint(
            &header_buffer,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":[{{\"uri\":\"mock://large\",\"mimeType\":\"text/plain\",\"text\":\"",
            .{id},
        );
        try writeStdoutAll(header);
        var block: [64 * 1024]u8 = undefined;
        @memset(&block, 'r');
        var remaining: usize = 17 * 1024 * 1024 + 29;
        while (remaining != 0) {
            const count = @min(remaining, block.len);
            try writeStdoutAll(block[0..count]);
            remaining -= count;
        }
        try writeStdoutAll("RESOURCE_TAIL\"}]}}\n");
        return;
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const tool = toolName(line);
        if (std.mem.eql(u8, tool, "hang")) {
            hang_id = id;
            return;
        }
        if (std.mem.eql(u8, tool, "cancelled")) {
            const payload = try std.fmt.allocPrint(alloc,
                \\{{"content":[{{"type":"text","text":"cancelled:{d}"}}]}}
            , .{last_cancelled orelse 0});
            defer alloc.free(payload);
            try writeResponse(alloc, id, payload);
            return;
        }
        if (std.mem.eql(u8, tool, "env")) {
            const name = extractNestedStringField(line, "name") orelse "";
            var name_buffer: [256]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buffer, "{s}", .{name}) catch "";
            const value = if (std.c.getenv(name_z.ptr)) |raw| std.mem.span(raw) else "<unset>";
            const payload = try std.fmt.allocPrint(alloc,
                \\{{"content":[{{"type":"text","text":"env:{s}={s}"}}]}}
            , .{ name, value });
            defer alloc.free(payload);
            try writeResponse(alloc, id, payload);
            return;
        }
        if (std.mem.eql(u8, tool, "cwd")) {
            var cwd_buffer: [4096]u8 = undefined;
            const cwd = if (std.c.getcwd(&cwd_buffer, cwd_buffer.len)) |raw| std.mem.span(@as([*:0]const u8, @ptrCast(raw))) else "?";
            const payload = try std.fmt.allocPrint(alloc,
                \\{{"content":[{{"type":"text","text":"cwd:{s}"}}]}}
            , .{cwd});
            defer alloc.free(payload);
            try writeResponse(alloc, id, payload);
            return;
        }
        if (modern and std.mem.eql(u8, tool, "mrtr")) {
            // Round 1: ask for input. Round 2 (with inputResponses and the
            // echoed requestState): answer with what the client sent.
            if (std.mem.indexOf(u8, line, "\"inputResponses\"") == null) {
                try writeResponse(alloc, id,
                    \\{"resultType":"input_required","inputRequests":{"login":{"method":"elicitation/create","params":{"message":"who are you","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}},"requestState":"opaque-state-1"}
                );
                return;
            }
            const action = extractStringField(line, "action") orelse "none";
            const state_ok = std.mem.indexOf(u8, line, "\"requestState\":\"opaque-state-1\"") != null;
            const payload = try std.fmt.allocPrint(alloc,
                \\{{"resultType":"complete","content":[{{"type":"text","text":"mrtr:{s}:state={}"}}]}}
            , .{ action, state_ok });
            defer alloc.free(payload);
            try writeResponse(alloc, id, payload);
            return;
        }
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
            _ = pfs.write(1, wbuf);
            return;
        }
        if (std.mem.eql(u8, tool, "slow_echo")) {
            @import("platform").sync.sleepMs(100);
        }
        if (std.mem.eql(u8, tool, "large")) {
            var header_buffer: [160]u8 = undefined;
            const header = try std.fmt.bufPrint(
                &header_buffer,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"",
                .{id},
            );
            try writeStdoutAll(header);
            var block: [64 * 1024]u8 = undefined;
            @memset(&block, 'm');
            var remaining: usize = 17 * 1024 * 1024 + 23;
            while (remaining != 0) {
                const count = @min(remaining, block.len);
                try writeStdoutAll(block[0..count]);
                remaining -= count;
            }
            try writeStdoutAll("\"}]}}\n");
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

fn writeToolsList(alloc: std.mem.Allocator, id: u64, cursor: ?[]const u8) !void {
    const result_type = if (modern) "\"resultType\":\"complete\"," else "";
    if (paginate and cursor == null) {
        // An empty-string cursor is a real cursor (pagination.mdx): page two follows.
        const page = try std.fmt.allocPrint(alloc,
            \\{{{s}"tools":[{{"name":"echo","description":"echo back input","inputSchema":{{"type":"object","properties":{{"message":{{"type":"string"}}}},"required":["message"]}}}}],"nextCursor":""}}
        , .{result_type});
        defer alloc.free(page);
        try writeResponse(alloc, id, page);
        return;
    }
    if (paginate) {
        const page = try std.fmt.allocPrint(alloc,
            \\{{{s}"tools":[{{"name":"page.two","description":"second page","inputSchema":{{"type":"object"}}}}]}}
        , .{result_type});
        defer alloc.free(page);
        try writeResponse(alloc, id, page);
        return;
    }
    const full = try std.fmt.allocPrint(alloc,
        \\{{{s}"tools":[{{"name":"echo","description":"echo back input","inputSchema":{{"type":"object","properties":{{"message":{{"type":"string"}}}},"required":["message"]}}}},{{"name":"slow_echo","description":"delayed echo for concurrency tests","inputSchema":{{"type":"object","properties":{{"message":{{"type":"string"}}}},"required":["message"]}}}},{{"name":"elicit","description":"asks user via elicitation","inputSchema":{{"type":"object"}}}},{{"name":"large","description":"stream a 17MiB result","inputSchema":{{"type":"object"}}}},{{"name":"env","description":"report an environment variable","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string"}}}}}}}},{{"name":"cwd","description":"report the working directory","inputSchema":{{"type":"object"}}}},{{"name":"hang","description":"never answers","inputSchema":{{"type":"object"}}}},{{"name":"cancelled","description":"last cancelled request id","inputSchema":{{"type":"object"}}}},{{"name":"mrtr","description":"needs input (2026-07-28)","inputSchema":{{"type":"object"}}}}]}}
    , .{result_type});
    defer alloc.free(full);
    try writeResponse(alloc, id, full);
}

/// `params.name` of a tools/call: the last `"name"` before `"arguments"`
/// (a 2026-07-28 request's `_meta.clientInfo` also has a `name`).
fn toolName(line: []const u8) []const u8 {
    const arguments = std.mem.indexOf(u8, line, "\"arguments\"") orelse line.len;
    var result: []const u8 = "";
    var cursor: usize = 0;
    while (extractStringFieldFrom(line[0..arguments], cursor, "name")) |found| {
        result = found.value;
        cursor = found.end;
    }
    return result;
}

fn parseUintAfter(data: []const u8, key: []const u8) ?u64 {
    const index = std.mem.indexOf(u8, data, key) orelse return null;
    var start = index + key.len;
    while (start < data.len and data[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, data[start..end], 10) catch null;
}

fn writeStdoutAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset != bytes.len) {
        const count = pfs.write(1, bytes[offset..]);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}

fn writeResponse(alloc: std.mem.Allocator, id: u64, result_json: []const u8) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}\n", .{ id, result_json });
    defer alloc.free(resp);
    _ = pfs.write(1, resp);
}

fn writeError(alloc: std.mem.Allocator, id: u64, code: i32, message: []const u8) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n", .{ id, code, message });
    defer alloc.free(resp);
    _ = pfs.write(1, resp);
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
    const pat = buf[0 .. 2 + field.len];
    const idx = std.mem.indexOfPos(u8, data, from, pat) orelse return null;
    var s = idx + pat.len;
    while (s < data.len and (data[s] == ' ' or data[s] == '\t')) : (s += 1) {}
    if (s >= data.len or data[s] != ':') return null;
    s += 1;
    while (s < data.len and (data[s] == ' ' or data[s] == '\t')) : (s += 1) {}
    if (s >= data.len or data[s] != '"') return null;
    s += 1;
    var e = s;
    while (e < data.len) : (e += 1) {
        if (data[e] == '"' and data[e - 1] != '\\') break;
    }
    return Found{ .value = data[s..e], .end = e + 1 };
}
