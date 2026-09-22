//! MsgQueue —— 生成期"待发送队列"(对齐 Claude Code 的 commandQueue)。
//!
//! LLM 流式输出时,用户在输入框按回车提交的消息**不立即发**,而是入此队列;
//! LLM 一轮结束后,主循环从队首逐条取出作为后续 input 续发,直到队空。
//!
//! 线程安全:watcher 线程(生成期输入)push,主线程 popFront/snapshot 渲染。
//! 自带 pthread mutex(不复用 RenderRegion.mutex,避免锁顺序耦合)。

const std = @import("std");
const sync = @import("platform").sync;

pub const MsgQueue = struct {
    items: std.ArrayList([]u8) = .empty, // 每条 owned text(入队 dupe,出队转移所有权给调用者)
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) MsgQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MsgQueue) void {
        for (self.items.items) |t| self.allocator.free(t);
        self.items.deinit(self.allocator);
    }

    fn lock(self: *MsgQueue) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *MsgQueue) void {
        _ = self.mutex.unlock();
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

    /// 队首满足 `accept` 时取出(所有权转移给调用者),否则**留在队列**并返回 null——FIFO 不重排:
    /// 队首是 REPL 命令时,后面的普通消息也一起等 Run 结束(#115:agent_loop 只在 turn 边界
    /// 消费普通 prompt,`/命令`、`!shell` 归 REPL)。
    pub fn popFrontIf(self: *MsgQueue, comptime accept: fn ([]const u8) bool) ?[]u8 {
        self.lock();
        defer self.unlock();
        if (self.items.items.len == 0) return null;
        if (!accept(self.items.items[0])) return null;
        return self.items.orderedRemove(0);
    }

    /// 把一条已 owned 的消息放回**队首**(所有权交回队列;须是本队列 allocator 分配的)。
    /// 消费方取出后才发现 Run 已中断时用它还回去,让 REPL 在 Run 结束后按老规矩续发。
    /// OOM → false,所有权仍在调用方。
    pub fn pushFront(self: *MsgQueue, owned: []u8) bool {
        self.lock();
        defer self.unlock();
        self.items.insert(self.allocator, 0, owned) catch return false;
        return true;
    }

    /// 持锁视图:守卫存活期间队列不会被另一线程 pop/free,`items()` 借用的字节才安全。
    /// 渲染队列预览(watcher 线程)用它;#115 起 agent_loop 线程会在 turn 边界 popFront 并释放
    /// 字节,老的"先 snapshot 再放锁再画"是 use-after-free 窗口。守卫期间不要再调本队列的其它方法
    /// (mutex 不可重入)。
    pub const Held = struct {
        queue: *MsgQueue,

        pub fn items(self: Held) []const []u8 {
            return self.queue.items.items;
        }

        pub fn release(self: Held) void {
            self.queue.unlock();
        }
    };

    pub fn hold(self: *MsgQueue) Held {
        self.lock();
        return .{ .queue = self };
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

test "MsgQueue hold: locked view of the queued items" {
    var q = MsgQueue.init(std.testing.allocator);
    defer q.deinit();
    _ = q.push("a");
    _ = q.push("b");
    const held = q.hold();
    try std.testing.expectEqual(@as(usize, 2), held.items().len);
    try std.testing.expectEqualStrings("a", held.items()[0]);
    try std.testing.expectEqualStrings("b", held.items()[1]);
    held.release();
    try std.testing.expectEqual(@as(usize, 2), q.len()); // 锁已放开,常规方法可用
}

fn acceptsPlain(text: []const u8) bool {
    return text.len == 0 or text[0] != '/';
}

test "MsgQueue popFrontIf leaves a rejected head in place and keeps FIFO order" {
    var q = MsgQueue.init(std.testing.allocator);
    defer q.deinit();
    _ = q.push("/model x");
    _ = q.push("plain steer");
    // 队首是命令:不取、不重排——后面的普通消息一起等。
    try std.testing.expect(q.popFrontIf(acceptsPlain) == null);
    try std.testing.expectEqual(@as(usize, 2), q.len());
    const head = q.popFront().?;
    defer std.testing.allocator.free(head);
    try std.testing.expectEqualStrings("/model x", head);
    const next = q.popFrontIf(acceptsPlain).?;
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("plain steer", next);
    try std.testing.expect(q.popFrontIf(acceptsPlain) == null);
}

test "MsgQueue pushFront returns a taken message to the head" {
    var q = MsgQueue.init(std.testing.allocator);
    defer q.deinit();
    _ = q.push("first");
    _ = q.push("second");
    const taken = q.popFront().?;
    try std.testing.expect(q.pushFront(taken)); // 所有权交回队列,deinit 会释放
    const head = q.popFront().?;
    defer std.testing.allocator.free(head);
    try std.testing.expectEqualStrings("first", head);
    try std.testing.expectEqual(@as(usize, 1), q.len());
}
