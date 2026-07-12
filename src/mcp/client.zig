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

/// elicitation 回调:server 在 tool 执行中发 `elicitation/create` 请求用户输入时被调。
/// 入参 = elicitation params JSON(含 message/requestedSchema);返回 = 用户回复的 content 对象 JSON
/// (owned by 传入 allocator)或 null=用户拒绝(client 回 {"action":"decline"})。
pub const ElicitHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, params_json: []const u8, alloc: std.mem.Allocator) ?[]u8,
};

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    transport: StdioTransport,
    next_id: u64 = 1,
    initialized: bool = false,
    /// server→client elicitation 回调(可选)。未设 → 一律 decline(协议仍正确闭合,server 不卡)。
    elicit: ?ElicitHandler = null,
    /// 中断信号(callTool 期由调用方设):挂死的 MCP server 可被 Ctrl+C 打断(经 transport poll)。
    abort: ?*const @import("../util/abort.zig").AbortSignal = null,

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
    /// **JSON-RPC 循环**:读到 server→client 请求(有 method+id,如 elicitation/create)就地处理并回复,
    /// 通知(有 method 无 id)忽略,继续读直到拿到本请求 id 的响应。否则 server 发 elicitation 会把
    /// 单次 recvLine 的响应假设打破(旧版直接解析失败)。
    fn request(self: *McpClient, method: []const u8, params_json: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        const req = try protocol.serializeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(req);
        self.transport.abort = self.abort; // 透传中断信号给阻塞读
        self.transport.send(req) catch return error.McpServerCrashed;

        while (true) {
            const line = self.transport.recvLine() catch return error.McpServerCrashed;
            defer self.allocator.free(line);

            // **按顶层字段分类**(不是全文子串扫):JSON-RPC 铁律——请求/通知有顶层 method,响应有顶层
            // result/error 且从不有 method。子串扫会被 params/requestedSchema 里名为 method/result/error
            // 的**嵌套属性**误导(Linus:elicitation 的 requestedSchema 含 "result" 属性 → 死锁)。
            // 用 std.json 解顶层一次(MCP 每行是完整 JSON,小)。
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
                // 不可解析 → 当无效响应(退化;正常 MCP 行都是完整 JSON)。
                return error.McpMalformedResponse;
            };
            defer parsed.deinit();
            if (parsed.value != .object) return error.McpMalformedResponse;
            const obj = parsed.value.object;

            // 顶层有 method → server→client 请求(带 id)或通知(无 id),不是本请求的响应。
            if (obj.get("method")) |mv| {
                if (mv == .string) {
                    if (obj.get("id")) |idv| {
                        if (idv == .integer and idv.integer >= 0) {
                            self.handleServerRequest(@intCast(idv.integer), mv.string, line);
                        }
                    } // 无 id/非整数 = 通知 → 忽略
                    continue;
                }
            }

            // 否则是响应:按顶层 id 匹配;result/error 从原行提取(顶层)。
            const resp_id: ?u64 = if (obj.get("id")) |idv| (if (idv == .integer and idv.integer >= 0) @intCast(idv.integer) else null) else null;
            if (resp_id != null and resp_id.? != id) continue; // 非本请求 → 丢弃继续读
            if (obj.get("error") != null) return error.McpError;
            const resp = protocol.parseResponse(line) catch return error.McpMalformedResponse;
            if (!resp.isSuccess()) return error.McpError;
            if (resp.result_json) |r| return try self.allocator.dupe(u8, r);
            return try self.allocator.dupe(u8, "null");
        }
    }

    /// 处理 server→client 请求并回复。elicitation/create → 回调(或 decline);其它 → method_not_found。
    fn handleServerRequest(self: *McpClient, server_id: u64, method: []const u8, line: []const u8) void {
        if (std.mem.eql(u8, method, "elicitation/create")) {
            // 取 params 喂回调;回调给合法 content → {"action":"accept","content":<content>};否则 decline。
            const params = protocol.findObjectField(line, "params") orelse "{}";
            var reply_buf: ?[]u8 = null;
            defer if (reply_buf) |rb| self.allocator.free(rb);
            if (self.elicit) |h| {
                if (h.handleFn(h.ctx, params, self.allocator)) |content| {
                    defer self.allocator.free(content);
                    // **校验 content 是合法 JSON**再 splice——回调可能喂模型脏输出,裸拼会破 JSON-RPC 帧
                    // (Linus #4 腐化向量)。非法 → 当 decline(不发损坏回复)。
                    if (isValidJson(self.allocator, content)) {
                        const result = std.fmt.allocPrint(self.allocator, "{{\"action\":\"accept\",\"content\":{s}}}", .{content}) catch return;
                        defer self.allocator.free(result); // 无论 serializeResult 成败都释放(Linus #5 泄漏修)
                        reply_buf = protocol.serializeResult(self.allocator, server_id, result) catch null;
                    }
                }
            }
            if (reply_buf == null) {
                // 无回调 / 拒绝 / content 非法 → decline(协议正确闭合,server 不卡)。
                reply_buf = protocol.serializeResult(self.allocator, server_id, "{\"action\":\"decline\"}") catch return;
            }
            self.transport.send(reply_buf.?) catch {};
            return;
        }
        // 其它 server→client 方法未实现 → method_not_found(回错误,不静默)。
        const err = protocol.serializeErrorResponse(self.allocator, server_id, @intFromEnum(protocol.ErrorCode.method_not_found), "not supported") catch return;
        defer self.allocator.free(err);
        self.transport.send(err) catch {};
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

/// content 是否可解析为合法 JSON 值(elicitation accept 前校验,防裸拼破帧)。
fn isValidJson(alloc: std.mem.Allocator, s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return false;
    var p = std.json.parseFromSlice(std.json.Value, alloc, t, .{}) catch return false;
    p.deinit();
    return true;
}

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
