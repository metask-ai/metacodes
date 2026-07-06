//! OpenAIClient:讲 OpenAI chat/completions 协议的 Provider 实现(多 Provider 重构 P3)。
//!
//! 证明点:这是第二个真 provider——它的 wire 协议(请求 body / SSE 事件)与 Anthropic 完全不同,
//! 但它产出**同一套中立 IR**(StreamEvent: text/tool_use_start/usage/done),经同一个 Provider vtable
//! 暴露。**agent_loop / Conversation / 中立 IR / provider.zig 一行不改**就能用它跑。这是"真多协议"
//! (区别于 cc 全归一成 Anthropic SDK)的端到端兑现。
//!
//! 范围(P3 最小证明,非生产级 OpenAI client):文本流 + 单个 tool_call(function calling)
//! + usage(含缓存命中 cached_tokens,经 stream_options.include_usage)。**诚实登记——以下未做**:
//!   - **并行 tool_calls**:一个 turn 只认单个 tool_call。OpenAI 并行 function calling(一个
//!     delta 多个 index/id)未实现;检测到第二个不同 id → log.warn 一声(不静默丢),只执行第一个。
//!   - **跨 chunk arguments 转义**:arguments 提取按"单 chunk 内是完整字符串值"假设。OpenAI
//!     流式可能把 arguments 切成多 chunk、单 chunk 内引号不配对——那种情况下转义层数会错。
//!     本测试 cassette 用简单 arguments(""/"{}"),真实复杂参数(含路径/嵌套引号且跨 chunk)未覆盖。
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
        req_ptr.transfer_encoding = .{ .content_length = body.len };
        req_ptr.sendBodyComplete(@constCast(body)) catch |err| {
            log.errId("openai", rid, "send body failed: {s}", .{@errorName(err)});
            req_ptr.deinit(); // 释放 Request 内部;heap box 由 errdefer destroy
            return error.RequestFailed;
        };
        const response = req_ptr.receiveHead(&.{}) catch |err| {
            log.errId("openai", rid, "receiveHead failed: {s}", .{@errorName(err)});
            req_ptr.deinit();
            return err;
        };
        if (response.head.status != .ok) {
            log.errId("openai", rid, "HTTP {d}", .{@intFromEnum(response.head.status)});
            req_ptr.deinit();
            return error.RequestFailed;
        }

        // receiveHead 成功后到 heap 转移所有权前若出错(create OOM),deinit 开着连接的 Request
        // (否则泄漏 socket fd)。errdefer LIFO:此 deinit 先跑、顶部 destroy 后跑 = deinit()→destroy()。
        errdefer req_ptr.deinit();
        const heap = try self.allocator.create(OpenAIStream);
        heap.* = .{ .allocator = self.allocator, .request = req_ptr, .response = response, .abort = abort, .id = rid };
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
    id: log.RequestId,
    done: bool = false,
    last_stop: StopReason = .unknown,
    // tool_calls 增量累积(OpenAI 分块发 name+arguments)。
    tc_id: std.ArrayList(u8) = .empty,
    tc_name: std.ArrayList(u8) = .empty,
    tc_args: std.ArrayList(u8) = .empty,
    tc_active: bool = false,
    tc_warned_parallel: bool = false, // 已对并行 tool_calls 告警过(只警一次)

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
        self.tc_id.deinit(self.allocator);
        self.tc_name.deinit(self.allocator);
        self.tc_args.deinit(self.allocator);
        self.request.deinit();
        self.allocator.destroy(self.request);
    }

    /// 读下一个中立事件。逐行读 SSE,翻译 OpenAI chunk → StreamEvent。
    fn next(self: *OpenAIStream) anyerror!?StreamEvent {
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
                return try self.flushPendingToolCall();
            };
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const data = std.mem.trim(u8, trimmed[5..], " ");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.done = true;
                if (try self.flushPendingToolCall()) |ev| return ev;
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
            return StreamEvent{
                .usage = UsageDelta{
                    .input_tokens = util_json.extractIntField(data, "prompt_tokens"),
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
        // delta.tool_calls 增量:累积 id/name/arguments(下一段 finish 时 flush)。
        // **MVP 限制(诚实登记,非 silent drop)**:只支持单个 tool_call/turn。OpenAI 并行
        // function calling 一个 delta 里能有多个 tool_call(各带不同 index/id),但本累积器是
        // 单组 ArrayList。检测到第二个不同 id 的 tool_call(tc_id 已填又来新 id)→ warn 一声,
        // 不静默丢(CLAUDE.md「no silent caps」死罪)。真并行支持是后续工作。
        if (std.mem.indexOf(u8, data, "\"tool_calls\"") != null) {
            self.tc_active = true;
            // extractStringField 取**首个**匹配 → 首个 tool_call 的 id/name/args 落到 tc_*。
            // 这是我们要执行的那一个,无论是否并行都要捕获。
            if (util_json.extractStringField(data, "id")) |id| {
                if (self.tc_id.items.len == 0) {
                    try self.tc_id.appendSlice(self.allocator, id);
                } else if (!std.mem.eql(u8, self.tc_id.items, id) and !self.tc_warned_parallel) {
                    // 跨 chunk:已有首个 id,又来一个不同 id = 第二个 tool_call(并行)。
                    self.tc_warned_parallel = true;
                    log.warnId("openai", self.id, "并行 tool_calls 未实现:第二个 tool_call id={s} 被忽略(MVP 仅单 tool_call/turn)", .{id});
                }
            }
            // 只在尚未判定并行时追加 name/args(首个 tool_call 的字段)。判定并行后,
            // 后续 chunk 的 name/args 属于第二个 tool_call,不能拼到第一个上。
            if (!self.tc_warned_parallel) {
                if (util_json.extractStringField(data, "name")) |name| {
                    try self.tc_name.appendSlice(self.allocator, name);
                }
                if (extractArgumentsDelta(data)) |args| {
                    try self.tc_args.appendSlice(self.allocator, args);
                }
            }
            // 同一 chunk 内多个 tool_call(array 里 ≥2 个 `"index":`):首个已捕获到 tc_*(上面
            // extractStringField 取首个),现在标记并行 → 警告 + 阻止后续 chunk 继续追加。
            // 必须放在追加之后,否则会跳过首个 tool_call 的 name/args 捕获。
            if (!self.tc_warned_parallel and countOccurrences(data, "\"index\":") > 1) {
                self.tc_warned_parallel = true;
                log.warnId("openai", self.id, "并行 tool_calls 未实现:单 delta 含多个 tool_call,仅执行第一个(MVP 仅单 tool_call/turn)", .{});
            }
        }
        return null;
    }

    /// 把累积的 tool_call flush 成中立 tool_use_start(若有)。done 时调。
    /// **所有权契约(对齐 Anthropic stream)**:id/name/input_json 必须是 owned slice,
    /// agent_loop 接管所有权(不 dupe,后续随 tool_uses 释放)。故这里 toOwnedSlice 转移,
    /// 不借用 self 的 ArrayList——否则 stream.deinit free 一次 + agent_loop free 一次 = double-free。
    fn flushPendingToolCall(self: *OpenAIStream) !?StreamEvent {
        if (!self.tc_active or self.tc_name.items.len == 0) return null;
        self.tc_active = false;
        const a = self.allocator;
        const id = try self.tc_id.toOwnedSlice(a);
        errdefer a.free(id);
        const name = try self.tc_name.toOwnedSlice(a);
        errdefer a.free(name);
        // arguments 空 → owned "{}"(也必须 owned,agent_loop 一视同仁 free)。
        const args = if (self.tc_args.items.len > 0)
            try self.tc_args.toOwnedSlice(a)
        else
            try a.dupe(u8, "{}");
        return StreamEvent{ .tool_use_start = .{
            .id = id,
            .name = name,
            .input_json = args,
        } };
    }
};

fn mapFinish(fr: []const u8) StopReason {
    if (std.mem.eql(u8, fr, "stop")) return .end_turn;
    if (std.mem.eql(u8, fr, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, fr, "length")) return .max_tokens;
    return .unknown;
}

/// 数 needle 在 haystack 中的(非重叠)出现次数。用于检测一个 delta chunk 里有几个 tool_call。
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

/// 提取 OpenAI delta.content(简易:找 `"content":"..."`,反转义)。null=本 chunk 无 content。
fn extractDeltaContent(data: []const u8) ?[]const u8 {
    // delta 里的 content;避免误命中其它 content(本测试 chunk 简单, 取首个 "content")。
    return util_json.extractStringField(data, "content");
}
/// 提取 tool_calls delta 的 arguments 片段。
fn extractArgumentsDelta(data: []const u8) ?[]const u8 {
    return util_json.extractStringField(data, "arguments");
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
        // OpenAI 要求每个 tool_result 是独立 message;这里取第一个(MVP 单工具足够证明)。
        for (m.content) |c| switch (c) {
            .tool_result => |tr| {
                try out.appendSlice(allocator, "{\"role\":\"tool\",\"tool_call_id\":");
                try util_json.serializeString(tr.tool_use_id, out, allocator);
                try out.appendSlice(allocator, ",\"content\":");
                try util_json.serializeString(tr.content, out, allocator);
                try out.append(allocator, '}');
                return;
            },
            else => {},
        };
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
