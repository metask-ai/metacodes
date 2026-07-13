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
    /// P0.4:该 slot 的结果已由流式预取(stream_prefetch)填好 → executeSlots 跳过,不重复执行。
    prefetched: bool = false,
};

/// 一个并发 job 的输入(safe 批用)。
const Job = struct {
    slot: *Slot,
    ctx: *const ToolContext, // 共享(只读字段 + 线程安全的 read_state)
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
    done: bool = false,
};

/// 单个工具执行的结果(所有 owned 字段挂 parent_allocator,逃逸内部 arena)。
pub const OneResult = union(enum) {
    /// 正常完成(成功或工具级错误)。
    done: struct { content: ?[]u8, is_error: bool, elapsed_ms: u64 },
    /// L3 挂起:工具发起 custom UI(error.UiPending)。kind/payload owned by parent_allocator。
    pending: struct { kind: ?[]u8, payload: ?[]u8, elapsed_ms: u64 },
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
) OneResult {
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
    const r = tools_mod.dispatch(&job_ctx, name, input) catch |err| {
        const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
        // L3:UiPending 是控制信号(非工具错误)——kind/payload dupe 到父 allocator 逃逸 arena。
        if (err == error.UiPending) {
            log.infoId("agent", rid, "tool.exec PENDING(par) name={s} id={s} kind={s}", .{ name, id, if (pending_req) |pr| pr.kind else "" });
            return .{ .pending = .{
                .kind = if (pending_req) |pr| parent_allocator.dupe(u8, pr.kind) catch null else null,
                .payload = if (pending_req) |pr| parent_allocator.dupe(u8, pr.payload_json) catch null else null,
                .elapsed_ms = elapsed,
            } };
        }
        const code = if (err == error.UnknownTool) "UnknownTool" else @errorName(err);
        const tool_error = @import("tool_error.zig");
        // 错误 json 用父 allocator(逃逸 arena)。工具填了 detail 用之,否则通用文案。
        // P0.6:UnknownTool 附可用工具清单(hermes 式引导),弱模型据此自纠而非空转烧 turn。
        const ej = if (err_detail) |d|
            tool_error.errorToJson(code, "{s}", .{d}, parent_allocator) catch null
        else if (err == error.UnknownTool) blk: {
            const names = tools_mod.availableToolNames(&job_ctx, parent_allocator) catch null;
            defer if (names) |nm| parent_allocator.free(nm);
            // 模糊建议(仅提示,不执行):有则加 "Did you mean 'X'?"。
            const guess = tools_mod.suggestToolName(&job_ctx, name);
            break :blk if (guess) |g|
                tool_error.errorToJson(code, "Tool '{s}' does not exist. Did you mean '{s}'? Available tools: {s}", .{ name, g, if (names) |nm| nm else "(unavailable)" }, parent_allocator) catch null
            else
                tool_error.errorToJson(code, "Tool '{s}' does not exist. Available tools: {s}", .{ name, if (names) |nm| nm else "(unavailable)" }, parent_allocator) catch null;
        } else tool_error.errorToJson(code, "{s} failed with {s}", .{ name, @errorName(err) }, parent_allocator) catch null;
        log.warnId("agent", rid, "tool.exec FAILED(par) name={s} err={s} duration_ms={d} input={s}", .{ name, @errorName(err), elapsed, input[0..@min(input.len, 200)] });
        return .{ .done = .{ .content = ej, .is_error = true, .elapsed_ms = elapsed } };
    };
    // dispatch 结果在 arena 里 → dupe 到父 allocator 逃逸;大结果落盘(超阈值 → preview+path)。
    var content: ?[]u8 = null;
    if (parent_allocator.dupe(u8, r) catch null) |o| {
        const storage = @import("../tools/tool_result_storage.zig");
        if (storage.maybePersist(parent_allocator, name, o, base_ctx.home_dir) catch null) |preview| {
            parent_allocator.free(o);
            content = preview;
        } else {
            content = o;
        }
    }
    const elapsed: u64 = @intCast(@max(util_time.nowMs() - t_start, 0));
    log.infoId("agent", rid, "tool.exec done(par) name={s} output_bytes={d} duration_ms={d}", .{ name, r.len, elapsed });
    return .{ .done = .{ .content = content, .is_error = false, .elapsed_ms = elapsed } };
}

fn runJob(job: *Job) void {
    const s = job.slot;
    switch (executeOne(job.ctx, s.name, s.input, s.id, job.parent_allocator, job.rid)) {
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
    }
    job.done = true;
}

/// per-slot 并发安全判定:在 isConcurrencySafeInput 之上叠加同步 Task 特例。
/// 同步 Task/Agent(非 run_in_background)各自 spawn 独立子 agent + 独立 TaskStore,
/// 唯一共享风险是 http.Client——agent.zig 同步路径用 registry.makeProvider 造 per-call
/// provider(独立 client)规避。故仅当有 agent_jobs(能造独立 client)时才允许 Task 并发,否则保守串行
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
    executeSlots(&slots, &ctx, a, .{ .bytes = [_]u8{'0'} ** 12 });
    // prefetched → 未执行 → content 仍是预填值(未被 UnknownTool 错误覆写)。
    try std.testing.expect(slots[0].content != null);
    try std.testing.expectEqualStrings("PREFETCHED_CONTENT", slots[0].content.?);
    try std.testing.expect(!slots[0].is_error);
}

test "executeOne:成功路径返回 done+content(与 executeSlots 同一入口)" {
    const a = std.testing.allocator;
    var ctx = tools_mod.ToolContext{ .allocator = a, .cwd_abs = "." };
    const r = executeOne(&ctx, "Glob", "{\"pattern\":\"*.zig\"}", "gid", a, .{ .bytes = [_]u8{'0'} ** 12 });
    switch (r) {
        .done => |d| {
            try std.testing.expect(!d.is_error);
            try std.testing.expect(d.content != null);
            if (d.content) |c| a.free(c);
        },
        .pending => try std.testing.expect(false),
    }
}

test "executeOne:UnknownTool → 富错误引导(prefetch/executeSlots 共享此路径)" {
    const a = std.testing.allocator;
    var ctx = tools_mod.ToolContext{ .allocator = a };
    const r = executeOne(&ctx, "NoSuchTool", "{}", "x", a, .{ .bytes = [_]u8{'0'} ** 12 });
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
        .pending => try std.testing.expect(false),
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
