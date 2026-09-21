//! TaskBatch 工具(P1.2:参数化批量 agent fan-out)。
//!
//! 动机:cc-zig 的并发执行引擎早已完备——模型在一个 turn 里发 N 个 Task 块,executeSlots 的
//! runConcurrentBatch 就真并发跑(≤8 线程、各持独立 provider、保序回填)。缺的只是**单次调用的
//! 参数化 fan-out 符号入口**:对一组输入各起一个同构 subagent。TaskBatch 补这个:一个 prompt 模板
//! + 一个 items 数组 → 每个 item 展开模板成 prompt → 各起一个 subagent。相比让模型手写 N 份重复
//! Task JSON:① 保证 fan-out 一定发生(工具契约强制,不靠模型自觉);② 省 N 份重复 prompt 的 token;
//! ③ 天然表达"一批输入各一 agent"的语义。
//!
//! **对齐 codex spawn_agents_on_csv 的核心**(模板展开 `{key}` + 并发 + 结果聚合),但**故意不移植**其
//! SQLite 持久化 / CSV I/O / 崩溃恢复——那些与 cc-zig 既有 AgentJobRegistry 重复且对内存内批处理是
//! 过度工程。结果内联返回(N 由模型控制,有上限);持久化/后台轮询走既有 run_in_background Task。
//!
//! **执行**:有 registry(ctx.agent_jobs)→ 每 item 独立 OwnedProvider + 独立线程并发(≤8,滑动窗口),
//! 各用 c_allocator(线程安全,App arena 非线程安全)跑 spawnAgentSink,结果 dupe 回后聚合。
//! 无 registry(headless)→ 主线程串行(用 ctx 的 provider),行为一致只是不并发。
//! per-item deadline watchdog(MAX_ITEM_SECONDS=300)防单个子 agent 跑飞拖垮整批 join。
//!
//! **已知差距(未实现,登记非沉默)**:
//!  - **结果落文件/summary 模式**:codex 结果落 CSV 只回 summary 防撑爆父 context;本实现 N 个 final_text
//!    会先在 TaskBatch 聚合器内构造完整返回；随后统一投影能把超限结果保存到 Session CAS 并经
//!    ReadArtifact 完整恢复，所以 Conversation 不再丢正文，但生成期峰值仍是 O(聚合结果)。未做
//!    per-item byte-zero spool/summary 模式(P1 待办)。
//!  - **output_schema 强制**:codex 每 worker 结果按 JSON Schema 校验;本实现不校验(schema 无此字段)。
//!  - 串行(headless)路径无 watchdog;并发路径的 watchdog 在 deadline / 父 abort 时**同时调
//!    provider.cancel**(shutdown 连接,让卡在单次网络读里的子 agent 立即返回),client 层另有
//!    空闲监视(RequestAbortRegistry idle limit)兜住对端沉默——2026-09-10 前两者都没有,一个
//!    ESTABLISHED 却不再发字节的连接让整批 join 永远等下去。
//!  - **id_column 去重 / report 工具回填 / SQLite 持久化 / CSV I/O / 崩溃恢复**:故意不移植(与既有
//!    AgentJobRegistry 重复,内存内批处理不需要)。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const subagent = @import("../core/subagent.zig");
const util_json = @import("../util/json.zig");
const utf8 = @import("../util/utf8.zig");
const filter_mod = @import("../agents/filter.zig");
const provider_mod = @import("../api/provider.zig");
const client_mod = @import("../client.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const writer_backend = @import("../core/writer_backend.zig");
const log = @import("../util/log.zig");
const agent_tool = @import("agent.zig");

const MAX_BATCH_ITEMS: usize = 32; // 防滥用:单次批量上限
const MAX_BATCH_CONCURRENCY: usize = 8; // 与 tool_exec MAX_TOOL_CONCURRENCY 一致
const MAX_ITEM_SECONDS: u64 = 300; // per-item 墙钟上限:5 分钟。防单个子 agent 跑飞拖垮整批 join。
const PER_ITEM_TEXT_CAP: usize = 4096; // 单项 final_text 内联上限(超出留头 + truncated 标记),防父 context 膨胀
const util_time = @import("../util/time.zig");

/// 每个 item 的作业(线程共享读 + 各自写结果)。
const BatchJob = struct {
    idx: usize,
    prompt: []const u8, // c_allocator owned(展开后)
    // 共享只读:
    tool_defs: []const @import("../json.zig").ToolDefinition,
    perm: *const @import("../permission.zig").PermissionContext,
    abort: ?*const AbortSignal,
    opts: subagent.SpawnOptions,
    /// per-item 独立 provider,**主线程串行造好**再交给线程(makeProvider 用 reg.allocator,非线程
    /// 安全——绝不能在 worker 线程里造。null = 造 provider 失败,该 item 记 error 跳过)。
    owned: ?@import("../api/provider_factory.zig").OwnedProvider = null,
    /// per-item abort:watchdog 据 deadline / 父 abort 触发(worker 传给 spawnAgentSink)。
    abort_sig: AbortSignal = AbortSignal.init(),
    /// watchdog 已对本 job 调过 provider.cancel(只调一次;shutdown 幂等但别刷日志)。
    cancel_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // 0=未启动;watchdog 读
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // worker 结束置;watchdog 读
    // 输出(runBatchJob 写):
    result_text: ?[]u8 = null, // c_allocator owned
    turns: u32 = 0,
    tool_calls: u32 = 0,
    stop_reason: []const u8 = "error",
    err_name: ?[]const u8 = null,
};

fn runBatchJob(job: *BatchJob) void {
    defer job.done.store(true, .release); // watchdog 据此判该 item 结束
    const a = std.heap.c_allocator; // 线程安全(App arena 非线程安全)
    var owned = job.owned orelse {
        job.err_name = "ProviderUnavailable";
        return;
    };
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    // 用 per-item abort_sig(watchdog 据 deadline/父 abort 触发),而非共享 ctx.abort。
    const r = subagent.spawnAgentSink(a, owned.provider(), owned.anthropicClient(), job.tool_defs, job.perm, &job.abort_sig, job.prompt, job.opts, &be) catch |e| {
        job.err_name = @errorName(e);
        return;
    };
    defer r.deinit();
    recordResult(job, r);
}

/// per-item deadline watchdog:监控每个已启动未完成 job,超 MAX_ITEM_SECONDS 或父 abort → 触发
/// 该 job 的 abort_sig(agent_loop 在 turn 边界检查 → 停)**并 cancel 它在飞的请求**(注册表
/// shutdown 连接 → 卡在单次网络读里的线程立即返回,不必等下一个事件)。所有 job done 即退出。
const Watchdog = struct {
    jobs: []BatchJob,
    parent_abort: ?*const AbortSignal,
    deadline_ms: u64 = MAX_ITEM_SECONDS * 1000, // 可注入(测试用小值);默认 300s
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// 纯判定(可测):某已启动未完成 job 此刻是否该被 abort。started==0(未启动)→ false。
/// 父 abort → true;运行时长超 deadline → true。now/started 单位 ms(nowMs 是 MONOTONIC)。
fn shouldAbortJob(started_ms: u64, now_ms: u64, parent_aborted: bool, deadline_ms: u64) bool {
    if (started_ms == 0) return false; // 未启动:不计 deadline
    if (parent_aborted) return true;
    return (now_ms - started_ms) > deadline_ms;
}

fn watchdogMain(wd: *Watchdog) void {
    const deadline_ms = wd.deadline_ms;
    while (!wd.stop.load(.acquire)) {
        const parent_aborted = if (wd.parent_abort) |pa| pa.isAborted() else false;
        var all_done = true;
        const now: u64 = @intCast(util_time.nowMs());
        for (wd.jobs) |*j| {
            if (j.done.load(.acquire)) continue;
            all_done = false;
            const started = j.started_ms.load(.acquire);
            if (shouldAbortJob(started, now, parent_aborted, deadline_ms)) {
                // reason 要如实:父 abort → 透传父的 reason(user_ctrl_c vs user_interrupt 语义不同,
                // 见 abort.zig);纯超时才 .timeout。否则 recordResult 会把 Ctrl+C 的 item 谎报成 "timeout"。
                const why: @import("../util/abort.zig").Reason =
                    if (parent_aborted) (if (wd.parent_abort) |pa| pa.reason() else .timeout) else .timeout;
                j.abort_sig.abort(why);
                // 置标志只在事件之间被看到;卡在 readv 里的线程要靠 shutdown 连接叫醒。
                // owned 由主线程造、join 后才 deinit,worker 未 done 时它一定活着。
                if (!j.cancel_sent.swap(true, .acq_rel)) {
                    if (j.owned) |*o| o.provider().cancel(&j.abort_sig);
                }
            }
        }
        if (all_done) break;
        util_time.sleepMs(200);
    }
}

/// 把子 agent 结果写进 job:失败 stop_reason(api_error/aborted)记 error 不算 completed;
/// dupe OOM 也记 error(别把丢数据装成成功)。
fn recordResult(job: *BatchJob, r: subagent.SubagentResult) void {
    if (isFailureStop(r.stop_reason)) {
        // 超时被 watchdog 砍 vs 用户取消:agent_loop 只返 .aborted 不透传 reason,查 abort_sig.reason()
        // 还原成清楚的 err_name("timeout" vs "aborted"),debug 时分得清。
        if (r.stop_reason == .aborted and job.abort_sig.reason() == .timeout) {
            job.err_name = "timeout";
        } else {
            job.err_name = @tagName(r.stop_reason);
        }
        return;
    }
    if (std.heap.c_allocator.dupe(u8, r.final_text)) |t| {
        job.result_text = t;
        job.turns = r.turns;
        job.tool_calls = r.tool_calls;
        job.stop_reason = @tagName(r.stop_reason);
    } else |_| {
        job.err_name = "OutOfMemory";
    }
}

/// 子 agent 的终止是否算失败。**exhaustive switch**:编译器逼后来人处理 StopReason 新增变体
/// (别用 `==` 漏网——哪天给 batch subagent 接上 requester,suspended 不能被谎报成 completed)。
fn isFailureStop(sr: @import("../core/agent_loop.zig").StopReason) bool {
    return switch (sr) {
        .api_error, .aborted, .tool_error, .suspended, .max_tokens_exhausted => true, // 出错/中断/挂起/续写耗尽未完成 → 失败
        .end_turn, .max_turns, .tool_loop, .backgrounded, .budget => false, // 跑到终止,有产出 → 完成
    };
}

/// 从 tool_defs 里剥掉指定名字的工具(不改原集,返回新 slice;caller free)。
fn stripTool(a: std.mem.Allocator, defs: []const @import("../json.zig").ToolDefinition, name: []const u8) ![]const @import("../json.zig").ToolDefinition {
    var out = std.ArrayList(@import("../json.zig").ToolDefinition).empty;
    errdefer out.deinit(a);
    for (defs) |d| {
        if (!std.mem.eql(u8, d.name, name)) try out.append(a, d);
    }
    return out.toOwnedSlice(a);
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    if (ctx.agent_depth >= agent_tool.MAX_AGENT_DEPTH) return error.AgentDepthExceeded;
    const tool_defs = ctx.tool_defs orelse return error.AgentUnavailable;
    const perm = ctx.permission_ctx orelse return error.AgentUnavailable;

    // 解析整个 args 为 JSON(需要 items 数组,子串提取搞不定)。
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args, .{}) catch return error.InvalidBatchArgs;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidBatchArgs;

    const template = switch (root.object.get("prompt_template") orelse return error.MissingPromptTemplate) {
        .string => |s| s,
        else => return error.MissingPromptTemplate,
    };
    const items_val = root.object.get("items") orelse return error.MissingItems;
    if (items_val != .array) return error.MissingItems;
    const items = items_val.array.items;
    if (items.len == 0) return error.EmptyItems;
    if (items.len > MAX_BATCH_ITEMS) {
        setDetail(ctx, "TaskBatch: {d} items exceeds max {d}. Split into smaller batches.", .{ items.len, MAX_BATCH_ITEMS });
        return error.TooManyItems;
    }

    const subagent_type = switch (root.object.get("subagent_type") orelse std.json.Value{ .string = "general-purpose" }) {
        .string => |s| s,
        else => "general-purpose",
    };
    // max_turns 上限 100:防 `max_turns:999` 配合 fan-out 烧穿账单(schema 广告 default 20)。
    const max_turns: u32 = switch (root.object.get("max_turns") orelse std.json.Value{ .integer = 20 }) {
        .integer => |i| if (i > 0 and i <= 100) @intCast(i) else 20,
        else => 20,
    };

    // 解析 subagent def + filter tool_defs(一次,所有 item 共享)。
    var def_opt: ?*const @import("../agents/def.zig").AgentDef = null;
    if (ctx.agents) |as| def_opt = as.find(subagent_type) orelse as.find("general-purpose");
    if (def_opt == null and ctx.agents != null) {
        log.warn("taskbatch", "subagent_type '{s}' 未找到且无 general-purpose fallback → subagent 拿父全量工具", .{subagent_type});
    }
    var def_filtered = tool_defs;
    var filter_owned: ?[]@import("../json.zig").ToolDefinition = null;
    defer if (filter_owned) |f| ctx.allocator.free(f);
    if (def_opt) |d| {
        const filtered = try filter_mod.filterToolDefs(ctx.allocator, tool_defs, d);
        filter_owned = filtered;
        def_filtered = filtered;
    }

    // **关键(嵌套 fan-out 预算)**:从 subagent 工具集里剥掉 TaskBatch —— 否则每个 worker 的
    // subagent 又能 fan-out,depth 3 下 8×8×8=512 个并发 agent 把机器跑跪。剥掉后 TaskBatch
    // fan-out 至多 1 层(顶层这次调用),彻底封死指数放大。
    const sub_tool_defs = try stripTool(ctx.allocator, def_filtered, "TaskBatch");
    defer ctx.allocator.free(sub_tool_defs);

    const shared_opts = subagent.SpawnOptions{
        .max_turns = max_turns,
        .session = ctx.session,
        .agent_depth = ctx.agent_depth + 1,
        .dyn_registry = ctx.dyn_registry,
        .tool_defs_override = sub_tool_defs, // 始终 override(含剥 TaskBatch);spawnAgentSink 内 override 赢
        .host_services = if (ctx.host_services) |hs| hs.skillOnly() else null,
        .tool_observer = ctx.tool_observer,
        .execution_boundary = ctx.execution_boundary,
        .project_rule_gate = ctx.project_rule_gate,
        .project_dir = ctx.project_dir,
        .kg = ctx.kg,
        .kg_projects_dir = ctx.kg_projects_dir,
        .artifact_root = ctx.artifact_root,
        .tool_result_metrics = ctx.tool_result_metrics,
        .file_change_journal = ctx.file_change_journal,
    };

    // 展开每个 item 的 prompt(c_allocator owned;并发线程与串行都用)。
    const c_a = std.heap.c_allocator;
    var jobs = try ctx.allocator.alloc(BatchJob, items.len);
    defer ctx.allocator.free(jobs);
    var built: usize = 0;
    defer {
        // 清理所有 c_allocator owned prompt/result。
        var k: usize = 0;
        while (k < built) : (k += 1) {
            c_a.free(jobs[k].prompt);
            if (jobs[k].result_text) |t| c_a.free(t);
        }
    }
    for (items, 0..) |item, i| {
        const expanded = expandTemplate(c_a, template, item) catch return error.OutOfMemory;
        jobs[i] = .{
            .idx = i,
            .prompt = expanded,
            .tool_defs = sub_tool_defs, // 剥了 TaskBatch 的集(与 opts.tool_defs_override 一致,消歧义)
            .perm = perm,
            .abort = ctx.abort,
            .opts = shared_opts,
            // .owned 默认 null;并发路径主线程填,串行路径不用。
        };
        built += 1;
    }

    // 执行:有 registry → 并发(滑动窗口 ≤ MAX);否则串行(主线程,用 ctx.api_client)。
    if (ctx.agent_jobs) |reg| {
        // **主线程串行**造好每个 item 的独立 provider(makeProvider 用 reg.allocator 非线程安全,
        // 绝不能在 worker 线程里造)。造好后交给线程只读使用;join 后统一 deinit。
        for (jobs) |*j| {
            j.owned = reg.makeProvider() catch null; // 失败 → runBatchJob 记 ProviderUnavailable
        }
        defer for (jobs) |*j| if (j.owned) |*o| o.deinit();
        try runConcurrent(jobs, ctx.abort);
    } else {
        try runSerial(ctx, jobs);
    }

    return buildResult(ctx.allocator, jobs);
}

/// 滑动窗口并发:同时最多 MAX_BATCH_CONCURRENCY 个线程。带 deadline watchdog(超时/父 abort → 停该 job)。
fn runConcurrent(jobs: []BatchJob, parent_abort: ?*const AbortSignal) !void {
    var wd = Watchdog{ .jobs = jobs, .parent_abort = parent_abort };
    // watchdog 是父 abort → job.abort_sig 的**唯一**中继(worker 传 &job.abort_sig 而非 ctx.abort)。
    // spawn 失败(近乎不可能)→ 降级:无超时保护 + 在飞子 agent 不再响应父 abort。低危,记一笔。
    const wd_thread: ?std.Thread = std.Thread.spawn(.{}, watchdogMain, .{&wd}) catch null;
    defer if (wd_thread) |t| {
        wd.stop.store(true, .release);
        t.join();
    };

    var next: usize = 0;
    while (next < jobs.len) {
        const batch_end = @min(next + MAX_BATCH_CONCURRENCY, jobs.len);
        var threads: [MAX_BATCH_CONCURRENCY]?std.Thread = .{null} ** MAX_BATCH_CONCURRENCY;
        for (next..batch_end) |i| {
            jobs[i].started_ms.store(@intCast(util_time.nowMs()), .release); // watchdog deadline 起点
            threads[i - next] = std.Thread.spawn(.{}, runBatchJob, .{&jobs[i]}) catch blk: {
                runBatchJob(&jobs[i]); // spawn 失败 → 当场同步跑
                break :blk null;
            };
        }
        for (next..batch_end) |i| {
            if (threads[i - next]) |t| t.join();
        }
        next = batch_end;
    }
}

/// 串行(headless,无独立 client):主线程逐个用 ctx 的 provider 跑。
fn runSerial(ctx: *const ToolContext, jobs: []BatchJob) !void {
    const api_client = ctx.api_client orelse return error.AgentUnavailable;
    const prov = ctx.provider orelse api_client.provider();
    for (jobs) |*j| {
        var wb = writer_backend.WriterBackend.initNull();
        const be = wb.backend();
        const r = subagent.spawnAgentSink(ctx.allocator, prov, api_client, j.tool_defs, j.perm, j.abort, j.prompt, j.opts, &be) catch |e| {
            j.err_name = @errorName(e);
            continue;
        };
        defer r.deinit();
        recordResult(j, r);
    }
}

/// 展开模板:`{key}` → item[key] 的字符串值;`{{`/`}}` → 字面 `{`/`}`。未知 key 保留原样。
fn expandTemplate(a: std.mem.Allocator, template: []const u8, item: std.json.Value) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try out.append(a, '{');
                i += 2;
                continue;
            }
            // 找闭合 }。
            const close = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                try out.append(a, c);
                i += 1;
                continue;
            };
            const key = template[i + 1 .. close];
            if (item == .object) {
                if (item.object.get(key)) |v| {
                    try appendJsonValueAsString(a, &out, v);
                    i = close + 1;
                    continue;
                }
            }
            // 未知 key:原样保留 {key}。
            try out.appendSlice(a, template[i .. close + 1]);
            i = close + 1;
            continue;
        }
        if (c == '}' and i + 1 < template.len and template[i + 1] == '}') {
            try out.append(a, '}');
            i += 2;
            continue;
        }
        try out.append(a, c);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn appendJsonValueAsString(a: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .string => |s| try out.appendSlice(a, s),
        .integer => |n| try out.print(a, "{d}", .{n}),
        .float => |f| try out.print(a, "{d}", .{f}),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .null => {},
        else => {}, // 嵌套对象/数组:跳过(模板占位应引用标量列)
    }
}

fn buildResult(allocator: std.mem.Allocator, jobs: []const BatchJob) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var completed: usize = 0;
    var failed: usize = 0;
    try out.writer.writeAll("{\"results\":[");
    for (jobs, 0..) |j, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"index\":{d},", .{j.idx});
        if (j.err_name) |e| {
            failed += 1;
            try out.writer.writeAll("\"error\":");
            try util_json.writeJsonString(&out.writer, e);
            try out.writer.writeByte('}');
        } else {
            completed += 1;
            // per-item final_text 截断:防 N × 长输出撑爆父 context。单项 >PER_ITEM_TEXT_CAP 留头 + 标记。
            const full = j.result_text orelse "";
            const shown = utf8.pagePrefix(full, PER_ITEM_TEXT_CAP);
            const truncated = shown.len < full.len;
            try out.writer.writeAll("\"final_text\":");
            try util_json.writeJsonString(&out.writer, shown);
            if (truncated) try out.writer.print(",\"truncated\":true,\"full_len\":{d}", .{full.len});
            try out.writer.print(",\"turns\":{d},\"tool_calls\":{d},\"stop_reason\":\"{s}\"}}", .{ j.turns, j.tool_calls, j.stop_reason });
        }
    }
    try out.writer.print("],\"total\":{d},\"completed\":{d},\"failed\":{d}}}", .{ jobs.len, completed, failed });
    return try out.toOwnedSlice();
}

fn setDetail(ctx: *const ToolContext, comptime fmt: []const u8, args: anytype) void {
    if (ctx.error_detail) |slot| {
        slot.* = std.fmt.allocPrint(ctx.allocator, fmt, args) catch null;
    }
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;

fn parseItem(a: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}

test "expandTemplate: {key} 替换 + {{ }} 转义 + 未知 key 保留" {
    const a = testing.allocator;
    var p = try parseItem(a, "{\"name\":\"Alice\",\"n\":3}");
    defer p.deinit();
    const out = try expandTemplate(a, "Hi {name}, count={n}, literal {{brace}}, unknown {missing}", p.value);
    defer a.free(out);
    try testing.expectEqualStrings("Hi Alice, count=3, literal {brace}, unknown {missing}", out);
}

test "expandTemplate: 标量类型(int/bool/float)转字符串" {
    const a = testing.allocator;
    var p = try parseItem(a, "{\"i\":42,\"b\":true,\"f\":1.5}");
    defer p.deinit();
    const out = try expandTemplate(a, "{i}/{b}/{f}", p.value);
    defer a.free(out);
    try testing.expectEqualStrings("42/true/1.5", out);
}

test "接线: TaskBatch 在 registry + 权限类别(spawn=execute 风险)" {
    const tools = @import("../tools.zig");
    try testing.expect(tools.getTool("TaskBatch") != null);
}

test "buildResult: 长 final_text 截断 + truncated 标记(防父 context 膨胀)" {
    const a = testing.allocator;
    const long = try a.alloc(u8, PER_ITEM_TEXT_CAP + 500);
    defer a.free(long);
    @memset(long, 'x');
    var jobs = [_]BatchJob{.{
        .idx = 0,
        .prompt = "",
        .tool_defs = &.{},
        .perm = undefined,
        .abort = null,
        .opts = .{ .session = @import("../core/session_id.zig").SessionId.single },
        .result_text = long,
        .stop_reason = "end_turn",
    }};
    const res = try buildResult(a, &jobs);
    defer a.free(res);
    try testing.expect(std.mem.indexOf(u8, res, "\"truncated\":true") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"completed\":1") != null);
    // 展示的 text 不超过 cap(截断真发生)。
    const marker = "\"full_len\":";
    try testing.expect(std.mem.indexOf(u8, res, marker) != null);
}

// 构造一个 watchdog 测试用的最小 job(worker 不跑,只被 watchdog 读 done/started_ms/abort_sig)。
fn wdTestJob(idx: usize) BatchJob {
    return .{ .idx = idx, .prompt = "", .tool_defs = &.{}, .perm = undefined, .abort = null, .opts = .{ .session = @import("../core/session_id.zig").SessionId.single } };
}

/// watchdog 测试等待轮数(每轮 100ms):10s 上限,见下方注释。
const WD_TEST_WAIT_ROUNDS: usize = 100;

test "watchdog 线程真触发超时 abort(started_ms 远早于 now → 超 deadline)" {
    var jobs = [_]BatchJob{wdTestJob(0)};
    // started_ms=1(单调钟 1ms 处启动,now 是当前单调时间,elapsed 远超 300s deadline)→ 必被砍。
    jobs[0].started_ms.store(1, .release);
    var wd = Watchdog{ .jobs = &jobs, .parent_abort = null };
    const t = try std.Thread.spawn(.{}, watchdogMain, .{&wd});
    // 轮询等 watchdog 把 abort_sig 砍掉(≤200ms 一轮)。上限 10s:只决定"真挂了"时多久
    // 报错,正常路径一两轮就结束;2s 在满载的托管 runner 上不够(PR #139 Linux 实测 flake)。
    var waited: usize = 0;
    while (!jobs[0].abort_sig.isAborted() and waited < WD_TEST_WAIT_ROUNDS) : (waited += 1) {
        util_time.sleepMs(100);
    }
    // 让 watchdog 退出。
    jobs[0].done.store(true, .release);
    wd.stop.store(true, .release);
    t.join();
    try testing.expect(jobs[0].abort_sig.isAborted());
    try testing.expectEqual(@import("../util/abort.zig").Reason.timeout, jobs[0].abort_sig.reason());
}

test "watchdog 线程中继父 abort(未超 deadline 但父 abort → 砍 job)" {
    var jobs = [_]BatchJob{wdTestJob(0)};
    jobs[0].started_ms.store(@intCast(util_time.nowMs()), .release); // 刚启动,远未超时
    var parent = AbortSignal.init();
    var wd = Watchdog{ .jobs = &jobs, .parent_abort = &parent };
    const t = try std.Thread.spawn(.{}, watchdogMain, .{&wd});
    parent.abort(.user_ctrl_c); // 触发父 abort
    var waited: usize = 0;
    while (!jobs[0].abort_sig.isAborted() and waited < WD_TEST_WAIT_ROUNDS) : (waited += 1) {
        util_time.sleepMs(100);
    }
    jobs[0].done.store(true, .release);
    wd.stop.store(true, .release);
    t.join();
    try testing.expect(jobs[0].abort_sig.isAborted()); // 父 abort 经 watchdog 中继到 job
    // reason 必须如实透传父的(user_ctrl_c),不能被误标 .timeout(否则 recordResult 谎报 "timeout")。
    try testing.expectEqual(@import("../util/abort.zig").Reason.user_ctrl_c, jobs[0].abort_sig.reason());
}

test "shouldAbortJob: deadline / 父 abort / 未启动 判定(watchdog 核心逻辑)" {
    const deadline: u64 = 300_000; // 300s
    // 未启动(started=0)→ 永不 abort。
    try testing.expect(!shouldAbortJob(0, 1_000_000, false, deadline));
    try testing.expect(!shouldAbortJob(0, 1_000_000, true, deadline)); // 未启动即便父 abort 也不动
    // 运行中未超时 → false。
    try testing.expect(!shouldAbortJob(1_000_000, 1_100_000, false, deadline)); // 100s < 300s
    // 运行中超时 → true。
    try testing.expect(shouldAbortJob(1_000_000, 1_400_000, false, deadline)); // 400s > 300s
    // 父 abort(已启动)→ 立即 true(不等 deadline)。
    try testing.expect(shouldAbortJob(1_000_000, 1_100_000, true, deadline));
    // 边界:恰好 deadline(不超)→ false。
    try testing.expect(!shouldAbortJob(1_000_000, 1_300_000, false, deadline));
}

test "isFailureStop: exhaustive 覆盖 StopReason 10 变体" {
    const SR = @import("../core/agent_loop.zig").StopReason;
    try testing.expect(isFailureStop(.api_error));
    try testing.expect(isFailureStop(.aborted));
    try testing.expect(isFailureStop(.tool_error));
    try testing.expect(isFailureStop(.suspended));
    try testing.expect(isFailureStop(.max_tokens_exhausted));
    try testing.expect(!isFailureStop(.end_turn));
    try testing.expect(!isFailureStop(.max_turns));
    try testing.expect(!isFailureStop(.tool_loop));
    try testing.expect(!isFailureStop(.backgrounded));
    try testing.expect(!isFailureStop(.budget));
    _ = SR;
}

test "stripTool: 从 subagent 工具集剥掉 TaskBatch(防嵌套指数 fan-out)" {
    const a = testing.allocator;
    const Def = @import("../json.zig").ToolDefinition;
    const defs = [_]Def{
        .{ .name = "TaskBatch", .description = "", .input_schema = .{ .type = "object" } },
        .{ .name = "Read", .description = "", .input_schema = .{ .type = "object" } },
        .{ .name = "Bash", .description = "", .input_schema = .{ .type = "object" } },
    };
    const stripped = try stripTool(a, &defs, "TaskBatch");
    defer a.free(stripped);
    try testing.expectEqual(@as(usize, 2), stripped.len);
    for (stripped) |d| try testing.expect(!std.mem.eql(u8, d.name, "TaskBatch"));
    // Read/Bash 仍在。
    var has_read = false;
    for (stripped) |d| if (std.mem.eql(u8, d.name, "Read")) {
        has_read = true;
    };
    try testing.expect(has_read);
}
