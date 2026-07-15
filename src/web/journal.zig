//! EventJournal —— web 会话的事件日志(内存,append-only,seq = 下标)。
//!
//! 解决 CoreEvent fire-and-forget 与浏览器断线重连的矛盾:emit 落 journal,
//! SSE 连接从任意 seq 起重放 + condvar 低延迟推送新事件。一份 journal 就是
//! 一个 session 的"渲染事件层真相"(与 transcript 的 API message 层互补)。
//!
//! 线程性:agent_loop/工具线程 append,HTTP 连接线程 waitSince——pthread mutex +
//! cond 保护(全仓惯例:裁剪版 std 无 Thread.Mutex)。行是 owned 拷贝,append 后
//! 不再改动 → waitSince 在锁内 dupe 返回,调用方自由持有。
//!
//! 容量(U7 有界化):环形淘汰——超 `max_lines` 条**或** `max_bytes` 字节时从**队首**逐条
//! 淘汰(free + 前移),防长会话内存无界(轴A 摄取治理)。**seq 保持逻辑单调**:淘汰不重排
//! seq,靠 `base_seq`(= lines[0] 的逻辑 seq)偏移——物理数组只留尾窗,逻辑 seq 永不回退。
//! 落后于保留窗口的 SSE 客户端(其游标 seq < base_seq)靠 `waitSinceFrom` 报出 effective start
//! → SSE 层发 `resync` 事件让客户端重拉 /state(config/roster 幂等可重建,被淘汰的只是瞬态渲染
//! 事件 text_chunk/进度,不影响附着态)。协议见 U5/U6 附着设计。

const std = @import("std");
const time = @import("../util/time.zig");
const sync = @import("platform").sync;
const log = @import("../util/log.zig");

/// 默认容量上限(慷慨但有界):20k 事件 或 16MB,先到者触发淘汰。web 单 session 生命周期内
/// 足够长回放,又挡住无界增长。测试用 initWithLimits 强制小上限触发淘汰路径。
pub const DEFAULT_MAX_LINES: usize = 20_000;
pub const DEFAULT_MAX_BYTES: usize = 16 * 1024 * 1024;

pub const EventJournal = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]u8) = .empty,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    closed: bool = false,
    /// **U7:逻辑 seq 偏移** = lines[0] 的逻辑 seq(淘汰累计)。逻辑 seq(count/waitSince/frame id)
    /// = base_seq + 物理下标。淘汰只增 base_seq,永不回退 → attach seq 语义(U5)不变。
    base_seq: usize = 0,
    /// 当前保留行总字节(淘汰按字节上限判定用)。
    total_bytes: usize = 0,
    max_lines: usize = DEFAULT_MAX_LINES,
    max_bytes: usize = DEFAULT_MAX_BYTES,

    pub fn init(allocator: std.mem.Allocator) EventJournal {
        return .{ .allocator = allocator };
    }

    /// U7:自定义上限(测试强制小窗触发淘汰;daemon 可按内存预算调)。
    pub fn initWithLimits(allocator: std.mem.Allocator, max_lines: usize, max_bytes: usize) EventJournal {
        return .{ .allocator = allocator, .max_lines = max_lines, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *EventJournal) void {
        self.lock();
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.unlock();
    }

    fn lock(self: *EventJournal) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *EventJournal) void {
        _ = self.mutex.unlock();
    }

    /// 持锁:淘汰队首直到满足两上限(始终保留 ≥1 条——单条超 max_bytes 也留,否则永删自己)。
    fn evictLocked(self: *EventJournal) void {
        while (self.lines.items.len > 1 and
            (self.lines.items.len > self.max_lines or self.total_bytes > self.max_bytes))
        {
            const front = self.lines.orderedRemove(0); // O(n) 前移;淘汰不频繁(仅越界时)
            self.total_bytes -= front.len;
            self.allocator.free(front);
            self.base_seq += 1; // 逻辑 seq 前进,物理 [0] 换成下一条
        }
    }

    /// 追加一行(dupe,owned by journal)并唤醒所有等待者。超上限则淘汰队首(U7)。
    /// OOM 不致命但不静默吞:丢行会让浏览器视图缺工具结果 → 记 warn(对齐 headless_backend)。
    pub fn append(self: *EventJournal, line: []const u8) void {
        const owned = self.allocator.dupe(u8, line) catch {
            log.warn("web", "journal dropped line (OOM)", .{});
            return;
        };
        self.lock();
        defer self.unlock();
        self.lines.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            log.warn("web", "journal dropped line (OOM)", .{});
            return;
        };
        self.total_bytes += owned.len;
        self.evictLocked(); // U7:越上限淘汰队首(logical seq 经 base_seq 保持单调)
        _ = self.cond.broadcast();
    }

    /// 下一个新事件的**逻辑 seq**(= base_seq + 物理行数)。U5 attach 快照锁定它。
    pub fn count(self: *EventJournal) usize {
        self.lock();
        defer self.unlock();
        return self.base_seq + self.lines.items.len;
    }

    /// **U7:最老保留行的逻辑 seq**(= base_seq)。客户端游标 < 此 = 落后保留窗,须 resync。
    pub fn firstSeq(self: *EventJournal) usize {
        self.lock();
        defer self.unlock();
        return self.base_seq;
    }

    /// 关闭(session 结束):唤醒所有 waitSince,让 SSE 连接收尾退出。
    pub fn close(self: *EventJournal) void {
        self.lock();
        defer self.unlock();
        self.closed = true;
        _ = self.cond.broadcast();
    }

    pub fn isClosed(self: *EventJournal) bool {
        self.lock();
        defer self.unlock();
        return self.closed;
    }

    /// 拷贝逻辑 seq >= since 的所有保留行(每行 dupe,owned by 调用方;调用方逐行 free + free 外层)。
    /// 无新行时阻塞至多 timeout_ms;超时或已 closed 且无新行 → null。
    /// since 越界(坏客户端/未来 seq)按"等新事件"处理,不 panic。**U7:since < base_seq(落后保留窗)
    /// → 从 base_seq 起返回保留尾**(effective start 经 waitSinceFrom 的 start_out 报出)。
    pub fn waitSince(self: *EventJournal, allocator: std.mem.Allocator, since: usize, timeout_ms: u64) !?[][]u8 {
        var start: usize = undefined;
        return self.waitSinceFrom(allocator, since, timeout_ms, &start);
    }

    /// U7:同 waitSince,但把**返回批次首行的逻辑 seq**写进 start_out。SSE 层据此:
    /// ① start_out > since ⇒ 请求的 [since, start_out) 已被淘汰 → 发 resync 事件让客户端重拉 /state;
    /// ② frame `id:` 用 start_out + i(逻辑 seq 正确,重连续传不错位)。
    /// **锁内一次算定 effective start**,消除"检查 firstSeq 与 waitSince 之间又淘汰"的竞态。
    pub fn waitSinceFrom(self: *EventJournal, allocator: std.mem.Allocator, since: usize, timeout_ms: u64, start_out: *usize) !?[][]u8 {
        self.lock();
        defer self.unlock();
        // effective start = max(since, base_seq):落后保留窗则夹到 base_seq;领先则等到该 seq 出现。
        var eff = @max(since, self.base_seq);
        // 等到逻辑 seq eff 有行可返回,即 base_seq + len > eff。signal 醒来重算 eff 后重判谓词;
        // timeout → break(下方无条件重算兜底)。
        while (self.base_seq + self.lines.items.len <= eff and !self.closed) {
            if (!self.cond.timedWait(&self.mutex, timeout_ms * std.time.ns_per_ms)) break;
            eff = @max(since, self.base_seq);
        }
        // **U7 BLOCKER 修(review)**:timeout-break 路径原不重算 eff → 若并发淘汰使 base_seq 越过旧
        // eff,下方 phys=eff-base_seq 下溢(usize)→ OOB 崩。故循环退出后**无条件用当前 base_seq 重算
        // eff**(锁仍持,base_seq 稳定)→ eff>=base_seq 恒成立,不下溢。**注**:此 bug 仅在
        // ETIMEDOUT-与-signal-同刻(POSIX 允许)的罕见窗触发,无法确定性 red-light;修是把
        // "eff>=base_seq 后置条件"变成**所有退出路径无条件成立**的防御式不变式(可推理证明,非靠运气)。
        eff = @max(since, self.base_seq);
        start_out.* = eff;
        if (self.base_seq + self.lines.items.len <= eff) return null; // 超时/closed 且无新行
        const phys = eff - self.base_seq; // 物理下标(eff >= base_seq 恒成立,不下溢)
        const n = self.lines.items.len - phys;
        const out = try allocator.alloc([]u8, n);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |l| allocator.free(l);
            allocator.free(out);
        }
        for (self.lines.items[phys..], 0..) |l, i| {
            out[i] = try allocator.dupe(u8, l);
            filled += 1;
        }
        return out;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "append 后 waitSince 立即返回,行内容与顺序正确" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    j.append("{\"a\":1}");
    j.append("{\"b\":2}");
    const batch = (try j.waitSince(testing.allocator, 0, 10)).?;
    defer {
        for (batch) |l| testing.allocator.free(l);
        testing.allocator.free(batch);
    }
    try testing.expectEqual(@as(usize, 2), batch.len);
    try testing.expectEqualStrings("{\"a\":1}", batch[0]);
    try testing.expectEqualStrings("{\"b\":2}", batch[1]);
}

test "waitSince 从中间 seq 增量拉取(断线重连语义)" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    j.append("e0");
    j.append("e1");
    j.append("e2");
    const batch = (try j.waitSince(testing.allocator, 2, 10)).?;
    defer {
        for (batch) |l| testing.allocator.free(l);
        testing.allocator.free(batch);
    }
    try testing.expectEqual(@as(usize, 1), batch.len);
    try testing.expectEqualStrings("e2", batch[0]);
}

test "无新行超时返回 null;越界 since 不 panic" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    j.append("only");
    try testing.expectEqual(@as(?[][]u8, null), try j.waitSince(testing.allocator, 1, 5));
    try testing.expectEqual(@as(?[][]u8, null), try j.waitSince(testing.allocator, 99, 5));
}

test "close 唤醒等待者并返回 null;isClosed 可见" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    const Waiter = struct {
        fn run(jj: *EventJournal) void {
            // 长超时:必须靠 close 的 broadcast 提前醒,否则测试会卡满 5s
            _ = jj.waitSince(std.testing.allocator, 0, 5000) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Waiter.run, .{&j});
    // 给 waiter 一点进入等待的时间(非严格同步,close 的 broadcast 对未入等者也安全)
    time.sleepMs(20);
    j.close();
    t.join();
    try testing.expect(j.isClosed());
    try testing.expectEqual(@as(?[][]u8, null), try j.waitSince(testing.allocator, 0, 5));
}

test "U7: 环形淘汰——超行数上限淘汰队首,count 逻辑单调,firstSeq 前进,物理有界" {
    var j = EventJournal.initWithLimits(testing.allocator, 3, 1 << 30); // 上限 3 行
    defer j.deinit();
    // 追 6 条(e0..e5)。物理只留末 3 条(e3,e4,e5);逻辑 seq 仍 0..6。
    var buf: [8]u8 = undefined;
    for (0..6) |i| j.append(std.fmt.bufPrint(&buf, "e{d}", .{i}) catch unreachable);

    try testing.expectEqual(@as(usize, 6), j.count()); // 逻辑下一个 seq(单调,未回退)
    try testing.expectEqual(@as(usize, 3), j.firstSeq()); // 最老保留 = e3 的逻辑 seq
    try testing.expectEqual(@as(usize, 3), j.lines.items.len); // 物理有界

    // 从逻辑 seq 3 拉 → e3,e4,e5。
    const b = (try j.waitSince(testing.allocator, 3, 10)).?;
    defer {
        for (b) |l| testing.allocator.free(l);
        testing.allocator.free(b);
    }
    try testing.expectEqual(@as(usize, 3), b.len);
    try testing.expectEqualStrings("e3", b[0]);
    try testing.expectEqualStrings("e5", b[2]);
}

test "U7: 字节上限也触发淘汰(先到者判定)" {
    // 行数上限极大,字节上限小:靠字节触发。每行 ~5 字节,上限 12 字节 → 留末 2 行。
    var j = EventJournal.initWithLimits(testing.allocator, 1 << 30, 12);
    defer j.deinit();
    j.append("aaaaa"); // 5B
    j.append("bbbbb"); // 10B
    j.append("ccccc"); // 15B>12 → 淘 aaaaa(留 bbbbb+ccccc=10B)
    try testing.expectEqual(@as(usize, 1), j.firstSeq()); // aaaaa(seq0)被淘
    try testing.expectEqual(@as(usize, 3), j.count());
    try testing.expect(j.total_bytes <= 12);
}

test "U7: 落后保留窗 → waitSinceFrom 报 effective start(SSE resync 信号)+ frame id 不错位" {
    var j = EventJournal.initWithLimits(testing.allocator, 2, 1 << 30);
    defer j.deinit();
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        j.append(std.fmt.bufPrint(&buf, "e{d}", .{i}) catch unreachable);
    }
    // 物理留 e3,e4(base_seq=3)。客户端游标 since=1(< base_seq)= 落后保留窗。
    var start: usize = undefined;
    const b = (try j.waitSinceFrom(testing.allocator, 1, 10, &start)).?;
    defer {
        for (b) |l| testing.allocator.free(l);
        testing.allocator.free(b);
    }
    // effective start 报 3(SSE 层据此发 resync + 用 3+i 作 frame id,不把 e3 当 seq1)。
    try testing.expectEqual(@as(usize, 3), start);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectEqualStrings("e3", b[0]);
    try testing.expectEqualStrings("e4", b[1]);
}

test "U7 BLOCKER 回归: 等待者在 base_seq 越过其 eff 时不下溢/不 OOB(并发淘汰 vs 超时-break)" {
    // review BLOCKER:waitSinceFrom 的 timeout-break 路径原不重算 eff → 并发淘汰把 base_seq 推过
    // 旧 eff 后,phys=eff-base_seq 下溢 → OOB 崩。本测复现:小窗 journal,一个等待者从 since 起等
    // (进 wait),producer 狂 append+evict 把 base_seq 推到远超 since → 等待者醒来必须夹到当前
    // base_seq(start_out>=base_seq),绝不下溢/崩。
    var j = EventJournal.initWithLimits(testing.allocator, 2, 1 << 30); // 只留 2 行
    defer j.deinit();
    j.append("seed"); // seq0

    const Producer = struct {
        fn run(jj: *EventJournal) void {
            var buf: [16]u8 = undefined;
            var i: usize = 0;
            while (i < 500) : (i += 1) {
                jj.append(std.fmt.bufPrint(&buf, "p{d}", .{i}) catch unreachable);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&j});
    // 消费者从 since=0 反复拉:base_seq 会被 producer 推到 ~499。每次拿到的 start_out 必 >= base_seq
    // 当时值(单调不减),且 phys 不下溢(不崩)。拉到逻辑 seq 追上 count 即停。
    var cursor: usize = 0;
    var iters: usize = 0;
    while (cursor < 500 and iters < 5000) : (iters += 1) {
        var start: usize = undefined;
        const batch = (try j.waitSinceFrom(testing.allocator, cursor, 5, &start)) orelse continue;
        defer {
            for (batch) |l| testing.allocator.free(l);
            testing.allocator.free(batch);
        }
        // start_out 必 >= cursor(夹到保留窗)且 = 返回批次首行逻辑 seq。不下溢的直接证据:
        // start >= j.firstSeq 当时(>=0),且 batch.len>0。
        try testing.expect(start >= cursor);
        cursor = start + batch.len; // 逻辑 seq 前进(可能因 resync 跳)
    }
    t.join();
    try testing.expectEqual(@as(usize, 501), j.count()); // seed + 500
}

test "U7: 无淘汰时 base_seq=0,行为与旧版逐字节等价(向后兼容)" {
    var j = EventJournal.init(testing.allocator); // 默认大上限,不淘汰
    defer j.deinit();
    j.append("x");
    j.append("y");
    try testing.expectEqual(@as(usize, 0), j.firstSeq());
    try testing.expectEqual(@as(usize, 2), j.count());
    var start: usize = undefined;
    const b = (try j.waitSinceFrom(testing.allocator, 0, 10, &start)).?;
    defer {
        for (b) |l| testing.allocator.free(l);
        testing.allocator.free(b);
    }
    try testing.expectEqual(@as(usize, 0), start); // 无淘汰 → start==since
    try testing.expectEqual(@as(usize, 2), b.len);
}

test "跨线程 append/waitSince 数据完整(生产者-消费者)" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    const N = 50;
    const Producer = struct {
        fn run(jj: *EventJournal) void {
            var buf: [16]u8 = undefined;
            for (0..N) |i| {
                const s = std.fmt.bufPrint(&buf, "ev{d}", .{i}) catch unreachable;
                jj.append(s);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&j});
    var got: usize = 0;
    while (got < N) {
        const batch = (try j.waitSince(testing.allocator, got, 2000)) orelse continue;
        defer {
            for (batch) |l| testing.allocator.free(l);
            testing.allocator.free(batch);
        }
        // 顺序校验:第 got+i 条应为 "ev{got+i}"
        for (batch, 0..) |l, i| {
            var buf: [16]u8 = undefined;
            const want = std.fmt.bufPrint(&buf, "ev{d}", .{got + i}) catch unreachable;
            try testing.expectEqualStrings(want, l);
        }
        got += batch.len;
    }
    t.join();
    try testing.expectEqual(@as(usize, N), j.count());
}
