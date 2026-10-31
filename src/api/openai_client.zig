//! OpenAIClient:讲 OpenAI chat/completions 协议的 Provider 实现(多 Provider 重构 P3)。
//!
//! 证明点:这是第二个真 provider——它的 wire 协议(请求 body / SSE 事件)与 Anthropic 完全不同,
//! 但它产出**同一套中立 IR**(StreamEvent: text/tool_use_start/usage/done),经同一个 Provider vtable
//! 暴露。**agent_loop / Conversation / 中立 IR / provider.zig 一行不改**就能用它跑。这是"真多协议"
//! (区别于 cc 全归一成 Anthropic SDK)的端到端兑现。
//!
//! 范围(P3+,非生产级 OpenAI client):文本流 + **并行 tool_calls**(function calling)
//! + usage(含缓存命中 cached_tokens,经 stream_options.include_usage)。
//!   - **并行 tool_calls(P0.1 已实现)**:按 delta 的 `index` 分槽累积(ToolCallAcc),done 时
//!     每槽 flush 一个 tool_use_start,executeSlots 真并发执行;请求侧每个 tool_result 独立
//!     {role:"tool"} 回传。见 parseChunk tool_calls 分支 / buildFlush / serializeOpenAIMessage。
//! `function.arguments` 的每个 SSE 字符串片段按**原始转义字节**拼进 tool-call `index`
//! 槽,flush 时一次解除外层 JSON 转义(decode-once,见 buildFlush)——被 chunk 边界
//! 拆开的 `\uXXXX` 代理对因此无损,字符串字段和反斜杠以原始 JSON 字节进入工具层。
//! **诚实登记——以下未做**:
//!   - **建连重试 / 429 退避**:pSendStreamRetry 忽略 max_retries/reporter,直接发一次;doStream
//!     遇非 200(含 429/500)直接 error.RequestFailed,无重试。Anthropic 路径有 withRetry,此处没有。
//!   - **非流式 pSend**:返回 error.NotImplemented → auto-compact summary 在 OpenAI 路径退化成
//!     纯丢老消息(compact_summary.summarize catch 兜底,不崩)。
//!   - **max_tokens/context_window**:output 保持原生 4096 默认(序列化器不发送该字段,所以不接 `--max-tokens` override,否则本地预算与服务端脱节);context window 按 ModelContext 解析,未命中以 128000 兜底。
//!   - **keep_alive=false**(每请求新连接):牺牲连接池(省 TLS 握手)换稳定性;流式池化收益小。
//!   - thinking/o1-reasoning、prompt cache、completion(非 chat)。
//!
//! 协议差异(本文件锁住的全部脏活):
//!   - URL:{base}/v1/chat/completions(Anthropic 是 /v1/messages)
//!   - 认证:Authorization: Bearer {key}(凑巧同 Anthropic;无 anthropic-version header)
//!   - 请求 body:{model, messages:[{role,content|tool_calls|tool_call_id}], tools:[{type:function,...}], stream}
//!   - SSE:data: {choices:[{delta:{content|tool_calls}, finish_reason}]} / data: [DONE]
//!
//! **Responses API(issue #4)**:protocol=.responses 时同一 Client 改讲 /v1/responses——
//! 请求走 serializeOpenAIResponsesRequest(input items / instructions / 扁平 tools /
//! reasoning:{effort} / store:false),SSE 走 parseResponsesChunk(typed 事件,无 [DONE])。
//! 协议是显式配置(--openai-protocol / METACODES_OPENAI_PROTOCOL),绝不从 base_url/model 推断。

const std = @import("std");
const http = std.http;
const connection_gate = @import("connection_gate.zig");
const ResponseStatus = @import("http_status.zig").ResponseStatus;
const http_status = @import("http_status.zig");
const http_connection = @import("http_connection.zig");
const no_redirects = http_status.no_redirects;
const log = @import("../util/log.zig");
const types = @import("../types.zig");
const json_mod = @import("../json.zig");
const util_json = @import("../util/json.zig");
const api_stream = @import("stream.zig");
const provider_mod = @import("provider.zig");
const client_mod = @import("../client.zig");
const liveness_reader = @import("liveness_reader.zig");
const capability = @import("capability.zig");
const cache = @import("cache.zig");
const request_overrides = @import("request_overrides.zig");
const dialect_mod = @import("dialect.zig");
const catalog_mod = @import("catalog.zig");
const image_capability = @import("image_capability.zig");
const auth_header_mod = @import("auth_header.zig");
const credential_mod = @import("credential_cell.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const model_context_mod = @import("../app/model_context.zig");

const StreamEvent = api_stream.StreamEvent;
const StreamHandle = api_stream.StreamHandle;
const StopReason = api_stream.StopReason;
const UsageDelta = api_stream.UsageDelta;

pub const DEFAULT_OPENAI_URL = "https://api.openai.com/v1/chat/completions";
pub const DEFAULT_OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";

pub const OpenAIClient = struct {
    pub const RefreshFn = *const fn (ctx: *anyopaque, stale_access_token: []const u8) anyerror![]u8;
    allocator: std.mem.Allocator,
    /// Read when each request's header is built (see `client_mod.Client.credential`).
    credential: credential_mod.Credential,
    /// 完整端点 URL 覆盖(可指向 MockServer / 自建中转站)。null = 按 protocol 选官方端点
    /// (effectiveUrl)。存 init 入参原样——protocol 可在 init 后设置(precedent app.zig)。
    base_url: ?[]const u8,
    model: []const u8,
    http_client: http.Client,
    abort_registry: provider_mod.RequestAbortRegistry = .{},
    /// 收头阶段空闲上限,见 client.zig DEFAULT_STREAM_IDLE_TIMEOUT_MS;init 时从 env 取,测试可直接改字段。
    stream_idle_timeout_ms: u64 = client_mod.DEFAULT_STREAM_IDLE_TIMEOUT_MS,
    /// 正文阶段空闲上限的平覆盖;null = 按 max_tokens 自动(client.zig bodyIdleLimitMs)。
    stream_body_idle_timeout_ms: ?u64 = null,
    max_tokens: u32 = 4096,
    context_window: u32 = 128_000,
    model_context: ?*const model_context_mod.ModelContext = null,
    reasoning_effort: ?types.ReasoningEffort = null,
    /// OpenAI wire 协议(显式配置,组装层从 config.openai_protocol 塞;绝不从 URL 推断)。
    protocol: types.OpenAIProtocol = .chat_completions,
    /// 方言字段覆盖(null = profile 默认)。来源:计划 jolly-glacier。
    overrides: request_overrides.RequestOverrides = .{},
    /// Provider-declared authentication for the selected offer (issue #16).
    /// Null keeps the historical `authorization: Bearer <key>` bytes exactly.
    auth_scheme: ?auth_header_mod.AuthScheme = null,
    dialect_resolver: dialect_mod.Resolver = .{},
    /// The provider's model catalog, when the caller has one (owned). Its
    /// image_input declarations override the family table (issue #273).
    catalog: ?catalog_mod.Catalog = null,
    /// Host declarations about models' image input; they outrank the catalog
    /// (issue #273). Owned; empty by default.
    host_capabilities: image_capability.Declarations = .{},
    server_request_id: [256]u8 = undefined,
    server_request_id_len: usize = 0,
    last_request_id: log.RequestId = .{ .bytes = .{0} ** 12 },
    last_http_status: u16 = 0,
    refresh_ctx: ?*anyopaque = null,
    refresh_fn: ?RefreshFn = null,
    refresh_token_owned: ?[]u8 = null,
    refresh_token_history: std.ArrayList([]u8) = .empty,
    last_retry_attempt: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, base_url: ?[]const u8) OpenAIClient {
        return .{
            .allocator = allocator,
            .credential = .{ .fixed = api_key },
            .base_url = base_url,
            .model = model,
            .http_client = http.Client{ .allocator = allocator, .io = io },
            .stream_idle_timeout_ms = client_mod.streamIdleTimeoutMsFromEnv(),
            .stream_body_idle_timeout_ms = client_mod.streamBodyIdleTimeoutMsFromEnv(),
        };
    }
    pub fn deinit(self: *OpenAIClient) void {
        if (self.refresh_token_owned) |token| secureFree(self.allocator, token);
        for (self.refresh_token_history.items) |token| secureFree(self.allocator, token);
        self.refresh_token_history.deinit(self.allocator);
        self.abort_registry.deinit(self.allocator);
        self.http_client.deinit();
        if (self.catalog) |*catalog| catalog.deinit();
        self.host_capabilities.deinit();
    }

    pub fn serverRequestId(self: *const OpenAIClient) []const u8 {
        return self.server_request_id[0..self.server_request_id_len];
    }

    pub fn setRefreshCallback(self: *OpenAIClient, ctx: *anyopaque, callback: RefreshFn) void {
        self.refresh_ctx = ctx;
        self.refresh_fn = callback;
    }

    fn replaceRefreshToken(self: *OpenAIClient, token: []u8) !void {
        if (self.refresh_token_owned) |old| try self.refresh_token_history.append(self.allocator, old);
        self.refresh_token_owned = token;
        self.credential = .{ .fixed = token };
    }

    /// 本次请求的实际端点:显式 base_url 优先,否则按 protocol 选官方端点。
    fn effectiveUrl(self: *const OpenAIClient) []const u8 {
        return self.base_url orelse switch (self.protocol) {
            .chat_completions => DEFAULT_OPENAI_URL,
            .responses => DEFAULT_OPENAI_RESPONSES_URL,
        };
    }

    // ── Provider vtable ──────────────────────────────────────────────────────
    pub fn provider(self: *OpenAIClient) provider_mod.Provider {
        return .{
            .ctx = @ptrCast(self),
            .modelFn = &pModel,
            .sendStreamFn = &pSendStream,
            .sendStreamRetryFn = &pSendStreamRetry,
            .sendFn = &pSend,
            .cancelFn = &pCancel,
            .maxTokensFn = &pMaxTokens,
            .maxInputTokensFn = &pMaxInputTokens,
            .maxTokensForFn = &pMaxTokensFor,
            .maxInputTokensForFn = &pMaxInputTokensFor,
            .reasoningEffortFn = &pReasoningEffort,
            .setReasoningEffortFn = &pSetReasoningEffort,
            .routeFn = &pRoute,
            .requestOverridesFn = &pRequestOverrides,
            .setRequestOverridesFn = &pSetRequestOverrides,
            .supportsFn = &pSupports,
            .supportsForModelFn = &pSupportsForModel,
            .imageInputFn = &pImageInput,
            .visionModelsFn = &pVisionModels,
            .requestIdTextFn = &pRequestIdText,
            .serverRequestIdFn = &pServerRequestId,
            .httpStatusFn = &pHttpStatus,
            .retryAttemptFn = &pRetryAttempt,
        };
    }
    inline fn cast(ctx: *anyopaque) *OpenAIClient {
        return @ptrCast(@alignCast(ctx));
    }
    fn pModel(ctx: *anyopaque) []const u8 {
        return cast(ctx).model;
    }
    fn pRoute(ctx: *anyopaque) ?provider_mod.ProviderRoute {
        const self = cast(ctx);
        return .{
            .kind = .openai,
            .base_url = self.base_url orelse "",
            .model = self.model,
            // A replaceable credential is never lent: no delegable route.
            .credential = self.credential.lendable() orelse return null,
            .auth_scheme = self.auth_scheme,
            .openai_protocol = self.protocol,
        };
    }
    /// Provider.requestOverrides() 返回 Client.overrides;同步也镜像 reasoning_effort
    /// 进 overrides.reasoning_effort(若 overrides 未显式设,从 legacy 字段兜底),
    /// 让 serialize 经统一入口拿到 effort。
    fn pRequestOverrides(ctx: *anyopaque) request_overrides.RequestOverrides {
        const self = cast(ctx);
        var o = self.overrides;
        if (o.reasoning_effort == null) o.reasoning_effort = self.reasoning_effort;
        return o;
    }
    fn pSetRequestOverrides(ctx: *anyopaque, o: request_overrides.RequestOverrides) void {
        cast(ctx).overrides = o;
        // 同步 reasoning_effort(若 o 显式设了),保持 legacy 字段一致
        if (o.reasoning_effort) |e| cast(ctx).reasoning_effort = e;
    }
    fn pMaxTokens(ctx: *anyopaque) u32 {
        const self = cast(ctx);
        return pMaxTokensFor(ctx, self.model);
    }
    fn pMaxInputTokens(ctx: *anyopaque) u32 {
        const self = cast(ctx);
        return pMaxInputTokensFor(ctx, self.model);
    }
    fn pMaxTokensFor(ctx: *anyopaque, model: []const u8) u32 {
        const self = cast(ctx);
        _ = model; // OpenAI does not serialize max_tokens; an override would desync local budgeting.
        return self.max_tokens;
    }
    fn pMaxInputTokensFor(ctx: *anyopaque, model: []const u8) u32 {
        const self = cast(ctx);
        if (self.model_context) |mc| if (mc.windowFor(model)) |w| return w;
        return self.context_window;
    }
    fn pReasoningEffort(ctx: *anyopaque) ?types.ReasoningEffort {
        return cast(ctx).reasoning_effort;
    }
    fn pSetReasoningEffort(ctx: *anyopaque, effort: ?types.ReasoningEffort) void {
        cast(ctx).reasoning_effort = effort;
    }
    fn pSupports(ctx: *anyopaque, cap: provider_mod.Capability) bool {
        return cast(ctx).supportsForModel(cap, cast(ctx).model);
    }
    fn pSupportsForModel(ctx: *anyopaque, cap: provider_mod.Capability, model: []const u8) bool {
        return cast(ctx).supportsForModel(cap, model);
    }
    fn pImageInput(ctx: *anyopaque, model: []const u8) image_capability.Resolution {
        const profile = cast(ctx).dialectFor(model).profileFor(.openai, model);
        return .{ .supported = profile.supports_image_input, .source = profile.image_input_source };
    }
    fn pVisionModels(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const []const u8 {
        const catalog = &(cast(ctx).catalog orelse return try allocator.alloc([]const u8, 0));
        return catalog.visionModels(allocator);
    }

    /// The dialect for `model` with the Host's or the catalog's image_input
    /// declaration applied (Host first) - the one profile the serializer's
    /// gate and every capability query read, as in the Anthropic client.
    pub fn dialectFor(self: *const OpenAIClient, model: []const u8) dialect_mod.Dialect {
        var dialect = self.dialect_resolver.resolve(.openai, model);
        const from_catalog: ?bool = if (self.catalog) |*catalog| catalog.imageInputFor(model) else null;
        dialect.declareImageInput(self.host_capabilities.imageInputFor(model), from_catalog);
        return dialect;
    }

    pub fn supportsForModel(self: *const OpenAIClient, cap: provider_mod.Capability, model: []const u8) bool {
        return switch (cap) {
            .image_input => self.dialectFor(model).profileFor(.openai, model).supports_image_input,
            else => capability.supports(.openai, model, cap),
        };
    }
    fn pRequestIdText(ctx: *anyopaque) []const u8 {
        return cast(ctx).last_request_id.asSlice();
    }
    fn pServerRequestId(ctx: *anyopaque) []const u8 {
        return cast(ctx).serverRequestId();
    }
    fn pHttpStatus(ctx: *anyopaque) u16 {
        return cast(ctx).last_http_status;
    }
    fn pRetryAttempt(ctx: *anyopaque) u32 {
        return cast(ctx).last_retry_attempt;
    }
    fn pSend(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, model_override: ?[]const u8) anyerror!provider_mod.ApiResponse {
        // P3 MVP:非流式不实现(compact summary 在 OpenAI 路径下退回纯丢老消息)。诚实返回空。
        _ = ctx;
        _ = messages;
        _ = system;
        _ = tools;
        _ = model_override;
        return error.NotImplemented;
    }
    fn pCancel(ctx: *anyopaque, signal: *const AbortSignal) void {
        cast(ctx).abort_registry.cancel(signal);
    }
    fn pSendStreamRetry(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, max_retries: u32, retry_base_ms: u64, reporter: ?provider_mod.RetryReporter, user_query: []const u8) anyerror!StreamHandle {
        // P3 MVP:不做建连重试(直接发一次)。retry/reporter 忽略——证明架构不需要它先齐全。
        _ = max_retries;
        _ = retry_base_ms;
        _ = reporter;
        return pSendStream(ctx, messages, system, tools, abort, model_override, tool_choice, user_query);
    }
    fn pSendStream(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!StreamHandle {
        _ = user_query; // OpenAI 无 server-tool web_search → 无需 query 透传
        const self = cast(ctx);
        const model = model_override orelse self.model;
        // overrides 从 provider 状态读(reasoning_effort 走 legacy 兜底,tool_choice 走 per-call 参数)。
        // 这样 agent_loop 无需感知 overrides——provider 自己管方言字段。
        var o = self.overrides;
        if (o.reasoning_effort == null) o.reasoning_effort = self.reasoning_effort;
        o.tool_choice = tool_choice;
        const dialect = self.dialectFor(model);
        // 图像 tool_result 定案(原生块 / 占位)由序列化器实际报告,随流句柄回传。
        var report = json_mod.SerializationReport{};
        defer report.deinit(self.allocator);
        // wire 协议分派:chat/completions(默认)或 Responses API(typed SSE)。
        const body = switch (self.protocol) {
            .chat_completions => try serializeOpenAIRequestWithOverridesAndDialectReport(self.allocator, model, messages, system, tools, o, dialect, &report),
            .responses => try serializeOpenAIResponsesRequestReport(self.allocator, model, messages, system, tools, o, dialect, &report),
        };
        defer self.allocator.free(body);
        const placeholder_ids = try report.placeholder_ids.toOwnedSlice(self.allocator);
        return self.doStreamWithAuthReplay(body, abort, dialect, placeholder_ids);
    }

    fn doStreamWithAuthReplay(
        self: *OpenAIClient,
        body: []const u8,
        abort: ?*const AbortSignal,
        dialect: dialect_mod.Dialect,
        image_placeholder_ids: []const []const u8,
    ) !StreamHandle {
        self.last_retry_attempt = 0;
        const first = self.doStream(body, abort, dialect, image_placeholder_ids, 0) catch |err| {
            if (err != error.TokenExpired) return err;
            // The first transport retained the placeholder slice so the
            // replay can use the identical serialized request. If refresh is
            // unavailable, this call owns the only remaining copy and must
            // release it here.
            const callback = self.refresh_fn orelse {
                self.allocator.free(image_placeholder_ids);
                return error.RequestFailed;
            };
            const ctx = self.refresh_ctx orelse {
                self.allocator.free(image_placeholder_ids);
                return error.RequestFailed;
            };
            // Refresh replaces fixed bytes the client owns; a Session's
            // replaceable credential is rotated by its Host instead.
            const stale = self.credential.lendable() orelse {
                self.allocator.free(image_placeholder_ids);
                return error.RequestFailed;
            };
            const token = callback(ctx, stale) catch {
                self.allocator.free(image_placeholder_ids);
                return error.RequestFailed;
            };
            self.replaceRefreshToken(token) catch {
                secureFree(self.allocator, token);
                self.allocator.free(image_placeholder_ids);
                return error.RequestFailed;
            };
            self.last_retry_attempt = 1;
            return self.doStream(body, abort, dialect, image_placeholder_ids, 1) catch |replay_err| {
                // A second token_expired response also retains the slice;
                // every other failure has already released it through
                // doStream's errdefer.
                if (replay_err == error.TokenExpired) {
                    self.allocator.free(image_placeholder_ids);
                    return error.RequestFailed;
                }
                return replay_err;
            };
        };
        return first;
    }

    /// 发 HTTP POST + 包成中立 StreamHandle(堆框 OpenAIStream,地址稳定)。
    /// `image_placeholder_ids` 所有权转入本函数:失败路径释放,成功后归 OpenAIStream。
    fn doStream(self: *OpenAIClient, body: []const u8, abort: ?*const AbortSignal, dialect: dialect_mod.Dialect, image_placeholder_ids: []const []const u8, retry_attempt: u32) !StreamHandle {
        var preserve_placeholder_ids = false;
        errdefer if (!preserve_placeholder_ids) self.allocator.free(image_placeholder_ids);
        const rid = log.genRequestId();
        self.last_request_id = rid;
        log.infoId(
            "openai",
            rid,
            "POST {s} model={s} body_bytes={d} cache_mode={s} reasoning_effort={s}",
            .{ self.effectiveUrl(), self.model, body.len, cache.modeFor(.openai).label(), if (self.reasoning_effort) |effort| effort.name() else "default" },
        );
        const uri = std.Uri.parse(self.effectiveUrl()) catch return error.InvalidUrl;

        const req_ptr = try self.allocator.create(http.Client.Request);
        errdefer self.allocator.destroy(req_ptr); // 唯一 destroy:所有错误路径靠它(不手动 destroy,否则 double-free)
        var connection_lease = try connection_gate.acquire(abort);
        defer connection_lease.release();
        // Read with the connection slot held, right before the request opens
        // (see client_mod.Client.doRequest).
        const auth = self.credential.header(self.allocator, self.auth_scheme) catch |err| {
            log.errId("openai", rid, "auth header materialization failed: {s}", .{@errorName(err)});
            return credential_mod.requestError(err);
        };
        defer secureFree(self.allocator, auth.value);
        req_ptr.* = self.http_client.request(.POST, uri, .{
            // 保持禁用陈旧池连接；跨 provider 的 process-wide connection_gate 限制并发握手。
            .keep_alive = false,
            // The key rides in a header; a 3xx is reported, not followed.
            .redirect_behavior = no_redirects,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = auth.name, .value = auth.value },
            },
        }) catch |err| {
            log.errId("openai", rid, "request init failed: {s}", .{@errorName(err)});
            return error.RequestFailed; // req_ptr.* 未初始化, errdefer destroy 即可
        };
        var registered = false;
        errdefer {
            if (registered) self.abort_registry.unregister(req_ptr);
            req_ptr.deinit();
        }
        // 总是登记:abort 路由(有 signal 时)+ 空闲监视(见 client.zig DEFAULT_STREAM_IDLE_TIMEOUT_MS)。
        try self.abort_registry.registerMonitored(
            self.allocator,
            abort,
            req_ptr,
            shutdownRequest,
            self.stream_idle_timeout_ms,
        );
        registered = true;
        req_ptr.transfer_encoding = .{ .content_length = body.len };
        http_connection.sendBodyComplete(req_ptr, @constCast(body)) catch |err| {
            log.errId("openai", rid, "send body failed: {s}", .{@errorName(err)});
            client_mod.noteConnectFailure(err);
            return error.RequestFailed;
        };
        const response = req_ptr.receiveHead(&.{}) catch |err| {
            if (self.abort_registry.stalled(req_ptr)) |stall| {
                client_mod.reportHeadStall("openai", rid, stall);
                return error.TransientNetwork;
            }
            log.errId("openai", rid, "receiveHead failed: {s}", .{@errorName(err)});
            client_mod.noteConnectFailure(err);
            return err;
        };
        const status = ResponseStatus.capture(&response);
        self.last_http_status = status.code;
        self.server_request_id_len = copyMetaskRequestId(&self.server_request_id, response.head.bytes);
        client_mod.noteResponseHead(status.code, response.head, auth.value);
        connection_lease.release();
        if (!status.isOk()) {
            var location_buf: [http_status.REDIRECT_LOCATION_BYTES]u8 = undefined;
            if (http_status.copyRedirectLocation(&response, &location_buf)) |location| {
                client_mod.reportRedirect("openai", rid, status, location);
                return error.RequestFailed;
            }
            var err_body: [4096]u8 = undefined;
            const body_reader = req_ptr.reader.bodyReader(
                err_body[0..],
                response.head.transfer_encoding,
                response.head.content_length,
            );
            const n = body_reader.readSliceShort(err_body[0..]) catch 0;
            const preview = err_body[0..@min(n, err_body.len)];
            log.errId("openai", rid, "HTTP {d} {s}: body={s}", .{ status.code, status.name, preview });
            client_mod.reportHttpFailure(status.code, preview);
            if (status.code == 401 and containsMetaskTokenExpired(preview)) {
                preserve_placeholder_ids = true;
                return error.TokenExpired;
            }
            return error.RequestFailed;
        }
        client_mod.noteRequestAccepted();
        // 响应头已接受 → 正文阶段上限(见 client.zig bodyIdleLimitMs);字节级续命由 LivenessReader 负责。
        self.abort_registry.setIdleLimit(req_ptr, client_mod.bodyIdleLimitMs(self.stream_body_idle_timeout_ms, self.stream_idle_timeout_ms, self.max_tokens), .sse);

        const heap = try self.allocator.create(OpenAIStream);
        heap.* = .{
            .allocator = self.allocator,
            .image_placeholder_ids = image_placeholder_ids,
            .model = self.model,
            .dialect = dialect,
            .protocol = self.protocol,
            .request = req_ptr,
            .response = response,
            .abort = abort,
            .abort_registry = &self.abort_registry,
            .id = rid,
            .http_status = status.code,
            .retry_attempt = retry_attempt,
            .server_request_id = self.server_request_id,
            .server_request_id_len = self.server_request_id_len,
        };
        return heap.handle();
    }
};

fn secureFree(allocator: std.mem.Allocator, buf: []u8) void {
    @memset(buf, 0);
    allocator.free(buf);
}

fn copyMetaskRequestId(dst: *[256]u8, raw_head: []const u8) usize {
    var lines = std.mem.splitSequence(u8, raw_head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "x-metask-request-id")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const n = @min(value.len, dst.len);
        @memcpy(dst[0..n], value[0..n]);
        return n;
    }
    return 0;
}

fn containsMetaskTokenExpired(body: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, body, from, "\"code\"")) |key_pos| {
        var i = key_pos + "\"code\"".len;
        while (i < body.len and std.ascii.isWhitespace(body[i])) : (i += 1) {}
        if (i >= body.len or body[i] != ':') {
            from = i;
            continue;
        }
        i += 1;
        while (i < body.len and std.ascii.isWhitespace(body[i])) : (i += 1) {}
        const value = "\"token_expired\"";
        if (i + value.len <= body.len and std.mem.eql(u8, body[i .. i + value.len], value)) return true;
        from = i + 1;
    }
    return false;
}

test "OpenAI transport captures Metask request id and recognizes only token_expired" {
    var out: [256]u8 = undefined;
    const n = copyMetaskRequestId(&out, "x-METASK-request-id:req-openai\r\n");
    try std.testing.expectEqualStrings("req-openai", out[0..n]);
    try std.testing.expect(containsMetaskTokenExpired("{\"error\":{\"code\": \"token_expired\"}}"));
    try std.testing.expect(!containsMetaskTokenExpired("{\"error\":{\"code\": \"invalid_token\"}}"));
    try std.testing.expect(!containsMetaskTokenExpired("{\"error\":{\"code\": \"invalid_token\",\"message\":\"token_expired\"}}"));
}

/// OpenAI 流式响应:持 Response + transfer buffer + 逐行 SSE 解析状态。包成中立 StreamHandle。
/// 合成 tool_call id 的进程级单调序号(后端漏发 id 时兜底;u64 不 wrap)。
var g_synth_id_serial = std.atomic.Value(u64).init(1);

const OpenAIStream = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    dialect: dialect_mod.Dialect,
    /// wire 协议(chat/completions 或 Responses):parseChunk 据此分派解析路径。
    protocol: types.OpenAIProtocol = .chat_completions,
    request: *http.Client.Request,
    response: http.Client.Response,
    transfer_buf: [8192]u8 = undefined,
    /// 单行 SSE 超出 transfer_buf(8KB)时的溢出累积缓冲(port 自 stream.zig 的 takeLine
    /// 慢路径,同一 16MB 硬上限)。Responses 终止事件(output_text.done / completed /
    /// function_call_arguments.done)携带整段累积 payload——超 8KB 的行是常态而非异常。
    /// 复用同一 ArrayList,每次清空再用;deinit 时释放。
    line_overflow: std.ArrayList(u8) = .empty,
    reader: ?*std.Io.Reader = null,
    /// 字节级活性适配器(见 liveness_reader.zig):首次 next 时包在 body reader 外;heap 分配,地址稳定。
    liveness: liveness_reader.LivenessReader = undefined,
    liveness_buf: [8192]u8 = undefined,
    abort: ?*const AbortSignal = null,
    abort_registry: ?*provider_mod.RequestAbortRegistry = null,
    id: log.RequestId,
    http_status: u16 = 0,
    retry_attempt: u32 = 0,
    server_request_id: [256]u8 = undefined,
    server_request_id_len: usize = 0,
    /// 序列化时走占位的图像 tool_result id(owned),随 StreamHandle 回传。
    image_placeholder_ids: []const []const u8 = &.{},
    done: bool = false,
    /// chat 协议:与内容增量**同 chunk** 到达的 usage(部分兼容端把 usage 挂在末个内容
    /// chunk 上)。parseChunk 一次只能返回一个事件,故先返回内容事件、usage 存这里,
    /// 下一次 next() 经 takeQueued 紧接着吐出。单槽即可:每个 chunk 至多一个 usage
    /// 对象,且槽在读下一行之前必被 takeQueued 清空。
    pending_usage: ?UsageDelta = null,
    /// Responses 协议:终止事件(completed/incomplete)已处理完(有 usage 对象则已发),
    /// flush 队列排空后补发一个 .done(Responses 无 [DONE] 哨兵行)。
    pending_done: bool = false,
    last_stop: StopReason = .unknown,
    /// 流报告过"怎么停的":chat 的非 null `finish_reason`,或 Responses 的终止事件
    /// (completed/incomplete)。与 last_stop 分开——`.unknown` 也可能是"报了个本端不认识
    /// 的值"。没有它就结束的流(EOF 或只有 `[DONE]`)不是收尾:丢的可能正是
    /// `finish_reason:"length"`(issue #269)。
    stop_reported: bool = false,
    // 并行 tool_calls 增量累积(P0.1):OpenAI 流式把每个 tool_call 按 `index` 分槽分块发
    // (id/name 一次,arguments 跨 chunk 拼)。按 index 找槽累积,done 时把每个槽 flush 成一个
    // tool_use_start 事件排队,next() 逐个 drain → executeSlots 收到多 slot 真并发。
    tcs: std.ArrayList(ToolCallAcc) = .empty,
    tc_active: bool = false,
    flush_q: std.ArrayList(StreamEvent) = .empty, // done 时排队的 tool_use_start
    flush_pos: usize = 0,
    flushed: bool = false,
    /// Responses:已回传过的 reasoning item 去重键(owned)。同一 item 会同时出现在
    /// `response.output_item.done` 与终止事件的 `response.output` 里——两处都独立提取
    /// (服务端漏发任一个都不能丢推理状态),靠键去重保证只回传一次。
    /// 键 = item 的 `id`;无 id 时退化为 item 全文。
    reasoning_keys: std.ArrayList([]u8) = .empty,

    fn handle(self: *OpenAIStream) StreamHandle {
        return .{ .ctx = @ptrCast(self), .image_placeholder_ids = self.image_placeholder_ids, .nextFn = &hNext, .deinitFn = &hDeinit, .stopReasonFn = &hStop, .requestIdFn = &hRid, .serverRequestIdFn = &hServerRid, .httpStatusFn = &hHttpStatus, .retryAttemptFn = &hRetryAttempt };
    }
    fn hNext(ctx: *anyopaque) anyerror!?StreamEvent {
        return @as(*OpenAIStream, @ptrCast(@alignCast(ctx))).next();
    }
    fn hDeinit(ctx: *anyopaque) void {
        const s: *OpenAIStream = @ptrCast(@alignCast(ctx));
        const a = s.allocator;
        s.deinit();
        a.destroy(s);
    }
    fn hStop(ctx: *anyopaque) StopReason {
        return @as(*OpenAIStream, @ptrCast(@alignCast(ctx))).last_stop;
    }
    fn hRid(ctx: *anyopaque) log.RequestId {
        return @as(*OpenAIStream, @ptrCast(@alignCast(ctx))).id;
    }
    fn hServerRid(ctx: *anyopaque) []const u8 {
        const s: *OpenAIStream = @ptrCast(@alignCast(ctx));
        return s.server_request_id[0..s.server_request_id_len];
    }
    fn hHttpStatus(ctx: *anyopaque) u16 {
        return @as(*OpenAIStream, @ptrCast(@alignCast(ctx))).http_status;
    }
    fn hRetryAttempt(ctx: *anyopaque) u32 {
        return @as(*OpenAIStream, @ptrCast(@alignCast(ctx))).retry_attempt;
    }

    fn deinit(self: *OpenAIStream) void {
        self.releaseParseState();
        if (self.abort_registry) |registry| registry.unregister(self.request);
        self.request.deinit();
        self.allocator.destroy(self.request);
    }

    /// 释放解析侧状态(累积槽、未 drain 的 flush 事件、去重键、溢出行缓冲),不碰 HTTP
    /// request。deinit 的前半段;单测用固定 reader 直驱 next() 时只走这一半。
    fn releaseParseState(self: *OpenAIStream) void {
        self.allocator.free(self.image_placeholder_ids);
        for (self.tcs.items) |*tc| tc.deinit(self.allocator);
        self.tcs.deinit(self.allocator);
        // 异常拆解时未 drain 的 flush 事件仍持 owned id/name/input_json → 释放,防泄漏。
        for (self.flush_q.items[self.flush_pos..]) |ev| switch (ev) {
            .tool_use_start => |tu| {
                self.allocator.free(tu.id);
                self.allocator.free(tu.name);
                self.allocator.free(tu.input_json);
            },
            .reasoning_item => |bytes| self.allocator.free(bytes),
            else => {},
        };
        self.flush_q.deinit(self.allocator);
        for (self.reasoning_keys.items) |key| self.allocator.free(key);
        self.reasoning_keys.deinit(self.allocator);
        self.line_overflow.deinit(self.allocator);
    }

    /// 读一行(到 '\n',不含)。port 自 stream.zig EventIterator.takeLine——同一机制、同一上限。
    /// 快路径:takeDelimiter 直接借 reader buffer 里的 slice(短行,无分配)。
    /// 慢路径:行超出 transfer_buf(8KB)→ takeDelimiter 报 StreamTooLong,改用
    ///   streamDelimiterLimit 把整行累积到 line_overflow,并在读取过程中执行 16MB 硬上限。
    /// 返回借用 slice(指向 reader buffer 或 self.line_overflow);null = EOF。
    /// 修复(review F1):Responses 终止事件带完整累积 payload,>8KB 的行曾确定性
    /// StreamTooLong → agent_loop 丢弃整轮流式结果并重试(双计费)。chat 与 responses
    /// 协议同走本函数,两条路径一并覆盖。
    fn takeLine(self: *OpenAIStream, r: *std.Io.Reader) !?[]const u8 {
        if (r.takeDelimiter('\n')) |line_opt| {
            if (line_opt) |line| {
                if (line.len > api_stream.MAX_SSE_LINE_BYTES) return error.StreamTooLong;
            }
            return line_opt; // 含 EOF→null 的快路径
        } else |err| switch (err) {
            error.StreamTooLong => {
                // limit 取 max+1:允许恰好 max 字节后紧跟分隔符,同时保证无分隔符的
                // 恶意流最多只累积 max+1(与 stream.zig 同一契约)。
                self.line_overflow.clearRetainingCapacity();
                var alloc_w: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.line_overflow);
                const line_len = r.streamDelimiterLimit(
                    &alloc_w.writer,
                    '\n',
                    .limited(api_stream.MAX_SSE_LINE_BYTES + 1),
                ) catch |e| {
                    self.line_overflow = alloc_w.toArrayList();
                    log.warnId("openai", self.id, "streamDelimiterLimit failed: {s}", .{@errorName(e)});
                    return switch (e) {
                        error.StreamTooLong => error.StreamTooLong,
                        error.ReadFailed => error.ReadFailed,
                        // Allocating.writer 以 Writer.Error 报分配失败;还原 ArrayList
                        // 所有权后,向调用方抛可行动的 allocator 错误。
                        error.WriteFailed => error.OutOfMemory,
                    };
                };
                // streamDelimiterLimit 停在分隔符处(buffer 首字节是 '\n')或 EOF(buffer 空)。
                // 若还有分隔符,吞掉它,让下次从下一行开始。
                if (r.bufferedLen() > 0) r.toss(1);
                self.line_overflow = alloc_w.toArrayList(); // 取回所有权
                if (line_len > api_stream.MAX_SSE_LINE_BYTES) return error.StreamTooLong;
                return self.line_overflow.items;
            },
            else => return err,
        }
    }

    /// 注册表对这条请求的 stall 判定(null = 没被监视线程 shutdown 过,读错误另有原因)。
    fn stalledVerdict(self: *OpenAIStream) ?provider_mod.RequestAbortRegistry.Stall {
        const registry = self.abort_registry orelse return null;
        return registry.stalled(self.request);
    }

    /// 一条非保活 SSE 行 = 模型在产出 → 续正文空闲时钟(ping/注释行不算,见 stream.zig)。
    fn touchProgress(self: *OpenAIStream) void {
        const registry = self.abort_registry orelse return;
        registry.touch(self.request);
    }

    /// 一条保活行(注释 / ping)= 端点在沉默中开口 → 注册表学习保活节奏(见 provider.zig)。
    fn touchKeepalive(self: *OpenAIStream) void {
        const registry = self.abort_registry orelse return;
        registry.touchKeepalive(self.request);
    }

    /// 已排队事件的唯一出口;next() 每次读新行之前先走这里。出队顺序固定:
    ///   1. pending_usage —— 与内容同 chunk 的 usage,紧跟在该 chunk 的内容事件之后;
    ///   2. flush_q       —— 终止时 flush 的 reasoning_item / tool_use_start(按入队顺序);
    ///   3. pending_done  —— Responses 终止后补发的 done。
    /// 1 与 2 不会同时非空:pending_usage 只在 parseChunk 返回内容事件时写入,而下一次
    /// next() 在读任何新行(含触发 flush 的 [DONE]/EOF/终止事件)之前就把它吐掉了。
    /// 所以这个顺序就是 wire 上的到达顺序。
    fn takeQueued(self: *OpenAIStream) ?StreamEvent {
        if (self.pending_usage) |u| {
            self.pending_usage = null;
            return StreamEvent{ .usage = u };
        }
        if (self.flush_pos < self.flush_q.items.len) {
            const ev = self.flush_q.items[self.flush_pos];
            self.flush_pos += 1;
            return ev;
        }
        // Responses 终止事件已处理、flush 已排空 → 补发 done 并收流。
        if (self.pending_done) {
            self.pending_done = false;
            self.done = true;
            return StreamEvent{ .done = {} };
        }
        return null;
    }

    /// 读下一个中立事件。逐行读 SSE,翻译 OpenAI chunk → StreamEvent。
    fn next(self: *OpenAIStream) anyerror!?StreamEvent {
        if (self.takeQueued()) |ev| return ev;
        if (self.done) return null;
        if (self.reader == null) {
            const raw = self.response.reader(&self.transfer_buf);
            // 字节级续命:每次 recv 到字节就 touch——tool_calls 参数增量 chunk 不再是"沉默"。
            // 传输层字节只记"最近字节"时间戳;进展按非保活行续(下方)。
            self.reader = if (self.abort_registry) |registry| blk: {
                self.liveness = liveness_reader.LivenessReader.init(raw, registry, self.request, &self.liveness_buf, .transport_only);
                break :blk &self.liveness.interface;
            } else raw;
        }
        const r = self.reader.?;
        while (true) {
            if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
            // takeLine:快路径 takeDelimiter(借 buffer),>8KB 行走 line_overflow 慢路径。
            const line_opt = self.takeLine(r) catch |err| {
                // 读取/上限失败可能把传输层留在一行中间;置终态,防调用方再 next()
                // 把行尾当新 SSE 帧解析(对齐 stream.zig next 的 fail-terminal 契约)。
                self.done = true;
                // 取消优先:cancel 关掉了 socket,读才失败的——是 Aborted,不是 API 错误。
                if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
                if (self.stalledVerdict()) |stall| {
                    client_mod.reportBodyStall("openai", self.id, stall);
                    return error.StreamStalled;
                }
                log.warnId("openai", self.id, "stream read failed: {s}", .{@errorName(err)});
                return api_stream.midStreamReadError(err);
            };
            const line = line_opt orelse {
                self.done = true;
                // 干净 EOF 而无 [DONE]:cancel 关掉的连接也可能这样醒来——是取消,不是收尾。
                if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
                // 连接若是被监视线程 shutdown 的,这是 stall 而非正常收尾。
                if (self.stalledVerdict()) |stall| {
                    client_mod.reportBodyStall("openai", self.id, stall);
                    return error.StreamStalled;
                }
                // 没报告过停止原因的 EOF:流在说完之前断了(chat 末块 / Responses 终止事件
                // 没到)。报告过则只缺 `[DONE]` 帧尾(与可能跟在后面的 usage 块),回答完整。
                if (!self.stop_reported) return self.incomplete();
                return self.finishFlush();
            };
            // 进展记账:非保活行(含被 continue 掉的 usage/空 chunk)才续正文空闲时钟;
            // 保活行只交给注册表学习端点的保活节奏。
            switch (api_stream.classifyLine(line)) {
                .progress => self.touchProgress(),
                .keepalive => self.touchKeepalive(),
                .separator => {},
            }
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const data = std.mem.trim(u8, trimmed[5..], " ");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.done = true;
                // `[DONE]` 只是帧尾,不证明回答说完:携带 finish_reason 的末块(或 Responses
                // 终止事件)丢了时,它照样到达(issue #269 的 chat 形状)。
                if (!self.stop_reported) return self.incomplete();
                if (self.finishFlush()) |ev| return ev;
                return StreamEvent{ .done = {} };
            }
            if (try self.parseChunk(data)) |ev| return ev;
            // 该 chunk 无可 emit 事件(纯 tool_call 增量累积)→ 继续读下一行。
        }
    }

    /// 解析一个 OpenAI SSE data chunk。返回可 emit 的中立事件,或 null(增量累积中)。
    fn parseChunk(self: *OpenAIStream, data: []const u8) !?StreamEvent {
        // Responses API 走 typed 事件解析路径(chat/completions 的启发式对它不适用)。
        if (self.protocol == .responses) return self.parseResponsesChunk(data);
        // takeQueued 在读本行之前已清空槽(见其注释);这里写入前它必为空。
        std.debug.assert(self.pending_usage == null);
        // OpenAI 兼容端(OpenRouter 等)在流中途报错的形状:`data: {"error":{...}}`,没有 choices。
        // 旧实现把它当空 chunk 跳过,流随后没报告停止原因就结束 → StreamIncomplete,服务端的
        // 答复被当成断流。现在按服务端声明的失败上抛。
        if (util_json.topLevelObjectField(data, "error")) |err_obj| {
            self.done = true;
            client_mod.reportServerError("openai", self.id, err_obj);
            return error.ApiError;
        }
        // usage 只在**值为 object** 时存在(见 chatUsageObject)。include_usage 下每个普通
        // chunk 都带 `"usage":null`——旧实现按 substring `"usage"` 判存在并立即 return,
        // 把这些 chunk 的文本/推理/tool_call 增量/finish_reason 全部吞掉(issue #258)。
        const usage: ?UsageDelta = if (chatUsageObject(data)) |obj| chatUsageDelta(obj) else null;
        // 内容侧照常处理。同 chunk 既有内容事件又有 usage 对象时,两个都发且顺序固定:
        // 先内容、后 usage(存 pending_usage,下一次 next() 经 takeQueued 吐出)。
        // tool_call 增量本身不产事件(终止时才 flush),故"tool_calls + usage 同 chunk"时
        // usage 直接返回,先于对应的 tool_use_start。
        if (try self.parseChatDelta(data)) |ev| {
            self.pending_usage = usage;
            return ev;
        }
        if (usage) |u| return StreamEvent{ .usage = u };
        return null;
    }

    /// chat chunk 的内容侧:finish_reason、content、reasoning(方言)、tool_calls 增量。
    /// 返回至多一个内容事件(text/thinking),或 null(无可 emit 内容 / 增量累积中)。
    fn parseChatDelta(self: *OpenAIStream, data: []const u8) !?StreamEvent {
        // finish_reason → StopReason(末 chunk)。
        if (util_json.extractStringField(data, "finish_reason")) |fr| {
            // 空串与 null 同义:部分兼容端在中间块里发 `"finish_reason":""`,它不是停止报告。
            if (fr.len > 0 and !std.mem.eql(u8, fr, "null")) {
                self.last_stop = mapFinish(fr);
                self.stop_reported = true;
            }
        }
        // delta.content → text。OpenAI: {"choices":[{"delta":{"content":"hi"},...}]}
        // SSE string 片段带一层 JSON 转义(\n/\"/\uXXXX):必须解除后再交对话/UI,
        // 否则转义序列以字面量进入 assistant 文本(issue #4)。空片段 free 不发事件。
        // 已知局限(review F3 登记):文本走逐片段解码,`\uXXXX` 代理对若被 chunk 边界
        // 拆开会变两个 U+FFFD——修复需跨 chunk 解码状态;arguments 有缓冲故已修,文本暂不。
        if (try util_json.extractAndUnescapeStringField(data, "content", self.allocator)) |content| {
            if (content.len > 0) return StreamEvent{ .text = content };
            self.allocator.free(content);
        }
        // delta.reasoning_content → thinking(DeepSeek/Kimi/Qwen/GLM-5)。
        // OpenAI 原生不返回此字段(仅 reasoning_tokens 计数);兼容端点把它作为平级字符串返回。
        // 委托给 dialect(按 model 选解析逻辑;OpenAI 原生 dialect 返 null)。
        if (try self.dialect.extractThinkingDelta(data, self.allocator)) |reasoning| {
            if (reasoning.len > 0) {
                return StreamEvent{ .thinking = reasoning };
            }
            self.allocator.free(reasoning);
        }
        // delta.tool_calls 增量(P0.1 并行):按 `index` 分槽累积。OpenAI 流式对每个并行 tool_call
        // 用独立 index;同一 chunk 的 tool_calls array 可含多个元素,元素跨 chunk 续拼 arguments。
        // 逐元素定位/新建对应 index 的槽,追加 id/name/arguments 片段。done 时全部 flush。
        if (findToolCallsArray(data)) |arr| {
            self.tc_active = true;
            var it = ElemIter{ .s = arr };
            while (it.next()) |elem| {
                const idx = util_json.extractIntField(elem, "index"); // OpenAI 恒发 index;缺失→0
                const acc = self.accFor(idx) catch continue;
                // id:整个 tool_call 只发一次;仅在本槽尚未填时写(防重复拼接)。
                if (util_json.extractStringField(elem, "id")) |id| {
                    if (id.len > 0 and acc.id.items.len == 0) acc.id.appendSlice(self.allocator, id) catch {};
                }
                // name = function.name(元素内首个 "name");arguments = function.arguments 片段。
                if (util_json.extractStringField(elem, "name")) |name| {
                    acc.name.appendSlice(self.allocator, name) catch {};
                }
                // arguments 片段按**原始转义字节**拼接,flush 时一次解码(decode-once,
                // 见 buildFlush):片段可在 `\uXXXX` 代理对中间断开,逐片段解码会把拆开
                // 的高/低代理各变成一个 U+FFFD(review F3)。
                if (util_json.extractRawStringField(elem, "arguments")) |args| {
                    try acc.args.appendSlice(self.allocator, args);
                }
            }
        }
        return null;
    }

    /// 解析一个 Responses API SSE data chunk(typed 事件:`"type":"response.xxx"`)。
    /// 返回可 emit 的中立事件,或 null(增量累积/被忽略的事件类型)。
    /// 未识别的事件类型一律忽略(向前兼容:服务端新增事件不破坏既有流)。
    fn parseResponsesChunk(self: *OpenAIStream, data: []const u8) !?StreamEvent {
        const ev_type = extractResponsesEventType(data) orelse return null;
        // 文本增量:{"type":"response.output_text.delta","delta":"..."}。
        // delta 是 JSON string 片段 → 解除一层转义(同 chat content 分支);空片段 free 不发。
        // 已知局限(同 chat content,review F3):逐片段解码,拆开的代理对会变 U+FFFD。
        if (std.mem.eql(u8, ev_type, "response.output_text.delta")) {
            if (try util_json.extractAndUnescapeStringField(data, "delta", self.allocator)) |text| {
                if (text.len > 0) return StreamEvent{ .text = text };
                self.allocator.free(text);
            }
            return null;
        }
        // 新 output item:function_call item 携带完整 call_id + name(arguments 后续增量发)。
        // 按 output_index 分槽累积(对齐 chat 的 tool_calls index 分槽)。
        if (std.mem.eql(u8, ev_type, "response.output_item.added")) {
            const item = findObjectField(data, "item") orelse return null;
            const item_type = util_json.extractStringField(item, "type") orelse return null;
            if (!std.mem.eql(u8, item_type, "function_call")) return null;
            self.tc_active = true;
            const acc = self.accFor(util_json.extractIntField(data, "output_index")) catch return null;
            // call_id/name 每 item 只发一次;仅在本槽尚未填时写(防重复拼接,同 chat ~id 守卫)。
            if (util_json.extractStringField(item, "call_id")) |id| {
                if (id.len > 0 and acc.id.items.len == 0) acc.id.appendSlice(self.allocator, id) catch {};
            }
            if (util_json.extractStringField(item, "name")) |name| {
                if (name.len > 0 and acc.name.items.len == 0) acc.name.appendSlice(self.allocator, name) catch {};
            }
            return null;
        }
        // 完整 output item。`store:false` 下服务端不保存响应,推理上下文只能由客户端
        // 逐字节回传(OpenAI "preserve reasoning without stored responses"),故这里把
        // reasoning item 原样捕获。function_call 的完整 arguments 走 *_arguments.done,
        // 本分支不重复处理。
        if (std.mem.eql(u8, ev_type, "response.output_item.done")) {
            const item = findObjectFieldRaw(data, "item") orelse return null;
            if (!itemTypeIs(item, "reasoning")) return null;
            return self.takeReasoningItem(item);
        }
        // arguments 增量:片段按**原始转义字节**按槽拼接,flush 时一次解码(同 chat
        // arguments 的 decode-once 契约,见 buildFlush;review F3 拆代理对场景)。
        if (std.mem.eql(u8, ev_type, "response.function_call_arguments.delta")) {
            if (util_json.extractRawStringField(data, "delta")) |args| {
                const acc = self.accFor(util_json.extractIntField(data, "output_index")) catch return null;
                try acc.args.appendSlice(self.allocator, args);
            }
            return null;
        }
        // arguments 终值:done 事件携带完整 arguments(authoritative)——整体覆盖已拼片段,
        // 漏发/重发 delta 都不会造成错拼。同样存原始转义字节,flush 时一次解码。
        if (std.mem.eql(u8, ev_type, "response.function_call_arguments.done")) {
            if (util_json.extractRawStringField(data, "arguments")) |args| {
                const acc = self.accFor(util_json.extractIntField(data, "output_index")) catch return null;
                acc.args.clearRetainingCapacity();
                try acc.args.appendSlice(self.allocator, args);
            }
            return null;
        }
        // 正常终止:usage + stop 归一 + flush tool_call 槽 + 排队 done(Responses 无 [DONE] 行)。
        if (std.mem.eql(u8, ev_type, "response.completed")) {
            self.last_stop = if (self.tc_active) .tool_use else .end_turn;
            self.stop_reported = true;
            return self.finishResponsesTerminal(data);
        }
        // 截断终止:incomplete_details.reason=max_output_tokens → .max_tokens,其余 .unknown。
        if (std.mem.eql(u8, ev_type, "response.incomplete")) {
            self.last_stop = if (util_json.extractStringField(data, "reason")) |reason|
                (if (std.mem.eql(u8, reason, "max_output_tokens")) StopReason.max_tokens else .unknown)
            else
                .unknown;
            self.stop_reported = true;
            return self.finishResponsesTerminal(data);
        }
        // 失败终止(response.failed)/流级 error 事件:服务端声明的失败 → ApiError(不是断连,
        // agent_loop 不兜底重发;见 stream.zig midStreamReadError 的名字约定)。
        if (std.mem.eql(u8, ev_type, "response.failed") or std.mem.eql(u8, ev_type, "error")) {
            const response = util_json.topLevelObjectField(data, "response") orelse data;
            const err_obj = util_json.topLevelObjectField(response, "error") orelse
                util_json.topLevelObjectField(data, "error") orelse data;
            self.done = true;
            client_mod.reportServerError("openai", self.id, err_obj);
            return error.ApiError;
        }
        return null; // 其它 typed 事件(created/in_progress/output_text.done 等):忽略
    }

    /// Responses 终止事件(completed/incomplete)公共尾:usage 归一 + flush + 排队 done。
    /// 事件顺序:usage(仅当 `response.usage` 是 object)→ reasoning_item → tool_use_start → done。
    fn finishResponsesTerminal(self: *OpenAIStream, data: []const u8) ?StreamEvent {
        // 先排 reasoning item、后排 tool_use_start:next() 按入队顺序 drain,消费者
        // 因此在拿到工具调用之前就收齐了本轮的推理状态。
        self.queueTerminalReasoningItems(data);
        self.buildFlush();
        self.flushed = true;
        self.pending_done = true;
        if (responsesUsageObject(data)) |usage_obj| return StreamEvent{ .usage = responsesUsageDelta(usage_obj) };
        // 无 usage 对象(缺失或 `"usage":null`):不伪造全零 usage——那会把"未计量"
        // 报成"已计量为 0"(cache_break.ResponseUsage.reported)。直接吐队首事件。
        return self.takeQueued();
    }

    /// 终止事件的 `response.output` 全量数组:补上任何没经 `output_item.done` 到达的
    /// reasoning item。已回传过的按键跳过,故"两个事件都带同一 item"只产出一次,
    /// 且不依赖某个特定事件一定出现。
    fn queueTerminalReasoningItems(self: *OpenAIStream, data: []const u8) void {
        const response_obj = findObjectField(data, "response") orelse return;
        const output = findArrayField(response_obj, "output") orelse return;
        var it = ElemIter{ .s = output };
        while (it.next()) |elem| {
            if (!itemTypeIs(elem, "reasoning")) continue;
            const ev = self.takeReasoningItem(elem) orelse continue;
            self.flush_q.append(self.allocator, ev) catch self.allocator.free(ev.reasoning_item);
        }
    }

    /// 把一条完整的 reasoning item(含花括号)转成 owned 事件;已回传过则返 null。
    /// 分配失败退化为"本项不回传"(推理续传是尽力而为的优化,绝不因它中断流),
    /// 但**留痕**——静默降级回修复前的行为是不可接受的。
    fn takeReasoningItem(self: *OpenAIStream, item: []const u8) ?StreamEvent {
        // 去重键取 item 的 `id`。这里用首次匹配是安全的:reasoning item 的嵌套结构
        // 只有 `summary[]`,其元素带 `type`/`text` 而没有 `id`;真出现别的形态时
        // 首次匹配也只会退化成"键更长",不会把两条不同的 item 判成同一条。
        // 无 id 时退化为整条 item 全文做键。
        const key = util_json.extractStringField(item, "id") orelse item;
        for (self.reasoning_keys.items) |seen| {
            if (std.mem.eql(u8, seen, key)) return null;
        }
        const owned_item = self.allocator.dupe(u8, item) catch return self.noteReasoningDropped();
        const owned_key = self.allocator.dupe(u8, key) catch {
            self.allocator.free(owned_item);
            return self.noteReasoningDropped();
        };
        self.reasoning_keys.append(self.allocator, owned_key) catch {
            self.allocator.free(owned_item);
            self.allocator.free(owned_key);
            return self.noteReasoningDropped();
        };
        return StreamEvent{ .reasoning_item = owned_item };
    }

    fn noteReasoningDropped(self: *OpenAIStream) ?StreamEvent {
        log.warnId("openai", self.id, "reasoning item dropped (allocation failed); continuity for this turn is lost", .{});
        return null;
    }

    /// 按 index 找累积槽,没有则新建。返回稳定指针(ToolCallAcc 的三个 ArrayList 后备内存在堆,
    /// tcs 扩容搬移结构体不影响其后备指针)。
    fn accFor(self: *OpenAIStream, idx: u64) !*ToolCallAcc {
        for (self.tcs.items) |*tc| if (tc.index == idx) return tc;
        try self.tcs.append(self.allocator, .{ .index = idx });
        return &self.tcs.items[self.tcs.items.len - 1];
    }

    /// done 时:把每个累积槽 flush 成一个 tool_use_start 事件排队(仅 name 非空的);之后
    /// next() 逐个 drain。**所有权契约(对齐 Anthropic stream)**:id/name/input_json 是 owned
    /// slice,agent_loop 接管(不 dupe,随 tool_uses 释放),故 toOwnedSlice 转移所有权。
    fn buildFlush(self: *OpenAIStream) void {
        const a = self.allocator;
        for (self.tcs.items) |*tc| {
            if (tc.name.items.len == 0) continue; // 无 name = 不完整,跳过
            var id = tc.id.toOwnedSlice(a) catch continue;
            if (id.len == 0) {
                // 后端漏发 id → 空串会当 dispatch_id 流进观察日志/审计,
                // trace.py 对空 id fail-closed 且同轮多工具全空必撞重复
                // (2026-08-17 复审发射侧 #1 的 OpenAI 变体)。合成进程级唯一 id。
                a.free(id);
                const serial = g_synth_id_serial.fetchAdd(1, .monotonic);
                id = std.fmt.allocPrint(a, "call_{s}_{d}", .{ self.id.asSlice(), serial }) catch continue;
            }
            const name = tc.name.toOwnedSlice(a) catch {
                a.free(id);
                continue;
            };
            // decode-once(review F3):槽里是原始转义片段的拼接(arguments 自身是装在
            // string 里的 JSON 文档,恰好一层外层转义)。此处一次性解码——更早逐片段解码
            // 会毁掉跨 chunk 拆开的 `\uXXXX` 代理对;不解码则任何 string 参数以非法
            // JSON 进工具层。
            const args = if (tc.args.items.len > 0) blk: {
                const decoded = util_json.unescapeString(tc.args.items, a) catch {
                    a.free(id);
                    a.free(name);
                    continue;
                };
                tc.args.clearAndFree(a);
                break :blk decoded;
            } else (a.dupe(u8, "{}") catch {
                a.free(id);
                a.free(name);
                continue;
            });
            self.flush_q.append(a, StreamEvent{ .tool_use_start = .{ .id = id, .name = name, .input_json = args } }) catch {
                a.free(id);
                a.free(name);
                a.free(args);
            };
        }
    }

    /// 流在报告停止原因之前结束:置终态、留现场、上抛。累积中的 tool_call 槽不 flush——
    /// 没收尾的参数可能残缺,调用方本来也要丢弃整段残片重发(deinit 释放这些槽)。
    /// 取消与 stall 优先:被 cancel / 监视线程关掉的连接,缓冲里剩下的 `[DONE]` 或随后
    /// 的 EOF 都只是它们的症状(issue #269 review)。
    fn incomplete(self: *OpenAIStream) error{ StreamIncomplete, Aborted, StreamStalled } {
        self.done = true;
        if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
        if (self.stalledVerdict()) |stall| {
            client_mod.reportBodyStall("openai", self.id, stall);
            return error.StreamStalled;
        }
        client_mod.reportStreamIncomplete("openai", self.id);
        return error.StreamIncomplete;
    }

    /// 构建(一次)并返回队列里下一个 flush 事件;耗尽返 null。
    fn finishFlush(self: *OpenAIStream) ?StreamEvent {
        if (!self.flushed) {
            if (self.tc_active) self.buildFlush();
            self.flushed = true;
        }
        if (self.flush_pos < self.flush_q.items.len) {
            const ev = self.flush_q.items[self.flush_pos];
            self.flush_pos += 1;
            return ev;
        }
        return null;
    }
};

fn shutdownRequest(raw: *anyopaque) void {
    const request: *http.Client.Request = @ptrCast(@alignCast(raw));
    provider_mod.abortHttpRequest(request);
}

/// 单个并行 tool_call 的按-index 累积槽。
const ToolCallAcc = struct {
    index: u64,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
    fn deinit(self: *ToolCallAcc, a: std.mem.Allocator) void {
        self.id.deinit(a);
        self.name.deinit(a);
        self.args.deinit(a);
    }
};

/// 一个 output item 的 `type` 是否等于 `want`。**按值过滤逐个 `"type"`**,而不是
/// `extractStringField` 的首次匹配:reasoning item 的 `summary[]` 元素自己也带
/// `type`("summary_text"),服务端一旦把 summary 排在前面,首次匹配就会静默把整条
/// 推理续传状态丢掉——本文件已经因为同一条假设翻过一次车(见 extractResponsesEventType
/// 的 review F4 注释)。JSON 字符串值里的引号必转义,故嵌套字符串内容撞不上这里的
/// `"type"` 键模式;要匹配的值集合(reasoning/function_call)也与 summary_text 不重叠。
fn itemTypeIs(item: []const u8, want: []const u8) bool {
    var rest: []const u8 = item;
    while (util_json.extractStringField(rest, "type")) |value| {
        if (std.mem.eql(u8, value, want)) return true;
        const value_end = (@intFromPtr(value.ptr) - @intFromPtr(rest.ptr)) + value.len;
        rest = rest[value_end..];
    }
    return false;
}

/// 定位 `"tool_calls":` 后的 array(见 findArrayField)。
fn findToolCallsArray(data: []const u8) ?[]const u8 {
    return findArrayField(data, "tool_calls");
}

/// 定位 `"<key>":` 后的 array,返回 `[` 与配对 `]` 之间的内容(深度感知,跳字符串)。
/// 分块未闭合(部分 chunk)时返回剩余部分。找不到返 null。
fn findArrayField(data: []const u8, key_name: []const u8) ?[]const u8 {
    var pattern_buf: [64]u8 = undefined;
    if (key_name.len + 3 > pattern_buf.len) return null;
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..key_name.len], key_name);
    pattern_buf[1 + key_name.len] = '"';
    pattern_buf[2 + key_name.len] = ':';
    const key = pattern_buf[0 .. key_name.len + 3];
    const start = std.mem.indexOf(u8, data, key) orelse return null;
    var i = start + key.len;
    while (i < data.len and data[i] != '[') : (i += 1) {}
    if (i >= data.len) return null;
    const arr_open = i;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return data[arr_open + 1 .. i];
            },
            else => {},
        }
    }
    return data[arr_open + 1 ..]; // 未闭合:返回剩余
}

/// Responses 事件类型提取(review F4):取首个值以 "response." 开头(或恰为流级
/// "error")的 `"type"`。单纯取首个 `"type"` 依赖服务端把顶层 type 序列化在 item 之前
/// ——若 item 在前,会命中嵌套的 item.type("function_call" 等),整个事件被当未知类型
/// 丢弃。事件类型词表全部带 "response." 前缀、流级错误恰为 "error",而 item.type 和
/// 合法 JSON 的 string 内容(引号必转义)都不可能撞上这两种形态——按值过滤等价于
/// top-level 扫描,且对字段顺序不敏感。
fn extractResponsesEventType(data: []const u8) ?[]const u8 {
    var rest: []const u8 = data;
    while (util_json.extractStringField(rest, "type")) |v| {
        if (std.mem.startsWith(u8, v, "response.") or std.mem.eql(u8, v, "error")) return v;
        // 命中嵌套 type:跳过该值,从其后继续扫(每轮严格前进,必终止)。
        const value_end = (@intFromPtr(v.ptr) - @intFromPtr(rest.ptr)) + v.len;
        rest = rest[value_end..];
    }
    return null;
}

/// 定位 `"<key>":` 后的 object,返回 `{` 与配对 `}` 之间的内容(深度感知,跳字符串;
/// 与 findArrayField 同扫描风格,只是括号换成花括号)。分块未闭合时返回剩余部分。
/// 找不到 key 或值不是 object 返 null。
fn findObjectField(data: []const u8, key: []const u8) ?[]const u8 {
    const span = findObjectFieldSpan(data, key) orelse return null;
    return data[span.inner_start..span.inner_end];
}

/// 同 findObjectField,但返回**含两端花括号**的整块 object。reasoning item 必须
/// 逐字节原样回传给服务端,不能只拿内容再自行拼括号。
fn findObjectFieldRaw(data: []const u8, key: []const u8) ?[]const u8 {
    const span = findObjectFieldSpan(data, key) orelse return null;
    if (!span.closed) return null; // 未闭合的分块 object 不是可回传的完整 item
    return data[span.inner_start - 1 .. span.inner_end + 1];
}

const ObjectSpan = struct { inner_start: usize, inner_end: usize, closed: bool };

fn findObjectFieldSpan(data: []const u8, key: []const u8) ?ObjectSpan {
    var pattern_buf: [64]u8 = undefined;
    if (key.len + 3 > pattern_buf.len) return null;
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..key.len], key);
    pattern_buf[1 + key.len] = '"';
    pattern_buf[2 + key.len] = ':';
    const pattern = pattern_buf[0 .. key.len + 3];
    const start = std.mem.indexOf(u8, data, pattern) orelse return null;
    var i = start + pattern.len;
    while (i < data.len and data[i] != '{') : (i += 1) {}
    if (i >= data.len) return null;
    const obj_open = i;
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .inner_start = obj_open + 1, .inner_end = i, .closed = true };
            },
            else => {},
        }
    }
    // 未闭合:返回剩余(与 findArrayField 同款分块容忍)。
    return .{ .inner_start = obj_open + 1, .inner_end = data.len, .closed = false };
}

/// 迭代 JSON array slice 里的顶层 `{...}` 对象(深度感知,跳字符串)。
const ElemIter = struct {
    s: []const u8,
    i: usize = 0,
    fn next(self: *ElemIter) ?[]const u8 {
        while (self.i < self.s.len and self.s[self.i] != '{') : (self.i += 1) {}
        if (self.i >= self.s.len) return null;
        const obj_start = self.i;
        var depth: i32 = 0;
        var in_str = false;
        var esc = false;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (in_str) {
                if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        self.i += 1;
                        return self.s[obj_start..self.i];
                    }
                },
                else => {},
            }
        }
        const rest = self.s[obj_start..];
        self.i = self.s.len;
        return rest; // 未闭合元素(部分 chunk)
    }
};

fn mapFinish(fr: []const u8) StopReason {
    if (std.mem.eql(u8, fr, "stop")) return .end_turn;
    if (std.mem.eql(u8, fr, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, fr, "length")) return .max_tokens;
    return .unknown;
}

/// chat chunk 携带的 usage 对象(含两端花括号,借用 data);没有则 null。
/// 只认**值为 JSON object** 的 `usage` 成员,按位置优先级:
///   1. 顶层 `usage`——OpenAI include_usage 的规范位置(末尾 `{"choices":[],"usage":{...}}`,
///      部分兼容端挂在末个内容 chunk 上);
///   2. 否则 `choices[i].usage`——部分兼容端(如 Moonshot)把末块 usage 放进 choice。
///      旧实现的 substring 判定碰巧也接住了这种形态,保留以免回退。
/// `"usage":null`(include_usage 下每个普通 chunk 的常态)、缺失、非 object 值、只出现在
/// 字符串内容里(如 delta.content 恰为 "usage")都不算——issue #258。
fn chatUsageObject(data: []const u8) ?[]const u8 {
    if (util_json.topLevelObjectField(data, "usage")) |obj| return obj;
    const choices = util_json.topLevelField(data, "choices") orelse return null;
    if (choices[0] != '[') return null;
    var it = ElemIter{ .s = choices[1 .. choices.len - 1] };
    while (it.next()) |choice| {
        if (util_json.topLevelObjectField(choice, "usage")) |obj| return obj;
    }
    return null;
}

/// OpenAI chat usage 对象 → 中立 UsageDelta。数值只从 usage 对象本身读,不扫整个 chunk。
/// 语义归一(Anthropic-exclusive):OpenAI 的 prompt_tokens **包含** cached_tokens
/// (prompt_tokens_details 下,经 cache.parseOpenAICacheUsage),中立 UsageDelta 约定
/// input_tokens 不含 cache。消费方(usage 锚点/成本累计)按 in+cache_r+cache_w 求和——
/// 不减会把缓存双计。`"prompt_tokens":` 含闭引号+冒号,不会命中 `prompt_tokens_details`。
/// Read a required non-negative integer from a usage object without collapsing
/// a missing or non-numeric value to zero. Optional cache counters keep their
/// historical absent-is-zero behavior; prompt/completion counters are the
/// contract's required pair, so an unreadable one makes the whole sample
/// unavailable and lets the caller preserve `metering:unknown`.
fn chatUsageDelta(usage_obj: []const u8) ?UsageDelta {
    const prompt_tokens = usageIntField(usage_obj, "prompt_tokens") orelse return null;
    const completion_tokens = usageIntField(usage_obj, "completion_tokens") orelse return null;
    const cu = cache.parseOpenAICacheUsage(usage_obj);
    return .{
        .input_tokens = prompt_tokens -| cu.read_tokens,
        .output_tokens = completion_tokens,
        .cache_read_input_tokens = cu.read_tokens,
        .cache_creation_input_tokens = cu.creation_tokens, // OpenAI 无写区分 → 0
    };
}

/// `extractIntField` intentionally returns zero for missing/unreadable values,
/// which is useful for tolerant metadata but loses the accounting distinction
/// between an explicit zero and an unavailable counter. OpenAI chat usage needs
/// that distinction at its provider boundary.
fn usageIntField(usage_obj: []const u8, field: []const u8) ?u64 {
    const raw = util_json.topLevelField(usage_obj, field) orelse return null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

/// Responses 终止事件的 `response.usage` 对象(含两端花括号,借用 data);缺失或非 object
/// (如 `"usage":null`)→ null。只在规范位置找:终止事件的 `response` 还回显 tools(参数
/// schema 可能恰有名为 input_tokens 的属性)、instructions 等,扫整个事件会读错数。
fn responsesUsageObject(data: []const u8) ?[]const u8 {
    const response = util_json.topLevelObjectField(data, "response") orelse return null;
    return util_json.topLevelObjectField(response, "usage");
}

/// Responses usage 对象 → 中立 UsageDelta(归一同 chatUsageDelta:input_tokens **包含**
/// input_tokens_details.cached_tokens,减掉防双计)。`"input_tokens":` 含闭引号+冒号,
/// 不会命中 `"input_tokens_details"`。
fn responsesUsageDelta(usage_obj: []const u8) UsageDelta {
    const cached = util_json.extractIntField(usage_obj, "cached_tokens");
    return .{
        .input_tokens = util_json.extractIntField(usage_obj, "input_tokens") -| cached,
        .output_tokens = util_json.extractIntField(usage_obj, "output_tokens"),
        .cache_read_input_tokens = cached,
        .cache_creation_input_tokens = 0, // Responses 无写区分 → 0
    };
}

/// 中立 Conversation/tools → OpenAI chat/completions 请求 body。caller free。
/// 按 model 查 ModelProfile 决定 thinking wire 格式(GLM prompt 标签 / K3 extra_body / DeepSeek 顶层 / OpenAI effort)。
/// tool_choice 由 dialect.serializeToolChoice 翻译成 OpenAI wire(Anthropic 语义→OpenAI 语义)。
pub fn serializeOpenAIRequest(allocator: std.mem.Allocator, model: []const u8, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, reasoning_effort: ?types.ReasoningEffort, tool_choice: ?json_mod.ToolChoice) ![]u8 {
    // Legacy 签名 wrapper:把散落的 reasoning_effort + tool_choice 包成 RequestOverrides
    // 转给 serializeOpenAIRequestWithOverrides。保留向后兼容(既有测试/调用方不动)。
    return serializeOpenAIRequestWithOverrides(allocator, model, messages, system, tools, .{
        .reasoning_effort = reasoning_effort,
        .tool_choice = tool_choice,
    });
}

/// 完整方言字段入口的序列化(阶段 3:接线 dead code)。
/// overrides 非 null 字段 = 显式覆盖;null 字段 = dialect 按 profile 静态推断(现状)。
/// 来源:计划 jolly-glacier(2026-08-11)。
pub fn serializeOpenAIRequestWithOverrides(allocator: std.mem.Allocator, model: []const u8, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, overrides: request_overrides.RequestOverrides) ![]u8 {
    return serializeOpenAIRequestWithOverridesAndDialect(
        allocator,
        model,
        messages,
        system,
        tools,
        overrides,
        dialect_mod.dialectFor(.openai, model),
    );
}

pub fn serializeOpenAIRequestWithOverridesAndDialect(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const json_mod.ToolDefinition,
    overrides: request_overrides.RequestOverrides,
    dialect: dialect_mod.Dialect,
) ![]u8 {
    var scratch = json_mod.SerializationReport{};
    defer scratch.deinit(allocator);
    return serializeOpenAIRequestWithOverridesAndDialectReport(allocator, model, messages, system, tools, overrides, dialect, &scratch);
}

/// 同上,并把图像 tool_result 的实际序列化决定写入 `report`(见 request.SerializationReport)。
pub fn serializeOpenAIRequestWithOverridesAndDialectReport(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const json_mod.ToolDefinition,
    overrides: request_overrides.RequestOverrides,
    dialect: dialect_mod.Dialect,
    report: *json_mod.SerializationReport,
) ![]u8 {
    const profile = dialect.profileFor(.openai, model);
    const visible_capabilities = dialect_mod.visibleCapabilities(tools);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"model\":");
    try util_json.serializeString(model, &out, allocator);
    // thinking 控制:委托给 dialect(按 model 选 wire 格式)。
    try dialect.serializeThinking(profile, overrides.reasoning_effort, &out, allocator);
    // 通用采样参数(不经 dialect,所有 OpenAI 协议都认)。
    if (overrides.temperature) |t| {
        try out.appendSlice(allocator, ",\"temperature\":");
        try util_json.serializeNumber(t, &out, allocator);
    }
    if (overrides.top_p) |p| {
        try out.appendSlice(allocator, ",\"top_p\":");
        try util_json.serializeNumber(p, &out, allocator);
    }
    // stream_options.include_usage=true:OpenAI 默认流式不发 usage,显式要求才在末尾发一个
    // {choices:[],usage:{...}} chunk。缓存命中(cached_tokens)就在这个 usage 里。
    try out.appendSlice(allocator, ",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    var first = true;
    // system → 首条 {role:"system"}。The dialect receives an exact typed
    // projection of this request's tool surface before bytes are serialized.
    var sys_buf: std.ArrayList(u8) = .empty;
    defer sys_buf.deinit(allocator);
    if (system) |sys| try sys_buf.appendSlice(allocator, sys);
    try dialect.injectSystemMods(profile, overrides.reasoning_effort, &sys_buf, allocator);
    try dialect.activateCapabilities(
        profile,
        visible_capabilities,
        &sys_buf,
        allocator,
    );
    if (sys_buf.items.len != 0) {
        try out.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try util_json.serializeString(sys_buf.items, &out, allocator);
        try out.append(allocator, '}');
        first = false;
    }
    for (messages) |m| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try serializeOpenAIMessage(allocator, &out, m, dialect, profile, report);
    }
    try out.append(allocator, ']');
    // tools → OpenAI function 形态
    if (tools) |tl| {
        if (tl.len > 0) {
            try out.appendSlice(allocator, ",\"tools\":[");
            for (tl, 0..) |t, i| {
                if (i > 0) try out.append(allocator, ',');
                try serializeOpenAITool(allocator, &out, t);
            }
            try out.append(allocator, ']');
        }
    }
    // tool_choice:委托给 dialect(按 model 翻译 + 能力降级 GLM-5)。
    const route_already_invoked = if (visible_capabilities.required_first) |route|
        route.satisfied or dialect_mod.hasSuccessfulRequiredFirst(messages, route)
    else
        false;
    const effective_tool_choice = dialect.routeToolChoice(
        profile,
        visible_capabilities,
        route_already_invoked,
        overrides.tool_choice,
    );
    if (effective_tool_choice) |tc| {
        _ = try dialect.serializeToolChoice(profile, tc, &out, allocator);
    }
    // response_format:阶段 3 接线(此前 dead code)。能力守门在 dialect 内(GLM-5 json_schema→json_object)。
    if (overrides.response_format) |rf| {
        _ = try dialect.serializeResponseFormat(profile, rf, &out, allocator);
    }
    // prompt_cache_key:阶段 3 接线。能力守门(supports_prompt_cache_key=false 的 dialect 返 false 不发)。
    if (overrides.prompt_cache_key) |key| {
        _ = try dialect.serializePromptCacheKey(profile, key, &out, allocator);
    }
    // parallel_tool_calls:阶段 3 接线。能力守门(supports_parallel_tool_calls=false 的 dialect 返 false 不发)。
    if (overrides.parallel_tool_calls) |b| {
        _ = try dialect.serializeParallelToolCalls(profile, b, &out, allocator);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn serializeOpenAIMessage(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    m: types.ApiMessage,
    dialect: dialect_mod.Dialect,
    profile: dialect_mod.ModelProfile,
    report: *json_mod.SerializationReport,
) !void {
    // 收集 text / tool_use / tool_result。OpenAI:assistant 的 tool_use → tool_calls;
    // tool_result → 独立 {role:"tool"} 消息。MVP:每个 tool_result 拆成单独 message。
    // 简化:先处理 tool_result(它要 role:"tool"),再处理 text+tool_use 的 user/assistant 消息。
    var has_tool_result = false;
    for (m.content) |c| if (c == .tool_result) {
        has_tool_result = true;
    };
    if (has_tool_result) {
        // tool_result 消息在 OpenAI wire 上先投影 {role:"tool"} 项。同消息内的 text 块
        // (agent_loop 追加进同一 user 消息的 PostToolUse additionalContext、验证检查点、
        // 需求台账提示等)不能内联进 tool 消息(官方 content 只收工具输出),在所有 tool
        // 消息之后以一条 user 消息补发——此前被静默丢弃,模型从未收到这些控制文本。
        // image 受 issue #10"绝不静默丢"铁律保护,防御性显式报错(正常路径永不产出此混合)。
        for (m.content) |c| if (c == .image) return error.ImageWithToolResultUnsupported;
        // OpenAI 要求每个 tool_result 是独立 {role:"tool"} message。并行工具一轮有多个
        // tool_result,**全部展开**成逗号分隔的多条 message(P0.1:旧版只发首个 → 并行回合
        // 下一次请求缺 tool_call_id 配对被 OpenAI 400)。调用方在本消息前已加分隔逗号。
        //
        // 图像 tool_result(Read 工具,dialect.extractImageResult 命中):chat/completions
        // 的 {role:"tool"} 消息 content 只接受文本,不接受 image part——官方推荐做法是
        // tool 消息回短文本、图像本体放进**紧随其后的 {role:"user"} 消息**(image_url
        // data URL part,与一等图像输入同一方言 wire)。每张图前置一个 text part 标注
        // 来源 tool_call_id,并行多图也能配对。非 vision 模型(方言返 false)tool 消息
        // 发短占位文本。两种情况都绝不把 MB 级 base64 原文当纯文本塞给模型。
        var image_parts: std.ArrayList(u8) = .empty;
        defer image_parts.deinit(allocator);
        var first_tr = true;
        for (m.content) |c| switch (c) {
            .tool_result => |tr| {
                if (!first_tr) try out.append(allocator, ',');
                first_tr = false;
                try out.appendSlice(allocator, "{\"role\":\"tool\",\"tool_call_id\":");
                try util_json.serializeString(tr.tool_use_id, out, allocator);
                try out.appendSlice(allocator, ",\"content\":");
                if (dialect_mod.extractImageResult(tr.content)) |img| {
                    report.image_results += 1;
                    // scratch 先渲染方言图像 part:方言返回值是 vision/占位的唯一分支决策点,
                    // 指向文本与图像本体不可能不一致。
                    const mark = image_parts.items.len;
                    if (mark > 0) try image_parts.append(allocator, ',');
                    try image_parts.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
                    var label: std.ArrayList(u8) = .empty;
                    defer label.deinit(allocator);
                    try label.appendSlice(allocator, "Image result of tool call ");
                    try label.appendSlice(allocator, tr.tool_use_id);
                    try label.append(allocator, ':');
                    try util_json.serializeString(label.items, &image_parts, allocator);
                    try image_parts.appendSlice(allocator, "},");
                    if (try dialect.serializeImagePart(profile, img, &image_parts, allocator)) {
                        var pointer: std.ArrayList(u8) = .empty;
                        defer pointer.deinit(allocator);
                        try pointer.appendSlice(allocator, "[image (");
                        try pointer.appendSlice(allocator, img.media_type);
                        try pointer.appendSlice(allocator, ") attached in the following user message]");
                        try util_json.serializeString(pointer.items, out, allocator);
                    } else {
                        image_parts.shrinkRetainingCapacity(mark);
                        try report.notePlaceholder(allocator, tr.tool_use_id);
                        var placeholder: std.ArrayList(u8) = .empty;
                        defer placeholder.deinit(allocator);
                        try dialect_mod.appendImageOmittedPlaceholder(img.media_type, &placeholder, allocator);
                        try util_json.serializeString(placeholder.items, out, allocator);
                    }
                } else {
                    try util_json.serializeString(tr.content, out, allocator);
                }
                try out.append(allocator, '}');
            },
            else => {},
        };
        var trailing_text: std.ArrayList(u8) = .empty;
        defer trailing_text.deinit(allocator);
        for (m.content) |c| switch (c) {
            .text => |t| try trailing_text.appendSlice(allocator, t),
            else => {},
        };
        if (image_parts.items.len > 0) {
            try out.appendSlice(allocator, ",{\"role\":\"user\",\"content\":[");
            try out.appendSlice(allocator, image_parts.items);
            if (trailing_text.items.len > 0) {
                try out.appendSlice(allocator, ",{\"type\":\"text\",\"text\":");
                try util_json.serializeString(trailing_text.items, out, allocator);
                try out.append(allocator, '}');
            }
            try out.appendSlice(allocator, "]}");
        } else if (trailing_text.items.len > 0) {
            try out.appendSlice(allocator, ",{\"role\":\"user\",\"content\":");
            try util_json.serializeString(trailing_text.items, out, allocator);
            try out.append(allocator, '}');
        }
        return;
    }
    const role_str = switch (m.role) {
        .user => "user",
        .assistant => "assistant",
    };
    try out.appendSlice(allocator, "{\"role\":\"");
    try out.appendSlice(allocator, role_str);
    try out.appendSlice(allocator, "\"");
    var has_tool_use = false;
    var has_image = false;
    for (m.content) |c| switch (c) {
        .tool_use => has_tool_use = true,
        .image => has_image = true,
        else => {},
    };
    try out.appendSlice(allocator, ",\"content\":");
    if (has_image) {
        // 一等图像内容(issue #10):content 切换为 parts 数组,text/image 按原始顺序
        // 交错输出。图像 wire 形态委托方言;方言返 false = 不支持 → 显式能力错误。
        // 纯文本消息仍走下方 string 形态——请求字节与图像特性引入前逐字节相同
        // (provider prefix cache 契约:不含图的会话字节不变)。
        try out.append(allocator, '[');
        var first_part = true;
        for (m.content) |c| switch (c) {
            .text => |t| {
                if (!first_part) try out.append(allocator, ',');
                first_part = false;
                try out.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
                try util_json.serializeString(t, out, allocator);
                try out.append(allocator, '}');
            },
            .image => |img| {
                if (!first_part) try out.append(allocator, ',');
                first_part = false;
                const emitted = try dialect.serializeImagePart(profile, img, out, allocator);
                if (!emitted) return error.ImageInputUnsupported;
            },
            else => {},
        };
        try out.append(allocator, ']');
    } else {
        // text content(既有路径:拼接为单 string)
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(allocator);
        for (m.content) |c| switch (c) {
            .text => |t| try text_buf.appendSlice(allocator, t),
            else => {},
        };
        try util_json.serializeString(text_buf.items, out, allocator);
    }
    // assistant tool_use → tool_calls
    if (has_tool_use) {
        try out.appendSlice(allocator, ",\"tool_calls\":[");
        var ti: usize = 0;
        for (m.content) |c| switch (c) {
            .tool_use => |tu| {
                if (ti > 0) try out.append(allocator, ',');
                ti += 1;
                try out.appendSlice(allocator, "{\"id\":");
                try util_json.serializeString(tu.id, out, allocator);
                try out.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
                try util_json.serializeString(tu.name, out, allocator);
                try out.appendSlice(allocator, ",\"arguments\":");
                try util_json.serializeString(tu.input, out, allocator);
                try out.appendSlice(allocator, "}}");
            },
            else => {},
        };
        try out.append(allocator, ']');
    }
    try out.append(allocator, '}');
}

fn serializeOpenAITool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), t: json_mod.ToolDefinition) !void {
    try out.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
    try util_json.serializeString(t.name, out, allocator);
    try out.appendSlice(allocator, ",\"description\":");
    try util_json.serializeString(t.description, out, allocator);
    // parameters = input_schema(中立 schema,OpenAI 直接吃 JSON schema)。
    try out.appendSlice(allocator, ",\"parameters\":");
    try @import("request.zig").serializeInputSchema(t.input_schema, out, allocator);
    try out.appendSlice(allocator, "}}");
}

/// 中立 Conversation/tools → OpenAI **Responses API** 请求 body(/v1/responses)。caller free。
/// 与 chat/completions 的 wire 差异(本函数锁住的全部脏活):
///   - messages → `input` items:text-bearing user/assistant 是 {role,content};tool_use 是
///     顶层 {"type":"function_call",call_id,name,arguments};tool_result 是
///     {"type":"function_call_output",call_id,output}。thinking block 跳过(不回传)。
///   - system → 顶层 `instructions`(经 dialect.injectSystemMods + activateCapabilities,
///     同 chat 的 system 组装;非空才发)。
///   - thinking 控制:顶层 `reasoning:{effort}`,活跃档位按名字原样发(GPT-6 的 xhigh 与 max 是两档)——
///     不走 dialect.serializeThinking(那是 chat body 的字段形态)。
///   - tools 扁平:{"type":"function",name,description,parameters,strict:false}(无嵌套 function)。
///   - response_format → 顶层 `text:{format:{...}}`(chat 的 response_format 字段形态
///     Responses 不认);prompt_cache_key / parallel_tool_calls 与 chat 同名顶层字段。
///   - `store:false`(agent loop 自管上下文,不用服务端存储);无 max_output_tokens、
///     无 stream_options(Responses 流式默认带 usage)。
pub fn serializeOpenAIResponsesRequest(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const json_mod.ToolDefinition,
    overrides: request_overrides.RequestOverrides,
    dialect: dialect_mod.Dialect,
) ![]u8 {
    var scratch = json_mod.SerializationReport{};
    defer scratch.deinit(allocator);
    return serializeOpenAIResponsesRequestReport(allocator, model, messages, system, tools, overrides, dialect, &scratch);
}

/// 同上,并把图像 tool_result 的实际序列化决定写入 `report`。
pub fn serializeOpenAIResponsesRequestReport(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const json_mod.ToolDefinition,
    overrides: request_overrides.RequestOverrides,
    dialect: dialect_mod.Dialect,
    report: *json_mod.SerializationReport,
) ![]u8 {
    const profile = dialect.profileFor(.openai, model);
    const visible_capabilities = dialect_mod.visibleCapabilities(tools);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"model\":");
    try util_json.serializeString(model, &out, allocator);
    // reasoning.effort: only an active level is sent, by its own name. GPT-6
    // accepts low..max with xhigh and max as distinct levels (developers.openai.com
    // models/gpt-6-astra, 2026-10); capping xhigh at high sent a weaker level
    // than the one chosen. Which levels a model takes is its offer's control
    // vocabulary, so the picker never offers one the model refuses.
    if (overrides.reasoning_effort) |e| if (e.active()) {
        const effort: []const u8 = switch (e) {
            .none, .minimal => "minimal", // excluded by active(); the lowest level
            .low, .medium, .high, .xhigh, .max => e.name(),
        };
        try out.appendSlice(allocator, ",\"reasoning\":{\"effort\":");
        try util_json.serializeString(effort, &out, allocator);
        try out.append(allocator, '}');
    };
    // 通用采样参数(同 chat)。
    if (overrides.temperature) |t| {
        try out.appendSlice(allocator, ",\"temperature\":");
        try util_json.serializeNumber(t, &out, allocator);
    }
    if (overrides.top_p) |p| {
        try out.appendSlice(allocator, ",\"top_p\":");
        try util_json.serializeNumber(p, &out, allocator);
    }
    try out.appendSlice(allocator, ",\"stream\":true,\"store\":false");
    // system → instructions。组装链与 chat 一致(dialect 注入 + 能力激活),非空才发。
    var sys_buf: std.ArrayList(u8) = .empty;
    defer sys_buf.deinit(allocator);
    if (system) |sys| try sys_buf.appendSlice(allocator, sys);
    try dialect.injectSystemMods(profile, overrides.reasoning_effort, &sys_buf, allocator);
    try dialect.activateCapabilities(
        profile,
        visible_capabilities,
        &sys_buf,
        allocator,
    );
    if (sys_buf.items.len != 0) {
        try out.appendSlice(allocator, ",\"instructions\":");
        try util_json.serializeString(sys_buf.items, &out, allocator);
    }
    try out.appendSlice(allocator, ",\"input\":[");
    var first = true;
    for (messages) |m| {
        try serializeResponsesInputItems(allocator, &out, m, &first, profile, model, report);
    }
    try out.append(allocator, ']');
    // tools:Responses 扁平形态(name/description/parameters 顶层;strict:false 不强制 schema 严格模式)。
    if (tools) |tl| {
        if (tl.len > 0) {
            try out.appendSlice(allocator, ",\"tools\":[");
            for (tl, 0..) |t, i| {
                if (i > 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, "{\"type\":\"function\",\"name\":");
                try util_json.serializeString(t.name, &out, allocator);
                try out.appendSlice(allocator, ",\"description\":");
                try util_json.serializeString(t.description, &out, allocator);
                try out.appendSlice(allocator, ",\"parameters\":");
                try @import("request.zig").serializeInputSchema(t.input_schema, &out, allocator);
                try out.appendSlice(allocator, ",\"strict\":false}");
            }
            try out.append(allocator, ']');
        }
    }
    try serializeResponsesToolChoice(overrides.tool_choice, &out, allocator);
    // response_format → Responses 顶层 text.format(review F2:此前三个 override 在
    // responses 路径静默 no-op——CLI 传了却不上 wire)。responses-local,不走
    // dialect.serializeResponseFormat(那是 chat 的 response_format 字段形态;
    // protocol=responses 是显式 OpenAI 原生配置,无三方兼容端点的能力守门问题)。
    // 字段用法镜像 chat 序列化:json_object 只发 type;json_schema 内联 schema + 必填
    // name(Responses 的 text.format 是平铺形态,name 在 format 层;缺 name 服务端 400,
    // R2-4 修),schema 缺失退化 json_object(同 chat 降级语义)。
    if (overrides.response_format) |rf| {
        if (rf.kind == .json_schema and rf.schema != null) {
            try out.appendSlice(allocator, ",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"response\",\"schema\":");
            try out.appendSlice(allocator, rf.schema.?);
            try out.appendSlice(allocator, "}}");
        } else if (rf.kind != .none) {
            try out.appendSlice(allocator, ",\"text\":{\"format\":{\"type\":\"json_object\"}}");
        }
    }
    // prompt_cache_key / parallel_tool_calls:与 chat 同名顶层字段(Responses 同样支持)。
    if (overrides.prompt_cache_key) |key| {
        try out.appendSlice(allocator, ",\"prompt_cache_key\":");
        try util_json.serializeString(key, &out, allocator);
    }
    if (overrides.parallel_tool_calls) |b| {
        try out.appendSlice(allocator, ",\"parallel_tool_calls\":");
        try out.appendSlice(allocator, if (b) "true" else "false");
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// 一条中立 ApiMessage → 0..N 个 Responses `input` items(逗号管理经 first 指针)。
/// text-bearing 消息 → {role,content}(拼接 .text block,跳 .thinking);每个 tool_use →
/// {"type":"function_call"};每个 tool_result → {"type":"function_call_output"}。
/// 含 image 的消息 → content 变 parts 数组(input_text/input_image 按原始顺序交错);
/// input_image 是 responses-local wire 形态(同 text.format 先例,不走 dialect——
/// protocol=responses 是显式 OpenAI 原生配置),能力守门仍查 profile.supports_image_input。
/// 图像 tool_result(Read 工具形态)→ vision 模型 output 发 input_image parts 数组
/// (官方 2025-09-26 起支持,call_id 原生配对);非 vision 模型 output 发短占位文本。
/// reasoning item(issue #23)→ 顶层 item **逐字节原样**回传,排在本条消息的其余
/// item 之前(服务端 `output` 就是 reasoning 在前)。
fn serializeResponsesInputItems(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    m: types.ApiMessage,
    first: *bool,
    profile: dialect_mod.ModelProfile,
    model: []const u8,
    report: *json_mod.SerializationReport,
) !void {
    // `store:false` 时服务端不保存推理状态,只能由客户端把带 encrypted_content 的
    // reasoning item 原样发回(OpenAI "preserve reasoning without stored responses")。
    // **不重新序列化**:重排字段或再转义一次都可能让服务端拒绝解密。
    // 模型门控:加密推理状态是模型作用域的,会话中途换模型后旧 item 不再有效,
    // 与其让整个请求被服务端拒掉,不如安静地不回传那几项(等价于修复前的行为)。
    for (m.content) |c| switch (c) {
        .reasoning_item => |item| {
            if (!std.mem.eql(u8, item.model, model)) continue;
            if (!first.*) try out.append(allocator, ',');
            first.* = false;
            try out.appendSlice(allocator, item.json);
        },
        else => {},
    };
    var has_image = false;
    var has_tool_result = false;
    var text_len: usize = 0;
    for (m.content) |c| switch (c) {
        .image => has_image = true,
        .tool_result => has_tool_result = true,
        .text => |t| text_len += t.len,
        else => {},
    };
    if (has_image) {
        // 与 chat/Gemini 的守卫对称:tool_result+image 混合消息在 Responses 上会被
        // 拆成两个 wire item(image 抢在 function_call_output 配对前),同样防御性显式
        // 报错而非静默重排(正常路径经 merge 守护永不产出此混合)。
        if (has_tool_result) return error.ImageWithToolResultUnsupported;
        if (!profile.supports_image_input) return error.ImageInputUnsupported;
        if (!first.*) try out.append(allocator, ',');
        first.* = false;
        try out.appendSlice(allocator, "{\"role\":\"");
        try out.appendSlice(allocator, switch (m.role) {
            .user => "user",
            .assistant => "assistant",
        });
        try out.appendSlice(allocator, "\",\"content\":[");
        var first_part = true;
        for (m.content) |c| switch (c) {
            .text => |t| {
                if (!first_part) try out.append(allocator, ',');
                first_part = false;
                try out.appendSlice(allocator, "{\"type\":\"input_text\",\"text\":");
                try util_json.serializeString(t, out, allocator);
                try out.append(allocator, '}');
            },
            .image => |img| {
                if (!first_part) try out.append(allocator, ',');
                first_part = false;
                // data-URL 核心与 chat 的 image_url 共享(dialects/openai.writeImageDataUrl,
                // 注入安全同源);仅外围 input_image 信封是 responses-local。
                try out.appendSlice(allocator, "{\"type\":\"input_image\",\"image_url\":\"");
                try @import("dialects/openai.zig").writeImageDataUrl(img, out, allocator);
                try out.appendSlice(allocator, "\"}");
            },
            else => {},
        };
        try out.appendSlice(allocator, "]}");
    } else if (text_len > 0) {
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(allocator);
        for (m.content) |c| switch (c) {
            .text => |t| try text_buf.appendSlice(allocator, t),
            else => {},
        };
        if (!first.*) try out.append(allocator, ',');
        first.* = false;
        try out.appendSlice(allocator, "{\"role\":\"");
        try out.appendSlice(allocator, switch (m.role) {
            .user => "user",
            .assistant => "assistant",
        });
        try out.appendSlice(allocator, "\",\"content\":");
        try util_json.serializeString(text_buf.items, out, allocator);
        try out.append(allocator, '}');
    }
    for (m.content) |c| switch (c) {
        .tool_use => |tu| {
            if (!first.*) try out.append(allocator, ',');
            first.* = false;
            try out.appendSlice(allocator, "{\"type\":\"function_call\",\"call_id\":");
            try util_json.serializeString(tu.id, out, allocator);
            try out.appendSlice(allocator, ",\"name\":");
            try util_json.serializeString(tu.name, out, allocator);
            // arguments 是装在 string 里的 JSON 文档(serializeString 加回一层转义)。
            try out.appendSlice(allocator, ",\"arguments\":");
            try util_json.serializeString(tu.input, out, allocator);
            try out.append(allocator, '}');
        },
        .tool_result => |tr| {
            if (!first.*) try out.append(allocator, ',');
            first.* = false;
            try out.appendSlice(allocator, "{\"type\":\"function_call_output\",\"call_id\":");
            try util_json.serializeString(tr.tool_use_id, out, allocator);
            try out.appendSlice(allocator, ",\"output\":");
            if (dialect_mod.extractImageResult(tr.content)) |img| {
                report.image_results += 1;
                if (profile.supports_image_input) {
                    // 官方形态(2025-09-26 起):output 接受 content parts **数组**(真数组,
                    // 非 JSON 字符串化数组);input_image 与一等图像输入同 responses-local
                    // wire,call_id 原生配对,无需追加消息。detail 不发(服务端默认 auto)。
                    try out.appendSlice(allocator, "[{\"type\":\"input_image\",\"image_url\":\"data:");
                    try util_json.serializeStringContents(img.media_type, out, allocator);
                    try out.appendSlice(allocator, ";base64,");
                    try util_json.serializeStringContents(img.data, out, allocator);
                    try out.appendSlice(allocator, "\"}]");
                } else {
                    // 非 vision:显式占位文本,绝不把 base64 原文当 output 字符串发。
                    try report.notePlaceholder(allocator, tr.tool_use_id);
                    var placeholder: std.ArrayList(u8) = .empty;
                    defer placeholder.deinit(allocator);
                    try dialect_mod.appendImageOmittedPlaceholder(img.media_type, &placeholder, allocator);
                    try util_json.serializeString(placeholder.items, out, allocator);
                }
            } else {
                try util_json.serializeString(tr.content, out, allocator);
            }
            try out.append(allocator, '}');
        },
        else => {},
    };
}

/// Responses API 的 tool_choice(responses-local,不走 dialect.serializeToolChoice——
/// 那是 chat 的嵌套 function 形态)。中立语义映射:auto→"auto",any/required→"required",
/// none→"none",tool+name→扁平 {"type":"function","name":..},tool 缺 name→"required"。
/// 未识别 type 不发(服务端用默认)。
fn serializeResponsesToolChoice(tc_opt: ?json_mod.ToolChoice, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const tc = tc_opt orelse return;
    if (std.mem.eql(u8, tc.type, "auto")) {
        try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
    } else if (std.mem.eql(u8, tc.type, "none")) {
        try out.appendSlice(allocator, ",\"tool_choice\":\"none\"");
    } else if (std.mem.eql(u8, tc.type, "any") or std.mem.eql(u8, tc.type, "required")) {
        try out.appendSlice(allocator, ",\"tool_choice\":\"required\"");
    } else if (std.mem.eql(u8, tc.type, "tool")) {
        if (tc.name) |n| {
            try out.appendSlice(allocator, ",\"tool_choice\":{\"type\":\"function\",\"name\":");
            try util_json.serializeString(n, out, allocator);
            try out.append(allocator, '}');
        } else {
            try out.appendSlice(allocator, ",\"tool_choice\":\"required\"");
        }
    }
}

test "OpenAI 请求翻译:中立 Conversation → chat/completions body" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hello" }} },
    };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "you are helpful", null, .high, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
}

test "serializeOpenAIRequest: GLM-5.2 effort=high 走顶层 reasoning_effort body(非 system 标签)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // GLM-5.2:顶层 reasoning_effort body + thinking:{type:enabled};不再注入 system 标签。
    // 来源:docs.z.ai/guides/capabilities/thinking(2026-08 KnowForge 调研)。
    try std.testing.expect(std.mem.indexOf(u8, body, "<reasoning_effort>") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "clear_thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Model-specific capability activation") == null);
}

test "serializeOpenAIRequest: GLM Skill capability activation is typed and byte-stable" {
    const allocator = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const skill = json_mod.ToolDefinition{
        .name = "Skill",
        .description = "invoke a bound skill",
        .input_schema = .{},
        .model_activation = .{
            .mode = .required_first,
            .argument_name = "name",
            .argument_value = "verify-change",
        },
    };
    const first = try serializeOpenAIRequest(allocator, "glm-5.2", &msgs, "sys", &.{skill}, .high, null);
    defer allocator.free(first);
    const second = try serializeOpenAIRequest(allocator, "glm-5.2", &msgs, "sys", &.{skill}, .high, null);
    defer allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "Model-specific capability activation") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "blocking requirement") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "`verify-change`") != null);
    // GLM's OpenAI-compatible profile is auto-only: exact-name guidance is
    // emitted, but an unsupported forced-function value is not.
    try std.testing.expect(std.mem.indexOf(u8, first, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"name\":\"Skill\"") != null);
}

test "serializeOpenAIRequest: Kimi K3 effort=high 走顶层 reasoning_effort(不发 thinking body)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeOpenAIRequest(a, "kimi-k3", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // K3:顶层 reasoning_effort,不发 thinking:{} body(那是 K2.6)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
}

test "serializeOpenAIRequest: Kimi K3 effort=null 默认 max" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeOpenAIRequest(a, "kimi-k3", &msgs, "sys", null, null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
}

test "serializeOpenAIRequest: Kimi K2.6 effort=high 走 extra_body thinking" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeOpenAIRequest(a, "kimi-k2", &msgs, "sys", null, .high, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"high\"") != null);
    // K2.6 不发顶层 reasoning_effort(那是 K3 的)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":") == null);
}

test "serializeOpenAIRequest: DeepSeek effort=high 走顶层 reasoning_effort" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeOpenAIRequest(a, "deepseek-chat", &msgs, "sys", null, .high, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
}

test "serializeOpenAIRequest: DeepSeek effort=xhigh → reasoning_effort=max(V4 修正)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeOpenAIRequest(a, "deepseek-chat", &msgs, "sys", null, .xhigh, null);
    defer a.free(body);
    // V4 文档明确 xhigh → max(此前误为 high,2026-08 KnowForge 调研修正)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") == null);
}

// ── M3:tool_choice 端到端字节断言(声明=接线=测试 DoD)───────────────────────────

test "M3 serializeOpenAIRequest: tool_choice=auto 发 \"auto\"" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "auto" };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
}

test "M3 serializeOpenAIRequest: tool_choice=any → \"required\"(OpenAI 语义)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "any" };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"required\"") != null);
}

test "M3 serializeOpenAIRequest: tool_choice=tool+name → function 指定" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "tool", .name = "web_search" };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"web_search\"}}") != null);
}

test "M3 serializeOpenAIRequest: tool_choice=none → \"none\"" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "none" };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"none\"") != null);
}

test "M3 serializeOpenAIRequest: tool_choice=tool 缺 name → 退到 required" {
    // tool 类型但 name=null,无法指定具体工具,退到 required(强制选一个)。
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "tool", .name = null };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") == null);
}

test "M3 serializeOpenAIRequest: GLM-5 tool_choice=required 降级为 auto(能力守门)" {
    // 声明=接线=测试:GLM-5 profile.tool_choice_support==.auto_only,任何非 auto/none 都必须降级。
    // 不降级 → 服务端 400;dialect 必须守门。
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "required" };
    const body = try serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"required\"") == null);
}

test "M3 serializeOpenAIRequest: GLM-5 tool_choice=none 不降级(通用语义)" {
    // none=不调用工具,所有 OpenAI-compatible 服务端都认,不该降级成 auto(会变允许工具)。
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "none" };
    const body = try serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") == null);
}

test "M3 serializeOpenAIRequest: tool_choice=null 不发 tool_choice 字段" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
}

// ── issue #10:一等图像输入(chat/completions + Responses)────────────────────────

test "chat: 含 image 的 user 消息 → content parts 数组(text/image_url 按序)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .text = "describe" },
            .{ .image = .{ .media_type = "image/png", .data = "UE5HREFUQQ==" } },
        } },
    };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, null, null, null, null);
    defer a.free(body);
    const arr = std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"describe\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,UE5HREFUQQ==\"}}]");
    try std.testing.expect(arr != null);
}

test "chat: 纯文本消息 content 仍是 string(请求字节稳定,prompt cache 契约)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, null, null, null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
}

test "chat: 不支持 vision 的模型带 image → 显式能力错误(不静默丢图)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .image = .{ .media_type = "image/png", .data = "QUJD" } },
        } },
    };
    try std.testing.expectError(
        error.ImageInputUnsupported,
        serializeOpenAIRequest(a, "deepseek-chat", &msgs, null, null, null, null),
    );
}

const IMG_TOOL_RESULT_JSON = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"UE5HREFUQQ==\"}";

test "chat: vision 模型的图像 tool_result → tool 消息短文本 + 紧随 user 消息 image_url" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .tool_use = .{ .id = "call_1", .name = "Read", .input = "{}" } },
        } },
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_1", .content = IMG_TOOL_RESULT_JSON } },
        } },
    };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, null, null, null, null);
    defer a.free(body);
    // tool 消息:短指向文本,不含 base64;图像本体在紧随其后的 user 消息(官方约定:
    // chat 的 tool 消息 content 不接受 image part)。字节级锁定完整序列。
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"[image (image/png) attached in the following user message]\"},{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Image result of tool call call_1:\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,UE5HREFUQQ==\"}}]}") != null);
    // 原始 JSON 绝不作为文本出现(仅 data URL 内出现一次 base64)。
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);
}

test "chat: 非 vision 模型的图像 tool_result → 占位文本,无 base64 无追加消息" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_1", .content = IMG_TOOL_RESULT_JSON } },
        } },
    };
    const body = try serializeOpenAIRequest(a, "deepseek-chat", &msgs, null, null, null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"[image (image/png) was read successfully but omitted: this model does not support image input]\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "UE5HREFUQQ==") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") == null);
}

test "chat: 并行 tool_result 文本+图像混合 → 文本字节不变,单条追加 user 消息配对 id" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_a", .content = "file contents" } },
            .{ .tool_result = .{ .tool_use_id = "call_b", .content = IMG_TOOL_RESULT_JSON } },
        } },
    };
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, null, null, null, null);
    defer a.free(body);
    // 非图像 tool_result 字节与图像特性引入前逐字节相同(prompt cache 契约)。
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_a\",\"content\":\"file contents\"}") != null);
    // 图像统一收尾在**单条**追加 user 消息,text part 配对 tool_call_id。
    const trailer = std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Image result of tool call call_b:\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,UE5HREFUQQ==\"}}]}").?;
    const tool_b = std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_b\"").?;
    try std.testing.expect(tool_b < trailer);
}

test "responses: 含 image 的 user 消息 → input_text/input_image parts(按序)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .text = "what is this" },
            .{ .image = .{ .media_type = "image/jpeg", .data = "SlBFRw==" } },
        } },
    };
    const body = try serializeOpenAIResponsesRequest(a, "gpt-5.2", &msgs, null, null, .{}, dialect_mod.dialectFor(.openai, "gpt-5.2"));
    defer a.free(body);
    const arr = std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"input_text\",\"text\":\"what is this\"},{\"type\":\"input_image\",\"image_url\":\"data:image/jpeg;base64,SlBFRw==\"}]");
    try std.testing.expect(arr != null);
}

test "responses: 不支持 vision 的模型带 image → 显式能力错误" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .image = .{ .media_type = "image/png", .data = "QUJD" } },
        } },
    };
    try std.testing.expectError(
        error.ImageInputUnsupported,
        serializeOpenAIResponsesRequest(a, "qwen3-235b", &msgs, null, null, .{}, dialect_mod.dialectFor(.openai, "qwen3-235b")),
    );
}

test "chat: tool_result 消息混入 image → 显式错误(防 wire 投影静默丢图)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok" } },
            .{ .image = .{ .media_type = "image/png", .data = "QUJD" } },
        } },
    };
    try std.testing.expectError(
        error.ImageWithToolResultUnsupported,
        serializeOpenAIRequest(a, "gpt-4o", &msgs, null, null, null, null),
    );
}

test "responses: vision 模型的图像 tool_result → output 为 input_image parts 数组" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_1", .content = IMG_TOOL_RESULT_JSON } },
        } },
    };
    const body = try serializeOpenAIResponsesRequest(a, "gpt-5.2", &msgs, null, null, .{}, dialect_mod.dialectFor(.openai, "gpt-5.2"));
    defer a.free(body);
    // 官方形态:output 是真 JSON 数组(非字符串化数组),call_id 原生配对。字节级锁定。
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,UE5HREFUQQ==\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);
}

test "responses: 非 vision 模型的图像 tool_result → output 占位字符串,无 base64" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_1", .content = IMG_TOOL_RESULT_JSON } },
        } },
    };
    const body = try serializeOpenAIResponsesRequest(a, "qwen3-235b", &msgs, null, null, .{}, dialect_mod.dialectFor(.openai, "qwen3-235b"));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output\":\"[image (image/png) was read successfully but omitted: this model does not support image input]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "UE5HREFUQQ==") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "input_image") == null);
}

test "SerializationReport(OpenAI): chat 走 fail-closed 方言计占位;Responses 按 profile 计" {
    const a = std.testing.allocator;
    const tool_use = [_]types.ApiContent{.{ .tool_use = .{ .id = "call_img", .name = "Read", .input = "{}" } }};
    const tool_result = [_]types.ApiContent{.{ .tool_result = .{ .tool_use_id = "call_img", .content = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}" } }};
    const msgs = [_]types.ApiMessage{ .{ .role = .assistant, .content = &tool_use }, .{ .role = .user, .content = &tool_result } };
    // chat/completions + 默认 fail-closed 方言(gpt-4o 的 profile 支持 vision,方言仍拒绝)。
    var chat_closed = json_mod.SerializationReport{};
    defer chat_closed.deinit(a);
    const body_closed = try serializeOpenAIRequestWithOverridesAndDialectReport(a, "gpt-4o", &msgs, null, null, .{}, .{ .ctx = undefined }, &chat_closed);
    defer a.free(body_closed);
    try std.testing.expectEqual(@as(usize, 1), chat_closed.image_results);
    try std.testing.expectEqual(@as(usize, 1), chat_closed.image_placeholders);
    try std.testing.expect(!chat_closed.imagesNative());
    // chat/completions + 内建方言:原生 image_url,不计占位。
    var chat_native = json_mod.SerializationReport{};
    defer chat_native.deinit(a);
    const body_native = try serializeOpenAIRequestWithOverridesAndDialectReport(a, "gpt-4o", &msgs, null, null, .{}, dialect_mod.Resolver.builtin().resolve(.openai, "gpt-4o"), &chat_native);
    defer a.free(body_native);
    try std.testing.expect(chat_native.imagesNative());
    // Responses:非 vision 模型计占位,vision 模型不计。
    var resp_closed = json_mod.SerializationReport{};
    defer resp_closed.deinit(a);
    const body_resp_closed = try serializeOpenAIResponsesRequestReport(a, "deepseek-chat", &msgs, null, null, .{}, dialect_mod.Resolver.builtin().resolve(.openai, "deepseek-chat"), &resp_closed);
    defer a.free(body_resp_closed);
    try std.testing.expectEqual(@as(usize, 1), resp_closed.image_placeholders);
    var resp_native = json_mod.SerializationReport{};
    defer resp_native.deinit(a);
    const body_resp_native = try serializeOpenAIResponsesRequestReport(a, "gpt-5.2", &msgs, null, null, .{}, dialect_mod.Resolver.builtin().resolve(.openai, "gpt-5.2"), &resp_native);
    defer a.free(body_resp_native);
    try std.testing.expect(resp_native.imagesNative());
}

test "OpenAI chat: tool_result 消息里的同消息 text(hook 上下文/检查点)在 tool 消息之后以 user 消息补发" {
    const a = std.testing.allocator;
    const tool_use = [_]types.ApiContent{.{ .tool_use = .{ .id = "call_1", .name = "Bash", .input = "{}" } }};
    const mixed = [_]types.ApiContent{
        .{ .tool_result = .{ .tool_use_id = "call_1", .content = "ok" } },
        .{ .text = "[PostToolUse hook]\npost-check ok" },
    };
    const msgs = [_]types.ApiMessage{ .{ .role = .assistant, .content = &tool_use }, .{ .role = .user, .content = &mixed } };
    const body = try serializeOpenAIRequestWithOverridesAndDialect(a, "gpt-4o", &msgs, null, null, .{}, dialect_mod.Resolver.builtin().resolve(.openai, "gpt-4o"));
    defer a.free(body);
    const tool_at = std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"ok\"}").?;
    const text_at = std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":\"[PostToolUse hook]\\npost-check ok\"}").?;
    try std.testing.expect(tool_at < text_at);
    // 图像结果 + 文本:文本作为紧随 user 消息的最后一个 text part。
    const img_mixed = [_]types.ApiContent{
        .{ .tool_result = .{ .tool_use_id = "call_1", .content = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}" } },
        .{ .text = "post-check ok" },
    };
    const img_msgs = [_]types.ApiMessage{ .{ .role = .assistant, .content = &tool_use }, .{ .role = .user, .content = &img_mixed } };
    const img_body = try serializeOpenAIRequestWithOverridesAndDialect(a, "gpt-4o", &img_msgs, null, null, .{}, dialect_mod.Resolver.builtin().resolve(.openai, "gpt-4o"));
    defer a.free(img_body);
    const image_at = std.mem.indexOf(u8, img_body, "{\"type\":\"image_url\"").?;
    const part_at = std.mem.indexOf(u8, img_body, ",{\"type\":\"text\",\"text\":\"post-check ok\"}]}").?;
    try std.testing.expect(image_at < part_at);
}

const REASONING_ITEM_JSON =
    "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"opaque-ciphertext\"}";

test "responses: reasoning item 逐字节回传,排在同消息的 function_call 之前" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "what time is it" }} },
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .reasoning_item = .{ .model = "gpt-5.2", .json = REASONING_ITEM_JSON } },
            .{ .tool_use = .{ .id = "call_1", .name = "get_time", .input = "{}" } },
        } },
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_1", .content = "{\"t\":42}" } },
        } },
    };
    const body = try serializeOpenAIResponsesRequest(a, "gpt-5.2", &msgs, null, null, .{}, dialect_mod.dialectFor(.openai, "gpt-5.2"));
    defer a.free(body);
    // 原样(未再转义)出现:重新序列化或多包一层字符串都会让服务端拒绝解密。
    const reasoning = std.mem.indexOf(u8, body, REASONING_ITEM_JSON) orelse return error.TestUnexpectedResult;
    const call = std.mem.indexOf(u8, body, "\"type\":\"function_call\"").?;
    const output = std.mem.indexOf(u8, body, "\"type\":\"function_call_output\"").?;
    const user = std.mem.indexOf(u8, body, "what time is it").?;
    try std.testing.expect(user < reasoning);
    try std.testing.expect(reasoning < call);
    try std.testing.expect(call < output);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    // 不得被当成字符串塞进某个字段(那是"转义过的原始 JSON"形态)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"type\\\":\\\"reasoning\\\"") == null);
}

test "responses: 换模型后旧 reasoning item 不回传(加密状态是模型作用域的)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .reasoning_item = .{ .model = "gpt-5.2", .json = REASONING_ITEM_JSON } },
            .{ .text = "let me check" },
        } },
    };
    const body = try serializeOpenAIResponsesRequest(a, "o4-mini", &msgs, null, null, .{}, dialect_mod.dialectFor(.openai, "o4-mini"));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "rs_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "opaque-ciphertext") == null);
    // 同消息的其余内容照常发(丢的只是那一项 provider 私有状态)。
    try std.testing.expect(std.mem.indexOf(u8, body, "let me check") != null);
}

test "responses: 无 reasoning item 时请求字节与既有实现完全一致" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .tool_use = .{ .id = "call_1", .name = "get_time", .input = "{}" } },
        } },
    };
    const body = try serializeOpenAIResponsesRequest(a, "gpt-5.2", &msgs, null, null, .{}, dialect_mod.dialectFor(.openai, "gpt-5.2"));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[{\"role\":\"user\",\"content\":\"hi\"},{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"get_time\",\"arguments\":\"{}\"}]") != null);
}

test "Anthropic 序列化跳过 reasoning item(无多余逗号,其余 block 字节不变)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .assistant, .content = &[_]types.ApiContent{
            .{ .reasoning_item = .{ .model = "gpt-5.2", .json = REASONING_ITEM_JSON } },
            .{ .text = "hello" },
            .{ .reasoning_item = .{ .model = "gpt-5.2", .json = REASONING_ITEM_JSON } },
            .{ .tool_use = .{ .id = "call_1", .name = "get_time", .input = "{}" } },
        } },
    };
    const body = try json_mod.serializeMessagesRequest(.{
        .model = "claude-sonnet-4",
        .max_tokens = 64,
        .messages = &msgs,
        .stream = true,
    }, a);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "rs_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"tool_use\",\"id\":\"call_1\"") != null);
}

test "itemTypeIs: 按值过滤,不依赖服务端把顶层 type 排在嵌套对象之前" {
    const ordered = "{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"x\"}]}";
    const reordered = "{\"summary\":[{\"type\":\"summary_text\",\"text\":\"x\"}],\"id\":\"rs_1\",\"type\":\"reasoning\"}";
    const call = "{\"id\":\"fc_1\",\"call_id\":\"c1\",\"type\":\"function_call\",\"name\":\"f\",\"arguments\":\"{}\"}";
    try std.testing.expect(itemTypeIs(ordered, "reasoning"));
    // 首次匹配会在这里读到 "summary_text" 并静默丢掉整条推理状态。
    try std.testing.expect(itemTypeIs(reordered, "reasoning"));
    try std.testing.expect(!itemTypeIs(call, "reasoning"));
    try std.testing.expect(itemTypeIs(call, "function_call"));
    // 转义后的字符串内容撞不上键模式(工具参数里出现同样的文本也不会误判)。
    const escaped = "{\"id\":\"fc_2\",\"type\":\"function_call\",\"arguments\":\"{\\\"type\\\":\\\"reasoning\\\"}\"}";
    try std.testing.expect(!itemTypeIs(escaped, "reasoning"));
}

// ── issue #258:`usage:null` 不得截断 chunk;usage 只从 usage 对象读 ────────────────
//
// 直驱真实的 OpenAIStream.next()(含 takeQueued 出队顺序),只把 HTTP body reader 换成
// 固定字节——SSE 分行、parseChunk、flush、事件顺序都与生产同一条路径。每个 usage:null
// 用例配一个"只删掉 usage 字段"的对照,断言两者事件序列逐项一致(双侧)。

/// 接管自 tool_use_start 的 owned 三元组(Replay.deinit 释放)。
const ReplayTool = struct { id: []const u8, name: []const u8, input: []const u8 };

/// 一次回放的可观察结果:事件种类序列 + 拼接文本/思考 + 工具调用 + usage 序列 + stop。
const Replay = struct {
    kinds: std.ArrayList(std.meta.Tag(StreamEvent)) = .empty,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ReplayTool) = .empty,
    usages: std.ArrayList(UsageDelta) = .empty,
    stop: StopReason = .unknown,

    fn deinit(self: *Replay, a: std.mem.Allocator) void {
        self.kinds.deinit(a);
        self.text.deinit(a);
        self.thinking.deinit(a);
        for (self.tools.items) |t| {
            a.free(t.id);
            a.free(t.name);
            a.free(t.input);
        }
        self.tools.deinit(a);
        self.usages.deinit(a);
    }

    fn expectSame(expected: *const Replay, actual: *const Replay) !void {
        try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), expected.kinds.items, actual.kinds.items);
        try std.testing.expectEqualStrings(expected.text.items, actual.text.items);
        try std.testing.expectEqualStrings(expected.thinking.items, actual.thinking.items);
        try std.testing.expectEqual(expected.tools.items.len, actual.tools.items.len);
        for (expected.tools.items, actual.tools.items) |e, g| {
            try std.testing.expectEqualStrings(e.id, g.id);
            try std.testing.expectEqualStrings(e.name, g.name);
            try std.testing.expectEqualStrings(e.input, g.input);
        }
        try std.testing.expectEqualSlices(UsageDelta, expected.usages.items, actual.usages.items);
        try std.testing.expectEqual(expected.stop, actual.stop);
    }
};

fn replaySse(a: std.mem.Allocator, model: []const u8, protocol: types.OpenAIProtocol, sse: []const u8) !Replay {
    var stream = OpenAIStream{
        .allocator = a,
        .model = model,
        .dialect = dialect_mod.dialectFor(.openai, model),
        .protocol = protocol,
        .request = undefined, // 固定 reader 直驱:不建 HTTP 请求,releaseParseState 不碰它
        .response = undefined,
        .id = .{ .bytes = .{0} ** 12 },
    };
    defer stream.releaseParseState();
    var body = std.Io.Reader.fixed(sse);
    stream.reader = &body;

    var out: Replay = .{};
    errdefer out.deinit(a);
    while (try stream.next()) |ev| {
        switch (ev) {
            .text => |t| {
                defer a.free(t);
                try out.text.appendSlice(a, t);
            },
            .thinking => |t| {
                defer a.free(t);
                try out.thinking.appendSlice(a, t);
            },
            .tool_use_start => |tu| out.tools.append(a, .{ .id = tu.id, .name = tu.name, .input = tu.input_json }) catch |e| {
                a.free(tu.id);
                a.free(tu.name);
                a.free(tu.input_json);
                return e;
            },
            .reasoning_item => |bytes| a.free(bytes),
            .web_search_result => |w| {
                a.free(w.ui_text);
                a.free(w.content_json);
            },
            .web_search_query => |q| a.free(q),
            .usage => |u| try out.usages.append(a, u),
            .done => {},
        }
        try out.kinds.append(a, std.meta.activeTag(ev));
    }
    out.stop = stream.last_stop;
    return out;
}

/// 回放 `with_usage_null` 与其去掉 usage 字段的对照,断言两者一致并返回前者(caller deinit)。
fn replayAgainstControl(a: std.mem.Allocator, model: []const u8, with_usage_null: []const u8, control: []const u8) !Replay {
    var got = try replaySse(a, model, .chat_completions, with_usage_null);
    errdefer got.deinit(a);
    var want = try replaySse(a, model, .chat_completions, control);
    defer want.deinit(a);
    try Replay.expectSame(&want, &got);
    return got;
}

test "issue #258: usage:null 在 choices 之后——文本与 stop 照常,不产 usage 事件(对照同)" {
    const a = std.testing.allocator;
    var got = try replayAgainstControl(
        a,
        "gpt-4o",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}\n\n" ++
            "data: [DONE]\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .done }, got.kinds.items);
    try std.testing.expectEqualStrings("Hello", got.text.items);
    try std.testing.expectEqual(StopReason.end_turn, got.stop);
    try std.testing.expectEqual(@as(usize, 0), got.usages.items.len);
}

test "issue #258: usage:null 在 choices 之前 + role-only delta + 空 delta/finish_reason(对照同)" {
    const a = std.testing.allocator;
    var got = try replayAgainstControl(
        a,
        "gpt-4o",
        "data: {\"usage\":null,\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
            "data: {\"usage\":null,\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n" ++
            "data: {\"usage\":null,\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\n" ++
            "data: {\"usage\": null, \"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n" ++
            "data: [DONE]\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .done }, got.kinds.items);
    try std.testing.expectEqualStrings("Hi", got.text.items);
    // 末块 finish_reason 与 usage:null 同 chunk 也必须被记下(旧实现会提前 return 丢掉)。
    try std.testing.expectEqual(StopReason.max_tokens, got.stop);
    try std.testing.expectEqual(@as(usize, 0), got.usages.items.len);
}

test "issue #258: tool_call 增量带 usage:null 仍完整成型(对照同)" {
    const a = std.testing.allocator;
    var got = try replayAgainstControl(
        a,
        "gpt-4o",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"arguments\":\"\"}}]}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"tz\\\":\"}}]}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"utc\\\"}\"}}]}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":null}\n\n" ++
            "data: [DONE]\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"arguments\":\"\"}}]}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"tz\\\":\"}}]}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"utc\\\"}\"}}]}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{.tool_use_start}, got.kinds.items);
    try std.testing.expectEqualStrings("call_1", got.tools.items[0].id);
    try std.testing.expectEqualStrings("get_time", got.tools.items[0].name);
    try std.testing.expectEqualStrings("{\"tz\":\"utc\"}", got.tools.items[0].input);
    try std.testing.expectEqual(StopReason.tool_use, got.stop);
    try std.testing.expectEqual(@as(usize, 0), got.usages.items.len);
}

test "issue #258: reasoning_content 带 usage:null 仍产 thinking(deepseek 方言,对照同)" {
    const a = std.testing.allocator;
    var got = try replayAgainstControl(
        a,
        "deepseek-chat",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"think\"}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\",\"reasoning_content\":null}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}\n\n" ++
            "data: [DONE]\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"think\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\",\"reasoning_content\":null}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .thinking, .text, .done }, got.kinds.items);
    try std.testing.expectEqualStrings("think", got.thinking.items);
    try std.testing.expectEqualStrings("ok", got.text.items);
    try std.testing.expectEqual(StopReason.end_turn, got.stop);
}

test "issue #258: 末尾 {choices:[],usage:{...}} 仍产正确 token/缓存数(前面 chunk 带 usage:null,对照同)" {
    const a = std.testing.allocator;
    const final_usage = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":2006,\"completion_tokens\":10,\"total_tokens\":2016," ++
        "\"prompt_tokens_details\":{\"cached_tokens\":1920},\"completion_tokens_details\":{\"reasoning_tokens\":0}}}\n\n";
    var got = try replayAgainstControl(
        a,
        "gpt-4o",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}],\"usage\":null}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}\n\n" ++
            final_usage ++ "data: [DONE]\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            final_usage ++ "data: [DONE]\n\n",
    );
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .usage, .done }, got.kinds.items);
    // prompt_tokens 含 cached:input = 2006-1920 = 86;cache_read = 1920;output = completion。
    try std.testing.expectEqualSlices(UsageDelta, &.{.{
        .input_tokens = 86,
        .output_tokens = 10,
        .cache_read_input_tokens = 1920,
        .cache_creation_input_tokens = 0,
    }}, got.usages.items);
    try std.testing.expectEqual(StopReason.end_turn, got.stop);
}

test "issue #258: 同 chunk 既有内容又有 usage 对象——两个都发,内容在前 usage 在后" {
    const a = std.testing.allocator;
    const want_usage = [_]UsageDelta{.{ .input_tokens = 8, .output_tokens = 2, .cache_read_input_tokens = 4 }};
    // usage 在 choices 之后 / 之前,结果一致。
    const fixtures = [_][]const u8{
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]," ++
            "\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":4}}}\n\n" ++
            "data: [DONE]\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
            "data: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":4}}," ++
            "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
    };
    for (fixtures) |sse| {
        var got = try replaySse(a, "gpt-4o", .chat_completions, sse);
        defer got.deinit(a);
        try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .text, .usage, .done }, got.kinds.items);
        try std.testing.expectEqualStrings("Hello", got.text.items);
        try std.testing.expectEqualSlices(UsageDelta, &want_usage, got.usages.items);
        try std.testing.expectEqual(StopReason.end_turn, got.stop);
    }

    // reasoning 增量 + usage 同 chunk:thinking 在前,usage 紧随。
    var reasoning = try replaySse(
        a,
        "deepseek-chat",
        .chat_completions,
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"r\"}}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\"},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer reasoning.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .thinking, .usage, .text, .done }, reasoning.kinds.items);
    try std.testing.expectEqualSlices(UsageDelta, &.{.{ .input_tokens = 3, .output_tokens = 1 }}, reasoning.usages.items);

    // tool_call 增量 + finish_reason + usage 同 chunk:增量不产事件,usage 先发,tool_use_start 在 flush 时到。
    var tool = try replaySse(
        a,
        "gpt-4o",
        .chat_completions,
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_9\",\"type\":\"function\"," ++
            "\"function\":{\"name\":\"get_time\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]," ++
            "\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer tool.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .usage, .tool_use_start }, tool.kinds.items);
    try std.testing.expectEqualStrings("call_9", tool.tools.items[0].id);
    try std.testing.expectEqual(StopReason.tool_use, tool.stop);
    try std.testing.expectEqualSlices(UsageDelta, &.{.{ .input_tokens = 5, .output_tokens = 3 }}, tool.usages.items);
}

test "issue #258: content 恰为 \"usage\" 是文本,不是 usage 事件" {
    const a = std.testing.allocator;
    var got = try replaySse(
        a,
        "gpt-4o",
        .chat_completions,
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"usage\"}}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .done }, got.kinds.items);
    try std.testing.expectEqualStrings("usage", got.text.items);
    try std.testing.expectEqual(@as(usize, 0), got.usages.items.len);
}

test "issue #258: choices[i].usage(兼容端位置)按 object 才计,null 不计;同块 finish_reason 保留" {
    const a = std.testing.allocator;
    var obj = try replaySse(
        a,
        "moonshot-v1-8k",
        .chat_completions,
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"usage\":null}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"," ++
            "\"usage\":{\"prompt_tokens\":19,\"completion_tokens\":13,\"total_tokens\":32}}]}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer obj.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .usage, .done }, obj.kinds.items);
    try std.testing.expectEqualStrings("hi", obj.text.items);
    try std.testing.expectEqualSlices(UsageDelta, &.{.{ .input_tokens = 19, .output_tokens = 13 }}, obj.usages.items);
    try std.testing.expectEqual(StopReason.end_turn, obj.stop);

    // 顶层 usage 对象优先于 choice 内的(只发一次,数取顶层)。
    var both = try replaySse(
        a,
        "gpt-4o",
        .chat_completions,
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\",\"usage\":{\"prompt_tokens\":1}}]," ++
            "\"usage\":{\"prompt_tokens\":40,\"completion_tokens\":2}}\n\n" ++
            "data: [DONE]\n\n",
    );
    defer both.deinit(a);
    try std.testing.expectEqualSlices(UsageDelta, &.{.{ .input_tokens = 40, .output_tokens = 2 }}, both.usages.items);
}

// Responses:usage 只在 `response.usage` 是 object 时发,数值只从该对象读。
test "issue #258 Responses: usage 从 response.usage 读——回显的 tools schema 里同名属性不干扰" {
    const a = std.testing.allocator;
    var got = try replaySse(
        a,
        "gpt-5.2",
        .responses,
        "event: response.created\n" ++
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\",\"usage\":null}}\n\n" ++
            "event: response.output_text.delta\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"hi\"}\n\n" ++
            "event: response.completed\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"," ++
            "\"tools\":[{\"type\":\"function\",\"name\":\"count\",\"parameters\":{\"type\":\"object\",\"properties\":" ++
            "{\"input_tokens\":{\"type\":\"integer\"},\"output_tokens\":{\"type\":\"integer\"},\"cached_tokens\":{\"type\":\"integer\"}}}}]," ++
            "\"usage\":{\"input_tokens\":2006,\"input_tokens_details\":{\"cached_tokens\":1920},\"output_tokens\":10}}}\n\n",
    );
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .usage, .done }, got.kinds.items);
    try std.testing.expectEqualStrings("hi", got.text.items);
    try std.testing.expectEqualSlices(UsageDelta, &.{.{
        .input_tokens = 86,
        .output_tokens = 10,
        .cache_read_input_tokens = 1920,
    }}, got.usages.items);
    try std.testing.expectEqual(StopReason.end_turn, got.stop);
}

test "issue #258 Responses: 终止事件 usage:null 不伪造全零 usage,flush 与 done 照常" {
    const a = std.testing.allocator;
    var text = try replaySse(
        a,
        "gpt-5.2",
        .responses,
        "event: response.output_text.delta\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"hi\"}\n\n" ++
            "event: response.completed\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"usage\":null}}\n\n",
    );
    defer text.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .done }, text.kinds.items);
    try std.testing.expectEqualStrings("hi", text.text.items);
    try std.testing.expectEqual(@as(usize, 0), text.usages.items.len);
    try std.testing.expectEqual(StopReason.end_turn, text.stop);

    var tool = try replaySse(
        a,
        "gpt-5.2",
        .responses,
        "event: response.output_item.added\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_r1\",\"name\":\"get_time\",\"arguments\":\"\"}}\n\n" ++
            "event: response.function_call_arguments.done\n" ++
            "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"output_index\":0,\"arguments\":\"{}\"}\n\n" ++
            "event: response.incomplete\n" ++
            "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_3\",\"status\":\"incomplete\"," ++
            "\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n",
    );
    defer tool.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .tool_use_start, .done }, tool.kinds.items);
    try std.testing.expectEqualStrings("call_r1", tool.tools.items[0].id);
    try std.testing.expectEqual(@as(usize, 0), tool.usages.items.len);
    try std.testing.expectEqual(StopReason.max_tokens, tool.stop);
}

// ── issue #269:流在报告停止原因之前结束,不是收尾 ─────────────────────────────

/// 驱动 OpenAIStream 直到流结束或出错,把出错前收到的事件种类追加进 `kinds`;错误原样上抛。
fn replayUntilError(a: std.mem.Allocator, protocol: types.OpenAIProtocol, sse: []const u8, kinds: *std.ArrayList(std.meta.Tag(StreamEvent))) !void {
    var stream = OpenAIStream{
        .allocator = a,
        .model = "m",
        .dialect = dialect_mod.dialectFor(.openai, "m"),
        .protocol = protocol,
        .request = undefined,
        .response = undefined,
        .id = .{ .bytes = .{0} ** 12 },
    };
    defer stream.releaseParseState();
    var body = std.Io.Reader.fixed(sse);
    stream.reader = &body;
    while (stream.next() catch |err| {
        // 失败即终态:之后不再读出任何东西(对齐 stream.zig 的 fail-terminal 契约)。
        try std.testing.expect((try stream.next()) == null);
        return err;
    }) |ev| {
        switch (ev) {
            .text, .thinking, .reasoning_item, .web_search_query => |bytes| a.free(bytes),
            .tool_use_start => |tu| {
                a.free(tu.id);
                a.free(tu.name);
                a.free(tu.input_json);
            },
            .web_search_result => |w| {
                a.free(w.ui_text);
                a.free(w.content_json);
            },
            .usage, .done => {},
        }
        try kinds.append(a, std.meta.activeTag(ev));
    }
}

test "issue #269 chat: [DONE] without any finish_reason is StreamIncomplete, not end_turn" {
    const a = std.testing.allocator;
    var kinds: std.ArrayList(std.meta.Tag(StreamEvent)) = .empty;
    defer kinds.deinit(a);
    // The final chunk carrying finish_reason never arrived; `[DONE]` did.
    try std.testing.expectError(error.StreamIncomplete, replayUntilError(a, .chat_completions, "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"part one\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\" part two\"},\"finish_reason\":null}]}\n\n" ++
        "data: [DONE]\n\n", &kinds));
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .text }, kinds.items);
}

test "issue #269 chat: clean EOF with neither finish_reason nor [DONE] is StreamIncomplete" {
    const a = std.testing.allocator;
    var kinds: std.ArrayList(std.meta.Tag(StreamEvent)) = .empty;
    defer kinds.deinit(a);
    try std.testing.expectError(error.StreamIncomplete, replayUntilError(a, .chat_completions, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n", &kinds));
}

test "issue #269 chat: half-built tool_calls are not flushed from an unterminated stream" {
    const a = std.testing.allocator;
    var kinds: std.ArrayList(std.meta.Tag(StreamEvent)) = .empty;
    defer kinds.deinit(a);
    try std.testing.expectError(error.StreamIncomplete, replayUntilError(a, .chat_completions, "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"Read\",\"arguments\":\"{\\\"file_path\\\":\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: [DONE]\n\n", &kinds));
    // No tool_use_start: arguments that never finished must not reach a tool.
    try std.testing.expectEqual(@as(usize, 0), kinds.items.len);
}

test "issue #269 chat: finish_reason then EOF without [DONE] keeps the answer and its stop" {
    const a = std.testing.allocator;
    // Only the frame tail (and any usage chunk after it) is missing; the stop
    // status — here the `length` marker the continuation net needs — arrived.
    var got = try replaySse(a, "m", .chat_completions, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"cut\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n");
    defer got.deinit(a);
    try std.testing.expectEqualStrings("cut", got.text.items);
    try std.testing.expectEqual(StopReason.max_tokens, got.stop);
}

test "issue #317 chat: successful stream without usage stays accepted and emits no zero sample" {
    const a = std.testing.allocator;
    var got = try replaySse(a, "gpt-4o", .chat_completions, "data: {\"choices\":[{\"delta\":{\"content\":\"HELLO\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n");
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .done }, got.kinds.items);
    try std.testing.expectEqualStrings("HELLO", got.text.items);
    try std.testing.expectEqual(StopReason.end_turn, got.stop);
    try std.testing.expectEqual(@as(usize, 0), got.usages.items.len);
}

test "issue #317 chat: accepted tail loss keeps answer and marks usage unavailable" {
    const a = std.testing.allocator;
    // The provider reported how the answer stopped, then the clean EOF lost
    // both the optional usage tail and [DONE]. The existing acceptance rule is
    // deliberate: answer bytes and stop status remain usable.
    var got = try replaySse(a, "gpt-4o", .chat_completions, "data: {\"choices\":[{\"delta\":{\"content\":\"TAIL\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n");
    defer got.deinit(a);
    try std.testing.expectEqualStrings("TAIL", got.text.items);
    try std.testing.expectEqual(StopReason.end_turn, got.stop);
    // A clean EOF after the stop marker is accepted, but there is no trailing
    // [DONE] frame from which to synthesize a separate done event.
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{.text}, got.kinds.items);
    try std.testing.expectEqual(@as(usize, 0), got.usages.items.len);
}

test "issue #317 chat: unreadable usage counters do not become known zero" {
    const a = std.testing.allocator;
    var unreadable = try replaySse(a, "gpt-4o", .chat_completions, "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":\"11\",\"completion_tokens\":\"7\"}}\n\n" ++
        "data: [DONE]\n\n");
    defer unreadable.deinit(a);
    try std.testing.expectEqualStrings("OK", unreadable.text.items);
    try std.testing.expectEqual(StopReason.end_turn, unreadable.stop);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .done }, unreadable.kinds.items);
    try std.testing.expectEqual(@as(usize, 0), unreadable.usages.items.len);

    // Explicit numeric zero is a real report and must remain distinguishable
    // from the unavailable cases above.
    var known_zero = try replaySse(a, "gpt-4o", .chat_completions, "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0}}\n\n" ++
        "data: [DONE]\n\n");
    defer known_zero.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .usage, .done }, known_zero.kinds.items);
    try std.testing.expectEqualSlices(UsageDelta, &.{.{}}, known_zero.usages.items);
}

test "issue #269 chat: an empty finish_reason on an intermediate chunk is not a stop report" {
    const a = std.testing.allocator;
    var kinds: std.ArrayList(std.meta.Tag(StreamEvent)) = .empty;
    defer kinds.deinit(a);
    try std.testing.expectError(error.StreamIncomplete, replayUntilError(a, .chat_completions, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"\"}]}\n\n" ++
        "data: [DONE]\n\n", &kinds));
}

test "issue #269 chat: an unrecognized finish_reason still counts as reported" {
    const a = std.testing.allocator;
    var got = try replaySse(a, "m", .chat_completions, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"content_filter\"}]}\n\n" ++
        "data: [DONE]\n\n");
    defer got.deinit(a);
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{ .text, .done }, got.kinds.items);
    try std.testing.expectEqual(StopReason.unknown, got.stop);
}

test "issue #269 Responses: EOF without response.completed/incomplete is StreamIncomplete" {
    const a = std.testing.allocator;
    var kinds: std.ArrayList(std.meta.Tag(StreamEvent)) = .empty;
    defer kinds.deinit(a);
    try std.testing.expectError(error.StreamIncomplete, replayUntilError(a, .responses, "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"hi\"}\n\n" ++
        "event: response.output_text.done\n" ++
        "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":0,\"text\":\"hi\"}\n\n", &kinds));
    try std.testing.expectEqualSlices(std.meta.Tag(StreamEvent), &.{.text}, kinds.items);
}

test "issue #269 chat: a cancelled stream's leftover [DONE] is Aborted, not StreamIncomplete" {
    // Cancellation closes the socket; a [DONE] already buffered is a symptom
    // of the cancel, and the loop must see a cancel (no retry, partial kept).
    const a = std.testing.allocator;
    var signal = AbortSignal.init();
    var stream = OpenAIStream{
        .allocator = a,
        .model = "m",
        .dialect = dialect_mod.dialectFor(.openai, "m"),
        .protocol = .chat_completions,
        .request = undefined,
        .response = undefined,
        .id = .{ .bytes = .{0} ** 12 },
        .abort = &signal,
    };
    defer stream.releaseParseState();
    var body = std.Io.Reader.fixed("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"part\"},\"finish_reason\":null}]}\n\n" ++
        "data: [DONE]\n\n");
    stream.reader = &body;
    const first = (try stream.next()).?;
    a.free(first.text);
    signal.abort(.user_ctrl_c);
    // The line loop checks abort before reading; reproduce the race where the
    // flag lands after the [DONE] line was read by calling the terminal path.
    try std.testing.expectError(error.Aborted, @as(anyerror!void, stream.incomplete()));
}

test "issue #269 Responses: a [DONE] sentinel does not stand in for the terminal event" {
    const a = std.testing.allocator;
    var kinds: std.ArrayList(std.meta.Tag(StreamEvent)) = .empty;
    defer kinds.deinit(a);
    try std.testing.expectError(error.StreamIncomplete, replayUntilError(a, .responses, "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"hi\"}\n\n" ++
        "data: [DONE]\n\n", &kinds));
}

test "OpenAIClient: catalog then Host declarations answer image input, Host first (issue #273)" {
    const a = std.testing.allocator;
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = OpenAIClient.init(a, io_rt.io(), "k", "vendor-x", "http://localhost");
    defer client.deinit();
    const p = client.provider();
    // The family table alone.
    try std.testing.expectEqual(false, p.supports(.image_input));
    try std.testing.expectEqual(
        if (false) image_capability.Source.model_family else image_capability.Source.unknown,
        p.imageInput(null).source,
    );
    // A catalog declaration overrides the family table, in both directions.
    var catalog = catalog_mod.Catalog.init(a);
    try catalog.loadFromModelsListJson("{\"data\":[{\"id\":\"vendor-x\",\"capabilities\":{\"image_input\":{\"supported\":true}}}]}");
    client.catalog = catalog;
    try std.testing.expectEqual(!false, p.supports(.image_input));
    try std.testing.expectEqual(image_capability.Source.catalog, p.imageInput(null).source);
    try std.testing.expectEqual(!false, client.dialectFor("vendor-x").profileFor(.openai, "vendor-x").supports_image_input);
    // A Host declaration outranks the catalog, for this and any named model.
    client.host_capabilities = try image_capability.Declarations.init(a, &.{.{ .model = "vendor-x", .image_input = false }});
    try std.testing.expectEqual(false, p.supports(.image_input));
    try std.testing.expectEqual(image_capability.Source.host, p.imageInput(null).source);
    try std.testing.expectEqual(image_capability.Source.unknown, p.imageInput("vendor-unlisted").source);
}
