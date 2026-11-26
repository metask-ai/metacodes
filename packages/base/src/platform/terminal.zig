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
extern "kernel32" fn FlushConsoleInputBuffer(hConsoleInput: win.HANDLE) callconv(.winapi) c_int;
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

/// Whether stdin and stdout are both a Windows console (conhost, or a pseudo
/// console such as Windows Terminal's): the host of console modes like
/// win32-input-mode. Redirected or piped handles are not, nor is anything on
/// POSIX (a Linux binary under WSL included).
pub fn isConsole() bool {
    if (!is_windows) return false;
    var mode: win.DWORD = 0;
    return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode) != 0 and
        GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0;
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

// ── win32-input-mode 按键记录 ───────────────────────────────────────────────
// The REPL turns win32-input-mode on (repl/input.zig, `CSI ? 9001 h`) so that
// Shift+Enter is not Enter; the console then sends every key as a record.
// Every reader of the console reads through readInput/waitReadable, and these
// decode the records there (win32_input.zig): the permission dialog, the
// question dialog, the pager and vim's normal mode read the bytes they read
// without the mode, not the records. Once on it stays on: records already
// queued when the mode goes off are still to be read, and the decoder passes
// every byte that is no record as it came.
const win32_input = @import("win32_input.zig");
var g_key_records = std.atomic.Value(bool).init(false);
var g_decoder: win32_input.Decoder = .{};
var g_last_read_key_record: bool = false;
var g_key_records_type_text = std.atomic.Value(bool).init(false);

/// Read the console's input as win32-input-mode key records from now on,
/// right after `CSI ? 9001 h` went to the console. Windows only.
pub fn decodeKeyRecords() void {
    if (is_windows) g_key_records.store(true, .release);
}

/// Whether the last byte readInput handed out came from a key record, a key
/// pressed on the console, rather than as a byte the terminal wrote (the
/// `ESC CR` of a Shift+Enter key binding, text, a replay). False off Windows.
pub fn lastReadWasKeyRecord() bool {
    return g_last_read_key_record;
}

/// Whether a key record typed text: the console's host sends the keys it
/// reads off the keyboard, modifier state included (Windows Terminal, classic
/// conhost), so Shift+Enter arrives as itself. A terminal that sends only VT
/// bytes through ConPTY gets records for its lone control characters, never
/// for text (win32_input.Decoder.typed_text).
pub fn keyRecordsTypeText() bool {
    return g_key_records_type_text.load(.acquire);
}

/// Tests: `stream` through the console's decoder as if ReadConsoleW had
/// returned it; the decoded bytes are dropped.
pub fn decodeConsoleInputForTesting(stream: []const u8) void {
    @memcpy(g_conin_buf[0..stream.len], stream);
    g_conin_len = stream.len;
    g_conin_pos = 0;
    var sink: [64]u8 = undefined;
    while (g_conin_pos < g_conin_len or g_decoder.holding()) {
        decodeRead();
        _ = g_decoder.take(&sink);
    }
    g_decoder.endOfInput();
    _ = g_decoder.take(&sink);
}

/// Tests: forget the console input read and what it showed of the host, and
/// read the console as without win32-input-mode again.
pub fn resetConsoleInputForTesting() void {
    g_key_records.store(false, .release);
    g_conin_len = 0;
    g_conin_pos = 0;
    g_decoder = .{};
    g_last_read_key_record = false;
    g_key_records_type_text.store(false, .release);
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn ReadConsoleW(hConsoleInput: win.HANDLE, lpBuffer: [*]u16, nNumberOfCharsToRead: win.DWORD, lpNumberOfCharsRead: *win.DWORD, pInputControl: ?*anyopaque) callconv(.winapi) c_int;

// ── 回放:已从终端读走、还欠下一个读者的输入 ─────────────────────────────────
// 启动期终端探测(repl/tui/bg_probe.zig)读应答时,同一批字节里可能夹着用户在探测期间
// 敲的键、粘贴的文字。探测把这些原样交回这里(replayInput),readInput/waitReadable 先吐
// 它们、再读终端:输入 parser 看到的字节流与没有探测时逐字节相同(#327)。
// 单线程假设同上;唯一的跨线程读者(启动动画线程)在探测写完之后才起。
pub const replay_capacity = 4096;
var g_replay_buf: [replay_capacity]u8 = undefined;
var g_replay_fd: c_int = -1;
var g_replay_len: usize = 0;
var g_replay_pos: usize = 0;

/// Hand `bytes`, read from `fd` but not meant for the reader that took them,
/// back to the next `readInput(fd, …)`, ahead of anything the terminal sends
/// later. They append to what is still owed. At most `replay_capacity` bytes
/// are owed: this takes what fits (`replayRoom`) and returns how many bytes
/// it took. Callers read no more from the terminal than fits, so nothing is
/// cut; one that passed more would lose the excess, never the buffer.
pub fn replayInput(fd: c_int, bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    if (g_replay_pos >= g_replay_len or g_replay_fd != fd) {
        g_replay_len = 0;
        g_replay_pos = 0;
    }
    // Move what is still owed to the front, then append.
    const owed = g_replay_len - g_replay_pos;
    std.mem.copyForwards(u8, g_replay_buf[0..owed], g_replay_buf[g_replay_pos..g_replay_len]);
    const n = @min(bytes.len, replay_capacity - owed);
    @memcpy(g_replay_buf[owed..][0..n], bytes[0..n]);
    g_replay_fd = fd;
    g_replay_pos = 0;
    g_replay_len = owed + n;
    return n;
}

/// How many times input the terminal had received was thrown away: a POSIX
/// mode switch with TCSAFLUSH, or `discardPendingInput`. A reader holding the
/// first half of a sequence compares two counts to learn that its second
/// half may be gone. A discard that found nothing queued does not count: the
/// half still to come cannot have gone with it (the startup splash enters raw
/// mode right after the probe, before a late tail arrives). Queued input is
/// what `poll` reports, which in canonical mode is only a whole line; the
/// reader this is for keeps the terminal non-canonical.
var g_discards = std.atomic.Value(u32).init(0);

pub fn discardCount() u32 {
    return g_discards.load(.acquire);
}

/// Whether a discard on `fd` now throws input away.
fn hasQueuedInput(fd: c_int) bool {
    return waitTerminal(fd, 0) > 0;
}

fn replayOwed(fd: c_int) []const u8 {
    if (fd != g_replay_fd) return &.{};
    return g_replay_buf[g_replay_pos..g_replay_len];
}

/// How many more bytes `replayInput(fd, …)` can take now.
pub fn replayRoom(fd: c_int) usize {
    return replay_capacity - replayOwed(fd).len;
}

/// What the terminal has queued on `fd`, without waiting and without the
/// bytes `replayInput` handed back: 0 when nothing is queued, <0 on error.
pub fn readPending(fd: c_int, buf: []u8) isize {
    if (waitTerminal(fd, 0) <= 0) return 0;
    return readTerminal(fd, buf);
}

/// 读终端输入。先吐 replayInput 交回的字节(若有)。POSIX / 非 console fd:直读(CRT read)。
/// Windows console(fd=0 且真 console):ReadConsoleW 宽读 → UTF-8 内部缓冲 → 按需吐出。
/// 返回读到字节数;0=EOF;<0=错误。
pub fn readInput(fd: c_int, buf: []u8) isize {
    const owed = replayOwed(fd);
    if (owed.len > 0 and buf.len > 0) {
        const n = @min(buf.len, owed.len);
        @memcpy(buf[0..n], owed[0..n]);
        g_replay_pos += n;
        g_last_read_key_record = false;
        return @intCast(n);
    }
    return readTerminal(fd, buf);
}

/// readInput without the replay: what the terminal itself sends.
fn readTerminal(fd: c_int, buf: []u8) isize {
    if (is_windows and fd == 0) {
        const h = GetStdHandle(STD_INPUT_HANDLE);
        var mode: win.DWORD = 0;
        if (GetConsoleMode(h, &mode) != 0) {
            if (g_key_records.load(.acquire)) return readDecoded(h, buf);
            if (g_conin_pos >= g_conin_len) {
                const got = fillConin(h);
                if (got <= 0) return got;
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

/// One ReadConsoleW into the UTF-8 buffer, which must be read out: it blocks
/// until the console has a character. Characters read, 0, or <0 on error.
fn fillConin(h: win.HANDLE) isize {
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
    return @intCast(got);
}

/// Bytes read from the console but not yet through the decoder go through it
/// until it has something to hand out.
fn decodeRead() void {
    while (!g_decoder.holding() and g_conin_pos < g_conin_len) {
        g_decoder.put(g_conin_buf[g_conin_pos]);
        g_conin_pos += 1;
    }
    if (g_decoder.typed_text) g_key_records_type_text.store(true, .release);
}

/// readTerminal on a console that sends key records: the decoded bytes, as
/// many as are ready, waiting for the console only when none are. A record
/// the read cut in two waits for its rest, which the console queued with it;
/// with nothing queued, what was read of it is the bytes it was.
fn readDecoded(h: win.HANDLE, buf: []u8) isize {
    var n: usize = 0;
    while (true) {
        n += g_decoder.take(buf[n..]);
        if (n > 0) g_last_read_key_record = g_decoder.last_from_record;
        if (n == buf.len) return @intCast(n);
        if (g_conin_pos < g_conin_len) {
            decodeRead();
            continue;
        }
        if (n > 0) return @intCast(n);
        if (g_decoder.framing() and !keyDownQueued(h)) {
            g_decoder.endOfInput();
            continue;
        }
        const got = fillConin(h);
        if (got <= 0) return got;
    }
}

/// Consume the events at the head of the queue that are no key-down (resize,
/// focus, mouse, key-up): ReadConsoleW reads no character from them. Whether
/// a key-down is left at the head.
fn keyDownQueued(h: win.HANDLE) bool {
    while (true) {
        var pending: win.DWORD = 0;
        if (GetNumberOfConsoleInputEvents(h, &pending) == 0 or pending == 0) return false;
        var rec: INPUT_RECORD = undefined;
        var got: win.DWORD = 0;
        if (PeekConsoleInputW(h, &rec, 1, &got) == 0 or got == 0) return false;
        if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) return true;
        _ = ReadConsoleInputW(h, &rec, 1, &got);
    }
}

/// Whether the key-down at the head of the queue carries a character, so
/// that ReadConsoleW returns at once. Every character of a key record does;
/// with win32-input-mode off, a bare modifier does not, and ReadConsoleW
/// would wait for the next key that types.
fn queuedKeyTypes(h: win.HANDLE) bool {
    var rec: INPUT_RECORD = undefined;
    var got: win.DWORD = 0;
    if (PeekConsoleInputW(h, &rec, 1, &got) == 0 or got == 0) return false;
    return rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0 and !typesNothing(rec.Event.KeyEvent);
}

/// waitTerminal on a console that sends key records: readable once there are
/// decoded bytes to read. A record that types nothing (a key-up, a modifier
/// alone) is read and dropped here and the wait goes on to its end: a reader
/// waiting to tell Esc from the start of a sequence is not woken by the Esc's
/// own key-up. A wake-up for an event that is no key (resize, focus) still
/// ends the wait early, as in waitTerminal, so the caller looks at the size.
fn waitDecoded(h: win.HANDLE, timeout_ms: i32) i32 {
    const deadline = GetTickCount64() + @as(u64, @intCast(@max(timeout_ms, 0)));
    while (true) {
        decodeRead();
        if (g_decoder.holding()) return 1;
        if (keyDownQueued(h)) {
            if (!queuedKeyTypes(h)) return 1;
            const got = fillConin(h);
            if (got < 0) return -1;
            if (got == 0) return 0;
            continue;
        }
        if (g_decoder.framing()) {
            g_decoder.endOfInput();
            continue;
        }
        const now = GetTickCount64();
        if (now >= deadline) return 0;
        const rc = WaitForSingleObject(h, @intCast(@min(deadline - now, std.math.maxInt(u32) - 1)));
        if (rc == 0x102) return 0; // WAIT_TIMEOUT
        if (rc != 0) return -1;
        if (!keyDownQueued(h)) return 0;
    }
}

/// 等 fd 可读,最多 timeout_ms。返回 >0=可读、0=超时、<0=错误。
/// POSIX:poll(POLLIN)。Windows:WaitForSingleObject 控制台输入句柄 + **非键盘记录过滤**:
/// resize/focus/mouse/键抬起等 INPUT_RECORD 也会把句柄置 signaled,但 ReadFile 读不出字节——
/// 不过滤的话 resize 一发生,调用方 read 直接阻塞到下一次真按键(TUI 卡死,ConPTY 实测)。
/// 这里把队首的非产字节记录消费掉再判定;只剩非键记录时按"超时"返回,让调用方的
/// 超时分支(查 resize 标志/轮询尺寸)跑起来。replayInput 交回的字节还没吐完 → 立即可读。
/// 控制台送 win32-input-mode 按键记录时(decodeKeyRecords):可读 = 有还原好的字节可读,
/// 不产字节的记录(抬键、单按修饰键)不算,等待照旧到时(waitDecoded)。
pub fn waitReadable(fd: c_int, timeout_ms: i32) i32 {
    if (replayOwed(fd).len > 0) return 1;
    return waitTerminal(fd, timeout_ms);
}

/// waitReadable without the replay: whether the terminal itself has input.
fn waitTerminal(fd: c_int, timeout_ms: i32) i32 {
    if (is_windows) {
        // fd(0=stdin)→ 控制台输入句柄。用 STD_INPUT_HANDLE 而非 _get_osfhandle:
        // 交互输入恒是控制台。
        const h = GetStdHandle(STD_INPUT_HANDLE);
        var mode: win.DWORD = 0;
        if (fd == 0 and g_key_records.load(.acquire) and GetConsoleMode(h, &mode) != 0) return waitDecoded(h, timeout_ms);
        // readInput 的内部 UTF-8 缓冲还有余量 → 立即可读(否则宽读一批后调用方在
        // waitReadable 上等 console 新事件,缓冲里的字节被卡住直到下一次按键)。
        if (g_conin_pos < g_conin_len) return 1;
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

/// Throw away every pending input event without ever blocking.
///
/// Windows console: the whole input queue goes, together with what
/// `readInput` has already decoded. That includes key records that carry no
/// character, such as a bare Shift, Ctrl, Alt, Win or CapsLock: `waitReadable`
/// reports those as readable, and `ReadConsoleW` would then block until the
/// next key that types something. POSIX, or a non-console fd: the bytes
/// already readable, a bounded number of reads that never wait.
///
/// Bytes handed back with `replayInput` stay: the process has already read
/// them from the terminal and owes them to the input parser, they are not
/// pending there.
pub fn discardPendingInput(fd: c_int) void {
    if (hasQueuedInput(fd)) _ = g_discards.fetchAdd(1, .acq_rel);
    if (is_windows and fd == 0) {
        const h = GetStdHandle(STD_INPUT_HANDLE);
        var mode: win.DWORD = 0;
        if (GetConsoleMode(h, &mode) != 0) {
            _ = FlushConsoleInputBuffer(h);
            g_conin_len = 0;
            g_conin_pos = 0;
            g_decoder.reset();
            return;
        }
    }
    // Bounded (16 KiB, room for a paste) so a stream that never stops
    // cannot hold the caller; each read follows a zero-timeout check.
    var scratch: [256]u8 = undefined;
    var rounds: u8 = 0;
    while (rounds < 64 and waitTerminal(fd, 0) > 0) : (rounds += 1) {
        if (readTerminal(fd, &scratch) <= 0) break;
    }
}

/// Drop, without blocking, the pending input events at the head of the
/// queue that type nothing, and keep everything from the first one that
/// does. A Windows console can queue a key-down that carries no character
/// (a bare Shift, Ctrl, Alt, Win or lock key; whatever else a host passes on
/// without one); `waitReadable` reports it, and `ReadConsoleW` would then
/// block until the next key that types something. For the readers of startup
/// input, which keep only what types: the startup animation skips on a key
/// and leaves it for the prompt, and the first prompt reads all of it.
/// POSIX: every pending byte is input; nothing goes.
pub fn dropSilentInput(fd: c_int) void {
    if (!is_windows or fd != 0) return;
    const h = GetStdHandle(STD_INPUT_HANDLE);
    while (true) {
        var pending: win.DWORD = 0;
        if (GetNumberOfConsoleInputEvents(h, &pending) == 0 or pending == 0) return;
        var rec: INPUT_RECORD = undefined;
        var got: win.DWORD = 0;
        if (PeekConsoleInputW(h, &rec, 1, &got) == 0 or got == 0) return;
        if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0 and
            !typesNothing(rec.Event.KeyEvent)) return;
        _ = ReadConsoleInputW(h, &rec, 1, &got);
    }
}

/// A key-down that carries no character types nothing.
fn typesNothing(key: KEY_EVENT_RECORD) bool {
    return key.uChar.UnicodeChar == 0;
}

pub const TermSize = struct { rows: u16, cols: u16 };

/// Whether the console re-wraps the lines it shows when the window narrows,
/// where the platform decides it rather than the terminal emulator. On POSIX
/// the emulator decides (null; repl/tui/term.zig reads its environment). On
/// Windows the output goes through conhost, and the pseudo console the TTY
/// suite drives (pywinpty, on the CI runners and on Windows 11) clips: after
/// a narrowing the banner stays one row, and a frame that climbed as if its
/// rows had been re-wrapped went one row too far per resize, erasing the line
/// above it. A Windows host that does re-wrap is left the old rule's second
/// half instead, the lesser fault: it erases nothing.
pub const console_reflows: ?bool = if (is_windows) false else null;

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
/// 只切模式，不发 escape 序列（上层负责）。POSIX 切换时丢掉终端已收、未读的输入(TCSAFLUSH)。
pub fn enterRaw(fd: c_int) ?SavedMode {
    return enterRawWith(fd, .discard);
}

/// What a POSIX mode switch does with input the terminal has received but
/// nobody has read. A Windows console mode switch never discards input.
const PendingInput = enum { discard, keep };

/// enterRaw that keeps the input already received (TCSANOW): a line typed
/// ahead in cooked mode becomes readable instead of being dropped. For a
/// reader that hands back every byte it does not consume (the startup probe,
/// `replayInput`).
pub fn enterRawKeepingInput(fd: c_int) ?SavedMode {
    return enterRawWith(fd, .keep);
}

/// restoreMode that keeps the input already received, the pair of
/// enterRawKeepingInput.
pub fn restoreModeKeepingInput(fd: c_int, saved: SavedMode) void {
    restoreModeWith(fd, saved, .keep);
}

fn enterRawWith(fd: c_int, pending: PendingInput) ?SavedMode {
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
    const discards = pending == .discard and hasQueuedInput(fd);
    if (std.c.tcsetattr(fd, tcsaction(pending), &raw) != 0) return null;
    if (discards) _ = g_discards.fetchAdd(1, .acq_rel);
    return orig;
}

/// Keep the terminal quiet: nothing typed is echoed, input is readable byte
/// by byte, and Ctrl+C / Ctrl+Z still signal (unlike raw mode). `original` is
/// the mode to build it from. Input already received stays. For the stretch
/// of startup between the terminal probe and the REPL, when the probe's
/// answers may still arrive and must not be echoed. POSIX only (a Windows
/// console echoes only while a read is pending): false elsewhere.
pub fn enterQuiet(fd: c_int, original: SavedMode) bool {
    if (is_windows) return false;
    var quiet = original;
    quiet.lflag.ECHO = false;
    quiet.lflag.ICANON = false;
    quiet.lflag.IEXTEN = false;
    quiet.cc[@intFromEnum(std.c.V.MIN)] = 1;
    quiet.cc[@intFromEnum(std.c.V.TIME)] = 0;
    return std.c.tcsetattr(fd, std.posix.TCSA.NOW, &quiet) == 0;
}

// ── 退出时复原 ─────────────────────────────────────────────────────────────
// enterQuiet 之后、交给 REPL 之前,进程从任何正常路径退出(main 返回错误、std.process.exit)
// 都要把终端还原:否则 shell 接手一个不回显的终端。被信号杀掉时由 shell 复原它保存的模式。
var g_exit_restore: ?struct { fd: c_int, saved: SavedMode } = null;
var g_exit_hooked = false;
extern "c" fn atexit(func: *const fn () callconv(.c) void) c_int;

/// Restore `saved` on `fd` when the process exits, unless cancelled first.
/// POSIX only (it pairs with enterQuiet).
pub fn restoreAtExit(fd: c_int, saved: SavedMode) void {
    if (is_windows) return;
    g_exit_restore = .{ .fd = fd, .saved = saved };
    if (!g_exit_hooked) g_exit_hooked = atexit(&restoreOnExit) == 0;
}

/// The mode passed to restoreAtExit is someone else's to restore now.
pub fn cancelRestoreAtExit() void {
    g_exit_restore = null;
}

fn restoreOnExit() callconv(.c) void {
    if (g_exit_restore) |r| restoreModeWith(r.fd, r.saved, .keep);
}

fn tcsaction(pending: PendingInput) @TypeOf(std.posix.TCSA.FLUSH) {
    return switch (pending) {
        .discard => std.posix.TCSA.FLUSH,
        .keep => std.posix.TCSA.NOW,
    };
}

/// 复原终端模式。POSIX 切换时丢掉终端已收、未读的输入(TCSAFLUSH)。
pub fn restoreMode(fd: c_int, saved: SavedMode) void {
    restoreModeWith(fd, saved, .discard);
}

fn restoreModeWith(fd: c_int, saved: SavedMode, pending: PendingInput) void {
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
        const discards = pending == .discard and hasQueuedInput(fd);
        if (std.c.tcsetattr(fd, tcsaction(pending), &saved) == 0 and discards) _ = g_discards.fetchAdd(1, .acq_rel);
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
/// Windows 上同时关掉 VT 输入:shell 交给程序的控制台不带它,编辑器按 shell 下的样子读键。
pub fn setCooked(fd: c_int) void {
    if (is_windows) {
        const hin = GetStdHandle(STD_INPUT_HANDLE);
        var m: win.DWORD = 0;
        if (GetConsoleMode(hin, &m) == 0) return;
        _ = SetConsoleMode(hin, (m | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT) & ~ENABLE_VIRTUAL_TERMINAL_INPUT);
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

test "discardPendingInput drops readable bytes and never waits" {
    if (is_windows) return;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try std.testing.expectEqual(@as(isize, 5), std.c.write(fds[1], "hello", 5));
    try std.testing.expect(waitReadable(fds[0], 0) > 0);
    const before = discardCount();
    discardPendingInput(fds[0]);
    try std.testing.expectEqual(@as(i32, 0), waitReadable(fds[0], 0));
    try std.testing.expectEqual(before + 1, discardCount());
    // Nothing pending: it returns at once instead of blocking on the read end,
    // and threw nothing away.
    discardPendingInput(fds[0]);
    try std.testing.expectEqual(@as(i32, 0), waitReadable(fds[0], 0));
    try std.testing.expectEqual(before + 1, discardCount());
}

fn resetReplayForTesting() void {
    g_replay_fd = -1;
    g_replay_len = 0;
    g_replay_pos = 0;
}

test "replayInput: owed bytes come first, in order, survive a discard and only for their fd" {
    if (is_windows) return;
    defer resetReplayForTesting();
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try std.testing.expectEqual(@as(usize, 3), replayInput(fds[0], "ab\x1b"));
    // Readable without waiting, though the terminal sent nothing.
    try std.testing.expectEqual(@as(i32, 1), waitReadable(fds[0], 0));
    // Another descriptor is not owed them.
    try std.testing.expectEqual(@as(i32, 0), waitReadable(fds[1], 0));

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), readInput(fds[0], buf[0..1]));
    try std.testing.expectEqual(@as(u8, 'a'), buf[0]);
    // More owed later goes after what is still owed.
    _ = replayInput(fds[0], "[A");
    // A discard drops what the terminal has pending, not what is owed.
    try std.testing.expectEqual(@as(isize, 3), std.c.write(fds[1], "zzz", 3));
    discardPendingInput(fds[0]);
    try std.testing.expectEqual(@as(isize, 4), readInput(fds[0], &buf));
    try std.testing.expectEqualStrings("b\x1b[A", buf[0..4]);

    // Paid off: the terminal is read again.
    try std.testing.expectEqual(@as(i32, 0), waitReadable(fds[0], 0));
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "c", 1));
    try std.testing.expectEqual(@as(isize, 1), readInput(fds[0], &buf));
    try std.testing.expectEqual(@as(u8, 'c'), buf[0]);
}

test "dropSilentInput: a key-down without a character types nothing, whatever the key" {
    // Modifiers, locks, Pause, Apps, a dead key: no character.
    for ([_]u16{ 0x10, 0x11, 0xA0, 0x5B, 0x14, 0x13, 0x5D, 0xDE }) |vk|
        try std.testing.expect(typesNothing(.{ .bKeyDown = 1, .wRepeatCount = 1, .wVirtualKeyCode = vk, .wVirtualScanCode = 0, .uChar = .{ .UnicodeChar = 0 }, .dwControlKeyState = 0 }));
    // A letter, Enter, Esc, and VT input's synthesized keys (no virtual key).
    for ([_][2]u16{ .{ 0x41, 'a' }, .{ 0x0D, '\r' }, .{ 0x1B, 0x1b }, .{ 0, '[' } }) |kc|
        try std.testing.expect(!typesNothing(.{ .bKeyDown = 1, .wRepeatCount = 1, .wVirtualKeyCode = kc[0], .wVirtualScanCode = 0, .uChar = .{ .UnicodeChar = kc[1] }, .dwControlKeyState = 0 }));
    if (is_windows) return;
    // POSIX: a pending byte is input and stays.
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    dropSilentInput(fds[0]);
    try std.testing.expect(waitReadable(fds[0], 0) > 0);
}

test "console_reflows: conhost clips on Windows; elsewhere the terminal emulator decides" {
    if (is_windows) {
        try std.testing.expectEqual(@as(?bool, false), console_reflows);
    } else {
        try std.testing.expectEqual(@as(?bool, null), console_reflows);
    }
}
