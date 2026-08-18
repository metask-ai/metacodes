//! 工具批量执行(批1:对齐 cc 的 isConcurrencySafe + 分批并发)。
//!
//! agent_loop 把本轮 tool_use 列表 + 已算好的权限结果交给这里。本模块:
//!   - 把"已放行"的 tool_use 按 isConcurrencySafe 分批(连续 safe 并一批,unsafe 单独);
//!   - safe 批:每个 tool 独立线程 + 独立 arena 跑 dispatch,结果按**原 index 回填**;
//!   - unsafe 批:主线程串行;
//!   - 保证 result_blocks 严格按原 tool_use 顺序(tool_result 顺序不能乱)。
//!
//! 权限检查(走 fd0 prompt)必须在调用方主线程串行做好——本模块只执行已决定的。
//! 共享态:read_state 已加锁(Read 安全);其余 safe 工具(Glob/Grep/WebFetch/BashOutput)
//! 不写共享态。每个并发 job 用独立 ArenaAllocator；这些 arena 的后备分配和逃逸结果
//! 都经 LockedAllocator 串行访问父 allocator（生产父 allocator 是 session arena，本身不线程安全）。

const std = @import("std");
const platform = @import("platform");
const tools_mod = @import("../tools.zig");
const ToolContext = tools_mod.ToolContext;
const tool_observation = @import("../tools/observation.zig");
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");
const pfs = platform.fs;
const project_gate_protocol = @import("../tools/project_rule_gate.zig");
const project_rule_signal = @import("../tools/project_rule_signal.zig");
const file_reference = @import("file_reference.zig");
const tool_catalog = @import("tool_catalog.zig");

/// 给任意 allocator 加互斥视图。ArenaAllocator 只隔离自己的链表元数据，它增长时仍会
/// 调后备 allocator；多个 worker 直接以同一个 session arena 为后备会破坏 arena 状态。
/// 该包装只活在一次并发 batch 内，所有 worker join 后才销毁，因此 ptr 生命周期稳定。
const LockedAllocator = struct {
    child: std.mem.Allocator,
    mutex: platform.sync.Mutex = .{},

    fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn cast(ctx: *anyopaque) *LockedAllocator {
        return @ptrCast(@alignCast(ctx));
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = cast(ctx);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = cast(ctx);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = cast(ctx);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = cast(ctx);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

pub const MAX_TOOL_CONCURRENCY: usize = 8;
pub const MAX_TOOL_ERROR_PAYLOAD_BYTES_V1: usize = 1024 * 1024;

/// 单个 tool 的执行决定 + 结果槽位。
pub const Slot = struct {
    /// 权限决定:.run=执行,.denied=已被拒(content 已填错误 json,owned)。
    decision: enum { run, denied },
    name: []const u8, // borrowed(指向 conversation 的 tool_use)
    id: []const u8, // borrowed
    input: []const u8, // borrowed
    /// 执行后填:成功内容 或 错误内容(均 owned by caller allocator)。
    content: ?[]u8 = null,
    is_error: bool = false,
    /// 执行耗时(ms),runJob 填。供 tool_card 显示真实耗时(0 = 未执行/被拒)。
    elapsed_ms: u64 = 0,
    /// L3 挂起:工具返 error.UiPending(异步 custom UI 未完成)→ runJob 置此并填 pending_kind/
    /// payload(从 ctx.pending_request 取,dupe 到父 allocator 逃逸)。content 留 null(无结果)。
    /// agent_loop 扫到 pending → emit ui_request_pending + 整轮挂起(stop_reason=.suspended)。
    pending: bool = false,
    pending_kind: ?[]u8 = null,
    pending_payload: ?[]u8 = null,
    /// Successful built-in file references owned by the parent allocator.
    file_refs: ?[]file_reference.FileReference = null,
    /// P0.4:该 slot 的结果已由流式预取(stream_prefetch)填好 → executeSlots 跳过,不重复执行。
    prefetched: bool = false,
    /// Typed effect copied from the real dispatch observation. It is consumed
    /// by run-local observers only; it is never model-visible.
    effect: ?tool_observation.Effect = null,
    effect_valid: bool = true,

    /// 释放全部 slot-owned payload(content/pending_kind/pending_payload)并置 null。
    /// agent_loop 用单个 defer 遍历调用,覆盖**所有**退出路径(正常/挂起/fatal/错误);
    /// 已转移 ownership 的字段(takeContent 置 null)天然跳过。
    pub fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        self.content = null;
        if (self.pending_kind) |k| allocator.free(k);
        self.pending_kind = null;
        if (self.pending_payload) |p| allocator.free(p);
        self.pending_payload = null;
        if (self.file_refs) |refs| {
            for (refs) |*ref| ref.deinit(allocator);
            allocator.free(refs);
        }
        self.file_refs = null;
    }

    /// 转移 content ownership 给调用方并置 null——转移即置空,杜绝与 deinit 双释放。
    pub fn takeContent(self: *Slot) ?[]u8 {
        const c = self.content;
        self.content = null;
        return c;
    }
};

/// 一个并发 job 的输入(safe 批用)。
const Job = struct {
    slot: *Slot,
    ctx: *const ToolContext, // 共享(只读字段 + 线程安全的 read_state)
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
    done: bool = false,
    /// Host 工具 fatal:runJob 置位,executeSlots join 后汇聚为 error.HostToolFatal。
    fatal: bool = false,
    /// 本地复制/编码 OOM 是 Run 级失败，不得伪装成模型可见 tool error。
    out_of_memory: bool = false,
};

/// 单个工具执行的结果(所有 owned 字段挂 parent_allocator,逃逸内部 arena)。
pub const OneResult = union(enum) {
    /// 正常完成(成功或工具级错误)。
    done: struct {
        content: ?[]u8,
        is_error: bool,
        elapsed_ms: u64,
        file_refs: ?[]file_reference.FileReference = null,
        effect: ?tool_observation.Effect = null,
        effect_valid: bool = true,
    },
    /// L3 挂起:工具发起 custom UI(error.UiPending)。kind/payload owned by parent_allocator。
    pending: struct { kind: ?[]u8, payload: ?[]u8, elapsed_ms: u64 },
    /// Host 工具 fatal:类型化控制信号,无 payload——不组装 tool_result,逐层显式传递
    /// 至 agent loop 映射为 error.HostToolFatal(→ poisonRun)。
    host_fatal,
};

fn emitDispatchStarted(
    ctx: *const ToolContext,
    id: []const u8,
    requested_name: []const u8,
    dispatched_name: []const u8,
    input: []const u8,
    file_target_state: tool_observation.FileTargetState,
    within_root: bool,
) bool {
    const sink = ctx.tool_observer orelse return true;
    return sink.emit(.{ .dispatch_started = .{
        .id = id,
        .requested_name = requested_name,
        .dispatched_name = dispatched_name,
        .origin = ctx.tool_observation_origin,
        .agent_depth = ctx.agent_depth,
        .input_bytes = input.len,
        .input_sha256 = tool_observation.sha256Hex(input),
        .file_target_state = file_target_state,
        .within_root = within_root,
    } });
}

fn emitDispatchFinished(
    ctx: *const ToolContext,
    id: []const u8,
    requested_name: []const u8,
    dispatched_name: []const u8,
    outcome: tool_observation.Outcome,
    error_code: ?[]const u8,
    elapsed_ms: u64,
    result: ?[]const u8,
    effect_slot: tool_observation.EffectSlot,
) bool {
    const sink = ctx.tool_observer orelse return true;
    return sink.emit(.{ .dispatch_finished = .{
        .id = id,
        .requested_name = requested_name,
        .dispatched_name = dispatched_name,
        .origin = ctx.tool_observation_origin,
        .agent_depth = ctx.agent_depth,
        .outcome = outcome,
        .error_code = error_code,
        .elapsed_ms = elapsed_ms,
        .result_present = result != null,
        .result_bytes = if (result) |bytes| bytes.len else 0,
        .result_sha256 = if (result) |bytes|
            tool_observation.sha256Hex(bytes)
        else
            [_]u8{'0'} ** 64,
        .effect = effect_slot.effect,
        .effect_valid = effect_slot.valid,
    } });
}

/// Keeps the actual-dispatch observation pair structurally closed. Explicit
/// terminal outcomes still carry the useful code/result; the defer is a final
/// defense against a future early-return branch silently losing its finish.
const DispatchObservation = struct {
    ctx: *const ToolContext,
    id: []const u8,
    requested_name: []const u8,
    dispatched_name: []const u8,
    started_at_ms: i64,
    effect_slot: *tool_observation.EffectSlot,
    started: bool = false,
    terminal_attempted: bool = false,
    input_bytes: usize = 0,
    file_target_state: @import("project_rule_spec.zig").FileTargetState = .unobserved,
    // 与 file_target_state 同源(分类器判定)。事件 struct 的 within_root 带
    // 默认 true——发射时不显式传值 = journal 恒记 true(2026-08-17 复审:两次
    // /tmp 根外拦截被记成 within_root=true,内核判对了但审计字段说谎)。
    within_root: bool = true,
    project_pre_signal: ?project_gate_protocol.PreSignal = null,

    fn start(self: *DispatchObservation, input: []const u8) bool {
        if (!emitDispatchStarted(
            self.ctx,
            self.id,
            self.requested_name,
            self.dispatched_name,
            input,
            self.file_target_state,
            self.within_root,
        )) return false;
        self.input_bytes = input.len;
        self.started = true;
        return true;
    }

    fn finish(
        self: *DispatchObservation,
        outcome: tool_observation.Outcome,
        error_code: ?[]const u8,
        result: ?[]const u8,
    ) bool {
        // This protocol protects production evidence, so duplicate/unstarted
        // terminal attempts must fail closed in Release builds too; a Debug
        // assertion alone would compile the guard away.
        if (!self.started or self.terminal_attempted) return false;
        self.terminal_attempted = true;
        reobserveFileEffect(self.effect_slot);
        const elapsed: u64 = @intCast(@max(util_time.nowMs() - self.started_at_ms, 0));
        const formal = if (self.ctx.project_rule_gate) |gate| gate.post(.{
            .pre = self.project_pre_signal orelse return false,
            .outcome = outcome,
            .effect = self.effect_slot.effect,
            .effect_valid = self.effect_slot.valid,
        }) else project_gate_protocol.Result.admit;
        // Formal admission precedes terminal acceptance, but the already-real
        // outcome must still be durably recorded even when the gate blocks or
        // faults.  This ordering prevents an observation sink from treating a
        // side effect as accepted before the fixed kernel has judged it while
        // preserving the evidence needed for recovery and a future candidate.
        const observed = emitDispatchFinished(
            self.ctx,
            self.id,
            self.requested_name,
            self.dispatched_name,
            outcome,
            error_code,
            elapsed,
            result,
            self.effect_slot.*,
        );
        return observed and formal == .admit;
    }

    fn ensureTerminal(self: *DispatchObservation) void {
        if (!self.started or self.terminal_attempted) return;
        _ = self.finish(.host_fatal, "DispatchObservationUnwound", null);
    }
};

fn reobserveFileEffect(slot: *tool_observation.EffectSlot) void {
    const effect = slot.effect orelse return;
    const mutation = switch (effect) {
        .file_mutation_v1 => |value| value,
        .file_mutation_v2 => return,
    };
    const unavailable = tool_observation.FileReobservationV1{
        .state = .unavailable,
        .observed_sha256 = [_]u8{'0'} ** 64,
        .observed_bytes = 0,
    };
    const path = slot.filePath() orelse {
        slot.effect = .{ .file_mutation_v2 = .{
            .mutation = mutation,
            .reobservation = unavailable,
        } };
        return;
    };
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) {
        slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
        return;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) {
        slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
        return;
    }
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch {
        slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
        return;
    };
    if (!before.is_regular or before.size > std.math.maxInt(usize)) {
        slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
        return;
    }
    const observed_bytes: usize = @intCast(before.size);
    if (observed_bytes != mutation.after_bytes) {
        slot.effect = .{ .file_mutation_v2 = .{
            .mutation = mutation,
            .reobservation = .{
                .state = .mismatched,
                .observed_sha256 = [_]u8{'0'} ** 64,
                .observed_bytes = observed_bytes,
            },
        } };
        return;
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const count = pfs.read(fd, &buffer);
        if (count < 0) {
            slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
            return;
        }
        if (count == 0) break;
        const n: usize = @intCast(count);
        total += n;
        if (total > observed_bytes) {
            slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
            return;
        }
        hasher.update(buffer[0..n]);
    }
    const after = pfs.fileInfo(fd) catch {
        slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
        return;
    };
    if (!after.is_regular or after.size != before.size or total != observed_bytes) {
        slot.effect = .{ .file_mutation_v2 = .{ .mutation = mutation, .reobservation = unavailable } };
        return;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const observed_sha256 = std.fmt.bytesToHex(digest, .lower);
    slot.effect = .{ .file_mutation_v2 = .{
        .mutation = mutation,
        .reobservation = .{
            .state = if (std.mem.eql(u8, &observed_sha256, &mutation.after_sha256)) .matched else .mismatched,
            .observed_sha256 = observed_sha256,
            .observed_bytes = observed_bytes,
        },
    } };
}

const ObservationCapture = struct {
    mutex: platform.sync.Mutex = .{},
    starts: usize = 0,
    finishes: usize = 0,
    depth: u8 = 0,
    origin: tool_observation.Origin = .authoritative,
    outcome: tool_observation.Outcome = .tool_error,
    effect: ?tool_observation.Effect = null,
    effect_valid: bool = false,
    accept_start: bool = true,
    accept_finish: bool = true,
    saw_name_repair: bool = false,
    dispatched_as_write: bool = false,

    fn sink(self: *ObservationCapture) tools_mod.ToolObservationSink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }

    fn emit(raw: *anyopaque, event: tool_observation.Event) bool {
        const self: *ObservationCapture = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (event) {
            .rule_filter, .rule_coverage_gap, .rule_bounds_overflow, .verification_final_gate, .requirement_ledger, .test_weakening_candidate, .formal_decision, .formal_decision_batch => return true,
            .dispatch_started => |started| {
                self.starts += 1;
                self.depth = started.agent_depth;
                self.origin = started.origin;
                self.saw_name_repair = !std.mem.eql(u8, started.requested_name, started.dispatched_name);
                self.dispatched_as_write = std.mem.eql(u8, started.dispatched_name, "Write");
                return self.accept_start;
            },
            .dispatch_finished => |finished| {
                self.finishes += 1;
                self.depth = finished.agent_depth;
                self.origin = finished.origin;
                self.outcome = finished.outcome;
                self.effect = finished.effect;
                self.effect_valid = finished.effect_valid;
                return self.accept_finish;
            },
        }
    }
};

/// **单一工具执行入口**——executeSlots(串行/并发批)与 stream_prefetch(边流边执行)共用,
/// 保证两条路径的执行语义/错误处理**完全一致**(消除历史"行为分叉":富错误 detail、UnknownTool
/// 引导、大结果落盘、UiPending 控制信号、计时)。每次自建 arena 规避 GPA 并发;结果 dupe 逃逸。
/// id 用于 progress 路由(progress_tool_id);rid 用于日志。
pub fn executeOne(
    base_ctx: *const ToolContext,
    name: []const u8,
    input: []const u8,
    id: []const u8,
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
) error{OutOfMemory}!OneResult {
    const t_start = util_time.nowMs();
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    var job_ctx = base_ctx.*;
    job_ctx.allocator = arena.allocator();
    // per-toolUse 进度路由:盖上本 tool_use id,reportProgress 据此找对应卡。
    job_ctx.progress_tool_id = id;
    // 富错误 detail 槽:工具可在抛错前写入,替代通用 "X failed with Y"。
    var err_detail: ?[]const u8 = null;
    job_ctx.error_detail = &err_detail;
    // L3 挂起槽:工具发起 custom UI 拿到 .pending → 写 {kind,payload} 进这里 + 返 error.UiPending。
    var pending_req: ?tools_mod.PendingRequest = null;
    job_ctx.pending_request = &pending_req;
    var effect_slot = tool_observation.EffectSlot{};
    job_ctx.effect_slot = &effect_slot;
    // Built-in/dynamic dispatch performs deterministic name normalization;
    // host Session dispatch deliberately receives the exact advertised name.
    // Preserve both so evidence never attributes a repaired call to the model.
    var dispatched_name = if (job_ctx.tool_dispatcher != null)
        name
    else
        tools_mod.resolveToolNameExact(&job_ctx, name) orelse name;
    var dispatch_input = input;
    var dispatch_observation = DispatchObservation{
        .ctx = &job_ctx,
        .id = id,
        .requested_name = name,
        .dispatched_name = dispatched_name,
        .started_at_ms = t_start,
        .effect_slot = &effect_slot,
    };
    const builtin_file_tool = isBuiltinFileTool(&job_ctx, dispatched_name);

    log.infoId("agent", rid, "tool.exec start(par) name={s} id={s}", .{ name, id });
    if (job_ctx.execution_policy) |policy| {
        if (!policy.allowsInvocation(name, input)) {
            const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
            const denied = @import("tool_error.zig").errorToJson(
                "ToolPolicyDenied",
                "Tool '{s}' is outside the current execution policy",
                .{name},
                parent_allocator,
            ) catch return error.OutOfMemory;
            log.warnId(
                "agent",
                rid,
                "tool.exec POLICY-DENIED name={s} duration_ms={d}",
                .{ name, elapsed },
            );
            return .{ .done = .{
                .content = denied,
                .is_error = true,
                .elapsed_ms = elapsed,
            } };
        }
    }
    // Auto source-CAS lowering must not turn a malformed model-authored Write
    // into a well-typed host-authored Edit.  The ordinary dispatcher performs
    // these same checks, but lowering happens before it.  Validate every
    // native built-in Write at this boundary so signal-only and governed Runs
    // retain identical schema-first semantics. An embedding Session owns its
    // advertised schema. No formal obligation or dispatch-start evidence is
    // emitted for an input that never reached a valid dispatcher invocation.
    if (job_ctx.tool_dispatcher == null and
        std.mem.eql(u8, dispatched_name, "Write"))
    {
        tools_mod.validateRequired("Write", input) catch |err|
            return invalidNativeWriteArgsResult(
                name,
                err,
                parent_allocator,
                t_start,
                rid,
            );
        tools_mod.validateTypes("Write", input) catch |err|
            return invalidNativeWriteArgsResult(
                name,
                err,
                parent_allocator,
                t_start,
                rid,
            );
    }
    // Formal rule/observer runs use the complete pre-dispatch sensor. Ordinary
    // AgentCore file-reference runs use only the bounded target-state sensor;
    // neither path is enabled or disabled by the other path's policy switch.
    var project_pre_signal: ?project_gate_protocol.PreSignal = null;
    if (job_ctx.project_rule_gate != null or job_ctx.tool_observer != null) {
        project_pre_signal = project_rule_signal.observePre(
            &job_ctx,
            id,
            dispatched_name,
            input,
        );
        dispatch_observation.file_target_state = project_pre_signal.?.file_target_state;
        dispatch_observation.within_root = project_pre_signal.?.within_root;
        dispatch_observation.project_pre_signal = project_pre_signal.?;
    } else if (builtin_file_tool) {
        // File references need only the bounded lstat-style target state. Do
        // not pull the project-rule exact-edit material sensor into ordinary
        // AgentCore Runs: it reads and hashes full files and may block on a
        // FIFO. The complete observePre path remains reserved for formal
        // rules or an explicitly installed observation sink.
        const lite_target = project_rule_signal.observeFileTarget(
            &job_ctx,
            dispatched_name,
            input,
        );
        dispatch_observation.file_target_state = lite_target.state;
        dispatch_observation.within_root = lite_target.within_root;
    }
    if (job_ctx.project_rule_gate) |gate| {
        switch (gate.pre(project_pre_signal.?)) {
            .admit => {
                if (std.mem.eql(u8, dispatched_name, "Write") and
                    project_pre_signal.?.file_target_state == .missing)
                    job_ctx.project_write_exclusive_create = true;
            },
            .admit_exact_edit => {
                // This tag is an authority-bearing native execution mode,
                // not a generic "yes".  A buggy/malicious gate must not use
                // it to reroute another tool through Edit.
                if (!std.mem.eql(u8, dispatched_name, "Edit")) {
                    _ = gate.cancelPre(project_pre_signal.?);
                    log.warnId("agent", rid, "project formal gate returned exact-edit admission for non-Edit name={s} id={s}", .{ name, id });
                    return .host_fatal;
                }
                job_ctx.project_edit_mode = .whole_file_exact;
            },
            .synthesize_exact_edit => {
                // The first Lean decision selected a bounded repair for this
                // exact Write.  Construct the corresponding Edit from real
                // source bytes plus the original proposal, then require a
                // second Lean admission before exposing any dispatch event.
                if (!std.mem.eql(u8, dispatched_name, "Write")) {
                    log.warnId("agent", rid, "project formal gate requested exact-Edit synthesis for non-Write name={s} id={s}", .{ name, id });
                    return .host_fatal;
                }
                const exact_input = project_rule_signal.synthesizeExactEditInput(
                    &job_ctx,
                    input,
                ) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
                    log.warnId("agent", rid, "project exact-Edit synthesis failed closed name={s} id={s} err={s}", .{ name, id, @errorName(err) });
                    const denied = @import("tool_error.zig").projectRuleExactEditBlockedJson(
                        dispatched_name,
                        parent_allocator,
                    ) catch return error.OutOfMemory;
                    return .{ .done = .{
                        .content = denied,
                        .is_error = true,
                        .elapsed_ms = elapsed,
                    } };
                };
                dispatch_input = exact_input;
                dispatched_name = "Edit";
                const exact_signal = project_rule_signal.observePre(
                    &job_ctx,
                    id,
                    dispatched_name,
                    dispatch_input,
                );
                switch (gate.pre(exact_signal)) {
                    .admit_exact_edit => job_ctx.project_edit_mode = .whole_file_exact,
                    .block => |recovery_action| {
                        const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
                        const tool_error = @import("tool_error.zig");
                        const denied = switch (recovery_action) {
                            .none => tool_error.projectRuleBlockedJson(
                                dispatched_name,
                                exact_signal.file_target_state,
                                parent_allocator,
                            ),
                            .edit_existing_file_exact => tool_error.projectRuleExactEditBlockedJson(
                                dispatched_name,
                                parent_allocator,
                            ),
                        } catch return error.OutOfMemory;
                        return .{ .done = .{
                            .content = denied,
                            .is_error = true,
                            .elapsed_ms = elapsed,
                        } };
                    },
                    .admit, .synthesize_exact_edit, .fault => {
                        log.warnId("agent", rid, "project synthesized exact Edit lacked recovery admission name={s} id={s}", .{ name, id });
                        return .host_fatal;
                    },
                }
                project_pre_signal = exact_signal;
                dispatch_observation.dispatched_name = dispatched_name;
                dispatch_observation.file_target_state = exact_signal.file_target_state;
                dispatch_observation.within_root = exact_signal.within_root;
                dispatch_observation.project_pre_signal = exact_signal;
            },
            .block => |recovery_action| {
                const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
                const tool_error = @import("tool_error.zig");
                const denied = switch (recovery_action) {
                    .none => tool_error.projectRuleBlockedJson(
                        dispatched_name,
                        project_pre_signal.?.file_target_state,
                        parent_allocator,
                    ),
                    .edit_existing_file_exact => tool_error.projectRuleExactEditBlockedJson(
                        dispatched_name,
                        parent_allocator,
                    ),
                } catch return error.OutOfMemory;
                return .{ .done = .{
                    .content = denied,
                    .is_error = true,
                    .elapsed_ms = elapsed,
                } };
            },
            .fault => {
                log.warnId("agent", rid, "project formal gate failed closed before dispatch name={s} id={s}", .{ name, id });
                return .host_fatal;
            },
        }
    }
    if (!dispatch_observation.start(dispatch_input)) {
        if (job_ctx.project_edit_mode == .whole_file_exact) {
            const gate = job_ctx.project_rule_gate orelse return .host_fatal;
            if (!gate.cancelPre(project_pre_signal.?))
                log.warnId("agent", rid, "project exact-edit pre-state cancellation failed after observation start rejection name={s} id={s}", .{ name, id });
        }
        log.warnId("agent", rid, "tool observation rejected dispatch start name={s} id={s}", .{ name, id });
        return .host_fatal;
    }
    defer dispatch_observation.ensureTerminal();
    const r = (if (job_ctx.project_edit_mode == .whole_file_exact)
        tools_mod.dispatchProjectExactEdit(&job_ctx, dispatch_input)
    else
        tools_mod.dispatch(&job_ctx, name, input)) catch |err| {
        const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
        if (err == error.OutOfMemory) {
            if (!dispatch_observation.finish(.host_fatal, @errorName(err), null))
                return .host_fatal;
            return error.OutOfMemory;
        }
        // L3:UiPending 是控制信号(非工具错误)——kind/payload dupe 到父 allocator 逃逸 arena。
        if (err == error.UiPending) {
            if (!dispatch_observation.finish(.pending, @errorName(err), null))
                return .host_fatal;
            log.infoId("agent", rid, "tool.exec PENDING(par) name={s} id={s} kind={s}", .{ name, id, if (pending_req) |pr| pr.kind else "" });
            const kind = if (pending_req) |pr| try parent_allocator.dupe(u8, pr.kind) else null;
            errdefer if (kind) |bytes| parent_allocator.free(bytes);
            const payload = if (pending_req) |pr| try parent_allocator.dupe(u8, pr.payload_json) else null;
            return .{ .pending = .{
                .kind = kind,
                .payload = payload,
                .elapsed_ms = elapsed,
            } };
        }
        const code = if (err == error.UnknownTool) "UnknownTool" else @errorName(err);
        if (!dispatch_observation.finish(.tool_error, code, null))
            return .host_fatal;
        const tool_error = @import("tool_error.zig");
        // 错误 json 用父 allocator(逃逸 arena)。工具填了 detail 用之,否则通用文案。
        // P0.6:UnknownTool 附可用工具清单(hermes 式引导),弱模型据此自纠而非空转烧 turn。
        const ej = if (err_detail) |d|
            tool_error.errorToJson(code, "{s}", .{d}, parent_allocator) catch return error.OutOfMemory
        else if (err == error.UnknownTool) blk: {
            const names = tools_mod.availableToolNames(&job_ctx, parent_allocator) catch null;
            defer if (names) |nm| parent_allocator.free(nm);
            // 模糊建议(仅提示,不执行):有则加 "Did you mean 'X'?"。
            const guess = tools_mod.suggestToolName(&job_ctx, name);
            break :blk if (guess) |g|
                tool_error.errorToJson(code, "Tool '{s}' does not exist. Did you mean '{s}'? Available tools: {s}", .{ name, g, if (names) |nm| nm else "(unavailable)" }, parent_allocator) catch return error.OutOfMemory
            else
                tool_error.errorToJson(code, "Tool '{s}' does not exist. Available tools: {s}", .{ name, if (names) |nm| nm else "(unavailable)" }, parent_allocator) catch return error.OutOfMemory;
        } else tool_error.errorToJson(code, "{s} failed with {s}", .{ name, @errorName(err) }, parent_allocator) catch return error.OutOfMemory;
        // `dispatch_input` may be a host-synthesized exact Edit containing
        // source bytes that were never model-visible. Preserve the historical
        // model-input diagnostic without leaking that host-only snapshot.
        log.warnId("agent", rid, "tool.exec FAILED(par) name={s} err={s} duration_ms={d} input={s}", .{ name, @errorName(err), elapsed, input[0..@min(input.len, 200)] });
        return .{ .done = .{ .content = ej, .is_error = true, .elapsed_ms = elapsed } };
    };
    // outcome slice 挂 job_ctx.allocator(= 本函数 arena) → 随 arena 回收,无单独释放点。
    switch (r) {
        .host_fatal => {
            _ = dispatch_observation.finish(.host_fatal, "HostToolFatal", null);
            log.warnId("agent", rid, "tool.exec HOST-FATAL name={s} id={s}", .{ name, id });
            return .host_fatal;
        },
        .host_failed, .host_rejected => |maybe_detail| {
            const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
            const code: []const u8 = if (r == .host_failed) "HostToolFailed" else "HostToolRejected";
            const outcome: tool_observation.Outcome = if (r == .host_failed) .host_failed else .host_rejected;
            if (!dispatch_observation.finish(outcome, code, maybe_detail))
                return .host_fatal;
            const ej = try hostToolErrorJson(code, name, maybe_detail, parent_allocator);
            log.warnId("agent", rid, "tool.exec HOST-{s}(par) name={s} duration_ms={d}", .{ code, name, elapsed });
            return .{ .done = .{ .content = ej, .is_error = true, .elapsed_ms = elapsed } };
        },
        .ok => {},
    }
    const ok_bytes = r.ok;
    if (!dispatch_observation.finish(.succeeded, null, ok_bytes)) {
        log.warnId("agent", rid, "tool observation rejected dispatch finish name={s} id={s}", .{ name, id });
        return .host_fatal;
    }
    // A successful persistent-task claim is the first decision point for that
    // task. Feed verified, execution-grounded history back through the same
    // tool result before the next model request. The adapter is deliberately
    // best-effort at this outer boundary: protocol/retrieval failures are
    // encoded as an explicit unavailable packet, while an unexpected adapter
    // bug must not hide a lease the model already acquired.
    const experience_packet = @import("../kg/experience_packet.zig");
    const experience_bytes = experience_packet.enrichClaimResult(
        job_ctx.allocator,
        job_ctx.kg,
        name,
        input,
        ok_bytes,
    ) catch |err| blk: {
        log.warnId("kg", rid, "experience packet enrichment failed: {s}", .{@errorName(err)});
        break :blk experience_packet.unavailableClaimResult(
            job_ctx.allocator,
            name,
            input,
            ok_bytes,
        ) catch null;
    };
    const result_bytes = experience_bytes orelse ok_bytes;
    // dispatch 结果在 arena 里 → dupe 到父 allocator 逃逸。落盘必须延迟到
    // executeSlots 确认整批无 fatal 之后，否则 fatal 会留下无人引用的 transient 文件。
    const content = try parent_allocator.dupe(u8, result_bytes);
    errdefer parent_allocator.free(content);
    const refs = if (builtin_file_tool)
        try buildFileReferences(parent_allocator, &job_ctx, dispatched_name, dispatch_input, dispatch_observation.file_target_state)
    else
        null;
    const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
    log.infoId("agent", rid, "tool.exec done(par) name={s} output_bytes={d} duration_ms={d}", .{ name, result_bytes.len, elapsed });
    return .{ .done = .{
        .content = content,
        .is_error = false,
        .elapsed_ms = elapsed,
        .file_refs = refs,
        .effect = effect_slot.effect,
        .effect_valid = effect_slot.valid,
    } };
}

fn isBuiltinFileTool(ctx: *const ToolContext, name: []const u8) bool {
    if (!file_reference.isBuiltinFileTool(name)) return false;
    if (ctx.tool_dispatcher) |dispatcher| return dispatcher.isBuiltin(name);
    return tools_mod.getTool(name) != null;
}

fn buildFileReferences(
    allocator: std.mem.Allocator,
    ctx: *const ToolContext,
    name: []const u8,
    input: []const u8,
    state: tool_observation.FileTargetState,
) !?[]file_reference.FileReference {
    // Write/Edit/NotebookEdit references are emitted only when the execution-boundary
    // sensor produced a reliable pre-state. Unknown observations must never
    // be guessed as "modified".
    if ((std.mem.eql(u8, name, "Write") or
        std.mem.eql(u8, name, "Edit") or
        std.mem.eql(u8, name, "NotebookEdit")) and
        state != .missing and state != .regular_existing)
        return null;
    const target = (try file_reference.resolveFileTarget(allocator, ctx, name, input, state)) orelse return null;
    defer allocator.free(target.path);
    var refs = try allocator.alloc(file_reference.FileReference, 1);
    refs[0] = file_reference.project(allocator, target, name) catch |err| {
        allocator.free(refs);
        if (err == error.FileReferenceTitleTooLong) return null;
        return error.OutOfMemory;
    };
    return refs;
}

fn invalidNativeWriteArgsResult(
    name: []const u8,
    err: anyerror,
    allocator: std.mem.Allocator,
    started_at_ms: i64,
    rid: log.RequestId,
) error{OutOfMemory}!OneResult {
    const elapsed: u64 = @intCast(@max(util_time.nowMs() - started_at_ms, 0));
    const code = @errorName(err);
    const encoded = @import("tool_error.zig").errorToJson(
        code,
        "{s} failed with {s}",
        .{ name, code },
        allocator,
    ) catch return error.OutOfMemory;
    log.warnId(
        "agent",
        rid,
        "tool.exec INVALID-ARGS name={s} code={s} duration_ms={d}",
        .{ name, code, elapsed },
    );
    return .{ .done = .{
        .content = encoded,
        .is_error = true,
        .elapsed_ms = elapsed,
    } };
}

fn hostToolErrorJson(
    code: []const u8,
    name: []const u8,
    maybe_detail: ?[]const u8,
    allocator: std.mem.Allocator,
) error{OutOfMemory}![]u8 {
    const tool_error = @import("tool_error.zig");
    if (maybe_detail) |detail| {
        if (detail.len != 0) {
            if (try tool_error.errorToJsonCapped(code, detail, MAX_TOOL_ERROR_PAYLOAD_BYTES_V1, allocator)) |encoded|
                return encoded;
        }
    }
    return tool_error.errorToJson(code, "{s} failed with {s}", .{ name, code }, allocator) catch error.OutOfMemory;
}

fn runJob(job: *Job) void {
    const s = job.slot;
    const result = executeOne(job.ctx, s.name, s.input, s.id, job.parent_allocator, job.rid) catch {
        job.out_of_memory = true;
        job.done = true;
        return;
    };
    switch (result) {
        .pending => |p| {
            s.pending = true;
            s.pending_kind = p.kind;
            s.pending_payload = p.payload;
            s.elapsed_ms = p.elapsed_ms;
        },
        .done => |d| {
            s.content = d.content;
            s.is_error = d.is_error;
            s.elapsed_ms = d.elapsed_ms;
            s.file_refs = d.file_refs;
            s.effect = d.effect;
            s.effect_valid = d.effect_valid;
        },
        // fatal 不组装 tool_result:slot 不填 content,信号经 Job.fatal 上传。
        .host_fatal => job.fatal = true,
    }
    job.done = true;
}

/// per-slot 并发安全判定:在 isConcurrencySafeInput 之上叠加同步 Task 特例。
/// 同步 Task/Agent(非 run_in_background)各自 spawn 独立子 agent + 独立 TaskStore,
/// 唯一共享风险是 http.Client——agent.zig 同步路径用 registry.makeProvider 造 per-call
/// provider(独立 client)规避。故仅当有 agent_jobs(能造独立 client)时才允许 Task 并发,否则保守串行
/// (headless 无 TUI,串行无碍)。对齐 cc:多个 Task 在一轮内并行跑(独立计时器)。
fn slotSafe(ctx: *const ToolContext, s: Slot) bool {
    // Host 工具:并发能力由 dispatcher 的显式 executor metadata 判定,不按名字猜
    // ("叫 Read 就碰巧并发"是事故不是设计)。header 契约要求 Host callback 承受
    // 同 Session 并发,Host owns ctx locking(tool_catalog 注释),故 host_sync 一律 safe。
    if (ctx.tool_dispatcher) |d| {
        if (d.isHostSync(s.name)) return true;
    }
    if ((std.mem.eql(u8, s.name, "Task") or std.mem.eql(u8, s.name, "Agent")) and ctx.agent_jobs != null) {
        // run_in_background 的 Task 立即返回不阻塞,本就不进并发批语义;但即便并发也安全
        // (它只注册后台 job 即返回)。统一按 safe 处理。
        return true;
    }
    // WebSearch is safe only when each worker can construct an isolated
    // provider. The process-wide WebSearch gate separately caps active searches
    // at two; without this capability it continues down the legacy serial path.
    if (std.mem.eql(u8, s.name, "WebSearch") and ctx.provider_factory != null) return true;
    return tools_mod.isConcurrencySafeInput(s.name, s.input);
}

/// 执行 slots 中所有 decision==.run 的 tool(分批并发);denied 的不动。
/// 结果写回 slot.content/is_error。base_ctx 是构造好的 ToolContext(allocator=父)。
/// Host 工具 fatal → error.HostToolFatal:fatal 后不再启动后续 slot/批;已启动的并发
/// worker 全部 join 后才返回;slot-owned payload 的销毁由调用方的 Slot.deinit defer
/// 承担(覆盖所有退出路径);不组装 tool_result。
pub fn executeSlots(
    slots: []Slot,
    base_ctx: *const ToolContext,
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
) error{ HostToolFatal, OutOfMemory }!void {
    var i: usize = 0;
    while (i < slots.len) {
        // denied(已填错误)或 prefetched(结果已由流式预取填好)→ 跳过,不执行。
        if (slots[i].decision == .denied or slots[i].prefetched) {
            // Prefetch execution is only knowledge-bearing after the main
            // permission path accepts the slot. Denied prefetched work is
            // deliberately invisible to the ledger.
            if (slots[i].decision == .run and slots[i].prefetched)
                observeSuccessfulExecutions(slots[i .. i + 1], base_ctx);
            i += 1;
            continue;
        }
        // 收集从 i 起连续的同安全性 run-slot 为一批。per-input 判定(Bash 看 command;
        // Task 同步 spawn 仅当有 agent_jobs 可造 per-call client 时算 safe,见 slotSafe)。
        const safe = slotSafe(base_ctx, slots[i]);
        var j = i;
        while (j < slots.len and slots[j].decision == .run and !slots[j].prefetched and slotSafe(base_ctx, slots[j]) == safe) : (j += 1) {}
        // slots[i..j] 是一批(同安全性)。
        if (safe and (j - i) > 1) {
            try runConcurrentBatch(slots[i..j], base_ctx, parent_allocator, rid);
        } else {
            // 单个 或 unsafe → 串行(复用并发 job 逻辑跑单个,保持错误处理一致)。
            for (slots[i..j]) |*s| {
                if (s.decision != .run) continue;
                var job = Job{ .slot = s, .ctx = base_ctx, .parent_allocator = parent_allocator, .rid = rid };
                runJob(&job);
                if (job.fatal) return error.HostToolFatal;
                if (job.out_of_memory) return error.OutOfMemory;
            }
        }
        // Commit host-observed facts after this execution batch succeeds, not
        // at turn end. A later fatal batch must not erase already established
        // successful work, while errors in this batch remain excluded.
        observeSuccessfulExecutions(slots[i..j], base_ctx);
        i = j;
    }

    // Result persistence is intentionally not an execution concern. The
    // agent loop lets PostToolUse hooks and UI consume raw results, then makes
    // one deterministic projection immediately before Conversation append.
}

fn observeSuccessfulExecutions(slots: []const Slot, base_ctx: *const ToolContext) void {
    const kg = base_ctx.kg orelse return;
    if (!kg.ready) return;
    const tasks = base_ctx.tasks orelse return;
    const task_id = tasks.uniqueActiveKgTaskId() orelse return;
    const project_dir = if (base_ctx.project_dir.len != 0) base_ctx.project_dir else base_ctx.cwd_abs;
    if (project_dir.len == 0) return;

    for (slots) |slot| {
        if (slot.decision != .run or slot.pending or slot.is_error or slot.content == null) continue;
        kg.observeSuccessfulExecution(task_id, slot.name, slot.input, project_dir);
    }
}

test "executeSlots 跳过 prefetched slot(不重复执行,P0.4 无双执行铁证)" {
    const a = std.testing.allocator;
    // prefetched slot:内容预填,名字是不存在的工具——若被执行会 dispatch 失败并覆写成错误 json;
    // 跳过则 content 原样保留。故"content 未变"= 确实跳过(没重复执行)。
    const marker = try a.dupe(u8, "PREFETCHED_CONTENT");
    var slots = [_]Slot{.{
        .decision = .run,
        .name = "NonExistentToolXYZ",
        .id = "s1",
        .input = "{}",
        .content = marker,
        .prefetched = true,
    }};
    defer if (slots[0].content) |c| a.free(c);
    var ctx = tools_mod.ToolContext{ .allocator = a };
    try executeSlots(&slots, &ctx, a, .{ .bytes = [_]u8{'0'} ** 12 });
    // prefetched → 未执行 → content 仍是预填值(未被 UnknownTool 错误覆写)。
    try std.testing.expect(slots[0].content != null);
    try std.testing.expectEqualStrings("PREFETCHED_CONTENT", slots[0].content.?);
    try std.testing.expect(!slots[0].is_error);
}

test "executeOne:成功路径返回 done+content(与 executeSlots 同一入口)" {
    const a = std.testing.allocator;
    var ctx = tools_mod.ToolContext{ .allocator = a, .cwd_abs = "." };
    const r = try executeOne(&ctx, "Glob", "{\"pattern\":\"*.zig\"}", "gid", a, .{ .bytes = [_]u8{'0'} ** 12 });
    switch (r) {
        .done => |d| {
            try std.testing.expect(!d.is_error);
            try std.testing.expect(d.content != null);
            if (d.content) |c| a.free(c);
        },
        .pending, .host_fatal => try std.testing.expect(false),
    }
}

test "executeOne: built-in Write emits a created file reference without a gate" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    var ctx = tools_mod.ToolContext{ .allocator = a, .cwd_abs = root, .resolve_relative_paths = true };
    const input = "{\"file_path\":\"ref-target.txt\",\"content\":\"hello\"}";
    const result = try executeOne(&ctx, "Write", input, "write-ref", a, .{ .bytes = [_]u8{'0'} ** 12 });
    switch (result) {
        .done => |done| {
            defer if (done.content) |content| a.free(content);
            defer if (done.file_refs) |refs| {
                for (refs) |*ref| ref.deinit(a);
                a.free(refs);
            };
            try std.testing.expect(!done.is_error);
            try std.testing.expect(done.file_refs != null);
            const refs = done.file_refs.?;
            try std.testing.expectEqual(@as(usize, 1), refs.len);
            try std.testing.expectEqualStrings("created", refs[0].kind);
            switch (refs[0].locator) {
                .workspace_path => {},
                else => return error.UnexpectedLocator,
            }
        },
        else => return error.UnexpectedToolOutcome,
    }
}

test "file reference projection never defaults an unobserved Write to modified" {
    const a = std.testing.allocator;
    var ctx = tools_mod.ToolContext{ .allocator = a, .cwd_abs = ".", .resolve_relative_paths = true };
    const refs = try buildFileReferences(
        a,
        &ctx,
        "Write",
        "{\"file_path\":\"unknown.txt\",\"content\":\"x\"}",
        .unobserved,
    );
    try std.testing.expect(refs == null);
}

test "executeOne: AgentCore Session Host Read does not emit a builtin file reference" {
    const a = std.testing.allocator;
    var probe: SameNameHostProbe = .{};
    var catalog = try tool_catalog.Catalog.init(a, &.{}, &.{.{
        .definition = .{
            .name = "Read",
            .description = "Host-owned Read",
            .input_schema = .{ .type = "object", .required = &.{} },
        },
        .ctx = @ptrCast(&probe),
        .execute = SameNameHostProbe.execute,
    }});
    defer catalog.deinit();
    var selection = try tool_catalog.Selection.init(a, &catalog, &.{"Read"});
    defer selection.deinit();

    var anchor: u8 = 0;
    var ctx = tools_mod.ToolContext{
        .allocator = a,
        .cwd_abs = ".",
        .tool_dispatcher = selection.dispatcher(),
        .host_run = .{
            .identity = .{ .session_id = @import("session_id.zig").SessionId.single, .run_id = 1 },
            .host_session_ctx = @ptrCast(&anchor),
        },
    };
    const result = try executeOne(&ctx, "Read", "{\"file_path\":\"outside.txt\"}", "host-read", a, .{ .bytes = [_]u8{'0'} ** 12 });
    switch (result) {
        .done => |done| {
            defer if (done.content) |content| a.free(content);
            defer if (done.file_refs) |refs| {
                for (refs) |*ref| ref.deinit(a);
                a.free(refs);
            };
            try std.testing.expect(!done.is_error);
            try std.testing.expect(done.file_refs == null);
        },
        else => return error.UnexpectedToolOutcome,
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

const SameNameHostProbe = struct {
    calls: usize = 0,

    fn execute(raw: *anyopaque, _: tool_catalog.HostRunIdentity, args: []const u8) error{OutOfMemory}!tool_catalog.HostToolOutcome {
        const self: *SameNameHostProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .ok = .{ .bytes = args, .release_ctx = raw, .releaseFn = release } };
    }

    fn release(_: *anyopaque, _: []const u8) void {}
};

test "executeOne:UnknownTool → 富错误引导(prefetch/executeSlots 共享此路径)" {
    const a = std.testing.allocator;
    var ctx = tools_mod.ToolContext{ .allocator = a };
    const r = try executeOne(&ctx, "NoSuchTool", "{}", "x", a, .{ .bytes = [_]u8{'0'} ** 12 });
    switch (r) {
        .done => |d| {
            try std.testing.expect(d.is_error);
            try std.testing.expect(d.content != null);
            if (d.content) |c| {
                defer a.free(c);
                // 富引导(非裸 "failed with"):列可用工具,弱模型据此自纠。
                try std.testing.expect(std.mem.indexOf(u8, c, "does not exist") != null);
                try std.testing.expect(std.mem.indexOf(u8, c, "Available tools") != null);
            }
        },
        .pending, .host_fatal => try std.testing.expect(false),
    }
}

/// 一批 safe slot 并发执行(每个独立线程,cap MAX_TOOL_CONCURRENCY)。
/// fatal 语义:当前窗口的 worker **全部 join** 后才检查/返回;fatal 后不启动下一窗口。
fn runConcurrentBatch(batch: []Slot, base_ctx: *const ToolContext, parent_allocator: std.mem.Allocator, rid: log.RequestId) error{ HostToolFatal, OutOfMemory }!void {
    return runConcurrentBatchWithSpawner(batch, base_ctx, parent_allocator, rid, spawnJob);
}

const SpawnJobFn = *const fn (job: *Job) std.Thread.SpawnError!std.Thread;

fn spawnJob(job: *Job) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, runJob, .{job});
}

/// Spawner injection exists solely to make the resource-exhaustion fallback
/// deterministic in tests. Production always passes `spawnJob`.
fn runConcurrentBatchWithSpawner(
    batch: []Slot,
    base_ctx: *const ToolContext,
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
    spawn_job: SpawnJobFn,
) error{ HostToolFatal, OutOfMemory }!void {
    var locked_parent = LockedAllocator{ .child = parent_allocator };
    const worker_allocator = locked_parent.allocator();
    var jobs = parent_allocator.alloc(Job, batch.len) catch {
        // 分配失败 → 退化串行
        for (batch) |*s| {
            var job = Job{ .slot = s, .ctx = base_ctx, .parent_allocator = parent_allocator, .rid = rid };
            runJob(&job);
            if (job.fatal) return error.HostToolFatal;
            if (job.out_of_memory) return error.OutOfMemory;
        }
        return;
    };
    defer parent_allocator.free(jobs);
    for (batch, 0..) |*s, k| jobs[k] = .{ .slot = s, .ctx = base_ctx, .parent_allocator = worker_allocator, .rid = rid };

    var threads = parent_allocator.alloc(?std.Thread, batch.len) catch {
        for (jobs) |*job| {
            runJob(job);
            if (job.fatal) return error.HostToolFatal;
            if (job.out_of_memory) return error.OutOfMemory;
        }
        return;
    };
    defer parent_allocator.free(threads);
    for (threads) |*t| t.* = null;

    // 滑动窗口:最多 MAX_TOOL_CONCURRENCY 个并发。
    var started: usize = 0;
    while (started < jobs.len) {
        const window_end = @min(started + MAX_TOOL_CONCURRENCY, jobs.len);
        var k = started;
        while (k < window_end) {
            threads[k] = spawn_job(&jobs[k]) catch null;
            if (threads[k] == null) {
                // spawn 失败 → 当场串行跑。若它观察到 fatal，立刻停止
                // 启动窗口内剩余 job；之前已启动的线程仍在下方全部 join。
                runJob(&jobs[k]);
                k += 1;
                if (jobs[k - 1].fatal or jobs[k - 1].out_of_memory) break;
            } else {
                k += 1;
            }
        }
        const launched_end = k;
        k = started;
        while (k < launched_end) : (k += 1) {
            if (threads[k]) |thread| thread.join();
        }
        // join 完整个窗口后才检查 fatal——不撕裂在飞 worker;fatal 则不再开下一窗口。
        for (jobs[started..launched_end]) |*job| {
            if (job.fatal) return error.HostToolFatal;
        }
        for (jobs[started..launched_end]) |*job| {
            if (job.out_of_memory) return error.OutOfMemory;
        }
        started = window_end;
    }
}

// —— T1 矩阵测试:fatal 清理(24)与 host 并发 metadata(25) ——

/// 测试用 dispatcher stub:按工具名返回 ok/fatal,并声明 host_sync metadata。
const StubDispatcher = struct {
    /// 名字以 "Fatal" 开头 → host_fatal;否则 .ok(内容为 input 的拷贝)。
    fn dispatch(_: *const anyopaque, tool_ctx: *const tools_mod.ToolContext, name: []const u8, args: []const u8) anyerror!tools_mod.ToolDispatchOutcome {
        if (std.mem.startsWith(u8, name, "Fatal")) return .host_fatal;
        return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
    }
    fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
        return false;
    }
    fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn hostSync(_: *const anyopaque, _: []const u8) bool {
        return true; // 全部按 host_sync 声明 → 并发判定走 metadata,不看名字
    }
    fn dispatcher() tools_mod.ToolDispatcher {
        return .{ .ctx = @ptrCast(&sentinel), .dispatchFn = dispatch, .prefetchSafeFn = prefetchSafe, .nameAtFn = nameAt, .hostSyncFn = hostSync };
    }
    var sentinel: u8 = 0;
};

test "execution policy denies before the single dispatch choke point" {
    const Probe = struct {
        calls: usize = 0,

        fn dispatch(
            raw: *const anyopaque,
            tool_ctx: *const tools_mod.ToolContext,
            _: []const u8,
            args: []const u8,
        ) anyerror!tools_mod.ToolDispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.calls += 1;
            return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
        }
        fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }
        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn dispatcher(self: *@This()) tools_mod.ToolDispatcher {
            return .{
                .ctx = @ptrCast(self),
                .dispatchFn = dispatch,
                .prefetchSafeFn = prefetchSafe,
                .nameAtFn = nameAt,
                .hostSyncFn = hostSync,
            };
        }
        fn allowsTool(_: *const anyopaque, _: []const u8) bool {
            return true;
        }
        fn allowsInvocation(
            _: *const anyopaque,
            _: []const u8,
            args: []const u8,
        ) bool {
            return std.mem.indexOf(u8, args, "denied") == null;
        }
        fn policy(self: *const @This()) tools_mod.ToolExecutionPolicy {
            return .{
                .ctx = @ptrCast(self),
                .allowsToolFn = allowsTool,
                .allowsInvocationFn = allowsInvocation,
            };
        }
    };

    const allocator = std.testing.allocator;
    var probe = Probe{};
    var ctx = tools_mod.ToolContext{
        .allocator = allocator,
        .tool_dispatcher = probe.dispatcher(),
        .execution_policy = probe.policy(),
    };
    const denied = try executeOne(
        &ctx,
        "Write",
        "{\"value\":\"denied\"}",
        "policy-denied",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (denied) {
        .done => |result| {
            defer if (result.content) |content| allocator.free(content);
            try std.testing.expect(result.is_error);
            try std.testing.expect(std.mem.indexOf(
                u8,
                result.content orelse "",
                "\"code\":\"permission_denied\"",
            ) != null);
        },
        else => return error.UnexpectedToolOutcome,
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);

    const allowed = try executeOne(
        &ctx,
        "Write",
        "{\"value\":\"allowed\"}",
        "policy-allowed",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (allowed) {
        .done => |result| {
            defer if (result.content) |content| allocator.free(content);
            try std.testing.expect(!result.is_error);
        },
        else => return error.UnexpectedToolOutcome,
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "矩阵24:host fatal 后无泄漏——已完成 slot 的 owned payload 由 Slot.deinit 全部回收" {
    const a = std.testing.allocator; // testing.allocator 自带泄漏检测:测试结束未释放即 fail
    var slots = [_]Slot{
        .{ .decision = .run, .name = "OkTool", .id = "s1", .input = "{\"x\":1}" },
        .{ .decision = .run, .name = "FatalTool", .id = "s2", .input = "{}" },
        .{ .decision = .denied, .name = "Denied", .id = "s3", .input = "{}" },
    };
    // denied slot 预填 owned 错误内容(agent_loop 的真实形态)。
    slots[2].content = try a.dupe(u8, "{\"error\":\"denied\"}");
    slots[2].is_error = true;
    defer for (&slots) |*s| s.deinit(a); // 调用方职责:单 defer 覆盖所有退出路径
    var ctx = tools_mod.ToolContext{ .allocator = a, .tool_dispatcher = StubDispatcher.dispatcher() };

    // host_sync metadata → 三个 slot 同批;FatalTool fatal → error 返回。
    try std.testing.expectError(error.HostToolFatal, executeSlots(&slots, &ctx, a, .{ .bytes = [_]u8{'0'} ** 12 }));
    // fatal slot 不组装任何 tool_result。
    try std.testing.expect(slots[1].content == null);
}

test "矩阵25:Host 工具并发判定走 executor metadata,不按名字猜" {
    const a = std.testing.allocator;
    var ctx = tools_mod.ToolContext{ .allocator = a, .tool_dispatcher = StubDispatcher.dispatcher() };
    // "UnsafeSoundingName" 不在任何 builtin 并发白名单里;metadata 声明 host_sync → safe。
    const s = Slot{ .decision = .run, .name = "UnsafeSoundingName", .id = "x", .input = "{}" };
    try std.testing.expect(slotSafe(&ctx, s));
    // 无 dispatcher(legacy 路径)→ 回退名字判定 → 该名字不安全。
    var legacy_ctx = tools_mod.ToolContext{ .allocator = a };
    try std.testing.expect(!slotSafe(&legacy_ctx, s));
}

test "thread spawn fallback observes fatal before starting the next job" {
    const ProbeDispatcher = struct {
        calls: usize = 0,

        fn dispatch(raw: *const anyopaque, tool_ctx: *const tools_mod.ToolContext, name: []const u8, args: []const u8) anyerror!tools_mod.ToolDispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.calls += 1;
            if (std.mem.eql(u8, name, "FatalFirst")) return .host_fatal;
            return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
        }

        fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
            return false;
        }

        fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }

        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return true;
        }

        fn dispatcher(self: *@This()) tools_mod.ToolDispatcher {
            return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .prefetchSafeFn = prefetchSafe, .nameAtFn = nameAt, .hostSyncFn = hostSync };
        }
    };
    const alwaysFailSpawn = struct {
        fn call(_: *Job) std.Thread.SpawnError!std.Thread {
            return error.SystemResources;
        }
    }.call;

    const a = std.testing.allocator;
    var probe = ProbeDispatcher{};
    var ctx = tools_mod.ToolContext{ .allocator = a, .tool_dispatcher = probe.dispatcher() };
    var slots = [_]Slot{
        .{ .decision = .run, .name = "FatalFirst", .id = "1", .input = "{}" },
        .{ .decision = .run, .name = "MustNotStart", .id = "2", .input = "{}" },
    };
    defer for (&slots) |*slot| slot.deinit(a);

    try std.testing.expectError(
        error.HostToolFatal,
        runConcurrentBatchWithSpawner(&slots, &ctx, a, .{ .bytes = [_]u8{'0'} ** 12 }, alwaysFailSpawn),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "serial host fatal stops before the next slot" {
    const SerialProbe = struct {
        calls: usize = 0,

        fn dispatch(raw: *const anyopaque, tool_ctx: *const tools_mod.ToolContext, name: []const u8, args: []const u8) anyerror!tools_mod.ToolDispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.calls += 1;
            if (std.mem.eql(u8, name, "FatalSerial")) return .host_fatal;
            return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
        }
        fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }
        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return false; // force the serial path
        }
        fn dispatcher(self: *@This()) tools_mod.ToolDispatcher {
            return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .prefetchSafeFn = prefetchSafe, .nameAtFn = nameAt, .hostSyncFn = hostSync };
        }
    };

    const allocator = std.testing.allocator;
    var probe = SerialProbe{};
    var ctx = tools_mod.ToolContext{ .allocator = allocator, .tool_dispatcher = probe.dispatcher() };
    var slots = [_]Slot{
        .{ .decision = .run, .name = "FatalSerial", .id = "1", .input = "{}" },
        .{ .decision = .run, .name = "AfterSerial", .id = "2", .input = "{}" },
    };
    defer for (&slots) |*slot| slot.deinit(allocator);
    try std.testing.expectError(error.HostToolFatal, executeSlots(&slots, &ctx, allocator, .{ .bytes = [_]u8{'0'} ** 12 }));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "concurrent host fatal joins started workers and skips the next window" {
    const ConcurrentProbe = struct {
        slow_done: std.atomic.Value(bool) = .init(false),
        after_started: std.atomic.Value(bool) = .init(false),

        fn dispatch(raw: *const anyopaque, tool_ctx: *const tools_mod.ToolContext, name: []const u8, args: []const u8) anyerror!tools_mod.ToolDispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            if (std.mem.startsWith(u8, name, "Slow")) {
                platform.sync.sleepMs(20);
                self.slow_done.store(true, .release);
                return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
            }
            if (std.mem.eql(u8, name, "FatalConcurrent")) return .host_fatal;
            if (std.mem.eql(u8, name, "AfterWindow")) self.after_started.store(true, .release);
            return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
        }
        fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }
        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return true;
        }
        fn dispatcher(self: *@This()) tools_mod.ToolDispatcher {
            return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .prefetchSafeFn = prefetchSafe, .nameAtFn = nameAt, .hostSyncFn = hostSync };
        }
    };

    const allocator = std.testing.allocator;
    var probe = ConcurrentProbe{};
    var ctx = tools_mod.ToolContext{ .allocator = allocator, .tool_dispatcher = probe.dispatcher() };
    var slots = [_]Slot{
        .{ .decision = .run, .name = "Slow0", .id = "0", .input = "{}" },
        .{ .decision = .run, .name = "FatalConcurrent", .id = "1", .input = "{}" },
        .{ .decision = .run, .name = "Slow2", .id = "2", .input = "{}" },
        .{ .decision = .run, .name = "Slow3", .id = "3", .input = "{}" },
        .{ .decision = .run, .name = "Slow4", .id = "4", .input = "{}" },
        .{ .decision = .run, .name = "Slow5", .id = "5", .input = "{}" },
        .{ .decision = .run, .name = "Slow6", .id = "6", .input = "{}" },
        .{ .decision = .run, .name = "Slow7", .id = "7", .input = "{}" },
        .{ .decision = .run, .name = "AfterWindow", .id = "8", .input = "{}" },
    };
    defer for (&slots) |*slot| slot.deinit(allocator);
    try std.testing.expectError(error.HostToolFatal, executeSlots(&slots, &ctx, allocator, .{ .bytes = [_]u8{'0'} ** 12 }));
    try std.testing.expect(probe.slow_done.load(.acquire));
    try std.testing.expect(!probe.after_started.load(.acquire));
}

test "fatal batch does not persist a completed transient result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(std.testing.io, &home_buffer);
    const home = home_buffer[0..home_len];
    const result_dir = try std.fmt.allocPrintSentinel(allocator, "{s}/.metacodes/tool-results", .{home}, 0);
    defer allocator.free(result_dir);

    const large = try allocator.alloc(u8, 60_000);
    defer allocator.free(large);
    @memset(large, 'x');
    var ctx = tools_mod.ToolContext{ .allocator = allocator, .home_dir = home, .tool_dispatcher = StubDispatcher.dispatcher() };
    var slots = [_]Slot{
        .{ .decision = .run, .name = "LargeResult", .id = "1", .input = large },
        .{ .decision = .run, .name = "FatalTool", .id = "2", .input = "{}" },
    };
    defer for (&slots) |*slot| slot.deinit(allocator);

    try std.testing.expectError(error.HostToolFatal, executeSlots(&slots, &ctx, allocator, .{ .bytes = [_]u8{'0'} ** 12 }));
    try std.testing.expect(!platform.fs.exists(result_dir.ptr));
}

test "Host error detail bypasses result persistence and aggregate budget" {
    const FailureDispatcher = struct {
        detail: []const u8,
        fail: bool,

        fn dispatch(raw: *const anyopaque, tool_ctx: *const tools_mod.ToolContext, tool_name: []const u8, args: []const u8) anyerror!tools_mod.ToolDispatchOutcome {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            if (self.fail or std.mem.eql(u8, tool_name, "HostFailureProbe"))
                return .{ .host_failed = try tool_ctx.allocator.dupe(u8, self.detail) };
            return .{ .ok = try tool_ctx.allocator.dupe(u8, args) };
        }

        fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
            return false;
        }

        fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }

        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return true;
        }

        fn dispatcher(self: *const @This()) tools_mod.ToolDispatcher {
            return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .prefetchSafeFn = prefetchSafe, .nameAtFn = nameAt, .hostSyncFn = hostSync };
        }
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(std.testing.io, &home_buffer);
    const home = home_buffer[0..home_len];
    const result_dir = try std.fmt.allocPrintSentinel(allocator, "{s}/.metacodes/tool-results", .{home}, 0);
    defer allocator.free(result_dir);

    const detail_60k = try allocator.alloc(u8, 60_000);
    defer allocator.free(detail_60k);
    @memset(detail_60k, 'a');
    const detail_250k = try allocator.alloc(u8, 250_000);
    defer allocator.free(detail_250k);
    @memset(detail_250k, 'b');
    const detail_40k = try allocator.alloc(u8, 40_000);
    defer allocator.free(detail_40k);
    @memset(detail_40k, 'c');

    for ([_][]const u8{ detail_60k, detail_250k }) |detail| {
        const probe = FailureDispatcher{ .detail = detail, .fail = true };
        var ctx = tools_mod.ToolContext{ .allocator = allocator, .home_dir = home, .tool_dispatcher = probe.dispatcher() };
        var slots = [_]Slot{.{ .decision = .run, .name = "HostPersistenceProbe", .id = "failure", .input = "{}" }};
        defer slots[0].deinit(allocator);

        try executeSlots(&slots, &ctx, allocator, .{ .bytes = [_]u8{'0'} ** 12 });
        try std.testing.expect(slots[0].is_error);
        const encoded = slots[0].content orelse return error.MissingHostError;
        try std.testing.expect(std.mem.indexOf(u8, encoded, "\"persisted\":true") == null);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "\"truncated\":true") == null);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(detail, parsed.value.object.get("error").?.object.get("detail").?.string);
    }

    // A large error is outside the aggregate bulk budget: it must not force an
    // otherwise sub-threshold successful sibling to disk.
    const mixed_probe = FailureDispatcher{ .detail = detail_250k, .fail = false };
    var mixed_ctx = tools_mod.ToolContext{ .allocator = allocator, .home_dir = home, .tool_dispatcher = mixed_probe.dispatcher() };
    var mixed_slots = [_]Slot{
        .{ .decision = .run, .name = "HostFailureProbe", .id = "failure", .input = "{}" },
        .{ .decision = .run, .name = "HostPersistenceProbe", .id = "success", .input = detail_40k },
    };
    defer for (&mixed_slots) |*slot| slot.deinit(allocator);
    try executeSlots(&mixed_slots, &mixed_ctx, allocator, .{ .bytes = [_]u8{'0'} ** 12 });
    try std.testing.expect(mixed_slots[0].is_error);
    try std.testing.expect(!mixed_slots[1].is_error);
    try std.testing.expectEqualStrings(detail_40k, mixed_slots[1].content.?);
    try std.testing.expect(std.mem.indexOf(u8, mixed_slots[0].content.?, "\"persisted\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, mixed_slots[1].content.?, "\"persisted\":true") == null);
    try std.testing.expect(!platform.fs.exists(result_dir.ptr));

    // Even normal bulk output remains raw at the dispatch seam. Projection is
    // an agent-loop commit concern so hooks/UI can inspect the exact result.
    const success_probe = FailureDispatcher{ .detail = &.{}, .fail = false };
    var success_ctx = tools_mod.ToolContext{ .allocator = allocator, .home_dir = home, .tool_dispatcher = success_probe.dispatcher() };
    var success_slots = [_]Slot{.{ .decision = .run, .name = "HostPersistenceProbe", .id = "success", .input = detail_60k }};
    defer success_slots[0].deinit(allocator);
    try executeSlots(&success_slots, &success_ctx, allocator, .{ .bytes = [_]u8{'0'} ** 12 });
    try std.testing.expect(!success_slots[0].is_error);
    try std.testing.expectEqualStrings(detail_60k, success_slots[0].content.?);
    try std.testing.expect(!platform.fs.exists(result_dir.ptr));
}

test "Host detail JSON is exact when valid and falls back when encoded payload exceeds cap" {
    const allocator = std.testing.allocator;
    const detail = "quote=\" slash=\\ line=\n nul=\x00";
    const encoded = try hostToolErrorJson("HostToolFailed", "HostX", detail, allocator);
    defer allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(detail, parsed.value.object.get("error").?.object.get("detail").?.string);

    const hostile = try allocator.alloc(u8, 200 * 1024);
    defer allocator.free(hostile);
    @memset(hostile, 0);
    const fallback = try hostToolErrorJson("HostToolRejected", "HostX", hostile, allocator);
    defer allocator.free(fallback);
    try std.testing.expect(fallback.len <= MAX_TOOL_ERROR_PAYLOAD_BYTES_V1);
    var fallback_parsed = try std.json.parseFromSlice(std.json.Value, allocator, fallback, .{});
    defer fallback_parsed.deinit();
    try std.testing.expectEqualStrings(
        "HostX failed with HostToolRejected",
        fallback_parsed.value.object.get("error").?.object.get("detail").?.string,
    );
}

test "Slot.takeContent 转移即置空,与 deinit 无双释放" {
    const a = std.testing.allocator;
    var s = Slot{ .decision = .run, .name = "T", .id = "i", .input = "{}" };
    s.content = try a.dupe(u8, "payload");
    const taken = s.takeContent();
    try std.testing.expect(s.content == null);
    a.free(taken.?); // 调用方持有
    s.deinit(a); // 已置空 → no-op,无双释放(testing.allocator 会抓)
}

test "tool observation: actual Write dispatch emits UI-independent typed effect at nested depth" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/observed.txt",
        .{root_buffer[0..root_len]},
        0,
    );
    defer allocator.free(path);
    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"file_path\":\"{s}\",\"content\":\"grounded\"}}",
        .{path},
    );
    defer allocator.free(args);

    var capture = ObservationCapture{};
    var ctx = tools_mod.ToolContext.simple(allocator);
    ctx.agent_depth = 7;
    ctx.tool_observer = capture.sink();
    const result = try executeOne(
        &ctx,
        "write_tool",
        args,
        "nested-write",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    switch (result) {
        .done => |done| {
            defer if (done.content) |bytes| allocator.free(bytes);
            defer if (done.file_refs) |refs| {
                for (refs) |*ref| ref.deinit(allocator);
                allocator.free(refs);
            };
            try std.testing.expect(!done.is_error);
        },
        else => return error.UnexpectedToolResult,
    }

    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
    try std.testing.expectEqual(@as(u8, 7), capture.depth);
    try std.testing.expect(capture.origin == .authoritative);
    try std.testing.expect(capture.outcome == .succeeded);
    try std.testing.expect(capture.saw_name_repair);
    try std.testing.expect(capture.dispatched_as_write);
    try std.testing.expect(capture.effect_valid);
    const effect = capture.effect orelse return error.MissingToolEffect;
    const observed = switch (effect) {
        .file_mutation_v1 => return error.MissingPostReobservation,
        .file_mutation_v2 => |value| value,
    };
    const mutation = observed.mutation;
    try std.testing.expect(mutation.before_state == .missing);
    try std.testing.expect(mutation.change == .changed);
    try std.testing.expectEqual(@as(usize, "grounded".len), mutation.after_bytes);
    try std.testing.expectEqualSlices(
        u8,
        &tool_observation.sha256Hex(path),
        &mutation.path_sha256,
    );
    try std.testing.expect(observed.reobservation.state == .matched);
    try std.testing.expectEqualSlices(
        u8,
        &mutation.after_sha256,
        &observed.reobservation.observed_sha256,
    );
    try std.testing.expect(platform.fs.exists(path.ptr));
}

test "tool observation: finish rejection poisons dispatch after preserving actual file effect" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/finish-rejected.txt",
        .{root_buffer[0..root_len]},
        0,
    );
    defer allocator.free(path);
    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"file_path\":\"{s}\",\"content\":\"effect-happened\"}}",
        .{path},
    );
    defer allocator.free(args);

    var capture = ObservationCapture{ .accept_finish = false };
    var ctx = tools_mod.ToolContext.simple(allocator);
    ctx.tool_observer = capture.sink();
    const result = try executeOne(
        &ctx,
        "Write",
        args,
        "finish-rejected",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );

    try std.testing.expect(result == .host_fatal);
    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
    try std.testing.expect(capture.outcome == .succeeded);
    try std.testing.expect(capture.effect_valid);
    try std.testing.expect(capture.effect != null);
    try std.testing.expect(platform.fs.exists(path.ptr));
}

test "project post gate runs before terminal observation and block preserves actual effect" {
    const GateProbe = struct {
        post_called: bool = false,
        saw_matched_reobservation: bool = false,

        fn pre(_: *anyopaque, _: project_gate_protocol.PreSignal) project_gate_protocol.PreResult {
            return .admit;
        }

        fn post(raw: *anyopaque, signal: project_gate_protocol.PostSignal) project_gate_protocol.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.post_called = true;
            self.saw_matched_reobservation = switch (signal.effect orelse return .block) {
                .file_mutation_v1 => false,
                .file_mutation_v2 => |value| value.reobservation.state == .matched,
            };
            return .block;
        }

        fn gate(self: *@This()) project_gate_protocol.Gate {
            return .{ .ctx = @ptrCast(self), .preFn = pre, .postFn = post };
        }
    };
    const TerminalCapture = struct {
        gate_probe: *const GateProbe,
        starts: usize = 0,
        finishes: usize = 0,
        finish_saw_post: bool = false,
        effect: ?tool_observation.Effect = null,

        fn emit(raw: *anyopaque, event: tool_observation.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .rule_filter, .rule_coverage_gap, .rule_bounds_overflow, .verification_final_gate, .requirement_ledger, .test_weakening_candidate, .formal_decision, .formal_decision_batch => {},
                .dispatch_started => self.starts += 1,
                .dispatch_finished => |finished| {
                    self.finishes += 1;
                    self.finish_saw_post = self.gate_probe.post_called;
                    self.effect = finished.effect;
                },
            }
            return true;
        }

        fn sink(self: *@This()) tools_mod.ToolObservationSink {
            return .{ .ctx = @ptrCast(self), .emitFn = emit };
        }
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/post-blocked.txt",
        .{root_buffer[0..root_len]},
        0,
    );
    defer allocator.free(path);
    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"file_path\":\"{s}\",\"content\":\"effect-happened\"}}",
        .{path},
    );
    defer allocator.free(args);

    var gate_probe = GateProbe{};
    var capture = TerminalCapture{ .gate_probe = &gate_probe };
    var ctx = tools_mod.ToolContext.simple(allocator);
    ctx.project_rule_gate = gate_probe.gate();
    ctx.tool_observer = capture.sink();
    const result = try executeOne(
        &ctx,
        "Write",
        args,
        "post-blocked",
        allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );

    try std.testing.expect(result == .host_fatal);
    try std.testing.expect(gate_probe.post_called);
    try std.testing.expect(gate_probe.saw_matched_reobservation);
    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
    try std.testing.expect(capture.finish_saw_post);
    try std.testing.expect(capture.effect != null);
    try std.testing.expect(platform.fs.exists(path.ptr));
}

test "tool observation: sink rejection blocks before actual dispatcher invocation" {
    const Probe = struct {
        calls: usize = 0,

        fn dispatch(raw: *const anyopaque, tool_ctx: *const tools_mod.ToolContext, _: []const u8, _: []const u8) anyerror!tools_mod.ToolDispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.calls += 1;
            return .{ .ok = try tool_ctx.allocator.dupe(u8, "unexpected") };
        }
        fn prefetchSafe(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn nameAt(_: *const anyopaque, _: usize) ?[]const u8 {
            return null;
        }
        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return false;
        }
        fn dispatcher(self: *@This()) tools_mod.ToolDispatcher {
            return .{
                .ctx = @ptrCast(self),
                .dispatchFn = dispatch,
                .prefetchSafeFn = prefetchSafe,
                .nameAtFn = nameAt,
                .hostSyncFn = hostSync,
            };
        }
    };

    var probe = Probe{};
    var capture = ObservationCapture{ .accept_start = false };
    var ctx = tools_mod.ToolContext.simple(std.testing.allocator);
    ctx.tool_dispatcher = probe.dispatcher();
    ctx.tool_observer = capture.sink();
    const result = try executeOne(
        &ctx,
        "Probe",
        "{}",
        "blocked",
        std.testing.allocator,
        .{ .bytes = [_]u8{'0'} ** 12 },
    );
    try std.testing.expect(result == .host_fatal);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.finishes);
}
