//! **SessionRegistry + SessionHost(U10-A,精简核心 / option B)** —— daemon 多 session 宿主的
//! **最小生命周期层**。
//!
//! daemon(`metacodes serve`)一个进程宿主 N 个 session。每个 session = 一个 **SessionHost**:
//! own 一个 EventJournal(U7 有界)+ inbox(客户端消息)+ 一条 driver 线程(跑该 session 的 agent
//! loop 循环)。**SessionRegistry** 是 SessionId→*SessionHost 的加锁表,管**创建/移除/优雅关停**。
//!
//! ## 刻意最小(YAGNI —— 双 re-review 后的收缩)
//! 上一版(v2)在**零消费者**(绑定层/真 driver 都没写,唯一 driver 是测试 fake echo)时,给这层
//! 加了 borrow API(acquire/get)+ refcount teardown + max_sessions/closing/idle 治理 + HostState,
//! 全是猜"未来多线程绑定层"的推测抽象。Linus/PM re-review 一致判过度工程 + 那套 refcount 的 UAF
//! 红灯测试是假绿(testing.allocator 无 UAF 页保护,去掉 fix 照样过)。**故收缩到"任何绑定层都必然
//! 需要"的核心**:创建/移除/关停 + driver 注入 + **abort_fn(优雅关停必须能中断 in-flight run)**。
//!
//! **不含(等真消费者 U10-C/D 出现,按其真实需求再加)**:
//! - **按 id 借用 host 的访问 API**(postMessage/acquire)——绑定层如何路由消息、是否需要跨阻塞调用
//!   持有 host,取决于 UDS/web attach 的真实形态。**没有 borrow API ⇒ 没有跨线程借用 ⇒ 没有 UAF
//!   ⇒ 现在不需要 refcount**。这才是零消费者阶段的诚实姿态。
//! - idle-reap/max-sessions/closing 等治理——有 reaper/accept 循环消费者时再加(设计 §4 已登记 TODO)。
//!
//! ## 并发/所有权
//! - SessionHost **堆分配**(*SessionHost 地址稳:其 journal 内含 mutex/condvar 被 driver 线程 + 未来
//!   附着的 HTTP/UDS 线程跨线程引用,绝不可随 map grow 搬)。
//! - registry.mutex 只护 map 短临界区,**绝不**跨 join/destroy 持有(防关停死锁)。
//! - **优雅关停能中断 in-flight**:requestStop 先 abort_fn(中断 driver 阻塞的网络 IO)再 stop_flag +
//!   journal.close;否则 destroy 的 join 会挂到当前一整轮 agent_loop.run 自然结束。

const std = @import("std");
const sync = @import("platform").sync;
const time = @import("../util/time.zig");
const abort = @import("../util/abort.zig");
const SessionId = @import("../core/session_id.zig").SessionId;
const EventJournal = @import("../web/journal.zig").EventJournal;
const MsgQueue = @import("../repl/msg_queue.zig").MsgQueue;

/// 一个 session 的运行时宿主单元。堆分配,registry 持 *SessionHost。
pub const SessionHost = struct {
    id: SessionId,
    allocator: std.mem.Allocator,
    journal: EventJournal,
    inbox: MsgQueue, // 客户端消息;driver 线程消费(绑定层如何 push 待其定义)
    /// U11:斜杠命令队列(transport 线程只入队,driver 线程独占执行——对齐 web
    /// StateSource.command 的"HTTP 线程绝不碰 App"契约)。
    cmdbox: MsgQueue,

    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// **生成期标志**(driver 维护:一轮 agent_loop.run 期间 true,空闲 false)。transport 的
    /// SessionView.generating 指它:`/interrupt` 只在生成期打 abort(空闲期误打会让下一条消息被
    /// already-aborted 信号即刻吞掉——PM review S1)。单/多 session daemon 共用此门。
    generating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    driver_ctx: *anyopaque,
    driver_fn: *const fn (host: *SessionHost, ctx: *anyopaque) void,
    ctx_deinit_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,
    /// **run-abort 句柄**:requestStop 调它中断 driver in-flight IO(真=app.abort.abort(reason))。
    /// null=cooperative driver(仅靠 stop_flag poll,如测试 echo)。
    abort_fn: ?*const fn (ctx: *anyopaque, reason: abort.Reason) void = null,

    pub fn create(
        allocator: std.mem.Allocator,
        id: SessionId,
        driver_ctx: *anyopaque,
        driver_fn: *const fn (host: *SessionHost, ctx: *anyopaque) void,
        ctx_deinit_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        abort_fn: ?*const fn (ctx: *anyopaque, reason: abort.Reason) void,
    ) !*SessionHost {
        const self = try allocator.create(SessionHost);
        self.* = .{
            .id = id,
            .allocator = allocator,
            .journal = EventJournal.init(allocator),
            .inbox = MsgQueue.init(allocator),
            .cmdbox = MsgQueue.init(allocator),
            .driver_ctx = driver_ctx,
            .driver_fn = driver_fn,
            .ctx_deinit_fn = ctx_deinit_fn,
            .abort_fn = abort_fn,
        };
        return self;
    }

    pub fn start(self: *SessionHost) !void {
        self.thread = try std.Thread.spawn(.{}, driverTrampoline, .{self});
    }

    fn driverTrampoline(self: *SessionHost) void {
        self.driver_fn(self, self.driver_ctx);
    }

    /// host 停止:**先中断 in-flight run**(abort_fn,让阻塞的网络 IO 立即返回)→ stop_flag(cooperative
    /// driver poll 退出)→ close journal(唤醒未来附着的 SSE/UDS waitSince)。幂等
    /// (AbortSignal.abort 幂等 cmpxchg;journal.close 幂等;store 幂等)。
    pub fn requestStop(self: *SessionHost) void {
        if (self.abort_fn) |f| f(self.driver_ctx, .user_ctrl_c);
        self.stop_flag.store(true, .seq_cst);
        self.journal.close();
    }

    pub fn stopRequested(self: *const SessionHost) bool {
        return self.stop_flag.load(.seq_cst);
    }

    fn join(self: *SessionHost) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// 全清(锁外调):requestStop(中断 driver + 唤醒附着者)→ join driver(退出后不再碰 journal/inbox)
    /// → ctx_deinit + deinit journal/inbox + free。**无 borrow API ⇒ 无需等 refcount**:除 driver 线程
    /// (由 join 收敛)外,没有别的线程持有本 host(绑定层的按 id 借用 API 尚未引入)。
    pub fn destroy(self: *SessionHost) void {
        self.requestStop();
        self.join();
        if (self.ctx_deinit_fn) |f| f(self.driver_ctx, self.allocator);
        self.journal.deinit();
        self.inbox.deinit();
        self.cmdbox.deinit();
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

/// SessionId → *SessionHost 加锁表。管创建/移除/关停生命周期。
pub const SessionRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    hosts: std.AutoHashMapUnmanaged(SessionId, *SessionHost) = .{},
    /// 关停已发起(shutdownAll 置位,mutex 保护)。**put 守卫**:关停期(尤其未来 dynamic op=new 由绑定层
    /// accept 线程并发建 session)拒绝新 put——否则 shutdownAll 快照+清 map 后进来的 host 永不被 destroy
    /// (泄漏 + driver 跑在已拆 registry 上)。task#21:accept 循环已落地(WebServer/UdsServer),补此守卫。
    closing: bool = false,

    pub fn init(allocator: std.mem.Allocator) SessionRegistry {
        return .{ .allocator = allocator };
    }

    /// 关停并释放所有 host(shutdownAll)+ 释放 map。
    pub fn deinit(self: *SessionRegistry) void {
        self.shutdownAll();
        _ = self.mutex.lock();
        self.hosts.deinit(self.allocator);
        _ = self.mutex.unlock();
    }

    /// 插入(关停已发起 → ShuttingDown;id 已存在 → AlreadyExists,caller 不泄漏 host)。加锁短临界区。
    pub fn put(self: *SessionRegistry, host: *SessionHost) !void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        if (self.closing) return error.ShuttingDown; // 关停期拒新 session(task#21,防泄漏+UAF)
        if (self.hosts.contains(host.id)) return error.AlreadyExists;
        try self.hosts.put(self.allocator, host.id, host);
    }

    pub fn count(self: *SessionRegistry) usize {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        return self.hosts.count();
    }

    /// 移除并 destroy。**锁内摘 map(取出指针)→ 放锁 → destroy(含 join,绝不持 map 锁)**:避免关停期
    /// join 阻塞与 map 锁叠加死锁。id 不存在=no-op。
    pub fn remove(self: *SessionRegistry, id: SessionId) void {
        _ = self.mutex.lock();
        const host = self.hosts.get(id);
        if (host != null) _ = self.hosts.remove(id);
        _ = self.mutex.unlock();
        if (host) |h| h.destroy();
    }

    /// 优雅关停所有 session。**两阶段**:① 加锁快照全部 *SessionHost + 清 map → 放锁;② 锁外先全
    /// requestStop(并行触发退出,中断各自 in-flight)再逐个 destroy(join+释放)。join/destroy 全在锁外。
    pub fn shutdownAll(self: *SessionRegistry) void {
        _ = self.mutex.lock();
        self.closing = true; // 置于锁内、快照前:此后并发 put 一律 ShuttingDown,无 host 漏出快照(task#21)
        const n = self.hosts.count();
        if (n == 0) {
            _ = self.mutex.unlock();
            return;
        }
        const snap = self.allocator.alloc(*SessionHost, n) catch {
            // OOM 降级:仍**锁外** stop+destroy(固定小批搬出,绝不持锁 join)。
            var pending: [16]*SessionHost = undefined;
            while (true) {
                var k: usize = 0;
                var it = self.hosts.valueIterator();
                while (it.next()) |hp| : (k += 1) {
                    if (k >= pending.len) break;
                    pending[k] = hp.*;
                }
                if (k == 0) break;
                for (pending[0..k]) |h| _ = self.hosts.remove(h.id);
                _ = self.mutex.unlock();
                for (pending[0..k]) |h| h.requestStop();
                for (pending[0..k]) |h| h.destroy();
                _ = self.mutex.lock();
            }
            _ = self.mutex.unlock();
            return;
        };
        var i: usize = 0;
        var it = self.hosts.valueIterator();
        while (it.next()) |hp| : (i += 1) snap[i] = hp.*;
        self.hosts.clearRetainingCapacity();
        _ = self.mutex.unlock();

        for (snap) |h| h.requestStop(); // ① 并行触发退出(中断 in-flight)
        for (snap) |h| h.destroy(); // ② 逐个 join+释放(锁外)
        self.allocator.free(snap);
    }
};

// ============================================================================
// Tests —— 精简核心的生命周期 + 关停能中断 in-flight。真 App driver 在绑定层(U10-C/D)接入并 e2e。
// **注册在 main.zig 测试聚合器(`_ = &@import`)——否则 lazy analysis 整个跳过本文件(含编译错+测试)。**
// ============================================================================

const testing = std.testing;

/// fake cooperative driver:poll host.stop + 消费 inbox echo 进 journal。
fn echoDriver(host: *SessionHost, ctx: *anyopaque) void {
    _ = ctx;
    while (!host.stopRequested()) {
        if (host.inbox.popFront()) |m| {
            defer host.allocator.free(m);
            host.journal.append(m);
        } else {
            time.sleepMs(2);
        }
    }
}

/// **阻塞式** fake driver:模拟真 driver 卡在网络 IO(只等 abort,**不** poll stop_flag),退出时置
/// exited 标志。验 abort_fn 能中断它。
const BlockingCtx = struct {
    sig: abort.AbortSignal,
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};
fn blockingDriver(host: *SessionHost, ctx: *anyopaque) void {
    _ = host;
    const bc: *BlockingCtx = @ptrCast(@alignCast(ctx));
    while (!bc.sig.isAborted()) time.sleepMs(1); // 卡在"IO",只有 abort 能救
    bc.exited.store(true, .release);
}
fn blockingAbort(ctx: *anyopaque, reason: abort.Reason) void {
    const bc: *BlockingCtx = @ptrCast(@alignCast(ctx));
    bc.sig.abort(reason);
}

fn idFrom(n: u8) SessionId {
    var id = SessionId.single;
    id.bytes[0] = n;
    return id;
}

test "U10-A: 两 session 各自 journal 独立,消息不串台" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    defer reg.deinit();

    var dummy: u8 = 0;
    const h1 = try SessionHost.create(a, idFrom('A'), @ptrCast(&dummy), echoDriver, null, null);
    const h2 = try SessionHost.create(a, idFrom('B'), @ptrCast(&dummy), echoDriver, null, null);
    try reg.put(h1);
    try reg.put(h2);
    try h1.start();
    try h2.start();
    try testing.expectEqual(@as(usize, 2), reg.count());

    // 测试持有 h1/h2 的直接引用(创建者),直接 push——绑定层的按 id 路由 API 尚未引入(option B)。
    _ = h1.inbox.push("hello-A");
    _ = h2.inbox.push("hello-B");

    var waited: usize = 0;
    while ((h1.journal.count() == 0 or h2.journal.count() == 0) and waited < 500) : (waited += 1) {
        time.sleepMs(2);
    }
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
}

test "U10-A: abort_fn 中断阻塞在 IO 的 driver → 有界内退出(真红灯:去掉 abort 则 exited 永假)" {
    // **真红灯**:blockingDriver 只等 abort、不 poll stop。requestStop 若不调 abort_fn,driver 不退出,
    // exited 永假 → 下方 2s 有界断言**干净失败**。cleanup **绕过 requestStop 直接强制 abort**——即便
    // requestStop 的 abort 坏了,driver 也退出、join/destroy 不挂死(断言 fail 后进程仍干净退出,非 CI
    // 超时)。故这是"去掉 fix 就变红且不挂"的真守护。host 不入 registry(手工管生命周期,cleanup 可控)。
    const a = testing.allocator;
    const bc = try a.create(BlockingCtx);
    bc.* = .{ .sig = abort.AbortSignal.init() };
    const h = try SessionHost.create(a, idFrom('K'), @ptrCast(bc), blockingDriver, null, blockingAbort);
    try h.start();
    defer {
        bc.sig.abort(.user_ctrl_c); // 强制兜底:即便 requestStop 的 abort 坏了,driver 也退出 → join 不挂
        h.destroy();
        a.destroy(bc);
    }

    h.requestStop(); // 应经 abort_fn 中断 driver
    // 有界等 driver 退出(≤2s);abort 坏 → exited 永假 → 断言干净失败(cleanup 强制 abort 保证不挂)。
    var waited: usize = 0;
    while (!bc.exited.load(.acquire) and waited < 2000) : (waited += 1) time.sleepMs(1);
    try testing.expect(bc.exited.load(.acquire)); // 真红灯锚点
}

test "U10-A: shutdownAll 优雅关停全部,count 归零 join 不挂" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    var dummy: u8 = 0;
    var n: u8 = 0;
    while (n < 5) : (n += 1) {
        const h = try SessionHost.create(a, idFrom('a' + n), @ptrCast(&dummy), echoDriver, null, null);
        try reg.put(h);
        try h.start();
    }
    try testing.expectEqual(@as(usize, 5), reg.count());
    reg.shutdownAll();
    try testing.expectEqual(@as(usize, 0), reg.count());
    reg.deinit();
}

test "U10-A: remove 单个 session 优雅摘除,其余不受影响" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    defer reg.deinit();
    var dummy: u8 = 0;
    const h1 = try SessionHost.create(a, idFrom('X'), @ptrCast(&dummy), echoDriver, null, null);
    const h2 = try SessionHost.create(a, idFrom('Y'), @ptrCast(&dummy), echoDriver, null, null);
    try reg.put(h1);
    try reg.put(h2);
    try h1.start();
    try h2.start();

    reg.remove(idFrom('X'));
    try testing.expectEqual(@as(usize, 1), reg.count());
}

test "U10-A: 关停后 put → ShuttingDown(task#21 守卫:关停期不收新 session)" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    defer reg.deinit();
    var dummy: u8 = 0;
    const h1 = try SessionHost.create(a, idFrom('P'), @ptrCast(&dummy), echoDriver, null, null);
    try reg.put(h1);
    try h1.start();
    reg.shutdownAll(); // 置 closing,清空并关停 h1
    try testing.expectEqual(@as(usize, 0), reg.count());
    // 关停后新 host 被拒(caller 自行释放,不入 registry → 不泄漏 / 不 UAF)。
    const h2 = try SessionHost.create(a, idFrom('Q'), @ptrCast(&dummy), echoDriver, null, null);
    try testing.expectError(error.ShuttingDown, reg.put(h2));
    h2.destroy();
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "U10-A: put 重复 id → AlreadyExists(不覆盖不泄漏)" {
    const a = testing.allocator;
    var reg = SessionRegistry.init(a);
    defer reg.deinit();
    var dummy: u8 = 0;
    const h1 = try SessionHost.create(a, idFrom('Z'), @ptrCast(&dummy), echoDriver, null, null);
    try reg.put(h1);
    try h1.start();
    const h2 = try SessionHost.create(a, idFrom('Z'), @ptrCast(&dummy), echoDriver, null, null);
    try testing.expectError(error.AlreadyExists, reg.put(h2));
    h2.destroy(); // 未进 registry,caller 释放
    try testing.expectEqual(@as(usize, 1), reg.count());
}
