//! 流式工具预取(P0.4:streaming tool execution 的安全子集)。
//!
//! **动机**:模型一边流式产出 assistant 文本/工具块,一边我们已收到 tool_use_start 事件。旧版把所有
//! tool_use 攒到流结束再统一 executeSlots——对"多工具 + 大 Read"的长回合,首个工具本可在流还在跑时
//! 就启动。cc 的 StreamingToolExecutor / codex 的 in-flight futures 都证明边流边执行是核心能力。
//!
//! **安全子集**:只预取**纯只读工具**(Read/Grep/Glob)——无副作用、并发安全、权限 auto-allow、无
//! PreToolUse hook 匹配。这类工具"提前跑或丢弃"都无害,故预取不改动权限/提交/执行主管线(风险为零):
//!   - tool_use_start 到达 → 若可预取 → 开线程用 dispatch 跑,结果按 tool_use id 存;
//!   - 流结束后 executeSlots 处理该工具时 → 若有预取结果 → 直接用,不重复执行;
//!   - 预取失败/未用(权限实际拒/plan 模式)→ 丢弃,executeSlots 正常跑(fallback)。
//!
//! 每个预取线程独立 ArenaAllocator(规避 GPA 非线程安全),结果 dupe 回父 allocator 逃逸。

const std = @import("std");
const tools_mod = @import("../tools.zig");
const ToolContext = tools_mod.ToolContext;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");

/// 可预取的纯只读工具白名单。副作用工具(Bash/Write/Edit/Task…)绝不进。
pub fn isPrefetchable(name: []const u8) bool {
    return std.mem.eql(u8, name, "Read") or
        std.mem.eql(u8, name, "Grep") or
        std.mem.eql(u8, name, "Glob");
}

const Entry = struct {
    id: []const u8, // borrowed(指向 tool_uses 里的 id;预取 take 前有效)
    thread: ?std.Thread = null,
    content: ?[]u8 = null, // owned by parent allocator(dispatch 结果 dupe 出 arena)
    is_error: bool = false,
    elapsed_ms: u64 = 0,
    taken: bool = false, // 已被 executeSlots 取走(所有权转移)
};

const Job = struct {
    entry: *Entry,
    ctx: *const ToolContext,
    name: []const u8, // borrowed
    input: []const u8, // borrowed
    parent_allocator: std.mem.Allocator,
};

fn runJob(job: *Job) void {
    const t_start = util_time.nowMs();
    var arena = std.heap.ArenaAllocator.init(job.parent_allocator);
    defer arena.deinit();
    var job_ctx = job.ctx.*;
    job_ctx.allocator = arena.allocator();
    var err_detail: ?[]const u8 = null;
    job_ctx.error_detail = &err_detail;
    const r = tools_mod.dispatch(&job_ctx, job.name, job.input) catch |err| {
        const tool_error = @import("tool_error.zig");
        const code = @errorName(err);
        job.entry.content = tool_error.errorToJson(code, "{s} failed with {s}", .{ job.name, code }, job.parent_allocator) catch null;
        job.entry.is_error = true;
        job.entry.elapsed_ms = @intCast(@max(util_time.nowMs() - t_start, 0));
        return;
    };
    // 大结果落盘(与 tool_exec 一致):超阈值 → preview+path。
    const owned = job.parent_allocator.dupe(u8, r) catch null;
    if (owned) |o| {
        const storage = @import("../tools/tool_result_storage.zig");
        if (storage.maybePersist(job.parent_allocator, job.name, o, job.ctx.home_dir) catch null) |preview| {
            job.parent_allocator.free(o);
            job.entry.content = preview;
        } else {
            job.entry.content = o;
        }
    }
    job.entry.is_error = false;
    job.entry.elapsed_ms = @intCast(@max(util_time.nowMs() - t_start, 0));
}

pub const Prefetch = struct {
    allocator: std.mem.Allocator,
    /// **堆分配的 Entry 指针**:后续 start() 追加不会搬移已有 Entry(运行中的线程持 `job.entry` 指针,
    /// 若用值切片,ArrayList 扩容会让在飞线程写进已释放内存——多工具回合的悬垂 UAF)。
    entries: std.ArrayList(*Entry) = .empty,
    jobs: std.ArrayList(*Job) = .empty,

    pub fn init(allocator: std.mem.Allocator) Prefetch {
        return .{ .allocator = allocator };
    }

    /// 开一个预取线程执行 (name,input),结果按 id 存。ctx 必须活过整个流(基于 turn 作用域的 ctx)。
    /// spawn 失败 → 静默跳过(该工具流末正常执行,无害)。
    pub fn start(self: *Prefetch, ctx: *const ToolContext, id: []const u8, name: []const u8, input: []const u8) void {
        const entry = self.allocator.create(Entry) catch return;
        entry.* = .{ .id = id };
        self.entries.append(self.allocator, entry) catch {
            self.allocator.destroy(entry);
            return;
        };
        const job = self.allocator.create(Job) catch return; // entry 已入表,deinit 会收
        job.* = .{ .entry = entry, .ctx = ctx, .name = name, .input = input, .parent_allocator = self.allocator };
        self.jobs.append(self.allocator, job) catch {
            self.allocator.destroy(job);
            return;
        };
        entry.thread = std.Thread.spawn(.{}, runJob, .{job}) catch blk: {
            runJob(job); // spawn 失败 → 当场同步跑(仍能用结果)
            break :blk null;
        };
    }

    /// 取某 id 的预取结果(join 线程)。有则返回 owned content(转移所有权,调用方 free);
    /// 无该 id / 已取走 → null(调用方正常执行)。
    pub fn take(self: *Prefetch, id: []const u8) ?struct { content: ?[]u8, is_error: bool, elapsed_ms: u64 } {
        for (self.entries.items) |e| {
            if (e.taken) continue;
            if (!std.mem.eql(u8, e.id, id)) continue;
            if (e.thread) |t| {
                t.join();
                e.thread = null;
            }
            e.taken = true;
            const content = e.content;
            e.content = null; // 所有权转移给调用方
            return .{ .content = content, .is_error = e.is_error, .elapsed_ms = e.elapsed_ms };
        }
        return null;
    }

    /// join 所有在飞线程 + 释放未取走结果(**幂等**:thread/content 置 null,可反复调)。
    /// **必须在释放 tool_uses(线程 borrow 其 id/name/input 字节)之前调**——否则在飞的 Read/Grep
    /// 线程会读已释放内存(Linus HIGH-1 UAF)。abort / stream-error 早退分支显式调它。
    pub fn joinAll(self: *Prefetch) void {
        for (self.entries.items) |e| {
            if (e.thread) |t| {
                t.join();
                e.thread = null;
            }
            if (!e.taken) {
                if (e.content) |c| self.allocator.free(c);
                e.content = null;
            }
        }
    }

    /// join(幂等)+ 释放 jobs/entries。turn 末 defer 调。
    pub fn deinit(self: *Prefetch) void {
        self.joinAll();
        for (self.entries.items) |e| self.allocator.destroy(e);
        for (self.jobs.items) |j| self.allocator.destroy(j);
        self.jobs.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }
};

test "isPrefetchable whitelist" {
    try std.testing.expect(isPrefetchable("Read"));
    try std.testing.expect(isPrefetchable("Grep"));
    try std.testing.expect(isPrefetchable("Glob"));
    try std.testing.expect(!isPrefetchable("Bash"));
    try std.testing.expect(!isPrefetchable("Write"));
    try std.testing.expect(!isPrefetchable("Task"));
}

test "Prefetch start+take:真 builtin Glob 结果正确落地(执行路径端到端)" {
    const a = std.testing.allocator;
    var p = Prefetch.init(a);
    defer p.deinit();
    // 最小 ctx:Glob 只需 cwd。cwd_abs="." → 匹配当前目录(测试从 cc-zig 根跑,有 *.zig)。
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "." };
    p.start(&ctx, "gid", "Glob", "{\"pattern\":\"*.zig\"}");
    const r = p.take("gid");
    try std.testing.expect(r != null);
    try std.testing.expect(r.?.content != null); // 预取线程真跑了 Glob 并存了结果
    if (r.?.content) |c| a.free(c); // take 转移所有权,调用方 free
    // 再取同 id → null(已取走);随机 id → null。
    try std.testing.expect(p.take("gid") == null);
    try std.testing.expect(p.take("nope") == null);
}

test "Prefetch:未取走的 entry 由 deinit join+释放(无泄漏,MED-2 abort/discard 生命周期)" {
    const a = std.testing.allocator;
    var p = Prefetch.init(a);
    // 起两个预取,**都不 take**(模拟 abort/stream-error 丢弃):joinAll(经 deinit)必须 join 线程 +
    // 释放各自 content,否则 testing.allocator 报泄漏 / 线程未 join 崩溃。
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "." };
    p.start(&ctx, "a", "Glob", "{\"pattern\":\"*.zig\"}");
    p.start(&ctx, "b", "Glob", "{\"pattern\":\"*.md\"}");
    // 显式先 joinAll(幂等)——模拟早退分支在释放 borrow 源前的调用;再 deinit(再 joinAll no-op)。
    p.joinAll();
    p.joinAll(); // 幂等:第二次 no-op
    p.deinit();
    // 到此无泄漏、无未 join 线程即通过(testing.allocator 会在测试末校验)。
}
