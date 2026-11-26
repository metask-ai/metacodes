//! 测试专用夹具:文件系统链接、目录枚举断言、虚拟时钟与私有控制台。只从 `test` 块 `@import`,生产代码不得引用。
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
//! - `PrivateConsole`:Windows 上测试自己的控制台(伪控制台 + 一个不读输入的子进程)。造出来的键盘
//!   记录走真实的 `terminal.readInput` / `waitReadable`,不受 ConPTY 管道时序影响。

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

/// Windows:测试自己的控制台——没有窗口,也没有别的进程在读它的输入——`begin` 到 `end` 之间是本进程的
/// 标准输入。`send` 写进去的键盘记录走真实的 `terminal.readInput` / `waitReadable`,和 conhost 排进
/// 队列的人的按键一样,却不经过 ConPTY 管道那一层的时序:同批、分两次、只剩抬键,测试想造哪种就是哪种。
/// 实现:一个伪控制台,里面跑一个不读输入的 `ping` 让它有客户端,本进程 `AttachConsole` 上去。
/// 非 Windows 跳过;本进程 stdout/stderr 是控制台时也跳过(`FreeConsole` 会让它们失效)。
/// 用它的测试要在编译期跳过别的平台(`if (builtin.os.tag != .windows) return error.SkipZigTest;`):
/// `begin` 只在运行时报跳过,编译器照样分析后面的调用。各方法在别的平台上直接返回、不碰 Windows
/// API,所以引用它们的代码也能编译。
pub const PrivateConsole = struct {
    hpc: HPCON,
    child: win.HANDLE,
    child_thread: win.HANDLE,
    in_write: win.HANDLE,
    out_read: win.HANDLE,
    conin: win.HANDLE,
    saved: [3]win.HANDLE,
    reattach: bool,

    /// 一条输入记录:某个字符的键按下 / 抬起,或一次焦点变化(和抬键一样不产字节)。
    pub const Event = union(enum) { down: u8, up: u8, focus };

    pub fn begin() !PrivateConsole {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var mode: win.DWORD = 0;
        if (GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0 or GetConsoleMode(GetStdHandle(STD_ERROR_HANDLE), &mode) != 0) return error.SkipZigTest;

        var in_read: win.HANDLE = undefined;
        var in_write: win.HANDLE = undefined;
        var out_read: win.HANDLE = undefined;
        var out_write: win.HANDLE = undefined;
        if (CreatePipe(&in_read, &in_write, null, 0) == 0) return error.PrivateConsoleFailed;
        if (CreatePipe(&out_read, &out_write, null, 0) == 0) {
            closeAll(&.{ in_read, in_write });
            return error.PrivateConsoleFailed;
        }
        var hpc: HPCON = undefined;
        const created = CreatePseudoConsole(.{ .X = 80, .Y = 25 }, in_read, out_write, 0, &hpc);
        // 伪控制台复制了自己要的两端。
        closeAll(&.{ in_read, out_write });
        if (created < 0) {
            closeAll(&.{ in_write, out_read });
            return error.PrivateConsoleFailed;
        }
        errdefer {
            closeAll(&.{ out_read, in_write });
            ClosePseudoConsole(hpc);
        }

        var attribute_size: win.SIZE_T = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
        const storage = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(usize)), attribute_size);
        defer std.heap.page_allocator.free(storage);
        const attribute_list: *anyopaque = @ptrCast(storage.ptr);
        if (InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_size) == .FALSE) return error.PrivateConsoleFailed;
        defer DeleteProcThreadAttributeList(attribute_list);
        if (UpdateProcThreadAttribute(attribute_list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == .FALSE) return error.PrivateConsoleFailed;
        var startup: StartupInfoEx = .{ .startup_info = std.mem.zeroes(win.STARTUPINFOW), .attribute_list = attribute_list };
        startup.startup_info.cb = @sizeOf(StartupInfoEx);
        // 不设的话子进程会拿到本进程重定向过的 stdout(zig build 的协议管道),而不是伪控制台。
        startup.startup_info.dwFlags = STARTF_USESTDHANDLES;
        startup.startup_info.hStdInput = win.INVALID_HANDLE_VALUE;
        startup.startup_info.hStdOutput = win.INVALID_HANDLE_VALUE;
        startup.startup_info.hStdError = win.INVALID_HANDLE_VALUE;
        var cmdline = std.unicode.utf8ToUtf16LeStringLiteral("ping.exe -n 120 127.0.0.1").*;
        var pi: win.PROCESS.INFORMATION = undefined;
        if (win.kernel32.CreateProcessW(null, &cmdline, null, null, @enumFromInt(0), .{ .extended_startupinfo_present = true }, null, null, @ptrCast(&startup), &pi) == .FALSE) return error.PrivateConsoleFailed;
        errdefer {
            _ = TerminateProcess(pi.hProcess, 0);
            _ = WaitForSingleObject(pi.hProcess, 5000);
            closeAll(&.{ pi.hProcess, pi.hThread });
        }

        const saved = [3]win.HANDLE{ GetStdHandle(STD_INPUT_HANDLE), GetStdHandle(STD_OUTPUT_HANDLE), GetStdHandle(STD_ERROR_HANDLE) };
        const reattach = GetConsoleWindow() != null;
        _ = FreeConsole();
        errdefer restoreConsole(saved, reattach);
        // 子进程启动时才连上控制台;连上之前 AttachConsole 失败。
        var attached = false;
        for (0..500) |_| {
            if (AttachConsole(pi.dwProcessId) != 0) {
                attached = true;
                break;
            }
            Sleep(10);
        }
        if (!attached) return error.PrivateConsoleFailed;
        const conin = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        if (conin == win.INVALID_HANDLE_VALUE) return error.PrivateConsoleFailed;
        // `terminal.enterRaw` 的输入模式:不按行、不回显、不处理 Ctrl+C,VT 输入。
        if (GetConsoleMode(conin, &mode) == 0 or SetConsoleMode(conin, (mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) | ENABLE_VIRTUAL_TERMINAL_INPUT) == 0) {
            closeAll(&.{conin});
            return error.PrivateConsoleFailed;
        }
        _ = SetStdHandle(STD_INPUT_HANDLE, conin);
        terminal.discardPendingInput(0);
        return .{ .hpc = hpc, .child = pi.hProcess, .child_thread = pi.hThread, .in_write = in_write, .out_read = out_read, .conin = conin, .saved = saved, .reattach = reattach };
    }

    pub fn end(self: *PrivateConsole) void {
        if (builtin.os.tag != .windows) return;
        // readInput 的缓冲是进程级的:别留给后面的测试。
        terminal.discardPendingInput(0);
        closeAll(&.{self.conin});
        restoreConsole(self.saved, self.reattach);
        _ = TerminateProcess(self.child, 0);
        _ = WaitForSingleObject(self.child, 5000);
        // 先关输出端:ClosePseudoConsole 可能等最后一帧被读走。
        closeAll(&.{ self.child, self.child_thread, self.out_read, self.in_write });
        ClosePseudoConsole(self.hpc);
    }

    /// 把 `events` 一次排进输入队列。
    pub fn send(self: *const PrivateConsole, events: []const Event) !void {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var records: [16]INPUT_RECORD = undefined;
        for (events, records[0..events.len]) |e, *r| r.* = switch (e) {
            .down, .up => |c| .{ .EventType = KEY_EVENT, .Event = .{ .KeyEvent = .{
                .bKeyDown = @intFromBool(e == .down),
                .wRepeatCount = 1,
                .wVirtualKeyCode = std.ascii.toUpper(c),
                .wVirtualScanCode = switch (c) {
                    0x1b => 0x01,
                    '\r' => 0x1c,
                    else => 0,
                },
                .UnicodeChar = c,
                .dwControlKeyState = 0,
            } } },
            .focus => .{ .EventType = FOCUS_EVENT, .Event = .{ .FocusEvent = .{ .bSetFocus = 1 } } },
        };
        var written: win.DWORD = 0;
        if (WriteConsoleInputW(self.conin, &records, @intCast(events.len), &written) == 0 or written != events.len) return error.PrivateConsoleFailed;
    }

    /// `text` 的每个字符各排一条按下记录:开着 win32-input-mode 时控制台就是这样把一条按键记录
    /// `ESC [ Vk;Sc;Uc;Kd;Cs;Rc _` 排进输入队列的(一个字符一个事件,实测)。
    pub fn sendChars(self: *const PrivateConsole, text: []const u8) !void {
        var rest = text;
        while (rest.len > 0) {
            const n = @min(rest.len, 16);
            var events: [16]Event = undefined;
            for (rest[0..n], events[0..n]) |c, *e| e.* = .{ .down = c };
            try self.send(events[0..n]);
            rest = rest[n..];
        }
    }

    /// 队列里还有几条按键按下的记录(只看不取)。
    pub fn keyDownsQueued(self: *const PrivateConsole) usize {
        if (builtin.os.tag != .windows) return 0;
        var records: [64]INPUT_RECORD = undefined;
        var got: win.DWORD = 0;
        if (PeekConsoleInputW(self.conin, &records, records.len, &got) == 0) return 0;
        var n: usize = 0;
        for (records[0..got]) |r| {
            if (r.EventType == KEY_EVENT and r.Event.KeyEvent.bKeyDown != 0) n += 1;
        }
        return n;
    }

    fn restoreConsole(saved: [3]win.HANDLE, reattach: bool) void {
        _ = FreeConsole();
        if (reattach) _ = AttachConsole(ATTACH_PARENT_PROCESS);
        for ([_]win.DWORD{ STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE }, saved) |which, h| {
            _ = SetStdHandle(which, h);
        }
    }

    fn closeAll(handles: []const win.HANDLE) void {
        for (handles) |h| win.CloseHandle(h);
    }

    const terminal = @import("terminal.zig");
    const win = std.os.windows;
    const HPCON = *anyopaque;
    const StartupInfoEx = extern struct { startup_info: win.STARTUPINFOW, attribute_list: ?*anyopaque };
    const KEY_EVENT: u16 = 0x0001;
    const FOCUS_EVENT: u16 = 0x0010;
    const INPUT_RECORD = extern struct {
        EventType: u16,
        Event: extern union {
            KeyEvent: extern struct {
                bKeyDown: c_int,
                wRepeatCount: u16,
                wVirtualKeyCode: u16,
                wVirtualScanCode: u16,
                UnicodeChar: u16,
                dwControlKeyState: win.DWORD,
            },
            FocusEvent: extern struct { bSetFocus: c_int },
            raw: [16]u8,
        },
    };
    const STD_INPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: win.DWORD = @bitCast(@as(i32, -12));
    const ATTACH_PARENT_PROCESS: win.DWORD = 0xFFFF_FFFF;
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: win.DWORD_PTR = 0x0002_0016;
    const STARTF_USESTDHANDLES: win.DWORD = 0x0000_0100;
    const GENERIC_READ: win.DWORD = 0x8000_0000;
    const GENERIC_WRITE: win.DWORD = 0x4000_0000;
    const FILE_SHARE_READ: win.DWORD = 0x1;
    const FILE_SHARE_WRITE: win.DWORD = 0x2;
    const OPEN_EXISTING: win.DWORD = 3;
    const ENABLE_PROCESSED_INPUT: win.DWORD = 0x0001;
    const ENABLE_LINE_INPUT: win.DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: win.DWORD = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: win.DWORD = 0x0200;

    extern "kernel32" fn CreatePipe(hReadPipe: *win.HANDLE, hWritePipe: *win.HANDLE, lpPipeAttributes: ?*win.SECURITY_ATTRIBUTES, nSize: win.DWORD) callconv(.winapi) c_int;
    extern "kernel32" fn CreatePseudoConsole(size: win.COORD, hInput: win.HANDLE, hOutput: win.HANDLE, dwFlags: win.DWORD, phPC: *HPCON) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: win.DWORD, dwFlags: win.DWORD, lpSize: *win.SIZE_T) callconv(.winapi) win.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: win.DWORD, attribute: win.DWORD_PTR, lpValue: *const anyopaque, cbSize: win.SIZE_T, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*win.SIZE_T) callconv(.winapi) win.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn TerminateProcess(hProcess: win.HANDLE, uExitCode: win.UINT) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(hHandle: win.HANDLE, dwMilliseconds: win.DWORD) callconv(.winapi) win.DWORD;
    extern "kernel32" fn Sleep(dwMilliseconds: win.DWORD) callconv(.winapi) void;
    extern "kernel32" fn FreeConsole() callconv(.winapi) c_int;
    extern "kernel32" fn AttachConsole(dwProcessId: win.DWORD) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn SetStdHandle(nStdHandle: win.DWORD, hHandle: win.HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: win.HANDLE, lpMode: *win.DWORD) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: win.HANDLE, dwMode: win.DWORD) callconv(.winapi) c_int;
    extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: win.DWORD, dwShareMode: win.DWORD, lpSecurityAttributes: ?*win.SECURITY_ATTRIBUTES, dwCreationDisposition: win.DWORD, dwFlagsAndAttributes: win.DWORD, hTemplateFile: ?win.HANDLE) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn WriteConsoleInputW(hConsoleInput: win.HANDLE, lpBuffer: [*]const INPUT_RECORD, nLength: win.DWORD, lpNumberOfEventsWritten: *win.DWORD) callconv(.winapi) c_int;
    extern "kernel32" fn PeekConsoleInputW(hConsoleInput: win.HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: win.DWORD, lpNumberOfEventsRead: *win.DWORD) callconv(.winapi) c_int;
};
