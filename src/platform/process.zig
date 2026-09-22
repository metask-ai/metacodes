//! W3 可移植子进程 spawn+capture（跨平台移植 roadmap，tinykg node 8867/8868）。
//!
//! 现状病灶：8 个 fork+execve 站点（common×2/auth/job_registry/input/mcp/lsp/hooks）。Windows
//! 无 fork/exec/waitpid/killpg。本模块提供中立 `capture`（spawn 命令、抽干 stdout[+stderr]、
//! 超时/进程组 kill/abort、tick 进度、返 exit code），覆盖 common.zig 的 spawn-capture 家族。
//!
//! - **POSIX**：fork + pipe + dup2 + execve；poll 抽干双 fd 带超时+abort+字节上限；waitpid；kill killpg 整组。
//! - **Windows**：CreateProcessW + CreatePipe + **reader 线程/fd 抽干**（避 pipe 满死锁）；
//!   WaitForSingleObject 分片轮询超时+abort；GetExitCodeProcess；kill TerminateProcess。
//!
//! **解耦**：abort/tick 走 opaque 回调（`?*const anyopaque` + fn 指针），platform/ 不依赖
//! util/abort。调用方（common.zig）把自己的 AbortSignal 包成回调传入。
//!
//! 未覆盖（后续增量）：双向 pipe（MCP/LSP 长连接）、JobObject 进程树 kill。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const psync = @import("sync.zig");

// Windows spawn 串行锁。bInheritHandles=TRUE 的 CreateProcessW 会把**并发线程**同窗口期
// 创建的全部可继承句柄(别人的管道写端/落盘句柄)一并塞给本次子进程。长命子进程(MCP
// server、bg job、teammate)握着别人 stdout 管道的写端 → 那条 capture 的 ReadFile 永不
// EOF → reader join 永挂(全套件多线程 spawn 实测挂死,agent/swarm/skill-fork 组必现)。
// 临界区 = 创建可继承句柄 → CreateProcessW → 关父端可继承副本;锁外做 stdin 写/等待/读。
// 正解是 PROC_THREAD_ATTRIBUTE_HANDLE_LIST 白名单(roadmap);串行化是小而正确的第一刀。
var g_spawn_serial: psync.Mutex = .{};

pub const CaptureError = error{ SpawnFailed, PipeFailed, ReadError, OutOfMemory, Aborted, Timeout, ChildChdirFailed, ChildExecFailed };

/// The step at which a child gave up before it ran anything of the caller's.
pub const SpawnStep = enum(u8) {
    /// `chdir` into the requested working directory refused (POSIX), or
    /// `CreateProcessW` rejected `lpCurrentDirectory` (Windows).
    chdir = 1,
    /// `execve` refused the program (POSIX), or `CreateProcessW` could not
    /// start it (Windows).
    exec = 2,
};

/// A child's own account of why it never started.
///
/// POSIX: between fork and exec the child writes this record to a
/// close-on-exec pipe and `_exit`s; a parent that reads EOF instead knows the
/// exec succeeded. Windows: derived from `GetLastError` after `CreateProcessW`
/// refused. Before this channel existed every pre-exec failure looked exactly
/// like the command itself exiting 127 with nothing on either stream — a
/// renamed working directory and a missing shell were indistinguishable from
/// a typo, and a model given that signal retries until its turn budget is gone.
pub const SpawnFailure = struct {
    step: SpawnStep,
    /// errno on POSIX; the Win32 error code on Windows.
    code: i32,

    /// The path named nothing: POSIX `ENOENT`, Win32 `ERROR_FILE_NOT_FOUND` /
    /// `ERROR_PATH_NOT_FOUND` / `ERROR_DIRECTORY`. Only this reading licenses a
    /// "renamed or removed" diagnosis; `EACCES`, `ENOTDIR`, `ENAMETOOLONG` are
    /// different stories and are reported as what they are.
    pub fn isNotFound(self: SpawnFailure) bool {
        if (is_windows) {
            return self.code == ERROR_FILE_NOT_FOUND or self.code == ERROR_PATH_NOT_FOUND or self.code == ERROR_DIRECTORY;
        } else {
            return self.code == @intFromEnum(std.c.E.NOENT);
        }
    }

    /// Symbolic form for diagnostics: "ENOENT" on POSIX, "Win32 error 267" on Windows.
    pub fn describeCode(self: SpawnFailure, buf: []u8) []const u8 {
        if (is_windows) {
            return std.fmt.bufPrint(buf, "Win32 error {d}", .{self.code}) catch "?";
        } else {
            if (std.enums.fromInt(std.c.E, self.code)) |e| {
                if (std.enums.tagName(std.c.E, e)) |name| {
                    return std.fmt.bufPrint(buf, "E{s}", .{name}) catch "?";
                }
            }
            return std.fmt.bufPrint(buf, "errno {d}", .{self.code}) catch "?";
        }
    }
};

/// The most recent spawn on this thread that returned `ChildChdirFailed` or
/// `ChildExecFailed`; every spawn entry point clears it first, and
/// `takeLastSpawnFailure` clears it on read. Thread-local for the reason errno
/// is: the failing call and its reader share a thread, and the primitives keep
/// their signatures.
threadlocal var last_spawn_failure: ?SpawnFailure = null;

pub fn takeLastSpawnFailure() ?SpawnFailure {
    const failure = last_spawn_failure;
    last_spawn_failure = null;
    return failure;
}

fn spawnFailureError(failure: SpawnFailure) CaptureError {
    last_spawn_failure = failure;
    return switch (failure.step) {
        .chdir => error.ChildChdirFailed,
        .exec => error.ChildExecFailed,
    };
}

/// abort 轮询回调：返 true=应中止。tick 回调：周期报告 elapsed_ms + 命令 label。
pub const CaptureOpts = struct {
    timeout_ms: u64 = 0,
    max_bytes: usize = 16 << 20,
    /// false → 子进程 stderr 丢弃（→/dev/null / NUL），结果 stderr 为空。
    want_stderr: bool = true,
    /// true → 超时时返回**已读部分输出**（Ok，timed_out=true，进程已 kill）而非 error.Timeout。
    /// 安全语义场景用（如 permission hook：慢但已产出 block 决策的 hook 超时也要保留其部分输出判决，
    /// 否则 fail-open 漏判）。默认 false（超时=error.Timeout，丢弃输出）。
    timeout_partial: bool = false,
    /// 非 null → 喂给子进程 stdin 后关闭（发 EOF）。**仅适合小数据**（≤ pipe 缓冲，如 hook JSON）：
    /// 首版在 drain 前一次性写完，大 stdin 会与子进程大 stdout 互阻死锁。
    stdin_data: ?[]const u8 = null,
    /// true → 子进程继承父进程环境变量（POSIX environ / Windows 默认继承）；false → POSIX 空环境
    /// （工具用绝对路径，硬化），Windows 始终继承（CreateProcessW lpEnvironment=null）。
    inherit_env: bool = false,
    abort_ctx: ?*const anyopaque = null,
    abort_poll: ?*const fn (?*const anyopaque) bool = null,
    tick_ctx: ?*const anyopaque = null,
    tick_cb: ?*const fn (?*const anyopaque, elapsed_ms: u64, label: []const u8) void = null,
    /// 非 null → 子进程在 spawn 时 chdir 到此目录(仅影响子进程,父进程 cwd 不变)。
    /// null → 继承父进程 cwd。借用切片,spawn 时消费,不持有。
    cwd: ?[]const u8 = null,
};

pub const Captured = struct {
    stdout: []u8, // owned
    stderr: []u8, // owned（want_stderr=false 时为空 slice）
    exit_code: i32,
    timed_out: bool = false, // 仅 timeout_partial=true 时有意义：超时被 kill 但返了部分输出。
    capture_complete: bool = true,
    // 超时(非 timeout_partial) → error.Timeout；abort → error.Aborted；cap 命中 → Ok（返部分，进程已 kill）。
};

/// spawn argv、抽干 stdout[+stderr]、返回结果。timeout_ms==0 无超时。
pub fn capture(argv: []const ?[*:0]const u8, allocator: std.mem.Allocator, opts: CaptureOpts) CaptureError!Captured {
    last_spawn_failure = null;
    if (is_windows) return captureWindows(argv, allocator, opts);
    return capturePosix(argv, allocator, opts);
}

/// 便捷：只捕 stdout（stderr 丢弃），无 abort/tick。
pub fn captureStdout(argv: []const ?[*:0]const u8, allocator: std.mem.Allocator, timeout_ms: u64, max_bytes: usize) CaptureError!Captured {
    return capture(argv, allocator, .{ .timeout_ms = timeout_ms, .max_bytes = max_bytes, .want_stderr = false });
}

/// spawn argv、**继承父进程 stdio**（交互式，如 $EDITOR）、等待，返回 exit code。
/// POSIX：fork+execve(inherit fd 0/1/2)+waitpid；Windows：CreateProcessW(继承 console)+Wait。
pub fn runInherit(argv: []const ?[*:0]const u8, inherit_env: bool) CaptureError!i32 {
    last_spawn_failure = null;
    if (is_windows) {
        const a = std.heap.page_allocator;
        const cmdline = buildWindowsCmdline(a, argv) catch return error.SpawnFailed;
        defer a.free(cmdline);
        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW); // 不设 USESTDHANDLES → 子进程继承本进程 console
        var pi = std.mem.zeroes(win.PROCESS.INFORMATION);
        if (win.kernel32.CreateProcessW(null, cmdline.ptr, null, null, @enumFromInt(0), .{}, null, null, &si, &pi) == .FALSE) return windowsSpawnFailure(GetLastError(), null);
        _ = WaitForSingleObject(pi.hProcess, INFINITE);
        var code: win.DWORD = 0;
        _ = GetExitCodeProcess(pi.hProcess, &code);
        win.CloseHandle(pi.hProcess);
        win.CloseHandle(pi.hThread);
        return @bitCast(code);
    }
    g_fork_serial.lock();
    const report = ReportPipe.open() orelse {
        g_fork_serial.unlock();
        return error.PipeFailed;
    };
    const pid = std.c.fork();
    if (pid < 0) {
        report.closeBoth();
        g_fork_serial.unlock();
        return error.SpawnFailed;
    }
    if (pid == 0) execChild(argv, inherit_env, null, report.wr);
    _ = std.c.close(report.wr);
    g_fork_serial.unlock();
    if (awaitChildReport(report, pid)) |failure| return spawnFailureError(failure);
    return posixExitCode(waitpidRetry(pid));
}

/// spawn argv、**detached**（关闭 stdio、不等待，fire-and-forget，如打开浏览器）。
/// POSIX：fork+setpgid+close(0/1/2)+execve，父不 waitpid；Windows：CreateProcessW(DETACHED_PROCESS)。
pub fn spawnDetached(argv: []const ?[*:0]const u8, inherit_env: bool) CaptureError!void {
    last_spawn_failure = null;
    if (is_windows) {
        const a = std.heap.page_allocator;
        const cmdline = buildWindowsCmdline(a, argv) catch return error.SpawnFailed;
        defer a.free(cmdline);
        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW);
        var pi = std.mem.zeroes(win.PROCESS.INFORMATION);
        if (win.kernel32.CreateProcessW(null, cmdline.ptr, null, null, @enumFromInt(0), .{ .detached_process = true }, null, null, &si, &pi) == .FALSE) return windowsSpawnFailure(GetLastError(), null);
        win.CloseHandle(pi.hProcess);
        win.CloseHandle(pi.hThread);
        return;
    }
    g_fork_serial.lock();
    const report = ReportPipe.open() orelse {
        g_fork_serial.unlock();
        return error.PipeFailed;
    };
    const pid = std.c.fork();
    if (pid < 0) {
        report.closeBoth();
        g_fork_serial.unlock();
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(0);
        _ = std.c.close(1);
        _ = std.c.close(2);
        execChild(argv, inherit_env, null, report.wr);
    }
    _ = std.c.close(report.wr);
    g_fork_serial.unlock();
    // 父：fire-and-forget，不 waitpid（对齐原 openBrowser）——除非子进程根本没起来:
    // 那时 awaitChildReport 已把它收尸,这里只把原因交出去。
    if (awaitChildReport(report, pid)) |failure| return spawnFailureError(failure);
}

// ============================================================================
// 长连接双向 pipe 子进程（MCP/LSP stdio transport：spawn + 持久 stdin/stdout + terminate）
// ============================================================================

/// 长连接子进程句柄：持有进程 + stdin(父写)/stdout(父读) 端点。POSIX=pid+fd；Windows=HANDLE。
pub const PipeChild = struct {
    proc: if (is_windows) win.HANDLE else std.c.pid_t,
    stdin_h: if (is_windows) win.HANDLE else std.c.fd_t,
    stdout_h: if (is_windows) win.HANDLE else std.c.fd_t,

    /// 写子进程 stdin。返回写出字节数（<0=错误）。
    pub fn write(self: *const PipeChild, data: []const u8) isize {
        if (is_windows) {
            var wrote: win.DWORD = 0;
            if (WriteFile(self.stdin_h, data.ptr, @intCast(@min(data.len, std.math.maxInt(win.DWORD))), &wrote, null) == 0) return -1;
            return @intCast(wrote);
        }
        return std.c.write(self.stdin_h, data.ptr, data.len);
    }

    /// 读子进程 stdout。返回读到字节数（0=EOF，<0=错误）。
    pub fn read(self: *const PipeChild, buf: []u8) isize {
        if (is_windows) {
            var got: win.DWORD = 0;
            if (ReadFile(self.stdout_h, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(win.DWORD))), &got, null) == 0) return -1; // ERROR_BROKEN_PIPE 等
            return @intCast(got);
        }
        return std.c.read(self.stdout_h, buf.ptr, buf.len);
    }

    /// stdout 是否在 timeout_ms 内可读（abort-aware 守卫用：超时回查 abort 再 poll）。
    /// 返 true=有数据可读 or EOF/错误（read 不会无限阻塞）；false=超时无数据。
    /// POSIX=poll；Windows=PeekNamedPipe 轮询（pipe HANDLE 无 poll）。
    /// stdin 是否在 timeout_ms 内可写。子进程停止排空 stdin 时,写会在管道满后
    /// 阻塞;调用方据此在 deadline 内放弃,而不是无限期挂住。
    ///
    /// **Windows 例外**:匿名管道没有可移植的"可写"查询,这里恒返 true,于是
    /// 调用方的 deadline **不能**打断一个已经阻塞的 `WriteFile`。要真正可中断
    /// 需要 overlapped I/O。当前唯一的写方是 `kg/kgd`,它的子进程是本产品自己
    /// 分发的 tinykgd,且请求上限 1MB;真正修复登记在 doc/TINYKG_INTEGRATION.md。
    pub fn pollWritable(self: *const PipeChild, timeout_ms: u32) bool {
        if (is_windows) {
            return true;
        }
        var pfds = [_]std.c.pollfd{.{ .fd = self.stdin_h, .events = std.c.POLL.OUT, .revents = 0 }};
        return std.c.poll(&pfds, 1, @intCast(timeout_ms)) > 0;
    }

    pub fn pollReadable(self: *const PipeChild, timeout_ms: u32) bool {
        if (is_windows) {
            const deadline = nowMs() + @as(i64, timeout_ms);
            while (true) {
                var avail: win.DWORD = 0;
                if (PeekNamedPipe(self.stdout_h, null, 0, null, &avail, null) == 0) return true; // 错误/EOF → 交给 read
                if (avail > 0) return true;
                if (nowMs() >= deadline) return false;
                Sleep(10);
            }
        }
        var pfds = [_]std.c.pollfd{.{ .fd = self.stdout_h, .events = std.c.POLL.IN, .revents = 0 }};
        return std.c.poll(&pfds, 1, @intCast(timeout_ms)) > 0;
    }

    /// 关闭 stdin 端（发 EOF 给子进程，如 LSP shutdown）。
    pub fn closeStdin(self: *const PipeChild) void {
        if (is_windows) win.CloseHandle(self.stdin_h) else _ = std.c.close(self.stdin_h);
    }

    /// 关闭 stdout 端。
    pub fn closeStdout(self: *const PipeChild) void {
        if (is_windows) win.CloseHandle(self.stdout_h) else _ = std.c.close(self.stdout_h);
    }

    /// 终止子进程并回收。POSIX：SIGTERM→200ms→WNOHANG 查→顽固则 SIGKILL→阻塞收尸（防 ignore-TERM
    /// 的 server 令 waitpid 永挂）；Windows：TerminateProcess+WaitForSingleObject+CloseHandle。
    pub fn terminate(self: *const PipeChild) void {
        if (is_windows) {
            _ = TerminateProcess(self.proc, 1);
            _ = WaitForSingleObject(self.proc, 2000);
            win.CloseHandle(self.proc);
        } else {
            _ = std.c.kill(-self.proc, std.c.SIG.TERM);
            const req = std.c.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
            var status: c_int = 0;
            const WNOHANG: c_int = 1;
            if (std.c.waitpid(self.proc, &status, WNOHANG) == 0) {
                _ = std.c.kill(-self.proc, std.c.SIG.KILL);
                _ = waitpidRetry(self.proc);
            }
        }
    }
};

/// spawn 长连接子进程，返回持久 stdin(父写)/stdout(父读) 端点。stderr 丢弃（→null/NUL）。
pub fn spawnPipes(argv: []const ?[*:0]const u8, inherit_env: bool, cwd: ?[]const u8) CaptureError!PipeChild {
    last_spawn_failure = null;
    if (is_windows) return spawnPipesWindows(argv, cwd);
    return spawnPipesPosix(argv, inherit_env, cwd);
}

fn spawnPipesPosix(argv: []const ?[*:0]const u8, inherit_env: bool, cwd: ?[]const u8) CaptureError!PipeChild {
    var in_pipe: [2]std.c.fd_t = undefined; // 父写 → 子读
    var out_pipe: [2]std.c.fd_t = undefined; // 子写 → 父读
    // 从建第一条 pipe 到父端关完子进程侧的端,持 fork 串行锁(见 g_fork_serial)。
    g_fork_serial.lock();
    var fork_locked = true;
    defer if (fork_locked) g_fork_serial.unlock();
    if (std.c.pipe(&in_pipe) != 0) return error.PipeFailed;
    if (std.c.pipe(&out_pipe) != 0) {
        closePair(in_pipe);
        return error.PipeFailed;
    }
    const report = ReportPipe.open() orelse {
        closePair(in_pipe);
        closePair(out_pipe);
        return error.PipeFailed;
    };
    const pid = std.c.fork();
    if (pid < 0) {
        closePair(in_pipe);
        closePair(out_pipe);
        report.closeBoth();
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(in_pipe[1]);
        _ = std.c.close(out_pipe[0]);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        wireStdioOrExit(.{ in_pipe[0], out_pipe[1], devnull }, report.wr);
        execChild(argv, inherit_env, cwd, report.wr);
    }
    _ = std.c.close(in_pipe[0]); // 父不读 stdin pipe
    _ = std.c.close(out_pipe[1]); // 父不写 stdout pipe
    _ = std.c.close(report.wr);
    _ = std.c.setpgid(pid, pid);
    g_fork_serial.unlock(); // 子进程侧的端全关,可继承窗口结束
    fork_locked = false;
    if (awaitChildReport(report, pid)) |failure| {
        _ = std.c.close(in_pipe[1]);
        _ = std.c.close(out_pipe[0]);
        return spawnFailureError(failure);
    }
    return .{ .proc = pid, .stdin_h = in_pipe[1], .stdout_h = out_pipe[0] };
}

fn spawnPipesWindows(argv: []const ?[*:0]const u8, cwd: ?[]const u8) CaptureError!PipeChild {
    // cmdline 在建任何可继承句柄**之前**构造(review-2 F1):它可失败(argv 含非法
    // UTF-8 即可,非只 OOM),若在句柄之后 early-return 会把可继承写端永久泄漏——
    // 之后任何 bInheritHandles spawn 都会把它塞给不相干子进程,capture 永不 EOF。
    const a = std.heap.page_allocator;
    const cmdline = buildWindowsCmdline(a, argv) catch return error.SpawnFailed;
    defer a.free(cmdline);
    // 缺陷 B 修复:cwd 转 UTF-16(Windows CreateProcessW 第 8 参数 lpCurrentDirectory)。
    const cwd_w: ?[:0]u16 = if (cwd) |c| (std.unicode.utf8ToUtf16LeAllocZ(a, c) catch return error.SpawnFailed) else null;
    defer if (cwd_w) |w| a.free(w);
    // 可继承句柄窗口期串行(见 g_spawn_serial)。
    g_spawn_serial.lock();
    var spawn_locked = true;
    defer if (spawn_locked) g_spawn_serial.unlock();
    // stdin：read 端可继承（子读）、write 端父写；stdout：write 端可继承（子写）、read 端父读。
    var in_rd: win.HANDLE = undefined;
    var in_wr: win.HANDLE = undefined;
    var sa = win.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(win.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = @enumFromInt(1) };
    if (CreatePipe(&in_rd, &in_wr, &sa, 0) == 0 or SetHandleInformation(in_wr, HANDLE_FLAG_INHERIT, 0) == 0) return error.PipeFailed;
    var out_rd: win.HANDLE = undefined;
    var out_wr: win.HANDLE = undefined;
    if (CreatePipe(&out_rd, &out_wr, &sa, 0) == 0 or SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0) == 0) {
        win.CloseHandle(in_rd);
        win.CloseHandle(in_wr);
        return error.PipeFailed;
    }
    var si = std.mem.zeroes(win.STARTUPINFOW);
    si.cb = @sizeOf(win.STARTUPINFOW);
    si.dwFlags = win.STARTF_USESTDHANDLES;
    si.hStdInput = in_rd;
    si.hStdOutput = out_wr;
    si.hStdError = null;
    var pi = std.mem.zeroes(win.PROCESS.INFORMATION);
    const cwd_ptr: ?[*:0]u16 = if (cwd_w) |w| w.ptr else null;
    const created = win.kernel32.CreateProcessW(null, cmdline.ptr, null, null, @enumFromInt(1), .{}, null, cwd_ptr, &si, &pi);
    const create_error: u32 = if (created == .FALSE) GetLastError() else 0; // 任何后续 Win32 调用都会覆盖它
    win.CloseHandle(in_rd); // 父端关子进程侧
    win.CloseHandle(out_wr);
    g_spawn_serial.unlock(); // 可继承句柄的父端副本已全关
    spawn_locked = false;
    if (created == .FALSE) {
        win.CloseHandle(in_wr);
        win.CloseHandle(out_rd);
        return windowsSpawnFailure(create_error, cwd);
    }
    win.CloseHandle(pi.hThread);
    return .{ .proc = pi.hProcess, .stdin_h = in_wr, .stdout_h = out_rd };
}

// ============================================================================
// 后台 job 进程（Bash bg：spawn detached、stdout/stderr 落盘 fd、非阻塞 reap、kill）
// ============================================================================

/// 进程句柄：POSIX=pid；Windows=进程 HANDLE。
pub const ProcHandle = if (is_windows) win.HANDLE else std.c.pid_t;

extern "c" fn _get_osfhandle(fd: c_int) callconv(.c) usize; // MSVCRT fd → HANDLE（intptr）
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) win.DWORD;

/// 当前进程 pid。POSIX=getpid；Windows=GetCurrentProcessId(避开 std.c.getpid 在 windows
/// 返回类型不宜 `{d}` 格式化的问题)。仅用于 LSP processId 等信息性字段。
pub fn currentPid() i32 {
    // @bitCast(非 @intCast):Windows PID 是 DWORD(u32),理论可 > i32 max → @intCast 在
    // ReleaseSafe 会 panic;processId 仅信息性,位模式重解释即可(负值也无碍)。
    if (is_windows) return @bitCast(GetCurrentProcessId());
    return std.c.getpid();
}

/// spawn 后台子进程，stdout→out_fd、stderr→err_fd（已 open 的文件 fd），返回进程句柄。
/// POSIX：fork+setpgid+dup2+execve；Windows：_get_osfhandle+CreateProcessW(CREATE_NO_WINDOW)。
/// inherit_env=true（bg job 需 PATH 等）。argv 须 null 结尾。
/// cwd 非 null → 子进程在 spawn 时 chdir(借用,spawn 时消费)。
pub fn spawnToFiles(argv: []const ?[*:0]const u8, out_fd: c_int, err_fd: c_int, cwd: ?[]const u8) CaptureError!ProcHandle {
    return spawnToFilesWithEnv(argv, out_fd, err_fd, cwd, true);
}

/// Variant used by the native tool-result spool adapter. Ordinary tool
/// capture historically executes with an empty POSIX environment, while
/// background shell jobs require inheritance. Keep that authority choice at
/// the call site instead of changing `spawnToFiles` compatibility semantics.
pub fn spawnToFilesWithEnv(
    argv: []const ?[*:0]const u8,
    out_fd: c_int,
    err_fd: c_int,
    cwd: ?[]const u8,
    inherit_env: bool,
) CaptureError!ProcHandle {
    last_spawn_failure = null;
    if (is_windows) {
        const out_raw = _get_osfhandle(out_fd);
        const err_raw = _get_osfhandle(err_fd);
        if (out_raw == std.math.maxInt(usize) or err_raw == std.math.maxInt(usize)) return error.SpawnFailed;
        const out_h: win.HANDLE = @ptrFromInt(out_raw);
        const err_h: win.HANDLE = @ptrFromInt(err_raw);
        const a = std.heap.page_allocator;
        const cmdline = buildWindowsCmdline(a, argv) catch return error.SpawnFailed;
        defer a.free(cmdline);
        // 缺陷 B 修复:cwd 转 UTF-16。
        const cwd_w: ?[:0]u16 = if (cwd) |c| (std.unicode.utf8ToUtf16LeAllocZ(a, c) catch return error.SpawnFailed) else null;
        defer if (cwd_w) |w| a.free(w);
        // 可继承句柄窗口期串行(见 g_spawn_serial);spawn 后立即撤销落盘 fd 的可继承标记
        // ——fd 生命周期远长于本次 spawn,留着会泄给后续任何 bInheritHandles 子进程。
        g_spawn_serial.lock();
        if (SetHandleInformation(out_h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) == 0) {
            g_spawn_serial.unlock();
            return error.SpawnFailed;
        }
        if (SetHandleInformation(err_h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) == 0) {
            _ = SetHandleInformation(out_h, HANDLE_FLAG_INHERIT, 0);
            g_spawn_serial.unlock();
            return error.SpawnFailed;
        }
        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW);
        si.dwFlags = win.STARTF_USESTDHANDLES;
        si.hStdOutput = out_h;
        si.hStdError = err_h;
        si.hStdInput = null;
        var pi = std.mem.zeroes(win.PROCESS.INFORMATION);
        const cwd_ptr: ?win.LPCWSTR = if (cwd_w) |w| w.ptr else null;
        const created = win.kernel32.CreateProcessW(null, cmdline.ptr, null, null, @enumFromInt(1), .{ .create_no_window = true }, null, cwd_ptr, &si, &pi);
        const create_error: u32 = if (created == .FALSE) GetLastError() else 0; // 任何后续 Win32 调用都会覆盖它
        _ = SetHandleInformation(out_h, HANDLE_FLAG_INHERIT, 0);
        _ = SetHandleInformation(err_h, HANDLE_FLAG_INHERIT, 0);
        g_spawn_serial.unlock();
        if (created == .FALSE) return windowsSpawnFailure(create_error, cwd);
        win.CloseHandle(pi.hThread);
        return pi.hProcess;
    }
    g_fork_serial.lock();
    const report = ReportPipe.open() orelse {
        g_fork_serial.unlock();
        return error.PipeFailed;
    };
    const pid = std.c.fork();
    if (pid < 0) {
        report.closeBoth();
        g_fork_serial.unlock();
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        // out_fd/err_fd 是调用方开的落盘文件:父进程关着 stdio 时它们也可能落在 0..2。
        wireStdioOrExit(.{ -1, out_fd, err_fd }, report.wr);
        execChild(argv, inherit_env, cwd, report.wr);
    }
    _ = std.c.close(report.wr);
    _ = std.c.setpgid(pid, pid);
    g_fork_serial.unlock();
    if (awaitChildReport(report, pid)) |failure| return spawnFailureError(failure);
    return pid;
}

pub const ReapStatus = union(enum) { running, exited: i32 };

/// 非阻塞查子进程是否退出。POSIX=waitpid(WNOHANG)；Windows=WaitForSingleObject(0)+GetExitCodeProcess。
pub fn reapNonblock(h: ProcHandle) ReapStatus {
    if (is_windows) {
        // 只有 WAIT_TIMEOUT(0x102)=仍运行;WAIT_OBJECT_0(0)=已退;WAIT_FAILED(0xFFFFFFFF)/
        // WAIT_ABANDONED 等=异常,当已退处理(否则失败的 wait 让死 job 永远"运行中"卡看板)。
        const w = WaitForSingleObject(h, 0);
        if (w == WAIT_TIMEOUT_) return .running;
        var code: win.DWORD = 0;
        _ = GetExitCodeProcess(h, &code);
        return .{ .exited = @bitCast(code) };
    }
    var status: c_int = 0;
    const WNOHANG: c_int = 1;
    const rc = std.c.waitpid(h, &status, WNOHANG);
    if (rc == 0) return .running;
    return .{ .exited = posixExitCode(status) };
}

/// 杀子进程。POSIX killpg（-pid=杀整组，因 spawnToFiles 已 setpgid(pid,pid) 使 pgid==pid）；
/// Windows TerminateProcess（单进程）。之后须 reapBlocking 收尸。
pub fn killJob(h: ProcHandle) void {
    if (is_windows) {
        _ = TerminateProcess(h, 1);
    } else {
        _ = std.c.kill(-h, std.c.SIG.TERM);
        const req = std.c.timespec{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
        var status: c_int = 0;
        const WNOHANG: c_int = 1;
        if (std.c.waitpid(h, &status, WNOHANG) == 0) {
            _ = std.c.kill(-h, std.c.SIG.KILL);
        }
    }
}

/// 阻塞 reap（收尸，防僵尸）。POSIX waitpid(0)；Windows CloseHandle（已 Terminate/退出）。
pub fn reapBlocking(h: ProcHandle) void {
    if (is_windows) {
        _ = WaitForSingleObject(h, 2000);
        win.CloseHandle(h);
    } else {
        _ = waitpidRetry(h);
    }
}

fn labelOf(argv: []const ?[*:0]const u8) []const u8 {
    const a0 = argv[0] orelse return "?";
    const full = std.mem.span(a0);
    const slash = std.mem.lastIndexOfScalar(u8, full, '/');
    return if (slash) |i| full[i + 1 ..] else full;
}

// ============================================================================
// POSIX backend
// ============================================================================

fn nowMs() i64 {
    // 显式 if/else(非 if-return 落穿):后者在 refAllDecls(zig test)下 POSIX 分支仍被分析,
    // std.c.clock_gettime 的 clockid_t=void 在 windows winapi 报错。else 块保证 comptime 死分支。
    if (is_windows) {
        return @intCast(GetTickCount64()); // 单调 ms（自开机），0.16 无 std.time.milliTimestamp
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
    }
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

/// fork-child 内 chdir(缺陷 B)。异步信号安全:仅栈 buffer + chdir,无 malloc/lock。
/// 成功返 true;失败或 cwd 过长返 false,errno 说明原因(调用方经报告管道交给父进程)。
/// 三处 spawn 原语共用,避免 7 行代码重复(Linus R2)。
fn chdirChild(cwd: ?[]const u8) bool {
    const c = cwd orelse return true;
    if (c.len >= std.fs.max_path_bytes) {
        std.c._errno().* = @intFromEnum(std.c.E.NAMETOOLONG);
        return false;
    }
    var cwd_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(cwd_z[0..c.len], c);
    cwd_z[c.len] = 0;
    return std.c.chdir(&cwd_z) == 0;
}

// ============================================================================
// 子进程失败报告通道(POSIX)
// ============================================================================

/// POSIX fork serial lock. A pipe end created for a child is inheritable until
/// the parent closes its own copy; a fork on another thread inside that window
/// hands the descriptor to an unrelated child, whose exec'd program then holds
/// a write end open and the parent's EOF never comes. Holding this from the
/// first pipe until the parent has closed every child-side end removes that
/// window for every spawn in this module — the rule `g_spawn_serial` already
/// applies to inheritable handles on Windows. Forks outside this module take
/// it through `forkSerialLock`/`forkSerialUnlock`.
var g_fork_serial: psync.Mutex = .{};

pub fn forkSerialLock() void {
    g_fork_serial.lock();
}

pub fn forkSerialUnlock() void {
    g_fork_serial.unlock();
}

fn closePair(p: [2]std.c.fd_t) void {
    _ = std.c.close(p[0]);
    _ = std.c.close(p[1]);
}

/// 阻塞收尸,EINTR 重试。被信号(SIGWINCH/SIGINT 等)打断的 waitpid 返 -1/EINTR;不重试就
/// 把已退出的子进程留成僵尸,还会把"退出码 0"报给调用方(codex R1 #2)。返回 wait status
/// (交给 posixExitCode);其它错误(ECHILD)按旧行为当 0。
fn waitpidRetry(pid: std.c.pid_t) c_int {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc >= 0) return status;
        if (std.c.errno(rc) != .INTR) return 0;
    }
}

/// 子进程侧:把 `srcs[slot]` 接到 stdio 槽位 0/1/2(-1 = 不动该槽)。
///
/// 父进程若关着某个 stdio,pipe()/open() 会把 0/1/2 发回来当管道端;朴素的
/// `dup2(src, slot); close(src)` 在 src == slot 时先 no-op 再把刚接好的槽关掉,
/// src 落在别的槽上时又会被后一个 dup2 盖掉(codex R1 #1)。所以分三步:先把所有落在
/// 0..2 的源抬到 ≥3(F_DUPFD_CLOEXEC),再 dup2,最后只关 ≥3 的源(同一源接多个槽只关一次)。
/// 只用 fcntl/dup2/close,异步信号安全。同一个低位源出现在多个槽位时,每个槽位各拿一份
/// 抬起来的副本(第一阶段不关原 fd),所以 {0, hi, 0} 这类形状是安全的。
///
/// 抬不上去(EMFILE/ENFILE)就返回 false,**一个槽都不接**:半接好的 stdio 会让后一个 dup2
/// 盖掉还没用到的源,或让一个低位源穿过 exec 泄给程序;调用方经报告通道交代 errno 后
/// `_exit`(codex R2 #2)。
fn applyStdioWiring(srcs_in: [3]std.c.fd_t) bool {
    var srcs = srcs_in;
    for (&srcs) |*s| {
        if (s.* >= 0 and s.* < 3) {
            const lifted = std.c.fcntl(s.*, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
            if (lifted < 3) return false;
            s.* = lifted;
        }
    }
    for (srcs, 0..) |s, slot| {
        if (s >= 0) _ = std.c.dup2(s, @intCast(slot));
    }
    for (srcs, 0..) |s, i| {
        if (s < 3) continue;
        var seen = false;
        for (srcs[0..i]) |earlier| {
            if (earlier == s) seen = true;
        }
        if (!seen) _ = std.c.close(s);
    }
    return true;
}

/// 子进程侧:接线失败就把 fcntl 的 errno 当 exec 步骤的失败交代出去,然后退出。
fn wireStdioOrExit(srcs: [3]std.c.fd_t, report_fd: std.c.fd_t) void {
    if (applyStdioWiring(srcs)) return;
    reportChildFailure(report_fd, .exec, currentErrno());
    std.c._exit(127);
}

/// Wire form of the child's report: `extern` so both sides of the fork agree
/// on the layout; written and read as raw bytes.
const ChildReport = extern struct {
    step: u8,
    pad: [3]u8 = .{ 0, 0, 0 },
    code: i32,
};

/// The parent stops waiting for a report after this long. A successful exec
/// produces EOF within microseconds; the bound only matters if a descriptor
/// leaked into a process forked outside `g_fork_serial`, and then the worst
/// case is a late report being missed — the child still exits 127, exactly
/// the behaviour before the channel existed. It never makes a running child
/// look failed.
const REPORT_WAIT_MS: i64 = 2000;

/// The close-on-exec pipe carrying the child's report.
const ReportPipe = struct {
    rd: std.c.fd_t,
    wr: std.c.fd_t,

    fn open() ?ReportPipe {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return null;
        // Close-on-exec on the write end *is* the mechanism: a successful
        // execve closes it and the parent reads EOF. The read end gets the
        // flag too so a sibling spawn's child cannot inherit it either.
        if (!setCloseOnExec(fds[0]) or !setCloseOnExec(fds[1])) {
            closePair(fds);
            return null;
        }
        // A parent running with any of 0/1/2 closed would get one of them back
        // from pipe(); the child's dup2 onto 0/1/2 would then clobber the write
        // end and a failure record could land in the program's stdout instead
        // of here. Keep both ends above the stdio range.
        const rd = liftAboveStdio(fds[0]) orelse {
            closePair(fds);
            return null;
        };
        const wr = liftAboveStdio(fds[1]) orelse {
            _ = std.c.close(rd);
            _ = std.c.close(fds[1]);
            return null;
        };
        return .{ .rd = rd, .wr = wr };
    }

    fn closeBoth(self: ReportPipe) void {
        _ = std.c.close(self.rd);
        _ = std.c.close(self.wr);
    }
};

fn setCloseOnExec(fd: std.c.fd_t) bool {
    const current = std.c.fcntl(fd, std.c.F.GETFD);
    return current >= 0 and std.c.fcntl(fd, std.c.F.SETFD, current | std.c.FD_CLOEXEC) >= 0;
}

/// Returns `fd` itself when it is already ≥ 3, otherwise a close-on-exec
/// duplicate ≥ 3 (the original is closed). Null when the dup fails.
fn liftAboveStdio(fd: std.c.fd_t) ?std.c.fd_t {
    if (fd >= 3) return fd;
    const lifted = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    _ = std.c.close(fd);
    return if (lifted >= 3) lifted else null;
}

fn currentErrno() i32 {
    return @intCast(std.c._errno().*);
}

/// Child side, between fork and exec: one fixed-size write and nothing else —
/// no allocation, no locks — so it is async-signal-safe.
fn reportChildFailure(fd: std.c.fd_t, step: SpawnStep, code: i32) void {
    const report = ChildReport{ .step = @intFromEnum(step), .code = code };
    const bytes = std.mem.asBytes(&report);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return;
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

/// The child's tail shared by every POSIX spawn: enter the working directory,
/// exec, and account for whichever step refused. Never returns.
fn execChild(argv: []const ?[*:0]const u8, inherit_env: bool, cwd: ?[]const u8, report_fd: std.c.fd_t) noreturn {
    if (!chdirChild(cwd)) {
        reportChildFailure(report_fd, .chdir, currentErrno());
        std.c._exit(127);
    }
    const argv0 = argv[0] orelse {
        reportChildFailure(report_fd, .exec, @intFromEnum(std.c.E.INVAL));
        std.c._exit(127);
    };
    const envp: [*:null]const ?[*:0]const u8 = if (inherit_env) @ptrCast(std.c.environ) else &.{null};
    _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), envp);
    reportChildFailure(report_fd, .exec, currentErrno());
    std.c._exit(127);
}

/// Parent side. Waits for the child's report, or for the EOF a successful exec
/// produces. On a report the child has already exited: it is reaped here and
/// the failure returned; null means the child is running the program. Always
/// closes the read end.
fn awaitChildReport(report: ReportPipe, pid: std.c.pid_t) ?SpawnFailure {
    defer _ = std.c.close(report.rd);
    var record: ChildReport = undefined;
    const bytes = std.mem.asBytes(&record);
    var got: usize = 0;
    const deadline = nowMs() + REPORT_WAIT_MS;
    while (got < bytes.len) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) break;
        var pfd = [_]std.c.pollfd{.{ .fd = report.rd, .events = std.c.POLL.IN, .revents = 0 }};
        const rc = std.c.poll(&pfd, 1, @intCast(@min(remaining, 100)));
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            break;
        }
        if (rc == 0) continue;
        const n = std.c.read(report.rd, bytes.ptr + got, bytes.len - got);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            break;
        }
        if (n == 0) break; // EOF: the write end went away with a successful exec
        got += @intCast(n);
    }
    if (got == 0) return null;
    // Even a short record came from a child that gave up before exec.
    const failure: SpawnFailure = if (got < bytes.len)
        .{ .step = .exec, .code = 0 }
    else
        .{ .step = std.enums.fromInt(SpawnStep, record.step) orelse .exec, .code = record.code };
    _ = waitpidRetry(pid);
    return failure;
}

fn capturePosix(argv: []const ?[*:0]const u8, allocator: std.mem.Allocator, opts: CaptureOpts) CaptureError!Captured {
    // 从建第一条 pipe 到父端关完子进程侧的端,持 fork 串行锁(见 g_fork_serial);
    // 喂 stdin 与抽干在锁外。
    g_fork_serial.lock();
    var fork_locked = true;
    defer if (fork_locked) g_fork_serial.unlock();

    var out_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&out_pipe) != 0) return error.PipeFailed;
    var err_pipe: [2]std.c.fd_t = .{ -1, -1 };
    if (opts.want_stderr) {
        if (std.c.pipe(&err_pipe) != 0) {
            closePair(out_pipe);
            return error.PipeFailed;
        }
    }
    var in_pipe: [2]std.c.fd_t = .{ -1, -1 };
    if (opts.stdin_data != null) {
        if (std.c.pipe(&in_pipe) != 0) {
            closePair(out_pipe);
            if (opts.want_stderr) closePair(err_pipe);
            return error.PipeFailed;
        }
    }
    const report = ReportPipe.open() orelse {
        closePair(out_pipe);
        if (opts.want_stderr) closePair(err_pipe);
        if (opts.stdin_data != null) closePair(in_pipe);
        return error.PipeFailed;
    };

    const pid = std.c.fork();
    if (pid < 0) {
        closePair(out_pipe);
        if (opts.want_stderr) closePair(err_pipe);
        if (opts.stdin_data != null) closePair(in_pipe);
        report.closeBoth();
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        // 先关父端的端,再统一接线(applyStdioWiring:源若落在 0..2 先抬走再 dup2)。
        _ = std.c.close(out_pipe[0]);
        if (opts.stdin_data != null) _ = std.c.close(in_pipe[1]);
        if (opts.want_stderr) _ = std.c.close(err_pipe[0]);
        const stderr_src: std.c.fd_t = if (opts.want_stderr) err_pipe[1] else std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        wireStdioOrExit(.{ if (opts.stdin_data != null) in_pipe[0] else -1, out_pipe[1], stderr_src }, report.wr);
        execChild(argv, opts.inherit_env, opts.cwd, report.wr);
    }

    _ = std.c.close(out_pipe[1]);
    if (opts.want_stderr) _ = std.c.close(err_pipe[1]);
    if (opts.stdin_data != null) _ = std.c.close(in_pipe[0]);
    _ = std.c.close(report.wr);
    _ = std.c.setpgid(pid, pid);
    g_fork_serial.unlock(); // 子进程侧的端全关,可继承窗口结束
    fork_locked = false;

    if (awaitChildReport(report, pid)) |failure| {
        _ = std.c.close(out_pipe[0]);
        if (opts.want_stderr) _ = std.c.close(err_pipe[0]);
        if (opts.stdin_data != null) _ = std.c.close(in_pipe[1]);
        return spawnFailureError(failure);
    }

    // 喂 stdin（小数据：先写完再 drain）。SIGPIPE 全局忽略 → 子进程早退时 write 返 EPIPE 不杀本进程。
    if (opts.stdin_data) |data| {
        var w: usize = 0;
        while (w < data.len) {
            const n = std.c.write(in_pipe[1], data.ptr + w, data.len - w);
            if (n <= 0) break;
            w += @intCast(n);
        }
        _ = std.c.close(in_pipe[1]);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var err = std.ArrayList(u8).empty;
    errdefer err.deinit(allocator);

    var buf: [4096]u8 = undefined;
    const start = nowMs();
    var last_tick = start;
    var out_done = false;
    var err_done = !opts.want_stderr;
    var timed_out = false;
    var capture_complete = true;
    const label = labelOf(argv);

    while (!(out_done and err_done)) {
        if (opts.abort_poll) |poll| if (poll(opts.abort_ctx)) {
            killGroupPosix(pid);
            _ = std.c.close(out_pipe[0]);
            if (opts.want_stderr) _ = std.c.close(err_pipe[0]);
            _ = waitpidRetry(pid);
            return error.Aborted;
        };
        const elapsed = nowMs() - start;
        if (opts.timeout_ms > 0 and elapsed >= @as(i64, @intCast(opts.timeout_ms))) {
            killGroupPosix(pid);
            timed_out = true;
            break;
        }
        if (opts.tick_cb) |cb| {
            if (nowMs() - last_tick >= 2000) {
                cb(opts.tick_ctx, @intCast(elapsed), label);
                last_tick = nowMs();
            }
        }
        var pfds = [_]std.c.pollfd{
            .{ .fd = if (out_done) -1 else out_pipe[0], .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = if (err_done) -1 else err_pipe[0], .events = std.c.POLL.IN, .revents = 0 },
        };
        const rc = std.c.poll(&pfds, 2, 100);
        if (rc < 0) {
            _ = std.c.close(out_pipe[0]);
            if (opts.want_stderr) _ = std.c.close(err_pipe[0]);
            return error.ReadError;
        }
        if (rc == 0) continue;
        const terminal_events = std.c.POLL.HUP | std.c.POLL.ERR | std.c.POLL.NVAL;
        if (!out_done and (pfds[0].revents & (std.c.POLL.IN | terminal_events)) != 0) {
            const n = std.c.read(out_pipe[0], &buf, buf.len);
            if (n < 0) {
                _ = std.c.close(out_pipe[0]);
                if (opts.want_stderr) _ = std.c.close(err_pipe[0]);
                return error.ReadError;
            }
            if (n == 0) out_done = true else try out.appendSlice(allocator, buf[0..@intCast(n)]);
        }
        if (!err_done and (pfds[1].revents & (std.c.POLL.IN | terminal_events)) != 0) {
            const n = std.c.read(err_pipe[0], &buf, buf.len);
            if (n < 0) {
                _ = std.c.close(out_pipe[0]);
                _ = std.c.close(err_pipe[0]);
                return error.ReadError;
            }
            if (n == 0) err_done = true else try err.appendSlice(allocator, buf[0..@intCast(n)]);
        }
        if (out.items.len + err.items.len >= opts.max_bytes) {
            killGroupPosix(pid); // cap 命中：止血，返已读部分（Ok，非错误，对齐 common.zig）
            capture_complete = false;
            break;
        }
    }
    _ = std.c.close(out_pipe[0]);
    if (opts.want_stderr) _ = std.c.close(err_pipe[0]);

    const status = waitpidRetry(pid);

    if (timed_out and !opts.timeout_partial) return error.Timeout; // errdefer 释放 out/err（勿显式 deinit → 双 free）
    return .{
        .stdout = try out.toOwnedSlice(allocator),
        .stderr = try err.toOwnedSlice(allocator),
        .exit_code = posixExitCode(status),
        .timed_out = timed_out,
        .capture_complete = capture_complete and !timed_out,
    };
}

// ============================================================================
// Windows backend
// ============================================================================

const win = std.os.windows;

const HANDLE_FLAG_INHERIT: win.DWORD = 0x00000001;
const INFINITE: win.DWORD = 0xFFFFFFFF;
const WAIT_TIMEOUT_: win.DWORD = 0x00000102;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn CreatePipe(hReadPipe: *win.HANDLE, hWritePipe: *win.HANDLE, lpPipeAttributes: ?*win.SECURITY_ATTRIBUTES, nSize: win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: win.DWORD, dwShareMode: win.DWORD, lpSecurityAttributes: ?*win.SECURITY_ATTRIBUTES, dwCreationDisposition: win.DWORD, dwFlagsAndAttributes: win.DWORD, hTemplateFile: ?win.HANDLE) callconv(.winapi) win.HANDLE;
extern "kernel32" fn SetHandleInformation(hObject: win.HANDLE, dwMask: win.DWORD, dwFlags: win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(hFile: win.HANDLE, lpBuffer: [*]u8, nToRead: win.DWORD, lpRead: *win.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(hFile: win.HANDLE, lpBuffer: [*]const u8, nToWrite: win.DWORD, lpWritten: *win.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: win.HANDLE, dwMilliseconds: win.DWORD) callconv(.winapi) win.DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: win.HANDLE, lpExitCode: *win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn TerminateProcess(hProcess: win.HANDLE, uExitCode: win.UINT) callconv(.winapi) c_int;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: win.HANDLE, lpBuffer: ?[*]u8, nBufferSize: win.DWORD, lpBytesRead: ?*win.DWORD, lpTotalBytesAvail: ?*win.DWORD, lpBytesLeftThisMessage: ?*win.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(dwMilliseconds: win.DWORD) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

const ERROR_FILE_NOT_FOUND: u32 = 2;
const ERROR_PATH_NOT_FOUND: u32 = 3;
const ERROR_ACCESS_DENIED: u32 = 5;
const ERROR_BAD_EXE_FORMAT: u32 = 193;
const ERROR_DIRECTORY: u32 = 267;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

/// `CreateProcessW` refused with `code` (captured straight after the call —
/// any Win32 call in between overwrites it). Classified the way the POSIX
/// child report is, so callers see the same two errors on both platforms. A
/// not-found code does not say whether the program or `lpCurrentDirectory` was
/// missing; the directory is looked at to settle the wording — naming only,
/// it gates no retry.
fn windowsSpawnFailure(code: u32, cwd: ?[]const u8) CaptureError {
    const step: SpawnStep = switch (code) {
        ERROR_DIRECTORY => .chdir,
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => blk: {
            const c = cwd orelse break :blk .exec;
            break :blk if (windowsIsDirectory(c)) .exec else .chdir;
        },
        ERROR_ACCESS_DENIED, ERROR_BAD_EXE_FORMAT => .exec,
        else => return error.SpawnFailed,
    };
    return spawnFailureError(.{ .step = step, .code = @bitCast(code) });
}

/// `lpCurrentDirectory` must name a directory (a regular file at that path is
/// just as unusable as nothing), so the attribute bit is required, not mere
/// existence (codex R1 #5). The path is evaluated as the caller gave it;
/// `CreateProcessW` wants a full path there, and every caller in this
/// repository passes an absolute session root.
fn windowsIsDirectory(path: []const u8) bool {
    var wbuf: [win.PATH_MAX_WIDE + 1]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return false;
    if (wlen >= wbuf.len) return false;
    wbuf[wlen] = 0;
    const attrs = GetFileAttributesW(@ptrCast(&wbuf));
    if (attrs == 0xFFFF_FFFF) return false; // INVALID_FILE_ATTRIBUTES
    return (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

// 每个 reader 线程独占自己的 list（out_reader→out / err_reader→err），main 在 join 后才读，
// 无跨线程并发访问同一 list → 无需锁。
const WinReader = struct {
    handle: win.HANDLE,
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    max_bytes: usize,
    oom: bool = false,
    /// 读满 max_bytes 时置真,让主循环 TerminateProcess——否则子进程继续写、pipe 满、子阻塞
    /// 在 write,reader 已退,主循环 WaitForSingleObject 无限空转(无 timeout 时永挂)。对齐
    /// POSIX 的 cap-kill 语义(cap 命中=Ok 返部分,非 Timeout)。
    capped: *std.atomic.Value(bool),

    fn run(self: *WinReader) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            var read_n: win.DWORD = 0;
            const ok = ReadFile(self.handle, &buf, buf.len, &read_n, null);
            if (ok == 0 or read_n == 0) break;
            self.list.appendSlice(self.allocator, buf[0..read_n]) catch {
                self.oom = true;
                break;
            };
            if (self.list.items.len >= self.max_bytes) {
                self.capped.store(true, .release);
                break;
            }
        }
    }
};

fn makeInheritablePipe(rd: *win.HANDLE, wr: *win.HANDLE) CaptureError!void {
    var sa = win.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(win.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = @enumFromInt(1) };
    if (CreatePipe(rd, wr, &sa, 0) == 0) return error.PipeFailed;
    if (SetHandleInformation(rd.*, HANDLE_FLAG_INHERIT, 0) == 0) {
        win.CloseHandle(rd.*);
        win.CloseHandle(wr.*);
        return error.PipeFailed;
    }
}

/// 打开 NUL 设备的可继承写句柄(丢弃 stderr 用,等价 POSIX /dev/null)。
fn openNulWrite() CaptureError!win.HANDLE {
    const GENERIC_WRITE: win.DWORD = 0x4000_0000;
    const FILE_SHARE_RW: win.DWORD = 0x1 | 0x2;
    const OPEN_EXISTING: win.DWORD = 3;
    var sa = win.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(win.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = @enumFromInt(1) };
    const nul_w = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
    const h = CreateFileW(nul_w, GENERIC_WRITE, FILE_SHARE_RW, &sa, OPEN_EXISTING, 0, null);
    if (h == win.INVALID_HANDLE_VALUE) return error.PipeFailed;
    return h;
}

fn captureWindows(argv: []const ?[*:0]const u8, allocator: std.mem.Allocator, opts: CaptureOpts) CaptureError!Captured {
    // cmdline 在建任何可继承句柄之前构造(review-2 F1):可失败(argv 非法 UTF-8/OOM),
    // 若在句柄之后 early-return 会把可继承写端永久泄漏 → 后续任意 capture 永不 EOF。
    const cmdline = buildWindowsCmdline(allocator, argv) catch return error.SpawnFailed;
    defer allocator.free(cmdline);
    // 缺陷 B 修复:cwd 转 UTF-16。
    const cwd_w: ?[:0]u16 = if (opts.cwd) |c| (std.unicode.utf8ToUtf16LeAllocZ(allocator, c) catch return error.SpawnFailed) else null;
    defer if (cwd_w) |w| allocator.free(w);
    // 可继承句柄窗口期串行(见 g_spawn_serial);锁外做 stdin 写与读取/等待。
    g_spawn_serial.lock();
    var spawn_locked = true;
    defer if (spawn_locked) g_spawn_serial.unlock();
    var out_rd: win.HANDLE = undefined;
    var out_wr: win.HANDLE = undefined;
    try makeInheritablePipe(&out_rd, &out_wr);

    // stderr:want_stderr 时独立 pipe 收集;否则送 NUL 设备**丢弃**(而非复用 stdout 写端——
    // 那会把 stderr 混进 stdout,污染 captureStdout 家族解析的命令输出,且违反 want_stderr=false
    // 契约。对齐 POSIX 的 dup2(child_stderr, /dev/null))。
    var err_rd: ?win.HANDLE = null;
    var err_wr: win.HANDLE = undefined;
    var err_is_nul = false;
    if (opts.want_stderr) {
        var rd: win.HANDLE = undefined;
        var wr: win.HANDLE = undefined;
        makeInheritablePipe(&rd, &wr) catch {
            win.CloseHandle(out_rd);
            win.CloseHandle(out_wr);
            return error.PipeFailed;
        };
        err_rd = rd;
        err_wr = wr;
    } else {
        err_wr = openNulWrite() catch {
            win.CloseHandle(out_rd);
            win.CloseHandle(out_wr);
            return error.PipeFailed;
        };
        err_is_nul = true;
    }

    // stdin pipe（若需喂入）：read 端可继承（子读），write 端不可继承（父写）——与 stdout 反。
    var in_rd: ?win.HANDLE = null;
    var in_wr: win.HANDLE = undefined;
    if (opts.stdin_data != null) {
        var sa = win.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(win.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = @enumFromInt(1) };
        var rd: win.HANDLE = undefined;
        var wr: win.HANDLE = undefined;
        if (CreatePipe(&rd, &wr, &sa, 0) == 0 or SetHandleInformation(wr, HANDLE_FLAG_INHERIT, 0) == 0) {
            win.CloseHandle(out_rd);
            win.CloseHandle(out_wr);
            if (err_rd) |h| win.CloseHandle(h);
            win.CloseHandle(err_wr); // err_wr 恒有效(pipe wr 或 NUL),父端副本总要关
            return error.PipeFailed;
        }
        in_rd = rd;
        in_wr = wr;
    }

    var si = std.mem.zeroes(win.STARTUPINFOW);
    si.cb = @sizeOf(win.STARTUPINFOW);
    si.dwFlags = win.STARTF_USESTDHANDLES;
    si.hStdOutput = out_wr;
    si.hStdError = err_wr;
    si.hStdInput = in_rd; // null → 子进程无 stdin（inherit_env 在 Windows 恒继承 env，此为 stdin）

    var pi = std.mem.zeroes(win.PROCESS.INFORMATION);
    const cwd_ptr: ?win.LPCWSTR = if (cwd_w) |w| w.ptr else null;
    const created = win.kernel32.CreateProcessW(null, cmdline.ptr, null, null, @enumFromInt(1), .{}, null, cwd_ptr, &si, &pi);
    const create_error: u32 = if (created == .FALSE) GetLastError() else 0; // 任何后续 Win32 调用都会覆盖它
    // 父端**先**关掉全部可继承句柄副本(out_wr/in_rd/err_wr)再解串行锁——锁窗口 = 可继承
    // 句柄存活期。stdin 写(in_wr 不可继承)移到锁外,大输入阻塞不占全局锁。
    win.CloseHandle(out_wr);
    if (in_rd) |h| win.CloseHandle(h); // 父端关 stdin read 端（子已继承副本）
    win.CloseHandle(err_wr); // err_wr 恒有效(pipe wr 或 NUL),父端副本总要关
    g_spawn_serial.unlock();
    spawn_locked = false;
    if (in_rd != null) {
        // 写 stdin_data 后关 write 端（发 EOF）。created 失败也要关 in_wr。
        if (created != .FALSE) {
            const data = opts.stdin_data.?;
            var w: usize = 0;
            while (w < data.len) {
                var wrote: win.DWORD = 0;
                if (WriteFile(in_wr, data.ptr + w, @intCast(data.len - w), &wrote, null) == 0 or wrote == 0) break;
                w += wrote;
            }
        }
        win.CloseHandle(in_wr);
    }
    if (created == .FALSE) {
        win.CloseHandle(out_rd);
        if (err_rd) |h| win.CloseHandle(h);
        return windowsSpawnFailure(create_error, opts.cwd);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var err = std.ArrayList(u8).empty;
    errdefer err.deinit(allocator);

    var capped = std.atomic.Value(bool).init(false);
    var out_reader = WinReader{ .handle = out_rd, .list = &out, .allocator = allocator, .max_bytes = opts.max_bytes, .capped = &capped };
    const out_thread = std.Thread.spawn(.{}, WinReader.run, .{&out_reader}) catch {
        win.CloseHandle(out_rd);
        if (err_rd) |h| win.CloseHandle(h);
        win.CloseHandle(pi.hProcess);
        win.CloseHandle(pi.hThread);
        return error.SpawnFailed;
    };
    var err_reader: WinReader = undefined;
    var err_thread: ?std.Thread = null;
    if (err_rd) |h| {
        err_reader = WinReader{ .handle = h, .list = &err, .allocator = allocator, .max_bytes = opts.max_bytes, .capped = &capped };
        err_thread = std.Thread.spawn(.{}, WinReader.run, .{&err_reader}) catch null;
    }

    // 分片轮询等进程：每 100ms 查 abort/timeout/tick。
    const start = nowMs();
    var last_tick = start;
    var timed_out = false;
    var aborted = false;
    const label = labelOf(argv);
    while (true) {
        const w = WaitForSingleObject(pi.hProcess, 100);
        if (w != WAIT_TIMEOUT_) break; // 进程已退出
        // reader 读满 max_bytes → kill 子进程(否则它继续写、pipe 满、阻塞在 write,主循环
        // 无 timeout 时永挂)。cap 命中=Ok 返部分(非 aborted/timed_out),对齐 POSIX。
        if (capped.load(.acquire)) {
            _ = TerminateProcess(pi.hProcess, 1);
            break;
        }
        if (opts.abort_poll) |poll| if (poll(opts.abort_ctx)) {
            _ = TerminateProcess(pi.hProcess, 1);
            aborted = true;
            break;
        };
        const elapsed = nowMs() - start;
        if (opts.timeout_ms > 0 and elapsed >= @as(i64, @intCast(opts.timeout_ms))) {
            _ = TerminateProcess(pi.hProcess, 1);
            timed_out = true;
            break;
        }
        if (opts.tick_cb) |cb| {
            if (nowMs() - last_tick >= 2000) {
                cb(opts.tick_ctx, @intCast(elapsed), label);
                last_tick = nowMs();
            }
        }
    }

    out_thread.join();
    if (err_thread) |t| t.join();
    win.CloseHandle(out_rd);
    if (err_rd) |h| win.CloseHandle(h);

    var code: win.DWORD = 0;
    _ = GetExitCodeProcess(pi.hProcess, &code);
    win.CloseHandle(pi.hProcess);
    win.CloseHandle(pi.hThread);

    if (out_reader.oom) return error.OutOfMemory;
    if (aborted) return error.Aborted; // errdefer 释放 out/err（勿显式 deinit → 双 free）
    if (timed_out and !opts.timeout_partial) return error.Timeout;
    return .{
        .stdout = try out.toOwnedSlice(allocator),
        .stderr = try err.toOwnedSlice(allocator),
        .exit_code = @bitCast(code),
        .timed_out = timed_out,
        .capture_complete = !capped.load(.acquire) and !timed_out,
    };
}

/// argv(UTF-8 C 串) → Windows 命令行 UTF-16(带标准 quoting)。
/// argv → 整条 WTF-16 命令行(CreateProcessW 参数形式;引号规则与 CommandLineToArgvW 往返一致)。
///
/// ⚠️ 本函数含 **exec 语义变换**,不是通用 argv→cmdline 序列化:
///   ① 剥离 "/usr/bin/env" 前缀(翻译成 CreateProcessW 原生 PATH 搜索);
///   ② argv[0] 正斜杠→反斜杠(CreateProcessW 不认相对路径正斜杠,实测 ERROR_FILE_NOT_FOUND)。
/// pub 消费方 parseArgsForTest 依赖"argv[0] 恒为裸名(如 \"metacodes\")"这一前提——
/// 若未来测试 argv[0] 含 '/' 或为 env,请改用纯 quoting 变体而非静默吞变换(review F9)。
pub fn buildWindowsCmdline(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8) ![:0]u16 {
    var u8buf = std.ArrayList(u8).empty;
    defer u8buf.deinit(allocator);
    // "/usr/bin/env prog args" 的语义 = 按 PATH 解析 prog 再 exec——CreateProcessW 原生就
    // 按 PATH 搜索模块。POSIX 调用方统一用 env 前缀,Windows 后端在此剥掉,免得每个
    // 调用点各写一份 if(windows)。注意:不支持 `env KEY=VAL prog` 形态(仓内无此用法)。
    var args = argv;
    if (args.len > 0) {
        if (args[0]) |a0| {
            if (std.mem.eql(u8, std.mem.span(a0), "/usr/bin/env")) args = args[1..];
        }
    }
    var first = true;
    for (args) |a_opt| {
        const a = a_opt orelse break;
        if (!first) try u8buf.append(allocator, ' ');
        if (first) {
            // argv[0](模块路径)正斜杠 → 反斜杠:CreateProcessW 对**相对路径**里的
            // 正斜杠直接 ERROR_FILE_NOT_FOUND(ctypes 实测;绝对路径两种都认)。
            // POSIX 风格相对路径("zig-out/bin/x")是跨平台调用方的常态,平台层归一。
            var norm_buf: [std.fs.max_path_bytes]u8 = undefined;
            const span = std.mem.span(a);
            if (span.len <= norm_buf.len and std.mem.indexOfScalar(u8, span, '/') != null) {
                for (span, 0..) |c, i| norm_buf[i] = if (c == '/') '\\' else c;
                try appendQuotedArg(allocator, &u8buf, norm_buf[0..span.len]);
            } else {
                try appendQuotedArg(allocator, &u8buf, span);
            }
            first = false;
            continue;
        }
        try appendQuotedArg(allocator, &u8buf, std.mem.span(a));
    }
    return try std.unicode.utf8ToUtf16LeAllocZ(allocator, u8buf.items);
}

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
// Tests
// ============================================================================

// 这 2 个测试 fork 真子进程。`zig build test` 的并行多-binary runner 下 fork 会崩
// (与其它并行 test binary 争 stdout/资源);standalone `zig test` 与 CI 专用 job 都正常。
// 故 env-gate:默认 skip，CI（cross-platform.yml 设 METACODES_PROC_TEST=1）与手动跑时启用。
fn procSpawnTestsEnabled() bool {
    return std.c.getenv("METACODES_PROC_TEST") != null;
}

test "capture stdout+stderr 分别捕获" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo out-line & echo err-line 1>&2", null }
    else
        &.{ "/bin/sh", "-c", "echo out-line; echo err-line 1>&2", null };
    const r = try capture(argv, a, .{ .timeout_ms = 10_000 });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "out-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "err-line") != null);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
}

test "captureStdout 便捷+非零 exit" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo hi & exit 3", null }
    else
        &.{ "/bin/sh", "-c", "echo hi; exit 3", null };
    const r = try captureStdout(argv, a, 10_000, 1 << 20);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hi") != null);
    try std.testing.expectEqual(@as(i32, 3), r.exit_code);
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len); // want_stderr=false
}

test "capturePosix drains short-lived stdout after pipe hangup" {
    if (is_windows or !procSpawnTestsEnabled()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const argv: []const ?[*:0]const u8 =
        &.{ "/bin/sh", "-c", "printf hup-drained", null };
    const result = try captureStdout(argv, allocator, 1_000, 1 << 20);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqualStrings("hup-drained", result.stdout);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
}

test "capture stdin_data 喂入子进程 stdin" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    // 子进程回显 stdin：POSIX cat / Windows more。
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "more", null }
    else
        &.{ "/bin/sh", "-c", "cat", null };
    const r = try capture(argv, a, .{ .stdin_data = "piped-input-42\n", .want_stderr = false, .timeout_ms = 10_000 });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "piped-input-42") != null);
}

test "capture cwd:子进程 pwd 在指定 cwd 而非父进程 cwd" {
    // 缺陷 B 回归测试:capture opts.cwd 非 null → 子进程 chdir 后再 exec。
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    // 选一个肯定存在、非当前 cwd 的目录:/tmp(POSIX) 或 %SystemRoot%(Windows)。
    var target_dir_owned: ?[]u8 = null;
    const target_dir: []const u8 = if (is_windows) blk: {
        target_dir_owned = (std.process.Environ{ .block = .global }).getAlloc(a, "SystemRoot") catch null;
        break :blk target_dir_owned orelse "C:\\Windows";
    } else "/tmp";
    defer if (target_dir_owned) |value| a.free(value);
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "cd", null }
    else
        &.{ "/bin/sh", "-c", "pwd", null };
    const r = try capture(argv, a, .{ .cwd = target_dir, .want_stderr = false, .timeout_ms = 10_000 });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    // Windows `cmd /c cd` may normalize drive-letter case and append a
    // trailing separator. Compare the canonical text case-insensitively after
    // trimming those presentation differences.
    const observed = std.mem.trim(u8, r.stdout, " \r\n");
    if (is_windows) {
        const expected = std.mem.trim(u8, target_dir, "\\/");
        try std.testing.expect(std.ascii.eqlIgnoreCase(observed, expected));
    } else {
        // 保留前导 '/' 锚定路径边界:macOS chdir("/tmp") 解析符号链接后 pwd 打
        // /private/tmp,endsWith("/tmp") 仍成立;裸 "tmp" 子串任何含 tmp 的 cwd
        // 都能满足,会漏掉 chdir 回归。
        try std.testing.expect(std.mem.endsWith(u8, observed, target_dir));
    }
}

/// Per-process scratch path for the vanishing-cwd tests: `<tmp>/metacodes-proc-<pid>-<name>`.
fn testScratchPath(a: std.mem.Allocator, buf: []u8, name: []const u8) ![:0]const u8 {
    var root_owned: ?[]u8 = null;
    defer if (root_owned) |r| a.free(r);
    const root: []const u8 = if (is_windows) blk: {
        root_owned = (std.process.Environ{ .block = .global }).getAlloc(a, "TEMP") catch null;
        break :blk root_owned orelse "C:\\Windows\\Temp";
    } else "/tmp";
    return std.fmt.bufPrintZ(buf, "{s}/metacodes-proc-{d}-{s}", .{ root, currentPid(), name });
}

/// A directory that really existed and then went away — what an agent does
/// to its own cwd when it renames or removes it mid-session.
fn testVanishedDir(a: std.mem.Allocator, buf: []u8, name: []const u8) ![:0]const u8 {
    const dir = try testScratchPath(a, buf, name);
    _ = std.c.mkdir(dir.ptr, 0o700);
    if (std.c.rmdir(dir.ptr) != 0) return error.TestScratchDirNotRemovable;
    return dir;
}

test "capture: cwd 在 spawn 前消失 → ChildChdirFailed 带原因,不再伪装成 exit 127" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testVanishedDir(a, &dir_buf, "vanished-cwd");
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo still-ran", null }
    else
        &.{ "/bin/sh", "-c", "echo still-ran", null };
    try std.testing.expectError(error.ChildChdirFailed, capture(argv, a, .{ .cwd = dir, .timeout_ms = 10_000 }));
    const failure = takeLastSpawnFailure() orelse return error.TestExpectedSpawnFailure;
    try std.testing.expectEqual(SpawnStep.chdir, failure.step);
    var code_buf: [32]u8 = undefined;
    if (!is_windows) {
        try std.testing.expectEqual(@as(i32, @intFromEnum(std.c.E.NOENT)), failure.code);
        try std.testing.expectEqualStrings("ENOENT", failure.describeCode(&code_buf));
    }
    // 取过一次即清空:下一次 spawn 的失败不会被旧记录冒充。
    try std.testing.expect(takeLastSpawnFailure() == null);
}

test "capture: 程序不存在 → ChildExecFailed(ENOENT),而不是 exit 127 双空流" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "C:\\metacodes-no-such-program.exe", null }
    else
        &.{ "/metacodes-no-such-program", null };
    try std.testing.expectError(error.ChildExecFailed, capture(argv, a, .{ .timeout_ms = 10_000 }));
    const failure = takeLastSpawnFailure() orelse return error.TestExpectedSpawnFailure;
    try std.testing.expectEqual(SpawnStep.exec, failure.step);
    if (!is_windows) try std.testing.expectEqual(@as(i32, @intFromEnum(std.c.E.NOENT)), failure.code);
}

test "capture: 成功的 spawn 不留下上一次的失败记录" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    const bad: []const ?[*:0]const u8 = if (is_windows)
        &.{ "C:\\metacodes-no-such-program.exe", null }
    else
        &.{ "/metacodes-no-such-program", null };
    try std.testing.expectError(error.ChildExecFailed, capture(bad, a, .{ .timeout_ms = 10_000 }));
    // 故意不 take:下一次成功的 spawn 必须自己清掉它。
    const good: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo fine", null }
    else
        &.{ "/bin/sh", "-c", "echo fine", null };
    const r = try capture(good, a, .{ .timeout_ms = 10_000 });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
    try std.testing.expect(takeLastSpawnFailure() == null);
}

test "spawnPipes / spawnToFiles: 同一条报告通道,cwd 消失同样返 ChildChdirFailed" {
    if (is_windows or !procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testVanishedDir(a, &dir_buf, "vanished-cwd-2");
    const argv: []const ?[*:0]const u8 = &.{ "/bin/sh", "-c", "echo still-ran", null };
    try std.testing.expectError(error.ChildChdirFailed, spawnPipes(argv, true, dir));
    try std.testing.expectEqual(SpawnStep.chdir, (takeLastSpawnFailure() orelse return error.TestExpectedSpawnFailure).step);
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(devnull >= 0);
    defer _ = std.c.close(devnull);
    try std.testing.expectError(error.ChildChdirFailed, spawnToFiles(argv, devnull, devnull, dir));
    try std.testing.expectEqual(SpawnStep.chdir, (takeLastSpawnFailure() orelse return error.TestExpectedSpawnFailure).step);
}

test "runInherit / spawnDetached: 程序不存在 → ChildExecFailed(同一条报告通道)" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const bad: []const ?[*:0]const u8 = if (is_windows)
        &.{ "C:\\metacodes-no-such-program.exe", null }
    else
        &.{ "/metacodes-no-such-program", null };
    try std.testing.expectError(error.ChildExecFailed, runInherit(bad, true));
    try std.testing.expectEqual(SpawnStep.exec, (takeLastSpawnFailure() orelse return error.TestExpectedSpawnFailure).step);
    try std.testing.expectError(error.ChildExecFailed, spawnDetached(bad, true));
    try std.testing.expectEqual(SpawnStep.exec, (takeLastSpawnFailure() orelse return error.TestExpectedSpawnFailure).step);
}

test "capture: 父进程 fd 1/2 已关闭时,子进程 stdout/stderr 接线仍正确(codex R1 #1)" {
    // 关掉 1/2 会毁掉测试进程自己的输出,所以在 fork 出来的副本里做:副本关 1/2、走一次
    // capture、把结果经管道交回。父进程关着 stdio 时 pipe() 会把 1/2 发回来,子进程
    // dup2(2, 1) 之后再 close(out_pipe[1]=2) 就把刚接好的 stderr 关掉了——err-line 丢失。
    if (is_windows or !procSpawnTestsEnabled()) return error.SkipZigTest;
    var result_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expect(std.c.pipe(&result_pipe) == 0);
    const helper = std.c.fork();
    try std.testing.expect(helper >= 0);
    if (helper == 0) {
        _ = std.c.close(result_pipe[0]);
        _ = std.c.close(1);
        _ = std.c.close(2);
        const argv: []const ?[*:0]const u8 = &.{ "/bin/sh", "-c", "echo out-line; echo err-line 1>&2", null };
        const r = capture(argv, std.heap.page_allocator, .{ .timeout_ms = 10_000 }) catch {
            _ = std.c.write(result_pipe[1], "spawn-error", 11);
            std.c._exit(0);
        };
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "out={d} err={d} code={d}", .{
            @intFromBool(std.mem.indexOf(u8, r.stdout, "out-line") != null),
            @intFromBool(std.mem.indexOf(u8, r.stderr, "err-line") != null),
            r.exit_code,
        }) catch "fmt";
        _ = std.c.write(result_pipe[1], msg.ptr, msg.len);
        std.c._exit(0);
    }
    _ = std.c.close(result_pipe[1]);
    var buf: [128]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(result_pipe[0], buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = std.c.close(result_pipe[0]);
    var st: c_int = 0;
    _ = std.c.waitpid(helper, &st, 0);
    try std.testing.expectEqualStrings("out=1 err=1 code=0", buf[0..total]);
}

/// 测试助手:在 fork 出来的副本里把结论写回父进程后退出。
fn reportAndExit(fd: std.c.fd_t, msg: []const u8) noreturn {
    _ = std.c.write(fd, msg.ptr, msg.len);
    std.c._exit(0);
}

/// 两个 fd 是否指向同一个文件对象(dev+ino)。走 platform/fs.fileInfo:`std.c.fstat` 在
/// Linux 目标上是 void(glibc 的 fstat 不是导出符号),直接调会在 Linux CI 上编译失败。
fn sameFile(a: std.c.fd_t, b: std.c.fd_t) bool {
    const pfs = @import("fs.zig");
    const ia = pfs.fileInfo(a) catch return false;
    const ib = pfs.fileInfo(b) catch return false;
    return ia.inode == ib.inode and ia.device == ib.device;
}

/// 读回副本写的结论。
fn readHelperReport(fd: std.c.fd_t, buf: []u8) []const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return buf[0..total];
}

test "applyStdioWiring: stdio 全关时的重复低位源({0, hi, 0})各自抬起,接线正确(codex R2 #1)" {
    if (is_windows or !procSpawnTestsEnabled()) return error.SkipZigTest;
    var result_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expect(std.c.pipe(&result_pipe) == 0);
    const helper = std.c.fork();
    try std.testing.expect(helper >= 0);
    if (helper == 0) {
        _ = std.c.close(result_pipe[0]);
        _ = std.c.close(0);
        _ = std.c.close(1);
        _ = std.c.close(2);
        // 0/1/2 空着:pipe() 拿到 {0,1},open 拿到 2,再 open 一次拿一个 ≥3 的源。
        var a: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&a) != 0) reportAndExit(result_pipe[1], "pipe-failed");
        const two = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        const hi = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (!(a[0] == 0 and a[1] == 1 and two == 2 and hi >= 3)) reportAndExit(result_pipe[1], "layout-unexpected");
        // 探针:各源的高位副本(接线会覆盖/关掉原 fd)。
        const probe_pipe = std.c.dup(a[0]);
        const probe_hi = std.c.dup(hi);
        _ = std.c.close(two); // 槽位 2 空出来
        if (!applyStdioWiring(.{ a[0], hi, a[0] })) reportAndExit(result_pipe[1], "wiring-returned-false");
        // 0 与 2 都应是管道读端,1 应是 /dev/null。
        if (!sameFile(0, probe_pipe) or !sameFile(2, probe_pipe) or !sameFile(1, probe_hi)) reportAndExit(result_pipe[1], "miswired");
        reportAndExit(result_pipe[1], "ok");
    }
    _ = std.c.close(result_pipe[1]);
    var buf: [64]u8 = undefined;
    const got = readHelperReport(result_pipe[0], &buf);
    _ = std.c.close(result_pipe[0]);
    var st: c_int = 0;
    _ = std.c.waitpid(helper, &st, 0);
    try std.testing.expectEqualStrings("ok", got);
}

test "applyStdioWiring: 低位源抬不起来(RLIMIT_NOFILE 收紧 → EMFILE)→ 返回 false,不半接(codex R2 #2)" {
    if (is_windows or !procSpawnTestsEnabled()) return error.SkipZigTest;
    var result_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expect(std.c.pipe(&result_pipe) == 0);
    const helper = std.c.fork();
    try std.testing.expect(helper >= 0);
    if (helper == 0) {
        _ = std.c.close(result_pipe[0]);
        _ = std.c.close(0);
        var a: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&a) != 0 or a[0] != 0) reportAndExit(result_pipe[1], "layout-unexpected");
        // 探针 = 读端自己的副本(同一个打开文件描述;写端在 macOS 上是另一个 inode,不能当探针),
        // 必须在收紧 rlimit 之前 dup。
        const probe_pipe = std.c.dup(a[0]);
        if (probe_pipe < 3) reportAndExit(result_pipe[1], "probe-failed");
        // pipe()/dup() 各取最低空闲 fd,所以 [3, probe] 此刻全被占着;把软上限设成 probe+1,
        // F_DUPFD_CLOEXEC(3) 在上限内找不到空位 → EMFILE(上限设成 3 会因 arg ≥ 上限而返 EINVAL,
        // 测的就不是"没 fd 可用"了)。已开着的 fd 照常可用。
        var rl: std.c.rlimit = undefined;
        if (std.c.getrlimit(.NOFILE, &rl) != 0) reportAndExit(result_pipe[1], "getrlimit-failed");
        rl.cur = @intCast(probe_pipe + 1);
        if (std.c.setrlimit(.NOFILE, &rl) != 0) reportAndExit(result_pipe[1], "setrlimit-failed");
        if (applyStdioWiring(.{ a[0], -1, -1 })) reportAndExit(result_pipe[1], "wiring-returned-true");
        const e = std.c.errno(@as(c_int, -1)); // 紧接着读,后面的 fstat 会盖掉它
        // 失败时一个槽都不接:0 仍是那条管道的读端,且 errno 说明原因。
        if (!sameFile(0, probe_pipe)) reportAndExit(result_pipe[1], "slot-touched");
        if (e != .MFILE and e != .NFILE) reportAndExit(result_pipe[1], "unexpected-errno");
        reportAndExit(result_pipe[1], "ok");
    }
    _ = std.c.close(result_pipe[1]);
    var buf: [64]u8 = undefined;
    const got = readHelperReport(result_pipe[0], &buf);
    _ = std.c.close(result_pipe[0]);
    var st: c_int = 0;
    _ = std.c.waitpid(helper, &st, 0);
    try std.testing.expectEqualStrings("ok", got);
}

test "capture 超时返 error.Timeout（有缓冲输出，验不 double-free）" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const a = std.testing.allocator; // testing.allocator 会捕获 double-free/leak
    // 先产出 "before"（进 out 缓冲）再长眠 → 400ms 超时命中带数据的 timeout 路径。
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo before& ping -n 12 127.0.0.1 >nul", null }
    else
        &.{ "/bin/sh", "-c", "echo before; sleep 10", null };
    try std.testing.expectError(error.Timeout, capture(argv, a, .{ .timeout_ms = 400 }));
}

test "spawnPipes 双向 echo（写 stdin 读回 stdout）" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "more", null }
    else
        &.{ "/bin/sh", "-c", "cat", null };
    const child = try spawnPipes(argv, true, null);
    const msg = "ping-pong-99\n";
    _ = child.write(msg);
    child.closeStdin(); // EOF → cat/more 回显后退出
    var buf: [128]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = child.read(buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    child.closeStdout();
    child.terminate();
    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "ping-pong-99") != null);
}

test "runInherit 返回 exit code" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "exit 7", null }
    else
        &.{ "/bin/sh", "-c", "exit 7", null };
    try std.testing.expectEqual(@as(i32, 7), try runInherit(argv, true));
}

test "spawnDetached 不阻塞不报错" {
    if (!procSpawnTestsEnabled()) return error.SkipZigTest;
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "exit 0", null }
    else
        &.{ "/bin/sh", "-c", "true", null };
    try spawnDetached(argv, true);
}

test "buildWindowsCmdline quoting" {
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = &.{ "prog", "a b", "c\"d", null };
    const w = try buildWindowsCmdline(a, argv);
    defer a.free(w);
    const u8out = try std.unicode.utf16LeToUtf8Alloc(a, w);
    defer a.free(u8out);
    try std.testing.expectEqualStrings("prog \"a b\" \"c\\\"d\"", u8out);
}

test "buildWindowsCmdline: env 前缀剥离 + argv0 正斜杠归一(非 argv0 参数不动)" {
    const a = std.testing.allocator;
    const argv: []const ?[*:0]const u8 = &.{ "/usr/bin/env", "zig-out/bin/tool", "arg/with/slash", null };
    const w = try buildWindowsCmdline(a, argv);
    defer a.free(w);
    const u8out = try std.unicode.utf16LeToUtf8Alloc(a, w);
    defer a.free(u8out);
    try std.testing.expectEqualStrings("zig-out\\bin\\tool arg/with/slash", u8out);
}
