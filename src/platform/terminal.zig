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

/// raw 模式前的原始状态（restoreMode 复原用）。POSIX=termios；Windows=进/出 console mode 对
/// + 进/出代码页(enterRaw 切 UTF-8,复原时还原)。
pub const SavedMode = if (is_windows) struct {
    in_mode: win.DWORD,
    out_mode: win.DWORD,
    out_valid: bool = false,
    in_cp: win.UINT = 0, // 0 = 未记录(不复原)
    out_cp: win.UINT = 0,
    stdin_fmode: c_int = 0, // CRT stdin 文本/二进制模式(0 = 未记录)
} else std.c.termios;

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
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) win.UINT;
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: win.UINT) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) win.UINT;
extern "kernel32" fn SetConsoleCP(wCodePageID: win.UINT) callconv(.winapi) c_int;
const CP_UTF8: win.UINT = 65001;
extern "c" fn _isatty(fd: c_int) c_int;
extern "c" fn _setmode(fd: c_int, mode: c_int) c_int;
const O_BINARY_MODE: c_int = 0x8000; // CRT _O_BINARY
extern "kernel32" fn WaitForSingleObject(hHandle: win.HANDLE, dwMilliseconds: win.DWORD) callconv(.winapi) win.DWORD;
extern "kernel32" fn GetNumberOfConsoleInputEvents(hConsoleInput: win.HANDLE, lpcNumberOfEvents: *win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn PeekConsoleInputW(hConsoleInput: win.HANDLE, lpBuffer: *INPUT_RECORD, nLength: win.DWORD, lpNumberOfEventsRead: *win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: win.HANDLE, lpBuffer: *INPUT_RECORD, nLength: win.DWORD, lpNumberOfEventsRead: *win.DWORD) callconv(.winapi) c_int;
const KEY_EVENT: u16 = 0x0001;
const KEY_EVENT_RECORD = extern struct {
    bKeyDown: c_int,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: extern union { UnicodeChar: u16, AsciiChar: u8 },
    dwControlKeyState: win.DWORD,
};
const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        raw: [16]u8, // 其它事件(mouse/resize/menu/focus)只需占位,统一消费不解析
    },
};

/// fd 是否连着终端。
/// 进程启动早期(任何输出之前)调用:Windows console 代码页切 UTF-8。
/// 应用全程写 UTF-8 字节;默认代码页(中文 Windows=GBK 936)下 enterRaw 之前的
/// banner/日志会被 console 按本地编码误读成乱码(ConPTY 实测)。POSIX no-op。
/// 正常退出路径应调 restoreConsoleCp() 还原(代码页是 console 属性,进程退出不自动还原)。
var g_orig_in_cp: if (is_windows) win.UINT else void = if (is_windows) 0 else {};
var g_orig_out_cp: if (is_windows) win.UINT else void = if (is_windows) 0 else {};
pub fn initConsoleUtf8() void {
    if (!is_windows) return;
    g_orig_in_cp = GetConsoleCP();
    g_orig_out_cp = GetConsoleOutputCP();
    _ = SetConsoleCP(CP_UTF8);
    _ = SetConsoleOutputCP(CP_UTF8);
}
pub fn restoreConsoleCp() void {
    if (!is_windows) return;
    if (g_orig_in_cp != 0) _ = SetConsoleCP(g_orig_in_cp);
    if (g_orig_out_cp != 0) _ = SetConsoleOutputCP(g_orig_out_cp);
}

pub fn isatty(fd: c_int) bool {
    if (is_windows) return _isatty(fd) != 0;
    return std.c.isatty(fd) != 0;
}

// ── 可移植终端输入读 ─────────────────────────────────────────────────────────
// Windows console 的 ReadFile/CRT read 在 CP65001 下对非 ASCII 输入返回**损坏字节**
// (conhost 历史缺陷;ConPTY 实测 '你' → U+FFFD×2,CJK 输入全乱)。console 输入必须走
// ReadConsoleW(UTF-16)再转 UTF-8;raw 模式(无 LINE_INPUT)下逐键返回,VT input
// 序列(方向键等 ESC 序列)同样经宽流下发,语义与 POSIX read 对齐。
// 单线程假设:REPL 输入仅主线程读(与 LineEditor 同约束),内部缓冲无锁。
var g_conin_buf: [1024]u8 = undefined;
var g_conin_len: usize = 0;
var g_conin_pos: usize = 0;

extern "kernel32" fn ReadConsoleW(hConsoleInput: win.HANDLE, lpBuffer: [*]u16, nNumberOfCharsToRead: win.DWORD, lpNumberOfCharsRead: *win.DWORD, pInputControl: ?*anyopaque) callconv(.winapi) c_int;

/// 读终端输入。POSIX / 非 console fd:直读(CRT read)。Windows console(fd=0 且真 console):
/// ReadConsoleW 宽读 → UTF-8 内部缓冲 → 按需吐出。返回读到字节数;0=EOF;<0=错误。
pub fn readInput(fd: c_int, buf: []u8) isize {
    if (is_windows and fd == 0) {
        const h = GetStdHandle(STD_INPUT_HANDLE);
        var mode: win.DWORD = 0;
        if (GetConsoleMode(h, &mode) != 0) {
            if (g_conin_pos >= g_conin_len) {
                var wbuf: [256]u16 = undefined;
                var got: win.DWORD = 0;
                if (ReadConsoleW(h, &wbuf, wbuf.len, &got, null) == 0) return -1;
                if (got == 0) return 0;
                // wtf16LeToWtf8(非 utf16 严格版,review-2 F3):批边界恰好截断 surrogate
                // pair(大段 emoji 粘贴可构造)或 IME 孤立 surrogate 时,严格版整批失败 →
                // 丢输入 + ReadError。WTF-8 版永不失败:孤立 half 各自编成 3 字节(跨批的
                // pair 两半**不合并**,极端场景显示降级为两个替换符),但零丢字节零报错。
                // 输出无边界检查:1024 ≥ 256×3 最坏膨胀,恒安全。
                g_conin_len = std.unicode.wtf16LeToWtf8(&g_conin_buf, wbuf[0..got]);
                g_conin_pos = 0;
            }
            const n = @min(buf.len, g_conin_len - g_conin_pos);
            @memcpy(buf[0..n], g_conin_buf[g_conin_pos..][0..n]);
            g_conin_pos += n;
            return @intCast(n);
        }
    }
    const fs_mod = @import("fs.zig");
    return fs_mod.read(fd, buf);
}

/// 等 fd 可读,最多 timeout_ms。返回 >0=可读、0=超时、<0=错误。
/// POSIX:poll(POLLIN)。Windows:WaitForSingleObject 控制台输入句柄 + **非键盘记录过滤**:
/// resize/focus/mouse/键抬起等 INPUT_RECORD 也会把句柄置 signaled,但 ReadFile 读不出字节——
/// 不过滤的话 resize 一发生,调用方 read 直接阻塞到下一次真按键(TUI 卡死,ConPTY 实测)。
/// 这里把队首的非产字节记录消费掉再判定;只剩非键记录时按"超时"返回,让调用方的
/// 超时分支(查 resize 标志/轮询尺寸)跑起来。
pub fn waitReadable(fd: c_int, timeout_ms: i32) i32 {
    if (is_windows) {
        // readInput 的内部 UTF-8 缓冲还有余量 → 立即可读(否则宽读一批后调用方在
        // waitReadable 上等 console 新事件,缓冲里的字节被卡住直到下一次按键)。
        if (g_conin_pos < g_conin_len) return 1;
        // fd(0=stdin)→ 控制台输入句柄。用 STD_INPUT_HANDLE 而非 _get_osfhandle:
        // 交互输入恒是控制台。
        const h = GetStdHandle(STD_INPUT_HANDLE);
        // 先清队首非键盘记录(仅当句柄真是 console;管道/重定向 GetNumberOfConsoleInputEvents
        // 失败 → 跳过,走纯 Wait 语义)。注:纯修饰键(单按 Shift)的 keydown 也不产字节,
        // 此处不过滤——与旧行为一致,最多多醒一次,read 等到下个真键,无卡死风险放大。
        while (true) {
            var pending: win.DWORD = 0;
            if (GetNumberOfConsoleInputEvents(h, &pending) == 0 or pending == 0) break;
            var rec: INPUT_RECORD = undefined;
            var got: win.DWORD = 0;
            if (PeekConsoleInputW(h, &rec, 1, &got) == 0 or got == 0) break;
            if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) return 1; // 真按键待读
            _ = ReadConsoleInputW(h, &rec, 1, &got); // 消费 resize/focus/mouse/keyup 记录
        }
        // @max(…,0):负超时(POSIX 语义=无限)在 windows @intCast 会 panic;调用方目前只传
        // 非负,防御性钳到 0(立即返回)而非误判 INFINITE。
        const rc = WaitForSingleObject(h, @intCast(@max(timeout_ms, 0)));
        if (rc == 0) {
            // 醒来可能是新到的非键记录:再过一遍过滤;过滤后队列只剩非键/空 → 按超时处理。
            while (true) {
                var pending: win.DWORD = 0;
                if (GetNumberOfConsoleInputEvents(h, &pending) == 0) return 1; // 非 console → 保持旧语义
                if (pending == 0) return 0;
                var rec: INPUT_RECORD = undefined;
                var got: win.DWORD = 0;
                if (PeekConsoleInputW(h, &rec, 1, &got) == 0 or got == 0) return 0;
                if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) return 1;
                _ = ReadConsoleInputW(h, &rec, 1, &got);
            }
        }
        return switch (rc) {
            // 0(WAIT_OBJECT_0)已在上面过滤循环里处理
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
        // 代码页:TUI 全程写 UTF-8 字节。默认代码页(中文 Windows=GBK 936)下 console 会
        // 误读成本地编码 → 全屏乱码(ConPTY 实测复现)。切 UTF-8,restoreMode 还原。
        const in_cp = GetConsoleCP();
        const out_cp = GetConsoleOutputCP();
        _ = SetConsoleCP(CP_UTF8);
        _ = SetConsoleOutputCP(CP_UTF8);
        // stdin 切二进制模式:CRT 文本模式会吞孤立 '\r'——而终端 Enter 发的正是 CR,
        // 不切则 raw 模式下 Enter 永远到不了 key parser(ConPTY 实测:\n 通、\r 丢)。
        const stdin_fmode = _setmode(0, O_BINARY_MODE);
        return .{ .in_mode = in_mode, .out_mode = out_mode, .out_valid = out_valid, .in_cp = in_cp, .out_cp = out_cp, .stdin_fmode = stdin_fmode };
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
        // 代码页还原(0 = enterRaw 没记录,saveMode 路径——不动)。
        if (saved.in_cp != 0) _ = SetConsoleCP(saved.in_cp);
        if (saved.out_cp != 0) _ = SetConsoleOutputCP(saved.out_cp);
        // stdin 文本/二进制模式还原(0/-1 = 未记录或失败——不动)。
        if (saved.stdin_fmode > 0) _ = _setmode(0, saved.stdin_fmode);
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
