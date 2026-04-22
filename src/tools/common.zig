const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

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
    var pipefd: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipefd) != 0) return error.SpawnError;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipefd[0]);
        _ = std.c.close(pipefd[1]);
        return error.SpawnError;
    }

    if (pid == 0) {
        // 子进程
        _ = std.c.setpgid(0, 0); // 新进程组；killpg 可杀整组
        _ = std.c.close(pipefd[0]);
        _ = std.c.dup2(pipefd[1], 1);
        _ = std.c.close(pipefd[1]);

        const argv0 = argv[0] orelse std.c._exit(127);
        _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), &.{null});
        std.c._exit(127);
    }

    // 父进程
    _ = std.c.close(pipefd[1]);
    // 父端也设一次 setpgid，避免竞态（子进程可能还没 setpgid）
    _ = std.c.setpgid(pid, pid);

    const result = readAbortableTimed(pipefd[0], allocator, pid, abort, timeout_ms);
    _ = std.c.close(pipefd[0]);

    // 如果是 abort/timeout，上面已经 kill 过；reap
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    return result;
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
        } else if ((pfd[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR)) != 0) {
            break;
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
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
