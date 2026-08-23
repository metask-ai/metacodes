const std = @import("std");
const time = @import("util/time.zig");
const log = @import("util/log.zig");
const http = std.http;
const types = @import("types.zig");
const json_mod = @import("json.zig");
const api_stream = @import("api/stream.zig");
const ResponseStatus = @import("api/http_status.zig").ResponseStatus;
const error_class = @import("api/error_class.zig");
const last_error = @import("api/last_error.zig");
const Catalog = @import("api/catalog.zig").Catalog;
const AbortSignal = @import("util/abort.zig").AbortSignal;
const provider_mod = @import("api/provider.zig");
const sync = @import("platform").sync;
const rng = @import("platform").rng;
const connection_gate = @import("api/connection_gate.zig");
const dialect_mod = @import("api/dialect.zig");

pub const VERSION = "0.1.0";

/// P0:AnthropicProvider 复用中立 Provider 接口(非 generic)。Client.provider() 产出它
/// (thunk 转调 + StreamResponse.handle() 中立化)。P1 起 agent_loop 等收 Provider 类型。
pub const AnthropicProvider = provider_mod.Provider;
pub const ANTHROPIC_API_URL = "https://napi.metask-ai.com/v1/messages";

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
    abort_registry: ?*provider_mod.RequestAbortRegistry = null,
};

/// 网络瞬态错误判定:服务端关连接(keep-alive 回收/LB 断连)、连接重置、读到 EOF 等。
/// 这些是**建连/收头阶段**的可重试错误(请求未产生副作用,从头重发安全)。
/// 已实测:MockServer 断连时 std.http receiveHead 抛 error.HttpConnectionClosing。
pub fn isTransientNetworkError(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.BrokenPipe,
        error.EndOfStream,
        error.UnexpectedReadFailure,
        error.UnexpectedWriteFailure,
        error.NetworkUnreachable,
        error.ConnectionRefused,
        error.TemporaryNameServerFailure,
        // std.http folds TLS certificate loading/handshake setup resource failures into this
        // concrete error. At request-setup time no response body has been consumed, so a bounded
        // retry is safe; permanent failures still terminate at max_retries with the original
        // concrete error retained in last_error diagnostics.
        error.TlsInitializationFailed,
        // std.Io.Writer/Reader 把底层 broken-pipe/reset **包装成通用 WriteFailed/ReadFailed**,
        // 丢了具体 errno。写 HTTP 请求体 / 读响应头时它必是连接问题(尤其长驻 daemon 撞到
        // 服务端已关的 pooled keep-alive 连接)→ 该重试(重连拿新连接)。非连接场景的
        // 请求体写失败不存在,retry 幂等(body 没发出去,重发无副作用)。
        // 病根:web 长驻进程复用 std.http.Client 连接池,空闲后连接被服务端关,首个 sendBody
        // WriteFailed 若不归瞬态就"1 attempt"放弃 → 用户见 api_error。headless 每次新进程无此问题。
        error.WriteFailed,
        error.ReadFailed,
        => true,
        else => false,
    };
}

/// 给定错误是否值得重试(瞬态网络错误 + 可重试 HTTP 状态)。对齐 CC shouldRetry:
/// 连接错误、429、5xx(ServerError/BadGateway/ServiceUnavailable)、overloaded(ApiError 由上层判)。
pub fn isRetriableError(err: anyerror) bool {
    if (isTransientNetworkError(err)) return true;
    return switch (err) {
        error.TransientNetwork,
        error.RateLimited,
        error.ServerError,
        error.BadGateway,
        error.ServiceUnavailable,
        => true,
        else => false,
    };
}

/// 纯函数版本：sample 由调用方注入，便于测试边界；生产入口 retryDelayMs 使用系统熵。
pub fn retryDelayMsWithSample(attempt: u32, base_ms: u64, sample: u64) u64 {
    const shift: u6 = @min(@as(u6, @intCast(@min(attempt -| 1, 16))), 6);
    const base = if (base_ms >= 32_000 or base_ms > (@as(u64, 32_000) >> shift))
        32_000
    else
        base_ms << shift;
    const jitter_max = base / 4;
    const jitter = if (jitter_max == 0) 0 else sample % (jitter_max + 1);
    return base + jitter;
}

/// 重试退避(对齐 CC getRetryDelay):min(base * 2^(attempt-1), 32000) + 真随机 jitter(0~25%)。
/// attempt 从 1 起。若系统熵源罕见失败，以单调时间 + 栈地址混合作为降级，避免退回所有
/// session 按 attempt 同步重试的确定性羊群行为。
pub fn retryDelayMs(attempt: u32, base_ms: u64) u64 {
    var bytes: [8]u8 = undefined;
    var sample: u64 = 0;
    if (rng.randomBytes(&bytes)) {
        for (bytes, 0..) |b, i| sample |= @as(u64, b) << @intCast(i * 8);
    } else {
        sample = @as(u64, @intCast(@max(time.nowMs(), 0))) ^ @as(u64, @intCast(@intFromPtr(&bytes))) ^ attempt;
    }
    return retryDelayMsWithSample(attempt, base_ms, sample);
}

pub const MAX_RETRY_AFTER_MS: u64 = 60_000;
pub const TLS_SETUP_MAX_ATTEMPTS: u32 = 3;

/// RFC 9110 Retry-After: delta-seconds or IMF-fixdate. Values are capped so a hostile/mistyped
/// header cannot pin an agent indefinitely. `now_unix` is injectable for deterministic tests.
pub fn parseRetryAfterMsAt(value_raw: []const u8, now_unix: i64) ?u64 {
    const value = std.mem.trim(u8, value_raw, " \t");
    if (value.len == 0) return null;
    var all_digits = true;
    var seconds: u64 = 0;
    for (value) |c| {
        if (c < '0' or c > '9') {
            all_digits = false;
            break;
        }
        seconds = @min(MAX_RETRY_AFTER_MS / 1000, seconds *| 10 +| (c - '0'));
    }
    if (all_digits) return @min(MAX_RETRY_AFTER_MS, seconds * 1000);

    const target = parseHttpDateUnix(value) orelse return null;
    if (target <= now_unix) return 0;
    const delta: u64 = @intCast(target - now_unix);
    return @min(MAX_RETRY_AFTER_MS, delta *| 1000);
}

fn parseHttpDateUnix(value: []const u8) ?i64 {
    // IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT"
    if (value.len != 29 or !std.mem.eql(u8, value[26..29], "GMT")) return null;
    if (!std.mem.eql(u8, value[3..5], ", ") or value[7] != ' ' or value[11] != ' ' or
        value[16] != ' ' or value[19] != ':' or value[22] != ':' or value[25] != ' ')
        return null;
    const day = parseFixed2(value[5..7]) orelse return null;
    const month = monthNumber(value[8..11]) orelse return null;
    const year = std.fmt.parseInt(i64, value[12..16], 10) catch return null;
    const hour = parseFixed2(value[17..19]) orelse return null;
    const minute = parseFixed2(value[20..22]) orelse return null;
    const second = parseFixed2(value[23..25]) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    const days = daysFromCivil(year, month, day) orelse return null;
    return days * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn parseFixed2(s: *const [2]u8) ?u8 {
    if (s[0] < '0' or s[0] > '9' or s[1] < '0' or s[1] > '9') return null;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

fn monthNumber(s: *const [3]u8) ?u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |name, n| if (std.mem.eql(u8, s, name)) return @intCast(n);
    return null;
}

fn daysFromCivil(year_raw: i64, month: u8, day: u8) ?i64 {
    if (month < 1 or month > 12 or day < 1) return null;
    const leap = @mod(year_raw, 4) == 0 and (@mod(year_raw, 100) != 0 or @mod(year_raw, 400) == 0);
    const month_days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > month_days[month - 1]) return null;
    var year = year_raw;
    if (month <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const adjusted_month: i64 = @as(i64, month) + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

const RetryHint = struct { delay_ms: ?u64 = null };

/// Deterministic L2 seam: fail the next N request-setup attempts with a concrete Zig error,
/// then allow the real HTTP request. This proves the public retry wrapper is wired to setup
/// classification; classifier-only unit tests cannot catch an earlier error-collapse bug.
pub const RequestSetupFailureInjector = struct {
    remaining: u32,
    failure: anyerror,

    fn take(self: *RequestSetupFailureInjector) ?anyerror {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return self.failure;
    }
};

fn retryAfterFromHead(head: http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after"))
            return parseRetryAfterMsAt(header.value, time.nowUnix());
    }
    return null;
}

/// 默认重试次数(对齐 CC DEFAULT_MAX_RETRIES=10;env CLAUDE_CODE_MAX_RETRIES 覆盖)。
pub fn defaultMaxRetries() u32 {
    if (std.c.getenv("CLAUDE_CODE_MAX_RETRIES")) |v_c| {
        const v = std.mem.span(v_c);
        return std.fmt.parseInt(u32, v, 10) catch 10;
    }
    return 10;
}

pub const RETRY_BASE_MS: u64 = 500;

/// 重试 UI 上报回调(agent_loop 注入,把 attempt/max/delay 渲染成 "Retrying in Ns…")。
/// state 类型擦除(指向 stdout_writer 等);headless 传 null。
pub const RetryReporter = api_stream.RetryReporter;

/// 可中断 sleep:分片 sleep(每 ≤50ms 查一次 abort)。返回 true=睡满,false=被 abort 打断。
pub fn interruptibleSleepMs(total_ms: u64, abort: ?*const AbortSignal) bool {
    const step_ms: u64 = 50;
    var slept: u64 = 0;
    while (slept < total_ms) {
        if (abort) |a| if (a.isAborted()) return false;
        const chunk = @min(step_ms, total_ms - slept);
        time.sleepMs(@intCast(chunk)); // 可移植睡眠(POSIX nanosleep / Windows Sleep)
        slept += chunk;
    }
    if (abort) |a| if (a.isAborted()) return false;
    return true;
}

/// API 客户端
pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    api_key: []const u8,
    /// **写务必走 setModel、跨线程读走 modelSnapshot(task#13)**:model 是 []const u8(ptr+len 两字),
    /// 非原子写。lead 主线程 switchModel(app.setModel→api_client.setModel)与后台 subagent 降级路径
    /// (owned_prov OOM 回退共享 api_client)的请求体读并发 → 撕裂 {new_ptr,old_len} 可致 OOB。mutex 串行。
    model: []const u8,
    model_mutex: sync.Mutex = .{},
    /// 完整的 messages endpoint URL。生产 = ANTHROPIC_API_URL;测试 = mock server URL。
    /// 通过 init 的 base_url_override 注入(L2 测试用)。
    base_url: []const u8,
    /// 模型 catalog——启动时 `probeModels` 填充。构造后为空，调 probeModels 再生效。
    catalog: Catalog,
    /// 模型上下文窗口表(~/.metacode/models.toml)。precedence:命中此表 > catalog probe > 200K。
    /// App 持有,借用不拥有(null = 未挂,落 catalog)。
    model_context: ?*const @import("app/model_context.zig").ModelContext = null,
    /// 用户 CLI `--max-tokens N` 覆盖；null = 自动（catalog → fallback table → default）。
    max_tokens_override: ?u32 = null,
    reasoning_effort: ?types.ReasoningEffort = null,
    /// Immutable Runtime-scoped model dialect lookup. Ordinary App/CLI clients
    /// use the built-in resolver; AgentRuntime injects its Snapshot resolver.
    dialect_resolver: dialect_mod.Resolver = .{},
    abort_registry: provider_mod.RequestAbortRegistry = .{},
    request_setup_failure_injector: ?*RequestSetupFailureInjector = null,

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
        client.abort_registry.deinit(client.allocator);
        client.http_client.deinit();
        client.catalog.deinit();
    }

    // ── P0:Provider vtable 包装(AnthropicProvider = Client 的 thunk)─────────
    // Client.provider() 产出一个 Provider,其 fn-ptr 转调本 Client 的现有方法,行为零变化。
    // agent_loop 后续(P1)改收 AnthropicProvider 而非 *Client,解耦到接口。
    pub fn provider(client: *Client) AnthropicProvider {
        return .{
            .ctx = @ptrCast(client),
            .modelFn = &pModel,
            .sendStreamFn = &pSendStream,
            .sendStreamRetryFn = &pSendStreamRetry,
            .sendFn = &pSend,
            .cancelFn = &pCancel,
            .maxTokensFn = &pMaxTokens,
            .maxInputTokensFn = &pMaxInputTokens,
            .reasoningEffortFn = &pReasoningEffort,
            .setReasoningEffortFn = &pSetReasoningEffort,
            // Anthropic 不支持方言字段覆盖(Claude 无 prompt_cache_key/parallel_tool_calls/response_format 方言字段);
            // requestOverridesFn 走 default(返全 null),setRequestOverridesFn 留 null(setter 调用返 error)
            .supportsFn = &pSupports,
        };
    }
    fn pModel(ctx: *anyopaque) []const u8 {
        return asClient(ctx).modelSnapshot(); // task#13:一致读(避免撕裂)
    }
    fn pSendStream(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!provider_mod.StreamHandle {
        const c = asClient(ctx);
        var sr = try c.sendMessageStreamFull(messages, system, tools, abort, model_override, tool_choice);
        sr.user_query = user_query;
        return boxHandle(c.allocator, sr);
    }
    fn pSendStreamRetry(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, max_retries: u32, retry_base_ms: u64, reporter: ?RetryReporter, user_query: []const u8) anyerror!provider_mod.StreamHandle {
        const c = asClient(ctx);
        var sr = try c.sendMessageStreamFullRetry(messages, system, tools, abort, model_override, tool_choice, max_retries, retry_base_ms, reporter);
        sr.user_query = user_query;
        return boxHandle(c.allocator, sr);
    }
    /// 把按值返回的 StreamResponse 堆框 + 包成中立 StreamHandle(地址稳定,next 后不移动)。
    fn boxHandle(allocator: std.mem.Allocator, sr: StreamResponse) !provider_mod.StreamHandle {
        // 拷贝前断言:sr 的 event_iter 未初始化(否则拷贝会把指向旧框 transfer_buf 的 reader 带进
        // 新框 → 悬挂)。send 路径返回的 sr 恒未初始化;此 assert 焊死该契约,防未来改坏。
        std.debug.assert(!sr.iter_initialized);
        const heap = try allocator.create(StreamResponse);
        heap.* = sr;
        return heap.heapHandle();
    }
    fn pSend(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, model_override: ?[]const u8) anyerror!ApiResponse {
        return asClient(ctx).sendMessageWithModel(messages, system, tools, model_override);
    }
    fn pCancel(ctx: *anyopaque, signal: *const AbortSignal) void {
        asClient(ctx).abort_registry.cancel(signal);
    }
    fn pMaxTokens(ctx: *anyopaque) u32 {
        return asClient(ctx).resolveMaxTokens();
    }
    fn pMaxInputTokens(ctx: *anyopaque) u32 {
        return asClient(ctx).resolveMaxInputTokens();
    }
    fn pReasoningEffort(ctx: *anyopaque) ?types.ReasoningEffort {
        return asClient(ctx).reasoning_effort;
    }
    fn pSetReasoningEffort(ctx: *anyopaque, effort: ?types.ReasoningEffort) void {
        asClient(ctx).reasoning_effort = effort;
    }
    fn pSupports(ctx: *anyopaque, cap: provider_mod.Capability) bool {
        // P2:走 capability 表(单一真相源),按当前 model 真判, 不再恒 true stub。
        const capability = @import("api/capability.zig");
        return capability.supports(.anthropic, asClient(ctx).model, cap);
    }
    inline fn asClient(ctx: *anyopaque) *Client {
        return @ptrCast(@alignCast(ctx));
    }

    /// 设置 CLI max_tokens 覆盖。null 恢复自动。
    pub fn setMaxTokensOverride(client: *Client, v: ?u32) void {
        client.max_tokens_override = v;
    }

    /// **切换 model(task#13)**:锁内写 {ptr,len} 一对,避免与跨线程读撕裂。app.setModel 唯一入口调它。
    pub fn setModel(client: *Client, m: []const u8) void {
        _ = client.model_mutex.lock();
        client.model = m;
        _ = client.model_mutex.unlock();
    }

    /// **跨线程一致读 model(task#13)**:锁内取 {ptr,len} 一对返回(避免撕裂)。请求体构造走它。
    pub fn modelSnapshot(client: *Client) []const u8 {
        _ = client.model_mutex.lock();
        defer _ = client.model_mutex.unlock();
        return client.model;
    }

    /// 按当前 model 解析真实使用的 max_tokens。
    pub fn resolveMaxTokens(client: *const Client) u32 {
        return client.catalog.maxTokensFor(client.model, client.max_tokens_override);
    }

    /// 按当前 model 解析 input context window(用于 auto-compact 阈值,非 output max_tokens)。
    pub fn resolveMaxInputTokens(client: *const Client) u32 {
        return client.resolveMaxInputTokensFor(client.model);
    }

    pub fn resolveMaxInputTokensFor(client: *const Client, model: []const u8) u32 {
        // precedence:~/.metacode/models.toml 命中 > catalog(/v1/models probe)> 200K 默认。
        if (client.model_context) |mc| {
            if (mc.windowFor(model)) |w| return w;
        }
        return client.catalog.maxInputTokensFor(model);
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

        const auth_header = std.fmt.allocPrint(client.allocator, "Bearer {s}", .{client.api_key}) catch return error.RequestFailed;
        defer secureFree(client.allocator, auth_header);

        var connection_lease = connection_gate.acquire(null) catch return error.RequestFailed;
        defer connection_lease.release();
        var req = client.http_client.request(.GET, uri, .{
            .keep_alive = false, // 同 POST:不复用陈旧连接
            .extra_headers = &.{
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "authorization", .value = auth_header },
            },
        }) catch return error.RequestFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.RequestFailed;
        var redirect_buf: [4096]u8 = undefined;
        const http_response = req.receiveHead(&redirect_buf) catch return error.RequestFailed;
        const status = ResponseStatus.capture(&http_response);
        connection_lease.release();
        if (!status.isOk()) return error.HttpError;

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
        return client.sendMessageWithModel(messages, system, tools, null);
    }

    pub fn sendMessageWithModel(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        model_override: ?[]const u8,
    ) !ApiResponse {
        const effective_model = model_override orelse client.modelSnapshot();
        const req_body = try json_mod.serializeMessagesRequestWithDialect(.{
            .model = effective_model,
            .max_tokens = client.catalog.maxTokensFor(effective_model, client.max_tokens_override), // task#13:用同一 effective_model 快照(不再单读 client.model 撕裂)
            .messages = messages,
            .system = system,
            .stream = false,
            .tools = tools,
            .reasoning_effort = client.reasoning_effort,
        }, client.allocator, client.dialect_resolver.resolve(.anthropic, effective_model));
        defer client.allocator.free(req_body);

        const result = try client.doRequest(req_body, false, null, null);
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
    /// model_override = null → 用 client.modelSnapshot();非 null → 用 override。
    /// **task#13**:max_tokens 用与 .model **同一** effective_model(catalog.maxTokensFor(effective_model,…)),
    /// 即请求内一致(override 时 max_tokens 也按 override model 查,与实际发送的 model 匹配,更正确);
    /// 且不再在 .model 快照后紧接着单独裸读 client.model(避免跨线程撕裂 {new_ptr,old_len} OOB)。
    pub fn sendMessageStreamFull(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
    ) !StreamResponse {
        return client.sendMessageStreamFullAttempt(messages, system, tools, abort, model_override, tool_choice, null);
    }

    fn sendMessageStreamFullAttempt(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
        retry_hint: ?*RetryHint,
    ) !StreamResponse {
        const effective_model = model_override orelse client.modelSnapshot();
        const req_body = try json_mod.serializeMessagesRequestWithDialect(.{
            .model = effective_model,
            .max_tokens = client.catalog.maxTokensFor(effective_model, client.max_tokens_override), // task#13:用同一 effective_model 快照(不再单读 client.model 撕裂)
            .messages = messages,
            .system = system,
            .stream = true,
            .tools = tools,
            .tool_choice = tool_choice,
            .reasoning_effort = client.reasoning_effort,
        }, client.allocator, client.dialect_resolver.resolve(.anthropic, effective_model));
        // doRequest 内部 sendBodyComplete 是同步全发,返回后 body 即可释放(stream/error 都)。
        defer client.allocator.free(req_body);

        const result = try client.doRequest(req_body, true, abort, retry_hint);
        switch (result) {
            .streaming_response => |r| {
                return StreamResponse.init(client.allocator, r, abort);
            },
            .full_body => unreachable,
        }
    }

    /// 建连阶段重试包装(对齐 CC withRetry)。仅覆盖 sendMessageStreamFull(建连+收头),
    /// 此时流尚未消费、未输出任何文本 → 从头重发安全。可重试错误(瞬态网络/429/5xx)按
    /// 指数退避重试,最多 max_retries 次;UI 经 reporter 回调(前 3 次由 reporter 自行降噪)。
    /// retry_base_ms=0 时用默认 RETRY_BASE_MS(测试注入小值避免真 sleep)。
    pub fn sendMessageStreamFullRetry(
        client: *Client,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
        max_retries: u32,
        retry_base_ms: u64,
        reporter: ?RetryReporter,
    ) !StreamResponse {
        const base_ms = if (retry_base_ms > 0) retry_base_ms else RETRY_BASE_MS;
        var attempt: u32 = 0;
        while (true) {
            var retry_hint = RetryHint{};
            const r = client.sendMessageStreamFullAttempt(messages, system, tools, abort, model_override, tool_choice, &retry_hint);
            if (r) |stream| {
                return stream;
            } else |err| {
                attempt += 1;
                // TlsInitializationFailed can hide both transient resource pressure and permanent
                // certificate/protocol failures. Retrying is safe before body send, but cap it
                // tighter than generic network/HTTP retries to avoid minutes of deterministic pain.
                const effective_max_attempts = if (err == error.TlsInitializationFailed)
                    @min(max_retries, TLS_SETUP_MAX_ATTEMPTS)
                else
                    max_retries;
                if (!isRetriableError(err) or attempt >= effective_max_attempts) {
                    log.err("client", "stream connect failed after {d} attempt(s): {s}", .{ attempt, @errorName(err) });
                    // (Aborted 不在 sendMessageStreamFull 的 error set 里,编译器背书,无需分支。)
                    switch (err) {
                        // HTTP 状态类:logErrorBody 已记 body,只补尝试次数。
                        error.Unauthorized, error.RateLimited, error.ServerError, error.BadGateway, error.ServiceUnavailable, error.HttpError, error.ContextWindowExceeded => last_error.noteAttempts(attempt),
                        // 连接类:无 HTTP 响应没走 logErrorBody,现场在这里补记。
                        else => {
                            // doRequest 已记录具体底层错误（例如 TlsInitializationFailed）；
                            // TransientNetwork 是对 send/receive 错误的分类壳，不能在这里覆盖现场。
                            if (err != error.TransientNetwork)
                                last_error.recordNamed("连接初始化失败", @errorName(err));
                            last_error.noteAttempts(attempt);
                        },
                    }
                    return err;
                }
                const delay = retry_hint.delay_ms orelse retryDelayMs(attempt, base_ms);
                if (reporter) |rep| rep.report(rep.state, attempt, effective_max_attempts, delay);
                log.warn("client", "stream connect retry {d}/{d} after {s}; sleeping {d}ms", .{ attempt, effective_max_attempts, @errorName(err), delay });
                // 可中断 sleep:每 50ms 查一次 abort。
                if (!interruptibleSleepMs(delay, abort)) return error.Aborted;
            }
        }
    }

    fn doRequest(
        client: *Client,
        body: []const u8,
        streaming: bool,
        abort: ?*const AbortSignal,
        retry_hint: ?*RetryHint,
    ) !RequestResult {
        const rid = log.genRequestId();
        const t_start = timestampMs();

        // 凭据及其任何片段都不得进入日志/eval artifact。
        log.infoId("client", rid, "POST {s} model={s} streaming={} body_bytes={d} reasoning_effort={s}", .{
            client.base_url,
            client.model,
            streaming,
            body.len,
            if (client.reasoning_effort) |effort| effort.name() else "default",
        });
        log.debugId("client", rid, "request body:\n{s}", .{body});

        // record/replay(Stage 7):录请求 body(开启新一轮 cassette)。dir 未设时 no-op。
        @import("core/recorder.zig").recordRequest(body);

        const uri = std.Uri.parse(client.base_url) catch {
            log.errId("client", rid, "invalid url", .{});
            return error.InvalidUrl;
        };

        // OAuth access tokens can be longer than a small stack buffer. Allocate
        // the header value and scrub it after request setup.
        const auth_header = std.fmt.allocPrint(client.allocator, "Bearer {s}", .{client.api_key}) catch {
            log.errId("client", rid, "alloc auth header failed", .{});
            return error.RequestFailed;
        };
        defer secureFree(client.allocator, auth_header);

        // Request 必须 heap-allocate：Response 内含 *Request，生命周期要覆盖 stream
        // 读取过程。若放栈上，doRequest 返回后 *Request 悬挂 → stream.next() 踩到
        // 新栈内容 segfault（ReleaseSmall 紧凑栈 reuse 下必炸）。
        const req_ptr = client.allocator.create(http.Client.Request) catch |err| {
            log.errId("client", rid, "alloc request: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        errdefer client.allocator.destroy(req_ptr);

        var connection_lease = try connection_gate.acquire(abort);
        defer connection_lease.release();

        if (client.request_setup_failure_injector) |injector| {
            if (injector.take()) |err| {
                log.errId("client", rid, "request setup injected failure: {s}", .{@errorName(err)});
                if (isTransientNetworkError(err)) {
                    last_error.recordNamed("连接初始化失败", @errorName(err));
                    return err;
                }
                return error.RequestFailed;
            }
        }

        // keep_alive=false:长驻(serve/--web)复用连接池,空闲后服务端关连接,首个 sendBody 撞
        // WriteFailed → 重试风暴(isTransientNetworkError 注释的病根)。新连接的握手洪峰由
        // process-wide connection_gate(MAX_CONNECTING_REQUESTS) 限制，不重新引入陈旧池连接。
        req_ptr.* = client.http_client.request(.POST, uri, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth_header },
            },
        }) catch |err| {
            log.errId("client", rid, "request setup failed: {s}", .{@errorName(err)});
            if (isTransientNetworkError(err)) {
                last_error.recordNamed("连接初始化失败", @errorName(err));
                return err;
            }
            return error.RequestFailed;
        };
        // errdefer 销毁顺序：先 req.deinit()（释放连接/缓冲），再 destroy 槽位。
        errdefer req_ptr.deinit();
        if (abort) |signal|
            try client.abort_registry.register(
                client.allocator,
                signal,
                req_ptr,
                shutdownRequest,
            );
        errdefer if (abort != null) client.abort_registry.unregister(req_ptr);

        // 发送 body
        req_ptr.sendBodyComplete(@constCast(body)) catch |err| {
            log.errId("client", rid, "sendBody failed: {s}", .{@errorName(err)});
            if (isTransientNetworkError(err)) {
                last_error.recordNamed("连接失败", @errorName(err));
                if (err == error.TlsInitializationFailed) return err;
                return error.TransientNetwork;
            }
            return error.RequestFailed;
        };

        // 读取响应头
        var redirect_buf: [4096]u8 = undefined;
        const http_response = req_ptr.receiveHead(&redirect_buf) catch |err| {
            log.errId("client", rid, "receiveHead failed: {s}", .{@errorName(err)});
            // 网络瞬态错误(服务端关连接等)上抛区分性 error,让重试层识别;非瞬态塌缩 RequestFailed。
            if (isTransientNetworkError(err)) {
                last_error.recordNamed("连接失败", @errorName(err));
                if (err == error.TlsInitializationFailed) return err;
                return error.TransientNetwork;
            }
            return error.RequestFailed;
        };
        const status = ResponseStatus.capture(&http_response);
        // DNS/TCP/TLS + request-head phase is complete; active streaming must not consume a slot.
        connection_lease.release();

        if (retry_hint) |hint| hint.delay_ms = retryAfterFromHead(http_response.head);

        const header_ms = timestampMs() - t_start;
        log.infoId("client", rid, "HTTP {d} {s} header_latency_ms={d}", .{
            status.code,
            status.name,
            header_ms,
        });

        switch (classifyHttpStatus(status.code)) {
            // 成功即清陈旧错误现场——否则后续无记录的失败路径(如 mid-stream 断连)
            // 会把几轮前的无关错误当死因端给用户。
            .ok => last_error.clear(),
            .failure => |failure| {
                // Read every error body exactly once while the request reader is alive. Cleanup
                // remains with the surrounding errdefers; do not deinit/destroy here.
                const body_info = logErrorBody(req_ptr, rid, status, http_response);
                return resolveHttpFailure(failure, body_info);
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
                    .abort_registry = if (abort != null) &client.abort_registry else null,
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

fn shutdownRequest(raw: *anyopaque) void {
    const request: *http.Client.Request = @ptrCast(@alignCast(raw));
    provider_mod.abortHttpRequest(request);
}

fn secureFree(allocator: std.mem.Allocator, buf: []u8) void {
    @memset(buf, 0);
    allocator.free(buf);
}

/// 毫秒时间戳（monotonic），用于测量请求延迟。失败返 0。可移植走 util/time。
fn timestampMs() u64 {
    const ms = time.nowMs();
    return if (ms < 0) 0 else @intCast(ms);
}

const HttpFailure = enum {
    unauthorized,
    rate_limited,
    server_error,
    bad_gateway,
    service_unavailable,
    generic,
};

const HttpDisposition = union(enum) {
    ok,
    failure: HttpFailure,
};

const HttpFailureError = error{
    Unauthorized,
    RateLimited,
    ServerError,
    BadGateway,
    ServiceUnavailable,
    ContextWindowExceeded,
    HttpError,
};

/// Total interpretation of the open HTTP status code domain into a closed,
/// provider-owned disposition.
fn classifyHttpStatus(status_code: u16) HttpDisposition {
    return switch (status_code) {
        200 => .ok,
        401 => .{ .failure = .unauthorized },
        429 => .{ .failure = .rate_limited },
        500 => .{ .failure = .server_error },
        502 => .{ .failure = .bad_gateway },
        503 => .{ .failure = .service_unavailable },
        else => .{ .failure = .generic },
    };
}

/// Exhaustive mapping over the closed provider failure set. Adding a new
/// failure category forces this function to make an explicit error decision.
fn resolveHttpFailure(failure: HttpFailure, body: ErrorBodyInfo) HttpFailureError {
    return switch (failure) {
        .unauthorized => error.Unauthorized,
        .rate_limited => error.RateLimited,
        .server_error => error.ServerError,
        .bad_gateway => error.BadGateway,
        .service_unavailable => error.ServiceUnavailable,
        .generic => if (body.context_window_exceeded)
            error.ContextWindowExceeded
        else
            error.HttpError,
    };
}

/// HTTP 错误现场:唯一失败分支在这里读取一次响应 body(截断 2KB)并以 err 级打日志。
/// 必须在 req_ptr.deinit() 之前调用(reader 还活着)。
fn logErrorBody(
    req_ptr: *http.Client.Request,
    rid: log.RequestId,
    status: ResponseStatus,
    http_response: http.Client.Response,
) ErrorBodyInfo {
    var err_body: [2048]u8 = undefined;
    const body_reader_tmp = req_ptr.reader.bodyReader(
        err_body[0..],
        http_response.head.transfer_encoding,
        http_response.head.content_length,
    );
    const n = body_reader_tmp.readSliceShort(err_body[0..]) catch 0;
    const preview = err_body[0..@min(n, err_body.len)];
    log.errId("client", rid, "HTTP {d} {s}: body={s}", .{
        status.code, status.name, preview,
    });
    last_error.recordHttp(status.code, preview);
    return .{ .context_window_exceeded = error_class.isContextWindowExceeded(preview) };
}

const ErrorBodyInfo = struct {
    context_window_exceeded: bool = false,
};

test "HTTP status classification is total and preserves provider semantics" {
    try std.testing.expectEqual(HttpDisposition.ok, classifyHttpStatus(200));

    const cases = [_]struct { code: u16, failure: HttpFailure }{
        .{ .code = 401, .failure = .unauthorized },
        .{ .code = 429, .failure = .rate_limited },
        .{ .code = 500, .failure = .server_error },
        .{ .code = 502, .failure = .bad_gateway },
        .{ .code = 503, .failure = .service_unavailable },
        .{ .code = 529, .failure = .generic },
        .{ .code = 599, .failure = .generic },
    };
    for (cases) |case| {
        const disposition = classifyHttpStatus(case.code);
        try std.testing.expectEqual(case.failure, disposition.failure);
    }

    try std.testing.expectEqual(error.Unauthorized, resolveHttpFailure(.unauthorized, .{ .context_window_exceeded = true }));
    try std.testing.expectEqual(error.ContextWindowExceeded, resolveHttpFailure(.generic, .{ .context_window_exceeded = true }));
    try std.testing.expectEqual(error.HttpError, resolveHttpFailure(.generic, .{}));
}

/// API 响应（非流式）
// ApiResponse/ToolCallResult 下沉到中立层 api/stream.zig(多 Provider 重构);此处 re-export 保持兼容。
pub const ApiResponse = api_stream.ApiResponse;
pub const ToolCallResult = api_stream.ToolCallResult;

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
        if (self.stream_result.abort_registry) |registry|
            registry.unregister(self.stream_result.request);
        self.stream_result.request.deinit();
        self.allocator.destroy(self.stream_result.request);
    }

    // ── 中立化:把 *堆分配* 的 StreamResponse 包成 provider 无关的 StreamHandle ──
    // StreamResponse.next 懒初始化 event_iter 时取 &self.stream_result 内部地址,故 self 首次
    // next 后**不可移动**——必须堆分配地址稳定。heapHandle 接管堆指针,handle.deinit 释放内部
    // 资源 + 销毁堆框。返回的 StreamHandle 借用该堆 StreamResponse(同步消费)。
    pub fn heapHandle(self: *StreamResponse) api_stream.StreamHandle {
        // 安全前提(焊死):self 必须堆分配 + event_iter **尚未初始化**。因为 next() 懒初始化时
        // 取 &self.stream_result.transfer_buf 的地址喂 reader——一旦初始化过, self 就不可移动/拷贝
        // (那个内联 8KB 数组地址会悬挂)。boxHandle 在 send 返回后立刻包, 此时恒未初始化。
        // 违反此前提(未来若有人在包之前先 next 一次)= 偶发悬挂指针, assert 当场 panic 暴露。
        std.debug.assert(!self.iter_initialized);
        return .{
            .ctx = @ptrCast(self),
            .nextFn = &hNext,
            .deinitFn = &hDeinit,
            .stopReasonFn = &hStopReason,
            .requestIdFn = &hRequestId,
        };
    }
    fn hNext(ctx: *anyopaque) anyerror!?StreamEvent {
        return @as(*StreamResponse, @ptrCast(@alignCast(ctx))).next();
    }
    fn hDeinit(ctx: *anyopaque) void {
        const sr: *StreamResponse = @ptrCast(@alignCast(ctx));
        const a = sr.allocator;
        sr.deinit();
        a.destroy(sr); // 销毁堆框(heapHandle 的前提是 sr 来自 a.create)
    }
    fn hStopReason(ctx: *anyopaque) api_stream.StopReason {
        return @as(*StreamResponse, @ptrCast(@alignCast(ctx))).stopReason();
    }
    fn hRequestId(ctx: *anyopaque) log.RequestId {
        return @as(*StreamResponse, @ptrCast(@alignCast(ctx))).id;
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
            error.ContextWindowExceededEvent => {
                log.warnId("stream", self.id, "context-window-exceeded error event surfaced", .{});
                return error.ContextWindowExceeded;
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
            .thinking_delta => |t| StreamEvent{ .thinking = t },
            .tool_use_start => |tu| StreamEvent{ .tool_use_start = tu },
            .web_search_result => |w| StreamEvent{ .web_search_result = w },
            .web_search_query => |q| StreamEvent{ .web_search_query = q },
            .usage => |u| StreamEvent{ .usage = u },
            .done => blk: {
                self.done = true;
                break :blk StreamEvent{ .done = {} };
            },
        };
    }
};

// StreamEvent 下沉到中立层 api/stream.zig(多 Provider 重构);此处 re-export 保持兼容
// (cc.client_mod.StreamEvent 等现有引用不变)。
pub const StreamEvent = api_stream.StreamEvent;

/// 解析非流式 API 响应
fn parseApiResponse(data: []const u8, allocator: std.mem.Allocator) !ApiResponse {
    var response = ApiResponse{};

    if (std.mem.indexOf(u8, data, "\"content\":[")) |idx| {
        // needle `"content":[` 长 11;`[` 在 idx+10。从 `[` 起扫(depth 计数要看到开括号),
        // findJsonArrayEnd 返回**闭括号之后**的索引 → 切片 [bracket, end) 含整个 `[...]`。
        const bracket = idx + 10;
        if (bracket < data.len) {
            const end = findJsonArrayEnd(data, bracket) orelse data.len;
            // 防御:end 已是"闭括号后一位",最大可为 data.len;不再 +1(旧 bug:content_end+1 越界)。
            const safe_end = @min(end, data.len);
            if (safe_end > bracket) {
                response.content = try allocator.dupe(u8, data[bracket..safe_end]);
            }
        }
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
            error.TransientNetwork, error.RateLimited, error.ServerError, error.BadGateway, error.ServiceUnavailable => |err| {
                const delay_ms = retryDelayMs(retries + 1, RETRY_BASE_MS);
                log.warn("client", "retry {d}/{d} after {s}; sleeping {d}ms", .{
                    retries + 1,
                    max_retries,
                    @errorName(err),
                    delay_ms,
                });
                _ = interruptibleSleepMs(delay_ms, null);
                continue;
            },
            else => return result,
        }
    }
}

/// Token 计数估算(与 Conversation.estimateTokens 同公式:ASCII/4 + 非 ASCII 码点)。
pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    var ascii: usize = 0;
    var other: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch return text.len / 4;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) ascii += 1 else other += 1;
    }
    return (ascii + 3) / 4 + other;
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

test "parseApiResponse: 提取 content 数组 + stop_reason" {
    const a = std.testing.allocator;
    const data = "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"stop_reason\":\"end_turn\"}";
    const resp = try parseApiResponse(data, a);
    defer a.free(resp.content);
    // content 应是完整 `[...]` 数组(含括号)。
    try std.testing.expect(resp.content.len > 0);
    try std.testing.expect(resp.content[0] == '[');
    try std.testing.expect(resp.content[resp.content.len - 1] == ']');
    try std.testing.expect(std.mem.indexOf(u8, resp.content, "\"text\":\"hi\"") != null);
    // stop_reason 现有实现含引号(`"end_turn"`);只断言包含 end_turn(不锁引号细节)。
    try std.testing.expect(resp.stop_reason != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.stop_reason.?, "end_turn") != null);
}

test "parseApiResponse: content 数组在末尾(回归 index OOB:旧 content_end+1 越界)" {
    // 真 TTY 实测崩点:auto-compact 的非流式响应,content 数组是最后一段时,
    // 旧代码 `data[content_start-1 .. content_end+1]` 的 +1 越界 panic。
    const a = std.testing.allocator;
    const data = "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"plan summary\"}]}";
    const resp = try parseApiResponse(data, a);
    defer a.free(resp.content);
    try std.testing.expect(std.mem.indexOf(u8, resp.content, "plan summary") != null);
    try std.testing.expect(resp.content[resp.content.len - 1] == ']'); // 不越界,正确收尾
}

test "parseApiResponse: 畸形响应(content 数组未闭合)不崩" {
    // findJsonArrayEnd 返回 null → fallback data.len;不该 +1 越界。
    const a = std.testing.allocator;
    const data = "{\"content\":[{\"type\":\"text\",\"text\":\"truncated";
    const resp = try parseApiResponse(data, a);
    defer if (resp.content.len > 0) a.free(resp.content);
    // 不崩即通过(content 截到 data 末尾)。
    try std.testing.expect(resp.content.len <= data.len);
}

test "parseApiResponse: 无 content 字段 → 空" {
    const a = std.testing.allocator;
    const resp = try parseApiResponse("{\"stop_reason\":\"end_turn\"}", a);
    defer if (resp.content.len > 0) a.free(resp.content);
    try std.testing.expect(resp.content.len == 0);
}

test "extractJsonString" {
    try std.testing.expect(std.mem.eql(u8, extractJsonString("{\"id\":\"abc\"}", "id") orelse "", "abc"));
    try std.testing.expect(std.mem.eql(u8, extractJsonString("{\"name\":\"foo\"}", "name") orelse "", "foo"));
    try std.testing.expect(extractJsonString("{\"x\":1}", "missing") == null);
}

test "estimateTokens" {
    try std.testing.expect(estimateTokens("hello world") > 0);
    try std.testing.expect(estimateTokens("你好") == 2); // 2 CJK codepoints ≈ 2 tokens
    try std.testing.expect(estimateTokens("") == 0);
    // 校准:ASCII ≈ 4 字符/token(实测 claude/gpt/glm 3.3~4.5 bytes/token)。
    try std.testing.expect(estimateTokens("abcdefgh") == 2);
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

test "task#13: setModel/modelSnapshot round-trip + 并发无撕裂(mutex 串行)" {
    const a = std.testing.allocator;
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", "http://x");
    defer client.deinit();

    // round-trip:setModel 写 → modelSnapshot 读回。
    try std.testing.expectEqualStrings("claude-3-5-haiku-20241022", client.modelSnapshot());
    client.setModel("claude-sonnet-4-20250514");
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", client.modelSnapshot());

    // 并发 hammer:writer 在**两个不同长度** model 间切,reader 每次 snapshot 必是完整一个。
    // 撕裂({new_ptr,old_len} 等)会得到既非 A 又非 B 的 slice(甚至 OOB 越读)。mutex 串行 → 永远一致。
    const A = "m"; // len 1
    const B = "claude-sonnet-4-longname-xyz"; // len 28(与 A 差异大,撕裂立显)
    const Ctx = struct {
        c: *Client,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn writer(s: *@This()) void {
            var i: usize = 0;
            while (!s.stop.load(.acquire)) : (i += 1) {
                s.c.setModel(if (i & 1 == 0) A else B);
            }
        }
    };
    client.setModel(A); // 起点置 A,避免 reader 读到初始 model(既非 A 又非 B)误报
    var wctx = Ctx{ .c = &client };
    const th = try std.Thread.spawn(.{}, Ctx.writer, .{&wctx});
    defer th.join();
    defer wctx.stop.store(true, .release);
    var n: usize = 0;
    while (n < 50_000) : (n += 1) {
        const m = client.modelSnapshot();
        if (!std.mem.eql(u8, m, A) and !std.mem.eql(u8, m, B)) return error.TornModelRead;
    }
}
