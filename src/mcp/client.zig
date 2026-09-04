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
const sync = @import("platform").sync;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const artifact_store = @import("../core/tool_result_artifact.zig");
const ToolResultBody = @import("../core/tool_result.zig").ToolResultBody;
const tool_error = @import("../core/tool_error.zig");
const ToolError = tool_error.ToolError;
const result_budget = @import("../core/result_budget.zig");
const result_stream = @import("../agentcore/mcp_result_stream.zig");

/// elicitation 回调:server 在 tool 执行中发 `elicitation/create` 请求用户输入时被调。
/// 入参 = elicitation params JSON(含 message/requestedSchema);返回 = 用户回复的 content 对象 JSON
/// (owned by 传入 allocator)或 null=用户拒绝(client 回 {"action":"decline"})。
pub const ElicitHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, params_json: []const u8, alloc: std.mem.Allocator) ?[]u8,
};

/// Frames up to this size are materialized before they are classified: a
/// server→client control frame (elicitation) has to be answered synchronously,
/// and only a parsed frame can be told apart from a response. It is also the
/// ceiling of what this client has ever held inline, which is why the
/// failed-publication fallback retains results up to it rather than only up to
/// `result_budget.PER_RESULT_MAX_BYTES`: the bytes are already in memory.
pub const CONTROL_FRAME_MATERIALIZE_BYTES: usize = 1024 * 1024;

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    transport: StdioTransport,
    next_id: u64 = 1,
    initialized: bool = false,
    /// stdio transport is one ordered JSON-RPC stream. Parallel agent tools
    /// may call the same server concurrently, but only one request may own the
    /// send/recv loop at a time or responses can be consumed by the wrong call.
    request_mutex: sync.Mutex = .{},
    /// server→client elicitation 回调(可选)。未设 → 一律 decline(协议仍正确闭合,server 不卡)。
    elicit: ?ElicitHandler = null,

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

        // request_mutex has not been used yet: McpClient is still a local value
        // that will be moved into caller storage on return. Never lock a pthread
        // mutex before that move.
        const resp = try self.requestUnlocked("initialize", params, null);
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
    fn request(self: *McpClient, method: []const u8, params_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        return self.requestUnlocked(method, params_json, abort);
    }

    fn requestUnlocked(self: *McpClient, method: []const u8, params_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;

        const req = try protocol.serializeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(req);
        self.transport.abort = abort;
        defer self.transport.abort = null;
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

    /// Typed byte-zero request path used by model-visible MCP tools/resources.
    /// Frames up to `CONTROL_FRAME_MATERIALIZE_BYTES` are materialized so
    /// server→client control frames can be classified and elicitation stays
    /// synchronous. A successful result's inline-or-publish disposition follows
    /// `budget.per_result_bytes`; if publication fails, the bytes already in
    /// memory are retained inline up to that same limit, which is what this
    /// path did before the threshold change.
    fn requestBody(
        self: *McpClient,
        method: []const u8,
        params_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        require_content: bool,
    ) !ToolResultBody {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        return self.requestBodyUnlocked(
            method,
            params_json,
            artifact_root,
            budget,
            abort,
            require_content,
        );
    }

    fn requestBodyUnlocked(
        self: *McpClient,
        method: []const u8,
        params_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        require_content: bool,
    ) !ToolResultBody {
        if (artifact_root.len == 0) return error.ArtifactRootUnavailable;
        const id = self.next_id;
        self.next_id += 1;
        const req = try protocol.serializeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(req);
        self.transport.abort = abort;
        defer self.transport.abort = null;
        self.transport.send(req) catch return error.McpServerCrashed;

        while (true) {
            var capture = try artifact_store.Capture.begin(
                self.allocator,
                artifact_root,
                result_stream.MAX_RESPONSE_BYTES,
            );
            defer capture.deinit();
            self.transport.recvLineCapture(&capture) catch return error.McpServerCrashed;
            try capture.seal();

            // Server→client requests are intentionally bounded control-plane
            // frames. Materialize only this small class so elicitation keeps
            // its existing synchronous semantics.
            if (capture.bytes <= CONTROL_FRAME_MATERIALIZE_BYTES) {
                const line = try capture.readRangeAlloc(
                    self.allocator,
                    0,
                    @intCast(capture.bytes),
                );
                defer self.allocator.free(line);
                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{
                    .duplicate_field_behavior = .@"error",
                }) catch return error.McpMalformedResponse;
                defer parsed.deinit();
                if (parsed.value != .object) return error.McpMalformedResponse;
                const obj = parsed.value.object;
                if (obj.get("method")) |method_value| {
                    if (method_value == .string) {
                        if (obj.get("id")) |id_value| {
                            if (id_value == .integer and id_value.integer >= 0)
                                self.handleServerRequest(
                                    @intCast(id_value.integer),
                                    method_value.string,
                                    line,
                                );
                        }
                        continue;
                    }
                }
                const response_id: ?u64 = if (obj.get("id")) |id_value|
                    (if (id_value == .integer and id_value.integer >= 0)
                        @intCast(id_value.integer)
                    else
                        null)
                else
                    null;
                if (response_id != null and response_id.? != id) continue;
                if (obj.get("error") != null)
                    return try self.structuredMcpError(line, .other, .user_error);
                const response = protocol.parseResponse(line) catch
                    return error.McpMalformedResponse;
                if (!response.isSuccess())
                    return try self.structuredMcpError(line, .other, .user_error);
                const result = response.result_json orelse "null";
                if (result.len <= budget.per_result_bytes)
                    return ToolResultBody.initInline(try self.allocator.dupe(u8, result));
                return sealJsonResult(self.allocator, artifact_root, result) catch |err| {
                    // Keep a complete bounded result renderable when CAS publication fails.
                    if (!result_budget.retainInlineAfterFailedPublish(
                        err,
                        result.len,
                        true,
                        CONTROL_FRAME_MATERIALIZE_BYTES,
                    )) return err;
                    return ToolResultBody.initInline(try self.allocator.dupe(u8, result));
                };
            }

            const projected = try result_stream.project(
                self.allocator,
                &capture,
                artifact_root,
                id,
                .classic_2025_11_25,
                .{},
                budget,
                false,
                require_content,
            );
            switch (projected) {
                .result => |body| return body,
                .diagnostic => |diagnostic| {
                    if (diagnostic.code == .response_id_mismatch) continue;
                    if (diagnostic.code == .resource_limit)
                        return try self.structuredMcpError(
                            @tagName(diagnostic.code),
                            .io_error,
                            .system_error,
                        );
                    return try self.structuredMcpError(
                        @tagName(diagnostic.code),
                        .other,
                        .user_error,
                    );
                },
            }
        }
    }

    fn structuredMcpError(
        self: *McpClient,
        detail: []const u8,
        code: tool_error.Code,
        category: tool_error.Category,
    ) !ToolResultBody {
        const bounded = detail[0..@min(detail.len, 64 * 1024)];
        const owned = try self.allocator.dupe(u8, bounded);
        const structured_error = ToolError.init(code, category, owned, true);
        defer structured_error.deinit(self.allocator);
        const encoded = try structured_error.toJson(self.allocator);
        defer self.allocator.free(encoded);
        return ToolResultBody.initStructuredError(self.allocator, encoded);
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
        return try self.request("tools/list", protocol.EMPTY_PARAMS, null);
    }

    /// 调用某个 tool。arguments_json 必须是合法 JSON object。
    pub fn callTool(self: *McpClient, name: []const u8, arguments_json: []const u8) ![]u8 {
        return self.callToolAbortable(name, arguments_json, null);
    }

    pub fn callToolAbortable(self: *McpClient, name: []const u8, arguments_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        const params = try protocol.callToolParams(self.allocator, name, arguments_json);
        defer self.allocator.free(params);
        return try self.request("tools/call", params, abort);
    }

    pub fn callToolBodyAbortable(
        self: *McpClient,
        name: []const u8,
        arguments_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
    ) !ToolResultBody {
        const params = try protocol.callToolParams(self.allocator, name, arguments_json);
        defer self.allocator.free(params);
        return self.requestBody("tools/call", params, artifact_root, budget, abort, true);
    }

    /// 列出 server 暴露的 resources（resources/list）。返回原始 JSON-RPC result。
    pub fn listResources(self: *McpClient) ![]u8 {
        return self.listResourcesAbortable(null);
    }

    pub fn listResourcesAbortable(self: *McpClient, abort: ?*const AbortSignal) ![]u8 {
        return try self.request("resources/list", protocol.EMPTY_PARAMS, abort);
    }

    pub fn listResourcesBodyAbortable(
        self: *McpClient,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
    ) !ToolResultBody {
        return self.requestBody("resources/list", protocol.EMPTY_PARAMS, artifact_root, budget, abort, false);
    }

    /// 读取一个 resource（resources/read）。uri 为 resource 标识。
    pub fn readResource(self: *McpClient, uri: []const u8) ![]u8 {
        return self.readResourceAbortable(uri, null);
    }

    pub fn readResourceAbortable(self: *McpClient, uri: []const u8, abort: ?*const AbortSignal) ![]u8 {
        const params = try protocol.readResourceParams(self.allocator, uri);
        defer self.allocator.free(params);
        return try self.request("resources/read", params, abort);
    }

    pub fn readResourceBodyAbortable(
        self: *McpClient,
        uri: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
    ) !ToolResultBody {
        const params = try protocol.readResourceParams(self.allocator, uri);
        defer self.allocator.free(params);
        return self.requestBody("resources/read", params, artifact_root, budget, abort, false);
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const argv = [_]?[*:0]const u8{ "/nonexistent/mcp-server", null };
    if (McpClient.connect(testing.allocator, argv[0..])) |_| {
        // 不应成功
        try testing.expect(false);
    } else |err| {
        try testing.expect(err == error.McpServerCrashed or err == error.McpMalformedResponse);
    }
}

/// An oversized JSON result, sealed but not published: the file is validated
/// and its receipt fixed, and the agent loop publishes it at the batch commit
/// boundary (#65). Before #65 this published during the call, so a fatal
/// sibling in the same batch left an unreferenced blob in the CAS.
fn sealJsonResult(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    result: []const u8,
) !ToolResultBody {
    var spool = try artifact_store.Spool.begin(allocator, artifact_root);
    defer spool.deinit(); // a no-op once `seal` has taken the buffers
    try spool.write(result);
    const sealed = try spool.seal();
    return .{
        .sealed = .{
            .spool = sealed,
            .media_type = .json,
            .capture_complete = true,
            // The bytes were materialized in memory up to the frame limit, so a
            // failed publication at the commit boundary keeps them inline exactly
            // as the execution-time policy did.
            .retain_inline_ceiling = CONTROL_FRAME_MATERIALIZE_BYTES,
        },
    };
}

fn testCountDirectory(allocator: std.mem.Allocator, directory: []const u8) !usize {
    const pdir = @import("platform").dir;
    const directory_z = try allocator.dupeZ(u8, directory);
    defer allocator.free(directory_z);
    var iterator = pdir.open(directory_z.ptr) orelse return 0;
    defer pdir.close(&iterator);
    var count: usize = 0;
    while (pdir.next(&iterator)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

test "McpClient: an oversized result is sealed, not published, until the batch commits (#65)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &b);
    const root = b[0..n];
    const cas = try std.fmt.allocPrint(a, "{s}/tool-results/sha256", .{root});
    defer a.free(cas);
    const result = "{\"rows\":[" ++ ("{\"k\":\"vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\"}," ** 64) ++ "null]}";

    var body = try sealJsonResult(a, root, result);
    defer body.deinit(a);
    try testing.expect(body == .sealed);
    try testing.expect(body.sealed.media_type == .json);
    try testing.expectEqual(@as(usize, 0), try testCountDirectory(a, cas));
    var before = try body.render(a);
    defer before.deinit(a);
    var sealed = body.takeSealed().?;
    defer sealed.spool.deinit();
    const completed = try sealed.spool.publish();
    try testing.expectEqual(@as(usize, 1), try testCountDirectory(a, cas));
    try testing.expectEqual(@as(u64, result.len), completed.receipt.bytes);
    // The envelope the model saw before publication names the blob that exists after it.
    try testing.expect(std.mem.indexOf(u8, before.bytes, completed.receipt.id()) != null);
    var chunk = try artifact_store.readChunk(a, root, completed.receipt.id(), 0, 8);
    defer chunk.deinit();
    try testing.expectEqualSlices(u8, result[0..8], chunk.bytes);
}
