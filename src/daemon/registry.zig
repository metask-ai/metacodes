//! **SessionRegistry + SessionHost(U10-A)** —— daemon 多 session 宿主的核心机制层。
//!
//! daemon(`metacodes serve`)一个进程宿主 N 个 session。每个 session = 一个 **SessionHost**:
//! own 一个 EventJournal(U7 有界)+ inbox(客户端消息)+ 一条 driver 线程(跑该 session 的 agent
//! loop 循环)。**SessionRegistry** 是 SessionId→*SessionHost 的加锁表,管生命周期(create/lookup/
//! remove/shutdownAll)。
//!
//! **分层刻意**:registry/host 只管**生命周期 + 并发 + 优雅关停**(daemon 的真新代码风险),不含
//! App/agent_loop——那些由**注入的 driver_fn**(真路径=web/session 的 driver 循环 with App;测试=
//! fake echo)携带。这样最易错的机制(map 并发、线程 join、journal close 唤醒附着者)可脱离沉重的
//! App 构造做确定性测试;绑定层(UDS/web,U10-B/C)再把真 App driver 接进来。
//!
//! **线程/所有权**:SessionHost **堆分配**(*SessionHost 地址稳定——其 journal 内含 mutex/condvar
//! 被 driver 线程 + 附着的 HTTP/UDS 线程跨线程引用,绝不可随 map grow 搬迁)。registry.mutex 只保护
//! map 结构(put/get/remove 的短临界区),**绝不**跨 driver 线程 join 持有(否则关停期与 driver 争锁
//! 死锁)。driver_ctx 的资源(真路径的 App)由 ctx_deinit_fn 在 host.deinit 释放。

const std = @import("std");
const sync = @import("../platform").sync;
const time = @import("../util/time.zig");
const SessionId = @import("../core/session_id.zig").SessionId;
const EventJournal = @import("../web/journal.zig").EventJournal;
const MsgQueue = @import("../repl/msg_queue.zig").MsgQueue;

/// 一个 session 的运行时宿主单元。堆分配,registry 持 *SessionHost。
pub const SessionHost = struct {
    id: SessionId,
    allocator: std.mem.Allocator,
    journal: EventJournal,
    inbox: MsgQueue, // 客户端消息(UDS/web POST 入队);driver 线程消费
    /// **host 级停止**旗标(区别于 session 的 run-abort)。requestStop 置位;driver_fn poll 它退出。
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// driver:真路径=跑 App agent loop 循环;测试=fake。捕获 App 等在 driver_ctx。
    driver_ctx: *anyopaque,
    driver_fn: *const fn (host: *SessionHost, ctx: *anyopaque) void,
    /// 释放 driver_ctx 拥有的资源(真路径的 App 析构)。null=ctx 无需释放(测试)。
    ctx_deinit_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,

    /// 建一个 host(堆分配 self,init journal/inbox;**未 start**——caller 决定何时 spawn driver)。
    pub fn create(
        allocator: std.mem.Allocator,
        id: SessionId,
        driver_ctx: *anyopaque,
        driver_fn: *const fn (host: *SessionHost, ctx: *anyopaque) void,
        ctx_deinit_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    ) !*SessionHost {
        const self = try allocator.create(SessionHost);
        self.* = .{
            .id = id,
            .allocator = allocator,
            .journal = EventJournal.init(allocator),
            .inbox = MsgQueue.init(allocator),
            .driver_ctx = driver_ctx,
            .driver_fn = driver_fn,
            .ctx_deinit_fn = ctx_deinit_fn,
        };
        return self;
    }

    /// spawn driver 线程。
    pub fn start(self: *SessionHost) !void {
        self.thread = try std.Thread.spawn(.{}, driverTrampoline, .{self});
    }

    fn driverTrampoline(self: *SessionHost) void {
        self.driver_fn(self, self.driver_ctx);
    }

    /// host 级停止:置 flag(driver poll 退出)+ close journal(唤醒附着的 SSE/UDS waitSince)。
    /// 幂等。**不 join**(join 在 registry 关停期不持 map 锁时做)。
    pub fn requestStop(self: *SessionHost) void {
        self.stop_flag.store(true, .seq_cst);
        self.journal.close();
    }

    pub fn stopRequested(self: *const SessionHost) bool {
        return self.stop_flag.load(.seq_cst);
    }

    /// join driver 线程(阻塞至 driver_fn 返回)。requestStop 后调。
    pub fn join(self: *SessionHost) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// 全清:join(若未)+ 释放 journal/inbox + ctx_deinit + destroy self。
    pub fn destroy(self: *SessionHost) void {
        self.requestStop();
        self.join();
        if (self.ctx_deinit_fn) |f| f(self.driver_ctx, self.allocator);
        self.journal.deinit();
        self.inbox.deinit();
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

/// SessionId → *SessionHost 加锁表。daemon 的多绑定线程(UDS/web accept)并发 create/lookup/remove。
pub const SessionRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    hosts: std.AutoHashMapUnmanaged(SessionId, *SessionHost) = .{},

    pub fn init(allocator: std.mem.Allocator) SessionRegistry {
        return .{ .allocator = allocator };
    }

    /// 关停并释放所有 host(见 shutdownAll)+ 释放 map。
    pub fn deinit(self: *SessionRegistry) void {
        self.shutdownAll();
        _ = self.mutex.lock();
        self.hosts.deinit(self.allocator);
        _ = self.mutex.unlock();
    }

    /// 插入(id 已存在 → error.AlreadyExists,caller 不泄漏 host)。加锁短临界区。
    pub fn put(self: *SessionRegistry, host: *SessionHost) !void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        if (self.hosts.contains(host.id)) return error.AlreadyExists;
        try self.hosts.put(self.allocator, host.id, host);
    }

    /// 查(借用 *SessionHost;caller 用完不 destroy——生命周期归 registry)。加锁。
    pub fn get(self: *SessionRegistry, id: SessionId) ?*SessionHost {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        return self.hosts.get(id);
    }

    pub fn count(self: *SessionRegistry) usize {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        return self.hosts.count();
    }

    /// 移除并 destroy 一个 host。**先加锁摘 map(短临界区取出指针)→ 放锁 → destroy(含 join,
    /// 不持 map 锁)**:避免关停期与其它绑定线程争 map 锁 + join 阻塞叠加死锁。id 不存在=no-op。
    pub fn remove(self: *SessionRegistry, id: SessionId) void {
        _ = self.mutex.lock();
        const host = self.hosts.get(id);
        if (host != null) _ = self.hosts.remove(id);
        _ = self.mutex.unlock();
        if (host) |h| h.destroy(); // 锁外 join+释放
    }

    /// 优雅关停所有 session(SIGINT/daemon stop 驱动)。**两阶段**:① 加锁快照所有 *SessionHost
    /// 到栈数组 + 清 map → 放锁;② 锁外先对全部 requestStop(并行触发退出),再逐个 join+destroy。
    /// 先全 requestStop 再全 join = 各 session driver 并行收尾(非串行等每个),关停快。
    pub fn shutdownAll(self: *SessionRegistry) void {
        _ = self.mutex.lock();
        const n = self.hosts.count();
        if (n == 0) {
            _ = self.mutex.unlock();
            return;
        }
        // 快照到堆数组(count 可能大;栈数组风险)。失败则退回持锁逐个(降级,仍安全)。
        const snap = self.allocator.alloc(*SessionHost, n) catch {
            var it = self.hosts.valueIterator();
            while (it.next()) |hp| hp.*.destroy();
            self.hosts.clearRetainingCapacity();
            _ = self.mutex.unlock();
            return;
        };
        var i: usize = 0;
        var it = self.hosts.valueIterator();
        while (it.next()) |hp| : (i += 1) snap[i] = hp.*;
        self.hosts.clearRetainingCapacity();
        _ = self.mutex.unlock();

        for (snap) |h| h.requestStop(); // ① 并行触发退出
        for (snap) |h| h.destroy(); // ② 逐个 join+释放(driver 已在收尾)
        self.allocator.free(snap);
    }
};

// ============================================================================
// Tests —— fake driver(echo inbox→journal)验证 registry 生命周期/并发/优雅关停,
// 脱离 App 构造。真 App driver 在 UDS/web 绑定层(U10-B/C)接入并另测。
// ============================================================================

const testing = std.testing;

/// fake driver:poll host.stop + 消费 inbox echo 进 journal。真 driver 结构同(但跑 agent_loop)。
fn echoDriver(host: *SessionHost, ctx: *anyopaque) void {
    _ = ctx;
    while (!host.stopRequested()) {
        if (host.inbox.popFront()) |m| {
            defer host.allocator.free(m); // MsgQueue.push dup,popFront 返 owned
            host.journal.append(m);
        } else {
            time.sleepMs(2);
        }
    }
}

fn idFrom(n: u8) SessionId {
    var id = SessionId.single;
    id.bytes[0] = n; // 各不同 → 不同 key
    return id;
}

test "U10-A: 两 session 各自 journal 独立,消息不串台" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    defer reg.deinit();

    var dummy: u8 = 0;
    const h1 = try SessionHost.create(a, idFrom('A'), @ptrCast(&dummy), echoDriver, null);
    const h2 = try SessionHost.create(a, idFrom('B'), @ptrCast(&dummy), echoDriver, null);
    try reg.put(h1);
    try reg.put(h2);
    try h1.start();
    try h2.start();
    try testing.expectEqual(@as(usize, 2), reg.count());

    // 各喂各的消息。
    _ = reg.get(idFrom('A')).?.inbox.push("hello-A");
    _ = reg.get(idFrom('B')).?.inbox.push("hello-B");

    // 等 driver 消费(poll 到 journal 出现)。
    var waited: usize = 0;
    while ((h1.journal.count() == 0 or h2.journal.count() == 0) and waited < 500) : (waited += 1) {
        time.sleepMs(2);
    }
    try testing.expect(h1.journal.count() >= 1);
    try testing.expect(h2.journal.count() >= 1);

    // journal 内容各自正确(不串台)。
    const b1 = (try h1.journal.waitSince(a, 0, 10)).?;
    defer {
        for (b1) |l| a.free(l);
        a.free(b1);
    }
    const b2 = (try h2.journal.waitSince(a, 0, 10)).?;
    defer {
        for (b2) |l| a.free(l);
        a.free(b2);
    }
    try testing.expectEqualStrings("hello-A", b1[0]);
    try testing.expectEqualStrings("hello-B", b2[0]);
    // deinit → shutdownAll 优雅关停(join 不挂、无泄漏,testing.allocator 守)。
}

test "U10-A: shutdownAll 优雅关停全部,count 归零,driver 线程 join 不挂" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);

    var dummy: u8 = 0;
    var n: u8 = 0;
    while (n < 5) : (n += 1) {
        const h = try SessionHost.create(a, idFrom('a' + n), @ptrCast(&dummy), echoDriver, null);
        try reg.put(h);
        try h.start();
    }
    try testing.expectEqual(@as(usize, 5), reg.count());

    reg.shutdownAll();
    try testing.expectEqual(@as(usize, 0), reg.count());
    reg.deinit(); // 二次 shutdownAll no-op + 释放 map
}

test "U10-A: remove 单个 session 优雅摘除,其余不受影响" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    defer reg.deinit();

    var dummy: u8 = 0;
    const h1 = try SessionHost.create(a, idFrom('X'), @ptrCast(&dummy), echoDriver, null);
    const h2 = try SessionHost.create(a, idFrom('Y'), @ptrCast(&dummy), echoDriver, null);
    try reg.put(h1);
    try reg.put(h2);
    try h1.start();
    try h2.start();

    reg.remove(idFrom('X')); // 摘 X(join+destroy)
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expect(reg.get(idFrom('X')) == null);
    try testing.expect(reg.get(idFrom('Y')) != null); // Y 仍在
}

test "U10-A: put 重复 id → AlreadyExists(不覆盖不泄漏)" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    defer reg.deinit();
    var dummy: u8 = 0;
    const h1 = try SessionHost.create(a, idFrom('Z'), @ptrCast(&dummy), echoDriver, null);
    try reg.put(h1);
    try h1.start();
    // 第二个同 id host:put 失败 → caller 自行 destroy(不进 registry,避免泄漏)。
    const h2 = try SessionHost.create(a, idFrom('Z'), @ptrCast(&dummy), echoDriver, null);
    try testing.expectError(error.AlreadyExists, reg.put(h2));
    h2.destroy(); // 未进 registry,caller 释放
    try testing.expectEqual(@as(usize, 1), reg.count());
}
