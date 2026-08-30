//! GeminiClient:讲 Google Gemini generateContent 协议的 Provider 实现(多 Provider 重构 C3)。
//!
//! 证明点:这是**第三个**真 provider——它验证缓存扩展点的"有状态对象"范式(区别于 Anthropic 显式
//! 断点、OpenAI 全自动前缀)。同一个 agent_loop / Conversation / 中立 IR / provider.zig 一行不改跑通。
//!
//! 协议差异(本文件锁住的脏活,与 Anthropic/OpenAI 都不同):
//!   - URL:{base}/v1beta/models/{model}:streamGenerateContent?alt=sse
//!   - 认证:x-goog-api-key header(非 Authorization)
//!   - 请求 body:{systemInstruction:{parts}, contents:[{role:user|model, parts:[{text}|{functionCall}
//!     |{functionResponse}]}], tools:[{function_declarations:[...]}], cachedContent:"<name>"?}
//!   - 角色:assistant→"model"(非 "assistant");tool_result→ user 角色的 functionResponse part
//!   - SSE:data: {candidates:[{content:{parts:[{text}|{functionCall:{name,args}}]}, finishReason}],
//!     usageMetadata:{promptTokenCount,candidatesTokenCount,cachedContentTokenCount}}
//!
//! **缓存范式 = 有状态对象(stateful_object)**:Gemini 显式缓存是 createCachedContent 建一个有
//! `name` 句柄、有 TTL、会 404 过期的远程对象。本 client 持一张 {prefix_hash → CacheEntry} 句柄表,
//! prepareCache 时查表:命中且未过期 → 请求带 cachedContent 引用;未命中/过期 → (MVP)走隐式缓存
//! (不主动 createCachedContent,留扩展点)。这张表是 GeminiClient **私有**,不上浮中立契约。
//!
//! **诚实登记——以下未做(文件头,别假装支持)**:
//!   - **显式 createCachedContent**:MVP 只实现句柄表机制 + 隐式缓存读命中(cachedContentTokenCount)。
//!     主动建缓存对象(POST cachedContents)+ 404 重建留 hook(prepareCacheExplicit 签名留,不实现)。
//!   - **并行 functionCall(P0.1 已实现)**:一个 chunk 的 parts 多个 functionCall 全部 emit
//!     (首个返回、其余排队 drain);functionResponse.name 按 tool_use_id 从全量消息找回真实工具名
//!     配对(Gemini 靠 name 配对)。见 parseChunk functionCall 循环 / serializeGeminiContent。
//!   - **建连重试 / 非流式 / thinking(thought parts)**:未做。(多模态 inline_data 的
//!     图像**输入**已做——user 消息 image block 经 GeminiDialect.serializeImagePart 发
//!     inline_data part,issue #10;图像输出/其它媒体仍未做。)
//!   - **max_tokens/context_window**:硬编码,未按 model 区分(Gemini 1.5 Pro 2M 等)。
//!
//! 取舍登记:keep_alive=false(每请求新连接)——牺牲真后端连接池(省 TLS 握手)换稳定性;
//! 流式请求被长流独占,池化收益本就小,且当前 per-job client 用法几乎不复用连接。

const std = @import("std");
const http = std.http;
const connection_gate = @import("connection_gate.zig");
const ResponseStatus = @import("http_status.zig").ResponseStatus;
const log = @import("../util/log.zig");
const types = @import("../types.zig");
const json_mod = @import("../json.zig");
const util_json = @import("../util/json.zig");
const api_stream = @import("stream.zig");
const provider_mod = @import("provider.zig");
const capability = @import("capability.zig");
const cache = @import("cache.zig");
const request_overrides = @import("request_overrides.zig");
const dialect_mod = @import("dialect.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

const StreamEvent = api_stream.StreamEvent;
const StreamHandle = api_stream.StreamHandle;
const StopReason = api_stream.StopReason;
const UsageDelta = api_stream.UsageDelta;

/// 默认 Gemini 端点基址(不含 model + :streamGenerateContent,doStream 拼)。
pub const DEFAULT_GEMINI_BASE = "https://generativelanguage.googleapis.com";

/// 有状态缓存句柄表的一项:prefix 哈希 → 远程 cache 对象名 + 过期时刻。
/// **Gemini 缓存范式的核心**:与 Anthropic/OpenAI 的"无状态前缀哈希"不同,Gemini 显式缓存是
/// 远程对象,客户端必须持句柄并管理生命周期。
/// **时钟语义**:expire_mono_ms 是**单调时钟毫秒**(util/time.nowMs 同源),非 wall-clock epoch。
/// TTL 当作 duration 用:registerCache 时传 `nowMonoMs() + ttl_ms`。单调时钟做 TTL 更稳(不受系统
/// 改时间影响)。**切勿传 std.time.timestamp()(wall epoch≈1.7e9)→ 与单调 now 比永不过期 = bug**。
pub const CacheEntry = struct {
    prefix_hash: u64,
    cache_name: []const u8, // "cachedContents/abc123";owned
    expire_mono_ms: i64, // 过期时刻(单调时钟毫秒);<=now 视为过期,需重建
};

/// 合成 functionCall id 的进程级单调序号(Gemini 不回传 tool id)。
/// dispatch_id 要求会话内全局唯一;u64 不 wrap,原子递增线程安全。
var g_call_serial = std.atomic.Value(u64).init(1);

pub const GeminiClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8, // 基址(可指向 MockServer);doStream 拼 model + :streamGenerateContent
    model: []const u8,
    http_client: http.Client,
    abort_registry: provider_mod.RequestAbortRegistry = .{},
    max_tokens: u32 = 8192,
    context_window: u32 = 1_048_576, // Gemini 1.5/2.x 默认 1M(保守;未按 model 区分)
    /// thinking 控制(effort 档位)。null = 自适应(Gemini 2.5 默认开 thinking,无需显式)。
    /// 非null → serializeGeminiRequest 经 GeminiDialect.serializeThinking 翻成
    /// generation_config.thinking_level(low/high)。
    reasoning_effort: ?types.ReasoningEffort = null,
    /// 方言字段覆盖(null = profile 默认)。来源:计划 jolly-glacier。
    overrides: request_overrides.RequestOverrides = .{},
    dialect_resolver: dialect_mod.Resolver = .{},

    /// 有状态缓存句柄表(GeminiClient 私有,不上浮中立契约)。
    /// prepareCache 据 system+tools 的 prefix 哈希查表命中则引用,未命中/过期则(MVP)走隐式。
    cache_table: std.ArrayList(CacheEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, base_url: ?[]const u8) GeminiClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .base_url = base_url orelse DEFAULT_GEMINI_BASE,
            .model = model,
            .http_client = http.Client{ .allocator = allocator, .io = io },
        };
    }
    pub fn deinit(self: *GeminiClient) void {
        self.abort_registry.deinit(self.allocator);
        for (self.cache_table.items) |e| self.allocator.free(e.cache_name);
        self.cache_table.deinit(self.allocator);
        self.http_client.deinit();
    }

    // ── 有状态缓存查表(Gemini 范式核心)──────────────────────────────────────
    /// 据 prefix 哈希查句柄表:命中且未过期 → 返回 cache_name(请求带 cachedContent 引用);
    /// 未命中/过期 → 返回 null(MVP 走隐式缓存,不主动建对象)。过期项原地剔除(模拟 404 失效处理)。
    /// now_mono_ms:单调时钟毫秒(nowMonoMs())。
    pub fn lookupCache(self: *GeminiClient, prefix_hash: u64, now_mono_ms: i64) ?[]const u8 {
        var i: usize = 0;
        while (i < self.cache_table.items.len) {
            const e = self.cache_table.items[i];
            if (e.prefix_hash == prefix_hash) {
                if (e.expire_mono_ms > now_mono_ms) return e.cache_name;
                // 过期:剔除句柄(对齐 Gemini 404 CachedContent not found → 删本地引用)。
                self.allocator.free(e.cache_name);
                _ = self.cache_table.swapRemove(i);
                return null;
            }
            i += 1;
        }
        return null;
    }

    /// 注册一个缓存句柄(模拟 createCachedContent 成功后存句柄;真显式缓存的写侧扩展点)。
    /// MVP 不在 doStream 里自动调用——留给"显式 createCachedContent"扩展(诚实登记未做)。
    /// expire_mono_ms:单调时钟毫秒过期时刻,传 `nowMonoMs() + ttl_ms`(切勿传 wall epoch)。
    pub fn registerCache(self: *GeminiClient, prefix_hash: u64, cache_name: []const u8, expire_mono_ms: i64) !void {
        const owned = try self.allocator.dupe(u8, cache_name);
        errdefer self.allocator.free(owned);
        try self.cache_table.append(self.allocator, .{
            .prefix_hash = prefix_hash,
            .cache_name = owned,
            .expire_mono_ms = expire_mono_ms,
        });
    }

    // ── Provider vtable ──────────────────────────────────────────────────────
    pub fn provider(self: *GeminiClient) provider_mod.Provider {
        return .{
            .ctx = @ptrCast(self),
            .modelFn = &pModel,
            .sendStreamFn = &pSendStream,
            .sendStreamRetryFn = &pSendStreamRetry,
            .sendFn = &pSend,
            .cancelFn = &pCancel,
            .maxTokensFn = &pMaxTokens,
            .maxInputTokensFn = &pMaxInputTokens,
            .reasoningEffortFn = &pReasoningEffort,
            .requestOverridesFn = &pRequestOverrides,
            .setRequestOverridesFn = &pSetRequestOverrides,
            .supportsFn = &pSupports,
        };
    }
    inline fn cast(ctx: *anyopaque) *GeminiClient {
        return @ptrCast(@alignCast(ctx));
    }
    fn pModel(ctx: *anyopaque) []const u8 {
        return cast(ctx).model;
    }
    /// Provider.requestOverrides() 返回 Client.overrides;镜像 reasoning_effort 兜底。
    fn pRequestOverrides(ctx: *anyopaque) request_overrides.RequestOverrides {
        const self = cast(ctx);
        var o = self.overrides;
        if (o.reasoning_effort == null) o.reasoning_effort = self.reasoning_effort;
        return o;
    }
    fn pSetRequestOverrides(ctx: *anyopaque, o: request_overrides.RequestOverrides) void {
        cast(ctx).overrides = o;
        if (o.reasoning_effort) |e| cast(ctx).reasoning_effort = e;
    }
    fn pMaxTokens(ctx: *anyopaque) u32 {
        return cast(ctx).max_tokens;
    }
    fn pMaxInputTokens(ctx: *anyopaque) u32 {
        return cast(ctx).context_window;
    }
    fn pReasoningEffort(_: *anyopaque) ?types.ReasoningEffort {
        return null;
    }
    fn pSupports(ctx: *anyopaque, cap: provider_mod.Capability) bool {
        return capability.supports(.gemini, cast(ctx).model, cap);
    }
    fn pSend(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, model_override: ?[]const u8) anyerror!provider_mod.ApiResponse {
        _ = ctx;
        _ = messages;
        _ = system;
        _ = tools;
        _ = model_override;
        return error.NotImplemented; // 非流式未实现(compact 退 keep-recent)
    }
    fn pCancel(ctx: *anyopaque, signal: *const AbortSignal) void {
        cast(ctx).abort_registry.cancel(signal);
    }
    fn pSendStreamRetry(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, max_retries: u32, retry_base_ms: u64, reporter: ?provider_mod.RetryReporter, user_query: []const u8) anyerror!StreamHandle {
        _ = max_retries;
        _ = retry_base_ms;
        _ = reporter;
        return pSendStream(ctx, messages, system, tools, abort, model_override, tool_choice, user_query);
    }
    fn pSendStream(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!StreamHandle {
        _ = user_query;
        const self = cast(ctx);
        const model = model_override orelse self.model;
        // prepareCache(写侧):查句柄表,命中未过期则请求带 cachedContent 引用。
        // 哈希 key 含 model:Gemini 缓存对象 model-specific,不含 model 会让 model_override 路径
        // 误命中别的 model 的句柄 → 发 400/404(C 修复)。
        const prefix_hash = hashPrefix(model, system, tools);
        const cached_ref = self.lookupCache(prefix_hash, nowMonoMs());
        var overrides = self.overrides;
        if (overrides.reasoning_effort == null) overrides.reasoning_effort = self.reasoning_effort;
        overrides.tool_choice = tool_choice;
        const dialect = self.dialect_resolver.resolve(.gemini, model);
        const body = try serializeGeminiRequestWithOverridesAndDialect(
            self.allocator,
            messages,
            system,
            tools,
            cached_ref,
            model,
            overrides,
            dialect,
        );
        defer self.allocator.free(body);
        return self.doStream(model, body, abort);
    }

    /// 发 HTTP POST + 包成中立 StreamHandle。URL 拼 model + :streamGenerateContent?alt=sse。
    fn doStream(self: *GeminiClient, model: []const u8, body: []const u8, abort: ?*const AbortSignal) !StreamHandle {
        const rid = log.genRequestId();
        // {base}/v1beta/models/{model}:streamGenerateContent?alt=sse
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse", .{ self.base_url, model });
        defer self.allocator.free(url);
        log.infoId("gemini", rid, "POST {s} body_bytes={d} cache_mode={s}", .{ url, body.len, cache.modeFor(.gemini).label() });
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        const req_ptr = try self.allocator.create(http.Client.Request);
        errdefer self.allocator.destroy(req_ptr); // 唯一 destroy:所有错误路径都靠它(不手动 destroy,否则 double-free)
        var connection_lease = try connection_gate.acquire(abort);
        defer connection_lease.release();
        req_ptr.* = self.http_client.request(.POST, uri, .{
            // 每请求独立连接:不复用 pooled 连接，避免"干净 EOF→连接入池→复用已弃连接
            // →HttpConnectionClosing"；process-wide connection_gate 负责限制握手洪峰。
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-goog-api-key", .value = self.api_key },
            },
        }) catch |err| {
            log.errId("gemini", rid, "request init failed: {s}", .{@errorName(err)});
            return error.RequestFailed; // errdefer destroy(req_ptr);req_ptr.* 未初始化, 无需 deinit
        };
        var registered = false;
        errdefer {
            if (registered) self.abort_registry.unregister(req_ptr);
            req_ptr.deinit();
        }
        if (abort) |signal| {
            try self.abort_registry.register(
                self.allocator,
                signal,
                req_ptr,
                shutdownRequest,
            );
            registered = true;
        }
        req_ptr.transfer_encoding = .{ .content_length = body.len };
        req_ptr.sendBodyComplete(@constCast(body)) catch |err| {
            log.errId("gemini", rid, "send body failed: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        const response = req_ptr.receiveHead(&.{}) catch |err| {
            log.errId("gemini", rid, "receiveHead failed: {s}", .{@errorName(err)});
            return err;
        };
        const status = ResponseStatus.capture(&response);
        connection_lease.release();
        if (!status.isOk()) {
            log.errId("gemini", rid, "HTTP {d} {s}", .{ status.code, status.name });
            return error.RequestFailed;
        }
        // receiveHead 成功后,req_ptr.* 是个开着连接的完整 Request。到 heap 转移所有权之前若出错
        // (create(GeminiStream) OOM),必须 deinit 它(否则泄漏 socket fd + 连接状态,非纯字节)。
        // errdefer LIFO:此 deinit 先跑、顶部 destroy 后跑 = 正确的 deinit()→destroy() 顺序。
        const heap = try self.allocator.create(GeminiStream);
        // create 成功 → 所有权转移给 GeminiStream(其 deinit 负责 req_ptr.deinit()+destroy);
        // 正常返回,两个 errdefer 都不触发。
        heap.* = .{
            .allocator = self.allocator,
            .request = req_ptr,
            .response = response,
            .abort = abort,
            .abort_registry = if (abort != null) &self.abort_registry else null,
            .id = rid,
        };
        return heap.handle();
    }
};

/// Gemini 流式响应:逐行 SSE 解析,翻译 candidates[].content.parts → 中立 StreamEvent。
const GeminiStream = struct {
    allocator: std.mem.Allocator,
    request: *http.Client.Request,
    response: http.Client.Response,
    transfer_buf: [8192]u8 = undefined,
    reader: ?*std.Io.Reader = null,
    abort: ?*const AbortSignal = null,
    abort_registry: ?*provider_mod.RequestAbortRegistry = null,
    id: log.RequestId,
    done: bool = false,
    last_stop: StopReason = .unknown,
    fc_counter: u32 = 0, // functionCall 计数(Gemini 无 id,自生成 call_N)
    /// 并行 functionCall 队列(P0.1):一个 Gemini chunk 的 parts 可含多个 functionCall。
    /// 一次 next() 只能吐一个事件,故首个直接返回、其余排队,后续 next() 逐个 drain。
    fc_queue: std.ArrayList(StreamEvent) = .empty,
    fc_pos: usize = 0,
    /// pending usage 槽:Gemini 常把 usageMetadata 与末 content chunk 合并(text+finishReason+usage 同 chunk)。
    /// 一个 chunk 只能 emit 一个 StreamEvent,故先 emit 内容、把 usage 存这里,下次 next() 先吐它。
    /// 不这样做 → usage 在最常见的"内容+usage 同 chunk"路径被静默丢(E 类 bug)。
    pending_usage: ?UsageDelta = null,

    fn handle(self: *GeminiStream) StreamHandle {
        return .{ .ctx = @ptrCast(self), .nextFn = &hNext, .deinitFn = &hDeinit, .stopReasonFn = &hStop, .requestIdFn = &hRid };
    }
    fn hNext(ctx: *anyopaque) anyerror!?StreamEvent {
        return @as(*GeminiStream, @ptrCast(@alignCast(ctx))).next();
    }
    fn hDeinit(ctx: *anyopaque) void {
        const s: *GeminiStream = @ptrCast(@alignCast(ctx));
        const a = s.allocator;
        s.deinit();
        a.destroy(s);
    }
    fn hStop(ctx: *anyopaque) StopReason {
        return @as(*GeminiStream, @ptrCast(@alignCast(ctx))).last_stop;
    }
    fn hRid(ctx: *anyopaque) log.RequestId {
        return @as(*GeminiStream, @ptrCast(@alignCast(ctx))).id;
    }
    fn deinit(self: *GeminiStream) void {
        // 未 drain 的并行 functionCall 事件持 owned id/name/input_json → 释放防泄漏。
        for (self.fc_queue.items[self.fc_pos..]) |ev| freeToolUseStart(self.allocator, ev);
        self.fc_queue.deinit(self.allocator);
        if (self.abort_registry) |registry| registry.unregister(self.request);
        self.request.deinit();
        self.allocator.destroy(self.request);
    }

    fn next(self: *GeminiStream) anyerror!?StreamEvent {
        // 并行 functionCall 队列优先 drain(一个 chunk 多个 functionCall 的其余)。
        if (self.fc_pos < self.fc_queue.items.len) {
            const ev = self.fc_queue.items[self.fc_pos];
            self.fc_pos += 1;
            return ev;
        }
        // pending usage 优先吐(上一个 chunk 内容+usage 合并时存的)。
        if (self.pending_usage) |u| {
            self.pending_usage = null;
            return StreamEvent{ .usage = u };
        }
        if (self.done) return null;
        if (self.reader == null) self.reader = self.response.reader(&self.transfer_buf);
        const r = self.reader.?;
        while (true) {
            if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
            const line_opt = try r.takeDelimiter('\n');
            const line = line_opt orelse {
                self.done = true;
                // 流尽:若还有 pending usage(末 chunk 只含内容+usage,内容已 emit),吐它。
                if (self.pending_usage) |u| {
                    self.pending_usage = null;
                    return StreamEvent{ .usage = u };
                }
                return null;
            };
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const data = std.mem.trim(u8, trimmed[5..], " ");
            if (try self.parseChunk(data)) |ev| return ev;
            // 该 chunk 无可 emit 内容(纯 usage/finishReason)→ parseChunk 已可能直接返回 usage;
            // 否则继续读下一行。
        }
    }

    /// 解析一个 Gemini SSE chunk(完整 GenerateContentResponse JSON)→ 中立 StreamEvent。
    fn parseChunk(self: *GeminiStream, data: []const u8) !?StreamEvent {
        if (util_json.extractStringField(data, "finishReason")) |fr| self.last_stop = mapGeminiFinish(fr);

        // usageMetadata → 中立 UsageDelta(含 cachedContentTokenCount → cache_read,经 cache.zig)。
        // **关键(E 修复)**:Gemini 常把 usageMetadata 与末 content chunk(text+finishReason)合并。
        // 一个 chunk 只能返回一个 StreamEvent,故:先把 usage 算好存进 pending_usage;若本 chunk 还有
        // 内容(text/functionCall)→ 下面 emit 内容,usage 由 next() 下次吐;若本 chunk 无内容 → 直接吐 usage。
        // 这保证"内容+usage 同 chunk"时 usage 不被静默丢(旧逻辑只在无内容 chunk emit usage = 丢)。
        if (std.mem.indexOf(u8, data, "\"usageMetadata\"") != null) {
            const cu = cache.parseGeminiCacheUsage(data);
            // 语义归一(Anthropic-exclusive):Gemini 的 promptTokenCount **包含**
            // cachedContentTokenCount;中立 UsageDelta 的 input_tokens 不含 cache,
            // 消费方按 in+cache_r+cache_w 求和(usage 锚点/成本)——不减会双计。
            const usage = UsageDelta{
                .input_tokens = util_json.extractIntField(data, "promptTokenCount") -| cu.read_tokens,
                .output_tokens = util_json.extractIntField(data, "candidatesTokenCount"),
                .cache_read_input_tokens = cu.read_tokens,
                .cache_creation_input_tokens = cu.creation_tokens,
            };
            const has_text = util_json.extractStringField(data, "text") != null;
            const has_fc = std.mem.indexOf(u8, data, "\"functionCall\"") != null;
            if (!has_text and !has_fc) return StreamEvent{ .usage = usage }; // 纯 usage chunk → 直接吐
            self.pending_usage = usage; // 内容+usage 同 chunk → 存,内容先 emit(见下),next() 再吐 usage
        }

        // functionCall → 中立 tool_use_start。Gemini: parts:[{functionCall:{name,args:{...}}}]
        // P0.1 并行:一个 chunk 的 parts 可含多个 functionCall,**全部** emit(首个返回、其余排队)。
        if (std.mem.indexOf(u8, data, "\"functionCall\"") != null) {
            var first_ev: ?StreamEvent = null;
            // OOM 时释放已建首事件(未入队、未返回)——不留孤儿 owned 分配(Linus #2)。
            errdefer if (first_ev) |ev| freeToolUseStart(self.allocator, ev);
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, data, search, "\"functionCall\":")) |fc_at| {
                // 取 "functionCall": 后的 {...} 对象(括号配平),拿到对象文本 + 结束偏移。
                const bo = braceObject(data, fc_at + "\"functionCall\":".len) orelse {
                    search = fc_at + 1;
                    continue;
                };
                search = bo.end; // 跳过本对象继续找下一个 functionCall
                const obj = bo.obj;
                const name = util_json.extractStringField(obj, "name") orelse continue;
                const args = extractArgsObject(obj) orelse "{}";
                self.fc_counter += 1;
                // dispatch_id 是观察日志/规则门/审计的全局身份,重复 = trace
                // fail-closed + journal 封死(2026-08-17 harness review 发射侧 #1)。
                // GeminiStream 每请求新建,fc_counter 每轮归零,裸 call_N 跨轮必撞;
                // RequestId 只含 seq 低 16 位,65536 次请求后也会 wrap(生成器自述
                // "够 grep 用,不是密码学 ID")。唯一性由进程级单调 u64 承担
                // (2^64 不 wrap);rid 仍掺入,供与请求日志对账。
                const serial = g_call_serial.fetchAdd(1, .monotonic);
                var id_buf: [64]u8 = undefined;
                const id_str = std.fmt.bufPrint(
                    &id_buf,
                    "call_{s}_{d}_{d}",
                    .{ self.id.asSlice(), serial, self.fc_counter },
                ) catch unreachable; // 5+12+1+20+1+10 = 49 < 64,编译期可证

                // 逐段 dupe + 逐段 errdefer:任一 dupe/append 失败都释放本迭代已 owned 的段(无泄漏)。
                const id_dup = try self.allocator.dupe(u8, id_str);
                errdefer self.allocator.free(id_dup);
                const name_dup = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(name_dup);
                const args_dup = try self.allocator.dupe(u8, args);
                errdefer self.allocator.free(args_dup);
                const ev = StreamEvent{ .tool_use_start = .{ .id = id_dup, .name = name_dup, .input_json = args_dup } };
                if (first_ev == null) first_ev = ev else try self.fc_queue.append(self.allocator, ev);
            }
            if (first_ev) |ev| return ev;
        }
        // text part → 中立 text。Gemini: parts:[{text:"..."}]
        if (util_json.extractStringField(data, "text")) |text| {
            if (text.len > 0) {
                // text 是 raw escaped(JSON 内层)→ 反转义成真文本(对齐 Anthropic/OpenAI 的 owned text)。
                const owned = try util_json.unescapeString(text, self.allocator);
                return StreamEvent{ .text = owned };
            }
        }
        return null;
    }
};

fn shutdownRequest(raw: *anyopaque) void {
    const request: *http.Client.Request = @ptrCast(@alignCast(raw));
    provider_mod.abortHttpRequest(request);
}

fn mapGeminiFinish(fr: []const u8) StopReason {
    if (std.mem.eql(u8, fr, "STOP")) return .end_turn;
    if (std.mem.eql(u8, fr, "MAX_TOKENS")) return .max_tokens;
    // Gemini 工具调用不单独给 finishReason(functionCall 在 parts 里),保守 unknown→上层据 tool_use 续轮。
    return .unknown;
}

/// 释放一个 tool_use_start 事件的 owned 字段(id/name/input_json)。其它变体 no-op。
fn freeToolUseStart(allocator: std.mem.Allocator, ev: StreamEvent) void {
    switch (ev) {
        .tool_use_start => |tu| {
            allocator.free(tu.id);
            allocator.free(tu.name);
            allocator.free(tu.input_json);
        },
        else => {},
    }
}

/// 从 `from` 起跳空白,取一个 {...} 对象(括号配平,跳字符串)。返回对象文本 + 结束偏移(供续找)。
fn braceObject(data: []const u8, from: usize) ?struct { obj: []const u8, end: usize } {
    var i = from;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return null;
    const start = i;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_str) {
            // 正确的转义状态机(对齐 OpenAI 侧):区分 `\"` 与 `\\"`,否则尾随反斜杠的字符串误闭合。
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') in_str = true else if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) return .{ .obj = data[start .. i + 1], .end = i + 1 };
        }
    }
    return null;
}

/// 提取 functionCall.args 的对象文本(`"args":{...}` 的 {...} 部分,含嵌套)。null=无。
/// 简易括号配平(args 值是 JSON 对象);够 MVP 用,复杂嵌套/字符串内含括号未完全鲁棒(诚实登记)。
fn extractArgsObject(data: []const u8) ?[]const u8 {
    const key = "\"args\":";
    const idx = std.mem.indexOf(u8, data, key) orelse return null;
    var i = idx + key.len;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return null;
    const start = i;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_str) {
            if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') in_str = true else if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) return data[start .. i + 1];
        }
    }
    return null;
}

/// prefix 哈希(model + system + tool 名做 FNV-1a)。缓存查表 key——model+system+tools 稳定则哈希稳定。
/// **含 model**:Gemini 缓存对象 model-specific,不含 model 会让 model_override 误命中别的 model 句柄。
fn hashPrefix(model: []const u8, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const fnv = struct {
        fn mix(hash: *u64, bytes: []const u8) void {
            for (bytes) |b| {
                hash.* ^= b;
                hash.* *%= 0x100000001b3;
            }
        }
    };
    fnv.mix(&h, model);
    if (system) |s| fnv.mix(&h, s);
    if (tools) |tl| for (tl) |t| fnv.mix(&h, t.name);
    return h;
}

/// 测试辅助:暴露 hashPrefix 给组件测试,验证缓存句柄命中(测试需用同样哈希注册)。
pub fn hashPrefixForTest(model: []const u8, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition) u64 {
    return hashPrefix(model, system, tools);
}

/// 当前单调时钟毫秒(缓存 TTL 过期判断)。走 util/time 统一时钟。
/// **单调时钟**(非 wall epoch):TTL 当 duration 用,registerCache 传 nowMonoMs()+ttl_ms。
fn nowMonoMs() i64 {
    return @import("../util/time.zig").nowMs();
}

/// 中立 Conversation/tools → Gemini generateContent 请求 body。caller free。
/// cached_ref 非 null → 请求带 cachedContent 引用(有状态缓存命中)。
/// model 用于查 dialect(GeminiDialect)翻译 tool_choice + thinking_level。
/// tool_choice 由 dialect.serializeToolChoice 翻成 tool_config.function_calling_config。
/// reasoning_effort 非 null → dialect.serializeThinking 翻成 generation_config.thinking_level。
pub fn serializeGeminiRequest(allocator: std.mem.Allocator, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, cached_ref: ?[]const u8, model: []const u8, tool_choice: ?json_mod.ToolChoice, reasoning_effort: ?types.ReasoningEffort) ![]u8 {
    // Legacy wrapper:包成 RequestOverrides 转给 WithOverrides 版。
    return serializeGeminiRequestWithOverrides(allocator, messages, system, tools, cached_ref, model, .{
        .reasoning_effort = reasoning_effort,
        .tool_choice = tool_choice,
    });
}

/// 完整方言字段入口的序列化(stage 3 接线 + stage 5 扩展)。
/// overrides 非 null 字段 = 显式覆盖;null = dialect 按 profile 静态推断。
/// Gemini 协议支持:thinking_level(thinking)/response_mime_type(response_format)/temperature/top_p。
/// 不支持:prompt_cache_key(Gemini 用 cachedContent 机制)/parallel_tool_calls(无此概念)→ 忽略。
pub fn serializeGeminiRequestWithOverrides(allocator: std.mem.Allocator, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, cached_ref: ?[]const u8, model: []const u8, overrides: request_overrides.RequestOverrides) ![]u8 {
    return serializeGeminiRequestWithOverridesAndDialect(
        allocator,
        messages,
        system,
        tools,
        cached_ref,
        model,
        overrides,
        dialect_mod.dialectFor(.gemini, model),
    );
}

pub fn serializeGeminiRequestWithOverridesAndDialect(
    allocator: std.mem.Allocator,
    messages: []const types.ApiMessage,
    system: ?[]const u8,
    tools: ?[]const json_mod.ToolDefinition,
    cached_ref: ?[]const u8,
    model: []const u8,
    overrides: request_overrides.RequestOverrides,
    dialect: dialect_mod.Dialect,
) ![]u8 {
    const profile = dialect.profileFor(.gemini, model);
    const visible_capabilities = dialect_mod.visibleCapabilities(tools);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first_top = true;
    // cachedContent 引用(有状态缓存命中时)。
    if (cached_ref) |cn| {
        try out.appendSlice(allocator, "\"cachedContent\":");
        try util_json.serializeString(cn, &out, allocator);
        first_top = false;
    }
    // systemInstruction:{parts:[{text}]}. Capability activation is typed and
    // deterministic; ordinary Gemini dialects keep the default no-op.
    var system_buf: std.ArrayList(u8) = .empty;
    defer system_buf.deinit(allocator);
    if (system) |sys| try system_buf.appendSlice(allocator, sys);
    try dialect.injectSystemMods(profile, overrides.reasoning_effort, &system_buf, allocator);
    try dialect.activateCapabilities(
        profile,
        visible_capabilities,
        &system_buf,
        allocator,
    );
    if (system_buf.items.len != 0) {
        if (!first_top) try out.append(allocator, ',');
        first_top = false;
        try out.appendSlice(allocator, "\"systemInstruction\":{\"parts\":[{\"text\":");
        try util_json.serializeString(system_buf.items, &out, allocator);
        try out.appendSlice(allocator, "}]}");
    }
    // contents:[{role, parts:[...]}]
    if (!first_top) try out.append(allocator, ',');
    try out.appendSlice(allocator, "\"contents\":[");
    var first_msg = true;
    for (messages) |m| {
        if (!first_msg) try out.append(allocator, ',');
        first_msg = false;
        try serializeGeminiContent(allocator, &out, m, messages, dialect, profile);
    }
    try out.append(allocator, ']');
    // tools:[{function_declarations:[...]}]
    if (tools) |tl| {
        if (tl.len > 0) {
            try out.appendSlice(allocator, ",\"tools\":[{\"function_declarations\":[");
            for (tl, 0..) |t, i| {
                if (i > 0) try out.append(allocator, ',');
                try serializeGeminiTool(allocator, &out, t);
            }
            try out.appendSlice(allocator, "]}]");
        }
    }
    // tool_choice:委托给 GeminiDialect 翻成 tool_config.function_calling_config。
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
    // generation_config:合并 thinking_level + response_mime_type + temperature + top_p。
    // 片段函数用"若 gen_cfg 非空则加前导逗号"策略,调用顺序无关。
    var gen_cfg: std.ArrayList(u8) = .empty;
    defer gen_cfg.deinit(allocator);
    // thinking_level:dialect.serializeThinking 输出 "thinking_level":"low" 片段。
    try dialect.serializeThinking(profile, overrides.reasoning_effort, &gen_cfg, allocator);
    // response_format:dialect.serializeResponseFormat 输出 "response_mime_type":... 片段。
    if (overrides.response_format) |rf| {
        _ = try dialect.serializeResponseFormat(profile, rf, &gen_cfg, allocator);
    }
    // temperature/top_p:通用采样参数,进 generation_config(Gemini 协议支持)。
    if (overrides.temperature) |t| {
        if (gen_cfg.items.len > 0) try gen_cfg.append(allocator, ',');
        try gen_cfg.appendSlice(allocator, "\"temperature\":");
        try util_json.serializeNumber(t, &gen_cfg, allocator);
    }
    if (overrides.top_p) |p| {
        if (gen_cfg.items.len > 0) try gen_cfg.append(allocator, ',');
        try gen_cfg.appendSlice(allocator, "\"top_p\":");
        try util_json.serializeNumber(p, &gen_cfg, allocator);
    }
    // 注:prompt_cache_key / parallel_tool_calls Gemini 协议不支持,忽略(能力守门)。
    if (gen_cfg.items.len > 0) {
        try out.appendSlice(allocator, ",\"generation_config\":{");
        try out.appendSlice(allocator, gen_cfg.items);
        try out.append(allocator, '}');
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// 从全量消息里按 tool_use_id 找回原 functionCall 的真实 name(Gemini functionResponse 靠 name 配对)。
/// 找不到 → null(调用方退回用 id 占位)。
fn findToolUseName(messages: []const types.ApiMessage, id: []const u8) ?[]const u8 {
    for (messages) |mm| for (mm.content) |c| switch (c) {
        .tool_use => |tu| if (std.mem.eql(u8, tu.id, id)) return tu.name,
        else => {},
    };
    return null;
}

fn serializeGeminiContent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), m: types.ApiMessage, all_messages: []const types.ApiMessage, dialect: dialect_mod.Dialect, profile: dialect_mod.ModelProfile) !void {
    // tool_result → user 角色的 functionResponse part(Gemini 特有)。
    var has_tool_result = false;
    for (m.content) |c| if (c == .tool_result) {
        has_tool_result = true;
    };
    if (has_tool_result) {
        // 同 OpenAI:tool_result 消息只投影 functionResponse parts,同消息 image 会被
        // 静默丢——issue #10 铁律下防御性显式报错(正常路径经 merge 守护永不产出)。
        for (m.content) |c| if (c == .image) return error.ImageWithToolResultUnsupported;
        // P0.1 并行:一轮多个 tool_result → **全部**作为同一 user content 的多个 functionResponse
        // parts(旧版只发首个 → 并行回合下一次请求缺 functionResponse 配对)。
        // functionResponse.name 必须是**原 functionCall 的真实名**(Gemini 靠 name 配对,非 id);
        // 从全量消息按 tool_use_id 找回真名,找不到才退回 id 占位。
        try out.appendSlice(allocator, "{\"role\":\"user\",\"parts\":[");
        var first_fr = true;
        for (m.content) |c| switch (c) {
            .tool_result => |tr| {
                if (!first_fr) try out.append(allocator, ',');
                first_fr = false;
                const fname = findToolUseName(all_messages, tr.tool_use_id) orelse tr.tool_use_id;
                try out.appendSlice(allocator, "{\"functionResponse\":{\"name\":");
                try util_json.serializeString(fname, out, allocator);
                try out.appendSlice(allocator, ",\"response\":{\"result\":");
                try util_json.serializeString(tr.content, out, allocator);
                try out.appendSlice(allocator, "}}}");
            },
            else => {},
        };
        try out.appendSlice(allocator, "]}");
        return;
    }
    // role:assistant→"model",user→"user"
    const role_str = switch (m.role) {
        .user => "user",
        .assistant => "model",
    };
    try out.appendSlice(allocator, "{\"role\":\"");
    try out.appendSlice(allocator, role_str);
    try out.appendSlice(allocator, "\",\"parts\":[");
    var first_part = true;
    for (m.content) |c| switch (c) {
        .text => |t| {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{\"text\":");
            try util_json.serializeString(t, out, allocator);
            try out.append(allocator, '}');
        },
        .tool_use => |tu| {
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            try out.appendSlice(allocator, "{\"functionCall\":{\"name\":");
            try util_json.serializeString(tu.name, out, allocator);
            try out.appendSlice(allocator, ",\"args\":");
            // tu.input 是 JSON 字符串(args 对象);直接内联(已是合法 JSON 对象)。
            try out.appendSlice(allocator, if (tu.input.len > 0) tu.input else "{}");
            try out.appendSlice(allocator, "}}");
        },
        .image => |img| {
            // 一等图像内容(issue #10):inline_data part,wire 形态委托方言。
            // 方言返 false = 该 model 不支持图像输入 → 显式能力错误,绝不静默丢图。
            if (!first_part) try out.append(allocator, ',');
            first_part = false;
            const emitted = try dialect.serializeImagePart(profile, img, out, allocator);
            if (!emitted) return error.ImageInputUnsupported;
        },
        else => {},
    };
    // 空 parts 兜底(Gemini 要求 parts 非空)。
    if (first_part) try out.appendSlice(allocator, "{\"text\":\"\"}");
    try out.appendSlice(allocator, "]}");
}

fn serializeGeminiTool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), t: json_mod.ToolDefinition) !void {
    try out.appendSlice(allocator, "{\"name\":");
    try util_json.serializeString(t.name, out, allocator);
    try out.appendSlice(allocator, ",\"description\":");
    try util_json.serializeString(t.description, out, allocator);
    try out.appendSlice(allocator, ",\"parameters\":");
    try @import("request.zig").serializeInputSchema(t.input_schema, out, allocator);
    try out.append(allocator, '}');
}

// ── 测试 ──────────────────────────────────────────────────────────────────
test "Gemini 请求翻译:中立 → generateContent body" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hello" }} },
    };
    const body = try serializeGeminiRequest(a, &msgs, "you are helpful", null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
}

test "Gemini 缓存命中:cachedContent 引用进请求体" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "q" }} },
    };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, "cachedContents/abc123", "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cachedContent\":\"cachedContents/abc123\"") != null);
}

// ── M3:Gemini tool_choice 端到端字节断言(声明=接线=测试 DoD)─────────────────────

test "M3 Gemini: tool_choice=auto → function_calling_config.mode AUTO" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "auto" };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", tc, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_config\":{\"function_calling_config\":{\"mode\":\"AUTO\"}}") != null);
}

test "M3 Gemini: tool_choice=any → mode ANY" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "any" };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", tc, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"ANY\"") != null);
}

test "M3 Gemini: tool_choice=tool+name → ANY + allowed_function_names" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "tool", .name = "web_search" };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", tc, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"ANY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"allowed_function_names\":[\"web_search\"]") != null);
}

test "M3 Gemini: tool_choice=none → mode NONE" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "none" };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", tc, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"NONE\"") != null);
}

test "M3 Gemini: tool_choice=tool 缺 name → ANY(强制选一个,不指定)" {
    // tool 类型但 name=null,Gemini 输出 mode=ANY 但不发 allowed_function_names。
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "tool", .name = null };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", tc, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"mode\":\"ANY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "allowed_function_names") == null);
}

test "M3 Gemini: tool_choice=null 不发 tool_config" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_config") == null);
}

// ── M7:Gemini thinking_level 端到端字节断言(声明=接线=测试 DoD)─────────────────

test "M7 Gemini: reasoning_effort=high → generation_config.thinking_level high" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, .high);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"generation_config\":{\"thinking_level\":\"high\"}") != null);
}

test "M7 Gemini: reasoning_effort=low → thinking_level low" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, .low);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking_level\":\"low\"") != null);
}

test "M7 Gemini: reasoning_effort=null 不发 generation_config(自适应)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "go" }} },
    };
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "generation_config") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "thinking_level") == null);
}

test "Gemini 有状态缓存句柄表:命中/过期/剔除" {
    const a = std.testing.allocator;
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = GeminiClient.init(a, io_rt.io(), "k", "gemini-2.5-flash", "http://localhost");
    defer client.deinit();

    try client.registerCache(12345, "cachedContents/x", 1000); // 过期时刻 mono_ms=1000
    // now=500 < 1000 → 命中。
    try std.testing.expectEqualStrings("cachedContents/x", client.lookupCache(12345, 500).?);
    // now=2000 > 1000 → 过期 → null + 剔除。
    try std.testing.expect(client.lookupCache(12345, 2000) == null);
    // 再查已被剔除。
    try std.testing.expect(client.lookupCache(12345, 500) == null);
    try std.testing.expectEqual(@as(usize, 0), client.cache_table.items.len);
}

test "extractArgsObject 嵌套对象" {
    const data = "{\"functionCall\":{\"name\":\"f\",\"args\":{\"a\":1,\"b\":{\"c\":2}}}}";
    const args = extractArgsObject(data).?;
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":{\"c\":2}}", args);
}

test "braceObject/extractArgsObject 转义状态机:值尾随转义反斜杠不误闭合(Linus #1)" {
    // args 值 = "a\\"(JSON 里 a + 一个反斜杠):闭合 `"` 前一字节是 `\`,旧启发式 data[i-1]!='\\'
    // 会误判成转义引号 → 字符串不闭合 → 括号跑到 EOF → functionCall 被丢/args 变 {}。
    // 字面量字节:{"functionCall":{"name":"w","args":{"p":"a\\"}}}
    const chunk = "{\"functionCall\":{\"name\":\"w\",\"args\":{\"p\":\"a\\\\\"}}}";
    const fc = std.mem.indexOf(u8, chunk, "\"functionCall\":").?;
    const bo = braceObject(chunk, fc + "\"functionCall\":".len).?;
    // functionCall 对象完整闭合(含 args 的两层 }),不跑到 EOF。
    try std.testing.expect(std.mem.endsWith(u8, bo.obj, "}"));
    try std.testing.expectEqualStrings("w", util_json.extractStringField(bo.obj, "name").?);
    // args 对象完整提取,尾随反斜杠保留。
    const args = extractArgsObject(bo.obj).?;
    try std.testing.expectEqualStrings("{\"p\":\"a\\\\\"}", args);
}

// ── issue #10:一等图像输入 ────────────────────────────────────────────────────

test "Gemini: 含 image 的 user 消息 → inline_data part(text/image 按序)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .text = "看图" },
            .{ .image = .{ .media_type = "image/png", .data = "UE5HREFUQQ==" } },
        } },
    };
    const body = try serializeGeminiRequest(a, &msgs, null, null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    const seq = std.mem.indexOf(u8, body, "{\"text\":\"看图\"},{\"inline_data\":{\"mime_type\":\"image/png\",\"data\":\"UE5HREFUQQ==\"}}");
    try std.testing.expect(seq != null);
}

test "Gemini: image 在 text 前时顺序保持" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .image = .{ .media_type = "image/jpeg", .data = "SlBFRw==" } },
            .{ .text = "以上是截图" },
        } },
    };
    const body = try serializeGeminiRequest(a, &msgs, null, null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    const img = std.mem.indexOf(u8, body, "\"inline_data\"").?;
    const txt = std.mem.indexOf(u8, body, "以上是截图").?;
    try std.testing.expect(img < txt);
}

test "Gemini: tool_result 消息混入 image → 显式错误(防 functionResponse 投影静默丢图)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "t1", .content = "ok" } },
            .{ .image = .{ .media_type = "image/png", .data = "QUJD" } },
        } },
    };
    try std.testing.expectError(
        error.ImageWithToolResultUnsupported,
        serializeGeminiRequest(a, &msgs, null, null, null, "gemini-2.5-pro", null, null),
    );
}
