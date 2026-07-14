const std = @import("std");
const pfs = @import("platform").fs;
const process = @import("platform").process;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");

/// nowMs：毫秒时间戳，复用 util/time.zig 的单一实现
fn nowMs() util_time.Millis {
    return util_time.nowMs();
}

/// 写富错误 detail 到 ctx.error_detail 通道(传给模型可见)。slot 为 null 则静默。
/// 与 edit.zig 的 setDetail 同模式,提到 common 供 grep/glob/find_symbol 等共享。
/// msg 用 allocator 分配(errorToJson 会拷贝,arena 释放前读取安全)。
pub fn setErrorDetail(
    slot: ?*?[]const u8,
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const s = slot orelse return;
    s.* = std.fmt.allocPrint(allocator, fmt, args) catch null;
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
/// **注意(轴A)**:本函数**无界**——整读进内存。新代码若读的是用户可控大小的文件,用
/// `readAllFromFdCapped` 而非本函数,否则巨型文件 OOM。仅在文件大小已被上游守卫/已知有界时用本函数。
pub fn readAllFromFd(fd: pfs.Fd, allocator: std.mem.Allocator) ![]u8 {
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    while (true) {
        const n = pfs.readZ(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
    }

    return try result.toOwnedSlice(allocator);
}

/// **轴A 单一入口:有界整读文件**。累积超 max_bytes → 释放已读 + 返回 `error.FileTooLarge`(内存
/// 上限 = max_bytes + 一个 chunk)。所有"读用户可控大小文件"的工具应走此函数,而非无界 readAllFromFd
/// ——建立文件读的统一摄取预算(消除 Write/NotebookEdit 等各自裸读绕过守卫的假象)。max_bytes=0 = 不限。
pub fn readAllFromFdCapped(fd: pfs.Fd, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var buf: [65536]u8 = undefined;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    while (true) {
        const n = pfs.readZ(fd, &buf) catch return error.ReadError;
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..@as(usize, @intCast(n))]);
        if (max_bytes > 0 and result.items.len > max_bytes) {
            return error.FileTooLarge; // errdefer 释放 result(勿再显式 deinit → 双 free)
        }
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
    // 委托可移植 platform/process.zig。stdout-only(want_stderr=false → 子进程 stderr→null/NUL,
    // 不泄漏污染 TUI)。abort 包 opaque 回调。行为对齐:timeout→error.Timeout/abort→error.Aborted/
    // cap→Ok部分/error.SpawnError。
    const AbortBridge = struct {
        fn poll(ctx: ?*const anyopaque) bool {
            const a: *const AbortSignal = @ptrCast(@alignCast(ctx.?));
            return a.isAborted();
        }
    };
    const r = process.capture(argv, allocator, .{
        .timeout_ms = timeout_ms,
        .max_bytes = if (max_bytes == 0) std.math.maxInt(usize) else max_bytes,
        .want_stderr = false,
        .abort_ctx = @ptrCast(abort),
        .abort_poll = if (abort != null) AbortBridge.poll else null,
    }) catch |e| switch (e) {
        error.Timeout => return error.Timeout,
        error.Aborted => return error.Aborted,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnError,
    };
    allocator.free(r.stderr); // want_stderr=false → 空 slice，defensive free
    return r.stdout;
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
/// 子进程输出捕获的字节上限(轴A OOM 防线):stdout+stderr 合计达此值 → killpg 止血,返回已读部分。
/// 16MB 远超任何合法命令/网页展示需求(Bash 展示只 30KB、WebFetch 8KB),只堵"疯产命令/巨型下载
/// 在超时窗口内产 GB → OOM"。8 并发 job × 16MB = 128MB 上界,可控。0 = 不限(危险,勿用)。
pub const MAX_SPAWN_CAPTURE_BYTES: usize = 16 * 1024 * 1024;

pub fn spawnCaptureWithStderrTimed(
    argv: []const ?[*:0]const u8,
    allocator: std.mem.Allocator,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
    /// 子进程"仍在运行"心跳(每 2s),per-session 经 ToolContext.spawn_tick_fn 传入。
    /// null = 不显示心跳。替代旧进程全局 g_progress_cb(多 Session 串台)。
    tick_fn: ?*const fn (elapsed_ms: u64, argv0: []const u8) void,
    /// 捕获字节上限(stdout+stderr 合计);达此值 killpg + 返回已读部分。0 = 不限。
    max_bytes: usize,
) !SpawnOut {
    logSpawnArgv(argv, timeout_ms);
    // 委托可移植 platform/process.zig(POSIX fork+poll / Windows CreateProcessW+reader线程)。
    // AbortSignal / tick_fn 包成 opaque 回调(process 层不依赖 util/abort)。行为对齐:
    // timeout→error.Timeout、abort→error.Aborted、cap 命中→Ok 部分、tick label=basename(argv0)。
    const AbortBridge = struct {
        fn poll(ctx: ?*const anyopaque) bool {
            const a: *const AbortSignal = @ptrCast(@alignCast(ctx.?));
            return a.isAborted();
        }
    };
    const TickBridge = struct {
        f: *const fn (u64, []const u8) void,
        fn cb(ctx: ?*const anyopaque, elapsed: u64, label: []const u8) void {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            self.f(elapsed, label);
        }
    };
    var tick_bridge: ?TickBridge = if (tick_fn) |tf| .{ .f = tf } else null;
    const r = process.capture(argv, allocator, .{
        .timeout_ms = timeout_ms,
        .max_bytes = if (max_bytes == 0) std.math.maxInt(usize) else max_bytes,
        .want_stderr = true,
        .abort_ctx = @ptrCast(abort),
        .abort_poll = if (abort != null) AbortBridge.poll else null,
        .tick_ctx = if (tick_bridge) |*t| @ptrCast(t) else null,
        .tick_cb = if (tick_bridge != null) TickBridge.cb else null,
    }) catch |e| switch (e) {
        error.Timeout => return error.Timeout,
        error.Aborted => return error.Aborted,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnError,
    };
    return .{ .stdout = r.stdout, .stderr = r.stderr, .exit_code = r.exit_code };
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const argv = [_]?[*:0]const u8{ "/bin/echo", "hello", null };
    const out = try spawnCaptureStdout(argv[0..argv.len], std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "spawnCaptureStdoutAbortable without abort behaves same as base" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
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
            util_time.sleepMs(200);
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

test "readAllFromFdCapped:超 cap 返 FileTooLarge、cap 内正常读(轴A 统一入口)" {
    const a = std.testing.allocator;
    const path = "/tmp/cc-readcapped-test.txt";
    const fd_w = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    try std.testing.expect(fd_w >= 0);
    var payload: [10000]u8 = undefined;
    @memset(&payload, 'z');
    _ = pfs.write(fd_w, &payload); // 10KB
    _ = pfs.close(fd_w);
    defer _ = std.c.unlink(path);

    // cap=5KB < 10KB → FileTooLarge。
    {
        const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
        defer pfs.close(fd);
        try std.testing.expectError(error.FileTooLarge, readAllFromFdCapped(fd, a, 5 * 1024));
    }
    // cap=1MB > 10KB → 正常读全。
    {
        const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
        defer pfs.close(fd);
        const r = try readAllFromFdCapped(fd, a, 1024 * 1024);
        defer a.free(r);
        try std.testing.expectEqual(@as(usize, 10000), r.len);
    }
    // cap=0 → 不限,读全。
    {
        const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
        defer pfs.close(fd);
        const r = try readAllFromFdCapped(fd, a, 0);
        defer a.free(r);
        try std.testing.expectEqual(@as(usize, 10000), r.len);
    }
}

test "spawnCaptureWithStderrTimed:max_bytes 封顶无限输出 killpg 止血不挂死(P0 轴A)" {
    const a = std.testing.allocator;
    const t0 = nowMs();
    // `yes` 无限打印 stdout;无 cap 会挂到 timeout;cap=32KB → 读够即 killpg,快速返回 ≤ 略多于 32KB。
    var argv = [_]?[*:0]const u8{ "/usr/bin/yes", "abcdefgh", null };
    const out = spawnCaptureWithStderrTimed(argv[0..argv.len], a, null, 8000, null, 32 * 1024) catch |e| {
        if (e == error.SpawnError) return; // 环境无 yes → 跳过
        return e;
    };
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    const dt = nowMs() - t0;
    // 封顶:stdout 读到 ~32KB 就止血(cap + 4KB read buffer 余量),不是无限;killGroup 含 2s sleep。
    try std.testing.expect(out.stdout.len >= 32 * 1024);
    try std.testing.expect(out.stdout.len < 32 * 1024 + 8 * 1024);
    try std.testing.expect(dt < 5000); // 远快于 8000ms timeout → 证明是 cap 而非超时才停
}
