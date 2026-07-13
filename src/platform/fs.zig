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

pub const invalid_fd: c_int = -1;

// ============================================================================
// O flags：POSIX 直通 std.c.O；Windows 镜像本代码实际用到的字段子集
// ============================================================================

pub const O = if (is_windows) WindowsO else std.c.O;

/// Windows 端 O：字段名与 std.c.O 对齐，使调用点 `.{ .ACCMODE = .WRONLY, .CREAT = true }`
/// 在两平台同构（迁移=纯前缀 swap）。仅含本仓用到的 flag（ACCMODE/CREAT/TRUNC/APPEND/EXCL）。
const WindowsO = struct {
    ACCMODE: AccessMode = .RDONLY,
    CREAT: bool = false,
    TRUNC: bool = false,
    APPEND: bool = false,
    EXCL: bool = false,

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
    if (is_windows) {
        // MSVCRT _open：第三变参是 pmode（_S_IREAD/_S_IWRITE），仅 CREAT 时生效。
        return _open(path, windowsOflag(flags), @as(c_int, @intCast(mode & 0o777)));
    }
    return std.c.open(path, flags, mode);
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
        return _lseek(fd, @intCast(offset), @intFromEnum(whence));
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
