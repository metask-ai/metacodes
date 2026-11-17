//! W4 可移植信号/中断（跨平台移植 roadmap，tinykg node 8869）。
//!
//! POSIX 用 `std.posix.sigaction`；Windows 无 POSIX 信号，改用：
//! - broken-pipe：Windows 无 SIGPIPE（socket 写返 WSAECONNRESET，各处 n<=0 分支已处理）→ no-op。
//! - Ctrl+C：`SetConsoleCtrlHandler`（CTRL_C_EVENT / CTRL_BREAK_EVENT）。
//! - 窗口 resize：Windows 无 SIGWINCH；resize 走 ConsoleInput 的 WINDOW_BUFFER_SIZE_EVENT
//!   （归 W4 终端模块）→ 此处 no-op（登记）。
//!
//! 中立 API 收 async-signal-safe 无副作用回调（只做 atomic store / abort）。POSIX 的
//! `std.posix.SIG` 签名细节锁在本模块的 comptime 分支内（comptime-known `is_windows` 使
//! Zig 惰性只分析选中分支，未选分支的 `std.c.*`/`std.posix.*` 不会在异平台被分析——已由
//! platform/fs.zig 交叉编译证实）。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;

/// 本进程是否声明了"SIGPIPE 恒忽略"(ignoreBrokenPipe 置位)。threadedIo 据此撤掉
/// std.Io.Threaded 装的空 SIGPIPE 处理器。库被宿主嵌入时宿主不调 ignoreBrokenPipe,
/// 信号策略归宿主,threadedIo 的行为与 std 一致。
var g_keep_broken_pipe_ignored = std.atomic.Value(bool).init(false);

/// 忽略 broken-pipe（向已关闭 pipe/socket 写不杀进程）,并声明本进程恒如此:之后经
/// threadedIo 创建的 std.Io.Threaded 不再把它换成处理器。Windows no-op。
pub fn ignoreBrokenPipe() void {
    if (is_windows) return;
    g_keep_broken_pipe_ignored.store(true, .release);
    setBrokenPipe(.{ .handler = std.posix.SIG.IGN });
}

/// 子进程侧(fork 之后、execve 之前):把 SIGPIPE 恢复为默认。exec 会把**捕获**的信号复位为
/// 默认,但**被忽略**的信号原样继承——父进程恒忽略 SIGPIPE,不复位的话子进程(以及它管道里的
/// `yes`/`cat`)写已关闭管道时不会被 SIGPIPE 正常结束,而是拿 EPIPE 报错。只调 sigaction
/// (async-signal-safe),不分配。Windows no-op。
pub fn defaultBrokenPipeInChild() void {
    if (is_windows) return;
    setBrokenPipe(.{ .handler = std.posix.SIG.DFL });
}

fn setBrokenPipe(handler: @FieldType(std.posix.Sigaction, "handler")) void {
    const act: std.posix.Sigaction = .{
        .handler = handler,
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

/// 创建 `std.Io.Threaded` 的唯一入口(仓库内不直接调 `std.Io.Threaded.init`,
/// scripts/tests/test_io_threaded_discipline.py 检查)。
///
/// std 的 init 把 SIGPIPE 换成一个空处理器(flags=0,无 SA_RESTART),deinit 再还原它 init 时
/// 看到的旧值。处理器与 SIG_IGN 的区别是信号会被**投递**:macOS 上向已关闭 socket 的写把
/// SIGPIPE 发给整个进程,任一线程阻塞中的 recv/poll/accept/waitpid 都可能因此返回 EINTR
/// (kg 自启探测曾把它当成"无应答";web server 把 recv<=0 当请求结束,会丢请求)。多个实例的
/// init/deinit 交错时,最后留下的还可能是别的实例的处理器。
///
/// 本进程声明了恒忽略(ignoreBrokenPipe)或这是测试二进制时,这里在 init 后立刻把 SIGPIPE
/// 设回 SIG_IGN,并把实例记下的"旧值"也换成 SIG_IGN,所以 deinit 还原出来的仍是 SIG_IGN。
/// SIGIO 处理器(取消机制靠它打断阻塞调用)原样保留。子进程在 exec 前经
/// defaultBrokenPipeInChild 恢复默认 SIGPIPE。
///
/// Pool workers get `thread.Stack.io_worker` (#503): std's default stack is a
/// 16 MiB commit per worker on Windows, held for the Io's whole life. A caller
/// that needs another size states it in `options.stack_size`; std's default is
/// the one size this cannot be asked for, so work that needs a `full` stack
/// runs on a `thread.spawn(.full, ...)` thread, not in an Io task.
pub fn threadedIo(gpa: std.mem.Allocator, options: std.Io.Threaded.InitOptions) std.Io.Threaded {
    var stated = options;
    if (stated.stack_size == std.Thread.SpawnConfig.default_stack_size)
        stated.stack_size = @import("thread.zig").Stack.io_worker.bytes();
    var threaded = std.Io.Threaded.init(gpa, stated);
    if (builtin.is_test or g_keep_broken_pipe_ignored.load(.acquire)) keepBrokenPipeIgnored(&threaded);
    return threaded;
}

comptime {
    // threadedIo 依赖这两个字段的语义;std 改了它们就得重新审视这里,而不是静默失效。
    if (!@hasField(std.Io.Threaded, "old_sig_pipe") or !@hasField(std.Io.Threaded, "have_signal_handler"))
        @compileError("std.Io.Threaded no longer records old_sig_pipe/have_signal_handler: revisit threadedIo");
}

fn keepBrokenPipeIgnored(threaded: *std.Io.Threaded) void {
    // 没有 SIGPIPE 的目标(Windows)上该字段是 void,std 也不装处理器。
    if (comptime @FieldType(std.Io.Threaded, "old_sig_pipe") == void) return;
    if (!threaded.have_signal_handler) return;
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    threaded.old_sig_pipe = ignore;
}

// ── Windows console ctrl handler（kernel32 未在 std 绑定，自 extern）─────────────
const CTRL_C_EVENT: win.DWORD = 0;
const CTRL_BREAK_EVENT: win.DWORD = 1;
extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const fn (win.DWORD) callconv(.winapi) win.BOOL,
    Add: win.BOOL,
) callconv(.winapi) win.BOOL;

/// 安装 Ctrl+C（中断）回调。POSIX=SIGINT sigaction；Windows=SetConsoleCtrlHandler。
/// `callback` 必须 async-signal-safe（POSIX 在信号上下文调用；Windows 在独立 handler 线程）。
pub fn installInterrupt(comptime callback: fn () void) void {
    if (is_windows) {
        const W = struct {
            fn ctrl(ctrl_type: win.DWORD) callconv(.winapi) win.BOOL {
                if (ctrl_type == CTRL_C_EVENT or ctrl_type == CTRL_BREAK_EVENT) {
                    callback();
                    return .TRUE;
                }
                return .FALSE;
            }
        };
        _ = SetConsoleCtrlHandler(W.ctrl, .TRUE);
    } else {
        const P = struct {
            fn h(_: std.posix.SIG) callconv(.c) void {
                callback();
            }
        };
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = P.h },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
}

/// 安装终止回调：POSIX=SIGTERM + SIGHUP（后台服务被 kill、登出、所在会话结束），
/// Windows=控制台关闭/注销/关机事件。与 `installInterrupt` 同一纪律：`callback`
/// 必须 async-signal-safe，只置标志让主循环自己收尾，不在信号上下文里做清理。
pub fn installTerminate(comptime callback: fn () void) void {
    if (is_windows) {
        const W = struct {
            fn ctrl(ctrl_type: win.DWORD) callconv(.winapi) win.BOOL {
                // CTRL_CLOSE_EVENT=2, CTRL_LOGOFF_EVENT=5, CTRL_SHUTDOWN_EVENT=6
                if (ctrl_type == 2 or ctrl_type == 5 or ctrl_type == 6) {
                    callback();
                    return .TRUE;
                }
                return .FALSE;
            }
        };
        _ = SetConsoleCtrlHandler(W.ctrl, .TRUE);
    } else {
        const P = struct {
            fn h(_: std.posix.SIG) callconv(.c) void {
                callback();
            }
        };
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = P.h },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
        std.posix.sigaction(std.posix.SIG.HUP, &act, null);
    }
}

/// `installTerminate`, except that a signal this process inherited as ignored
/// stays ignored: `nohup` sets SIGHUP to SIG_IGN so a command outlives its
/// terminal, and a handler installed over it would undo that. Windows has no
/// inherited disposition for console events; there it is `installTerminate`.
pub fn installTerminateUnlessIgnored(comptime callback: fn () void) void {
    if (is_windows) {
        installTerminate(callback);
    } else {
        const P = struct {
            fn h(_: std.posix.SIG) callconv(.c) void {
                callback();
            }
        };
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = P.h },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        for ([_]std.posix.SIG{ .TERM, .HUP }) |sig| {
            var previous: std.posix.Sigaction = undefined;
            std.posix.sigaction(sig, null, &previous);
            if (previous.handler.handler == std.posix.SIG.IGN) continue;
            std.posix.sigaction(sig, &act, null);
        }
    }
}

/// 安装窗口 resize 回调。POSIX=SIGWINCH sigaction；Windows no-op（resize 归 W4 终端 ConsoleInput）。
pub fn installResize(comptime callback: fn () void) void {
    if (is_windows) return; // TODO(W4)：WINDOW_BUFFER_SIZE_EVENT via ReadConsoleInput
    const P = struct {
        fn h(_: std.posix.SIG) callconv(.c) void {
            callback();
        }
    };
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = P.h },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
}

/// Install the POSIX continue hook.  SIGCONT is delivered after a stopped
/// foreground process resumes; the callback must only publish an atomic flag
/// because terminal IO is not async-signal-safe.  Windows has no equivalent.
pub fn installContinue(comptime callback: fn () void) void {
    if (is_windows) return;
    const P = struct {
        fn h(_: std.posix.SIG) callconv(.c) void {
            callback();
        }
    };
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = P.h },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.CONT, &act, null);
}

// ── 测试 ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn brokenPipeIgnored() bool {
    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, null, &current);
    return current.handler.handler == std.posix.SIG.IGN;
}

test "threadedIo keeps SIGPIPE ignored where std.Io.Threaded would install a handler" {
    if (is_windows) return error.SkipZigTest;
    var saved: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, null, &saved);
    defer std.posix.sigaction(std.posix.SIG.PIPE, &saved, null);
    setBrokenPipe(.{ .handler = std.posix.SIG.IGN });

    // 对照:std 自己的 init 把 SIG_IGN 换成处理器,deinit 才放回来。
    var raw = std.Io.Threaded.init(testing.allocator, .{});
    try testing.expect(!brokenPipeIgnored());
    raw.deinit();
    try testing.expect(brokenPipeIgnored());

    // 生命周期交错(先建的先析构):每一步都仍是 SIG_IGN。
    var first = threadedIo(testing.allocator, .{});
    try testing.expect(brokenPipeIgnored());
    var second = threadedIo(testing.allocator, .{});
    try testing.expect(brokenPipeIgnored());
    first.deinit();
    try testing.expect(brokenPipeIgnored());
    second.deinit();
    try testing.expect(brokenPipeIgnored());
}

const RecvOutcome = enum { data, interrupted, other };

/// 一个线程阻塞在 loopback 连接的 recv 上;本线程每 20 ms 给它发一次 SIGPIPE(约 300 ms),
/// 然后写一个字节。返回 recv 的结局。
fn recvUnderSigpipe() !RecvOutcome {
    const net = @import("net.zig");
    const pfs = @import("fs.zig");
    const listener = try net.listenLoopback(0, 1);
    defer net.closeSocket(listener.sock);
    const client = try net.connectLoopback(listener.port);
    defer net.closeSocket(client);
    const server = net.acceptConn(listener.sock) orelse return error.AcceptFailed;
    defer net.closeSocket(server);

    const Reader = struct {
        sock: net.Socket,
        started: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        outcome: RecvOutcome = .other,

        fn run(self: *@This()) void {
            var byte: [1]u8 = undefined;
            self.started.store(true, .release);
            const n = net.recv(self.sock, &byte);
            self.outcome = if (n == 1) .data else if (n < 0 and pfs.lastErrnoIs(.INTR)) .interrupted else .other;
            self.finished.store(true, .release);
        }
    };
    var reader: Reader = .{ .sock = server };
    const thread = try @import("thread.zig").spawn(.full, Reader.run, .{&reader});
    while (!reader.started.load(.acquire)) std.Thread.yield() catch {};
    var rounds: usize = 0;
    while (rounds < 15 and !reader.finished.load(.acquire)) : (rounds += 1) {
        @import("sync.zig").sleepMs(20);
        _ = std.c.pthread_kill(thread.getHandle(), std.posix.SIG.PIPE);
    }
    _ = net.send(client, "x");
    thread.join();
    return reader.outcome;
}

test "an ignored SIGPIPE leaves a blocked recv alone; std.Io.Threaded's handler interrupts it" {
    if (is_windows) return error.SkipZigTest;
    var saved: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, null, &saved);
    defer std.posix.sigaction(std.posix.SIG.PIPE, &saved, null);
    setBrokenPipe(.{ .handler = std.posix.SIG.IGN });
    {
        var io_runtime = threadedIo(testing.allocator, .{});
        defer io_runtime.deinit();
        try testing.expectEqual(RecvOutcome.data, try recvUnderSigpipe());
    }
    {
        // 对照:std 装的空处理器(无 SA_RESTART)让同一个 recv 返回 EINTR。
        var raw = std.Io.Threaded.init(testing.allocator, .{});
        defer raw.deinit();
        try testing.expectEqual(RecvOutcome.interrupted, try recvUnderSigpipe());
    }
}
