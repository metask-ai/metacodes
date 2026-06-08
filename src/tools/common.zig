const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");

/// nowMs：毫秒时间戳，复用 util/time.zig 的单一实现
fn nowMs() util_time.Millis {
    return util_time.nowMs();
}

/// Progress 心跳:子进程长命令"仍在运行"提示。重构前是进程全局 g_progress_cb(多 Session
/// 串台),已移到 ToolContext.spawn_tick_fn(per-session),作为参数传入 spawnCaptureWithStderrTimed。

/// 从 JSON 对象字符串提取字段值（纯手写解析，适配流式 partial JSON）
///
/// 支持：
/// - 带引号字符串：`"field":"value"` → 返回 `value`（**含原始转义**，调用方需自行 unescape）
/// - 带引号字符串（带空格）：`"field": "value"` → 同上
/// - 不带引号标量：`"field":123` / `"field":true` → 返回 `123` / `true`
/// - 转义的引号 `\"` 不误判为结束
///
/// 返回的切片指向 `data` 内部，生命周期与 `data` 绑定。
/// 无此字段时返回 null。
pub fn extractJsonArg(data: []const u8, field: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    std.debug.assert(field.len < 200);

    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..field.len], field);
    pattern_buf[1 + field.len] = '"';
    pattern_buf[2 + field.len] = ':';

    const key_pattern = pattern_buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, key_pattern) orelse return null;
    const start = idx + key_pattern.len;

    var pos = start;
    while (pos < data.len and data[pos] == ' ') : (pos += 1) {}
    if (pos >= data.len) return null;

    if (data[pos] == '"') {
        var end = pos + 1;
        while (end < data.len) {
            if (data[end] == '"' and data[end - 1] != '\\') {
                return data[pos + 1 .. end];
            }
            end += 1;
        }
        return null;
    }

    var end = pos;
    while (end < data.len) {
        const c = data[end];
        if (c == ',' or c == '}' or c == ' ' or c == '\n' or c == '\r' or c == '\t') break;
        end += 1;
    }
    if (end == pos) return null;
    return data[pos..end];
}

/// 把 posix fd 上的全部内容读到 allocator 拥有的 buffer 中。
///
/// 读到 EOF（read 返回 0）为止。单次 read 错误返回 `error.ReadError`。
/// 调用方负责 `allocator.free(result)`。
pub fn readAllFromFd(fd: std.posix.fd_t, allocator: std.mem.Allocator) ![]u8 {
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    while (true) {
        const n = std.posix.read(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
    }

    return try result.toOwnedSlice(allocator);
}

/// 子进程 spawn + stdout 捕获（pipe + fork + execve 模式）。
///
/// argv 以 null 结尾。argv[0] 必须是绝对路径。
/// 捕获 stdout 全部内容，忽略 stderr，等待子进程退出。
/// 返回的 bytes 由 allocator 拥有，调用方 free。
pub fn spawnCaptureStdout(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    return spawnCaptureStdoutAbortable(argv, allocator, null);
}

/// 带 AbortSignal 的子进程 spawn。
///
/// 关键不同：
/// 1. 子进程 setpgid(0,0) 独立进程组，防止孙进程逃逸成孤儿
/// 2. 父进程 poll 轮询 stdout，每 100ms 检查 abort
/// 3. abort 触发：killpg(-pgid, SIGTERM) → 等 2s → killpg(SIGKILL)
/// 4. 返回 error.Aborted
pub fn spawnCaptureStdoutAbortable(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal,
) ![]u8 {
    return spawnCaptureStdoutAbortableTimed(argv, allocator, abort, 0);
}

/// spawnCaptureStdoutAbortable 的增强版：额外 timeout_ms 参数。
/// timeout_ms == 0 表示无超时；> 0 则在 wall-clock 超过 timeout_ms 后 killGroup 并返 error.Timeout。
pub fn spawnCaptureStdoutAbortableTimed(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
) ![]u8 {
    return spawnCaptureStdoutAbortableTimedCapped(argv, allocator, abort, timeout_ms, 0);
}

/// 巨型仓库防护变体:max_bytes>0 时,捕获到 ≥max_bytes 就 killpg 子进程并返回已读部分
/// (截断但有效,不报错)。用于 `rg --files` 在 Chrome 这种仓库会吐几十 MB 路径、列表阶段
/// 就卡死的场景——只读够前 N 个文件即可(后续反正被 MAX_FILES 截)。max_bytes==0 = 不限。
pub fn spawnCaptureStdoutCapped(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
    max_bytes: usize,
) ![]u8 {
    return spawnCaptureStdoutAbortableTimedCapped(argv, allocator, abort, timeout_ms, max_bytes);
}

fn spawnCaptureStdoutAbortableTimedCapped(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
    max_bytes: usize,
) ![]u8 {
    logSpawnArgv(argv, timeout_ms);
    const t_start = nowMs();

    var pipefd: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipefd) != 0) return error.SpawnError;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipefd[0]);
        _ = std.c.close(pipefd[1]);
        log.err("spawn", "fork failed", .{});
        return error.SpawnError;
    }

    if (pid == 0) {
        // 子进程
        _ = std.c.setpgid(0, 0); // 新进程组；killpg 可杀整组
        _ = std.c.close(pipefd[0]);
        _ = std.c.dup2(pipefd[1], 1);
        // stderr → /dev/null：本函数是 stdout-only 捕获，子进程(git/rg/...)的 stderr
        // 绝不能泄漏到终端污染 TUI(实测:非 git 目录跑 `git log` → `fatal: not a git
        // repository` 直接打到屏上)。要 stderr 的调用方用 *WithStderr 变体。
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

    log.debug("spawn", "forked pid={d}", .{pid});

    // 父进程
    _ = std.c.close(pipefd[1]);
    // 父端也设一次 setpgid，避免竞态（子进程可能还没 setpgid）
    _ = std.c.setpgid(pid, pid);

    const result = readAbortableTimedCapped(pipefd[0], allocator, pid, abort, timeout_ms, max_bytes);
    _ = std.c.close(pipefd[0]);

    // 如果是 abort/timeout，上面已经 kill 过；reap
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const dt_ms = nowMs() - t_start;
    if (result) |out| {
        log.debug("spawn", "pid={d} exit={d} stdout_bytes={d} duration_ms={d}", .{ pid, exitCode(status), out.len, dt_ms });
    } else |err| {
        log.warn("spawn", "pid={d} failed err={s} duration_ms={d}", .{ pid, @errorName(err), dt_ms });
    }

    return result;
}

/// 把 argv 打印成可读形式，最多取前 N 个参数防止日志爆炸。
fn logSpawnArgv(argv: []const ?[*:0]const u8, timeout_ms: u64) void {
    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    for (argv, 0..) |a_opt, idx| {
        if (idx >= 8) {
            const tail = " ...";
            if (written + tail.len < buf.len) {
                @memcpy(buf[written..][0..tail.len], tail);
                written += tail.len;
            }
            break;
        }
        const a = a_opt orelse break;
        const sp = std.mem.span(@as([*:0]const u8, a));
        const need = if (idx == 0) sp.len else sp.len + 1;
        if (written + need >= buf.len) break;
        if (idx != 0) {
            buf[written] = ' ';
            written += 1;
        }
        @memcpy(buf[written..][0..sp.len], sp);
        written += sp.len;
    }
    log.info("spawn", "exec argv=[{s}] timeout_ms={d}", .{ buf[0..written], timeout_ms });
}

fn exitCode(status: c_int) i32 {
    // POSIX WEXITSTATUS 等价：(status >> 8) & 0xff；若被信号终止，返回 -signo
    if ((status & 0x7f) == 0) return @as(i32, @intCast((status >> 8) & 0xff));
    return -@as(i32, @intCast(status & 0x7f));
}

/// 带 stdout+stderr+exit_code 的子进程结果。调用方需 allocator.free(stdout) / free(stderr)。
pub const SpawnOut = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
};

/// spawn 子进程并同时捕获 stdout 和 stderr 到两个独立 buffer，返回 exit_code。
/// 与 spawnCaptureStdoutAbortableTimed 语义一致（abort/timeout 行为、进程组、kill 策略相同），
/// 区别只在于多了一条 stderr pipe。给 Bash tool 使用，让模型能看到错误信息。
///
/// timeout_ms == 0 无超时；>0 时超时返 error.Timeout（已发 kill）。abort 触发返 error.Aborted。
pub fn spawnCaptureWithStderrTimed(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
    /// 子进程"仍在运行"心跳(每 2s),per-session 经 ToolContext.spawn_tick_fn 传入。
    /// null = 不显示心跳。替代旧进程全局 g_progress_cb(多 Session 串台)。
    tick_fn: ?*const fn (elapsed_ms: u64, argv0: []const u8) void,
) !SpawnOut {
    logSpawnArgv(argv, timeout_ms);
    const t_start = nowMs();

    var out_pipe: [2]std.c.fd_t = undefined;
    var err_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&out_pipe) != 0) return error.SpawnError;
    if (std.c.pipe(&err_pipe) != 0) {
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        return error.SpawnError;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.close(err_pipe[0]);
        _ = std.c.close(err_pipe[1]);
        log.err("spawn", "fork failed", .{});
        return error.SpawnError;
    }

    if (pid == 0) {
        // 子进程
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(err_pipe[0]);
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.dup2(err_pipe[1], 2);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.close(err_pipe[1]);

        const argv0 = argv[0] orelse std.c._exit(127);
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), &.{null});
        std.c._exit(127);
    }

    log.debug("spawn", "forked pid={d} (stdout+stderr)", .{pid});

    // 父进程
    _ = std.c.close(out_pipe[1]);
    _ = std.c.close(err_pipe[1]);
    _ = std.c.setpgid(pid, pid);

    // tick 显示的命令名:取 argv[0] 的 basename(旧代码硬编码 "bash",对 WebFetch/Worktree
    // 等走本函数的工具是错的——它们不是 bash)。null argv[0] 兜底 "?"。
    const cmd_label: []const u8 = blk: {
        const a0 = argv[0] orelse break :blk "?";
        const full = std.mem.span(a0);
        const slash = std.mem.lastIndexOfScalar(u8, full, '/');
        break :blk if (slash) |i| full[i + 1 ..] else full;
    };
    const result = readTwoFdsAbortableTimed(out_pipe[0], err_pipe[0], allocator, pid, abort, timeout_ms, tick_fn, cmd_label);
    _ = std.c.close(out_pipe[0]);
    _ = std.c.close(err_pipe[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ec = exitCode(status);

    const dt_ms = nowMs() - t_start;
    if (result) |r| {
        log.debug("spawn", "pid={d} exit={d} stdout_bytes={d} stderr_bytes={d} duration_ms={d}", .{ pid, ec, r.stdout.len, r.stderr.len, dt_ms });
        return .{ .stdout = r.stdout, .stderr = r.stderr, .exit_code = ec };
    } else |err| {
        log.warn("spawn", "pid={d} failed err={s} duration_ms={d}", .{ pid, @errorName(err), dt_ms });
        return err;
    }
}

const TwoBufs = struct { stdout: []u8, stderr: []u8 };

/// 同时从两个 fd 读，直到都 EOF（或 abort/timeout 提前结束）。
fn readTwoFdsAbortableTimed(
    out_fd: std.c.fd_t,
    err_fd: std.c.fd_t,
    allocator: std.mem.Allocator,
    pgid: std.c.pid_t,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
    tick_fn: ?*const fn (elapsed_ms: u64, argv0: []const u8) void,
    cmd_label: []const u8,
) !TwoBufs {
    var buf: [4096]u8 = undefined;
    var out_list = std.ArrayList(u8).empty;
    errdefer out_list.deinit(allocator);
    var err_list = std.ArrayList(u8).empty;
    errdefer err_list.deinit(allocator);

    var out_done = false;
    var err_done = false;
    const start_ms = nowMs();
    var last_progress_ms = start_ms;
    const progress_interval_ms: i64 = 2000;

    while (!(out_done and err_done)) {
        if (abort) |a| if (a.isAborted()) {
            killGroup(pgid);
            return error.Aborted;
        };
        const elapsed = nowMs() - start_ms;
        if (timeout_ms > 0) {
            if (elapsed >= @as(i64, @intCast(timeout_ms))) {
                killGroup(pgid);
                return error.Timeout;
            }
        }
        // 每 2s 触发一次 progress（只在心跳回调已传入时）
        if (tick_fn) |cb| {
            if (nowMs() - last_progress_ms >= progress_interval_ms) {
                cb(@intCast(elapsed), cmd_label);
                last_progress_ms = nowMs();
            }
        }

        var pfds = [_]std.c.pollfd{
            .{ .fd = if (out_done) -1 else out_fd, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = if (err_done) -1 else err_fd, .events = std.c.POLL.IN, .revents = 0 },
        };
        const poll_rc = std.c.poll(&pfds, 2, 100);
        if (poll_rc < 0) return error.ReadError;
        if (poll_rc == 0) continue;

        if (!out_done) {
            if ((pfds[0].revents & std.c.POLL.IN) != 0) {
                const n = std.c.read(out_fd, &buf, buf.len);
                if (n <= 0) out_done = true else try out_list.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
            } else if ((pfds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR)) != 0) {
                out_done = true;
            }
        }
        if (!err_done) {
            if ((pfds[1].revents & std.c.POLL.IN) != 0) {
                const n = std.c.read(err_fd, &buf, buf.len);
                if (n <= 0) err_done = true else try err_list.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
            } else if ((pfds[1].revents & (std.c.POLL.HUP | std.c.POLL.ERR)) != 0) {
                err_done = true;
            }
        }
    }

    return .{
        .stdout = try out_list.toOwnedSlice(allocator),
        .stderr = try err_list.toOwnedSlice(allocator),
    };
}

/// 从 pipe 读，可被 abort 中断。abort 时 killpg 杀整组并返回 error.Aborted。
fn readAbortable(
    fd: std.c.fd_t,
    allocator: std.mem.Allocator,
    pgid: std.c.pid_t,
    abort: ?*const AbortSignal,
) ![]u8 {
    return readAbortableTimed(fd, allocator, pgid, abort, 0);
}

/// readAbortable + 可选总耗时 timeout_ms（>0 时生效）。超时返回 error.Timeout。
fn readAbortableTimed(
    fd: std.c.fd_t,
    allocator: std.mem.Allocator,
    pgid: std.c.pid_t,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
) ![]u8 {
    return readAbortableTimedCapped(fd, allocator, pgid, abort, timeout_ms, 0);
}

/// 同 readAbortableTimed,但 max_bytes>0 时:一旦捕获字节数 ≥ max_bytes,killpg 终止子进程
/// 并返回已读部分。用于巨型仓库防护:`rg --files` 在 Chrome 这种仓库会吐几十 MB 路径,
/// 列表阶段就卡死;调用方只需前 N 个文件(后面反正被 MAX_FILES 截),读够就杀。
/// 不报错——返回"截断但有效"的输出(按行解析,调用方对最后半行做容错)。
fn readAbortableTimedCapped(
    fd: std.c.fd_t,
    allocator: std.mem.Allocator,
    pgid: std.c.pid_t,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
    max_bytes: usize,
) ![]u8 {
    var buf: [4096]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    const start_ms = nowMs();
    while (true) {
        if (abort) |a| if (a.isAborted()) {
            killGroup(pgid);
            return error.Aborted;
        };
        if (timeout_ms > 0) {
            const elapsed = nowMs() - start_ms;
            if (elapsed >= @as(i64, @intCast(timeout_ms))) {
                killGroup(pgid);
                return error.Timeout;
            }
        }
        var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
        const poll_rc = std.c.poll(&pfd, 1, 100);
        if (poll_rc < 0) return error.ReadError;
        if (poll_rc == 0) continue; // timeout

        if ((pfd[0].revents & std.c.POLL.IN) != 0) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break; // EOF 或错误
            try result.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
            // 字节上限:读够就杀子进程,返回已读部分(不报错,截断但有效)。
            if (max_bytes > 0 and result.items.len >= max_bytes) {
                killGroup(pgid);
                break;
            }
        } else if ((pfd[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR)) != 0) {
            break;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// 向整个进程组发 SIGTERM → 等 2s → SIGKILL。
fn killGroup(pgid: std.c.pid_t) void {
    _ = std.c.kill(-pgid, std.c.SIG.TERM);
    // 等 2s 让 TERM 生效，再补 KILL
    const req = std.c.timespec{ .sec = 2, .nsec = 0 };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
    _ = std.c.kill(-pgid, std.c.SIG.KILL);
}

test "extractJsonArg string value" {
    const data = "{\"path\":\"/etc/hostname\",\"limit\":100}";
    try std.testing.expectEqualStrings("/etc/hostname", extractJsonArg(data, "path").?);
}

test "extractJsonArg numeric value" {
    const data = "{\"path\":\"/etc/hostname\",\"limit\":100}";
    try std.testing.expectEqualStrings("100", extractJsonArg(data, "limit").?);
}

test "extractJsonArg missing field" {
    const data = "{\"path\":\"/etc/hostname\"}";
    try std.testing.expect(extractJsonArg(data, "missing") == null);
}

test "extractJsonArg with spaces" {
    const data = "{\"path\": \"/etc/hostname\", \"limit\": 100}";
    try std.testing.expectEqualStrings("/etc/hostname", extractJsonArg(data, "path").?);
    try std.testing.expectEqualStrings("100", extractJsonArg(data, "limit").?);
}

test "extractJsonArg escaped quote in value" {
    const data = "{\"msg\":\"hello \\\"world\\\"\"}";
    try std.testing.expectEqualStrings("hello \\\"world\\\"", extractJsonArg(data, "msg").?);
}

test "extractJsonArg boolean" {
    const data = "{\"replace_all\":true}";
    try std.testing.expectEqualStrings("true", extractJsonArg(data, "replace_all").?);
}

test "extractJsonArg empty string value" {
    const data = "{\"path\":\"\"}";
    try std.testing.expectEqualStrings("", extractJsonArg(data, "path").?);
}

test "extractJsonArg nested quote escape preserved" {
    // extractJsonArg 返回原始未反转义的片段
    const data = "{\"msg\":\"a\\\"b\"}";
    try std.testing.expectEqualStrings("a\\\"b", extractJsonArg(data, "msg").?);
}

test "extractJsonArg false bool" {
    const data = "{\"enabled\":false}";
    try std.testing.expectEqualStrings("false", extractJsonArg(data, "enabled").?);
}

test "extractJsonArg field ordering" {
    const data = "{\"a\":1,\"b\":2,\"c\":3}";
    try std.testing.expectEqualStrings("1", extractJsonArg(data, "a").?);
    try std.testing.expectEqualStrings("2", extractJsonArg(data, "b").?);
    try std.testing.expectEqualStrings("3", extractJsonArg(data, "c").?);
}

test "spawnCaptureStdout echo" {
    const argv = [_]?[*:0]const u8{ "/bin/echo", "hello", null };
    const out = try spawnCaptureStdout(argv[0..argv.len], std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "spawnCaptureStdoutAbortable without abort behaves same as base" {
    const argv = [_]?[*:0]const u8{ "/bin/echo", "world", null };
    const out = try spawnCaptureStdoutAbortable(argv[0..argv.len], std.testing.allocator, null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "world") != null);
}

test "spawnCaptureStdoutAbortable returns error.Aborted when abort pre-set" {
    var sig = AbortSignal.init();
    sig.abort(.user_ctrl_c);
    const argv = [_]?[*:0]const u8{ "/bin/sleep", "10", null };
    const result = spawnCaptureStdoutAbortable(argv[0..argv.len], std.testing.allocator, &sig);
    try std.testing.expectError(error.Aborted, result);
}

test "spawnCaptureStdoutAbortable: abort mid-run kills process" {
    var sig = AbortSignal.init();
    const argv = [_]?[*:0]const u8{ "/bin/sleep", "5", null };

    // 200ms 后触发 abort
    const t0 = nowMs();
    const trigger = try std.Thread.spawn(.{}, struct {
        fn run(s: *AbortSignal) void {
            const req = std.c.timespec{ .sec = 0, .nsec = 200 * 1000 * 1000 };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
            s.abort(.user_ctrl_c);
        }
    }.run, .{&sig});

    const result = spawnCaptureStdoutAbortable(argv[0..argv.len], std.testing.allocator, &sig);
    trigger.join();
    const dt = nowMs() - t0;

    try std.testing.expectError(error.Aborted, result);
    // killGroup 含 2s sleep（SIGTERM 后等），所以总时间应该在 ~2s 左右但 < 5s
    try std.testing.expect(dt < 4500);
}

test "spawnCaptureStdoutCapped 截断无限输出且不挂死" {
    const a = std.testing.allocator;
    // `yes` 无限打印,无 cap 会挂死;cap=8KB 必须很快返回 ≤ 略多于 8KB。
    var argv = [_]?[*:0]const u8{ "/usr/bin/yes", "abcdefgh", null };
    const out = spawnCaptureStdoutCapped(argv[0..argv.len], a, null, 5000, 8 * 1024) catch |e| {
        // 某些环境 yes 路径不同 → 跳过(不算失败)
        if (e == error.SpawnError) return;
        return e;
    };
    defer a.free(out);
    // 读到了内容,且被 cap 截断在合理范围(cap + 一次 read buffer 4KB 余量内)
    try std.testing.expect(out.len >= 8 * 1024);
    try std.testing.expect(out.len < 8 * 1024 + 8 * 1024);
}
