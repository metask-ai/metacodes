//! W2 可移植【文件 fd】IO（跨平台移植 roadmap，tinykg node 8866）。
//!
//! 现状病灶：全仓 fd 基文件 IO 直接用 `std.c.open/read/write/close/lseek`。在 windows-gnu 上
//! `std.c.open` 的 oflag 类型 `std.c.O` 是 `void`（POSIX flags 不存在）→ 硬编译错误；
//! `std.c.close/read/write/lseek` 也未为 windows 绑定 → 全 FAIL。
//!
//! 本模块把【文件 fd】IO 收编成中立 API：
//! - **POSIX**：直通 `std.c.*`（`O = std.c.O`，零行为变化）。
//! - **Windows**：MSVCRT `_wopen/_read/_write/_close/_lseek`（fd 仍是 c_int，模型一致），
//!   O 结构翻译成 `_O_*` int，并**强制 `_O_BINARY`**（否则 MSVCRT 文本模式做 CRLF 翻译，
//!   破坏字节精确读写——这是 Windows FS 移植最隐蔽的坑）。**路径一律 UTF-8 → UTF-16 走宽字符
//!   入口**(`_wopen`/`_wmkdir`/`*W` API):窄字符 `_open`/`_mkdir` 按 ANSI 代码页解码路径字节,
//!   中文路径会落到另一个文件系统对象上(#121)。
//!
//! ⚠️ **严格边界：仅限文件 fd**。POSIX 一切皆 fd，但 Windows 上 close/read/write 按 fd 种类
//! 分道：文件 fd→`_close`/`_read`/`_write`；**socket fd→`closesocket`/`recv`/`send`**（web
//! server）；**pipe/子进程 HANDLE→`CloseHandle`/`ReadFile`**（W3 进程模块）。故 socket 与
//! pipe 的 close/read/write **不得**走本模块——它们各归 socket 可移植化与 W3。迁移时必须
//! 逐站点分类 fd 来源，不能盲目前缀替换（Linus/PM 双 review 的红线）。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Whether opening the final path component with `NOFOLLOW` is one atomic OS
/// operation. MSVCRT has no O_NOFOLLOW; its defensive attribute precheck is
/// useful for ordinary callers but cannot authorize a security-sensitive
/// read/compare/write transaction across a path-swap race.
pub const atomic_final_nofollow = !is_windows;

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

extern "c" fn _read(fd: c_int, buf: [*]u8, count: c_uint) c_int;
extern "c" fn _write(fd: c_int, buf: [*]const u8, count: c_uint) c_int;
extern "c" fn _close(fd: c_int) c_int;
extern "c" fn _lseek(fd: c_int, offset: c_long, origin: c_int) c_long;
extern "c" fn _lseeki64(fd: c_int, offset: i64, origin: c_int) i64; // Win64:64 位 offset(_lseek 仅 32 位)
extern "c" fn _commit(fd: c_int) c_int; // MSVCRT:等价 fsync(刷到磁盘)
extern "c" fn _chsize_s(fd: c_int, size: i64) c_int;
extern "c" fn _fullpath(absPath: ?[*]u8, relPath: [*:0]const u8, maxLength: usize) ?[*:0]u8; // MSVCRT:规范化路径(纯词法,不解 symlink/junction)
// 宽字符入口(#121):窄字符 `_open`/`_mkdir` 把路径字节按进程 ANSI 代码页解码,UTF-8 的 `测试.txt`
// 在 CP936 下变成 `娴嬭瘯.txt`——而 exists/statPath/unlinkPath 早已走 UTF-16,同一个路径字符串会被
// 两条路指到两个不同的文件系统对象。本模块所有接路径的 CRT 调用一律先转 UTF-16。
extern "c" fn _wopen(path: [*:0]const u16, oflag: c_int, ...) c_int;
extern "c" fn _wmkdir(path: [*:0]const u16) c_int;

const WideError = error{ InvalidUtf8, NameTooLong };

/// UTF-8 → NUL 结尾 UTF-16,供 Win32/UCRT 宽字符入口用。非法 UTF-8 或放不下 → 错误(**绝不截断**:
/// 截断的路径会指向别的文件)。UTF-16 code unit 数 ≤ UTF-8 字节数,故 `len < wbuf.len` 即放得下——
/// `utf8ToUtf16Le` 自身不对输出做边界检查,这条前置判断是唯一的护栏。
fn toWide(path: []const u8, wbuf: *[std.os.windows.PATH_MAX_WIDE + 1]u16) WideError![:0]const u16 {
    if (path.len >= wbuf.len) return error.NameTooLong;
    const wlen = std.unicode.utf8ToUtf16Le(wbuf, path) catch return error.InvalidUtf8;
    wbuf[wlen] = 0;
    return wbuf[0..wlen :0];
}

/// 转码失败时给调用方一个说得通的 errno(本模块没调 CRT,不能让调用方读到上一次的残留值)。
fn wideErrno(err: WideError) void {
    setErrno(switch (err) {
        error.InvalidUtf8 => .INVAL,
        error.NameTooLong => .NAMETOOLONG,
    });
}

fn windowsAttributes(wide: [:0]const u16) ?u32 {
    const attr = GetFileAttributesW(wide.ptr);
    return if (attr == 0xFFFF_FFFF) null else attr; // INVALID_FILE_ATTRIBUTES
}

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
        // 路径先转 UTF-16 走 `_wopen`(#121,见文件头 extern 处的说明);errno 语义与 CRT 同款,
        // 失败一律 -1。
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wide = toWide(std.mem.span(path), &wbuf) catch |err| {
            wideErrno(err);
            return -1;
        };
        // MSVCRT 没有 O_NOFOLLOW。先拒绝 reparse point,并像 POSIX 一样给出 ELOOP——调用方按
        // errno 分类失败原因时不能拿到上一次调用的残留值。真正需要抵抗路径竞态的安全边界应传
        // 已打开 fd(evaluation harness 正是如此),不要依赖此检查。
        if (flags.NOFOLLOW) {
            if (windowsAttributes(wide)) |attr| if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                setErrno(.LOOP);
                return -1;
            };
        }
        // UCRT _wopen:第三变参是 pmode(_S_IREAD/_S_IWRITE),仅 CREAT 时生效。
        return _wopen(wide.ptr, windowsOflag(flags), @as(c_int, @intCast(mode & 0o777)));
    } else {
        return std.c.open(path, flags, mode);
    }
}

/// mkdir(2) 形状的建目录。POSIX 直通 `std.c.mkdir`;Windows 转 UTF-16 走 `_wmkdir`(窄字符 `_mkdir`
/// 同样按 ANSI 代码页解码,含中文的父目录会建成乱码名或直接失败,#121),`mode` 在 Windows 无意义。
/// 返回 0 / -1,errno 与各平台 CRT 同款(已存在为 EEXIST)。全仓建目录一律走这里,不要直接调
/// `std.c.mkdir`(Windows 下它就是那个窄字符 `_mkdir` 的 shim)。
pub fn mkdir(path: [*:0]const u8, mode: c_uint) c_int {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wide = toWide(std.mem.span(path), &wbuf) catch |err| {
            wideErrno(err);
            return -1;
        };
        return _wmkdir(wide.ptr);
    } else {
        return std.c.mkdir(path, @intCast(mode));
    }
}

// ── errno(跨平台安全读法)────────────────────────────────────────────────────
// `@enumFromInt(std.c._errno().*)` 在 Debug/ReleaseSafe 下遇到 `std.c.E` 没命名的值(UCRT 的部分
// 错误码、极端情况下的负数)会 panic(#121)。统一用整数比较或按名查表(未命名 → null),不裸转。

/// 上一次失败调用留下的原始 errno(整数)。
pub fn lastErrno() c_int {
    return std.c._errno().*;
}

/// errno 是否等于 `code`。整数比较,任何取值都不会触发枚举安全检查。
pub fn lastErrnoIs(code: std.c.E) bool {
    return lastErrno() == @intFromEnum(code);
}

/// `raw` 对应的 `std.c.E` 名;没命名的值返回 null(而不是 panic)。非穷举枚举(Linux)同样只认命名值。
pub fn errnoTag(raw: c_int) ?std.c.E {
    inline for (@typeInfo(std.c.E).@"enum".fields) |field| {
        if (raw == field.value) return @enumFromInt(field.value);
    }
    return null;
}

/// 上一次失败调用的 errno 名,见 `errnoTag`。
pub fn lastErrnoTag() ?std.c.E {
    return errnoTag(lastErrno());
}

/// 日志用:errno 的名字;`std.c.E` 没命名的值返回 "unnamed"(数值另行打印)。
pub fn errnoName(raw: c_int) []const u8 {
    return if (errnoTag(raw)) |tag| @tagName(tag) else "unnamed";
}

/// 本模块在**没有**调用 CRT 就拒绝一个操作时(路径过长、非法 UTF-8、NOFOLLOW 撞上 reparse point)
/// 显式写 errno,调用方读到的永远是本次操作的原因,不是上一次调用的残留。
pub fn setErrno(code: std.c.E) void {
    std.c._errno().* = @intFromEnum(code);
}

const S_IFREG: u32 = 0o100000;

pub const FileInfo = struct {
    size: u64,
    is_regular: bool,
    link_count: u64,
    mode: u32,
    /// Stable identity for one open file while the descriptor remains live.
    /// Security-sensitive pathname re-observation must compare both fields;
    /// matching size/content alone cannot detect a same-byte final-path swap.
    device: u64,
    inode: u64,
    /// Owner. Zero on Windows, where the concept does not map; callers that
    /// need ownership there must use a Windows-specific check instead of
    /// trusting this field.
    uid: u32,
    /// True for a directory. `is_regular` answers the common case; a caller
    /// that hands a pathname to another process has to know the difference.
    is_dir: bool,
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
            .link_count = @intCast(@max(st.st_nlink, 0)),
            .mode = @intCast(st.st_mode),
            .device = @intCast(st.st_dev),
            .inode = @intCast(st.st_ino),
            .uid = 0,
            .is_dir = (@as(u32, st.st_mode) & S_IFMT) == S_IFDIR,
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
            .link_count = stx.nlink,
            .mode = stx.mode,
            .device = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor),
            .inode = stx.ino,
            .uid = stx.uid,
            .is_dir = (@as(u32, stx.mode) & S_IFMT) == S_IFDIR,
        };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0 or st.size < 0) return error.StatFailed;
    return .{
        .size = @intCast(st.size),
        .is_regular = (@as(u32, @intCast(st.mode)) & S_IFMT) == S_IFREG,
        .link_count = @intCast(st.nlink),
        .mode = @intCast(st.mode),
        .device = @intCast(st.dev),
        .inode = @intCast(st.ino),
        .uid = @intCast(st.uid),
        .is_dir = (@as(u32, @intCast(st.mode)) & S_IFMT) == S_IFDIR,
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
    if (path.len >= pbuf.len) {
        setErrno(.NAMETOOLONG); // 没调 CRT 也给出本次失败的原因:调用方按 errno 分类(#121)
        return error.OpenFailed;
    }
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

/// Resize one already-open regular file descriptor.  Security-sensitive
/// read/compare/write paths use this instead of reopening the pathname with
/// O_TRUNC, which would reintroduce a path-swap race after validation.
pub fn setSize(fd: Fd, size: u64) error{ResizeFailed}!void {
    if (size > std.math.maxInt(i64)) return error.ResizeFailed;
    if (is_windows) {
        if (_chsize_s(fd, @intCast(size)) != 0) return error.ResizeFailed;
    } else {
        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.ResizeFailed;
    }
}

/// 规范化绝对路径。签名对齐 std.c.realpath(失败返 null;`resolved_name` 至少
/// `std.fs.max_path_bytes` 字节)。POSIX realpath(解 symlink)。
///
/// Windows:先经**句柄**解析——`CreateFileW` + `GetFinalPathNameByHandleW` 跟随 NTFS symlink 与
/// junction,给出物理路径(#140:`_fullpath` 只做 `.`/`..`/分隔符的词法规范化,经 symlink/junction
/// 启动的 metacodes.exe 会把相邻的 rg/kernel/tinykg 找到链接旁边而不是真二进制旁边)。打不开
/// (不存在、无权限)时退回 `_fullpath` 的词法答案:只需要规范化的调用方行为与从前一致。
pub fn realpath(file_name: [*:0]const u8, resolved_name: [*]u8) ?[*:0]u8 {
    if (is_windows) {
        if (windowsFinalPath(std.mem.span(file_name), resolved_name)) |resolved| return resolved;
        return _fullpath(resolved_name, file_name, std.fs.max_path_bytes);
    } else {
        return std.c.realpath(file_name, resolved_name);
    }
}

/// 经句柄取物理路径(见 `realpath`)。任何一步失败 → null,由调用方决定退路。
fn windowsFinalPath(path: []const u8, resolved_name: [*]u8) ?[*:0]u8 {
    const win = std.os.windows;
    var wbuf: [win.PATH_MAX_WIDE + 1]u16 = undefined;
    const wide = toWide(path, &wbuf) catch return null;
    // 0 访问权限 + 全部共享位:只取路径,不与任何已打开的句柄冲突;BACKUP_SEMANTICS 才能打开目录。
    const handle = CreateFileW(wide.ptr, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if (handle == win.INVALID_HANDLE_VALUE) return null;
    defer win.CloseHandle(handle);
    var fbuf: [win.PATH_MAX_WIDE + 1]u16 = undefined;
    // FILE_NAME_NORMALIZED | VOLUME_NAME_DOS(两者都是 0):`\\?\C:\...` 或 `\\?\UNC\server\share\...`。
    const n = GetFinalPathNameByHandleW(handle, &fbuf, fbuf.len, 0);
    if (n == 0 or n >= fbuf.len) return null;
    const final = stripWin32ExtendedPrefix(fbuf[0..n]);
    const out = resolved_name[0..std.fs.max_path_bytes];
    // utf16LeToUtf8 不对输出做边界检查:先保证最坏 3 字节/code unit 放得下(同 dir.zig)。
    if (final.len * 3 + 1 > out.len) return null;
    const len = std.unicode.utf16LeToUtf8(out, final) catch return null;
    out[len] = 0;
    return out[0..len :0].ptr;
}

/// `\\?\C:\x` → `C:\x`;`\\?\UNC\srv\share\x` → `\\srv\share\x`(原地改写一个分隔符,零拷贝)。
fn stripWin32ExtendedPrefix(final: []u16) []u16 {
    const ext = [_]u16{ '\\', '\\', '?', '\\' };
    if (!std.mem.startsWith(u16, final, &ext)) return final;
    const unc = [_]u16{ 'U', 'N', 'C', '\\' };
    if (std.mem.startsWith(u16, final[ext.len..], &unc)) {
        // `\\?\UNC\` 的 `C`(下标 6)改成 `\`,从它起就是 `\\srv\share\...`。
        final[ext.len + 2] = '\\';
        return final[ext.len + 2 ..];
    }
    return final[ext.len..];
}

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn GetFinalPathNameByHandleW(hFile: std.os.windows.HANDLE, lpszFilePath: [*]u16, cchFilePath: u32, dwFlags: u32) callconv(.winapi) u32;
const FILE_SHARE_READ: u32 = 0x1;
const FILE_SHARE_WRITE: u32 = 0x2;
const FILE_SHARE_DELETE: u32 = 0x4;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

/// 原子重命名(**替换**已存在目标)。POSIX rename(本就替换)/ Windows MoveFileExW +
/// MOVEFILE_REPLACE_EXISTING(裸 rename 在 Windows 遇目标已存在会失败,非替换语义)。
/// 返回 0 成功、非 0 失败。
pub fn renameReplace(from: [*:0]const u8, to: [*:0]const u8) c_int {
    if (is_windows) {
        var fbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        var tbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const from_w = toWide(std.mem.span(from), &fbuf) catch return -1;
        const to_w = toWide(std.mem.span(to), &tbuf) catch return -1;
        const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
        const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
        return if (MoveFileExW(from_w.ptr, to_w.ptr, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) 0 else -1;
    }
    return std.c.rename(from, to);
}
extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, dwFlags: u32) callconv(.winapi) c_int;

/// Whether the last Windows file operation failed transiently because another
/// handle is replacing/holding the path.  The CRT normally reports these as
/// EACCES/EAGAIN, while the underlying Win32 call may report sharing/access
/// denied (or a momentary not-found while a replace is delete-pending).
/// Callers choose whether a not-found result is retryable; absent paths must
/// remain fast, while an existing path may use a preflight presence check.
pub fn isWindowsTransientFileError(include_not_found: bool) bool {
    if (is_windows) {
        const win_code = GetLastError();
        const crt_code = std.c._errno().*;
        if (include_not_found and (win_code == 2 or win_code == 3 or crt_code == @intFromEnum(std.c.E.NOENT))) return true;
        if (win_code == 5 or win_code == 32 or win_code == 33) return true;
        return crt_code == @intFromEnum(std.c.E.ACCES) or
            crt_code == @intFromEnum(std.c.E.AGAIN) or
            crt_code == @intFromEnum(std.c.E.BUSY);
    } else {
        return false;
    }
}

/// Atomically install `from` at an absent `to` without ever replacing an
/// existing pathname. Content-addressed stores need this stronger primitive:
/// a verify-then-`renameReplace` sequence has a cross-process race in which a
/// newly published object can be overwritten after the verification.
///
/// POSIX has no portable rename-no-replace operation, so use the same-filesystem
/// `link(2)` primitive. The caller must unlink `from` after `.linked`; until it
/// does, readers see link_count=2 and security-sensitive CAS readers fail
/// closed. Windows `MoveFileExW` without REPLACE_EXISTING moves the source and
/// fails atomically when the destination already exists.
pub const InstallNoReplaceResult = enum {
    moved,
    linked,
    already_exists,
};

pub fn installNoReplace(
    from: [*:0]const u8,
    to: [*:0]const u8,
) error{InstallFailed}!InstallNoReplaceResult {
    if (is_windows) {
        var fbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        var tbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const from_w = toWide(std.mem.span(from), &fbuf) catch return error.InstallFailed;
        const to_w = toWide(std.mem.span(to), &tbuf) catch return error.InstallFailed;
        const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
        if (MoveFileExW(from_w.ptr, to_w.ptr, MOVEFILE_WRITE_THROUGH) != 0)
            return .moved;
        const code = GetLastError();
        return switch (code) {
            80, // ERROR_FILE_EXISTS
            183, // ERROR_ALREADY_EXISTS
            => .already_exists,
            else => error.InstallFailed,
        };
    } else {
        if (posix_install.link(from, to) == 0) return .linked;
        const code = std.c._errno().*;
        if (code == @intFromEnum(std.c.E.EXIST)) return .already_exists;
        return error.InstallFailed;
    }
}

const posix_install = struct {
    extern "c" fn link(from: [*:0]const u8, to: [*:0]const u8) c_int;
};

test "installNoReplace preserves an existing destination and installs only when absent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const source = try std.fmt.allocPrintSentinel(allocator, "{s}/source", .{root}, 0);
    defer allocator.free(source);
    const destination = try std.fmt.allocPrintSentinel(allocator, "{s}/destination", .{root}, 0);
    defer allocator.free(destination);

    for ([_]struct { path: [:0]const u8, bytes: []const u8 }{
        .{ .path = source, .bytes = "source-bytes" },
        .{ .path = destination, .bytes = "destination-bytes" },
    }) |fixture| {
        const fd = open(fixture.path.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
        }, 0o600);
        if (fd < 0) return error.TestFileOpenFailed;
        defer close(fd);
        if (write(fd, fixture.bytes) != fixture.bytes.len) return error.TestFileWriteFailed;
    }

    try std.testing.expectEqual(
        InstallNoReplaceResult.already_exists,
        try installNoReplace(source.ptr, destination.ptr),
    );
    var observed: ["destination-bytes".len]u8 = undefined;
    const existing_fd = open(destination.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (existing_fd < 0) return error.TestFileOpenFailed;
    const observed_count = read(existing_fd, &observed);
    close(existing_fd);
    try std.testing.expectEqual(@as(isize, observed.len), observed_count);
    try std.testing.expectEqualStrings("destination-bytes", &observed);
    try unlinkPath(destination.ptr);

    switch (try installNoReplace(source.ptr, destination.ptr)) {
        .linked => try unlinkPath(source.ptr),
        .moved => {},
        .already_exists => return error.UnexpectedDestination,
    }
    try std.testing.expect(!exists(source.ptr));
    try std.testing.expect(exists(destination.ptr));
    var installed: ["source-bytes".len]u8 = undefined;
    const installed_fd = open(destination.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (installed_fd < 0) return error.TestFileOpenFailed;
    const installed_count = read(installed_fd, &installed);
    close(installed_fd);
    try std.testing.expectEqual(@as(isize, installed.len), installed_count);
    try std.testing.expectEqualStrings("source-bytes", &installed);
}

/// 路径是否存在(文件**或目录**)。POSIX access(F_OK) / Windows GetFileAttributesW。
/// **勿用 open() 判存在**:Windows `_open` 打不开目录(返 -1),会把存在的目录误判成不存在。
pub fn exists(path: [*:0]const u8) bool {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wide = toWide(std.mem.span(path), &wbuf) catch return false;
        return windowsAttributes(wide) != null;
    }
    return std.c.access(path, std.c.F_OK) == 0;
}
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// 路径存在**且不是目录**(跟随 symlink)。PATH 查找用:POSIX 上可搜索目录的
/// `access(X_OK)` 也返 0,裸判会把一个叫 `zls` 的目录当成 server 二进制交给 spawn。
/// 跟随 symlink 是必须的——PATH 里的可执行文件常是软链(homebrew/npm/rustup 全这么装)。
pub fn isExistingNonDir(path: [*:0]const u8) bool {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wide = toWide(std.mem.span(path), &wbuf) catch return false;
        const attr = windowsAttributes(wide) orelse return false;
        return (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
    }
    const m = statMode(path, true) orelse return false;
    return (m & S_IFMT) != S_IFDIR;
}
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

/// 删除一个已解析的普通文件路径。控制面 lease 用它显式释放独占标记；失败必须由
/// 调用方处理，不能把“仍被占用”静默解释成成功。
pub fn unlinkPath(path: [*:0]const u8) error{UnlinkFailed}!void {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wide = toWide(std.mem.span(path), &wbuf) catch return error.UnlinkFailed;
        if (DeleteFileW(wide.ptr) == 0) return error.UnlinkFailed;
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
const S_IFDIR: u32 = 0o040000;

/// Bounded lstat-style classification for pre-dispatch policy sensors. It
/// distinguishes a proven absence from lookup failure so a caller may allow
/// creation only for `.missing` while failing closed on ambiguous state.
pub const PathKind = enum {
    missing,
    regular,
    other,
    unavailable,
};

pub fn pathKindNoFollow(path_z: [*:0]const u8) PathKind {
    if (is_windows) {
        var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const wide = toWide(std.mem.span(path_z), &wbuf) catch return .unavailable;
        const attr = windowsAttributes(wide) orelse {
            const code = GetLastError();
            return if (code == 2 or code == 3) .missing else .unavailable;
        };
        // Reparse points and directories exist, but they are not regular file
        // targets and must never be confused with a safe new-file creation.
        if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0 or (attr & FILE_ATTRIBUTE_DIRECTORY) != 0) return .other;
        return .regular;
    } else if (builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        const AT_FDCWD: i32 = -100;
        const rc = std.os.linux.statx(
            AT_FDCWD,
            path_z,
            0x100, // AT_SYMLINK_NOFOLLOW
            std.os.linux.STATX.BASIC_STATS,
            &stx,
        );
        const signed: isize = @bitCast(rc);
        if (signed < 0) {
            const code: c_int = @intCast(-signed);
            return if (code == @intFromEnum(std.c.E.NOENT) or
                code == @intFromEnum(std.c.E.NOTDIR)) .missing else .unavailable;
        }
        return if ((@as(u32, stx.mode) & S_IFMT) == S_IFREG) .regular else .other;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, @as(u32, std.c.AT.SYMLINK_NOFOLLOW)) != 0) {
            const code = std.c._errno().*;
            return if (code == @intFromEnum(std.c.E.NOENT) or
                code == @intFromEnum(std.c.E.NOTDIR)) .missing else .unavailable;
        }
        return if ((@as(u32, @intCast(st.mode)) & S_IFMT) == S_IFREG) .regular else .other;
    }
}

test "pathKindNoFollow distinguishes missing regular directory and symlink" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const regular = try std.fmt.allocPrintSentinel(allocator, "{s}/regular", .{root}, 0);
    defer allocator.free(regular);
    const missing = try std.fmt.allocPrintSentinel(allocator, "{s}/missing", .{root}, 0);
    defer allocator.free(missing);
    const root_z = try allocator.dupeZ(u8, root);
    defer allocator.free(root_z);
    const fd = open(regular.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    try std.testing.expect(fd >= 0);
    close(fd);
    try std.testing.expectEqual(PathKind.regular, pathKindNoFollow(regular.ptr));
    try std.testing.expectEqual(PathKind.missing, pathKindNoFollow(missing.ptr));
    try std.testing.expectEqual(PathKind.other, pathKindNoFollow(root_z.ptr));
    if (is_windows) {
        // Reparse-point coverage belongs to the native Windows gate.
    } else {
        const link = try std.fmt.allocPrintSentinel(allocator, "{s}/link", .{root}, 0);
        defer allocator.free(link);
        if (std.c.symlink(regular.ptr, link.ptr) != 0) return error.SymlinkFailed;
        defer unlinkPath(link.ptr) catch {};
        try std.testing.expectEqual(PathKind.other, pathKindNoFollow(link.ptr));
    }
}

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
        const wide = toWide(std.mem.span(path_z), &wbuf) catch return false;
        const attr = windowsAttributes(wide) orelse return false;
        return (attr & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
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

    try setSize(fd, 5);
    try std.testing.expectEqual(@as(i64, 0), lseek(fd, 0, .set));
    const shortened = read(fd, buf[0..]);
    try std.testing.expectEqual(@as(isize, 5), shortened);
    try std.testing.expectEqualStrings("hello", buf[0..@intCast(shortened)]);
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

// ── #121 / #140 回归:UTF-8 路径与 symlink/junction 解析(Windows 原生 CI 真跑)──────────

/// 目录里除 `.`/`..` 外的条目数,并断言每个条目都叫 `expected_name`。走 platform/dir.zig
/// (Windows FindFirstFileW / POSIX readdir),与被测的 CRT 窄路径无关——是独立的证据通道。
fn countEntriesNamed(dir_z: [*:0]const u8, expected_name: []const u8) !usize {
    const pdir = @import("dir.zig");
    var it = pdir.open(dir_z) orelse return error.TestUnexpectedResult;
    defer pdir.close(&it);
    var entries: usize = 0;
    while (pdir.next(&it)) |ent| {
        if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        try std.testing.expectEqualStrings(expected_name, ent.name);
        entries += 1;
    }
    return entries;
}

test "UTF-8 paths reach the exact directory entry through mkdir/open (verified through std.Io and directory enumeration)" {
    // #121:Windows 窄字符 `_open`/`_mkdir` 用 ANSI 代码页解码 UTF-8 字节,`测试.txt` 会落成乱码名。
    // 用 std.Io(Windows 走 NT 宽字符 API,不经 CRT 窄路径)独立读回,再枚举目录断言"恰好一个条目且
    // 名字精确"——pfs 自己写自己读的往返证明不了任何事(两头都走错同一条路也能通过)。
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const root_z = try a.dupeZ(u8, root);
    defer a.free(root_z);
    const dir = try std.fmt.allocPrintSentinel(a, "{s}/测试目录", .{root}, 0);
    defer a.free(dir);
    const file = try std.fmt.allocPrintSentinel(a, "{s}/测试目录/测试.txt", .{root}, 0);
    defer a.free(file);

    try std.testing.expectEqual(@as(c_int, 0), mkdir(dir.ptr, 0o700));
    // 再建一次:同一个对象已存在 → EEXIST(宽字符 mkdir 看到的正是它自己建的那个目录)。
    try std.testing.expectEqual(@as(c_int, -1), mkdir(dir.ptr, 0o700));
    try std.testing.expect(lastErrnoIs(.EXIST));

    const fd = open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(isize, "exact\n".len), write(fd, "exact\n"));
    close(fd);

    // 独立通道 1:std.Io 按精确名读回内容。
    const bytes = try tmp.dir.readFileAlloc(io, "测试目录/测试.txt", a, .limited(64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("exact\n", bytes);
    // 独立通道 2:两层目录各只有一个精确名的条目,没有乱码兄弟。
    try std.testing.expectEqual(@as(usize, 1), try countEntriesNamed(root_z.ptr, "测试目录"));
    try std.testing.expectEqual(@as(usize, 1), try countEntriesNamed(dir.ptr, "测试.txt"));
    // exists(宽字符)与 open 看到的是同一个对象:EXCL 再建必 EEXIST。
    try std.testing.expect(exists(file.ptr));
    try std.testing.expectEqual(@as(c_int, -1), open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600));
    try std.testing.expect(lastErrnoIs(.EXIST));
    try unlinkPath(file.ptr);
    try std.testing.expect(!exists(file.ptr));
}

test "errno helpers: unnamed or negative values are reported as null, never converted unsafely" {
    setErrno(.NOENT);
    try std.testing.expect(lastErrnoIs(.NOENT));
    try std.testing.expectEqual(std.c.E.NOENT, lastErrnoTag().?);
    try std.testing.expectEqualStrings("NOENT", errnoName(lastErrno()));
    // 注入 CRT 可能给出但 `std.c.E` 没命名的值,以及负数:老写法 `@enumFromInt` 在 Debug/ReleaseSafe
    // 下会 panic(#121)。
    std.c._errno().* = -1;
    try std.testing.expect(lastErrnoTag() == null);
    try std.testing.expect(!lastErrnoIs(.NOENT));
    std.c._errno().* = 60_000;
    try std.testing.expect(lastErrnoTag() == null);
    try std.testing.expectEqualStrings("unnamed", errnoName(60_000));
    setErrno(.SUCCESS);
}

test "openZ rejects an over-long path before the CRT and still reports ENAMETOOLONG" {
    const long = [_]u8{'a'} ** (std.fs.max_path_bytes + 8);
    setErrno(.SUCCESS);
    try std.testing.expectError(error.OpenFailed, openZ(&long, .{ .ACCMODE = .RDONLY }, 0));
    try std.testing.expect(lastErrnoIs(.NAMETOOLONG));
}

test "open with NOFOLLOW refuses a symlink and reports ELOOP, not a stale errno" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "t" });
    try @import("test_links.zig").symlinkOrSkip(tmp.dir, io, "target.txt", "link.txt", .{});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const link = try std.fmt.allocPrintSentinel(a, "{s}/link.txt", .{root}, 0);
    defer a.free(link);
    setErrno(.SUCCESS); // 清掉残留:断言拿到的必须是本次 open 写的 ELOOP
    try std.testing.expectEqual(@as(c_int, -1), open(link.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0));
    try std.testing.expect(lastErrnoIs(.LOOP));
    // 不带 NOFOLLOW 照常跟随。
    const fd = open(link.ptr, .{ .ACCMODE = .RDONLY }, 0);
    try std.testing.expect(fd >= 0);
    close(fd);
}

test "realpath follows a symlink to the physical path" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "prefix/bin");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/target.txt", .data = "t" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    // 期望值来自 std(Windows 走 NT API + GetFinalPathNameByHandle),不是被测函数自己。
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = real_buf[0..try tmp.dir.realPathFile(io, "prefix/bin/target.txt", &real_buf)];
    try @import("test_links.zig").symlinkOrSkip(tmp.dir, io, real, "elsewhere/target.txt", .{});
    const link = try std.fmt.allocPrintSentinel(a, "{s}/elsewhere/target.txt", .{root}, 0);
    defer a.free(link);
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = realpath(link.ptr, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(real, std.mem.span(resolved));
}

test "Windows: realpath follows an NTFS junction (no privilege needed) to the physical path" {
    if (!is_windows) return error.SkipZigTest; // junction 是 Windows 独有的目录重解析点
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "prefix/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/target.txt", .data = "t" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = real_buf[0..try tmp.dir.realPathFile(io, "prefix/bin/target.txt", &real_buf)];
    const junction = try std.fmt.allocPrint(a, "{s}\\elsewhere_j", .{root});
    defer a.free(junction);
    const target = try std.fmt.allocPrint(a, "{s}\\prefix", .{root});
    defer a.free(target);
    try @import("test_links.zig").junction(a, junction, target);
    const through = try std.fmt.allocPrintSentinel(a, "{s}\\elsewhere_j\\bin\\target.txt", .{root}, 0);
    defer a.free(through);
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = realpath(through.ptr, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(real, std.mem.span(resolved));
    // 词法回退仍在:不存在的路径照旧被 `_fullpath` 规范化,而不是变成 null。
    const ghost = try std.fmt.allocPrintSentinel(a, "{s}\\elsewhere_j\\bin\\..\\bin\\missing.txt", .{root}, 0);
    defer a.free(ghost);
    const lexical = realpath(ghost.ptr, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(lexical), "..") == null);
}
