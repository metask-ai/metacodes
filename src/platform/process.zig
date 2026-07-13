//! W3 可移植子进程 spawn+capture（跨平台移植 roadmap，tinykg node 8867/8868）。
//!
//! 现状病灶：8 个 fork+execve 站点（common×2/auth/job_registry/input/mcp/lsp/hooks）。Windows
//! 无 fork/exec/waitpid/killpg。本模块提供中立 `captureStdout`（spawn 命令、抽干 stdout、超时/
//! 进程组 kill、返 exit code），首版覆盖 common.zig 的 stdout-capture 家族（最常用路径）。
//!
//! - **POSIX**：fork + pipe + dup2 + execve；poll 抽干带超时+字节上限；waitpid；超时 killpg 整组。
//! - **Windows**：CreateProcessW + CreatePipe（stdout）+ **reader 线程抽干**（避免 pipe 满死锁）；
//!   WaitForSingleObject 超时；GetExitCodeProcess；超时 TerminateProcess。git-bash 依赖见 roadmap。
//!
//! 未覆盖（后续增量，CI 验证）：stderr 双捕获、abort 回调、tick 进度、双向 pipe（MCP/LSP）、
//! 落盘重定向（job_registry bg）、JobObject 进程树 kill（当前 Windows 单进程 Terminate）。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const CaptureResult = struct {
    stdout: []u8, // owned by调用方 allocator
    exit_code: i32, // 被信号/超时终止时为负或 259(Windows STILL_ACTIVE→terminated)
    timed_out: bool = false,
};

pub const CaptureError = error{
    SpawnFailed,
    PipeFailed,
    ReadError,
    OutOfMemory,
};

/// spawn argv、抽干 stdout（stderr 丢弃），返回 stdout + exit code。
/// `timeout_ms==0` 无超时；>0 超时则 kill 整组（POSIX killpg / Windows Terminate）并置 timed_out。
/// `max_bytes` stdout 上限（轴A OOM 防线），达上限 kill 并返已读部分。
pub fn captureStdout(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    timeout_ms: u64,
    max_bytes: usize,
) CaptureError!CaptureResult {
    if (is_windows) return captureStdoutWindows(argv, allocator, timeout_ms, max_bytes);
    return captureStdoutPosix(argv, allocator, timeout_ms, max_bytes);
}

// ============================================================================
// POSIX backend
// ============================================================================

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn posixExitCode(status: c_int) i32 {
    if ((status & 0x7f) == 0) return @as(i32, @intCast((status >> 8) & 0xff));
    return -@as(i32, @intCast(status & 0x7f));
}

fn killGroupPosix(pgid: std.c.pid_t) void {
    _ = std.c.kill(-pgid, std.c.SIG.TERM);
    const req = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
    _ = std.c.kill(-pgid, std.c.SIG.KILL);
}

fn captureStdoutPosix(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    timeout_ms: u64,
    max_bytes: usize,
) CaptureError!CaptureResult {
    var pipefd: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipefd) != 0) return error.PipeFailed;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipefd[0]);
        _ = std.c.close(pipefd[1]);
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(pipefd[0]);
        _ = std.c.dup2(pipefd[1], 1);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 2);
            if (devnull != 2) _ = std.c.close(devnull);
        }
        _ = std.c.close(pipefd[1]);
        const argv0 = argv[0] orelse std.c._exit(127);
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), &.{null});
        std.c._exit(127);
    }

    _ = std.c.close(pipefd[1]);
    _ = std.c.setpgid(pid, pid);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    const start = nowMs();
    var timed_out = false;
    var done = false;
    while (!done) {
        if (timeout_ms > 0 and nowMs() - start >= @as(i64, @intCast(timeout_ms))) {
            killGroupPosix(pid);
            timed_out = true;
            break;
        }
        var pfds = [_]std.c.pollfd{.{ .fd = pipefd[0], .events = std.c.POLL.IN, .revents = 0 }};
        const rc = std.c.poll(&pfds, 1, 100);
        if (rc < 0) {
            _ = std.c.close(pipefd[0]);
            return error.ReadError;
        }
        if (rc == 0) continue;
        const n = std.c.read(pipefd[0], &buf, buf.len);
        if (n <= 0) {
            done = true;
        } else {
            const un: usize = @intCast(n);
            try out.appendSlice(allocator, buf[0..un]);
            if (out.items.len >= max_bytes) {
                killGroupPosix(pid);
                timed_out = true; // 用 timed_out 兼指"被截断 kill"
                break;
            }
        }
    }
    _ = std.c.close(pipefd[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const owned = try out.toOwnedSlice(allocator);
    return .{ .stdout = owned, .exit_code = posixExitCode(status), .timed_out = timed_out };
}

// ============================================================================
// Windows backend
// ============================================================================

const win = std.os.windows;

const HANDLE_FLAG_INHERIT: win.DWORD = 0x00000001;
const INFINITE: win.DWORD = 0xFFFFFFFF;
const WAIT_OBJECT_0: win.DWORD = 0;
const WAIT_TIMEOUT_: win.DWORD = 0x00000102;

extern "kernel32" fn CreatePipe(
    hReadPipe: *win.HANDLE,
    hWritePipe: *win.HANDLE,
    lpPipeAttributes: ?*win.SECURITY_ATTRIBUTES,
    nSize: win.DWORD,
) callconv(.winapi) c_int;
extern "kernel32" fn SetHandleInformation(hObject: win.HANDLE, dwMask: win.DWORD, dwFlags: win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(hFile: win.HANDLE, lpBuffer: [*]u8, nToRead: win.DWORD, lpRead: *win.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: win.HANDLE, dwMilliseconds: win.DWORD) callconv(.winapi) win.DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: win.HANDLE, lpExitCode: *win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn TerminateProcess(hProcess: win.HANDLE, uExitCode: win.UINT) callconv(.winapi) c_int;

/// reader 线程上下文：从 pipe 抽干到 list（避免 pipe 满死锁）。
const WinReader = struct {
    handle: win.HANDLE,
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    max_bytes: usize,
    oom: bool = false,

    fn run(self: *WinReader) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            var read_n: win.DWORD = 0;
            const ok = ReadFile(self.handle, &buf, buf.len, &read_n, null);
            if (ok == 0 or read_n == 0) break; // EOF 或写端关闭(ERROR_BROKEN_PIPE)
            self.list.appendSlice(self.allocator, buf[0..read_n]) catch {
                self.oom = true;
                break;
            };
            if (self.list.items.len >= self.max_bytes) break;
        }
    }
};

fn captureStdoutWindows(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    timeout_ms: u64,
    max_bytes: usize,
) CaptureError!CaptureResult {
    // 1) stdout pipe（写端可继承，读端不可继承）
    var sa = win.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = @enumFromInt(1),
    };
    var rd: win.HANDLE = undefined;
    var wr: win.HANDLE = undefined;
    if (CreatePipe(&rd, &wr, &sa, 0) == 0) return error.PipeFailed;
    if (SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0) == 0) {
        win.CloseHandle(rd);
        win.CloseHandle(wr);
        return error.PipeFailed;
    }

    // 2) 命令行 UTF-16（Windows 用单一 lpCommandLine，非 argv 数组）
    const cmdline = buildWindowsCmdline(allocator, argv) catch return error.SpawnFailed;
    defer allocator.free(cmdline);

    var si = std.mem.zeroes(win.STARTUPINFOW);
    si.cb = @sizeOf(win.STARTUPINFOW);
    si.dwFlags = win.STARTF_USESTDHANDLES;
    si.hStdOutput = wr;
    si.hStdError = wr; // stderr 也进同一 pipe（首版：stderr 不单独捕获，混入 stdout）
    si.hStdInput = null;

    var pi = std.mem.zeroes(win.PROCESS.INFORMATION);

    const created = win.kernel32.CreateProcessW(
        null,
        cmdline.ptr,
        null,
        null,
        @enumFromInt(1), // bInheritHandles=TRUE
        .{}, // CreateProcessFlags 默认
        null,
        null,
        &si,
        &pi,
    );
    win.CloseHandle(wr); // 父端关写端：reader 才能在子进程结束后收到 EOF
    if (created == .FALSE) {
        win.CloseHandle(rd);
        return error.SpawnFailed;
    }

    // 3) reader 线程抽干 stdout
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var reader = WinReader{ .handle = rd, .list = &out, .allocator = allocator, .max_bytes = max_bytes };
    const rthread = std.Thread.spawn(.{}, WinReader.run, .{&reader}) catch {
        win.CloseHandle(rd);
        win.CloseHandle(pi.hProcess);
        win.CloseHandle(pi.hThread);
        return error.SpawnFailed;
    };

    // 4) 等进程（超时则 Terminate）
    const wait_ms: win.DWORD = if (timeout_ms == 0) INFINITE else @intCast(@min(timeout_ms, @as(u64, INFINITE - 1)));
    const w = WaitForSingleObject(pi.hProcess, wait_ms);
    var timed_out = false;
    if (w == WAIT_TIMEOUT_) {
        _ = TerminateProcess(pi.hProcess, 1);
        timed_out = true;
    }

    rthread.join(); // reader 在写端全关后收 EOF 退出
    win.CloseHandle(rd);

    var code: win.DWORD = 0;
    _ = GetExitCodeProcess(pi.hProcess, &code);
    win.CloseHandle(pi.hProcess);
    win.CloseHandle(pi.hThread);

    if (reader.oom) return error.OutOfMemory;
    const owned = try out.toOwnedSlice(allocator);
    return .{ .stdout = owned, .exit_code = @bitCast(code), .timed_out = timed_out };
}

/// argv(UTF-8 C 串) → Windows 命令行 UTF-16(带标准 quoting)。
fn buildWindowsCmdline(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8) ![:0]u16 {
    var u8buf = std.ArrayList(u8).empty;
    defer u8buf.deinit(allocator);
    var first = true;
    for (argv) |a_opt| {
        const a = a_opt orelse break;
        const arg = std.mem.span(a);
        if (!first) try u8buf.append(allocator, ' ');
        first = false;
        try appendQuotedArg(allocator, &u8buf, arg);
    }
    return try std.unicode.utf8ToUtf16LeAllocZ(allocator, u8buf.items);
}

/// Windows 命令行参数 quoting（CommandLineToArgvW 的逆）：含空格/tab/引号则加双引号并转义。
fn appendQuotedArg(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), arg: []const u8) !void {
    const needs_quote = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") != null;
    if (!needs_quote) {
        try buf.appendSlice(allocator, arg);
        return;
    }
    try buf.append(allocator, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
        } else if (c == '"') {
            try buf.appendNTimes(allocator, '\\', backslashes * 2 + 1);
            try buf.append(allocator, '"');
            backslashes = 0;
        } else {
            try buf.appendNTimes(allocator, '\\', backslashes);
            try buf.append(allocator, c);
            backslashes = 0;
        }
    }
    try buf.appendNTimes(allocator, '\\', backslashes * 2);
    try buf.append(allocator, '"');
}

// ============================================================================
// Tests（POSIX + Windows CI 真跑：spawn 命令、验捕获输出与 exit code）
// ============================================================================

test "captureStdout spawn echo 捕获输出" {
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo hello-platform", null }
    else
        &.{ "/bin/sh", "-c", "echo hello-platform", null };
    const r = try captureStdout(argv, a, 10_000, 1 << 20);
    defer a.free(r.stdout);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hello-platform") != null);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
    try std.testing.expect(!r.timed_out);
}

test "captureStdout 非零 exit code" {
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "exit 3", null }
    else
        &.{ "/bin/sh", "-c", "exit 3", null };
    const r = try captureStdout(argv, a, 10_000, 1 << 20);
    defer a.free(r.stdout);
    try std.testing.expectEqual(@as(i32, 3), r.exit_code);
}

test "buildWindowsCmdline quoting" {
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = &.{ "prog", "a b", "c\"d", null };
    const w = try buildWindowsCmdline(a, argv);
    defer a.free(w);
    const u8out = try std.unicode.utf16LeToUtf8Alloc(a, w);
    defer a.free(u8out);
    // prog "a b" "c\"d"
    try std.testing.expectEqualStrings("prog \"a b\" \"c\\\"d\"", u8out);
}
