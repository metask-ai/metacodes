//! MsgQueue —— 生成期"待发送队列"(对齐 Claude Code 的 commandQueue)。
//!
//! LLM 流式输出时,用户在输入框按回车提交的消息**不立即发**,而是入此队列;
//! LLM 一轮结束后,主循环从队首逐条取出作为后续 input 续发,直到队空。
//!
//! 线程安全:watcher 线程(生成期输入)push,主线程 popFront/snapshot 渲染。
//! 自带 pthread mutex(不复用 RenderRegion.mutex,避免锁顺序耦合)。

const std = @import("std");

pub const MsgQueue = struct {
    items: std.ArrayList([]u8) = .empty, // 每条 owned text(入队 dupe,出队转移所有权给调用者)
    allocator: std.mem.Allocator,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn init(allocator: std.mem.Allocator) MsgQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MsgQueue) void {
        for (self.items.items) |t| self.allocator.free(t);
        self.items.deinit(self.allocator);
    }

    fn lock(self: *MsgQueue) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *MsgQueue) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// 入队(dupe text,owned by queue)。返回是否成功(OOM 时 false)。
    pub fn push(self: *MsgQueue, text: []const u8) bool {
        const owned = self.allocator.dupe(u8, text) catch return false;
        self.lock();
        defer self.unlock();
        self.items.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return false;
        };
        return true;
    }

    /// 取队首(所有权转移给调用者,需自行 free)。空返 null。
    pub fn popFront(self: *MsgQueue) ?[]u8 {
        self.lock();
        defer self.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// 取出**全部**队列消息,用 sep 连成一条(所有权转移给调用者,需 free)。空返 null。
    /// 对齐 Claude Code:同模式的多条 queued 消息一次性合并提交(而非逐条多轮)。
    pub fn popAllJoined(self: *MsgQueue, sep: []const u8) ?[]u8 {
        self.lock();
        defer self.unlock();
        if (self.items.items.len == 0) return null;
        defer {
            for (self.items.items) |t| self.allocator.free(t);
            self.items.clearRetainingCapacity();
        }
        if (self.items.items.len == 1) {
            // 单条:直接 dupe(避免无谓拼接)。
            return self.allocator.dupe(u8, self.items.items[0]) catch null;
        }
        var total: usize = 0;
        for (self.items.items, 0..) |t, i| {
            total += t.len;
            if (i + 1 < self.items.items.len) total += sep.len;
        }
        const out = self.allocator.alloc(u8, total) catch return null;
        var off: usize = 0;
        for (self.items.items, 0..) |t, i| {
            @memcpy(out[off .. off + t.len], t);
            off += t.len;
            if (i + 1 < self.items.items.len) {
                @memcpy(out[off .. off + sep.len], sep);
                off += sep.len;
            }
        }
        return out;
    }

    pub fn len(self: *MsgQueue) usize {
        self.lock();
        defer self.unlock();
        return self.items.items.len;
    }

    /// 把当前队列各条复制进 out_buf(最多 max 条),返回写入条数。供渲染预览用(不转移所有权)。
    /// 注意:返回的 slice 借用队列内部内存,调用方须在持有期间不让队列被改(渲染在持 region 锁的
    /// watcher 线程内同步调用,push 也在同线程,故安全)。
    pub fn snapshot(self: *MsgQueue, out_buf: [][]const u8) usize {
        self.lock();
        defer self.unlock();
        const n = @min(self.items.items.len, out_buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) out_buf[i] = self.items.items[i];
        return n;
    }
};

test "MsgQueue push/popFront FIFO + 无泄漏" {
    var q = MsgQueue.init(std.testing.allocator);
    defer q.deinit();
    try std.testing.expect(q.push("first"));
    try std.testing.expect(q.push("second"));
    try std.testing.expectEqual(@as(usize, 2), q.len());

    const a = q.popFront().?;
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("first", a);
    const b = q.popFront().?;
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("second", b);
    try std.testing.expect(q.popFront() == null);
}

test "MsgQueue snapshot" {
    var q = MsgQueue.init(std.testing.allocator);
    defer q.deinit();
    _ = q.push("a");
    _ = q.push("b");
    var buf: [4][]const u8 = undefined;
    const n = q.snapshot(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("a", buf[0]);
    try std.testing.expectEqualStrings("b", buf[1]);
}
