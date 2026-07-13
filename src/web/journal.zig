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
//! 容量:MVP 不设上限(journal 生命周期 = session 进程)。长会话若成问题,
//! 后续加环形淘汰 + "重放起点晚于请求 seq"信号,协议上 SSE 天然支持。

const std = @import("std");
const sync = @import("../platform/sync.zig");
const log = @import("../util/log.zig");

pub const EventJournal = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]u8) = .empty,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) EventJournal {
        return .{ .allocator = allocator };
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

    /// 追加一行(dupe,owned by journal)并唤醒所有等待者。
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
        _ = self.cond.broadcast();
    }

    /// 当前行数(下一个新事件的 seq)。
    pub fn count(self: *EventJournal) usize {
        self.lock();
        defer self.unlock();
        return self.lines.items.len;
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

    /// 拷贝 seq >= since 的所有行(每行 dupe,owned by 调用方;调用方逐行 free + free 外层)。
    /// 无新行时阻塞至多 timeout_ms;超时或已 closed 且无新行 → null。
    /// since 越界(坏客户端)按"等新事件"处理,不 panic。
    pub fn waitSince(self: *EventJournal, allocator: std.mem.Allocator, since: usize, timeout_ms: u64) !?[][]u8 {
        self.lock();
        defer self.unlock();
        if (self.lines.items.len <= since) {
            if (self.closed) return null;
            while (self.lines.items.len <= since and !self.closed) {
                // 相对超时等待；超时/错误 → break 按超时处理。SSE 各 client 独立 since 游标
                // 且不消费行，谓词一旦 lines.len>since 即恒真，无"信号后谓词仍假"重等场景。
                if (!self.cond.timedWait(&self.mutex, timeout_ms * std.time.ns_per_ms)) break;
            }
            if (self.lines.items.len <= since) return null;
        }
        const n = self.lines.items.len - since;
        const out = try allocator.alloc([]u8, n);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |l| allocator.free(l);
            allocator.free(out);
        }
        for (self.lines.items[since..], 0..) |l, i| {
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
    var req: std.c.timespec = .{ .sec = 0, .nsec = 20_000_000 };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
    j.close();
    t.join();
    try testing.expect(j.isClosed());
    try testing.expectEqual(@as(?[][]u8, null), try j.waitSince(testing.allocator, 0, 5));
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
