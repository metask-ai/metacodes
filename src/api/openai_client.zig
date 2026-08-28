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
//! `function.arguments` 的每个 SSE 字符串片段先解除外层 JSON 转义，再按 tool-call
//! `index` 拼接；字符串字段、反斜杠和跨 chunk 片段因此以原始 JSON 字节进入工具层。
//! **诚实登记——以下未做**:
//!   - **建连重试 / 429 退避**:pSendStreamRetry 忽略 max_retries/reporter,直接发一次;doStream
//!     遇非 200(含 429/500)直接 error.RequestFailed,无重试。Anthropic 路径有 withRetry,此处没有。
//!   - **非流式 pSend**:返回 error.NotImplemented → auto-compact summary 在 OpenAI 路径退化成
//!     纯丢老消息(compact_summary.summarize catch 兜底,不崩)。
//!   - **max_tokens/context_window**:硬编码 4096/128000,未按 model 区分(o1 实际 200k 等)。
//!   - **keep_alive=false**(每请求新连接):牺牲连接池(省 TLS 握手)换稳定性;流式池化收益小。
//!   - thinking/o1-reasoning、prompt cache、completion(非 chat)。
//!
//! 协议差异(本文件锁住的全部脏活):
//!   - URL:{base}/v1/chat/completions(Anthropic 是 /v1/messages)
//!   - 认证:Authorization: Bearer {key}(凑巧同 Anthropic;无 anthropic-version header)
//!   - 请求 body:{model, messages:[{role,content|tool_calls|tool_call_id}], tools:[{type:function,...}], stream}
//!   - SSE:data: {choices:[{delta:{content|tool_calls}, finish_reason}]} / data: [DONE]

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

pub const DEFAULT_OPENAI_URL = "https://api.openai.com/v1/chat/completions";

pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8, // 完整 chat/completions URL(可指向 MockServer / 自建中转站)
    model: []const u8,
    http_client: http.Client,
    abort_registry: provider_mod.RequestAbortRegistry = .{},
    max_tokens: u32 = 4096,
    context_window: u32 = 128_000,
    reasoning_effort: ?types.ReasoningEffort = null,
    /// 方言字段覆盖(null = profile 默认)。来源:计划 jolly-glacier。
    overrides: request_overrides.RequestOverrides = .{},
    dialect_resolver: dialect_mod.Resolver = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, base_url: ?[]const u8) OpenAIClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .base_url = base_url orelse DEFAULT_OPENAI_URL,
            .model = model,
            .http_client = http.Client{ .allocator = allocator, .io = io },
        };
    }
    pub fn deinit(self: *OpenAIClient) void {
        self.abort_registry.deinit(self.allocator);
        self.http_client.deinit();
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
            .reasoningEffortFn = &pReasoningEffort,
            .setReasoningEffortFn = &pSetReasoningEffort,
            .requestOverridesFn = &pRequestOverrides,
            .setRequestOverridesFn = &pSetRequestOverrides,
            .supportsFn = &pSupports,
        };
    }
    inline fn cast(ctx: *anyopaque) *OpenAIClient {
        return @ptrCast(@alignCast(ctx));
    }
    fn pModel(ctx: *anyopaque) []const u8 {
        return cast(ctx).model;
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
        return cast(ctx).max_tokens;
    }
    fn pMaxInputTokens(ctx: *anyopaque) u32 {
        return cast(ctx).context_window;
    }
    fn pReasoningEffort(ctx: *anyopaque) ?types.ReasoningEffort {
        return cast(ctx).reasoning_effort;
    }
    fn pSetReasoningEffort(ctx: *anyopaque, effort: ?types.ReasoningEffort) void {
        cast(ctx).reasoning_effort = effort;
    }
    fn pSupports(ctx: *anyopaque, cap: provider_mod.Capability) bool {
        return capability.supports(.openai, cast(ctx).model, cap);
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
        const dialect = self.dialect_resolver.resolve(.openai, model);
        const body = try serializeOpenAIRequestWithOverridesAndDialect(self.allocator, model, messages, system, tools, o, dialect);
        defer self.allocator.free(body);
        return self.doStream(body, abort, dialect);
    }

    /// 发 HTTP POST + 包成中立 StreamHandle(堆框 OpenAIStream,地址稳定)。
    fn doStream(self: *OpenAIClient, body: []const u8, abort: ?*const AbortSignal, dialect: dialect_mod.Dialect) !StreamHandle {
        const rid = log.genRequestId();
        log.infoId(
            "openai",
            rid,
            "POST {s} model={s} body_bytes={d} cache_mode={s} reasoning_effort={s}",
            .{ self.base_url, self.model, body.len, cache.modeFor(.openai).label(), if (self.reasoning_effort) |effort| effort.name() else "default" },
        );
        const uri = std.Uri.parse(self.base_url) catch return error.InvalidUrl;
        const auth = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) catch return error.RequestFailed;
        defer secureFree(self.allocator, auth);

        const req_ptr = try self.allocator.create(http.Client.Request);
        errdefer self.allocator.destroy(req_ptr); // 唯一 destroy:所有错误路径靠它(不手动 destroy,否则 double-free)
        var connection_lease = try connection_gate.acquire(abort);
        defer connection_lease.release();
        req_ptr.* = self.http_client.request(.POST, uri, .{
            // 保持禁用陈旧池连接；跨 provider 的 process-wide connection_gate 限制并发握手。
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "authorization", .value = auth },
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
            log.errId("openai", rid, "send body failed: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        const response = req_ptr.receiveHead(&.{}) catch |err| {
            log.errId("openai", rid, "receiveHead failed: {s}", .{@errorName(err)});
            return err;
        };
        const status = ResponseStatus.capture(&response);
        connection_lease.release();
        if (!status.isOk()) {
            log.errId("openai", rid, "HTTP {d} {s}", .{ status.code, status.name });
            return error.RequestFailed;
        }

        const heap = try self.allocator.create(OpenAIStream);
        heap.* = .{
            .allocator = self.allocator,
            .model = self.model,
            .dialect = dialect,
            .request = req_ptr,
            .response = response,
            .abort = abort,
            .abort_registry = if (abort != null) &self.abort_registry else null,
            .id = rid,
        };
        return heap.handle();
    }
};

fn secureFree(allocator: std.mem.Allocator, buf: []u8) void {
    @memset(buf, 0);
    allocator.free(buf);
}

/// OpenAI 流式响应:持 Response + transfer buffer + 逐行 SSE 解析状态。包成中立 StreamHandle。
/// 合成 tool_call id 的进程级单调序号(后端漏发 id 时兜底;u64 不 wrap)。
var g_synth_id_serial = std.atomic.Value(u64).init(1);

const OpenAIStream = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    dialect: dialect_mod.Dialect,
    request: *http.Client.Request,
    response: http.Client.Response,
    transfer_buf: [8192]u8 = undefined,
    reader: ?*std.Io.Reader = null,
    abort: ?*const AbortSignal = null,
    abort_registry: ?*provider_mod.RequestAbortRegistry = null,
    id: log.RequestId,
    done: bool = false,
    last_stop: StopReason = .unknown,
    // 并行 tool_calls 增量累积(P0.1):OpenAI 流式把每个 tool_call 按 `index` 分槽分块发
    // (id/name 一次,arguments 跨 chunk 拼)。按 index 找槽累积,done 时把每个槽 flush 成一个
    // tool_use_start 事件排队,next() 逐个 drain → executeSlots 收到多 slot 真并发。
    tcs: std.ArrayList(ToolCallAcc) = .empty,
    tc_active: bool = false,
    flush_q: std.ArrayList(StreamEvent) = .empty, // done 时排队的 tool_use_start
    flush_pos: usize = 0,
    flushed: bool = false,

    fn handle(self: *OpenAIStream) StreamHandle {
        return .{ .ctx = @ptrCast(self), .nextFn = &hNext, .deinitFn = &hDeinit, .stopReasonFn = &hStop, .requestIdFn = &hRid };
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

    fn deinit(self: *OpenAIStream) void {
        for (self.tcs.items) |*tc| tc.deinit(self.allocator);
        self.tcs.deinit(self.allocator);
        // 异常拆解时未 drain 的 flush 事件仍持 owned id/name/input_json → 释放,防泄漏。
        for (self.flush_q.items[self.flush_pos..]) |ev| switch (ev) {
            .tool_use_start => |tu| {
                self.allocator.free(tu.id);
                self.allocator.free(tu.name);
                self.allocator.free(tu.input_json);
            },
            else => {},
        };
        self.flush_q.deinit(self.allocator);
        if (self.abort_registry) |registry| registry.unregister(self.request);
        self.request.deinit();
        self.allocator.destroy(self.request);
    }

    /// 读下一个中立事件。逐行读 SSE,翻译 OpenAI chunk → StreamEvent。
    fn next(self: *OpenAIStream) anyerror!?StreamEvent {
        // 先把已排队的 flush 事件(并行 tool_use_start)逐个吐出。
        if (self.flush_pos < self.flush_q.items.len) {
            const ev = self.flush_q.items[self.flush_pos];
            self.flush_pos += 1;
            return ev;
        }
        if (self.done) return null;
        if (self.reader == null) {
            self.reader = self.response.reader(&self.transfer_buf);
        }
        const r = self.reader.?;
        while (true) {
            if (self.abort) |ab| if (ab.isAborted()) return error.Aborted;
            // takeDelimiter 在 0.16 返回 ?[]const u8(null=流结束),错误集只有 {ReadFailed,StreamTooLong}。
            const line_opt = try r.takeDelimiter('\n');
            const line = line_opt orelse {
                self.done = true;
                return self.finishFlush();
            };
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const data = std.mem.trim(u8, trimmed[5..], " ");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.done = true;
                if (self.finishFlush()) |ev| return ev;
                return StreamEvent{ .done = {} };
            }
            if (try self.parseChunk(data)) |ev| return ev;
            // 该 chunk 无可 emit 事件(纯 tool_call 增量累积)→ 继续读下一行。
        }
    }

    /// 解析一个 OpenAI SSE data chunk。返回可 emit 的中立事件,或 null(增量累积中)。
    fn parseChunk(self: *OpenAIStream, data: []const u8) !?StreamEvent {
        // usage chunk(include_usage 时末尾发):{"choices":[],"usage":{prompt_tokens,completion_tokens,
        // prompt_tokens_details:{cached_tokens}}}。归一成中立 UsageDelta(prompt→input、completion→output、
        // cached_tokens→cache_read,经 cache.parseOpenAICacheUsage)。让缓存命中能上抛 UI,与 Anthropic 一致。
        if (std.mem.indexOf(u8, data, "\"usage\"") != null) {
            const cu = cache.parseOpenAICacheUsage(data);
            // 语义归一(Anthropic-exclusive):OpenAI 的 prompt_tokens **包含** cached_tokens,
            // 中立 UsageDelta 约定 input_tokens 不含 cache(Anthropic 语义)。消费方
            // (usage 锚点/成本累计)按 in+cache_r+cache_w 求和——不减会把缓存双计。
            return StreamEvent{
                .usage = UsageDelta{
                    .input_tokens = util_json.extractIntField(data, "prompt_tokens") -| cu.read_tokens,
                    .output_tokens = util_json.extractIntField(data, "completion_tokens"),
                    .cache_read_input_tokens = cu.read_tokens,
                    .cache_creation_input_tokens = cu.creation_tokens, // OpenAI 无写区分 → 0
                },
            };
        }
        // finish_reason → StopReason(末 chunk)。
        if (util_json.extractStringField(data, "finish_reason")) |fr| {
            if (!std.mem.eql(u8, fr, "null")) self.last_stop = mapFinish(fr);
        }
        // delta.content → text。OpenAI: {"choices":[{"delta":{"content":"hi"},...}]}
        // SSE string 片段带一层 JSON 转义(\n/\"/\uXXXX):必须解除后再交对话/UI,
        // 否则转义序列以字面量进入 assistant 文本(issue #4)。空片段 free 不发事件。
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
                // arguments 片段先解除一层外层 JSON 转义再按槽拼接:`function.arguments`
                // 是装在 string 里的 JSON 文档,不解除会让任何 string 参数变成非法 JSON。
                if (try util_json.extractAndUnescapeStringField(
                    elem,
                    "arguments",
                    self.allocator,
                )) |args| {
                    defer self.allocator.free(args);
                    try acc.args.appendSlice(self.allocator, args);
                }
            }
        }
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
            const args = if (tc.args.items.len > 0)
                (tc.args.toOwnedSlice(a) catch {
                    a.free(id);
                    a.free(name);
                    continue;
                })
            else
                (a.dupe(u8, "{}") catch {
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

/// 定位 `"tool_calls":` 后的 array,返回 `[` 与配对 `]` 之间的内容(深度感知,跳字符串)。
/// 分块未闭合(部分 chunk)时返回剩余部分。找不到返 null。
fn findToolCallsArray(data: []const u8) ?[]const u8 {
    const key = "\"tool_calls\":";
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
        try serializeOpenAIMessage(allocator, &out, m);
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

fn serializeOpenAIMessage(allocator: std.mem.Allocator, out: *std.ArrayList(u8), m: types.ApiMessage) !void {
    // 收集 text / tool_use / tool_result。OpenAI:assistant 的 tool_use → tool_calls;
    // tool_result → 独立 {role:"tool"} 消息。MVP:每个 tool_result 拆成单独 message。
    // 简化:先处理 tool_result(它要 role:"tool"),再处理 text+tool_use 的 user/assistant 消息。
    var has_tool_result = false;
    for (m.content) |c| if (c == .tool_result) {
        has_tool_result = true;
    };
    if (has_tool_result) {
        // OpenAI 要求每个 tool_result 是独立 {role:"tool"} message。并行工具一轮有多个
        // tool_result,**全部展开**成逗号分隔的多条 message(P0.1:旧版只发首个 → 并行回合
        // 下一次请求缺 tool_call_id 配对被 OpenAI 400)。调用方在本消息前已加分隔逗号。
        var first_tr = true;
        for (m.content) |c| switch (c) {
            .tool_result => |tr| {
                if (!first_tr) try out.append(allocator, ',');
                first_tr = false;
                try out.appendSlice(allocator, "{\"role\":\"tool\",\"tool_call_id\":");
                try util_json.serializeString(tr.tool_use_id, out, allocator);
                try out.appendSlice(allocator, ",\"content\":");
                try util_json.serializeString(tr.content, out, allocator);
                try out.append(allocator, '}');
            },
            else => {},
        };
        return;
    }
    const role_str = switch (m.role) {
        .user => "user",
        .assistant => "assistant",
    };
    try out.appendSlice(allocator, "{\"role\":\"");
    try out.appendSlice(allocator, role_str);
    try out.appendSlice(allocator, "\"");
    // text content
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    var has_tool_use = false;
    for (m.content) |c| switch (c) {
        .text => |t| try text_buf.appendSlice(allocator, t),
        .tool_use => has_tool_use = true,
        else => {},
    };
    try out.appendSlice(allocator, ",\"content\":");
    try util_json.serializeString(text_buf.items, out, allocator);
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
