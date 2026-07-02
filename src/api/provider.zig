//! Provider:多 LLM 后端的可插拔接口(vtable),形状同 UiBackend。
//!
//! 设计(见 metaknow root「多 Provider 分离架构设计」f5no2pxq9rqvs99t23x8):
//! agent_loop core 只调 Provider 的语义方法,不知协议/认证/URL/SSE 格式。多 provider 的全部
//! 脏活(Anthropic / OpenAI / Gemini / Grok 各自的 wire format + 认证)锁在各 Provider 实现里。
//!
//! **中立 IR 是归一点**:请求侧用中立 ApiMessage/ToolDefinition,响应侧用中立 StreamHandle
//! (吐 StreamEvent:text/tool_use_start/usage/done)+ ApiResponse。各 provider 在自己实现内部
//! 翻译进/出这套 IR。agent_loop 拿到的永远是中立类型,换 provider 一行不改。
//!
//! **非 generic**:接口只认中立类型(StreamHandle / ApiResponse,均在 api/stream.zig 这一叶子层),
//! 不出现任何 provider 具体类型(如 client.zig 的 StreamResponse)。故无循环依赖、无需 generic 绕。
//! 各 provider 的具体 StreamResponse 各自 .handle() 成中立 StreamHandle。
//!
//! 认证不抽统一接口:OAuth/SigV4/企业中转站差异太大,是每个 Provider 实现的私事,塞在 sendStream
//! 内部(对齐 cc——它也没抽 Auth)。

const std = @import("std");
const types = @import("../types.zig");
const json_mod = @import("../json.zig");
const api_stream = @import("stream.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const StreamHandle = api_stream.StreamHandle;
pub const ApiResponse = api_stream.ApiResponse;
pub const RetryReporter = api_stream.RetryReporter;

/// provider+model 的能力查询(P2 落 capability 表;P0 先留枚举 + 占位)。
pub const Capability = enum {
    web_search,
    extended_thinking,
    prompt_cache,
    structured_output,
    server_tool,
};

/// LLM 后端接口。ctx 是后端实例(Client / 未来 OpenAIClient)的 type-erased 指针。
/// 方法签名镜像现 Client 的公开面——这是各 provider 必须覆盖的方法集。**全中立类型,非 generic。**
///
/// **借用契约**:Provider 值借用底层 ctx(如 *Client);底层必须比 Provider 值活得久。
/// 勿把 Provider 值存进比 ctx 长寿的容器(否则 UAF)。Provider 是廉价值(fn-ptr+指针),按值传。
pub const Provider = struct {
    ctx: *anyopaque,

    /// 当前 model 名(显示 / model_override 解析 / 日志)。借用,provider 生命周期有效。
    modelFn: *const fn (ctx: *anyopaque) []const u8,

    /// 流式请求(主路径)。messages/system/tools 是中立 IR;返回中立 StreamHandle。
    /// model_override:subagent 用;tool_choice:web_search 强制工具用。abort 网络读阶段生效。
    /// user_query:**本轮用户原话**(中立——任何 provider 的 server-tool 进度行显示真实 query 用;
    /// 不支持 server tool 的 provider 忽略它即可,无害)。空="" = 无。
    sendStreamFn: *const fn (
        ctx: *anyopaque,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
        user_query: []const u8,
    ) anyerror!StreamHandle,

    /// 带建连重试的流式请求。
    sendStreamRetryFn: *const fn (
        ctx: *anyopaque,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
        abort: ?*const AbortSignal,
        model_override: ?[]const u8,
        tool_choice: ?json_mod.ToolChoice,
        max_retries: u32,
        retry_base_ms: u64,
        reporter: ?RetryReporter,
        user_query: []const u8,
    ) anyerror!StreamHandle,

    /// 非流式请求(compact summary 用)。
    sendFn: *const fn (
        ctx: *anyopaque,
        messages: []const types.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const json_mod.ToolDefinition,
    ) anyerror!ApiResponse,

    /// 模型规格:output 上限 / input context window(auto-compact 阈值用)。
    maxTokensFn: *const fn (ctx: *anyopaque) u32,
    maxInputTokensFn: *const fn (ctx: *anyopaque) u32,
    reasoningEffortFn: *const fn (ctx: *anyopaque) ?types.ReasoningEffort,

    /// 能力查询(P2 真接表;P0 实现可恒按 Anthropic 能力答)。
    supportsFn: *const fn (ctx: *anyopaque, cap: Capability) bool,

    // ── 便利转发 ──────────────────────────────────────────────────────────
    pub inline fn model(self: Provider) []const u8 {
        return self.modelFn(self.ctx);
    }
    pub inline fn sendStream(self: Provider, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!StreamHandle {
        return self.sendStreamFn(self.ctx, messages, system, tools, abort, model_override, tool_choice, user_query);
    }
    pub inline fn sendStreamRetry(self: Provider, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, max_retries: u32, retry_base_ms: u64, reporter: ?RetryReporter, user_query: []const u8) anyerror!StreamHandle {
        return self.sendStreamRetryFn(self.ctx, messages, system, tools, abort, model_override, tool_choice, max_retries, retry_base_ms, reporter, user_query);
    }
    pub inline fn send(self: Provider, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition) anyerror!ApiResponse {
        return self.sendFn(self.ctx, messages, system, tools);
    }
    pub inline fn maxTokens(self: Provider) u32 {
        return self.maxTokensFn(self.ctx);
    }
    pub inline fn maxInputTokens(self: Provider) u32 {
        return self.maxInputTokensFn(self.ctx);
    }
    pub inline fn reasoningEffort(self: Provider) ?types.ReasoningEffort {
        return self.reasoningEffortFn(self.ctx);
    }
    pub inline fn supports(self: Provider, cap: Capability) bool {
        return self.supportsFn(self.ctx, cap);
    }
};

test "Capability enum + StreamHandle 可表达" {
    try std.testing.expect(Capability.web_search != Capability.prompt_cache);
    try std.testing.expect(@sizeOf(Provider) > 0);
}
