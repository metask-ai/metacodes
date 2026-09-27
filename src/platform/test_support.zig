//! 测试专用夹具:文件系统链接、目录枚举断言与虚拟时钟。只从 `test` 块 `@import`,生产代码不得引用。
//!
//! - `symlinkOrSkip`:Windows 上创建 symlink 需要 SeCreateSymbolicLinkPrivilege(或开发者模式);
//!   runner 拿不到就把用例标成 skip,而不是把"没特权"报成回归。其余平台照常创建。
//! - `junction`:NTFS junction(目录挂载点)不需要任何特权,是 Windows 安装最常见的链接形态
//!   (`mklink /J`),也是 #140 里 `_fullpath` 解不开的那种重解析点。成功判定 = 退出码 0 **且**
//!   链接存在(两个条件都要:cmd 内建命令的退出码并不总可靠)。
//! - `countEntriesNamed`:目录里除 `.`/`..` 外的条目数,并断言每个条目都叫指定名字——#121 的
//!   独立证据通道(platform/dir 走 FindFirstFileW / readdir,与被测的 CRT 窄路径无关)。
//! - `TickServicedClock`:睡眠按 Windows NT 相对等待建模的虚拟 awake 时钟,可早醒最多一个 tick;
//!   在任何宿主上确定性复现 Windows 早醒,给截止时长的下界做单测。

const std = @import("std");
const builtin = @import("builtin");

pub fn symlinkOrSkip(
    dir: std.Io.Dir,
    io: std.Io,
    target_path: []const u8,
    sym_link_path: []const u8,
    flags: std.Io.Dir.SymLinkFlags,
) !void {
    dir.symLink(io, target_path, sym_link_path, flags) catch |err| switch (err) {
        error.PermissionDenied, error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
}

/// `cmd.exe /c mklink /J <link> <target>`(cmd 内建;两个参数都改成反斜杠,mklink 不认正斜杠)。
/// 非 Windows 直接 skip——调用方通常已按平台门控。
pub fn junction(allocator: std.mem.Allocator, link: []const u8, target: []const u8) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const process = @import("process.zig");
    const fs = @import("fs.zig");
    const link_z = try allocator.dupeZ(u8, link);
    defer allocator.free(link_z);
    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    for (link_z) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    for (target_z) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    const comspec: [*:0]const u8 = std.c.getenv("COMSPEC") orelse "cmd.exe";
    const argv = [_]?[*:0]const u8{ comspec, "/c", "mklink", "/J", link_z.ptr, target_z.ptr, null };
    const captured = try process.captureStdout(argv[0..], allocator, 30_000, 1 << 16);
    defer allocator.free(captured.stdout);
    defer allocator.free(captured.stderr);
    if (captured.exit_code != 0 or !fs.exists(link_z.ptr)) return error.JunctionCreateFailed;
}

/// 目录里除 `.`/`..` 外的条目数,并断言每个条目都叫 `expected_name`。
pub fn countEntriesNamed(dir_z: [*:0]const u8, expected_name: []const u8) !usize {
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

/// 虚拟 awake 时钟,睡眠按 NT 相对等待建模。`std.Io.Threaded` 在 Windows 上连 `.deadline` 也换算成
/// 这种等待(`timeoutToWindowsInterval`):到期时刻 = 上一个时钟中断 tick 的中断时间 + 间隔,定时器
/// 只在 tick 上到期,所以在 tick 后段开始的一次睡眠可能比请求的时长早醒最多一个 tick。
/// 只覆盖 `now`/`sleep`;其余 vtable 项取自 `std.Io.failing`,不碰 userdata。
pub const TickServicedClock = struct {
    now_ns: i96,
    /// 已发起的等待次数,含被取消的那次。
    sleeps: u32 = 0,
    /// 挂起的取消请求;同 `std.Io`,只有下一次等待观察到它。
    cancel_requested: bool = false,

    /// Windows 默认时钟中断周期(64 Hz)。
    pub const tick_ns: i96 = 15_625_000;

    const vtable: std.Io.VTable = vtable: {
        var v = std.Io.failing.vtable.*;
        v.now = now;
        v.sleep = sleep;
        break :vtable v;
    };

    pub fn io(clock: *TickServicedClock) std.Io {
        return .{ .userdata = clock, .vtable = &vtable };
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        const self: *TickServicedClock = @ptrCast(@alignCast(userdata));
        std.debug.assert(clock == .awake);
        return .fromNanoseconds(self.now_ns);
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *TickServicedClock = @ptrCast(@alignCast(userdata));
        self.sleeps += 1;
        if (self.cancel_requested) {
            self.cancel_requested = false;
            return error.Canceled;
        }
        const interval: i96 = switch (timeout) {
            .none => unreachable,
            .duration => |d| d.raw.nanoseconds,
            .deadline => |d| d.raw.nanoseconds - self.now_ns,
        };
        // NT 至少等 100 ns,时钟总会前进。
        const due = @divFloor(self.now_ns, tick_ns) * tick_ns + @max(interval, 100);
        self.now_ns = (std.math.divCeil(i96, due, tick_ns) catch unreachable) * tick_ns;
    }
};
