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
const tt = @import("../tools/test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)
const pfs = @import("platform").fs;
const sync = @import("platform").sync;
const builtin = @import("builtin");
const util_time = @import("../util/time.zig");

pub const Entry = struct {
    mtime_ns: i128,
    byte_size: u64,
    read_at_ns: i128,
    /// 读取时的内容哈希(Wyhash)。staleness 双判用:mtime 变但 content_hash 不变 → 不算 stale
    /// (对齐 cc FileEdit:云同步/杀软改 mtime 但内容没变时放行)。0 = 未记录(向后兼容)。
    content_hash: u64 = 0,
    /// 本 session 是否已对该文件展示过 CodeMap/FindSymbol 提示(Read 弱提示去重频控用)。
    /// record 覆盖时保留(不因再次 Read 重置),确保同一文件一个 session 只提一次。
    hinted: bool = false,
};

pub const ReadState = struct {
    allocator: std.mem.Allocator,
    // path (owned, heap) → Entry
    map: std.StringHashMap(Entry),
    /// 并发工具执行(批1)下,Read 在其它线程也会 record。record/get 持锁。
    mutex: sync.Mutex = .{},

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
        _ = self.mutex.lock();
    }
    fn unlock(self: *ReadState) void {
        _ = self.mutex.unlock();
    }

    /// Read 成功后调用:记录 mtime/size/content_hash/read_at。path 会被 dupe 到内部存储。
    /// content_hash 传 0 表示不记(向后兼容旧调用)。重复调用同 path 覆盖旧条目。线程安全。
    pub fn record(self: *ReadState, path: []const u8, mtime_ns: i128, byte_size: u64) !void {
        return self.recordHashed(path, mtime_ns, byte_size, 0);
    }

    pub fn recordHashed(self: *ReadState, path: []const u8, mtime_ns: i128, byte_size: u64, content_hash: u64) !void {
        self.lock();
        defer self.unlock();
        const gop = try self.map.getOrPut(path);
        // 保留已有的 hinted(再次 Read 同文件不应重置"提示过"标记)。
        const prev_hinted = if (gop.found_existing) gop.value_ptr.hinted else false;
        if (!gop.found_existing) {
            // 分配一份 owned key；getOrPut 的 key_ptr 此时还指向传入的临时 slice
            const owned = try self.allocator.dupe(u8, path);
            gop.key_ptr.* = owned;
        }
        gop.value_ptr.* = .{
            .mtime_ns = mtime_ns,
            .byte_size = byte_size,
            .read_at_ns = util_time.nowNs(),
            .content_hash = content_hash,
            .hinted = prev_hinted,
        };
    }

    /// 标记该文件本 session 已展示过提示。文件必须已 record(Read 成功后才提示)。
    /// 未找到条目时静默忽略(理论不会发生:提示总在 record 之后)。线程安全。
    pub fn markHinted(self: *ReadState, path: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.map.getPtr(path)) |e| e.hinted = true;
    }

    /// 该文件本 session 是否已展示过提示。未读过 → false。线程安全。
    pub fn wasHinted(self: *ReadState, path: []const u8) bool {
        self.lock();
        defer self.unlock();
        if (self.map.get(path)) |e| return e.hinted;
        return false;
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
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = pfs.close(fd);
    var h = std.hash.Wyhash.init(0);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n <= 0) break;
        h.update(buf[0..@intCast(n)]);
    }
    return h.final();
}

pub const StatInfo = struct { mtime_ns: i128, size: u64 };

/// 从 fd stat 出 mtime_ns 和 size。
/// Linux：std.c.fstat 为 void，必须走 statx。
/// macOS/BSD：std.c.Stat 可用，直接 fstat。
// Windows：MSVCRT _fstat64 → struct _stat64（st_mtime 为 unix 秒，st_size i64）。std.c.fstat 在
// Windows 不可用，故自 extern。mtime 秒精度（无 nsec）——比 POSIX 粗，但配合 size 检查足够判 staleness。
const Stat64 = extern struct {
    st_dev: u32,
    st_ino: u16,
    st_mode: u16,
    st_nlink: i16,
    st_uid: i16,
    st_gid: i16,
    st_rdev: u32,
    st_size: i64,
    st_atime: i64,
    st_mtime: i64,
    st_ctime: i64,
};
extern "c" fn _fstat64(fd: c_int, buf: *Stat64) c_int;

// Windows 路径 stat(对目录也有效)。
const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
};
extern "kernel32" fn GetFileAttributesExW(lpFileName: [*:0]const u16, fInfoLevelId: i32, lpFileInformation: *WIN32_FILE_ATTRIBUTE_DATA) callconv(.winapi) c_int;

pub fn statFd(fd: pfs.Fd) !StatInfo {
    if (builtin.os.tag == .windows) {
        var st: Stat64 = undefined;
        if (_fstat64(fd, &st) != 0) return error.StatFailed;
        return .{ .mtime_ns = @as(i128, st.st_mtime) * std.time.ns_per_s, .size = @intCast(st.st_size) };
    }
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

    if (builtin.os.tag == .windows) {
        // **GetFileAttributesExW 而非 open+fstat**:Windows _open 打不开目录 → 对目录路径
        // (Grep/Glob 的搜索目录参数)会误判 StatFailed。GetFileAttributesEx 对文件/目录都работает。
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return error.StatFailed;
        if (wlen >= wbuf.len) return error.StatFailed;
        wbuf[wlen] = 0;
        var data: WIN32_FILE_ATTRIBUTE_DATA = undefined;
        if (GetFileAttributesExW(@ptrCast(&wbuf), 0, &data) == 0) return error.StatFailed;
        // FILETIME(100ns since 1601)→ unix ns
        const ticks: i128 = (@as(i128, data.ftLastWriteTime[1]) << 32) | @as(i128, data.ftLastWriteTime[0]);
        const mtime_ns = (ticks - 116_444_736_000_000_000) * 100;
        const size: u64 = (@as(u64, data.nFileSizeHigh) << 32) | @as(u64, data.nFileSizeLow);
        return .{ .mtime_ns = mtime_ns, .size = size };
    }
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
        const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.StatFailed;
        defer _ = pfs.close(fd);
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
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "readstate-stat-test.txt");
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    defer _ = std.c.unlink(path.ptr);
    _ = pfs.write(fd, "hello");
    _ = pfs.close(fd);

    const s = try statPath(path);
    try std.testing.expect(s.size == 5);
    try std.testing.expect(s.mtime_ns > 0);
}

test "hinted 标记:markHinted/wasHinted + record 覆盖时保留" {
    var rs = ReadState.init(std.testing.allocator);
    defer rs.deinit();
    try rs.record("/x/foo.zig", 100, 10);
    try std.testing.expect(!rs.wasHinted("/x/foo.zig"));
    rs.markHinted("/x/foo.zig");
    try std.testing.expect(rs.wasHinted("/x/foo.zig"));
    // 再次 record 同文件(模拟再读)→ hinted 不被重置
    try rs.record("/x/foo.zig", 200, 20);
    try std.testing.expect(rs.wasHinted("/x/foo.zig"));
    // 未读过的文件 → false
    try std.testing.expect(!rs.wasHinted("/x/never.zig"));
}
