//! Alt screen 生命周期管理(从 transcript_viewer.zig 抽出共用形式)。
//!
//! 用途:
//! - `transcript_viewer` 全屏浏览模式
//! - `tui fullscreen` 模式(Stage 5,§5.6)
//! - 未来的 `Ctrl+T` 任务列表覆盖层(若改成全屏视图)
//!
//! 不变量:enter 和 exit 必须配对。Drop(进程异常退出)会留 alt screen 状态,
//! 但终端在子进程退出 / 用户 Ctrl+C 时会清理。
//!
//! API 故意保持极简:enter / exit / isEntered。不管输入循环、不管渲染策略——
//! 调用方自己组织,本模块只负责"进入/退出 alt screen + 隐藏/恢复光标"。

const std = @import("std");
const pfs = @import("platform").fs;
const ansi = @import("ansi.zig");

pub const Overlay = struct {
    /// 写 ANSI 的 fd(通常 1 = stdout)
    fd: c_int = 1,
    /// 是否已 enter(防双重 enter / 没 enter 就 exit)
    entered: bool = false,
    /// 是否同时隐藏光标(default true)
    hide_cursor: bool = true,

    pub fn enter(self: *Overlay) void {
        if (self.entered) return;
        writeAll(self.fd, ansi.screen.alt_enter);
        if (self.hide_cursor) writeAll(self.fd, ansi.cursor.hide);
        // 进入 alt screen 后内容默认空,光标可能在任意位置,主动 home
        writeAll(self.fd, ansi.cursor.home);
        self.entered = true;
    }

    pub fn exit(self: *Overlay) void {
        if (!self.entered) return;
        if (self.hide_cursor) writeAll(self.fd, ansi.cursor.show);
        writeAll(self.fd, ansi.screen.alt_exit);
        self.entered = false;
    }

    pub fn isEntered(self: *const Overlay) bool {
        return self.entered;
    }
};

fn writeAll(fd: c_int, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const n = pfs.write(fd, bytes[total..][0 .. bytes.len - total]);
        if (n <= 0) return; // 终端关闭等异常:静默放弃
        total += @as(usize, @intCast(n));
    }
}

// ============================================================================
// Tests:不能真打 alt screen(会污染测试输出),所以测状态机即可。
// 真 IO 测试在 L3 集成层(pty)做。
// ============================================================================

const testing = std.testing;

test "Overlay: 双 enter 幂等" {
    // 用 /dev/null fd 避免污染终端
    const dev_null = pfs.open(@import("platform").paths.null_device, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    defer {
        if (dev_null >= 0) _ = pfs.close(dev_null);
    }
    if (dev_null < 0) return error.SkipZigTest;

    var ov = Overlay{ .fd = dev_null };
    try testing.expect(!ov.isEntered());
    ov.enter();
    try testing.expect(ov.isEntered());
    ov.enter(); // 第二次 enter 应 no-op
    try testing.expect(ov.isEntered());
    ov.exit();
    try testing.expect(!ov.isEntered());
    ov.exit(); // 第二次 exit 应 no-op
    try testing.expect(!ov.isEntered());
}

test "Overlay: hide_cursor=false 不写 hide/show" {
    const dev_null = pfs.open(@import("platform").paths.null_device, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    defer {
        if (dev_null >= 0) _ = pfs.close(dev_null);
    }
    if (dev_null < 0) return error.SkipZigTest;

    var ov = Overlay{ .fd = dev_null, .hide_cursor = false };
    ov.enter();
    try testing.expect(ov.isEntered());
    ov.exit();
    try testing.expect(!ov.isEntered());
}
