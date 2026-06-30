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
const tools_mod = @import("../tools.zig");
const ToolContext = tools_mod.ToolContext;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");

pub const MAX_TOOL_CONCURRENCY: usize = 8;

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
};

/// 一个并发 job 的输入(safe 批用)。
const Job = struct {
    slot: *Slot,
    ctx: *const ToolContext, // 共享(只读字段 + 线程安全的 read_state)
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
    done: bool = false,
};

fn runJob(job: *Job) void {
    const s = job.slot;
    const t_start = util_time.nowMs();
    // 每 job 独立 arena,规避 GPA 并发;dispatch 的临时分配挂这里。
    var arena = std.heap.ArenaAllocator.init(job.parent_allocator);
    defer arena.deinit();
    var job_ctx = job.ctx.*;
    job_ctx.allocator = arena.allocator();
    // per-toolUse 进度路由:盖上本 job 的 tool_use id,reportProgress 据此找对应卡。
    job_ctx.progress_tool_id = s.id;
    // 富错误 detail 槽:工具可在抛错前写入,替代通用 "X failed with Y"。
    var err_detail: ?[]const u8 = null;
    job_ctx.error_detail = &err_detail;
    // L3 挂起槽:工具发起 custom UI 拿到 .pending → 写 {kind,payload} 进这里 + 返 error.UiPending。
    var pending_req: ?tools_mod.PendingRequest = null;
    job_ctx.pending_request = &pending_req;

    log.infoId("agent", job.rid, "tool.exec start(par) name={s} id={s}", .{ s.name, s.id });
    const r = tools_mod.dispatch(&job_ctx, s.name, s.input) catch |err| {
        // L3:UiPending 是控制信号(非工具错误)——置 pending 标志 + 把 kind/payload dupe 到父
        // allocator 逃逸 arena(供 agent_loop emit + 落盘),不置 is_error、不产 tool_result。
        if (err == error.UiPending) {
            s.pending = true;
            if (pending_req) |pr| {
                s.pending_kind = job.parent_allocator.dupe(u8, pr.kind) catch null;
                s.pending_payload = job.parent_allocator.dupe(u8, pr.payload_json) catch null;
            }
            s.elapsed_ms = @intCast(@max(util_time.nowMs() - t_start, 0));
            log.infoId("agent", job.rid, "tool.exec PENDING(par) name={s} id={s} kind={s}", .{ s.name, s.id, if (pending_req) |pr| pr.kind else "" });
            job.done = true;
            return;
        }
        const code = if (err == error.UnknownTool) "UnknownTool" else @errorName(err);
        const tool_error = @import("tool_error.zig");
        // 错误 json 用父 allocator(逃逸 arena)。工具填了 detail 用之,否则通用文案。
        const ej = if (err_detail) |d|
            tool_error.errorToJson(code, "{s}", .{d}, job.parent_allocator) catch null
        else
            tool_error.errorToJson(code, "{s} failed with {s}", .{ s.name, @errorName(err) }, job.parent_allocator) catch null;
        s.content = ej;
        s.is_error = true;
        s.elapsed_ms = @intCast(@max(util_time.nowMs() - t_start, 0));
        log.warnId("agent", job.rid, "tool.exec FAILED(par) name={s} err={s} duration_ms={d} input={s}", .{ s.name, @errorName(err), util_time.nowMs() - t_start, s.input[0..@min(s.input.len, 200)] });
        job.done = true;
        return;
    };
    // dispatch 结果在 arena 里 → dupe 到父 allocator 逃逸。
    const owned = job.parent_allocator.dupe(u8, r) catch null;
    if (owned) |o| {
        // 大结果落盘(批1C):超阈值 → 替换为 preview+path。
        const storage = @import("../tools/tool_result_storage.zig");
        if (storage.maybePersist(job.parent_allocator, s.name, o, job.ctx.home_dir) catch null) |preview| {
            job.parent_allocator.free(o);
            s.content = preview;
        } else {
            s.content = o;
        }
    } else {
        s.content = null;
    }
    s.is_error = false;
    s.elapsed_ms = @intCast(@max(util_time.nowMs() - t_start, 0));
    log.infoId("agent", job.rid, "tool.exec done(par) name={s} output_bytes={d} duration_ms={d}", .{ s.name, r.len, util_time.nowMs() - t_start });
    job.done = true;
}

/// per-slot 并发安全判定:在 isConcurrencySafeInput 之上叠加同步 Task 特例。
/// 同步 Task/Agent(非 run_in_background)各自 spawn 独立子 agent + 独立 TaskStore,
/// 唯一共享风险是 http.Client——agent.zig 同步路径用 registry.makeClient 造 per-call
/// client 规避。故仅当有 agent_jobs(能造独立 client)时才允许 Task 并发,否则保守串行
/// (headless 无 TUI,串行无碍)。对齐 cc:多个 Task 在一轮内并行跑(独立计时器)。
fn slotSafe(ctx: *const ToolContext, s: Slot) bool {
    if ((std.mem.eql(u8, s.name, "Task") or std.mem.eql(u8, s.name, "Agent")) and ctx.agent_jobs != null) {
        // run_in_background 的 Task 立即返回不阻塞,本就不进并发批语义;但即便并发也安全
        // (它只注册后台 job 即返回)。统一按 safe 处理。
        return true;
    }
    return tools_mod.isConcurrencySafeInput(s.name, s.input);
}

/// 执行 slots 中所有 decision==.run 的 tool(分批并发);denied 的不动。
/// 结果写回 slot.content/is_error。base_ctx 是构造好的 ToolContext(allocator=父)。
pub fn executeSlots(
    slots: []Slot,
    base_ctx: *const ToolContext,
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
) void {
    var i: usize = 0;
    while (i < slots.len) {
        if (slots[i].decision == .denied) {
            i += 1;
            continue;
        }
        // 收集从 i 起连续的同安全性 run-slot 为一批。per-input 判定(Bash 看 command;
        // Task 同步 spawn 仅当有 agent_jobs 可造 per-call client 时算 safe,见 slotSafe)。
        const safe = slotSafe(base_ctx, slots[i]);
        var j = i;
        while (j < slots.len and slots[j].decision == .run and slotSafe(base_ctx, slots[j]) == safe) : (j += 1) {}
        // slots[i..j] 是一批(同安全性)。
        if (safe and (j - i) > 1) {
            runConcurrentBatch(slots[i..j], base_ctx, parent_allocator, rid);
        } else {
            // 单个 或 unsafe → 串行(复用并发 job 逻辑跑单个,保持错误处理一致)。
            for (slots[i..j]) |*s| {
                if (s.decision != .run) continue;
                var job = Job{ .slot = s, .ctx = base_ctx, .parent_allocator = parent_allocator, .rid = rid };
                runJob(&job);
            }
        }
        i = j;
    }

    // per-message 聚合预算(对齐 cc MAX_TOOL_RESULTS_PER_MESSAGE_CHARS):一轮多个工具
    // 结果合计超 200k → 按大小降序把最大的落盘(替成 preview)直到达标。批1A 并发后
    // 多工具同时产大结果更易触发;单结果落盘(maybePersist)已在 runJob 做,这里管"合计"。
    enforceMessageBudget(slots, base_ctx, parent_allocator);
}

const MAX_TOOL_RESULTS_PER_MESSAGE: usize = 200_000;

fn enforceMessageBudget(slots: []Slot, base_ctx: *const ToolContext, parent_allocator: std.mem.Allocator) void {
    const storage = @import("../tools/tool_result_storage.zig");
    var total: usize = 0;
    for (slots) |s| total += if (s.content) |c| c.len else 0;
    if (total <= MAX_TOOL_RESULTS_PER_MESSAGE) return;

    // 反复挑当前最大且"还没落盘"的 slot 落盘,直到达标或没得落。
    while (total > MAX_TOOL_RESULTS_PER_MESSAGE) {
        var biggest: ?usize = null;
        var biggest_len: usize = 0;
        for (slots, 0..) |s, k| {
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

/// 一批 safe slot 并发执行(每个独立线程,cap MAX_TOOL_CONCURRENCY)。
fn runConcurrentBatch(batch: []Slot, base_ctx: *const ToolContext, parent_allocator: std.mem.Allocator, rid: log.RequestId) void {
    var jobs = parent_allocator.alloc(Job, batch.len) catch {
        // 分配失败 → 退化串行
        for (batch) |*s| {
            var job = Job{ .slot = s, .ctx = base_ctx, .parent_allocator = parent_allocator, .rid = rid };
            runJob(&job);
        }
        return;
    };
    defer parent_allocator.free(jobs);
    for (batch, 0..) |*s, k| jobs[k] = .{ .slot = s, .ctx = base_ctx, .parent_allocator = parent_allocator, .rid = rid };

    var threads = parent_allocator.alloc(?std.Thread, batch.len) catch {
        for (jobs) |*job| runJob(job);
        return;
    };
    defer parent_allocator.free(threads);
    for (threads) |*t| t.* = null;

    // 滑动窗口:最多 MAX_TOOL_CONCURRENCY 个并发。
    var started: usize = 0;
    while (started < jobs.len) {
        const window_end = @min(started + MAX_TOOL_CONCURRENCY, jobs.len);
        var k = started;
        while (k < window_end) : (k += 1) {
            threads[k] = std.Thread.spawn(.{}, runJob, .{&jobs[k]}) catch blk: {
                runJob(&jobs[k]); // spawn 失败 → 当场串行跑
                break :blk null;
            };
        }
        k = started;
        while (k < window_end) : (k += 1) {
            if (threads[k]) |t| t.join();
        }
        started = window_end;
    }
}
