//! 流式工具执行(streaming tool execution:边流边跑)。
//!
//! **动机**:模型一边流式产出 assistant 文本/工具块,一边我们已收到 tool_use_start 事件。旧版把所有
//! tool_use 攒到流结束再统一 executeSlots——对"多工具 + 大 Read"的长回合,首个工具本可在流还在跑时
//! 就启动。cc 的 StreamingToolExecutor / codex 的 in-flight futures 都证明边流边执行是核心能力。
//!
//! **可流子集**:所有 **concurrency-safe**(只读语义:Read/Grep/Glob/BashOutput/WebFetch + 只读 Bash
//! `git status`/`ls`)+ **isStreamable**(排除 WebSearch,它子请求竞争模型 client)+ 权限 auto-allow +
//! 无 PreToolUse hook 匹配。这类工具"提前跑或丢弃"都无害,故不改动权限/提交/执行主管线:
//!   - tool_use_start 到达 → 若可流 → 开线程跑,结果按 tool_use id 存;
//!   - 流结束后 executeSlots 处理该工具时 → 若有结果 → 直接用,不重复执行;
//!   - 未用(权限实际拒/plan/UiPending 丢弃)→ executeSlots 正常跑(fallback)。
//!
//! **执行走共享 `tool_exec.executeOne`**(与 executeSlots 同一入口):错误处理/大结果落盘/UiPending
//! 完全一致,无"行为分叉"。每次独立 ArenaAllocator(规避 GPA 非线程安全),结果 dupe 回父逃逸。

const std = @import("std");
const tools_mod = @import("../tools.zig");
const ToolContext = tools_mod.ToolContext;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");
const file_reference = @import("file_reference.zig");
const file_change = @import("file_change.zig");

/// 可流式执行的工具:除 **WebSearch** 外的一切。WebSearch 在其隔离子请求里发子 LLM 请求,
/// 是重量级付费调用——主 stream 后续还可能取消/改写本轮工具,投机预取的浪费远高于 Read/Grep
/// (成本论;std.http.Client 连接池本身线程安全,并发不是排除理由)→ 留给流末 executeSlots。
/// 真正能否边流边执行由调用方叠加 `isConcurrencySafeInput`(只读语义)+ 权限 allow + 无 PreToolUse hook。
pub fn isStreamable(name: []const u8) bool {
    return !std.mem.eql(u8, name, "WebSearch");
}

/// 历史名(保留兼容/文档):纯只读工具白名单。现广播到全 concurrency-safe 集,门见 isStreamable。
pub fn isPrefetchable(name: []const u8) bool {
    return std.mem.eql(u8, name, "Read") or
        std.mem.eql(u8, name, "Grep") or
        std.mem.eql(u8, name, "Glob");
}

const Entry = struct {
    id: []const u8, // borrowed(指向 tool_uses 里的 id;预取 take 前有效)
    thread: ?std.Thread = null,
    content: ?[]u8 = null, // owned by parent allocator(dispatch 结果 dupe 出 arena)
    file_refs: ?[]file_reference.FileReference = null, // owned by parent allocator
    is_error: bool = false,
    elapsed_ms: u64 = 0,
    effect: ?@import("../tools/observation.zig").Effect = null,
    effect_valid: bool = true,
    /// Speculative prefetch is restricted to concurrency-safe tools, which do
    /// not mutate files. Mirrored anyway so that if that gate ever widens, the
    /// evidence transfers with the result instead of being dropped in silence.
    file_changes: ?[]file_change.Record = null,
    file_changes_overflow: bool = false,
    file_changes_lost: bool = false,
    taken: bool = false, // 已被 executeSlots 取走(所有权转移)
    skip: bool = false, // 预取遇 UiPending(并发安全工具不该发生)→ 丢弃,take 返 null 让 executeSlots 重跑
};

const Job = struct {
    entry: *Entry,
    ctx: *const ToolContext,
    name: []const u8, // borrowed
    input: []const u8, // borrowed
    parent_allocator: std.mem.Allocator,
    rid: log.RequestId,
};

fn runJob(job: *Job) void {
    // **与 executeSlots 共用同一 executeOne**:执行语义/错误处理/大结果落盘完全一致(无分叉)。
    const tool_exec = @import("tool_exec.zig");
    const result = tool_exec.executeOne(job.ctx, job.name, job.input, job.entry.id, job.parent_allocator, job.rid) catch {
        // Speculation may fail under pressure; the authoritative executeSlots
        // path retries and applies the Run-level OOM contract.
        job.entry.skip = true;
        return;
    };
    switch (result) {
        .pending => |p| {
            // 并发安全工具不该发起 custom UI;保守丢弃 + 标 skip → executeSlots 正常重跑。
            if (p.kind) |k| job.parent_allocator.free(k);
            if (p.payload) |pl| job.parent_allocator.free(pl);
            job.entry.skip = true;
        },
        .done => |d| {
            job.entry.content = d.content;
            job.entry.file_refs = d.file_refs;
            job.entry.is_error = d.is_error;
            job.entry.elapsed_ms = d.elapsed_ms;
            job.entry.effect = d.effect;
            job.entry.effect_valid = d.effect_valid;
            job.entry.file_changes = d.file_changes;
            job.entry.file_changes_overflow = d.file_changes_overflow;
            job.entry.file_changes_lost = d.file_changes_lost;
        },
        // Host 工具不进流式预取(prefetch_safe=false + isStreamable 白名单),此分支
        // 防御性兜底:标 skip 让 executeSlots 正常路径重跑并走完整 fatal 控制流。
        .host_fatal => job.entry.skip = true,
    }
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

    /// 已 spawn 未 join 的预取线程数。**刻意保守**:take/joinAll 只在流末发生,完成但未 join 的
    /// 线程照样占坑 → 实际语义是"每个流最多 MAX_TOOL_CONCURRENCY 次预取",不是"最多 N 并发"。
    /// 这也是 cap 测试确定性的前提(完成的 sleep 任务仍计数)——改成真在飞计数(done 标志)前
    /// 必须同步改测试。超出 cap 的工具流末正常执行,只损失投机收益。
    fn inflightCount(self: *const Prefetch) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.thread != null) n += 1;
        }
        return n;
    }

    /// 开一个预取线程执行 (name,input),结果按 id 存。ctx 必须活过整个流(基于 turn 作用域的 ctx)。
    /// spawn 失败 → 静默跳过(该工具流末正常执行,无害)。
    /// **并发上限**:在飞线程 ≥ MAX_TOOL_CONCURRENCY 时不预取(直接 return,take 返 null →
    /// executeSlots 正常执行)——消费路径有 8 的滑动窗口,预取侧无界曾是疏漏。
    pub fn start(self: *Prefetch, ctx: *const ToolContext, id: []const u8, name: []const u8, input: []const u8, rid: log.RequestId) void {
        if (self.inflightCount() >= @import("tool_exec.zig").MAX_TOOL_CONCURRENCY) return;
        const entry = self.allocator.create(Entry) catch return;
        entry.* = .{ .id = id };
        self.entries.append(self.allocator, entry) catch {
            self.allocator.destroy(entry);
            return;
        };
        const job = self.allocator.create(Job) catch return; // entry 已入表,deinit 会收
        job.* = .{ .entry = entry, .ctx = ctx, .name = name, .input = input, .parent_allocator = self.allocator, .rid = rid };
        self.jobs.append(self.allocator, job) catch {
            self.allocator.destroy(job);
            return;
        };
        entry.thread = std.Thread.spawn(.{}, runJob, .{job}) catch blk: {
            runJob(job); // spawn 失败 → 当场同步跑(仍能用结果)
            break :blk null;
        };
    }

    /// 取某 id 的预取结果(join 线程)。有则返回 owned content/file_refs(转移所有权,调用方 free);
    /// 无该 id / 已取走 → null(调用方正常执行)。
    pub fn take(self: *Prefetch, id: []const u8) ?struct {
        content: ?[]u8,
        file_refs: ?[]file_reference.FileReference,
        is_error: bool,
        elapsed_ms: u64,
        effect: ?@import("../tools/observation.zig").Effect,
        effect_valid: bool,
        file_changes: ?[]file_change.Record,
        file_changes_overflow: bool,
        file_changes_lost: bool,
    } {
        for (self.entries.items) |e| {
            if (e.taken) continue;
            if (!std.mem.eql(u8, e.id, id)) continue;
            if (e.thread) |t| {
                t.join();
                e.thread = null;
            }
            // skip(预取遇 UiPending 丢弃)→ 标 taken 但返 null,让 executeSlots 正常重跑该工具。
            if (e.skip) {
                e.taken = true;
                return null;
            }
            e.taken = true;
            const content = e.content;
            e.content = null; // 所有权转移给调用方
            const refs = e.file_refs;
            e.file_refs = null;
            const changes = e.file_changes;
            e.file_changes = null;
            return .{
                .content = content,
                .file_refs = refs,
                .is_error = e.is_error,
                .elapsed_ms = e.elapsed_ms,
                .effect = e.effect,
                .effect_valid = e.effect_valid,
                .file_changes = changes,
                .file_changes_overflow = e.file_changes_overflow,
                .file_changes_lost = e.file_changes_lost,
            };
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
                if (e.file_refs) |refs| {
                    for (refs) |*ref| ref.deinit(self.allocator);
                    self.allocator.free(refs);
                }
                e.file_refs = null;
                if (e.file_changes) |changes| file_change.freeRecords(self.allocator, changes);
                e.file_changes = null;
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

test "isStreamable 除 WebSearch 外皆可流(WebSearch 重量级子请求,成本论排除)" {
    // 可流性只排 WebSearch;真正能否流由调用方叠加 isConcurrencySafeInput + 权限 + 无 hook。
    try std.testing.expect(isStreamable("Read"));
    try std.testing.expect(isStreamable("Bash"));
    try std.testing.expect(isStreamable("BashOutput"));
    try std.testing.expect(isStreamable("WebFetch"));
    try std.testing.expect(isStreamable("Write")); // isStreamable 不看并发安全(下游 gate 挡)
    try std.testing.expect(!isStreamable("WebSearch")); // 唯一排除
}

test "广播:只读 Bash 经 executeOne 流式执行(非 read-only 白名单也能跑)" {
    const a = std.testing.allocator;
    var p = Prefetch.init(a);
    defer p.deinit();
    // 最小 ctx:jobs/sandbox 可空(快命令同步完成)。cwd_abs 供工作目录。
    var ctx = ToolContext{ .allocator = a, .cwd_abs = ".", .home_dir = "/tmp" };
    p.start(&ctx, "bid", "Bash", "{\"command\":\"echo streamtest\"}", .{ .bytes = [_]u8{'0'} ** 12 });
    const r = p.take("bid");
    try std.testing.expect(r != null);
    try std.testing.expect(!r.?.is_error);
    try std.testing.expect(r.?.content != null);
    // 真跑了 echo → 结果含输出(证明广播到 Bash 的执行路径端到端通)。
    if (r.?.content) |c| {
        defer a.free(c);
        try std.testing.expect(std.mem.indexOf(u8, c, "streamtest") != null);
    }
}

test "Prefetch start+take:真 builtin Glob 结果正确落地(执行路径端到端)" {
    const a = std.testing.allocator;
    var p = Prefetch.init(a);
    defer p.deinit();
    // 最小 ctx:Glob 只需 cwd。cwd_abs="." → 匹配当前目录(测试从 cc-zig 根跑,有 *.zig)。
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "." };
    p.start(&ctx, "gid", "Glob", "{\"pattern\":\"*.zig\"}", .{ .bytes = [_]u8{'0'} ** 12 });
    const r = p.take("gid");
    try std.testing.expect(r != null);
    try std.testing.expect(r.?.content != null); // 预取线程真跑了 Glob 并存了结果
    if (r.?.content) |c| a.free(c); // take 转移所有权,调用方 free
    // 再取同 id → null(已取走);随机 id → null。
    try std.testing.expect(p.take("gid") == null);
    try std.testing.expect(p.take("nope") == null);
}

test "Prefetch:在飞线程数被 MAX_TOOL_CONCURRENCY cap(一轮 20 个只起 ≤8 线程)" {
    const a = std.testing.allocator;
    var p = Prefetch.init(a);
    defer p.deinit();
    var ctx = ToolContext{ .allocator = a, .cwd_abs = ".", .home_dir = "/tmp" };
    // sleep 0.3s 让前 8 个线程稳定在飞;后 12 次 start 撞 cap 直接拒绝(不建 entry)。
    var i: usize = 0;
    var ids: [20][2]u8 = undefined;
    while (i < 20) : (i += 1) {
        ids[i] = .{ 'p', @as(u8, @intCast('a' + i)) };
        p.start(&ctx, &ids[i], "Bash", "{\"command\":\"sleep 0.3\"}", .{ .bytes = [_]u8{'0'} ** 12 });
    }
    const cap = @import("tool_exec.zig").MAX_TOOL_CONCURRENCY;
    try std.testing.expect(p.entries.items.len <= cap);
    try std.testing.expect(p.inflightCount() <= cap);
    // 被拒绝的 id take 返 null → executeSlots 正常执行,语义无损。
    try std.testing.expect(p.take(&ids[19]) == null);
}

test "Prefetch:未取走的 entry 由 deinit join+释放(无泄漏,MED-2 abort/discard 生命周期)" {
    const a = std.testing.allocator;
    var p = Prefetch.init(a);
    // 起两个预取,**都不 take**(模拟 abort/stream-error 丢弃):joinAll(经 deinit)必须 join 线程 +
    // 释放各自 content,否则 testing.allocator 报泄漏 / 线程未 join 崩溃。
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "." };
    p.start(&ctx, "a", "Glob", "{\"pattern\":\"*.zig\"}", .{ .bytes = [_]u8{'0'} ** 12 });
    p.start(&ctx, "b", "Glob", "{\"pattern\":\"*.md\"}", .{ .bytes = [_]u8{'0'} ** 12 });
    // 显式先 joinAll(幂等)——模拟早退分支在释放 borrow 源前的调用;再 deinit(再 joinAll no-op)。
    p.joinAll();
    p.joinAll(); // 幂等:第二次 no-op
    p.deinit();
    // 到此无泄漏、无未 join 线程即通过(testing.allocator 会在测试末校验)。
}
