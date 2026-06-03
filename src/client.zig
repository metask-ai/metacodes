const std = @import("std");
const log = @import("util/log.zig");
const http = std.http;
const types = @import("types.zig");
const json_mod = @import("json.zig");
const api_stream = @import("api/stream.zig");
const Catalog = @import("api/catalog.zig").Catalog;
const AbortSignal = @import("util/abort.zig").AbortSignal;

pub const VERSION = "0.1.0";
pub const ANTHROPIC_API_URL = "https://napi.metask-ai.com/v1/messages";
pub const ANTHROPIC_AUTH_TOKEN = "";

/// HTTP 请求结果
const RequestResult = union(enum) {
    full_body: struct {
        body: []u8,
        id: log.RequestId,
    },
    streaming_response: StreamResult,
};

/// 流式响应（持有 Response，caller 通过它逐行读取）
///
/// **生命周期陷阱**：`http.Client.Response` 内含 `request: *Request`，指向发起
/// 请求的 Request 实例。Request 必须在整个 stream 读取过程中存活。我们原先把
/// `var req` 直接塞进 StreamResult 按值返回，这让 `*Request` 悬挂到已 pop 的栈帧上；
/// debug 栈 0xaa 填充偶尔能活，ReleaseSmall 下紧凑栈 reuse 必炸。
/// 修法：Request 放 heap，StreamResult 持有 owned `*Request`，deinit 时 destroy。
pub const StreamResult = struct {
    request: *http.Client.Request,
    response: http.Client.Response,
    transfer_buf: [8192]u8,
    id: log.RequestId,
};

/// API 客户端
pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    api_key: []const u8,
    model: []const u8,
    /// 完整的 messages endpoint URL。生产 = ANTHROPIC_API_URL;测试 = mock server URL。
    /// 通过 init 的 base_url_override 注入(L2 测试用)。
    base_url: []const u8,
    /// 模型 catalog——启动时 `probeModels` 填充。构造后为空，调 probeModels 再生效。
    catalog: Catalog,
    /// 用户 CLI `--max-tokens N` 覆盖；null = 自动（catalog → fallback table → default）。
    max_tokens_override: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8) Client {
        return initWithBaseUrl(allocator, io, api_key, model, null);
    }

    /// 测试用:允许覆盖 base_url(指向 MockServer)。生产代码用 init。
    pub fn initWithBaseUrl(
        allocator: std.mem.Allocator,
        io: std.Io,
        api_key: []const u8,
        model: []const u8,
        base_url_override: ?[]const u8,
    ) Client {
        return .{
            .allocator = allocator,
            .http_client = http.Client{ .allocator = allocator, .io = io },
            .api_key = api_key,
            .model = model,
            .base_url = base_url_override orelse ANTHROPIC_API_URL,
            .catalog = Catalog.init(allocator),
        };
    }

    pub fn deinit(client: *Client) void {
        client.http_client.deinit();
        client.catalog.deinit();
    }

    /// 设置 CLI max_tokens 覆盖。null 恢复自动。
    pub fn setMaxTokensOverride(client: *Client, v: ?u32) void {
        client.max_tokens_override = v;
    }

    /// 按当前 model 解析真实使用的 max_tokens。
    pub fn resolveMaxTokens(client: *const Client) u32 {
        return client.catalog.maxTokensFor(client.model, client.max_tokens_override);
    }

    /// 按当前 model 解析 input context window(用于 auto-compact 阈值,非 output max_tokens)。
    pub fn resolveMaxInputTokens(client: *const Client) u32 {
        return client.catalog.maxInputTokensFor(client.model);
    }

    /// 启动时探测 `/v1/models` → 填 catalog。失败静默（不报错，fallback 仍可用）。
    pub fn probeModels(client: *Client) void {
        const body = client.doGetModels() catch |err| {
            log.debug("catalog", "probeModels: {s} (falling back to local table)", .{@errorName(err)});
            return;
        };
        defer client.allocator.free(body);
        client.catalog.loadFromModelsListJson(body) catch |err| {
            log.debug("catalog", "parse /v1/models failed: {s}", .{@errorName(err)});
        };
    }

    /// GET <base>/v1/models 拉完整响应。
    fn doGetModels(client: *Client) ![]u8 {
        // 把 /v1/messages 替换成 /v1/models
        const messages_url = client.base_url;
        const suffix = "/v1/messages";
        if (!std.mem.endsWith(u8, messages_url, suffix)) return error.UnexpectedUrl;
        const base = messages_url[0 .. messages_url.len - suffix.len];
        const url = try std.fmt.allocPrint(client.allocator, "{s}/v1/models", .{base});
        defer client.allocator.free(url);

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        var auth_header_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{client.api_key}) catch return error.RequestFailed;

        var req = client.http_client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "authorization", .value = auth_header },
            },
        }) catch return error.RequestFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.RequestFailed;
        var redirect_buf: [4096]u8 = undefined;
        const http_response = req.receiveHead(&redirect_buf) catch return error.RequestFailed;
        if (http_response.head.status != .ok) return error.HttpError;

        var transfer_buf: [8192]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buf, http_response.head.transfer_encoding, http_response.head.content_length);
        return body_reader.allocRemaining(client.allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.RequestFailed;
    }

    /// 发送非流式消息请求
    pub fn sendMessage(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
    ) !ApiResponse {
        const req_body = try json_mod.serializeMessagesRequest(.{
            .model = client.model,
            .max_tokens = client.resolveMaxTokens(),
            .messages = messages,
            .system = system,
            .stream = false,
            .tools = tools,
        }, client.allocator);
        defer client.allocator.free(req_body);

        const result = try client.doRequest(req_body, false);
        switch (result) {
            .full_body => |fb| {
                defer client.allocator.free(fb.body);
                log.debugId("client", fb.id, "response body ({d} bytes):\n{s}", .{ fb.body.len, fb.body });
                return try parseApiResponse(fb.body, client.allocator);
            },
            .streaming_response => unreachable,
        }
    }

    /// 发送流式消息请求，返回流式响应迭代器
    pub fn sendMessageStream(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
    ) !StreamResponse {
        return client.sendMessageStreamAbortable(messages, system, tools, null);
    }

    /// 带 AbortSignal 的流式请求。abort 在网络读取阶段通过 EventIterator 的检查点生效。
    pub fn sendMessageStreamAbortable(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
    ) !StreamResponse {
        return client.sendMessageStreamFull(messages, system, tools, abort, null, null);
    }

    /// 完整签名:支持 per-call model_override(subagent 用 def.zig 的 model 字段覆盖父 model)。
    /// model_override = null → 用 client.model;非 null → 用 override。
    /// 注意 max_tokens 仍走 client.resolveMaxTokens(),因为 model→max_tokens 表查的是 client.model;
    /// 若 override 后想用 override 的 max_tokens,需扩展 catalog 查询。本期保守:沿用 client max_tokens。
    pub fn sendMessageStreamFull(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
    ) !StreamResponse {
        const effective_model = model_override orelse client.model;
        const req_body = try json_mod.serializeMessagesRequest(.{
            .model = effective_model,
            .max_tokens = client.resolveMaxTokens(),
            .messages = messages,
            .system = system,
            .stream = true,
            .tools = tools,
            .tool_choice = tool_choice,
        }, client.allocator);
        // doRequest 内部 sendBodyComplete 是同步全发,返回后 body 即可释放(stream/error 都)。
        defer client.allocator.free(req_body);

        const result = try client.doRequest(req_body, true);
        switch (result) {
            .streaming_response => |r| {
                return StreamResponse.init(client.allocator, r, abort);
            },
            .full_body => unreachable,
        }
    }

    fn doRequest(client: *Client, body: []const u8, streaming: bool) !RequestResult {
        const rid = log.genRequestId();
        const t_start = timestampMs();

        // token preview：前 6 + 后 4 字符，中间打码。日志不能全量打 token。
        var tok_prev_buf: [24]u8 = undefined;
        const tok_preview = tokenPreview(client.api_key, &tok_prev_buf);
        log.infoId("client", rid, "POST {s} model={s} streaming={} token={s} body_bytes={d}", .{
            client.base_url,
            client.model,
            streaming,
            tok_preview,
            body.len,
        });
        log.debugId("client", rid, "request body:\n{s}", .{body});

        // record/replay(Stage 7):录请求 body(开启新一轮 cassette)。dir 未设时 no-op。
        @import("core/recorder.zig").recordRequest(body);

        const uri = std.Uri.parse(client.base_url) catch {
            log.errId("client", rid, "invalid url", .{});
            return error.InvalidUrl;
        };

        // 构建 authorization header
        var auth_header_buf: [128]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{client.api_key}) catch {
            log.errId("client", rid, "auth header buffer too small", .{});
            return error.RequestFailed;
        };

        // Request 必须 heap-allocate：Response 内含 *Request，生命周期要覆盖 stream
        // 读取过程。若放栈上，doRequest 返回后 *Request 悬挂 → stream.next() 踩到
        // 新栈内容 segfault（ReleaseSmall 紧凑栈 reuse 下必炸）。
        const req_ptr = client.allocator.create(http.Client.Request) catch |err| {
            log.errId("client", rid, "alloc request: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        errdefer client.allocator.destroy(req_ptr);

        req_ptr.* = client.http_client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth_header },
            },
        }) catch |err| {
            log.errId("client", rid, "request setup failed: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        // errdefer 销毁顺序：先 req.deinit()（释放连接/缓冲），再 destroy 槽位。
        errdefer req_ptr.deinit();

        // 发送 body
        req_ptr.sendBodyComplete(@constCast(body)) catch |err| {
            log.errId("client", rid, "sendBody failed: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };

        // 读取响应头
        var redirect_buf: [4096]u8 = undefined;
        const http_response = req_ptr.receiveHead(&redirect_buf) catch |err| {
            log.errId("client", rid, "receiveHead failed: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };

        const status = http_response.head.status;
        const header_ms = timestampMs() - t_start;
        log.infoId("client", rid, "HTTP {d} {s} header_latency_ms={d}", .{
            @intFromEnum(status),
            @tagName(status),
            header_ms,
        });

        switch (status) {
            .ok => {},
            // 错误分支:读 body 进 log 后直接 return error。
            // 清理交给 errdefer(:253 destroy + :266 deinit)——分支内**不要**手动
            // deinit/destroy,否则与 errdefer 双重释放 → segfault(这些路径过去无测试
            // 覆盖,Stage 6 L2 首次触发才暴露此潜伏 bug)。
            .unauthorized => {
                logErrorBody(req_ptr, rid, status, http_response);
                return error.Unauthorized;
            },
            .too_many_requests => {
                logErrorBody(req_ptr, rid, status, http_response);
                return error.RateLimited;
            },
            .internal_server_error => {
                logErrorBody(req_ptr, rid, status, http_response);
                return error.ServerError;
            },
            .bad_gateway => {
                logErrorBody(req_ptr, rid, status, http_response);
                return error.BadGateway;
            },
            .service_unavailable => {
                logErrorBody(req_ptr, rid, status, http_response);
                return error.ServiceUnavailable;
            },
            else => {
                // 4xx/other：读 body 进 log 便于 debug。否则用户只看到 "HttpError"，
                // 不知道是 model 名错、字段不识别、还是 API key 过期。
                logErrorBody(req_ptr, rid, status, http_response);
                return error.HttpError;
            },
        }

        if (streaming) {
            // 所有权转给调用方：StreamResult.request 拥有 req_ptr，StreamResponse.deinit
            // 负责 req_ptr.deinit() + destroy。
            return RequestResult{
                .streaming_response = .{
                    .request = req_ptr,
                    .response = http_response,
                    .transfer_buf = undefined,
                    .id = rid,
                },
            };
        }

        // 非流式：读取完整 body；结束后立即 deinit+destroy req_ptr（不再返回）
        var transfer_buf: [8192]u8 = undefined;
        const body_reader = req_ptr.reader.bodyReader(&transfer_buf, http_response.head.transfer_encoding, http_response.head.content_length);
        const response_body = body_reader.allocRemaining(client.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            log.errId("client", rid, "read body failed: {s}", .{@errorName(err)});
            req_ptr.deinit();
            client.allocator.destroy(req_ptr);
            return error.RequestFailed;
        };
        req_ptr.deinit();
        client.allocator.destroy(req_ptr);
        log.infoId("client", rid, "response complete bytes={d} total_ms={d}", .{ response_body.len, timestampMs() - t_start });
        return RequestResult{ .full_body = .{ .body = response_body, .id = rid } };
    }
};

/// 毫秒时间戳（monotonic），用于测量请求延迟。失败返 0。
fn timestampMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// HTTP 错误现场:读响应 body(截断 2KB)以 err 级打日志。
/// 五个明确 status 分支(401/429/500/502/503)和 else 分支共用,避免"零现场"return。
/// 必须在 req_ptr.deinit() 之前调用(reader 还活着)。
fn logErrorBody(
    req_ptr: *http.Client.Request,
    rid: log.RequestId,
    status: http.Status,
    http_response: http.Client.Response,
) void {
    var err_body: [2048]u8 = undefined;
    const body_reader_tmp = req_ptr.reader.bodyReader(
        err_body[0..],
        http_response.head.transfer_encoding,
        http_response.head.content_length,
    );
    const n = body_reader_tmp.readSliceShort(err_body[0..]) catch 0;
    const preview = err_body[0..@min(n, err_body.len)];
    log.errId("client", rid, "HTTP {d} {s}: body={s}", .{
        @intFromEnum(status), @tagName(status), preview,
    });
}

/// Token 打码：只露前 6 + 后 4 字符（常见格式 `sk-xxxxxxxx...yyyy`）。
/// 过短的 token 直接打 "<short:N>"。out buf 至少 24 字节。
fn tokenPreview(token: []const u8, out: []u8) []const u8 {
    if (token.len < 12) {
        return std.fmt.bufPrint(out, "<short:{d}>", .{token.len}) catch "<?>";
    }
    const head = token[0..6];
    const tail = token[token.len - 4 ..];
    return std.fmt.bufPrint(out, "{s}...{s}", .{ head, tail }) catch "<?>";
}

test "tokenPreview masks middle" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("sk-6cd...3711", tokenPreview("sk-test-redacted", &buf));
    try std.testing.expectEqualStrings("<short:4>", tokenPreview("abcd", &buf));
}

/// API 响应（非流式）
pub const ApiResponse = struct {
    content: []const u8 = "",
    stop_reason: ?[]const u8 = null,
    tool_calls: []const ToolCallResult = &.{},
};

pub const ToolCallResult = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8,
};

/// 流式响应迭代器（M1.4 起改为真流式）。
///
/// 持有 Response + transfer buffer + EventIterator，按需逐行解析事件。
/// 不再 allocRemaining，大响应不会 OOM，首字节延迟真实。
pub const StreamResponse = struct {
    allocator: std.mem.Allocator,
    stream_result: StreamResult,
    event_iter: api_stream.EventIterator = undefined,
    iter_initialized: bool = false,
    abort: ?*const AbortSignal = null,
    done: bool = false,
    /// 本轮用户原始输入(borrowed),透传给 EventIterator 供 web_search 显示真实 query。
    user_query: []const u8 = "",
    /// 本次流式请求的 request_id，所有下游（stream event、agent loop、工具调用）
    /// 用它把日志串起来。
    id: log.RequestId,

    fn init(allocator: std.mem.Allocator, sr: StreamResult, abort: ?*const AbortSignal) StreamResponse {
        return .{
            .allocator = allocator,
            .stream_result = sr,
            .abort = abort,
            .id = sr.id,
        };
    }

    pub fn deinit(self: *StreamResponse) void {
        // EventIterator 可能持有未 emit 的 pending_tool(流中途断开时残留),释放它。
        if (self.iter_initialized) self.event_iter.deinit(self.allocator);
        self.stream_result.request.deinit();
        self.allocator.destroy(self.stream_result.request);
    }

    /// drain 完后读 API 报告的 stop_reason(max_tokens 续写判断用)。
    /// 未初始化 / 未收到 message_delta → .unknown。
    pub fn stopReason(self: *const StreamResponse) api_stream.StopReason {
        if (!self.iter_initialized) return .unknown;
        return self.event_iter.last_stop_reason;
    }

    /// 读下一个事件。首次调用时懒初始化 EventIterator——Response.reader 的返回是一个
    /// 指向 self.stream_result 内部字段的指针，必须在 self 稳定后才能取地址。
    pub fn next(self: *StreamResponse) !?StreamEvent {
        if (self.done) return null;

        if (!self.iter_initialized) {
            const reader = self.stream_result.response.reader(&self.stream_result.transfer_buf);
            self.event_iter = if (self.abort) |a|
                api_stream.EventIterator.initWithAbort(reader, a)
            else
                api_stream.EventIterator.init(reader);
            self.event_iter.setRequestId(self.id);
            if (self.user_query.len > 0) self.event_iter.setUserQuery(self.user_query);
            self.iter_initialized = true;
        }

        const ev_opt = self.event_iter.next(self.allocator) catch |err| switch (err) {
            error.Aborted => {
                log.warnId("stream", self.id, "aborted during event read", .{});
                return error.Aborted;
            },
            error.ApiErrorEvent => {
                // SSE `event: error` 帧:API 主动报错(overloaded/invalid_request 等)。
                // 上抛**区分性** error,不塌缩成 RequestFailed,让 agent_loop/测试能识别。
                log.warnId("stream", self.id, "API error event surfaced", .{});
                return error.ApiError;
            },
            else => {
                log.warnId("stream", self.id, "event_iter.next failed: {s}", .{@errorName(err)});
                return error.RequestFailed;
            },
        };
        const ev = ev_opt orelse {
            self.done = true;
            return null;
        };
        return switch (ev) {
            .text_delta => |t| StreamEvent{ .text = t },
            .tool_use_start => |tu| StreamEvent{ .tool_use_start = tu },
            .web_search_result => |w| StreamEvent{ .web_search_result = w },
            .usage => |u| StreamEvent{ .usage = u },
            .done => blk: {
                self.done = true;
                break :blk StreamEvent{ .done = {} };
            },
        };
    }
};

pub const StreamEvent = union(enum) {
    text: []u8,
    tool_use_start: json_mod.ToolUseResult,
    web_search_result: api_stream.WebSearchResultEvent,
    usage: api_stream.UsageDelta,
    done: void,
};

/// 解析非流式 API 响应
fn parseApiResponse(data: []const u8, allocator: std.mem.Allocator) !ApiResponse {
    var response = ApiResponse{};

    if (std.mem.indexOf(u8, data, "\"content\":[")) |idx| {
        const content_start = idx + 12;
        const content_end = findJsonArrayEnd(data, content_start) orelse data.len;
        response.content = try allocator.dupe(u8, data[content_start - 1 .. content_end + 1]);
    }

    if (std.mem.indexOf(u8, data, "\"stop_reason\":")) |idx| {
        const start = idx + 14;
        const end = std.mem.indexOfScalar(u8, data[start..], ',') orelse (std.mem.indexOfScalar(u8, data[start..], '}') orelse data.len);
        response.stop_reason = data[start .. start + end];
    }

    if (std.mem.indexOf(u8, data, "\"tool_calls\":[")) |tc_idx| {
        const arr_start = tc_idx + 13;
        const arr_end = findJsonArrayEnd(data, arr_start) orelse data.len;
        response.tool_calls = try parseToolCalls(data[arr_start..arr_end], allocator);
    }

    return response;
}

fn parseToolCalls(arr_data: []const u8, allocator: std.mem.Allocator) ![]ToolCallResult {
    var results = try std.ArrayList(ToolCallResult).initCapacity(allocator, 4);
    defer results.deinit(allocator);

    var i: usize = 0;
    while (i < arr_data.len) {
        while (i < arr_data.len and std.ascii.isWhitespace(arr_data[i])) i += 1;
        if (i >= arr_data.len or arr_data[i] != '{') break;

        const obj_end = findJsonObjectEnd(arr_data, i) orelse break;
        const obj = arr_data[i..obj_end];

        if (extractJsonString(obj, "id")) |id| {
            if (extractJsonString(obj, "name")) |name| {
                if (extractJsonString(obj, "input")) |input| {
                    try results.append(allocator, .{ .id = id, .name = name, .input = input });
                }
            }
        }
        i = obj_end;
    }

    return try results.toOwnedSlice(allocator);
}

fn findJsonArrayEnd(data: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;

    for (data[start..], start..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (c == '[' or c == '{') depth += 1;
        if (c == ']' or c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn findJsonObjectEnd(data: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;

    for (data[start..], start..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn extractJsonString(data: []const u8, field: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    std.debug.assert(field.len < 200);
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..field.len], field);
    pattern_buf[1 + field.len] = '"';
    pattern_buf[2 + field.len] = ':';
    pattern_buf[3 + field.len] = '"';
    const pattern = pattern_buf[0 .. 4 + field.len];

    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    const start = idx + pattern.len;
    var end = start;
    while (end < data.len) : (end += 1) {
        if (data[end] == '"' and data[end - 1] != '\\') break;
    }
    return data[start..end];
}

/// 带重试的请求
pub fn withRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    api_key: []const u8,
    model: []const u8,
    messages: []const types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const json_mod.ToolDefinition,
    max_retries: u32,
) !ApiResponse {
    var client = Client.init(allocator, io, api_key, model);
    defer client.deinit();

    var retries: u32 = 0;
    while (true) : (retries += 1) {
        if (retries >= max_retries) {
            log.err("client", "max retries ({d}) exceeded", .{max_retries});
            return error.MaxRetriesExceeded;
        }

        const result = client.sendMessage(messages, system, tools);
        switch (result) {
            error.RateLimited, error.ServerError, error.BadGateway, error.ServiceUnavailable => |err| {
                const delay_ms = @as(u64, 1000) * (@as(u64, 1) << @min(@as(u6, @intCast(retries)), 5));
                log.warn("client", "retry {d}/{d} after {s}; sleeping {d}ms", .{
                    retries + 1,
                    max_retries,
                    @errorName(err),
                    delay_ms,
                });
                std.time.sleep(delay_ms * std.time.ns_per_ms);
                continue;
            },
            else => return result,
        }
    }
}

/// Token 计数估算
pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch return text.len / 4;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            count += 1;
        } else if (cp >= 0x4E00 and cp <= 0x9FFF) {
            count += 1; // CJK: each char is roughly 1 token
        } else {
            count += 1;
        }
    }
    return @max(count, text.len / 4);
}

test "findJsonObjectEnd" {
    try std.testing.expect(findJsonObjectEnd("{\"a\":1}", 0) == 7);
    try std.testing.expect(findJsonObjectEnd("{\"a\":{\"b\":2}}", 0) == 13);
    try std.testing.expect(findJsonObjectEnd("{\"a\":[1,2]}", 0) == 11); // [1,2] doesn't affect brace depth
}

test "findJsonArrayEnd" {
    try std.testing.expect(findJsonArrayEnd("[1,2,3]", 0) == 7);
    try std.testing.expect(findJsonArrayEnd("[{\"a\":1},{\"b\":2}]", 0) == 17);
    try std.testing.expect(findJsonArrayEnd("[1,[2,3]]", 0) == 9); // closing ] is at index 8, returns 9
}

test "extractJsonString" {
    try std.testing.expect(std.mem.eql(u8, extractJsonString("{\"id\":\"abc\"}", "id") orelse "", "abc"));
    try std.testing.expect(std.mem.eql(u8, extractJsonString("{\"name\":\"foo\"}", "name") orelse "", "foo"));
    try std.testing.expect(extractJsonString("{\"x\":1}", "missing") == null);
}

test "estimateTokens" {
    try std.testing.expect(estimateTokens("hello world") > 0);
    try std.testing.expect(estimateTokens("你好") == 2); // 2 CJK codepoints
    try std.testing.expect(estimateTokens("") == 0);
}

// Regression: GET /v1/models 必须用 sendBodiless()；std.http 对带 body 的 GET 会 assert。
// 有人把 sendBodiless 改回 sendBodyComplete("")，离线 probeModels 会 panic（非 error）。
// 源码扫描级断言兜底：测试读自己的源文件，确保关键行不退化。
test "doGetModels uses sendBodiless (no sendBodyComplete on GET)" {
    const src = @embedFile("client.zig");
    // 确认函数里有 sendBodiless 调用
    try std.testing.expect(std.mem.indexOf(u8, src, "req.sendBodiless()") != null);
    // 确认没人回退到 sendBodyComplete("") 模式
    try std.testing.expect(std.mem.indexOf(u8, src, "sendBodyComplete(@constCast(\"\"))") == null);
}
