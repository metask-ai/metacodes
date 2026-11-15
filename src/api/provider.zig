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
const image_capability = @import("image_capability.zig");
const json_mod = @import("../json.zig");
const api_stream = @import("stream.zig");
const request_overrides = @import("request_overrides.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const sync = @import("platform").sync;
const platform_thread = @import("platform").thread;
const log = @import("../util/log.zig");
const error_class = @import("error_class.zig");
const auth_header_mod = @import("auth_header.zig");

/// How this provider reaches its model: everything another process needs to
/// make the same request against the same account. A sealed Skill's gateway
/// (doc/SEALED_SKILL_PROTOCOL.md §8.1) runs the Skill's model calls with the
/// client's own route, so the model, the endpoint and the account are the
/// ones the user's fork would have used. Slices borrow the provider.
pub const ProviderRoute = struct {
    kind: types.ProviderKind,
    base_url: []const u8,
    model: []const u8,
    /// The secret as the provider sends it (API key or bearer token).
    credential: []const u8,
    /// Null keeps the kind's default header.
    auth_scheme: ?auth_header_mod.AuthScheme = null,
    openai_protocol: types.OpenAIProtocol = .chat_completions,
};

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
///
/// **Dead connections (2026-10-24)**: the body-phase limit is about *progress*
/// and is long (up to 30 minutes) because a gateway may legitimately sit on a
/// whole tool call. A connection that has died without a FIN or RST looks the
/// same to it — a session waited 1801 s on a socket that had received 6.5 KB
/// and then nothing, not even the keepalive pings that endpoint otherwise sends
/// every ≤15 s. So the registry also learns, per endpoint (one registry per
/// client), how long the peer stays quiet before it speaks up with a keepalive
/// mid-stream (`touchKeepalive`). Once it has seen that often enough, an SSE
/// body that goes silent at the *transport* level for several of those
/// intervals is judged dead (`Stall.cause == .transport_dead`). An endpoint
/// that never pinged mid-stream keeps exactly the old behaviour.
pub const RequestAbortRegistry = struct {
    const ShutdownFn = *const fn (ctx: *anyopaque) void;

    /// What the response body is once the head has been accepted. Only an SSE
    /// stream can carry keepalive lines, so only it is judged by the
    /// transport-dead rule; a whole body keeps the progress limit alone.
    pub const BodyKind = enum { whole, sse };

    const Phase = enum { head, whole_body, sse_body };

    const Slot = struct {
        /// Null = not cancellable through an AbortSignal (liveness-only slot).
        signal: ?*const AbortSignal,
        ctx: *anyopaque,
        shutdown_fn: ShutdownFn,
        phase: Phase = .head,
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
        /// The silence the most recent transport read ended (time since the
        /// byte before it). A keepalive line parsed out of that read inherits it
        /// as the interval the peer let pass before speaking up.
        last_transport_gap_ms: u64 = 0,
        /// A transport read has arrived that no keepalive sample has used yet;
        /// one read carrying "event: ping" + "data: {ping}" is one sample.
        unsampled_read: bool = false,
        /// This stream has produced progress in its body: keepalives sent before
        /// the first model line (proxies' "processing" comments) say nothing
        /// about how the endpoint behaves mid-stream.
        progress_seen: bool = false,
        /// Set once the monitor shut the request down for inactivity: how long
        /// it had been silent. Read by the transport to name the failure.
        stalled_after_ms: ?u64 = null,
        /// Transport idle at the moment of the stall verdict (see `Stall`).
        stalled_transport_idle_ms: u64 = 0,
        /// Which rule fired and the limit it judged against (see `Stall`).
        stalled_cause: Stall.Cause = .no_progress,
        stalled_limit_ms: u64 = 0,
        stalled_keepalive_gap_ms: u64 = 0,
    };

    /// Monitor wake-up interval; also bounds how late a stall is detected.
    pub const MONITOR_TICK_MS: u64 = 250;

    /// What the monitor recorded when it shut a silent request down: how long
    /// the request had been silent and which limit was in force at the time
    /// (head- or body-phase). The transport names the failure with both.
    pub const Stall = struct {
        pub const Cause = enum {
            /// No model output for `limit_ms` (the head- or body-phase limit).
            no_progress,
            /// No byte at all, keepalives included, for `limit_ms` on an
            /// endpoint that has been seen to send a keepalive at least every
            /// `keepalive_gap_ms` mid-stream: the connection is dead.
            transport_dead,
        };
        /// Silence in *progress* terms (no model-output bytes for this long).
        idle_ms: u64,
        /// The limit of the rule that fired.
        limit_ms: u64,
        /// Silence in transport terms (no bytes at all, keepalives included).
        /// Much smaller than `idle_ms` means the gateway kept the connection
        /// alive while producing nothing; equal means the connection was dead.
        transport_idle_ms: u64,
        cause: Cause = .no_progress,
        /// For `.transport_dead`: the longest mid-stream keepalive interval
        /// the endpoint had shown. 0 otherwise.
        keepalive_gap_ms: u64 = 0,
    };

    /// How the keepalive evidence turns into a transport limit. Fields are
    /// public so tests can shrink the time scale; production uses the defaults.
    pub const KeepaliveTuning = struct {
        /// A keepalive that ends a shorter silence says nothing about the
        /// endpoint's cadence (Anthropic-style APIs send one ping right after
        /// message_start); only longer ones count as samples.
        min_gap_ms: u64 = 2_000,
        /// Samples needed before the transport rule arms.
        min_samples: u32 = 3,
        /// Silence of this many learned intervals = dead.
        multiplier: u64 = 4,
        /// Never judge a connection dead sooner than this.
        floor_ms: u64 = 120_000,
    };

    /// What this endpoint has shown about its mid-stream keepalives. Guarded by
    /// `mutex`. Reset when the transport rule fires, so an endpoint that stops
    /// pinging (a gateway redeploy) is re-learned instead of killed again.
    pub const KeepaliveEvidence = struct {
        samples: u32 = 0,
        /// Longest silence a mid-stream keepalive ended.
        max_gap_ms: u64 = 0,

        /// Transport limit for a body judged by `progress_limit_ms`; 0 = the
        /// rule is not armed (too little evidence, or monitoring is off). Never
        /// at or above the progress limit, which fires first in that case.
        pub fn deadLimitMs(self: KeepaliveEvidence, tuning: KeepaliveTuning, progress_limit_ms: u64) u64 {
            if (progress_limit_ms == 0 or self.samples < tuning.min_samples) return 0;
            const limit = @max(self.max_gap_ms *| tuning.multiplier, tuning.floor_ms);
            return if (limit < progress_limit_ms) limit else 0;
        }
    };

    mutex: sync.Mutex = .{},
    slots: std.ArrayList(Slot) = .empty,
    monitor: ?std.Thread = null,
    monitor_stop: bool = false,
    /// Set by the monitor, under `mutex`, as it returns because no slot was
    /// left to watch (#503): an idle Session keeps no monitor thread and takes
    /// no wake-ups. The next monitored registration joins it and spawns anew.
    monitor_exited: bool = false,
    monitor_cond: sync.Condition = .{},
    keepalive: KeepaliveEvidence = .{},
    keepalive_tuning: KeepaliveTuning = .{},

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

    /// Spawn the monitor thread on a monitored registration when none is
    /// running. Caller holds the mutex. A limit of 0 never needs a monitor.
    fn ensureMonitorLocked(self: *RequestAbortRegistry, idle_limit_ms: u64) void {
        if (idle_limit_ms == 0) return;
        if (self.monitor) |thread| {
            if (!self.monitor_exited) return;
            // The monitor set the flag under this mutex and does nothing after
            // releasing it but return, so this join is short.
            thread.join();
            self.monitor = null;
        }
        self.monitor_stop = false;
        self.monitor_exited = false;
        // Waits on a condition and runs `reapStalled`: a waiter's stack.
        self.monitor = platform_thread.spawn(.waiter, monitorMain, .{self}) catch |err| blk: {
            // No monitor = no liveness guarantee for this process; say so
            // once rather than pretending the limit is enforced.
            log.warn("client", "stream liveness monitor unavailable ({s}); idle limit {d}ms will not be enforced", .{ @errorName(err), idle_limit_ms });
            break :blk null;
        };
    }

    /// Phase switch: the response head has been accepted, so from now on the
    /// request is judged against `limit_ms` (0 = stop monitoring it). The
    /// clock restarts here as well — the head itself was activity. A slot
    /// the monitor has already shut down keeps its verdict. `body` says
    /// whether the transport-dead rule may apply (SSE only).
    pub fn setIdleLimit(self: *RequestAbortRegistry, ctx: *anyopaque, limit_ms: u64, body: BodyKind) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |*active| {
            if (active.ctx != ctx) continue;
            active.idle_limit_ms = limit_ms;
            active.phase = switch (body) {
                .whole => .whole_body,
                .sse => .sse_body,
            };
            const now = monotonicMs();
            active.last_activity_ms = now;
            active.last_transport_ms = now;
            active.unsampled_read = false;
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
                active.progress_seen = true;
                // The read that carried this line ended its silence with
                // progress, not with a keepalive.
                active.unsampled_read = false;
                return;
            }
        }
    }

    /// Bytes of any kind arrived for `ctx` (called per transport read by
    /// `LivenessReader` in transport-only mode). Does **not** restart the idle
    /// clock: a keepalive proves the gateway is up, not that the model is
    /// producing. The stall report and the transport-dead rule read this stamp.
    pub fn touchTransport(self: *RequestAbortRegistry, ctx: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |*active| {
            if (active.ctx == ctx) {
                const now = monotonicMs();
                active.last_transport_gap_ms = now -| active.last_transport_ms;
                active.last_transport_ms = now;
                active.unsampled_read = true;
                return;
            }
        }
    }

    /// A keepalive line (ping or SSE comment, never a blank separator) was
    /// parsed for `ctx`. Restarts no clock; it is evidence about the endpoint:
    /// when it arrives mid-stream in an SSE body after a real silence, the
    /// silence it ended is one sample of how long this endpoint stays quiet
    /// before it speaks up.
    pub fn touchKeepalive(self: *RequestAbortRegistry, ctx: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.slots.items) |*active| {
            if (active.ctx != ctx) continue;
            if (active.phase != .sse_body or !active.progress_seen or !active.unsampled_read) return;
            active.unsampled_read = false;
            if (active.last_transport_gap_ms < self.keepalive_tuning.min_gap_ms) return;
            self.keepalive.samples +|= 1;
            self.keepalive.max_gap_ms = @max(self.keepalive.max_gap_ms, active.last_transport_gap_ms);
            return;
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
            const transport_idle = now_ms -| active.last_transport_ms;
            const dead_limit: u64 = if (active.phase == .sse_body)
                self.keepalive.deadLimitMs(self.keepalive_tuning, active.idle_limit_ms)
            else
                0;
            if (idle >= active.idle_limit_ms) {
                active.stalled_cause = .no_progress;
                active.stalled_limit_ms = active.idle_limit_ms;
                active.stalled_keepalive_gap_ms = 0;
            } else if (dead_limit > 0 and transport_idle >= dead_limit) {
                active.stalled_cause = .transport_dead;
                active.stalled_limit_ms = dead_limit;
                active.stalled_keepalive_gap_ms = self.keepalive.max_gap_ms;
                // The verdict spends the evidence: the retry starts unarmed, so
                // an endpoint that has stopped pinging is judged by the progress
                // limit until it shows keepalives again.
                self.keepalive = .{};
            } else continue;
            active.stalled_after_ms = idle;
            active.stalled_transport_idle_ms = transport_idle;
            log.warn("client", "stream {s} for {d}ms (limit {d}ms, last transport byte {d}ms ago): shutting down the connection so the blocked read returns", .{
                if (active.stalled_cause == .transport_dead) "dead (no byte, keepalives included)" else "idle",
                idle,
                active.stalled_limit_ms,
                transport_idle,
            });
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
            return .{
                .idle_ms = idle,
                .limit_ms = active.stalled_limit_ms,
                .transport_idle_ms = active.stalled_transport_idle_ms,
                .cause = active.stalled_cause,
                .keepalive_gap_ms = active.stalled_keepalive_gap_ms,
            };
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
            if (!self.watchingLocked()) {
                self.monitor_exited = true;
                return;
            }
        }
    }

    /// Whether a slot can still stall: monitored and not shut down yet.
    fn watchingLocked(self: *const RequestAbortRegistry) bool {
        for (self.slots.items) |active| {
            if (active.idle_limit_ms != 0 and active.stalled_after_ms == null) return true;
        }
        return false;
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
    /// Image input for `model` together with who said so (issue #273): the
    /// Host, the provider catalog, the family table, or nobody. Optional; a
    /// provider without it answers through `supportsForModel` with the
    /// source `model_family` for yes and `unknown` for no - it never claims
    /// a model is known not to take images.
    imageInputFn: ?*const fn (ctx: *anyopaque, model: []const u8) image_capability.Resolution = null,
    /// 本路由目录里声明能收图的模型名(借用 provider 内存;调用方只释放外层 slice)。
    /// 可选:没有目录的 provider 不实现,调用方视为"不知道",不编造候选。
    visionModelsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const []const u8 = null,
    /// Last transport identifiers, available even when a request failed before
    /// a StreamHandle could be returned (used by the Metask ledger).
    requestIdTextFn: ?*const fn (ctx: *anyopaque) []const u8 = null,
    serverRequestIdFn: ?*const fn (ctx: *anyopaque) []const u8 = null,
    httpStatusFn: ?*const fn (ctx: *anyopaque) u16 = null,
    retryAttemptFn: ?*const fn (ctx: *anyopaque) u32 = null,
    /// Numbers from the last head-phase context-window-exceeded response body
    /// (best effort; empty when the provider or the message carries none).
    lastContextWindowNumbersFn: ?*const fn (ctx: *anyopaque) error_class.ContextWindowNumbers = null,
    /// Stable identity of the endpoint requests go to (base URL). Learned
    /// context caps are keyed by it together with the model: the same model
    /// behind two gateways is two different walls.
    endpointIdFn: ?*const fn (ctx: *anyopaque) []const u8 = null,
    /// The route to this provider's model (see `ProviderRoute`). Null for a
    /// provider that has no delegable route (synthetic, test, or sealed).
    routeFn: ?*const fn (ctx: *anyopaque) ?ProviderRoute = null,

    // ── 便利转发 ──────────────────────────────────────────────────────────
    pub inline fn route(self: Provider) ?ProviderRoute {
        const f = self.routeFn orelse return null;
        return f(self.ctx);
    }
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
    /// Image input for the model a request will name, with its source. The
    /// AgentCore preflight uses this to tell "known not to take images" from
    /// "nothing says it does".
    pub fn imageInput(self: Provider, model_override: ?[]const u8) image_capability.Resolution {
        const name = model_override orelse self.model();
        if (self.imageInputFn) |resolve| return resolve(self.ctx, name);
        const supported = self.supportsForModel(.image_input, model_override);
        return .{ .supported = supported, .source = if (supported) .model_family else .unknown };
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
    pub inline fn lastContextWindowNumbers(self: Provider) error_class.ContextWindowNumbers {
        const f = self.lastContextWindowNumbersFn orelse return .{};
        return f(self.ctx);
    }
    pub inline fn endpointId(self: Provider) []const u8 {
        const f = self.endpointIdFn orelse return "";
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
    registry.setIdleLimit(@ptrCast(&probe), 5_000, .whole);
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
    registry.setIdleLimit(@ptrCast(&quiet), 0, .whole);
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
    registry.setIdleLimit(@ptrCast(&probe), 50, .whole);
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

fn monitorExited(registry: *RequestAbortRegistry) bool {
    registry.mutex.lock();
    defer registry.mutex.unlock();
    return registry.monitor_exited;
}

fn waitMonitorExited(registry: *RequestAbortRegistry) bool {
    var waited_ms: u64 = 0;
    while (!monitorExited(registry) and waited_ms < 5_000) : (waited_ms += 20) {
        @import("../util/time.zig").sleepMs(20);
    }
    return monitorExited(registry);
}

test "RequestAbortRegistry: the monitor exits once nothing is watched and the next monitored request brings it back (#503)" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var first = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&first), LivenessProbe.shutdown, 60_000);
    try std.testing.expect(registry.monitor != null);
    // A watched slot keeps the monitor running across ticks.
    @import("../util/time.zig").sleepMs(3 * RequestAbortRegistry.MONITOR_TICK_MS);
    try std.testing.expect(!monitorExited(&registry));
    // The request ends: within a tick the monitor is gone, as it is for a
    // Session idling between Runs.
    registry.unregister(@ptrCast(&first));
    try std.testing.expect(waitMonitorExited(&registry));
    // The next monitored request gets a monitor again, and it still reaps.
    var second = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&second), LivenessProbe.shutdown, 50);
    defer registry.unregister(@ptrCast(&second));
    try std.testing.expect(!monitorExited(&registry));
    var waited_ms: u64 = 0;
    while (second.shutdowns.load(.acquire) == 0 and waited_ms < 5_000) : (waited_ms += 20) {
        @import("../util/time.zig").sleepMs(20);
    }
    try std.testing.expectEqual(@as(u32, 1), second.shutdowns.load(.acquire));
    try std.testing.expect(registry.stalledIdleMs(@ptrCast(&second)).? >= 50);
    // Its only slot is shut down, so nothing is left to watch: it exits again.
    try std.testing.expect(waitMonitorExited(&registry));
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

/// Test helper: a transport read arrives `gap_ms` after the previous byte and
/// carries one keepalive line. Back-dates the stamp instead of sleeping.
fn keepaliveAfter(registry: *RequestAbortRegistry, ctx: *anyopaque, gap_ms: u64) void {
    registry.mutex.lock();
    for (registry.slots.items) |*active| {
        if (active.ctx == ctx) active.last_transport_ms = monotonicMs() -| gap_ms;
    }
    registry.mutex.unlock();
    registry.touchTransport(ctx);
    registry.touchKeepalive(ctx);
}

test "RequestAbortRegistry: only a mid-stream SSE keepalive that ends a real silence is evidence, once per read" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&probe), LivenessProbe.shutdown, 60_000);
    defer registry.unregister(@ptrCast(&probe));

    // Head phase: there is no body yet, nothing to learn.
    keepaliveAfter(&registry, @ptrCast(&probe), 3_000);
    try std.testing.expectEqual(@as(u32, 0), registry.keepalive.samples);
    registry.setIdleLimit(@ptrCast(&probe), 1_800_000, .sse);
    // Before the first model line: a proxy's "processing" comment, not mid-stream behaviour.
    keepaliveAfter(&registry, @ptrCast(&probe), 3_000);
    try std.testing.expectEqual(@as(u32, 0), registry.keepalive.samples);
    registry.touch(@ptrCast(&probe));
    // A ping that ends a short silence (Anthropic's ping right after message_start) says nothing.
    keepaliveAfter(&registry, @ptrCast(&probe), 500);
    try std.testing.expectEqual(@as(u32, 0), registry.keepalive.samples);
    // A ping after a real silence is one sample, and records how long that silence was.
    keepaliveAfter(&registry, @ptrCast(&probe), 3_000);
    try std.testing.expectEqual(@as(u32, 1), registry.keepalive.samples);
    try std.testing.expect(registry.keepalive.max_gap_ms >= 3_000);
    // "event: ping" + "data: {ping}" arrive in one read: the second line is not a second sample.
    registry.touchKeepalive(@ptrCast(&probe));
    try std.testing.expectEqual(@as(u32, 1), registry.keepalive.samples);
    // A read whose silence was ended by progress does not become a sample through a
    // keepalive parsed after it.
    registry.mutex.lock();
    registry.slots.items[0].last_transport_ms = monotonicMs() -| 5_000;
    registry.mutex.unlock();
    registry.touchTransport(@ptrCast(&probe));
    registry.touch(@ptrCast(&probe));
    registry.touchKeepalive(@ptrCast(&probe));
    try std.testing.expectEqual(@as(u32, 1), registry.keepalive.samples);

    // A whole (non-SSE) body is never evidence, whatever arrives.
    var whole = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&whole), LivenessProbe.shutdown, 60_000);
    defer registry.unregister(@ptrCast(&whole));
    registry.setIdleLimit(@ptrCast(&whole), 1_800_000, .whole);
    registry.touch(@ptrCast(&whole));
    keepaliveAfter(&registry, @ptrCast(&whole), 3_000);
    try std.testing.expectEqual(@as(u32, 1), registry.keepalive.samples);
}

test "KeepaliveEvidence.deadLimitMs: arms after min_samples, multiplier over a floor, never at or above the progress limit" {
    const tuning = RequestAbortRegistry.KeepaliveTuning{};
    const E = RequestAbortRegistry.KeepaliveEvidence;
    // Too little evidence: unarmed.
    try std.testing.expectEqual(@as(u64, 0), (E{ .samples = 2, .max_gap_ms = 15_000 }).deadLimitMs(tuning, 1_800_000));
    // napi's 15 s cadence: 4 × 15 s = 60 s, raised to the 2-minute floor.
    try std.testing.expectEqual(@as(u64, 120_000), (E{ .samples = 3, .max_gap_ms = 15_000 }).deadLimitMs(tuning, 1_800_000));
    // A slower pinger gets proportionally more room.
    try std.testing.expectEqual(@as(u64, 240_000), (E{ .samples = 3, .max_gap_ms = 60_000 }).deadLimitMs(tuning, 1_800_000));
    // At or above the progress limit the rule is redundant: off.
    try std.testing.expectEqual(@as(u64, 0), (E{ .samples = 3, .max_gap_ms = 15_000 }).deadLimitMs(tuning, 120_000));
    // Body monitoring off (METACODES_STREAM_BODY_IDLE_TIMEOUT_MS=0) turns this off too.
    try std.testing.expectEqual(@as(u64, 0), (E{ .samples = 9, .max_gap_ms = 15_000 }).deadLimitMs(tuning, 0));
}

test "RequestAbortRegistry: an armed endpoint's silent SSE body is judged dead at the learned limit, and the verdict spends the evidence" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    registry.keepalive = .{ .samples = 3, .max_gap_ms = 15_000 };
    var sse = LivenessProbe{};
    var whole = LivenessProbe{};
    // The whole body is registered first so the reaper reaches it while the evidence is
    // still armed: after the SSE verdict spends it, nothing would be judged by transport.
    try registry.registerMonitored(a, null, @ptrCast(&whole), LivenessProbe.shutdown, 60_000);
    defer registry.unregister(@ptrCast(&whole));
    try registry.registerMonitored(a, null, @ptrCast(&sse), LivenessProbe.shutdown, 60_000);
    defer registry.unregister(@ptrCast(&sse));
    registry.setIdleLimit(@ptrCast(&sse), 1_800_000, .sse);
    registry.setIdleLimit(@ptrCast(&whole), 1_800_000, .whole);
    registry.mutex.lock();
    const base = registry.slots.items[0].last_transport_ms;
    for (registry.slots.items) |*active| {
        active.last_activity_ms = base;
        active.last_transport_ms = base;
    }
    registry.mutex.unlock();

    try std.testing.expectEqual(@as(usize, 0), registry.reapStalled(base + 119_999));
    // Two minutes without a byte: the SSE body is dead; the whole body is not judged by this rule.
    try std.testing.expectEqual(@as(usize, 1), registry.reapStalled(base + 120_000));
    const verdict = registry.stalled(@ptrCast(&sse)) orelse return error.TestExpectedStall;
    try std.testing.expectEqual(RequestAbortRegistry.Stall.Cause.transport_dead, verdict.cause);
    try std.testing.expectEqual(@as(u64, 120_000), verdict.limit_ms);
    try std.testing.expectEqual(@as(u64, 120_000), verdict.transport_idle_ms);
    try std.testing.expectEqual(@as(u64, 15_000), verdict.keepalive_gap_ms);
    try std.testing.expectEqual(@as(u32, 1), sse.shutdowns.load(.acquire));
    try std.testing.expect(registry.stalled(@ptrCast(&whole)) == null);
    try std.testing.expectEqual(@as(u32, 0), whole.shutdowns.load(.acquire));
    // Spent: the next request is judged by the progress limit until the endpoint pings again.
    try std.testing.expectEqual(@as(u32, 0), registry.keepalive.samples);
    try std.testing.expectEqual(@as(u64, 0), registry.keepalive.max_gap_ms);
    // The whole body still stalls on the progress limit as before.
    try std.testing.expectEqual(@as(usize, 1), registry.reapStalled(base + 1_800_000));
    try std.testing.expectEqual(RequestAbortRegistry.Stall.Cause.no_progress, (registry.stalled(@ptrCast(&whole)) orelse return error.TestExpectedStall).cause);
}

test "RequestAbortRegistry: an armed endpoint whose keepalives keep arriving is judged by progress only, and an unarmed one never by transport" {
    const a = std.testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    registry.keepalive = .{ .samples = 3, .max_gap_ms = 15_000 };
    var probe = LivenessProbe{};
    try registry.registerMonitored(a, null, @ptrCast(&probe), LivenessProbe.shutdown, 60_000);
    defer registry.unregister(@ptrCast(&probe));
    registry.setIdleLimit(@ptrCast(&probe), 1_800_000, .sse);
    registry.mutex.lock();
    const base = registry.slots.items[0].last_transport_ms;
    registry.slots.items[0].last_activity_ms = base;
    // Pings every 15 s for the whole half hour: the transport is alive.
    registry.slots.items[0].last_transport_ms = base + 1_785_000;
    registry.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), registry.reapStalled(base + 1_799_999));
    try std.testing.expectEqual(@as(usize, 1), registry.reapStalled(base + 1_800_000));
    const verdict = registry.stalled(@ptrCast(&probe)) orelse return error.TestExpectedStall;
    try std.testing.expectEqual(RequestAbortRegistry.Stall.Cause.no_progress, verdict.cause);
    try std.testing.expectEqual(@as(u64, 1_800_000), verdict.limit_ms);
    // A progress verdict does not spend the keepalive evidence.
    try std.testing.expectEqual(@as(u32, 3), registry.keepalive.samples);

    // Unarmed (an endpoint that never pinged mid-stream): total silence waits for the progress limit.
    var quiet_registry = RequestAbortRegistry{};
    defer quiet_registry.deinit(a);
    var quiet = LivenessProbe{};
    try quiet_registry.registerMonitored(a, null, @ptrCast(&quiet), LivenessProbe.shutdown, 60_000);
    defer quiet_registry.unregister(@ptrCast(&quiet));
    quiet_registry.setIdleLimit(@ptrCast(&quiet), 1_800_000, .sse);
    quiet_registry.mutex.lock();
    const quiet_base = quiet_registry.slots.items[0].last_transport_ms;
    quiet_registry.slots.items[0].last_activity_ms = quiet_base;
    quiet_registry.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), quiet_registry.reapStalled(quiet_base + 1_799_999));
    try std.testing.expectEqual(@as(usize, 1), quiet_registry.reapStalled(quiet_base + 1_800_000));
    try std.testing.expectEqual(RequestAbortRegistry.Stall.Cause.no_progress, (quiet_registry.stalled(@ptrCast(&quiet)) orelse return error.TestExpectedStall).cause);
}
