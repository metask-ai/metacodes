//! W2 可移植【文件 fd】IO（跨平台移植 roadmap，tinykg node 8866）。
//!
//! 现状病灶：全仓 fd 基文件 IO 直接用 `std.c.open/read/write/close/lseek`。在 windows-gnu 上
//! `std.c.open` 的 oflag 类型 `std.c.O` 是 `void`（POSIX flags 不存在）→ 硬编译错误；
//! `std.c.close/read/write/lseek` 也未为 windows 绑定 → 全 FAIL。
//!
//! 本模块把【文件 fd】IO 收编成中立 API：
//! - **POSIX**：直通 `std.c.*`（`O = std.c.O`，零行为变化）。
//! - **Windows**：MSVCRT `_open/_read/_write/_close/_lseek`（fd 仍是 c_int，模型一致），
//!   O 结构翻译成 `_O_*` int，并**强制 `_O_BINARY`**（否则 MSVCRT 文本模式做 CRLF 翻译，
//!   破坏字节精确读写——这是 Windows FS 移植最隐蔽的坑）。
//!
//! ⚠️ **严格边界：仅限文件 fd**。POSIX 一切皆 fd，但 Windows 上 close/read/write 按 fd 种类
//! 分道：文件 fd→`_close`/`_read`/`_write`；**socket fd→`closesocket`/`recv`/`send`**（web
//! server）；**pipe/子进程 HANDLE→`CloseHandle`/`ReadFile`**（W3 进程模块）。故 socket 与
//! pipe 的 close/read/write **不得**走本模块——它们各归 socket 可移植化与 W3。迁移时必须
//! 逐站点分类 fd 来源，不能盲目前缀替换（Linus/PM 双 review 的红线）。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// 文件 fd 类型。两平台皆 c_int:POSIX 天然 fd;Windows 走 MSVCRT `_open`(返回 CRT 层
/// int fd,非内核 HANDLE),故模型一致。**勿用 `std.c.fd_t`**——它在 Windows 是 HANDLE
/// (*anyopaque),会与 pfs.open 返回的 c_int 冲突(-1 哨兵无法赋值)。
pub const Fd = c_int;
pub const invalid_fd: Fd = -1;

// ============================================================================
// O flags：POSIX 直通 std.c.O；Windows 镜像本代码实际用到的字段子集
// ============================================================================

pub const O = if (is_windows) WindowsO else std.c.O;

/// Windows 端 O：字段名与 std.c.O 对齐，使调用点 `.{ .ACCMODE = .WRONLY, .CREAT = true }`
/// 在两平台同构（迁移=纯前缀 swap）。仅含本仓用到的 flag。
const WindowsO = struct {
    ACCMODE: AccessMode = .RDONLY,
    CREAT: bool = false,
    TRUNC: bool = false,
    APPEND: bool = false,
    EXCL: bool = false,
    NOFOLLOW: bool = false,

    pub const AccessMode = enum(u2) { RDONLY = 0, WRONLY = 1, RDWR = 2 };
};

// MSVCRT _O_* 常量（<fcntl.h>）
const _O_RDONLY: c_int = 0x0000;
const _O_WRONLY: c_int = 0x0001;
const _O_RDWR: c_int = 0x0002;
const _O_APPEND: c_int = 0x0008;
const _O_CREAT: c_int = 0x0100;
const _O_TRUNC: c_int = 0x0200;
const _O_EXCL: c_int = 0x0400;
const _O_BINARY: c_int = 0x8000; // 必须：关掉 CRLF 文本翻译，保字节精确

extern "c" fn _open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn _read(fd: c_int, buf: [*]u8, count: c_uint) c_int;
extern "c" fn _write(fd: c_int, buf: [*]const u8, count: c_uint) c_int;
extern "c" fn _close(fd: c_int) c_int;
extern "c" fn _lseek(fd: c_int, offset: c_long, origin: c_int) c_long;
extern "c" fn _lseeki64(fd: c_int, offset: i64, origin: c_int) i64; // Win64:64 位 offset(_lseek 仅 32 位)
extern "c" fn _commit(fd: c_int) c_int; // MSVCRT:等价 fsync(刷到磁盘)
extern "c" fn _fullpath(absPath: ?[*]u8, relPath: [*:0]const u8, maxLength: usize) ?[*:0]u8; // MSVCRT:规范化路径

fn windowsOflag(flags: WindowsO) c_int {
    var o: c_int = _O_BINARY;
    o |= switch (flags.ACCMODE) {
        .RDONLY => _O_RDONLY,
        .WRONLY => _O_WRONLY,
        .RDWR => _O_RDWR,
    };
    if (flags.CREAT) o |= _O_CREAT;
    if (flags.TRUNC) o |= _O_TRUNC;
    if (flags.APPEND) o |= _O_APPEND;
    if (flags.EXCL) o |= _O_EXCL;
    return o;
}

// ============================================================================
// 中立文件 fd API
// ============================================================================

/// 打开文件，返回 fd（失败返 -1，errno 语义同各平台 CRT）。mode 为 CREAT 时的权限位。
pub fn open(path: [*:0]const u8, flags: O, mode: c_uint) c_int {
    // 显式 if/else(非 if-return 落穿):后者在 refAllDecls(zig test)下 POSIX 分支仍被分析,
    // 而 std.c.open 的 `oflag: O` 在 windows 是 void(std.c.O=void)→ winapi void-param 报错。
    // else 块保证该分支 comptime 死、不被分析(nowMs 同款,已验证)。
    if (is_windows) {
        // MSVCRT 没有 O_NOFOLLOW。先拒绝 reparse point；真正需要抵抗路径竞态的
        // 安全边界应传已打开 fd（evaluation harness 正是如此），不要依赖此检查。
        if (flags.NOFOLLOW and isSymlink(path)) return -1;
        // MSVCRT _open：第三变参是 pmode（_S_IREAD/_S_IWRITE），仅 CREAT 时生效。
        return _open(path, windowsOflag(flags), @as(c_int, @intCast(mode & 0o777)));
    } else {
        return std.c.open(path, flags, mode);
    }
}

const S_IFREG: u32 = 0o100000;

pub const FileInfo = struct {
    size: u64,
    is_regular: bool,
};

/// 对已打开 fd 做类型与大小检查。安全敏感读取必须先 open(O_NOFOLLOW)，再 fstat fd，
/// 不能只 lstat path 后 open（两步之间可被换成 symlink/FIFO）。
pub fn fileInfo(fd: Fd) error{StatFailed}!FileInfo {
    if (is_windows) {
        var st: Stat64 = undefined;
        if (_fstat64(fd, &st) != 0 or st.st_size < 0) return error.StatFailed;
        return .{
            .size = @intCast(st.st_size),
            .is_regular = (@as(u32, st.st_mode) & S_IFMT) == S_IFREG,
        };
    }
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const empty_path: [*:0]const u8 = "";
        const AT_EMPTY_PATH: u32 = 0x1000;
        const rc = std.os.linux.statx(fd, empty_path, AT_EMPTY_PATH, std.os.linux.STATX.BASIC_STATS, &stx);
        if (@as(isize, @bitCast(rc)) < 0) return error.StatFailed;
        return .{
            .size = stx.size,
            .is_regular = (@as(u32, stx.mode) & S_IFMT) == S_IFREG,
        };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0 or st.size < 0) return error.StatFailed;
    return .{
        .size = @intCast(st.size),
        .is_regular = (@as(u32, @intCast(st.mode)) & S_IFMT) == S_IFREG,
    };
}

/// 禁止 fd 穿过后续 exec 边界。POSIX 用 FD_CLOEXEC；Windows 清底层 HANDLE 的
/// HANDLE_FLAG_INHERIT，避免 bInheritHandles=TRUE 的工具子进程拿到可信 artifact fd。
pub fn makeCloseOnExec(fd: Fd) error{CloseOnExecFailed}!void {
    if (is_windows) {
        const raw = _get_osfhandle(fd);
        if (raw == -1) return error.CloseOnExecFailed;
        if (SetHandleInformation(@ptrFromInt(@as(usize, @bitCast(raw))), HANDLE_FLAG_INHERIT, 0) == 0)
            return error.CloseOnExecFailed;
        return;
    }
    const current = std.c.fcntl(fd, std.c.F.GETFD);
    if (current < 0 or std.c.fcntl(fd, std.c.F.SETFD, current | std.c.FD_CLOEXEC) < 0)
        return error.CloseOnExecFailed;
}

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
extern "c" fn _get_osfhandle(fd: c_int) isize;
const HANDLE_FLAG_INHERIT: u32 = 0x1;
extern "kernel32" fn SetHandleInformation(handle: *anyopaque, mask: u32, flags: u32) callconv(.winapi) c_int;

/// `open` 的 error-union 包装:收编全仓 `std.posix.openat(AT.FDCWD, …) catch/try` 样板
/// (std.posix.openat 在 Windows 无 AT.FDCWD、返回 HANDLE 而非 c_int fd)。语义等价:失败
/// 返 error.OpenFailed(不区分 errno——原调用方几乎都 blanket `catch return error.X`,
/// 无一按 errno 分支)。返回 pfs c_int fd,与 pfs.read/write/close 直接配套。
pub fn openZ(path: []const u8, flags: O, mode: c_uint) error{OpenFailed}!Fd {
    // 接受**非**哨兵 slice(对齐 std.posix.openat 契约:它也收 []const u8 内部补 NUL),
    // 故所有旧 openat 站点无论传 slice 还是 [:0] 都直接通过。
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return error.OpenFailed;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = open(@ptrCast(&pbuf), flags, mode);
    if (fd < 0) return error.OpenFailed;
    return fd;
}

/// `read` 的 error-union 包装:收编 `std.posix.read(fd, buf) catch …` 样板。返回读到字节
/// 数(0=EOF);<0 → error.ReadFailed。
pub fn readZ(fd: Fd, buf: []u8) error{ReadFailed}!usize {
    const n = read(fd, buf);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

/// 读取，返回读到字节数（0=EOF，<0=错误）。
pub fn read(fd: c_int, buf: []u8) isize {
    if (is_windows) {
        const n = _read(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint))));
        return n;
    }
    return std.c.read(fd, buf.ptr, buf.len);
}

/// 写入，返回写出字节数（<0=错误）。
pub fn write(fd: c_int, buf: []const u8) isize {
    if (is_windows) {
        const n = _write(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint))));
        return n;
    }
    return std.c.write(fd, buf.ptr, buf.len);
}

/// 刷盘。POSIX fsync / Windows _commit。
pub fn fsync(fd: c_int) void {
    fsyncChecked(fd) catch {};
}

/// 可观测的刷盘结果。安全控制面不能用上面的 best-effort 包装，否则磁盘错误会被
/// 误报成“授权/观测已经持久化”。
pub fn fsyncChecked(fd: c_int) error{SyncFailed}!void {
    if (is_windows) {
        if (_commit(fd) != 0) return error.SyncFailed;
    } else {
        if (std.c.fsync(fd) != 0) return error.SyncFailed;
    }
}

/// 规范化绝对路径。签名对齐 std.c.realpath(失败返 null)。POSIX realpath(解 symlink)/
/// Windows _fullpath(规范化 . 与 .. 及分隔符;Windows symlink 罕见,不解也可接受)。
pub fn realpath(file_name: [*:0]const u8, resolved_name: [*]u8) ?[*:0]u8 {
    if (is_windows) {
        return _fullpath(resolved_name, file_name, std.fs.max_path_bytes);
    }
    return std.c.realpath(file_name, resolved_name);
}

/// 原子重命名(**替换**已存在目标)。POSIX rename(本就替换)/ Windows MoveFileExW +
/// MOVEFILE_REPLACE_EXISTING(裸 rename 在 Windows 遇目标已存在会失败,非替换语义)。
/// 返回 0 成功、非 0 失败。
pub fn renameReplace(from: [*:0]const u8, to: [*:0]const u8) c_int {
    if (is_windows) {
        var fbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        var tbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const fl = std.unicode.utf8ToUtf16Le(&fbuf, std.mem.span(from)) catch return -1;
        const tl = std.unicode.utf8ToUtf16Le(&tbuf, std.mem.span(to)) catch return -1;
        if (fl >= fbuf.len or tl >= tbuf.len) return -1;
        fbuf[fl] = 0;
        tbuf[tl] = 0;
        const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
        const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
        return if (MoveFileExW(@ptrCast(&fbuf), @ptrCast(&tbuf), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) 0 else -1;
    }
    return std.c.rename(from, to);
}
extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, dwFlags: u32) callconv(.winapi) c_int;

/// 路径是否存在(文件**或目录**)。POSIX access(F_OK) / Windows GetFileAttributesW。
/// **勿用 open() 判存在**:Windows `_open` 打不开目录(返 -1),会把存在的目录误判成不存在。
pub fn exists(path: [*:0]const u8) bool {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const u8p = std.mem.span(path);
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, u8p) catch return false;
        if (wlen >= wbuf.len) return false;
        wbuf[wlen] = 0;
        return GetFileAttributesW(@ptrCast(&wbuf)) != 0xFFFF_FFFF; // INVALID_FILE_ATTRIBUTES
    }
    return std.c.access(path, std.c.F_OK) == 0;
}
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

/// 删除一个已解析的普通文件路径。控制面 lease 用它显式释放独占标记；失败必须由
/// 调用方处理，不能把“仍被占用”静默解释成成功。
pub fn unlinkPath(path: [*:0]const u8) error{UnlinkFailed}!void {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const u8p = std.mem.span(path);
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, u8p) catch return error.UnlinkFailed;
        if (wlen >= wbuf.len) return error.UnlinkFailed;
        wbuf[wlen] = 0;
        if (DeleteFileW(@ptrCast(&wbuf)) == 0) return error.UnlinkFailed;
        return;
    }
    if (std.c.unlink(path) != 0) return error.UnlinkFailed;
}
extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) c_int;

// ── 可移植 stat（文件类型探测）─────────────────────────────────────────────
// POSIX 文件类型位（S_IFMT 家族，macOS/Linux 值一致）。用字面量避开 `std.posix.S`
// （此 Zig 0.16 下 windows 时为 void，会硬编译错）。
const S_IFMT: u32 = 0o170000;
const S_IFSOCK: u32 = 0o140000;
const S_IFLNK: u32 = 0o120000;

/// 取 path 的 st_mode（含 S_IFMT 类型位），无法 stat 返 null。
/// follow=true 跟随 symlink（stat 语义），false 不跟随（lstat 语义）。
/// 跨平台:macOS/BSD `std.c.fstatat`（switch 自动处理 x86_64 的 $INODE64 桩）;Linux `statx`;
/// Windows 无 POSIX 文件类型（socket/symlink 语义不同）→ null。
/// **裁剪 std 背景**:此 Zig 0.16 的 `std.posix.Stat`/`std.c.Stat` 对 linux=void（改用 statx），
/// 故 `std.c.fstatat` 不能直用于 linux。分支同 read_state.zig statFd。
pub fn statMode(path_z: [*:0]const u8, follow: bool) ?u32 {
    if (is_windows) return null;
    if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const AT_FDCWD: i32 = -100;
        const flags: u32 = if (follow) 0 else 0x100; // AT_SYMLINK_NOFOLLOW (linux)
        const rc = std.os.linux.statx(AT_FDCWD, path_z, flags, std.os.linux.STATX.BASIC_STATS, &stx);
        if (@as(isize, @bitCast(rc)) < 0) return null;
        return @intCast(stx.mode);
    }
    var st: std.c.Stat = undefined;
    const flags: u32 = if (follow) 0 else @as(u32, std.c.AT.SYMLINK_NOFOLLOW);
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, flags) != 0) return null;
    return @intCast(st.mode);
}

/// path 是否 symlink（**不跟随**，lstat 语义；防 symlink 逃逸）。
/// Windows:GetFileAttributesW 的 REPARSE_POINT 位（不跟随，等价 lstat 语义）。
pub fn isSymlink(path_z: [*:0]const u8) bool {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, std.mem.span(path_z)) catch return false;
        if (wlen >= wbuf.len) return false;
        wbuf[wlen] = 0;
        const attr = GetFileAttributesW(@ptrCast(&wbuf));
        if (attr == 0xFFFF_FFFF) return false; // INVALID_FILE_ATTRIBUTES
        return (attr & 0x400) != 0; // FILE_ATTRIBUTE_REPARSE_POINT
    }
    const m = statMode(path_z, false) orelse return false;
    return (m & S_IFMT) == S_IFLNK;
}

/// path 是否 unix domain socket（跟随 symlink）。Windows→false。
pub fn isSocket(path_z: [*:0]const u8) bool {
    const m = statMode(path_z, true) orelse return false;
    return (m & S_IFMT) == S_IFSOCK;
}

/// 关闭【文件】fd。禁用于 socket/pipe（见文件头边界说明）。
pub fn close(fd: c_int) void {
    if (is_windows) {
        _ = _close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

pub const Whence = enum(c_int) { set = 0, cur = 1, end = 2 };

/// 定位，返回新偏移（<0=错误）。
pub fn lseek(fd: c_int, offset: i64, whence: Whence) i64 {
    if (is_windows) {
        // **_lseeki64 非 _lseek**:Win64 LLP64 下 `long` 是 32 位,_lseek 的 offset/返回值截到
        // ±2GB → 大后台 job 输出(>2GB)seek 到末尾时 @intCast(i64→i32) panic + total 静默截断。
        // _lseeki64 offset/返回是 __int64,无此限。
        return _lseeki64(fd, offset, @intFromEnum(whence));
    }
    return std.c.lseek(fd, @intCast(offset), @intFromEnum(whence));
}

// ============================================================================
// Tests（POSIX 可跑真实文件往返；Windows 走 CI 交叉编译验证编译）
// ============================================================================

test "open/write/lseek/read/close 文件往返" {
    // Windows CI（windows-latest）真跑：验证 MSVCRT _open+_O_BINARY / _read/_write/_lseek/_close。
    // 关键：含 '\n' 的 msg 若 _O_BINARY 缺失会被 CRLF 翻译撑长 → 长度断言红，正是运行时验证价值。
    const paths = @import("paths.zig");
    var pbuf: [512]u8 = undefined;
    const tmp = try std.fmt.bufPrintZ(&pbuf, "{s}/metacodes_pfs_test.txt", .{paths.tempDir()});
    defer _ = std.c.unlink(tmp.ptr);

    const fd = open(tmp.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    try std.testing.expect(fd >= 0);

    const msg = "hello\nplatform\nfs";
    try std.testing.expectEqual(@as(isize, msg.len), write(fd, msg));

    try std.testing.expectEqual(@as(i64, 0), lseek(fd, 0, .set));

    var buf: [64]u8 = undefined;
    const n = read(fd, buf[0..]);
    try std.testing.expectEqual(@as(isize, msg.len), n); // _O_BINARY：无 CRLF 膨胀，长度精确
    try std.testing.expectEqualStrings(msg, buf[0..@intCast(n)]);
    close(fd);
}

test "windowsOflag 映射（编译期常量，两平台可跑）" {
    // 直接测翻译函数（不依赖 is_windows，纯算术）。
    const o = windowsOflag(.{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    try std.testing.expect(o & _O_BINARY != 0); // 必带 binary
    try std.testing.expect(o & _O_WRONLY != 0);
    try std.testing.expect(o & _O_CREAT != 0);
    try std.testing.expect(o & _O_TRUNC != 0);
    try std.testing.expect(o & _O_APPEND == 0);
}
