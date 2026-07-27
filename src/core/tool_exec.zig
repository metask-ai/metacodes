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
//! 不写共享态。每个并发 job 用独立 ArenaAllocator 规避 GPA 非线程安全;结果 dupe 回父。

const std = @import("std");
const platform = @import("platform");
const tools_mod = @import("../tools.zig");
const ToolContext = tools_mod.ToolContext;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");

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
    /// P0.4:该 slot 的结果已由流式预取(stream_prefetch)填好 → executeSlots 跳过,不重复执行。
    prefetched: bool = false,

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
    done: struct { content: ?[]u8, is_error: bool, elapsed_ms: u64 },
    /// L3 挂起:工具发起 custom UI(error.UiPending)。kind/payload owned by parent_allocator。
    pending: struct { kind: ?[]u8, payload: ?[]u8, elapsed_ms: u64 },
    /// Host 工具 fatal:类型化控制信号,无 payload——不组装 tool_result,逐层显式传递
    /// 至 agent loop 映射为 error.HostToolFatal(→ poisonRun)。
    host_fatal,
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
    const r = tools_mod.dispatch(&job_ctx, name, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
        // L3:UiPending 是控制信号(非工具错误)——kind/payload dupe 到父 allocator 逃逸 arena。
        if (err == error.UiPending) {
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
        log.warnId("agent", rid, "tool.exec FAILED(par) name={s} err={s} duration_ms={d} input={s}", .{ name, @errorName(err), elapsed, input[0..@min(input.len, 200)] });
        return .{ .done = .{ .content = ej, .is_error = true, .elapsed_ms = elapsed } };
    };
    // outcome slice 挂 job_ctx.allocator(= 本函数 arena) → 随 arena 回收,无单独释放点。
    switch (r) {
        .host_fatal => {
            log.warnId("agent", rid, "tool.exec HOST-FATAL name={s} id={s}", .{ name, id });
            return .host_fatal;
        },
        .host_failed, .host_rejected => |maybe_detail| {
            const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
            const code: []const u8 = if (r == .host_failed) "HostToolFailed" else "HostToolRejected";
            const ej = try hostToolErrorJson(code, name, maybe_detail, parent_allocator);
            log.warnId("agent", rid, "tool.exec HOST-{s}(par) name={s} duration_ms={d}", .{ code, name, elapsed });
            return .{ .done = .{ .content = ej, .is_error = true, .elapsed_ms = elapsed } };
        },
        .ok => {},
    }
    const ok_bytes = r.ok;
    // dispatch 结果在 arena 里 → dupe 到父 allocator 逃逸。落盘必须延迟到
    // executeSlots 确认整批无 fatal 之后，否则 fatal 会留下无人引用的 transient 文件。
    const content = try parent_allocator.dupe(u8, ok_bytes);
    const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
    log.infoId("agent", rid, "tool.exec done(par) name={s} output_bytes={d} duration_ms={d}", .{ name, ok_bytes.len, elapsed });
    return .{ .done = .{ .content = content, .is_error = false, .elapsed_ms = elapsed } };
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
        i = j;
    }

    // 只有整批确认无 fatal/OOM 后才允许产生持久化副作用。
    persistCompletedResults(slots, base_ctx, parent_allocator);

    // per-message 聚合预算(对齐 cc MAX_TOOL_RESULTS_PER_MESSAGE_CHARS):一轮多个工具
    // 结果合计超 200k → 按大小降序把最大的落盘(替成 preview)直到达标。批1A 并发后
    // 多工具同时产大结果更易触发;单结果落盘由上方确认整批成功后统一做,这里管"合计"。
    enforceMessageBudget(slots, base_ctx, parent_allocator);
}

fn persistCompletedResults(slots: []Slot, base_ctx: *const ToolContext, parent_allocator: std.mem.Allocator) void {
    const storage = @import("../tools/tool_result_storage.zig");
    for (slots) |*slot| {
        // Error payloads are semantic model input, not bulk output. Replacing
        // them with a persisted/truncated envelope would destroy the Host
        // FAILED/REJECTED detail contract after it was safely serialized.
        if (slot.is_error) continue;
        const content = slot.content orelse continue;
        if (storage.maybePersist(parent_allocator, slot.name, content, base_ctx.home_dir) catch null) |preview| {
            parent_allocator.free(content);
            slot.content = preview;
        }
    }
}

const MAX_TOOL_RESULTS_PER_MESSAGE: usize = 200_000;

fn enforceMessageBudget(slots: []Slot, base_ctx: *const ToolContext, parent_allocator: std.mem.Allocator) void {
    const storage = @import("../tools/tool_result_storage.zig");
    var total: usize = 0;
    for (slots) |s| {
        // Error payloads are deliberately outside the bulk-result budget: the
        // encoded error cap bounds them, and persistence must not rewrite them.
        if (s.is_error) continue;
        total += if (s.content) |c| c.len else 0;
    }
    if (total <= MAX_TOOL_RESULTS_PER_MESSAGE) return;

    // 反复挑当前最大且"还没落盘"的 slot 落盘,直到达标或没得落。
    while (total > MAX_TOOL_RESULTS_PER_MESSAGE) {
        var biggest: ?usize = null;
        var biggest_len: usize = 0;
        for (slots, 0..) |s, k| {
            if (s.is_error) continue;
            const c = s.content orelse continue;
            // Read(maxResultChars==maxInt)永不落盘——它自有 maxTokens 上限,落盘会造
            // Read→file→Read 环(对齐 cc FileRead Infinity + per-message frozen/skip)。
            if (storage.maxResultChars(s.name) == std.math.maxInt(usize)) continue;
            // 已是 persisted/truncated preview 的不再处理(幂等)。
            if (std.mem.indexOf(u8, c, "\"persisted\":true") != null or std.mem.indexOf(u8, c, "\"truncated\":true") != null) continue;
            if (c.len > biggest_len) {
                biggest_len = c.len;
                biggest = k;
            }
        }
        const idx = biggest orelse break; // 没有可落盘的了
        const s = &slots[idx];
        const old = s.content.?;
        // 强制落盘:用 0 阈值确保这个一定被落(maybePersist 内部按 maxResultChars 判,
        // 这里直接调 persistForced 绕过阈值)。
        const preview = storage.persistForced(parent_allocator, s.name, old, base_ctx.home_dir) catch null;
        if (preview) |p| {
            total = total - old.len + p.len;
            parent_allocator.free(old);
            s.content = p;
        } else break; // 落盘失败 → 停(避免死循环)
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
    for (batch, 0..) |*s, k| jobs[k] = .{ .slot = s, .ctx = base_ctx, .parent_allocator = parent_allocator, .rid = rid };

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

    // Normal bulk output still follows the existing persistence policy.
    const success_probe = FailureDispatcher{ .detail = &.{}, .fail = false };
    var success_ctx = tools_mod.ToolContext{ .allocator = allocator, .home_dir = home, .tool_dispatcher = success_probe.dispatcher() };
    var success_slots = [_]Slot{.{ .decision = .run, .name = "HostPersistenceProbe", .id = "success", .input = detail_60k }};
    defer success_slots[0].deinit(allocator);
    try executeSlots(&success_slots, &success_ctx, allocator, .{ .bytes = [_]u8{'0'} ** 12 });
    try std.testing.expect(!success_slots[0].is_error);
    try std.testing.expect(std.mem.indexOf(u8, success_slots[0].content.?, "\"persisted\":true") != null);
    try std.testing.expect(platform.fs.exists(result_dir.ptr));
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
