//! W4 可移植终端控制（跨平台移植 roadmap，tinykg node 8869）。
//!
//! POSIX 用 termios（tcgetattr/tcsetattr）+ ioctl(TIOCGWINSZ)；Windows 用 console mode
//! (GetConsoleMode/SetConsoleMode) + GetConsoleScreenBufferInfo。
//!
//! 只抽象【模式切换 + 尺寸 + isatty】；escape 序列（kitty/bracketed-paste）由上层 input.zig
//! 负责（终端协议白名单逻辑不属平台层）。ANSI VT 渲染在 Windows Terminal 上原生支持——Windows
//! raw 模式同时开 ENABLE_VIRTUAL_TERMINAL_INPUT(输入)+ ENABLE_VIRTUAL_TERMINAL_PROCESSING(输出)，
//! 使既有 ANSI 渲染层零改动可用。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;

/// raw 模式前的原始状态（restoreMode 复原用）。POSIX=termios；Windows=进/出 console mode 对。
pub const SavedMode = if (is_windows) struct { in_mode: win.DWORD, out_mode: win.DWORD, out_valid: bool = false } else std.c.termios;

// ── Windows console API（std 仅绑 ENABLE_VIRTUAL_TERMINAL_PROCESSING，其余自 extern）──────
const STD_INPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -11));
const ENABLE_PROCESSED_INPUT: win.DWORD = 0x0001;
const ENABLE_LINE_INPUT: win.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: win.DWORD = 0x0004;
const ENABLE_VIRTUAL_TERMINAL_INPUT: win.DWORD = 0x0200;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: win.DWORD = 0x0004;

const COORD = extern struct { X: i16, Y: i16 };
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) callconv(.winapi) win.HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: win.HANDLE, lpMode: *win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: win.HANDLE, dwMode: win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: win.HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) c_int;
extern "c" fn _isatty(fd: c_int) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: win.HANDLE, dwMilliseconds: win.DWORD) callconv(.winapi) win.DWORD;

/// fd 是否连着终端。
pub fn isatty(fd: c_int) bool {
    if (is_windows) return _isatty(fd) != 0;
    return std.c.isatty(fd) != 0;
}

/// 等 fd 可读,最多 timeout_ms。返回 >0=可读、0=超时、<0=错误。
/// POSIX:poll(POLLIN)。Windows:WaitForSingleObject 控制台输入句柄(任意输入事件即就绪——
/// 键盘/鼠标/焦点都算,REPL 读循环据实际字节再定夺,粗就绪无碍)。用于交互输入循环周期性
/// 醒来查 resize/中断,不阻塞死等。
pub fn waitReadable(fd: c_int, timeout_ms: i32) i32 {
    if (is_windows) {
        // fd(0=stdin)→ 控制台输入句柄。用 STD_INPUT_HANDLE 而非 _get_osfhandle:
        // 交互输入恒是控制台。
        const h = GetStdHandle(STD_INPUT_HANDLE);
        // @max(…,0):负超时(POSIX 语义=无限)在 windows @intCast 会 panic;调用方目前只传
        // 非负,防御性钳到 0(立即返回)而非误判 INFINITE。
        const rc = WaitForSingleObject(h, @intCast(@max(timeout_ms, 0)));
        return switch (rc) {
            0 => 1, // WAIT_OBJECT_0:就绪
            0x102 => 0, // WAIT_TIMEOUT
            else => -1,
        };
    }
    var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    return std.c.poll(&pfd, 1, timeout_ms);
}

pub const TermSize = struct { rows: u16, cols: u16 };

/// 查终端尺寸。非 TTY / 失败 → null。
pub fn windowSize(fd: c_int) ?TermSize {
    if (is_windows) {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const h = GetStdHandle(STD_OUTPUT_HANDLE);
        if (GetConsoleScreenBufferInfo(h, &info) == 0) return null;
        // 可见窗口尺寸（非缓冲区）：右-左+1 列、下-上+1 行。
        const cols: u16 = @intCast(@max(0, info.srWindow.Right - info.srWindow.Left + 1));
        const rows: u16 = @intCast(@max(0, info.srWindow.Bottom - info.srWindow.Top + 1));
        return .{ .rows = rows, .cols = cols };
    }
    var ws: extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 } = undefined;
    const TIOCGWINSZ: c_ulong = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => 0x40087468,
        else => 0x5413, // Linux
    };
    if (std.c.ioctl(fd, TIOCGWINSZ, &ws) != 0) return null;
    return .{ .rows = ws.row, .cols = ws.col };
}

/// 进 raw 模式（关行缓冲/回显/信号），返回原始状态（restoreMode 复原）；非 tty/失败 → null。
/// 只切模式，不发 escape 序列（上层负责）。
pub fn enterRaw(fd: c_int) ?SavedMode {
    if (is_windows) {
        const hin = GetStdHandle(STD_INPUT_HANDLE);
        const hout = GetStdHandle(STD_OUTPUT_HANDLE);
        var in_mode: win.DWORD = 0;
        var out_mode: win.DWORD = 0;
        if (GetConsoleMode(hin, &in_mode) == 0) return null;
        const out_valid = GetConsoleMode(hout, &out_mode) != 0; // 取不到也继续开 VT,但**别复原**它
        // 输入：关行输入/回显/processed，开 VT 输入（ANSI 键序）。
        var new_in = in_mode;
        new_in &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
        new_in |= ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (SetConsoleMode(hin, new_in) == 0) return null;
        // 输出：开 VT processing（使既有 ANSI 渲染层生效）。仅在原模式取到时才动/复原。
        if (out_valid) _ = SetConsoleMode(hout, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        return .{ .in_mode = in_mode, .out_mode = out_mode, .out_valid = out_valid };
    }
    var orig: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &orig) != 0) return null;
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    if (std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &raw) != 0) return null;
    return orig;
}

/// 复原终端模式。
pub fn restoreMode(fd: c_int, saved: SavedMode) void {
    if (is_windows) {
        _ = SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), saved.in_mode);
        // 仅当原输出模式成功取到才复原——否则 out_mode=0 的 SetConsoleMode 会清掉 VT processing
        // 等本来开着的输出标志(把终端弄哑)。
        if (saved.out_valid) _ = SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), saved.out_mode);
    } else {
        _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &saved);
    }
}

/// 保存当前终端模式（不改变），供 restoreMode 复原。用于"临时切 cooked 再复原"场景。
pub fn saveMode(fd: c_int) ?SavedMode {
    if (is_windows) {
        var in_mode: win.DWORD = 0;
        var out_mode: win.DWORD = 0;
        if (GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &in_mode) == 0) return null;
        const out_valid = GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &out_mode) != 0;
        return .{ .in_mode = in_mode, .out_mode = out_mode, .out_valid = out_valid };
    }
    var orig: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &orig) != 0) return null;
    return orig;
}

/// 临时切 cooked 模式（行输入 + 回显 + 信号），供唤起外部编辑器等。复原走 restoreMode(saved)。
pub fn setCooked(fd: c_int) void {
    if (is_windows) {
        const hin = GetStdHandle(STD_INPUT_HANDLE);
        var m: win.DWORD = 0;
        if (GetConsoleMode(hin, &m) == 0) return;
        _ = SetConsoleMode(hin, m | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
        return;
    }
    var t: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &t) != 0) return;
    t.lflag.ECHO = true;
    t.lflag.ICANON = true;
    t.lflag.ISIG = true;
    _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &t);
}

// ============================================================================
// Tests
// ============================================================================

test "isatty 对非 tty fd 返 false（管道/文件）" {
    // 测试环境 stdin 通常非 tty（被重定向）；至少确认不 crash 且返 bool。
    _ = isatty(0);
    // 一个肯定非 tty 的 fd：打开 /dev/null（POSIX）。Windows 该测试跳过（走 CI 编译）。
    if (is_windows) return;
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    defer _ = std.c.close(fd);
    try std.testing.expect(!isatty(fd));
}

test "windowSize 非 tty 返 null 不 crash" {
    if (is_windows) return;
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(?TermSize, null), windowSize(fd));
}
