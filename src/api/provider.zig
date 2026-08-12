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
const request_overrides = @import("request_overrides.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const sync = @import("platform").sync;

pub const StreamHandle = api_stream.StreamHandle;
pub const ApiResponse = api_stream.ApiResponse;
pub const RetryReporter = api_stream.RetryReporter;

/// Registry for in-flight HTTP requests that borrow an AbortSignal.
/// Concrete transports register only after the request is initialized and
/// unregister before destroying it. `cancel` runs the transport's shutdown
/// hook under the same lock, closing the lifetime race without knowing HTTP
/// details in this neutral module.
pub const RequestAbortRegistry = struct {
    const ShutdownFn = *const fn (ctx: *anyopaque) void;
    const Slot = struct {
        signal: *const AbortSignal,
        ctx: *anyopaque,
        shutdown_fn: ShutdownFn,
    };

    mutex: sync.Mutex = .{},
    slots: std.ArrayList(Slot) = .empty,

    pub fn register(
        self: *RequestAbortRegistry,
        allocator: std.mem.Allocator,
        signal: *const AbortSignal,
        ctx: *anyopaque,
        shutdown_fn: ShutdownFn,
    ) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.slots.append(allocator, .{
            .signal = signal,
            .ctx = ctx,
            .shutdown_fn = shutdown_fn,
        });
        // Close the race where abort was accepted just before the transport
        // published its request in this registry.
        if (signal.isAborted()) shutdown_fn(ctx);
    }

    pub fn unregister(self: *RequestAbortRegistry, ctx: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items, 0..) |active, index| {
            if (active.ctx == ctx) {
                _ = self.slots.swapRemove(index);
                return;
            }
        }
    }

    pub fn cancel(self: *RequestAbortRegistry, signal: *const AbortSignal) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |active| {
            if (active.signal == signal) active.shutdown_fn(active.ctx);
        }
    }

    pub fn deinit(
        self: *RequestAbortRegistry,
        allocator: std.mem.Allocator,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.slots.items.len == 0);
        self.slots.deinit(allocator);
    }
};

/// provider+model 的能力查询(P2 落 capability 表;P0 先留枚举 + 占位)。
/// Interrupt a std.http request without taking ownership of its connection.
/// Windows needs an abortive AFD disconnect: ordinary `Stream.shutdown` does
/// not wake an already-pending asynchronous receive. POSIX shutdown does.
/// Request.deinit remains the sole close/destroy owner.
pub fn abortHttpRequest(request: *std.http.Client.Request) void {
    const connection = request.connection orelse return;
    connection.closing = true;
    if (@import("builtin").os.tag == .windows) {
        const win = std.os.windows;
        var iosb: win.IO_STATUS_BLOCK = undefined;
        var disconnect = win.AFD.PARTIAL_DISCONNECT_INFO{
            .DisconnectMode = .{
                .SEND = true,
                .RECEIVE = true,
                .ABORTIVE = true,
            },
            .Timeout = -1,
        };
        _ = win.ntdll.NtDeviceIoControlFile(
            connection.stream_reader.stream.socket.handle,
            null,
            null,
            null,
            &iosb,
            win.IOCTL.AFD.PARTIAL_DISCONNECT,
            &disconnect,
            @sizeOf(@TypeOf(disconnect)),
            null,
            0,
        );
        return;
    }
    connection.stream_reader.stream.shutdown(request.client.io, .both) catch {};
}

pub const Capability = enum {
    web_search,
    extended_thinking,
    prompt_cache,
    structured_output,
    server_tool,
    /// 返回 reasoning_content 平级字段(DeepSeek/Kimi/Qwen/GLM-5;Claude 用 thinking block,OpenAI 不暴露)。
    /// 用于 UI 决定是否折叠显示思考过程 + preserved thinking 回传策略。
    reasoning_content,
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
        model_override: ?[]const u8,
    ) anyerror!ApiResponse,

    /// Actively interrupt transport I/O registered against this exact signal.
    /// The default is a no-op for synthetic Providers that already observe the
    /// signal without a blocking transport.
    cancelFn: *const fn (ctx: *anyopaque, signal: *const AbortSignal) void = noopCancel,

    /// 模型规格:output 上限 / input context window(auto-compact 阈值用)。
    maxTokensFn: *const fn (ctx: *anyopaque) u32,
    maxInputTokensFn: *const fn (ctx: *anyopaque) u32,
    reasoningEffortFn: *const fn (ctx: *anyopaque) ?types.ReasoningEffort,
    /// Scoped subagent/teammate effort override. Optional because some wire
    /// protocols do not expose an equivalent control. A missing setter must
    /// fail explicitly instead of silently accepting an AgentDef field that
    /// cannot affect the request.
    setReasoningEffortFn: ?*const fn (ctx: *anyopaque, effort: ?types.ReasoningEffort) void = null,

    /// 当前生效的方言字段覆盖(null 字段 = profile 默认,即 dialect 静态推断)。
    /// 默认实现返全 null(等价"无覆盖",保持现状)。TUI / Config / AgentDef 可经
    /// setRequestOverridesFn 覆盖。来源:计划 jolly-glacier(2026-08-11)。
    requestOverridesFn: *const fn (ctx: *anyopaque) request_overrides.RequestOverrides = defaultRequestOverrides,
    /// 可选 setter;不支持配置方言字段的 provider 可不实现(返 error.OverridesUnsupportedProvider)。
    setRequestOverridesFn: ?*const fn (ctx: *anyopaque, o: request_overrides.RequestOverrides) void = null,

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
        return self.sendWithModel(messages, system, tools, null);
    }
    pub inline fn sendWithModel(self: Provider, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, model_override: ?[]const u8) anyerror!ApiResponse {
        return self.sendFn(self.ctx, messages, system, tools, model_override);
    }
    pub inline fn cancel(self: Provider, signal: *const AbortSignal) void {
        self.cancelFn(self.ctx, signal);
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
    pub inline fn setReasoningEffort(self: Provider, effort: ?types.ReasoningEffort) !void {
        const setter = self.setReasoningEffortFn orelse return error.AgentEffortUnsupportedProvider;
        setter(self.ctx, effort);
    }
    pub inline fn requestOverrides(self: Provider) request_overrides.RequestOverrides {
        return self.requestOverridesFn(self.ctx);
    }
    pub inline fn setRequestOverrides(self: Provider, o: request_overrides.RequestOverrides) !void {
        const setter = self.setRequestOverridesFn orelse return error.OverridesUnsupportedProvider;
        setter(self.ctx, o);
    }
    pub inline fn supports(self: Provider, cap: Capability) bool {
        return self.supportsFn(self.ctx, cap);
    }
};

fn noopCancel(_: *anyopaque, _: *const AbortSignal) void {}

/// 默认 requestOverrides 实现:返全 null(等价"无覆盖",走 profile 默认)。
/// 既有 provider 若不实现 requestOverridesFn,自动用此 default,行为不变。
fn defaultRequestOverrides(_: *anyopaque) request_overrides.RequestOverrides {
    return .{};
}

test "Capability enum + StreamHandle 可表达" {
    try std.testing.expect(Capability.web_search != Capability.prompt_cache);
    try std.testing.expect(@sizeOf(Provider) > 0);
}

test "RequestAbortRegistry closes pre-registration abort race" {
    var registry = RequestAbortRegistry{};
    defer registry.deinit(std.testing.allocator);
    var signal = AbortSignal.init();
    signal.abort(.user_interrupt);
    var interrupted = false;
    const Probe = struct {
        fn shutdown(raw: *anyopaque) void {
            const value: *bool = @ptrCast(@alignCast(raw));
            value.* = true;
        }
    };
    try registry.register(
        std.testing.allocator,
        &signal,
        &interrupted,
        Probe.shutdown,
    );
    defer registry.unregister(&interrupted);
    try std.testing.expect(interrupted);
}
