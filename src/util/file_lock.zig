//! 跨进程文件锁(对齐 cc proper-lockfile 语义,精简实现)。
//!
//! 用途:通用的共享文件读-改-写互斥(与 swarm 无关,故落在 util/)。消费者:
//! swarm/team(config.json)、swarm/mailbox(inboxes/<name>.json)、
//! core/task_store(镜像事务)、kg/client(迁移锁)。
//! 机制:`<path>.lock` 哨兵文件,O_CREAT|O_EXCL 原子创建=持锁;文件内容是
//! `{pid} {wall_ms}`,供陈旧检测(持锁者崩溃后 stale_ms 过期可抢)。
//!
//! 语义要点(陈旧检测参数对齐 cc teammateMailbox.ts:35;重试预算**有意偏离** cc,见下):
//!   - 重试:默认 100 次,退避 5ms→100ms(指数,cap 100,±25% 抖动),总等待 ~9.7s ≈ stale_ms。
//!     **不变式:活的持锁者必然让出(等到为止),死的持锁者到 stale_ms 被 steal 接管——
//!     LockBusy 只剩真异常。** cc 的 10 次/~655ms 按 Node 单事件循环设计(持锁窗口 ~1ms,
//!     饿死不可能);in-process swarm 是真线程,CPU 饱和下持锁线程可被调度延迟 100ms+,
//!     655ms 预算 11 次探测可能全输(2026-07-18 实测 ~20% 假 LockBusy)。对齐 cc 的是
//!     可观测语义(持有者活着就绝不虚报失败),不是参数字面值。
//!   - 陈旧:锁文件时间戳距今 > stale_ms(默认 10s,proper-lockfile 默认)视为死锁残留,
//!     接管时每条陈旧记录单赢家(见 stealObserved):先 O_EXCL 认领这条记录,认领后确认锁文件
//!     仍是它才 unlink 并 EXCL 重建。**抢锁者只删自己观测到的那条陈旧记录**,别人刚抢到的新锁
//!     不会被挪走或删掉。前提与重试预算同源:持锁/认领窗口里停顿超过 stale_ms 的一方视同已死。
//!   - 释放:unlink。释放非持有的锁是 bug,但实现上不校验 pid(cc 也不校验)。
//!
//! 平台:POSIX(std.c.unlink)。Windows 移植归 W2 workstream(platform/fs 已备 EXCL)。

const std = @import("std");
const pfs = @import("platform").fs;
const util_time = @import("time.zig");
const log = @import("log.zig");
const read_state = @import("../core/read_state.zig");

const is_windows = @import("builtin").os.tag == .windows;

pub const LockError = error{
    LockBusy, // 重试耗尽仍未获得
    PathTooLong,
    NoParentDir, // 目标目录不存在(锁文件永远建不出来,重试无意义)
};

pub const Options = struct {
    retries: u32 = 100,
    min_backoff_ms: u64 = 5,
    max_backoff_ms: u64 = 100,
    stale_ms: i128 = 10_000,
};

/// 持锁句柄。release() 释放。
pub const Lock = struct {
    lock_path: [std.fs.max_path_bytes]u8 = undefined,
    lock_path_len: usize = 0,

    /// 锁文件路径(NUL 结尾)。
    fn pathZ(self: *Lock) [*:0]const u8 {
        self.lock_path[self.lock_path_len] = 0;
        return @ptrCast(&self.lock_path);
    }

    pub fn release(self: *Lock) void {
        if (self.lock_path_len == 0) return;
        self.lock_path[self.lock_path_len] = 0;
        // unlink 失败必须重试:Windows 上并发读句柄(诊断路径/Defender 扫描)让 DeleteFile 吃
        // sharing violation;静默泄漏 = 全体等待者卡到 stale_ms。碰撞窗口 µs 级,短重试必过。
        var attempt: u32 = 0;
        // 宽字符删除(#121):锁文件由 pfs.open 按精确名创建,删除也必须按精确名,否则中文路径下
        // 窄字符 unlink 永远删不到、exists 却一直看得见 → 重试烧完、锁泄漏。
        while (true) {
            pfs.unlinkPath(@ptrCast(&self.lock_path)) catch |err| {
                if (err == error.NotFound) break; // 已消失(如被 steal)= 达成目的
                attempt += 1;
                if (attempt > 20) {
                    log.warn("file_lock", "release unlink 反复失败,锁文件泄漏: {s}", .{self.lock_path[0..self.lock_path_len]});
                    break;
                }
                util_time.sleepMs(2);
                continue;
            };
            break;
        }
        self.lock_path_len = 0;
    }
};

/// 对 target_path 加锁(锁文件为 `<target_path>.lock`)。成功返回 Lock,失败 LockBusy。
pub fn acquire(target_path: []const u8, opts: Options) LockError!Lock {
    var lock = try lockFor(target_path);

    var attempt: u32 = 0;
    var backoff: u64 = opts.min_backoff_ms;
    while (attempt <= opts.retries) : (attempt += 1) {
        if (tryCreate(&lock)) return lock;
        // 父目录不存在 → 永远建不出锁,立即报错(否则空耗重试后伪装成 LockBusy)。
        if (pfs.lastErrnoIs(.NOENT)) return error.NoParentDir;
        // 创建失败:现任记录陈旧就接管它(持锁时刻的来源分平台,见 observe)。
        if (observe(lock.pathZ())) |seen| {
            if (nowWallMs() - seen.held_ms > opts.stale_ms and stealObserved(&lock, &seen.record, opts)) return lock;
        }
        if (attempt == opts.retries) break;
        // 退避加 ±25% 抖动:多个败者同步睡醒会再次同时探测(lock convoy),抖动去相关。
        // 随机源用单调钟低位即可(只求打散,不求密码学)。
        const j = backoff / 4;
        const jittered = if (j > 0)
            backoff - j + @as(u64, @intCast(@mod(util_time.nowNs(), @as(i128, 2 * j + 1))))
        else
            backoff;
        util_time.sleepMs(jittered);
        backoff = @min(backoff * 2, opts.max_backoff_ms);
    }
    // 预算耗尽:落一条持锁者取证(pid/锁龄)再报 LockBusy。预算 ≈ stale_ms 的不变式下,
    // 走到这里 = 有活着的持锁者占了全预算 —— 这是异常,值得知道"谁、多久"。
    {
        const now_ms: i128 = @divTrunc(util_time.nowWallNs(), 1_000_000);
        const held_ms: ?i128 = readLockWallMs(&lock) orelse lockMtimeMs(&lock);
        const age: i128 = if (held_ms) |hm| now_ms - hm else -1;
        log.warn("file_lock", "acquire 预算耗尽: path={s} holder_pid={d} lock_age_ms={d}", .{
            lock.lock_path[0..lock.lock_path_len], readLockPid(&lock) orelse -1, age,
        });
    }
    lock.lock_path_len = 0; // 未持锁,防误 release
    return error.LockBusy;
}

/// 认领文件后缀 `.claim.<16 hex 记录指纹>.<代>` 的最大长度(见 stealObserved)。
const claim_suffix_max = ".claim.".len + 16 + ".".len + 3;
/// 一条陈旧记录最多试几代认领:每进一代,都要上一代的认领者死在 µs 级的认领窗口里。
const max_claim_generations: u8 = 8;

/// `target_path` 的锁句柄(锁文件 `<target_path>.lock`),尚未持锁。认领路径(锁路径 + 认领
/// 后缀)也得放得下:放不下的锁一旦陈旧就永远接管不了,不如一开始就报 PathTooLong。
fn lockFor(target_path: []const u8) LockError!Lock {
    var lock: Lock = .{};
    const suffix = ".lock";
    if (target_path.len + suffix.len + claim_suffix_max + 1 >= lock.lock_path.len) return error.PathTooLong;
    @memcpy(lock.lock_path[0..target_path.len], target_path);
    @memcpy(lock.lock_path[target_path.len..][0..suffix.len], suffix);
    lock.lock_path_len = target_path.len + suffix.len;
    lock.lock_path[lock.lock_path_len] = 0;
    return lock;
}

/// 一条记录的身份。同一次 O_EXCL 创建出的文件在持锁者释放或被接管之前这几项都不变;另一次
/// 创建(哪怕同一进程)至少 mtime 或内容不同。接管前的"还是不是它"按它逐项比对。
const Record = struct {
    mtime_ns: i128,
    size: u64,
    /// POSIX:文件内容 `{pid} {wall_ms}`(至多 64 字节);Windows 不读内容(零句柄,见 observe),恒空。
    content: [64]u8 = undefined,
    content_len: usize = 0,

    fn bytes(self: *const Record) []const u8 {
        return self.content[0..self.content_len];
    }

    fn eql(a: *const Record, b: *const Record) bool {
        return a.mtime_ns == b.mtime_ns and a.size == b.size and std.mem.eql(u8, a.bytes(), b.bytes());
    }

    /// 认领文件名里的记录指纹。FNV-1a 按规格定死,所有进程对同一条记录算出同一个名字。
    fn fingerprint(self: *const Record) u64 {
        var fnv = std.hash.Fnv1a_64.init();
        var head: [96]u8 = undefined;
        fnv.update(std.fmt.bufPrint(&head, "{d}|{d}|", .{ self.mtime_ns, self.size }) catch unreachable);
        fnv.update(self.bytes());
        return fnv.final();
    }
};

const Observation = struct {
    record: Record,
    /// 陈旧判定用的持锁时刻(wall ms)。
    held_ms: i128,
};

/// 观测 `path` 上的现任记录;文件不在 → null。持锁时刻的来源分平台:
/// - POSIX:同一个 fd 上 fstat + 读内容(身份各项出自同一 inode)。内容里的 wall_ms 优先(写入即
///   持锁时刻);读不到/解析不了(持锁者在 open 与 write 之间崩溃 → 空锁文件)退回 mtime。
///   (Linus MED-2:null 分支永不抢 → 死锁。)
/// - Windows:**只用 mtime(GetFileAttributesEx,零句柄)**。内容读取要 open,而 CRT open
///   无 FILE_SHARE_DELETE——探测读句柄的 µs 窗口撞上持锁者 release 的 unlink,DeleteFile
///   吃 sharing violation 静默失败 → 锁文件泄漏,全体等待者卡到 stale_ms 才能 steal,
///   期间到达者全部假 LockBusy(2026-07-18 实测 ~10-20% 失败率的真根因;探测频率 ×
///   等待者数 × 读窗口的碰撞概率与实测吻合)。mtime 语义等价:tryCreate 创建即写。
fn observe(path: [*:0]const u8) ?Observation {
    if (is_windows) {
        const st = read_state.statPath(std.mem.span(path)) catch return null;
        return .{
            .record = .{ .mtime_ns = st.mtime_ns, .size = st.size },
            .held_ms = @divTrunc(st.mtime_ns, std.time.ns_per_ms),
        };
    }
    const fd = pfs.open(path, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return null;
    defer pfs.close(fd);
    const st = read_state.statFd(fd) catch return null;
    var record: Record = .{ .mtime_ns = st.mtime_ns, .size = st.size };
    const n = pfs.read(fd, &record.content);
    record.content_len = if (n > 0) @intCast(n) else 0;
    return .{
        .record = record,
        .held_ms = parseWallMs(record.bytes()) orelse @divTrunc(st.mtime_ns, std.time.ns_per_ms),
    };
}

/// 接管一条**观测到的**陈旧记录,每条记录单赢家。返回 true = 已持锁。
///
/// 旧做法(Linus review HIGH-1 的"rename 到墓碑再 create")并不单赢:两个抢锁者都判定陈旧,
/// 先到者 rename + create 拿到新锁后,迟到者的 rename 挪走的是那把**新锁**,再 create → 双持有。
/// "挪走后发现不对再放回"也不行:挪走期间锁路径是空的,第三方的 EXCL 能建成,放回时撞上它 →
/// 仍双持有。现在的规则:
///   1. O_EXCL 建本记录专属的认领文件 `<lock>.claim.<指纹>.<代>`:同一条记录的同一代只有一个
///      抢锁者建得出来;
///   2. 持认领后重新观测锁文件,**仍是观测到的那条记录**才 unlink 并 EXCL 重建;已换成别的记录
///      (被别人接管了)就放手退避。抢锁者只删自己观测到的那条陈旧记录,新锁从不被挪动;
///   3. 认领文件只由其创建者删除。
/// 持认领期间能删掉这条记录的只有认领者自己:别的抢锁者建不出同名认领,正常 acquirer 的 EXCL 在
/// 记录存在时必败,陈旧记录的持锁者按不变式已死。认领者死在 µs 级的认领窗口里会留下一份认领:
/// 它新鲜时其余抢锁者退让;过了 stale_ms 就换下一代认领,而不是删掉它重建——删与建之间别人同样
/// 能删掉新认领,又回到双赢家。崩溃只会留下无人问津的认领文件,不影响正确性。
fn stealObserved(lock: *Lock, observed: *const Record, opts: Options) bool {
    var claim_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var gen: u8 = 0;
    const claim = while (gen < max_claim_generations) : (gen += 1) {
        const path = claimPath(&claim_buf, lock, observed, gen);
        if (createRecord(path.ptr)) break path;
        if (!pfs.lastErrnoIs(.EXIST)) {
            // Windows 上创建者正在删同名认领(delete pending)也会走到这里:退避重试即可。
            if (!pfs.isWindowsTransientFileError(true)) {
                const e = pfs.lastErrno();
                log.warn("file_lock", "认领文件建不出 errno={s}({d}),本轮不接管: {s}", .{ pfs.errnoName(e), e, path });
            }
            return false;
        }
        // 同代认领已存在:新鲜 = 有人正在接管这条记录,退让;刚被收走 = 那人已接管完,退避后看到的
        // 是它的新锁;陈旧 = 认领者死在了窗口里,换下一代。
        const claimant = observe(path.ptr) orelse return false;
        if (nowWallMs() - claimant.held_ms <= opts.stale_ms) return false;
    } else {
        log.warn("file_lock", "陈旧锁的 {d} 代认领全部陈旧,放弃接管: {s}", .{ max_claim_generations, lock.lock_path[0..lock.lock_path_len] });
        return false;
    };
    defer pfs.unlinkPath(claim.ptr) catch {};

    // 记录已不在(持锁者其实活着、刚释放):路径空了,EXCL 与正常 acquirer 公平竞争。
    const current = observe(lock.pathZ()) orelse return tryCreate(lock);
    if (!current.record.eql(observed)) return false; // 已被别人接管:不碰
    pfs.unlinkPath(lock.pathZ()) catch |err| switch (err) {
        error.NotFound => {},
        error.UnlinkFailed => return false, // Windows 共享冲突等:退避重试
    };
    return tryCreate(lock);
}

/// 认领文件路径 `<lock>.claim.<记录指纹>.<代>`,NUL 结尾写进 buf。
fn claimPath(buf: *[std.fs.max_path_bytes:0]u8, lock: *const Lock, record: *const Record, gen: u8) [:0]const u8 {
    const lock_path = lock.lock_path[0..lock.lock_path_len];
    return std.fmt.bufPrintZ(buf, "{s}.claim.{x:0>16}.{d}", .{ lock_path, record.fingerprint(), gen }) catch unreachable; // lockFor 已留足后缀长度
}

/// 读锁文件里的 pid(第一个字段)。读不到/解析失败 → null。
fn readLockPid(lock: *Lock) ?i64 {
    const fd = pfs.open(@ptrCast(&lock.lock_path), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return null;
    defer pfs.close(fd);
    var buf: [64]u8 = undefined;
    const n = pfs.read(fd, &buf);
    if (n <= 0) return null;
    const body = buf[0..@intCast(n)];
    const sp = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    return std.fmt.parseInt(i64, body[0..sp], 10) catch null;
}

/// 锁文件 mtime(wall 毫秒)。stat 失败(文件已消失等)→ null。
fn lockMtimeMs(lock: *Lock) ?i128 {
    const st = read_state.statPath(lock.lock_path[0..lock.lock_path_len]) catch return null;
    return @divTrunc(@as(i128, st.mtime_ns), 1_000_000);
}

/// O_CREAT|O_EXCL 尝试创建锁文件并写入 `{pid} {wall_ms}`。成功=true。
fn tryCreate(lock: *Lock) bool {
    return createRecord(lock.pathZ());
}

/// O_CREAT|O_EXCL 创建 `path` 并写入 `{pid} {wall_ms}`(锁文件与认领文件同一格式)。成功 = 本次
/// 调用独占创建了它;失败时 errno 仍是 open 留下的。
fn createRecord(path: [*:0]const u8) bool {
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c_uint, 0o644));
    if (fd < 0) return false;
    defer pfs.close(fd);
    var buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{d} {d}", .{ pid(), nowWallMs() }) catch return true;
    _ = pfs.write(fd, body);
    return true;
}

/// 读锁文件里的 wall_ms(第二个字段)。读不到/解析失败 → null。
fn readLockWallMs(lock: *Lock) ?i128 {
    const fd = pfs.open(@ptrCast(&lock.lock_path), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return null;
    defer pfs.close(fd);
    var buf: [64]u8 = undefined;
    const n = pfs.read(fd, &buf);
    if (n <= 0) return null;
    return parseWallMs(buf[0..@intCast(n)]);
}

/// `{pid} {wall_ms}` 里的 wall_ms。解析不了 → null。
fn parseWallMs(body: []const u8) ?i128 {
    const sp = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    const ms_str = std.mem.trim(u8, body[sp + 1 ..], " \n\r\t");
    return std.fmt.parseInt(i128, ms_str, 10) catch null;
}

fn nowWallMs() i128 {
    return @divTrunc(util_time.nowWallNs(), std.time.ns_per_ms);
}

fn pid() i64 {
    // Windows std.c.getpid 返回 HANDLE(*anyopaque),不能 @intCast;用 kernel32 GetCurrentProcessId。
    if (@import("builtin").os.tag == .windows) {
        const w = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
        };
        return @intCast(w.GetCurrentProcessId());
    }
    return @intCast(std.c.getpid());
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const test_fs = @import("fs.zig");

fn testDir(buf: []u8) ![]const u8 {
    const d = @import("fs.zig").testing.uniqueDir(buf, "cc-zig-filelock-test");
    try test_fs.mkdirParents(d);
    return d;
}

test "acquire + release 往返" {
    var dbuf: [256]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});

    var lock = try acquire(target, .{});
    // 锁文件存在。
    var lbuf: [256:0]u8 = undefined;
    const lp = try std.fmt.bufPrintZ(&lbuf, "{s}.lock", .{target});
    try testing.expect(pfs.exists(lp.ptr));
    lock.release();
    try testing.expect(!pfs.exists(lp.ptr));
}

test "二次 acquire 被拒(LockBusy),释放后可再获" {
    var dbuf: [256]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});

    var l1 = try acquire(target, .{});
    // 少量重试快速失败(fresh 锁不可抢)。
    try testing.expectError(error.LockBusy, acquire(target, .{ .retries = 2, .min_backoff_ms = 1, .max_backoff_ms = 2 }));
    l1.release();
    var l2 = try acquire(target, .{ .retries = 0 });
    l2.release();
}

test "陈旧锁被抢" {
    var dbuf: [256]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});

    // 手工伪造一个 20s 前的锁(内容时间戳)。Windows 判陈旧只看 mtime(见 observe 注释),
    // 伪造内容不改 mtime → 用"真实流逝 30ms + stale_ms=5"让两平台都走到 steal;
    // POSIX 侧同时验证内容时间戳优先(20s ≫ 5ms,即便 mtime 判定不同也必陈旧)。
    var lbuf: [256:0]u8 = undefined;
    const lp = try std.fmt.bufPrintZ(&lbuf, "{s}.lock", .{target});
    const fd = pfs.open(lp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
    try testing.expect(fd >= 0);
    const now_ms: i128 = @divTrunc(util_time.nowWallNs(), 1_000_000);
    var body_buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "99999 {d}", .{now_ms - 20_000});
    _ = pfs.write(fd, body);
    pfs.close(fd);

    util_time.sleepMs(30);
    var lock = try acquire(target, .{ .retries = 2, .min_backoff_ms = 1, .max_backoff_ms = 2, .stale_ms = 5 });
    lock.release();
}

test "空内容陈旧锁也能被抢(mtime 兜底,Linus MED-2 回归)" {
    var dbuf: [256]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});

    // 伪造"持锁者在 open 与 write 之间崩溃"——空锁文件(无时间戳内容)。
    var lbuf: [300:0]u8 = undefined;
    const lp = try std.fmt.bufPrintZ(&lbuf, "{s}.lock", .{target});
    const fd = pfs.open(lp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
    try testing.expect(fd >= 0);
    pfs.close(fd);

    // mtime 是"现在"→ 等 30ms 后用 stale_ms=5 判陈旧,应经 mtime 兜底完成抢锁。
    util_time.sleepMs(30);
    var lock = try acquire(target, .{ .retries = 2, .min_backoff_ms = 1, .max_backoff_ms = 2, .stale_ms = 5 });
    lock.release();
}

test "路径过长报错" {
    const long = "x" ** (std.fs.max_path_bytes);
    try testing.expectError(error.PathTooLong, acquire(long, .{}));
}

/// 伪造一条持锁者早已死掉的记录:POSIX 按内容 wall_ms 判陈旧(写成 20s 前);Windows 只看
/// mtime,调用方要先等真实时间流逝、再配 stale_ms=5(同"陈旧锁被抢")。
fn writeStaleRecord(path: [*:0]const u8) !void {
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.TestFixtureOpenFailed;
    defer pfs.close(fd);
    var body_buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "99999 {d}", .{nowWallMs() - 20_000});
    if (pfs.write(fd, body) != body.len) return error.TestFixtureWriteFailed;
}

test "陈旧锁已被别人接管:迟到的抢锁者不删那把新锁,自己也拿不到" {
    var dbuf: [256]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});
    const opts: Options = .{ .retries = 2, .min_backoff_ms = 1, .max_backoff_ms = 2, .stale_ms = 5 };

    var late = try lockFor(target); // B:尚未持锁的句柄
    try writeStaleRecord(late.pathZ());
    util_time.sleepMs(30); // Windows 只看 mtime:让它也过 stale_ms

    // B 观测到陈旧记录、判定可抢,随即被调度走。
    const stale = observe(late.pathZ()) orelse return error.TestUnexpectedResult;
    try testing.expect(nowWallMs() - stale.held_ms > opts.stale_ms);

    // A 这时接管了那条陈旧记录,持有新锁。
    var holder = try acquire(target, opts);
    defer holder.release();
    const fresh = observe(holder.pathZ()) orelse return error.TestUnexpectedResult;
    try testing.expect(!fresh.record.eql(&stale.record));

    // B 醒来,按早先的观测接着抢:必须放手,A 的新锁原样留在盘上。
    try testing.expect(!stealObserved(&late, &stale.record, opts));
    const after = observe(holder.pathZ()) orelse return error.TestUnexpectedResult;
    try testing.expect(after.record.eql(&fresh.record));
    var cbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    try testing.expect(!pfs.exists(claimPath(&cbuf, &late, &stale.record, 0).ptr)); // 认领都由创建者收走了
}

test "陈旧记录正被别人认领接管:其余抢锁者退让,不碰锁文件也不删别人的认领" {
    var dbuf: [256]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});

    var late = try lockFor(target);
    try writeStaleRecord(late.pathZ());
    const stale = observe(late.pathZ()) orelse return error.TestUnexpectedResult;
    // 另一个抢锁者刚认领了这条记录(认领新鲜,stale_ms 取 10s 让各平台都判它新鲜)。
    var cbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    const claim = claimPath(&cbuf, &late, &stale.record, 0);
    try testing.expect(createRecord(claim.ptr));

    try testing.expect(!stealObserved(&late, &stale.record, .{ .stale_ms = 10_000 }));
    const after = observe(late.pathZ()) orelse return error.TestUnexpectedResult;
    try testing.expect(after.record.eql(&stale.record));
    try testing.expect(pfs.exists(claim.ptr));
}

test "认领者死在认领窗口里:留下的陈旧认领不会永久卡住接管(换下一代)" {
    var dbuf: [256]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});

    var probe = try lockFor(target);
    try writeStaleRecord(probe.pathZ());
    const stale = observe(probe.pathZ()) orelse return error.TestUnexpectedResult;
    var c0buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const claim0 = claimPath(&c0buf, &probe, &stale.record, 0);
    try writeStaleRecord(claim0.ptr); // 死去的认领者留下的第 0 代认领
    util_time.sleepMs(30); // Windows 只看 mtime

    var lock = try acquire(target, .{ .retries = 2, .min_backoff_ms = 1, .max_backoff_ms = 2, .stale_ms = 5 });
    defer lock.release();
    var c1buf: [std.fs.max_path_bytes:0]u8 = undefined;
    try testing.expect(!pfs.exists(claimPath(&c1buf, &probe, &stale.record, 1).ptr)); // 自己那代已收走
    try testing.expect(pfs.exists(claim0.ptr)); // 认领只由创建者删,死者的留着
}
