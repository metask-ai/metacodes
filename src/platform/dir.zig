//! 可移植目录遍历。session 列表 / 缓存 GC / tab 补全 / agent&skill 发现 / kg autosync 共用。
//!
//! 为什么单独一层:POSIX 有 `opendir/readdir/closedir`(dirent 名是 UTF-8 字节);Windows 无
//! opendir,须 `FindFirstFileW/FindNextFileW/FindClose`——且要给路径补 `\*` 通配、名字是
//! UTF-16 须转 UTF-8。差异被这层吸收,上层只见 `Iter` + UTF-8 `name`。
//!
//! **契约**:`next()` 返回的 `name` 只在下次 `next()`/`close()` 前有效(POSIX 指向 dirent
//! 内部缓冲,Windows 指向 Iter 自带缓冲);需留存必须拷贝。消费者本就都拷(allocPrint/dupeZ)。
//! 不暴露 is_dir——现有消费者都用 try-opendir 或独立 stat 判目录,无一依赖 d_type。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;

pub const Entry = struct {
    /// UTF-8 文件名(不含路径)。仅在下次 next()/close() 前有效。
    name: []const u8,
    /// 是否目录。POSIX 取 dirent.d_type(某些 fs 报 DT_UNKNOWN 时保守为 false,同旧行为);
    /// Windows 取 FILE_ATTRIBUTE_DIRECTORY(可靠)。仅 tab 补全等需区分处用。
    is_dir: bool,
};

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

// Windows FindFirstFileW 需要的最小 extern(zig 0.16 std 未导出这些)。
const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

const winsys = struct {
    extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn FindNextFileW(hFindFile: win.HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) c_int;
    extern "kernel32" fn FindClose(hFindFile: win.HANDLE) callconv(.winapi) c_int;
};
const INVALID_HANDLE_VALUE = win.INVALID_HANDLE_VALUE;

pub const Iter = if (is_windows) WindowsIter else PosixIter;

const PosixIter = struct {
    dirp: *anyopaque, // DIR*

    fn next(self: *PosixIter) ?Entry {
        const ent_ptr = std.c.readdir(@ptrCast(self.dirp)) orelse return null;
        const ent = ent_ptr;
        const name = std.mem.sliceTo(&ent.name, 0);
        return .{ .name = name, .is_dir = ent.type == std.c.DT.DIR };
    }

    fn close(self: *PosixIter) void {
        _ = std.c.closedir(@ptrCast(self.dirp));
    }
};

const WindowsIter = struct {
    handle: win.HANDLE,
    find_data: WIN32_FIND_DATAW,
    pending_first: bool, // FindFirstFile 已拿到首项,首次 next 直接用它
    // cFileName 最多 259 UTF-16 code unit;U+0800–U+FFFF(全 CJK/多数非拉丁)每个编 3 UTF-8
    // 字节 → 最坏 259×3=777。**必须 ≥777**:utf16LeToUtf8 不对输出做边界检查(0.16 源码实证),
    // 缓冲不够会写越界 panic/堆损坏。260×3=780 覆盖最坏 + 有余量。
    name_buf: [260 * 3]u8,

    fn next(self: *WindowsIter) ?Entry {
        // 循环而非递归:UTF-16 解码失败(极罕见的坏文件名)跳过该项继续,避免病态目录下
        // 无界递归爆栈。
        while (true) {
            if (self.pending_first) {
                self.pending_first = false;
            } else {
                if (winsys.FindNextFileW(self.handle, &self.find_data) == 0) return null;
            }
            const w = std.mem.sliceTo(&self.find_data.cFileName, 0);
            const n = std.unicode.utf16LeToUtf8(&self.name_buf, w) catch continue;
            const is_dir = (self.find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            return .{ .name = self.name_buf[0..n], .is_dir = is_dir };
        }
    }

    fn close(self: *WindowsIter) void {
        _ = winsys.FindClose(self.handle);
    }
};

/// 打开目录遍历。不存在/无权限返 null(消费者惯例:目录不存在即 no-op)。
pub fn open(path_z: [*:0]const u8) ?Iter {
    if (is_windows) {
        // 路径补 `\*` 通配。UTF-8 → UTF-16。
        var wbuf: [win.PATH_MAX_WIDE + 4]u16 = undefined;
        const path_u8 = std.mem.span(path_z);
        var wlen = std.unicode.utf8ToUtf16Le(&wbuf, path_u8) catch return null;
        if (wlen + 3 >= wbuf.len) return null;
        // 去尾部分隔符(drive root "C:\" / 带斜杠目录)→ 否则 "C:\\*" 双分隔符,FindFirstFile
        // 未必规范化。去后统一补 "\*"。
        while (wlen > 0 and (wbuf[wlen - 1] == '\\' or wbuf[wlen - 1] == '/')) wlen -= 1;
        wbuf[wlen] = '\\';
        wbuf[wlen + 1] = '*';
        wbuf[wlen + 2] = 0;
        var it: WindowsIter = .{
            .handle = undefined,
            .find_data = undefined,
            .pending_first = true,
            .name_buf = undefined,
        };
        const h = winsys.FindFirstFileW(@ptrCast(&wbuf), &it.find_data);
        if (h == INVALID_HANDLE_VALUE) return null;
        it.handle = h;
        return it;
    } else {
        const dirp = std.c.opendir(path_z) orelse return null;
        return .{ .dirp = @ptrCast(dirp) };
    }
}

pub fn next(it: *Iter) ?Entry {
    return it.next();
}

pub fn close(it: *Iter) void {
    it.close();
}

// 强制两平台分支体都被语义分析(引用 fn 即触发 body 分析)——否则 windows 分支因懒分析被跳过,
// 藏类型错(W5 rng / net.zig 同款陷阱)。standalone `--test-no-exec -target windows` 据此真编。
comptime {
    _ = &open;
    _ = &next;
    _ = &close;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const pfs = @import("fs.zig");

test "iterate a real directory finds seeded files" {
    if (is_windows) return; // 运行期仅 POSIX;windows 编译由全量 build -Dtarget 覆盖
    // 用 pid 唯一 tmp 目录,建两文件,遍历应见到。走 std.c/pfs(裁剪 std 无 std.fs.*Absolute)。
    const pid: i64 = std.c.getpid();
    // platform 层测试单独用 `zig test` 编译,不能依赖 util/fs.zig;根的规则就地写一遍:
    // POSIX /tmp,Windows %TEMP%(当前驱动器根下的 \tmp 不保证存在)。
    const tmp_root = if (@import("builtin").os.tag == .windows) @import("paths.zig").tempDir() else "/tmp";
    var dbuf: [512]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&dbuf, "{s}/cczig_dir_{d}", .{ tmp_root, pid });
    _ = std.c.mkdir(dir_z.ptr, 0o755);
    defer {
        var ab: [600]u8 = undefined;
        const a = std.fmt.bufPrintZ(&ab, "{s}/alpha.md", .{dir_z}) catch unreachable;
        _ = std.c.unlink(a.ptr);
        var bb: [600]u8 = undefined;
        const b = std.fmt.bufPrintZ(&bb, "{s}/beta.md", .{dir_z}) catch unreachable;
        _ = std.c.unlink(b.ptr);
        _ = std.c.rmdir(dir_z.ptr);
    }
    inline for (.{ "alpha.md", "beta.md" }) |fname| {
        var fb: [600]u8 = undefined;
        const fp = try std.fmt.bufPrintZ(&fb, "{s}/{s}", .{ dir_z, fname });
        const fd = pfs.open(fp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        try testing.expect(fd >= 0);
        _ = pfs.write(fd, "x");
        _ = pfs.close(fd);
    }

    var it = open(dir_z.ptr) orelse return error.OpenFailed;
    defer close(&it);
    var seen_alpha = false;
    var seen_beta = false;
    while (next(&it)) |e| {
        if (std.mem.eql(u8, e.name, "alpha.md")) seen_alpha = true;
        if (std.mem.eql(u8, e.name, "beta.md")) seen_beta = true;
    }
    try testing.expect(seen_alpha and seen_beta);
}
