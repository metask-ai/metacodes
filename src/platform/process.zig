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

pub const CaptureError = error{ SpawnFailed, PipeFailed, ReadError, OutOfMemory, Aborted, Timeout };

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
    // 超时(非 timeout_partial) → error.Timeout；abort → error.Aborted；cap 命中 → Ok（返部分，进程已 kill）。
};

/// spawn argv、抽干 stdout[+stderr]、返回结果。timeout_ms==0 无超时。
pub fn capture(argv: []const ?[*:0]const u8, allocator: std.mem.Allocator, opts: CaptureOpts) CaptureError!Captured {
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
    if (is_windows) {
        const a = std.heap.page_allocator;
        const cmdline = buildWindowsCmdline(a, argv) catch return error.SpawnFailed;
        defer a.free(cmdline);
        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW); // 不设 USESTDHANDLES → 子进程继承本进程 console
        var pi = std.mem.zeroes(win.PROCESS.INFORMATION);
        if (win.kernel32.CreateProcessW(null, cmdline.ptr, null, null, @enumFromInt(0), .{}, null, null, &si, &pi) == .FALSE) return error.SpawnFailed;
        _ = WaitForSingleObject(pi.hProcess, INFINITE);
        var code: win.DWORD = 0;
        _ = GetExitCodeProcess(pi.hProcess, &code);
        win.CloseHandle(pi.hProcess);
        win.CloseHandle(pi.hThread);
        return @bitCast(code);
    }
    const pid = std.c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        const argv0 = argv[0] orelse std.c._exit(127);
        const envp: [*:null]const ?[*:0]const u8 = if (inherit_env) @ptrCast(std.c.environ) else &.{null};
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), envp);
        std.c._exit(127);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return posixExitCode(status);
}

/// spawn argv、**detached**（关闭 stdio、不等待，fire-and-forget，如打开浏览器）。
/// POSIX：fork+setpgid+close(0/1/2)+execve，父不 waitpid；Windows：CreateProcessW(DETACHED_PROCESS)。
pub fn spawnDetached(argv: []const ?[*:0]const u8, inherit_env: bool) CaptureError!void {
    if (is_windows) {
        const a = std.heap.page_allocator;
        const cmdline = buildWindowsCmdline(a, argv) catch return error.SpawnFailed;
        defer a.free(cmdline);
        var si = std.mem.zeroes(win.STARTUPINFOW);
        si.cb = @sizeOf(win.STARTUPINFOW);
        var pi = std.mem.zeroes(win.PROCESS.INFORMATION);
        if (win.kernel32.CreateProcessW(null, cmdline.ptr, null, null, @enumFromInt(0), .{ .detached_process = true }, null, null, &si, &pi) == .FALSE) return error.SpawnFailed;
        win.CloseHandle(pi.hProcess);
        win.CloseHandle(pi.hThread);
        return;
    }
    const pid = std.c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(0);
        _ = std.c.close(1);
        _ = std.c.close(2);
        const argv0 = argv[0] orelse std.c._exit(127);
        const envp: [*:null]const ?[*:0]const u8 = if (inherit_env) @ptrCast(std.c.environ) else &.{null};
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), envp);
        std.c._exit(127);
    }
    // 父：fire-and-forget，不 waitpid（对齐原 openBrowser）。
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
                _ = std.c.waitpid(self.proc, &status, 0);
            }
        }
    }
};

/// spawn 长连接子进程，返回持久 stdin(父写)/stdout(父读) 端点。stderr 丢弃（→null/NUL）。
pub fn spawnPipes(argv: []const ?[*:0]const u8, inherit_env: bool, cwd: ?[]const u8) CaptureError!PipeChild {
    if (is_windows) return spawnPipesWindows(argv, cwd);
    return spawnPipesPosix(argv, inherit_env, cwd);
}

fn spawnPipesPosix(argv: []const ?[*:0]const u8, inherit_env: bool, cwd: ?[]const u8) CaptureError!PipeChild {
    var in_pipe: [2]std.c.fd_t = undefined; // 父写 → 子读
    var out_pipe: [2]std.c.fd_t = undefined; // 子写 → 父读
    if (std.c.pipe(&in_pipe) != 0) return error.PipeFailed;
    if (std.c.pipe(&out_pipe) != 0) {
        _ = std.c.close(in_pipe[0]);
        _ = std.c.close(in_pipe[1]);
        return error.PipeFailed;
    }
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(in_pipe[0]);
        _ = std.c.close(in_pipe[1]);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.dup2(in_pipe[0], 0);
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.close(in_pipe[0]);
        _ = std.c.close(in_pipe[1]);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 2);
            if (devnull != 2) _ = std.c.close(devnull);
        }
        // 缺陷 B 修复:子进程 chdir。
        if (!chdirChild(cwd)) std.c._exit(127);
        const argv0 = argv[0] orelse std.c._exit(127);
        const envp: [*:null]const ?[*:0]const u8 = if (inherit_env) @ptrCast(std.c.environ) else &.{null};
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), envp);
        std.c._exit(127);
    }
    _ = std.c.close(in_pipe[0]); // 父不读 stdin pipe
    _ = std.c.close(out_pipe[1]); // 父不写 stdout pipe
    _ = std.c.setpgid(pid, pid);
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
    win.CloseHandle(in_rd); // 父端关子进程侧
    win.CloseHandle(out_wr);
    g_spawn_serial.unlock(); // 可继承句柄的父端副本已全关
    spawn_locked = false;
    if (created == .FALSE) {
        win.CloseHandle(in_wr);
        win.CloseHandle(out_rd);
        return error.SpawnFailed;
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
        _ = SetHandleInformation(out_h, HANDLE_FLAG_INHERIT, 0);
        _ = SetHandleInformation(err_h, HANDLE_FLAG_INHERIT, 0);
        g_spawn_serial.unlock();
        if (created == .FALSE) return error.SpawnFailed;
        win.CloseHandle(pi.hThread);
        return pi.hProcess;
    }
    const pid = std.c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.dup2(out_fd, 1);
        _ = std.c.dup2(err_fd, 2);
        _ = std.c.close(out_fd);
        _ = std.c.close(err_fd);
        // 缺陷 B 修复:子进程 chdir。
        if (!chdirChild(cwd)) std.c._exit(127);
        const argv0 = argv[0] orelse std.c._exit(127);
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    _ = std.c.setpgid(pid, pid);
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
        var status: c_int = 0;
        _ = std.c.waitpid(h, &status, 0);
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
/// 成功返 true;失败或 cwd 过长返 false(调用方 _exit(127))。
/// 三处 spawn 原语共用,避免 7 行代码重复(Linus R2)。
fn chdirChild(cwd: ?[]const u8) bool {
    const c = cwd orelse return true;
    if (c.len >= std.fs.max_path_bytes) return false;
    var cwd_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(cwd_z[0..c.len], c);
    cwd_z[c.len] = 0;
    return std.c.chdir(&cwd_z) == 0;
}

fn capturePosix(argv: []const ?[*:0]const u8, allocator: std.mem.Allocator, opts: CaptureOpts) CaptureError!Captured {
    var out_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&out_pipe) != 0) return error.PipeFailed;
    var err_pipe: [2]std.c.fd_t = .{ -1, -1 };
    if (opts.want_stderr) {
        if (std.c.pipe(&err_pipe) != 0) {
            _ = std.c.close(out_pipe[0]);
            _ = std.c.close(out_pipe[1]);
            return error.PipeFailed;
        }
    }
    var in_pipe: [2]std.c.fd_t = .{ -1, -1 };
    if (opts.stdin_data != null) {
        if (std.c.pipe(&in_pipe) != 0) {
            _ = std.c.close(out_pipe[0]);
            _ = std.c.close(out_pipe[1]);
            if (opts.want_stderr) {
                _ = std.c.close(err_pipe[0]);
                _ = std.c.close(err_pipe[1]);
            }
            return error.PipeFailed;
        }
    }

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        if (opts.want_stderr) {
            _ = std.c.close(err_pipe[0]);
            _ = std.c.close(err_pipe[1]);
        }
        if (opts.stdin_data != null) {
            _ = std.c.close(in_pipe[0]);
            _ = std.c.close(in_pipe[1]);
        }
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.dup2(out_pipe[1], 1);
        if (opts.stdin_data != null) {
            _ = std.c.close(in_pipe[1]);
            _ = std.c.dup2(in_pipe[0], 0);
            _ = std.c.close(in_pipe[0]);
        }
        if (opts.want_stderr) {
            _ = std.c.close(err_pipe[0]);
            _ = std.c.dup2(err_pipe[1], 2);
            _ = std.c.close(err_pipe[1]);
        } else {
            const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
            if (devnull >= 0) {
                _ = std.c.dup2(devnull, 2);
                if (devnull != 2) _ = std.c.close(devnull);
            }
        }
        _ = std.c.close(out_pipe[1]);
        // 缺陷 B 修复:子进程 chdir(仅影响本子进程,父进程 cwd 不变)。
        if (!chdirChild(opts.cwd)) std.c._exit(127);
        const argv0 = argv[0] orelse std.c._exit(127);
        const envp: [*:null]const ?[*:0]const u8 = if (opts.inherit_env) @ptrCast(std.c.environ) else &.{null};
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), envp);
        std.c._exit(127);
    }

    _ = std.c.close(out_pipe[1]);
    if (opts.want_stderr) _ = std.c.close(err_pipe[1]);
    _ = std.c.setpgid(pid, pid);

    // 喂 stdin（小数据：先写完再 drain）。SIGPIPE 全局忽略 → 子进程早退时 write 返 EPIPE 不杀本进程。
    if (opts.stdin_data) |data| {
        _ = std.c.close(in_pipe[0]);
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
    const label = labelOf(argv);

    while (!(out_done and err_done)) {
        if (opts.abort_poll) |poll| if (poll(opts.abort_ctx)) {
            killGroupPosix(pid);
            _ = std.c.close(out_pipe[0]);
            if (opts.want_stderr) _ = std.c.close(err_pipe[0]);
            var st: c_int = 0;
            _ = std.c.waitpid(pid, &st, 0);
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
            break;
        }
    }
    _ = std.c.close(out_pipe[0]);
    if (opts.want_stderr) _ = std.c.close(err_pipe[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    if (timed_out and !opts.timeout_partial) return error.Timeout; // errdefer 释放 out/err（勿显式 deinit → 双 free）
    return .{
        .stdout = try out.toOwnedSlice(allocator),
        .stderr = try err.toOwnedSlice(allocator),
        .exit_code = posixExitCode(status),
        .timed_out = timed_out,
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
        return error.SpawnFailed;
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
    // 选一个肯定存在、非当前 cwd 的目录:/tmp(POSIX) 或 %TEMP%(Windows)。
    const target_dir: []const u8 = if (is_windows) std.process.getEnvVarOwned(a, "TEMP") catch "/Temp" else "/tmp";
    defer if (is_windows) a.free(target_dir);
    const argv: []const ?[*:0]const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "cd", null }
    else
        &.{ "/bin/sh", "-c", "pwd", null };
    const r = try capture(argv, a, .{ .cwd = target_dir, .want_stderr = false, .timeout_ms = 10_000 });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    // stdout 应含 target_dir(子进程在 target_dir 下跑 pwd)。
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, target_dir) != null);
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
