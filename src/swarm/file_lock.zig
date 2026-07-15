//! 跨进程文件锁(对齐 cc proper-lockfile 语义,精简实现)。
//!
//! 用途:swarm 共享 JSON 文件(team config.json / inboxes/<name>.json)的互斥写。
//! 机制:`<path>.lock` 哨兵文件,O_CREAT|O_EXCL 原子创建=持锁;文件内容是
//! `{pid} {wall_ms}`,供陈旧检测(持锁者崩溃后 stale_ms 过期可抢)。
//!
//! 语义要点(cc teammateMailbox.ts:35 同款参数):
//!   - 重试:默认 10 次,退避 5ms→100ms(指数,cap 100)。
//!   - 陈旧:锁文件时间戳距今 > stale_ms(默认 10s,proper-lockfile 默认)视为死锁残留,
//!     unlink 后重试 EXCL。两个抢锁者最多一个赢得 EXCL(unlink+create 竞态下另一方再退避)。
//!   - 释放:unlink。释放非持有的锁是 bug,但实现上不校验 pid(cc 也不校验)。
//!
//! 平台:POSIX(std.c.unlink)。Windows 移植归 W2 workstream(platform/fs 已备 EXCL)。

const std = @import("std");
const pfs = @import("platform").fs;
const util_time = @import("../util/time.zig");

pub const LockError = error{
    LockBusy, // 重试耗尽仍未获得
    PathTooLong,
    NoParentDir, // 目标目录不存在(锁文件永远建不出来,重试无意义)
};

pub const Options = struct {
    retries: u32 = 10,
    min_backoff_ms: u64 = 5,
    max_backoff_ms: u64 = 100,
    stale_ms: i128 = 10_000,
};

/// 持锁句柄。release() 释放。
pub const Lock = struct {
    lock_path: [std.fs.max_path_bytes]u8 = undefined,
    lock_path_len: usize = 0,

    pub fn release(self: *Lock) void {
        if (self.lock_path_len == 0) return;
        self.lock_path[self.lock_path_len] = 0;
        _ = std.c.unlink(@ptrCast(&self.lock_path));
        self.lock_path_len = 0;
    }
};

/// 对 target_path 加锁(锁文件为 `<target_path>.lock`)。成功返回 Lock,失败 LockBusy。
pub fn acquire(target_path: []const u8, opts: Options) LockError!Lock {
    var lock: Lock = .{};
    const suffix = ".lock";
    if (target_path.len + suffix.len + 1 >= lock.lock_path.len) return error.PathTooLong;
    @memcpy(lock.lock_path[0..target_path.len], target_path);
    @memcpy(lock.lock_path[target_path.len..][0..suffix.len], suffix);
    lock.lock_path_len = target_path.len + suffix.len;
    lock.lock_path[lock.lock_path_len] = 0;

    var attempt: u32 = 0;
    var backoff: u64 = opts.min_backoff_ms;
    while (attempt <= opts.retries) : (attempt += 1) {
        if (tryCreate(&lock)) return lock;
        // 父目录不存在 → 永远建不出锁,立即报错(否则空耗重试后伪装成 LockBusy)。
        if (@as(std.c.E, @enumFromInt(std.c._errno().*)) == .NOENT) return error.NoParentDir;
        // 创建失败:检查陈旧锁。时间戳来源两层——锁文件内容里的 wall_ms;内容读不到/解析不了
        // (持锁者在 open 与 write 之间崩溃 → 空锁文件)则退回文件 mtime。两层都不可用说明
        // 文件刚消失,直接退避重试即可。(Linus review MED-2:老版本 null 分支永不抢 → 空锁死锁。)
        const held_ms: ?i128 = readLockWallMs(&lock) orelse lockMtimeMs(&lock);
        if (held_ms) |hm| {
            const now_ms: i128 = @divTrunc(util_time.nowWallNs(), 1_000_000);
            if (now_ms - hm > opts.stale_ms) {
                // 陈旧:**原子两阶段抢锁**(Linus review HIGH-1)。直接 unlink+create 会双持有:
                // 两个抢锁者都判定陈旧,P2 unlink→create 拿到新锁后,P3 的 unlink 会把 P2 的
                // *新*锁删掉再 create → 双持有写坏邮箱。改为先把陈旧锁 rename 到抢锁者私有名:
                // rename 是原子的,同一源文件只有一个 rename 赢家 → 只有赢家有资格 create。
                // 输家 ENOENT → 退避重试(此后看到的是赢家的新鲜锁,不再陈旧)。
                if (stealRename(&lock)) {
                    if (tryCreate(&lock)) return lock;
                    // create 输给了并行的正常 acquirer(EXCL 单赢家):退避重试。
                }
            }
        }
        if (attempt == opts.retries) break;
        util_time.sleepMs(backoff);
        backoff = @min(backoff * 2, opts.max_backoff_ms);
    }
    lock.lock_path_len = 0; // 未持锁,防误 release
    return error.LockBusy;
}

/// 抢锁第一阶段:把陈旧锁文件原子 rename 到本进程私有的墓碑名并删除。
/// 返回 true = 本进程是唯一 rename 赢家(有资格 create 新锁)。
/// 崩溃窗口(rename 后、unlink 前)只会留下无人问津的墓碑文件,不影响正确性。
fn stealRename(lock: *Lock) bool {
    var grave: [std.fs.max_path_bytes:0]u8 = undefined;
    const g = std.fmt.bufPrintZ(&grave, "{s}.steal{d}", .{ lock.lock_path[0..lock.lock_path_len], pid() }) catch return false;
    lock.lock_path[lock.lock_path_len] = 0;
    if (std.c.rename(@ptrCast(&lock.lock_path), g.ptr) != 0) return false;
    _ = std.c.unlink(g.ptr);
    return true;
}

/// 锁文件 mtime(wall 毫秒)。stat 失败(文件已消失等)→ null。
fn lockMtimeMs(lock: *Lock) ?i128 {
    const read_state = @import("../core/read_state.zig");
    const st = read_state.statPath(lock.lock_path[0..lock.lock_path_len]) catch return null;
    return @divTrunc(@as(i128, st.mtime_ns), 1_000_000);
}

/// O_CREAT|O_EXCL 尝试创建锁文件并写入 `{pid} {wall_ms}`。成功=true。
fn tryCreate(lock: *Lock) bool {
    const fd = pfs.open(
        @ptrCast(&lock.lock_path),
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true },
        @as(c_uint, 0o644),
    );
    if (fd < 0) return false;
    defer pfs.close(fd);
    var buf: [64]u8 = undefined;
    const now_ms: i128 = @divTrunc(util_time.nowWallNs(), 1_000_000);
    const body = std.fmt.bufPrint(&buf, "{d} {d}", .{ pid(), now_ms }) catch return true;
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
    const body = buf[0..@intCast(n)];
    const sp = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    const ms_str = std.mem.trim(u8, body[sp + 1 ..], " \n\r\t");
    return std.fmt.parseInt(i128, ms_str, 10) catch null;
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
const test_fs = @import("../util/fs.zig");

fn testDir(buf: []u8) ![]const u8 {
    const d = try std.fmt.bufPrint(buf, "/tmp/cc-zig-filelock-test-{d}", .{util_time.nowNs()});
    try test_fs.mkdirParents(d);
    return d;
}

test "acquire + release 往返" {
    var dbuf: [128]u8 = undefined;
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
    var dbuf: [128]u8 = undefined;
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
    var dbuf: [128]u8 = undefined;
    const dir = try testDir(&dbuf);
    defer test_fs.testing.rmrfBestEffort(dir);
    var pbuf: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&pbuf, "{s}/inbox.json", .{dir});

    // 手工伪造一个 20s 前的锁。
    var lbuf: [256:0]u8 = undefined;
    const lp = try std.fmt.bufPrintZ(&lbuf, "{s}.lock", .{target});
    const fd = pfs.open(lp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
    try testing.expect(fd >= 0);
    const now_ms: i128 = @divTrunc(util_time.nowWallNs(), 1_000_000);
    var body_buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "99999 {d}", .{now_ms - 20_000});
    _ = pfs.write(fd, body);
    pfs.close(fd);

    var lock = try acquire(target, .{ .retries = 1, .min_backoff_ms = 1, .max_backoff_ms = 2 });
    lock.release();
}

test "空内容陈旧锁也能被抢(mtime 兜底,Linus MED-2 回归)" {
    var dbuf: [128]u8 = undefined;
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
