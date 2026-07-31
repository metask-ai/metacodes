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
            .supportsFn = &pSupports,
        };
    }
    inline fn cast(ctx: *anyopaque) *OpenAIClient {
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
        _ = tool_choice;
        _ = user_query; // OpenAI 无 server-tool web_search → 无需 query 透传
        const self = cast(ctx);
        const model = model_override orelse self.model;
        const body = try serializeOpenAIRequest(self.allocator, model, messages, system, tools);
        defer self.allocator.free(body);
        return self.doStream(body, abort);
    }

    /// 发 HTTP POST + 包成中立 StreamHandle(堆框 OpenAIStream,地址稳定)。
    fn doStream(self: *OpenAIClient, body: []const u8, abort: ?*const AbortSignal) !StreamHandle {
        const rid = log.genRequestId();
        log.infoId("openai", rid, "POST {s} model={s} body_bytes={d} cache_mode={s}", .{ self.base_url, self.model, body.len, cache.modeFor(.openai).label() });
        const uri = std.Uri.parse(self.base_url) catch return error.InvalidUrl;
        const auth = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) catch return error.RequestFailed;
        defer secureFree(self.allocator, auth);

        const req_ptr = try self.allocator.create(http.Client.Request);
        errdefer self.allocator.destroy(req_ptr); // 唯一 destroy:所有错误路径靠它(不手动 destroy,否则 double-free)
        req_ptr.* = self.http_client.request(.POST, uri, .{
            .keep_alive = false, // 每请求独立连接(同 gemini_client:避免复用 pooled 连接致 HttpConnectionClosing)
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
        if (response.head.status != .ok) {
            log.errId("openai", rid, "HTTP {d}", .{@intFromEnum(response.head.status)});
            return error.RequestFailed;
        }

        const heap = try self.allocator.create(OpenAIStream);
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

fn secureFree(allocator: std.mem.Allocator, buf: []u8) void {
    @memset(buf, 0);
    allocator.free(buf);
}

/// OpenAI 流式响应:持 Response + transfer buffer + 逐行 SSE 解析状态。包成中立 StreamHandle。
const OpenAIStream = struct {
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
        if (extractDeltaContent(data)) |content| {
            if (content.len > 0) {
                const owned = try self.allocator.dupe(u8, content);
                return StreamEvent{ .text = owned };
            }
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
                if (try extractDecodedStringField(
                    self.allocator,
                    elem,
                    "arguments",
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
            const id = tc.id.toOwnedSlice(a) catch continue;
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

/// 提取一个 JSON string 字段并只解除其外层 JSON 转义。
///
/// OpenAI 的 `function.arguments` 自身是装在 string 里的 JSON 文档。把
/// raw escaped slice 交给工具层会让任何 string 参数变成非法 JSON。这个
/// owned-fragment 契约属于 OpenAI 流累积器，故不下沉到通用 JSON helper。
fn extractDecodedStringField(
    allocator: std.mem.Allocator,
    data: []const u8,
    field: []const u8,
) !?[]u8 {
    var pattern_buf: [256]u8 = undefined;
    if (field.len >= pattern_buf.len - 3) return null;
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..field.len], field);
    pattern_buf[1 + field.len] = '"';
    pattern_buf[2 + field.len] = ':';
    const pattern = pattern_buf[0 .. field.len + 3];

    const field_index = std.mem.indexOf(u8, data, pattern) orelse return null;
    var cursor = field_index + pattern.len;
    while (cursor < data.len and std.ascii.isWhitespace(data[cursor])) : (cursor += 1) {}
    if (cursor >= data.len or data[cursor] != '"') return null;
    cursor += 1;
    const value_start = cursor;
    var escaped = false;
    while (cursor < data.len) : (cursor += 1) {
        const byte = data[cursor];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') {
            return try util_json.unescapeString(
                data[value_start..cursor],
                allocator,
            );
        }
        if (byte < 0x20) return null;
    }
    return null;
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

test "OpenAI arguments decoder removes one JSON layer and handles backslash parity" {
    const a = std.testing.allocator;
    const decoded = (try extractDecodedStringField(
        a,
        "{\"arguments\":\"{\\\"name\\\":\\\"review\\\",\\\"path\\\":\\\"C:\\\\\\\\tmp\\\"}\"}",
        "arguments",
    )) orelse return error.MissingArguments;
    defer a.free(decoded);
    try std.testing.expectEqualStrings(
        "{\"name\":\"review\",\"path\":\"C:\\\\tmp\"}",
        decoded,
    );

    const trailing = (try extractDecodedStringField(
        a,
        "{\"arguments\":\"fragment\\\\\"}",
        "arguments",
    )) orelse return error.MissingArguments;
    defer a.free(trailing);
    try std.testing.expectEqualStrings("fragment\\", trailing);
}

/// 提取 OpenAI delta.content(简易:找 `"content":"..."`,反转义)。null=本 chunk 无 content。
fn extractDeltaContent(data: []const u8) ?[]const u8 {
    // delta 里的 content;避免误命中其它 content(本测试 chunk 简单, 取首个 "content")。
    return util_json.extractStringField(data, "content");
}

/// 中立 Conversation/tools → OpenAI chat/completions 请求 body。caller free。
pub fn serializeOpenAIRequest(allocator: std.mem.Allocator, model: []const u8, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"model\":");
    try util_json.serializeString(model, &out, allocator);
    // stream_options.include_usage=true:OpenAI 默认流式不发 usage,显式要求才在末尾发一个
    // {choices:[],usage:{...}} chunk。缓存命中(cached_tokens)就在这个 usage 里。
    try out.appendSlice(allocator, ",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    var first = true;
    // system → 首条 {role:"system"}
    if (system) |sys| {
        try out.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try util_json.serializeString(sys, &out, allocator);
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
    const body = try serializeOpenAIRequest(a, "gpt-4o", &msgs, "you are helpful", null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}
