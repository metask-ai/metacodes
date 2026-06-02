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

    log.infoId("agent", job.rid, "tool.exec start(par) name={s} id={s}", .{ s.name, s.id });
    const r = tools_mod.dispatch(&job_ctx, s.name, s.input) catch |err| {
        const code = if (err == error.UnknownTool) "UnknownTool" else @errorName(err);
        const tool_error = @import("tool_error.zig");
        // 错误 json 用父 allocator(逃逸 arena)。
        const ej = tool_error.errorToJson(code, "{s} failed with {s}", .{ s.name, @errorName(err) }, job.parent_allocator) catch null;
        s.content = ej;
        s.is_error = true;
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
    log.infoId("agent", job.rid, "tool.exec done(par) name={s} output_bytes={d} duration_ms={d}", .{ s.name, r.len, util_time.nowMs() - t_start });
    job.done = true;
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
        // 收集从 i 起连续的同安全性 run-slot 为一批。
        const safe = tools_mod.isConcurrencySafe(slots[i].name);
        var j = i;
        while (j < slots.len and slots[j].decision == .run and tools_mod.isConcurrencySafe(slots[j].name) == safe) : (j += 1) {}
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
