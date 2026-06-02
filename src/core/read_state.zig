//! 全局 readFileState 表：记录"模型已读过哪些文件"，为 Write/Edit 的 must-read-first
//! 校验提供依据。对齐 TS 原版 readFileState 语义。
//!
//! 设计要点：
//! - **单线程**：当前 Zig agent 是单线程跑 REPL + tool，hashmap 不加锁；未来如加并发需重审。
//! - **key = realpath**：避免同一文件 `./foo` / `foo` / 绝对路径 的条目重复。
//!   一期简化：不做 realpath，直接 dupe 原始传入的 path。Write/Edit 也用原始 path 查询，
//!   所以相对/绝对混用会漏命中——约定工具层总传绝对路径（main.zig 已有 cwd 解析）。
//! - **数据字段**：{mtime_ns, byte_size, read_at_ns}。
//!   staleness 校验 = 当前磁盘 mtime_ns != 记录中 mtime_ns。
//! - **生命周期**：挂在 App 上；session 退出时整体 deinit。
//!
//! API：
//!   var rs = ReadState.init(allocator);
//!   defer rs.deinit();
//!   try rs.record(path, file_fd_or_stat);  // Read 成功后调用
//!   const meta = rs.get(path);             // Write/Edit 查询

const std = @import("std");
const builtin = @import("builtin");
const util_time = @import("../util/time.zig");

pub const Entry = struct {
    mtime_ns: i128,
    byte_size: u64,
    read_at_ns: i128,
    /// 读取时的内容哈希(Wyhash)。staleness 双判用:mtime 变但 content_hash 不变 → 不算 stale
    /// (对齐 cc FileEdit:云同步/杀软改 mtime 但内容没变时放行)。0 = 未记录(向后兼容)。
    content_hash: u64 = 0,
};

pub const ReadState = struct {
    allocator: std.mem.Allocator,
    // path (owned, heap) → Entry
    map: std.StringHashMap(Entry),
    /// 并发工具执行(批1)下,Read 在其它线程也会 record。record/get 持锁。
    mutex: std.c.pthread_mutex_t = .{},

    pub fn init(allocator: std.mem.Allocator) ReadState {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ReadState) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
    }

    fn lock(self: *ReadState) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *ReadState) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// Read 成功后调用:记录 mtime/size/content_hash/read_at。path 会被 dupe 到内部存储。
    /// content_hash 传 0 表示不记(向后兼容旧调用)。重复调用同 path 覆盖旧条目。线程安全。
    pub fn record(self: *ReadState, path: []const u8, mtime_ns: i128, byte_size: u64) !void {
        return self.recordHashed(path, mtime_ns, byte_size, 0);
    }

    pub fn recordHashed(self: *ReadState, path: []const u8, mtime_ns: i128, byte_size: u64, content_hash: u64) !void {
        self.lock();
        defer self.unlock();
        const entry = Entry{
            .mtime_ns = mtime_ns,
            .byte_size = byte_size,
            .read_at_ns = util_time.nowNs(),
            .content_hash = content_hash,
        };
        const gop = try self.map.getOrPut(path);
        if (!gop.found_existing) {
            // 分配一份 owned key；getOrPut 的 key_ptr 此时还指向传入的临时 slice
            const owned = try self.allocator.dupe(u8, path);
            gop.key_ptr.* = owned;
        }
        gop.value_ptr.* = entry;
    }

    /// 查询记录;返回 null 表示未读过。线程安全。
    pub fn get(self: *ReadState, path: []const u8) ?Entry {
        self.lock();
        defer self.unlock();
        return self.map.get(path);
    }

    /// 清空（测试或 session 重置用）。
    pub fn clearAll(self: *ReadState) void {
        self.lock();
        defer self.unlock();
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.clearRetainingCapacity();
    }
};

/// 计算文件内容的 Wyhash(staleness 双判用)。读失败返回 0。
pub fn hashFileContent(path: []const u8) u64 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return 0;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(@ptrCast(&pbuf), std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    var h = std.hash.Wyhash.init(0);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        h.update(buf[0..@intCast(n)]);
    }
    return h.final();
}

pub const StatInfo = struct { mtime_ns: i128, size: u64 };

/// 从 fd stat 出 mtime_ns 和 size。
/// Linux：std.c.fstat 为 void，必须走 statx。
/// macOS/BSD：std.c.Stat 可用，直接 fstat。
pub fn statFd(fd: std.c.fd_t) !StatInfo {
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const empty_path: [*:0]const u8 = "";
        // AT_EMPTY_PATH（0x1000）让 statx 对 fd 本身 stat
        const AT_EMPTY_PATH: u32 = 0x1000;
        const rc = std.os.linux.statx(fd, empty_path, AT_EMPTY_PATH, std.os.linux.STATX.BASIC_STATS, &stx);
        if (@as(isize, @bitCast(rc)) < 0) return error.StatFailed;
        const sec: i128 = @intCast(stx.mtime.sec);
        const nsec: i128 = @intCast(stx.mtime.nsec);
        return .{ .mtime_ns = sec * std.time.ns_per_s + nsec, .size = stx.size };
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) return error.StatFailed;
        const mt = st.mtime();
        const sec: i128 = @intCast(mt.sec);
        const nsec: i128 = @intCast(mt.nsec);
        return .{
            .mtime_ns = sec * std.time.ns_per_s + nsec,
            .size = @intCast(st.size),
        };
    }
}

/// 从 path 打开并 stat；caller 不需要 fd 时用这个。
pub fn statPath(path: []const u8) !StatInfo {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);

    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const AT_FDCWD: std.c.fd_t = -100;
        const rc = std.os.linux.statx(AT_FDCWD, path_z, 0, std.os.linux.STATX.BASIC_STATS, &stx);
        if (@as(isize, @bitCast(rc)) < 0) return error.StatFailed;
        const sec: i128 = @intCast(stx.mtime.sec);
        const nsec: i128 = @intCast(stx.mtime.nsec);
        return .{ .mtime_ns = sec * std.time.ns_per_s + nsec, .size = stx.size };
    } else {
        // macOS arm64: std.c.stat 绑定缺失（private.stat 未声明）。改为 open + fstat。
        const fd = std.c.open(path_z, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.StatFailed;
        defer _ = std.c.close(fd);
        return statFd(fd);
    }
}

// nowNs 已下沉到 util/time.zig

// ============================================================================
// 测试
// ============================================================================

test "record and get" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();

    try std.testing.expect(rs.get("/tmp/foo") == null);
    try rs.record("/tmp/foo", 12345, 42);
    const e = rs.get("/tmp/foo").?;
    try std.testing.expect(e.mtime_ns == 12345);
    try std.testing.expect(e.byte_size == 42);
    try std.testing.expect(e.read_at_ns > 0);
}

test "record overwrites" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();

    try rs.record("/tmp/bar", 100, 10);
    try rs.record("/tmp/bar", 200, 20);
    const e = rs.get("/tmp/bar").?;
    try std.testing.expect(e.mtime_ns == 200);
    try std.testing.expect(e.byte_size == 20);
}

test "clearAll" {
    const a = std.testing.allocator;
    var rs = ReadState.init(a);
    defer rs.deinit();

    try rs.record("/tmp/a", 1, 1);
    try rs.record("/tmp/b", 2, 2);
    rs.clearAll();
    try std.testing.expect(rs.get("/tmp/a") == null);
    try std.testing.expect(rs.get("/tmp/b") == null);
}

test "statPath real file" {
    const path = "/tmp/cc-zig-readstate-stat-test.txt";
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    defer _ = std.c.unlink(path);
    _ = std.c.write(fd, "hello", 5);
    _ = std.c.close(fd);

    const s = try statPath(path);
    try std.testing.expect(s.size == 5);
    try std.testing.expect(s.mtime_ns > 0);
}
