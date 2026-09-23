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
const log = @import("../util/log.zig");

pub const StreamHandle = api_stream.StreamHandle;
pub const ApiResponse = api_stream.ApiResponse;
pub const RetryReporter = api_stream.RetryReporter;

/// Registry for in-flight HTTP requests that borrow an AbortSignal.
/// Concrete transports register only after the request is initialized and
/// unregister before destroying it. `cancel` runs the transport's shutdown
/// hook under the same lock, closing the lifetime race without knowing HTTP
/// details in this neutral module.
///
/// **Liveness (2026-09-10)**: a request registered with `idle_limit_ms > 0` is
/// also watched by a monitor thread. When no byte has arrived for that long the
/// monitor runs the same shutdown hook, so a read that is blocked in the kernel
/// returns instead of waiting forever — a TUI session froze for 40 minutes on a
/// gateway connection that stayed ESTABLISHED and silent; nothing else (abort
/// flag, watchdog, Ctrl+C) can wake a thread that sits in `readv`. The
/// transport reads `stalled` afterwards to report `StreamStalled` rather than
/// a generic connection error.
///
/// **Two phases, two limits (2026-09-11)**: the clock is refreshed by
/// `LivenessReader` on every transport read — bytes are the evidence of life,
/// not parsed events. A tool call's `input_json_delta` frames, SSE pings and
/// unknown events used to leave the clock untouched, so a legitimate 126 s
/// tool call died as "stalled" although bytes arrived every second. The
/// request is registered with the strict head-phase limit; once the response
/// head is accepted the transport switches the slot to the body-phase limit
/// with `setIdleLimit` (larger: a gateway may generate a whole tool call
/// before writing a single byte of it).
pub const RequestAbortRegistry = struct {
    const ShutdownFn = *const fn (ctx: *anyopaque) void;
    const Slot = struct {
        /// Null = not cancellable through an AbortSignal (liveness-only slot).
        signal: ?*const AbortSignal,
        ctx: *anyopaque,
        shutdown_fn: ShutdownFn,
        /// 0 = no liveness monitoring for this request.
        idle_limit_ms: u64 = 0,
        /// Last *progress*: bytes that carry model output (any SSE line that is
        /// not a keepalive, or any byte of a non-stream body). This is the clock
        /// the idle limit is judged against.
        last_activity_ms: u64 = 0,
        /// Last byte of any kind, keepalives included. Never judged, only
        /// reported: it tells a stall apart from a dead connection (2026-09-23:
        /// a gateway pinged every 15 s for 55 minutes while its upstream produced
        /// nothing; counting those pings as activity made the stall invisible).
        last_transport_ms: u64 = 0,
        /// Set once the monitor shut the request down for inactivity: how long
        /// it had been silent. Read by the transport to name the failure.
        stalled_after_ms: ?u64 = null,
        /// Transport idle at the moment of the stall verdict (see `Stall`).
        stalled_transport_idle_ms: u64 = 0,
    };

    /// Monitor wake-up interval; also bounds how late a stall is detected.
    pub const MONITOR_TICK_MS: u64 = 250;

    /// What the monitor recorded when it shut a silent request down: how long
    /// the request had been silent and which limit was in force at the time
    /// (head- or body-phase). The transport names the failure with both.
    pub const Stall = struct {
        /// Silence in *progress* terms (no model-output bytes for this long).
        idle_ms: u64,
        limit_ms: u64,
        /// Silence in transport terms (no bytes at all, keepalives included).
        /// Much smaller than `idle_ms` means the gateway kept the connection
        /// alive while producing nothing; equal means the connection was dead.
        transport_idle_ms: u64,
    };

    mutex: sync.Mutex = .{},
    slots: std.ArrayList(Slot) = .empty,
    monitor: ?std.Thread = null,
    monitor_stop: bool = false,
    monitor_cond: sync.Condition = .{},

    pub fn register(
        self: *RequestAbortRegistry,
        allocator: std.mem.Allocator,
        signal: *const AbortSignal,
        ctx: *anyopaque,
        shutdown_fn: ShutdownFn,
    ) error{OutOfMemory}!void {
        return self.registerMonitored(allocator, signal, ctx, shutdown_fn, 0);
    }

    /// Register an in-flight request. `signal` null = no abort routing;
    /// `idle_limit_ms` > 0 = the monitor shuts the request down after that much
    /// silence (call `touch` whenever bytes arrive).
    pub fn registerMonitored(
        self: *RequestAbortRegistry,
        allocator: std.mem.Allocator,
        signal: ?*const AbortSignal,
        ctx: *anyopaque,
        shutdown_fn: ShutdownFn,
        idle_limit_ms: u64,
    ) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = monotonicMs();
        try self.slots.append(allocator, .{
            .signal = signal,
            .ctx = ctx,
            .shutdown_fn = shutdown_fn,
            .idle_limit_ms = idle_limit_ms,
            .last_activity_ms = now,
            .last_transport_ms = now,
        });
        // Close the race where abort was accepted just before the transport
        // published its request in this registry.
        if (signal) |s| if (s.isAborted()) shutdown_fn(ctx);
        self.ensureMonitorLocked(idle_limit_ms);
    }

    /// Spawn the monitor thread on first monitored registration. Caller holds
    /// the mutex. A limit of 0 never needs a monitor.
    fn ensureMonitorLocked(self: *RequestAbortRegistry, idle_limit_ms: u64) void {
        if (idle_limit_ms == 0 or self.monitor != null) return;
        self.monitor_stop = false;
        self.monitor = std.Thread.spawn(.{}, monitorMain, .{self}) catch |err| blk: {
            // No monitor = no liveness guarantee for this process; say so
            // once rather than pretending the limit is enforced.
            log.warn("client", "stream liveness monitor unavailable ({s}); idle limit {d}ms will not be enforced", .{ @errorName(err), idle_limit_ms });
            break :blk null;
        };
    }

    /// Phase switch: the response head has been accepted, so from now on the
    /// request is judged against `limit_ms` (0 = stop monitoring it). The
    /// clock restarts here as well — the head itself was activity. A slot
    /// the monitor has already shut down keeps its verdict.
    pub fn setIdleLimit(self: *RequestAbortRegistry, ctx: *anyopaque, limit_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |*active| {
            if (active.ctx != ctx) continue;
            active.idle_limit_ms = limit_ms;
            const now = monotonicMs();
            active.last_activity_ms = now;
            active.last_transport_ms = now;
            self.ensureMonitorLocked(limit_ms);
            return;
        }
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

    /// Progress arrived for `ctx` (model-output bytes: a non-keepalive SSE line,
    /// or any byte of a non-stream body): restart the idle clock. Cheap (one
    /// uncontended lock).
    pub fn touch(self: *RequestAbortRegistry, ctx: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |*active| {
            if (active.ctx == ctx) {
                const now = monotonicMs();
                active.last_activity_ms = now;
                active.last_transport_ms = now;
                return;
            }
        }
    }

    /// Bytes of any kind arrived for `ctx` (called per transport read by
    /// `LivenessReader` in transport-only mode). Does **not** restart the idle
    /// clock: a keepalive proves the gateway is up, not that the model is
    /// producing. Only the stall report reads this stamp.
    pub fn touchTransport(self: *RequestAbortRegistry, ctx: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |*active| {
            if (active.ctx == ctx) {
                active.last_transport_ms = monotonicMs();
                return;
            }
        }
    }

    /// Shut down every monitored request that has been silent past its limit.
    /// Returns how many were shut down this pass. Idempotent per request: a
    /// stalled slot is never shut down twice.
    pub fn reapStalled(self: *RequestAbortRegistry, now_ms: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var reaped: usize = 0;
        for (self.slots.items) |*active| {
            if (active.idle_limit_ms == 0 or active.stalled_after_ms != null) continue;
            const idle = now_ms -| active.last_activity_ms;
            if (idle < active.idle_limit_ms) continue;
            active.stalled_after_ms = idle;
            active.stalled_transport_idle_ms = now_ms -| active.last_transport_ms;
            log.warn("client", "stream idle for {d}ms (limit {d}ms, last transport byte {d}ms ago): shutting down the connection so the blocked read returns", .{ idle, active.idle_limit_ms, active.stalled_transport_idle_ms });
            active.shutdown_fn(active.ctx);
            reaped += 1;
        }
        return reaped;
    }

    /// How long `ctx` had been silent when the monitor shut it down; null =
    /// not stalled (any read error then has another cause).
    pub fn stalledIdleMs(self: *RequestAbortRegistry, ctx: *anyopaque) ?u64 {
        return (self.stalled(ctx) orelse return null).idle_ms;
    }

    /// The monitor's verdict for `ctx` with the limit that was in force; null =
    /// not stalled (any read error then has another cause).
    pub fn stalled(self: *RequestAbortRegistry, ctx: *anyopaque) ?Stall {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |active| {
            if (active.ctx != ctx) continue;
            const idle = active.stalled_after_ms orelse return null;
            return .{ .idle_ms = idle, .limit_ms = active.idle_limit_ms, .transport_idle_ms = active.stalled_transport_idle_ms };
        }
        return null;
    }

    fn monitorMain(self: *RequestAbortRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.monitor_stop) {
            // timedWait releases the mutex while sleeping and re-acquires it;
            // deinit signals the condition so a stop never waits a full tick.
            _ = self.monitor_cond.timedWait(&self.mutex, MONITOR_TICK_MS * std.time.ns_per_ms);
            if (self.monitor_stop) break;
            self.mutex.unlock();
            _ = self.reapStalled(monotonicMs());
            self.mutex.lock();
        }
    }

    pub fn deinit(
        self: *RequestAbortRegistry,
        allocator: std.mem.Allocator,
    ) void {
        self.mutex.lock();
        self.monitor_stop = true;
        self.monitor_cond.broadcast();
        const monitor = self.monitor;
        self.monitor = null;
        self.mutex.unlock();
        if (monitor) |thread| thread.join();
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.slots.items.len == 0);
        self.slots.deinit(allocator);
    }
};

fn monotonicMs() u64 {
    return @intCast(@max(@import("../util/time.zig").nowMs(), 0));
}

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
    /// 原生图像输入(vision)。宿主入口预检用;序列化层守门以
    /// ModelProfile.supports_image_input 为单一真相(capability.zig 转发查表)。
    image_input,
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
    /// The same two numbers for a *specific* model, so a subagent whose
    /// `model_override` names something other than this provider's own model
    /// is budgeted against the window it will actually be sent to. Optional: a
    /// provider that cannot answer per model keeps returning its own numbers,
    /// which is what every caller got before these existed.
    maxTokensForFn: ?*const fn (ctx: *anyopaque, model: []const u8) u32 = null,
    maxInputTokensForFn: ?*const fn (ctx: *anyopaque, model: []const u8) u32 = null,
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
    /// 同一问题针对**某个具体模型**——subagent 的 `model_override` 指向的不是本
    /// provider 自己的模型时,它的能力(尤其 image_input)要按它真要发往的模型答,
    /// 不是按父模型答。可选:答不了的 provider 保持返回自己的答案,与 maxTokensForFn
    /// 同一约定。
    supportsForModelFn: ?*const fn (ctx: *anyopaque, cap: Capability, model: []const u8) bool = null,
    /// 本路由目录里声明能收图的模型名(借用 provider 内存;调用方只释放外层 slice)。
    /// 可选:没有目录的 provider 不实现,调用方视为"不知道",不编造候选。
    visionModelsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const []const u8 = null,
    /// Last transport identifiers, available even when a request failed before
    /// a StreamHandle could be returned (used by the Metask ledger).
    requestIdTextFn: ?*const fn (ctx: *anyopaque) []const u8 = null,
    serverRequestIdFn: ?*const fn (ctx: *anyopaque) []const u8 = null,
    httpStatusFn: ?*const fn (ctx: *anyopaque) u16 = null,
    retryAttemptFn: ?*const fn (ctx: *anyopaque) u32 = null,

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

    /// Context window of the model a request will actually name. Every budget
    /// derived from the window - per-result bytes, the turn budget, the
    /// auto-compact thresholds - has to use this rather than
    /// `maxInputTokens()`, because a subagent shares its parent's Provider and
    /// differs from it only by `model_override`. Sizing a child's results
    /// against the parent's window is how a 200K parent hands a 32K child a
    /// history the child's endpoint rejects outright.
    pub inline fn maxInputTokensFor(self: Provider, model_override: ?[]const u8) u32 {
        const name = model_override orelse return self.maxInputTokens();
        const resolve = self.maxInputTokensForFn orelse return self.maxInputTokens();
        return resolve(self.ctx, name);
    }

    pub inline fn maxTokensFor(self: Provider, model_override: ?[]const u8) u32 {
        const name = model_override orelse return self.maxTokens();
        const resolve = self.maxTokensForFn orelse return self.maxTokens();
        return resolve(self.ctx, name);
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
    /// 能力查询,按请求真会命名的模型答:`model_override` 为 null 时等价 `supports`。
    /// 与 `maxInputTokensFor` 同一形状——每一处按 override 派生的判断都要问这个,
    /// 否则子 agent 的图片门控会拿父模型的能力当自己的。
    pub inline fn supportsForModel(self: Provider, cap: Capability, model_override: ?[]const u8) bool {
        const name = model_override orelse return self.supports(cap);
        const resolve = self.supportsForModelFn orelse return self.supports(cap);
        return resolve(self.ctx, cap, name);
    }
    /// 目录声明能收图的模型名;provider 没有目录 → 空 slice(不是错误)。
    pub inline fn visionModels(self: Provider, allocator: std.mem.Allocator) anyerror![]const []const u8 {
        const f = self.visionModelsFn orelse return try allocator.alloc([]const u8, 0);
        return f(self.ctx, allocator);
    }
    pub inline fn requestIdText(self: Provider) []const u8 {
        const f = self.requestIdTextFn orelse return "";
        return f(self.ctx);
    }
    pub inline fn serverRequestId(self: Provider) []const u8 {
        const f = self.serverRequestIdFn orelse return "";
        return f(self.ctx);
    }
    pub inline fn httpStatus(self: Provider) u16 {
        const f = self.httpStatusFn orelse return 0;
        return f(self.ctx);
    }
    pub inline fn retryAttempt(self: Provider) u32 {
        const f = self.retryAttemptFn orelse return 0;
        return f(self.ctx);
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

const LivenessProbe = struct {
    shutdowns: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fn shutdown(ctx: *anyopaque) void {
        const self: *LivenessProbe = @ptrCast(@alignCast(ctx));
        _ = self.shutdowns.fetchAdd(1, .acq_rel);
    }
};

test "RequestAbortRegistry: reapStalled shuts a silent request down once, touch restarts the clock, limit 0 never stalls" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var watched = LivenessProbe{};
    var unwatched = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&watched), LivenessProbe.shutdown, 1_000);
    try registry.registerMonitored(a, null, @ptrCast(&unwatched), LivenessProbe.shutdown, 0);
    defer registry.unregister(@ptrCast(&watched));
    defer registry.unregister(@ptrCast(&unwatched));
    // Measure from the slot's own clock: registering spawns the monitor thread,
    // which can take more than a millisecond, so "now" is not the registration time.
    const registered_at = registry.slots.items[0].last_activity_ms;
    // Below the limit: nothing happens.
    try std.testing.expectEqual(@as(usize, 0), registry.reapStalled(registered_at + 999));
    try std.testing.expect(registry.stalledIdleMs(@ptrCast(&watched)) == null);
    // Activity restarts the idle clock.
    registry.touch(@ptrCast(&watched));
    const touched_at = registry.slots.items[0].last_activity_ms;
    try std.testing.expect(touched_at >= registered_at);
    try std.testing.expectEqual(@as(usize, 0), registry.reapStalled(touched_at + 999));
    // Past the limit: shut down exactly once, stall recorded, unmonitored slot untouched.
    try std.testing.expectEqual(@as(usize, 1), registry.reapStalled(touched_at + 1_000));
    try std.testing.expectEqual(@as(usize, 0), registry.reapStalled(touched_at + 5_000));
    try std.testing.expectEqual(@as(u32, 1), watched.shutdowns.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), unwatched.shutdowns.load(.acquire));
    try std.testing.expect(registry.stalledIdleMs(@ptrCast(&watched)).? >= 1_000);
    try std.testing.expect(registry.stalledIdleMs(@ptrCast(&unwatched)) == null);
    const verdict = registry.stalled(@ptrCast(&watched)).?;
    try std.testing.expect(verdict.idle_ms >= 1_000);
    try std.testing.expectEqual(@as(u64, 1_000), verdict.limit_ms);
    // No transport activity was reported after the progress touch, so both clocks agree.
    try std.testing.expectEqual(verdict.idle_ms, verdict.transport_idle_ms);
    try std.testing.expect(registry.stalled(@ptrCast(&unwatched)) == null);
    // A liveness-only slot is not cancellable through any signal.
    var signal = AbortSignal.init();
    signal.abort(.user_ctrl_c);
    registry.cancel(&signal);
    try std.testing.expectEqual(@as(u32, 1), watched.shutdowns.load(.acquire));
}

test "RequestAbortRegistry: setIdleLimit switches the slot to the body-phase limit, restarts the clock, and 0 stops monitoring" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe = LivenessProbe{};
    // Registered under the strict head-phase limit.
    try registry.registerMonitored(a, null, @ptrCast(&probe), LivenessProbe.shutdown, 1_000);
    defer registry.unregister(@ptrCast(&probe));
    const registered_at = registry.slots.items[0].last_activity_ms;
    // Head accepted: the body phase is judged against a larger limit. The old
    // limit no longer applies even though more than 1s of "silence" elapsed.
    registry.setIdleLimit(@ptrCast(&probe), 5_000);
    const switched_at = registry.slots.items[0].last_activity_ms;
    try std.testing.expect(switched_at >= registered_at);
    try std.testing.expectEqual(@as(u64, 5_000), registry.slots.items[0].idle_limit_ms);
    try std.testing.expectEqual(@as(usize, 0), registry.reapStalled(switched_at + 4_999));
    try std.testing.expect(registry.stalled(@ptrCast(&probe)) == null);
    try std.testing.expectEqual(@as(usize, 1), registry.reapStalled(switched_at + 5_000));
    const verdict = registry.stalled(@ptrCast(&probe)).?;
    try std.testing.expectEqual(@as(u64, 5_000), verdict.limit_ms);
    try std.testing.expect(verdict.idle_ms >= 5_000);
    try std.testing.expectEqual(@as(u32, 1), probe.shutdowns.load(.acquire));

    // A limit of 0 takes a fresh slot out of monitoring entirely.
    var quiet = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&quiet), LivenessProbe.shutdown, 1_000);
    defer registry.unregister(@ptrCast(&quiet));
    registry.setIdleLimit(@ptrCast(&quiet), 0);
    const quiet_at = registry.slots.items[1].last_activity_ms;
    try std.testing.expectEqual(@as(usize, 0), registry.reapStalled(quiet_at + 1_000_000));
    try std.testing.expect(registry.stalled(@ptrCast(&quiet)) == null);
    try std.testing.expectEqual(@as(u32, 0), quiet.shutdowns.load(.acquire));
}

test "RequestAbortRegistry: setIdleLimit on a slot registered without monitoring spawns the monitor" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&probe), LivenessProbe.shutdown, 0);
    defer registry.unregister(@ptrCast(&probe));
    try std.testing.expect(registry.monitor == null);
    registry.setIdleLimit(@ptrCast(&probe), 50);
    try std.testing.expect(registry.monitor != null);
    var waited: u64 = 0;
    while (registry.stalled(@ptrCast(&probe)) == null and waited < 5_000) : (waited += 10) {
        @import("../util/time.zig").sleepMs(10);
    }
    try std.testing.expect(registry.stalled(@ptrCast(&probe)).?.idle_ms >= 50);
}

test "RequestAbortRegistry: the monitor thread reaps a stalled request on its own and stops promptly on deinit" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    var probe = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&probe), LivenessProbe.shutdown, 50);
    try std.testing.expect(registry.monitor != null);
    // Wait for the monitor (250ms tick) rather than calling reapStalled by hand.
    var waited_ms: u64 = 0;
    while (probe.shutdowns.load(.acquire) == 0 and waited_ms < 5_000) : (waited_ms += 20) {
        @import("../util/time.zig").sleepMs(20);
    }
    try std.testing.expectEqual(@as(u32, 1), probe.shutdowns.load(.acquire));
    try std.testing.expect(registry.stalledIdleMs(@ptrCast(&probe)).? >= 50);
    registry.unregister(@ptrCast(&probe));
    const before = monotonicMs();
    registry.deinit(a);
    // deinit signals the monitor instead of waiting out a full tick (generous bound: a loaded
    // CI box, not a tick multiple, is what this must survive).
    try std.testing.expect(monotonicMs() - before < 2_000);
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

test "runtime capability bridge covers the full runtime enum" {
    // **必须绑真枚举**:此前 offer.zig 里是一份手抄副本,于是"加运行时能力却漏
    // 映射会编译报错"的承诺其实只覆盖副本——issue #25 加 `pdf_input` 时它一声
    // 没吭。绑 `Capability` 本尊后,这条断言才真正是那个 comptime 守卫。
    //
    // 断言住在 api 侧而不是 offer.zig 里,是因为 `subsystem:boundary` 不许
    // provider 子系统 import 传输层——那正是 `test:provider` 隔离性的全部内容。
    // offer.zig 的两个 helper 对运行时枚举是泛型的,生产代码因此不跨界;只有这
    // 条断言需要具体类型,于是它下沉到允许同时看见两层的这一侧。方向是
    // api → provider,守卫的强度一分未减。
    const offer = @import("../provider/offer.zig");
    offer.assertRuntimeCoverage(Capability);
    try std.testing.expectEqual(offer.Capability.vision, offer.fromRuntimeCapability(Capability.image_input));
    try std.testing.expectEqual(offer.Capability.reasoning, offer.fromRuntimeCapability(Capability.extended_thinking));
    try std.testing.expectEqual(offer.Capability.caching, offer.fromRuntimeCapability(Capability.prompt_cache));
}

test "a subagent's budget follows its model_override, not the shared provider" {
    // A subagent shares its parent's Provider and differs from it only by
    // `model_override` (see subagent.zig: "共享:api provider"). Every budget
    // derived from the context window therefore has to resolve that override,
    // or a 200K parent sizes a 32K child's results - and its auto-compact
    // thresholds - against a window the child's endpoint does not have.
    const Fake = struct {
        fn model(_: *anyopaque) []const u8 {
            return "parent-200k";
        }
        fn maxTokens(_: *anyopaque) u32 {
            return 32_000;
        }
        fn maxInputTokens(_: *anyopaque) u32 {
            return 200_000;
        }
        fn maxInputTokensFor(_: *anyopaque, name: []const u8) u32 {
            return if (std.mem.eql(u8, name, "child-32k")) 32_000 else 200_000;
        }
        fn maxTokensForModel(_: *anyopaque, name: []const u8) u32 {
            return if (std.mem.eql(u8, name, "child-32k")) 8_000 else 32_000;
        }
        fn supports(_: *anyopaque, _: Capability) bool {
            return false;
        }
        fn reasoningEffort(_: *anyopaque) ?types.ReasoningEffort {
            return null;
        }
    };
    var ctx: u8 = 0;
    const capable = Provider{
        .ctx = &ctx,
        .modelFn = Fake.model,
        .sendStreamFn = undefined,
        .sendStreamRetryFn = undefined,
        .sendFn = undefined,
        .maxTokensFn = Fake.maxTokens,
        .maxInputTokensFn = Fake.maxInputTokens,
        .maxTokensForFn = Fake.maxTokensForModel,
        .maxInputTokensForFn = Fake.maxInputTokensFor,
        .reasoningEffortFn = Fake.reasoningEffort,
        .supportsFn = Fake.supports,
    };
    // No override: the provider's own model, exactly as before.
    try std.testing.expectEqual(@as(u32, 200_000), capable.maxInputTokensFor(null));
    try std.testing.expectEqual(@as(u32, 32_000), capable.maxTokensFor(null));
    // Override: the window the request will actually be sent to.
    try std.testing.expectEqual(@as(u32, 32_000), capable.maxInputTokensFor("child-32k"));
    try std.testing.expectEqual(@as(u32, 8_000), capable.maxTokensFor("child-32k"));

    // A provider that cannot answer per model keeps its own numbers rather
    // than guessing - the behavior every caller had before these existed.
    var plain = capable;
    plain.maxInputTokensForFn = null;
    plain.maxTokensForFn = null;
    try std.testing.expectEqual(@as(u32, 200_000), plain.maxInputTokensFor("child-32k"));
    try std.testing.expectEqual(@as(u32, 32_000), plain.maxTokensFor("child-32k"));
}

test "RequestAbortRegistry: touchTransport keeps the connection's byte stamp fresh but never restarts the idle clock" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&probe), LivenessProbe.shutdown, 1_000);
    defer registry.unregister(@ptrCast(&probe));
    const registered_at = registry.slots.items[0].last_activity_ms;
    // Keepalive bytes keep arriving (gateway pings) — the transport stamp moves,
    // the progress stamp does not.
    registry.slots.items[0].last_transport_ms = registered_at + 900;
    registry.touchTransport(@ptrCast(&probe));
    try std.testing.expect(registry.slots.items[0].last_transport_ms >= registered_at);
    try std.testing.expectEqual(registered_at, registry.slots.items[0].last_activity_ms);
    // Force the stamps to known values so the verdict is deterministic.
    registry.slots.items[0].last_transport_ms = registered_at + 950;
    try std.testing.expectEqual(@as(usize, 1), registry.reapStalled(registered_at + 1_000));
    const verdict = registry.stalled(@ptrCast(&probe)).?;
    try std.testing.expectEqual(@as(u64, 1_000), verdict.idle_ms);
    try std.testing.expectEqual(@as(u64, 50), verdict.transport_idle_ms);
    try std.testing.expectEqual(@as(u32, 1), probe.shutdowns.load(.acquire));
}
