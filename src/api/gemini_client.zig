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
//!   - **并行 functionCall**:同 OpenAI,只认单个 functionCall/turn(检测多个 warn,不静默丢)。
//!   - **建连重试 / 非流式 / thinking(thought parts)/ 多模态 inline_data**:未做。
//!   - **max_tokens/context_window**:硬编码,未按 model 区分(Gemini 1.5 Pro 2M 等)。
//!
//! 取舍登记:keep_alive=false(每请求新连接)——牺牲真后端连接池(省 TLS 握手)换稳定性;
//! 流式请求被长流独占,池化收益本就小,且当前 per-job client 用法几乎不复用连接。

const std = @import("std");
const http = std.http;
const log = @import("../util/log.zig");
const types = @import("../types.zig");
const json_mod = @import("../json.zig");
const util_json = @import("../util/json.zig");
const api_stream = @import("stream.zig");
const provider_mod = @import("provider.zig");
const capability = @import("capability.zig");
const cache = @import("cache.zig");
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

pub const GeminiClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8, // 基址(可指向 MockServer);doStream 拼 model + :streamGenerateContent
    model: []const u8,
    http_client: http.Client,
    max_tokens: u32 = 8192,
    context_window: u32 = 1_048_576, // Gemini 1.5/2.x 默认 1M(保守;未按 model 区分)

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
            .maxTokensFn = &pMaxTokens,
            .maxInputTokensFn = &pMaxInputTokens,
            .reasoningEffortFn = &pReasoningEffort,
            .supportsFn = &pSupports,
        };
    }
    inline fn cast(ctx: *anyopaque) *GeminiClient {
        return @ptrCast(@alignCast(ctx));
    }
    fn pModel(ctx: *anyopaque) []const u8 {
        return cast(ctx).model;
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
    fn pSendStreamRetry(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, max_retries: u32, retry_base_ms: u64, reporter: ?provider_mod.RetryReporter, user_query: []const u8) anyerror!StreamHandle {
        _ = max_retries;
        _ = retry_base_ms;
        _ = reporter;
        return pSendStream(ctx, messages, system, tools, abort, model_override, tool_choice, user_query);
    }
    fn pSendStream(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!StreamHandle {
        _ = tool_choice;
        _ = user_query;
        const self = cast(ctx);
        const model = model_override orelse self.model;
        // prepareCache(写侧):查句柄表,命中未过期则请求带 cachedContent 引用。
        // 哈希 key 含 model:Gemini 缓存对象 model-specific,不含 model 会让 model_override 路径
        // 误命中别的 model 的句柄 → 发 400/404(C 修复)。
        const prefix_hash = hashPrefix(model, system, tools);
        const cached_ref = self.lookupCache(prefix_hash, nowMonoMs());
        const body = try serializeGeminiRequest(self.allocator, messages, system, tools, cached_ref);
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
        req_ptr.* = self.http_client.request(.POST, uri, .{
            .keep_alive = false, // 每请求独立连接:不复用 pooled 连接(MockServer 每连接一回放;
            // 真 Gemini 流式也无 pooling 收益)。避免"干净 EOF→连接入池→复用已弃连接→HttpConnectionClosing"。
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-goog-api-key", .value = self.api_key },
            },
        }) catch |err| {
            log.errId("gemini", rid, "request init failed: {s}", .{@errorName(err)});
            return error.RequestFailed; // errdefer destroy(req_ptr);req_ptr.* 未初始化, 无需 deinit
        };
        req_ptr.transfer_encoding = .{ .content_length = body.len };
        req_ptr.sendBodyComplete(@constCast(body)) catch |err| {
            log.errId("gemini", rid, "send body failed: {s}", .{@errorName(err)});
            req_ptr.deinit(); // 释放 Request 内部;heap box 由 errdefer destroy
            return error.RequestFailed;
        };
        const response = req_ptr.receiveHead(&.{}) catch |err| {
            log.errId("gemini", rid, "receiveHead failed: {s}", .{@errorName(err)});
            req_ptr.deinit();
            return err;
        };
        if (response.head.status != .ok) {
            log.errId("gemini", rid, "HTTP {d}", .{@intFromEnum(response.head.status)});
            req_ptr.deinit();
            return error.RequestFailed;
        }
        // receiveHead 成功后,req_ptr.* 是个开着连接的完整 Request。到 heap 转移所有权之前若出错
        // (create(GeminiStream) OOM),必须 deinit 它(否则泄漏 socket fd + 连接状态,非纯字节)。
        // errdefer LIFO:此 deinit 先跑、顶部 destroy 后跑 = 正确的 deinit()→destroy() 顺序。
        errdefer req_ptr.deinit();
        const heap = try self.allocator.create(GeminiStream);
        // create 成功 → 所有权转移给 GeminiStream(其 deinit 负责 req_ptr.deinit()+destroy);
        // 正常返回,两个 errdefer 都不触发。
        heap.* = .{ .allocator = self.allocator, .request = req_ptr, .response = response, .abort = abort, .id = rid };
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
    id: log.RequestId,
    done: bool = false,
    last_stop: StopReason = .unknown,
    fc_counter: u32 = 0, // functionCall 计数(Gemini 无 id,自生成 call_N)
    warned_parallel: bool = false,
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
        self.request.deinit();
        self.allocator.destroy(self.request);
    }

    fn next(self: *GeminiStream) anyerror!?StreamEvent {
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
            const usage = UsageDelta{
                .input_tokens = util_json.extractIntField(data, "promptTokenCount"),
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
        if (std.mem.indexOf(u8, data, "\"functionCall\"") != null) {
            const fc_count = countOccurrences(data, "\"functionCall\"");
            if (fc_count > 1 and !self.warned_parallel) {
                self.warned_parallel = true;
                log.warnId("gemini", self.id, "并行 functionCall 未实现:单 chunk 含多个,仅执行第一个(MVP)", .{});
            }
            const name = util_json.extractStringField(data, "name") orelse return null;
            // args:{...} 子对象 → input_json。提取 functionCall.args 的对象文本。
            const args = extractArgsObject(data) orelse "{}";
            self.fc_counter += 1;
            var id_buf: [32]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "call_{d}", .{self.fc_counter}) catch "call_1";
            return StreamEvent{ .tool_use_start = .{
                .id = try self.allocator.dupe(u8, id_str),
                .name = try self.allocator.dupe(u8, name),
                .input_json = try self.allocator.dupe(u8, args),
            } };
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

fn mapGeminiFinish(fr: []const u8) StopReason {
    if (std.mem.eql(u8, fr, "STOP")) return .end_turn;
    if (std.mem.eql(u8, fr, "MAX_TOKENS")) return .max_tokens;
    // Gemini 工具调用不单独给 finishReason(functionCall 在 parts 里),保守 unknown→上层据 tool_use 续轮。
    return .unknown;
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
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (in_str) {
            if (c == '"' and data[i - 1] != '\\') in_str = false;
            continue;
        }
        if (c == '"') in_str = true else if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) return data[start .. i + 1];
        }
    }
    return null;
}

/// 数 needle 在 haystack 中的(非重叠)出现次数(并行 functionCall 检测用)。
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
        n += 1;
        i = pos + needle.len;
    }
    return n;
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
pub fn serializeGeminiRequest(allocator: std.mem.Allocator, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, cached_ref: ?[]const u8) ![]u8 {
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
    // systemInstruction:{parts:[{text}]}
    if (system) |sys| {
        if (!first_top) try out.append(allocator, ',');
        first_top = false;
        try out.appendSlice(allocator, "\"systemInstruction\":{\"parts\":[{\"text\":");
        try util_json.serializeString(sys, &out, allocator);
        try out.appendSlice(allocator, "}]}");
    }
    // contents:[{role, parts:[...]}]
    if (!first_top) try out.append(allocator, ',');
    try out.appendSlice(allocator, "\"contents\":[");
    var first_msg = true;
    for (messages) |m| {
        if (!first_msg) try out.append(allocator, ',');
        first_msg = false;
        try serializeGeminiContent(allocator, &out, m);
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
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn serializeGeminiContent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), m: types.ApiMessage) !void {
    // tool_result → user 角色的 functionResponse part(Gemini 特有)。
    var has_tool_result = false;
    for (m.content) |c| if (c == .tool_result) {
        has_tool_result = true;
    };
    if (has_tool_result) {
        for (m.content) |c| switch (c) {
            .tool_result => |tr| {
                // Gemini functionResponse 需 name;tool_use_id 不是 name,但 MVP 用 id 占位
                // (单工具足够证明;真多工具需把 name 透传——诚实登记简化)。
                try out.appendSlice(allocator, "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":");
                try util_json.serializeString(tr.tool_use_id, out, allocator);
                try out.appendSlice(allocator, ",\"response\":{\"result\":");
                try util_json.serializeString(tr.content, out, allocator);
                try out.appendSlice(allocator, "}}}]}");
                return;
            },
            else => {},
        };
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
    const body = try serializeGeminiRequest(a, &msgs, "you are helpful", null, null);
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
    const body = try serializeGeminiRequest(a, &msgs, "sys", null, "cachedContents/abc123");
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cachedContent\":\"cachedContents/abc123\"") != null);
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
