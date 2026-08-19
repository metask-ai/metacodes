//! 结构化日志系统。
//!
//! 设计：
//! - 4 个 level：debug / info / warn / error
//! - 按模块标签过滤：`log.debug("stream", "...", .{})`；环境变量
//!   `METACODES_LOG="stream:debug,agent:info,*:warn"` 控制每模块级别
//! - 默认：全局 error-only（生产）；调用 `enableVerbose()` 放开到 info
//! - 输出：stderr（与 stdout 分离，REPL 流式不受干扰）；
//!   `METACODES_LOG_FILE=/path` 设置后额外追加到文件
//! - 线程安全：全局 Mutex 串行化写，避免多线程消息错切
//!
//! 调用示例：
//!     const log = @import("../util/log.zig");
//!     log.info("agent", "turn {d} started", .{turn_n});
//!     log.warn("stream", "event_iter error: {s}", .{@errorName(err)});

const std = @import("std");
const pfs = @import("platform").fs;
const time = @import("time.zig");
const sync = @import("platform").sync;

pub const Level = enum(u3) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    fn name(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    fn ansiColor(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[90m", // gray
            .info => "\x1b[36m", // cyan
            .warn => "\x1b[33m", // yellow
            .err => "\x1b[31m", // red
        };
    }
};

/// 全局配置。初始化前读环境变量；运行时可调 `enableVerbose` / `setLevel` 调整。
var g_default_level: Level = .err;
var g_module_filters: []const ModuleFilter = &.{};
var g_mutex: sync.Mutex = .{};
var g_log_file_fd: ?pfs.Fd = null;
var g_initialized: bool = false;
/// 是否往 stderr(fd 2)写日志。交互式 TUI 拥有终端时**必须关掉**——否则任何 err/warn 直接
/// 注入渲染流(fd 1/2 同一终端),把固定区写花、滚屏 desync(实测:web 搜索的 HTTP err 注入
/// footer 行 → spinner/footer 残影堆叠)。关掉后日志仍写文件(METACODES_LOG_FILE),只是不上屏。
var g_stderr_enabled: bool = true;

/// request_id 递增计数器。首次生成时用进程启动时间做高位，保证不同进程不撞。
/// 16-hex-char 字符串，格式 {seed16:x}{seq8:x}，seed 取 clock_gettime 低 32 位。
var g_reqid_seed: u32 = 0;
var g_reqid_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn lock() void {
    _ = g_mutex.lock();
}
fn unlock() void {
    _ = g_mutex.unlock();
}

pub const ModuleFilter = struct {
    name: []const u8, // 模块名；"*" 表示默认
    level: Level,
};

/// 从环境变量初始化。首次调用会 parse METACODES_LOG 和 METACODES_LOG_FILE。
/// 允许多次调用（幂等）。
pub fn initFromEnv() void {
    lock();
    if (g_initialized) {
        unlock();
        return;
    }
    g_initialized = true;

    if (std.c.getenv("METACODES_LOG")) |env_c| {
        const spec = std.mem.span(env_c);
        parseLogSpec(spec) catch {};
    }

    if (std.c.getenv("METACODES_LOG_FILE")) |path_c| {
        const fd = pfs.open(path_c, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) {
            g_log_file_fd = fd;
        }
    }

    // 为 request_id 生成 seed：用 monotonic 时钟纳秒截到 u32(可移植 util/time)。
    // 不追求密码学强度，只是让不同进程启动的日志 id 前缀不同，便于 grep。
    const seed_ns = time.nowNs();
    g_reqid_seed = if (seed_ns == 0) 0xDEADBEEF else @truncate(@as(u128, @bitCast(seed_ns)));
    unlock();

    // 初始化后写一条 banner——也方便确认 logger 本身工作
    info("log", "logger initialized; default_level={s}", .{g_default_level.name()});
}

/// 把全局默认 level 提到 .info（CLI 的 --verbose 调用）。
pub fn enableVerbose() void {
    lock();
    defer unlock();
    if (@intFromEnum(g_default_level) > @intFromEnum(Level.info)) {
        g_default_level = .info;
    }
}

pub fn setLevel(level: Level) void {
    lock();
    defer unlock();
    g_default_level = level;
}

pub const TestState = struct {
    default_level: Level,
    module_filters: []const ModuleFilter,
    log_file_fd: ?pfs.Fd,
    initialized: bool,
    stderr_enabled: bool,
    request_id_seed: u32,
    request_id_sequence: u32,
};

fn testStateLocked() TestState {
    return .{
        .default_level = g_default_level,
        .module_filters = g_module_filters,
        .log_file_fd = g_log_file_fd,
        .initialized = g_initialized,
        .stderr_enabled = g_stderr_enabled,
        .request_id_seed = g_reqid_seed,
        .request_id_sequence = g_reqid_seq.load(.monotonic),
    };
}

/// Snapshot every logger global that tests are allowed to mutate. Aggregated
/// suites deliberately keep multiple test files in one process, so a test
/// must restore this state instead of relying on process teardown for cleanup.
pub fn snapshotForTest() TestState {
    lock();
    defer unlock();
    return testStateLocked();
}

/// 测试钩子:直接注入借用的日志文件 fd(绕过 METACODES_LOG_FILE 的一次性 init)。
/// 返回完整 process-global 状态，调用方必须在关闭 fd 之前 `restoreForTest`。如果
/// 只关 fd 不清全局槽，该数字被后续文件复用时，logger 会静默污染无关文件。
pub fn setLogFileFdForTest(fd: pfs.Fd) TestState {
    lock();
    defer unlock();
    const previous = testStateLocked();
    g_initialized = true;
    g_log_file_fd = fd;
    return previous;
}

/// 恢复 `setLogFileFdForTest` 之前的日志状态。这里不 close 任何 fd：旧/新 fd
/// 的所有权都属于各自调用方，logger 只借用。
pub fn restoreForTest(previous: TestState) void {
    lock();
    defer unlock();
    g_default_level = previous.default_level;
    g_module_filters = previous.module_filters;
    g_log_file_fd = previous.log_file_fd;
    g_initialized = previous.initialized;
    g_stderr_enabled = previous.stderr_enabled;
    g_reqid_seed = previous.request_id_seed;
    g_reqid_seq.store(previous.request_id_sequence, .monotonic);
}

/// 解析 "stream:debug,agent:info,*:warn" 这种字符串
fn levelFromName(name: []const u8) ?Level {
    if (std.mem.eql(u8, name, "debug")) return .debug;
    if (std.mem.eql(u8, name, "info")) return .info;
    if (std.mem.eql(u8, name, "warn")) return .warn;
    if (std.mem.eql(u8, name, "error")) return .err;
    return null;
}

fn parseLogSpec(spec: []const u8) !void {
    // 简化：最多 16 个 filter
    var buf: [16]ModuleFilter = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |entry| {
        if (n >= buf.len) break;
        const trimmed = std.mem.trim(u8, entry, " \t");
        // 裸级别 token(METACODES_LOG=warn)= 全局默认级别。此前无冒号被
        // 静默跳过,默认停在 .err → 三轮评估的 warn 诊断链全部被抑制
        // (p5 取证:stderr 文件 0 字节)。"配置被静默忽略"是最坏的失败面。
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
            if (levelFromName(trimmed)) |bare| g_default_level = bare;
            continue;
        };
        const name = trimmed[0..colon];
        const lvl_str = trimmed[colon + 1 ..];
        const lvl: Level = levelFromName(lvl_str) orelse continue;

        if (std.mem.eql(u8, name, "*")) {
            g_default_level = lvl;
        } else {
            // 静态分配 filter slice 的内存——用 env 解析时的 name slice（指向 env 字符串，进程级）
            buf[n] = .{ .name = name, .level = lvl };
            n += 1;
        }
    }
    // 存到全局——我们把 buf 拷贝到静态 backing
    const Static = struct {
        var backing: [16]ModuleFilter = undefined;
    };
    @memcpy(Static.backing[0..n], buf[0..n]);
    g_module_filters = Static.backing[0..n];
}

fn effectiveLevel(module: []const u8) Level {
    for (g_module_filters) |f| {
        if (std.mem.eql(u8, f.name, module)) return f.level;
    }
    return g_default_level;
}

/// 日志核心：格式化、串行写 stderr 和可选文件。
fn logImpl(level: Level, module: []const u8, id: ?RequestId, comptime fmt: []const u8, args: anytype) void {
    if (!g_initialized) initFromEnv();
    if (@intFromEnum(level) < @intFromEnum(effectiveLevel(module))) return;

    lock();
    defer unlock();

    // 固定格式：[LEVEL module req=xxx] msg（req 段仅在 id 非空时出现）
    var buf: [8192]u8 = undefined;
    const prefix = if (id) |rid| std.fmt.bufPrint(&buf, "{s}[{s} {s} req={s}]\x1b[0m ", .{
        level.ansiColor(),
        level.name(),
        module,
        rid.asSlice(),
    }) catch return else std.fmt.bufPrint(&buf, "{s}[{s} {s}]\x1b[0m ", .{
        level.ansiColor(),
        level.name(),
        module,
    }) catch return;
    const msg_buf_start = prefix.len;
    const msg = std.fmt.bufPrint(buf[msg_buf_start..], fmt, args) catch {
        // 消息太长被截断：写 prefix 加提示
        const tail = "[msg truncated]\n";
        if (msg_buf_start + tail.len < buf.len) {
            @memcpy(buf[msg_buf_start..][0..tail.len], tail);
            const total = buf[0 .. msg_buf_start + tail.len];
            // 终端 log 走 std.debug.print(持 lockStdErr)——与渲染 flush 同一把锁,杜绝二者**字节级
            // 交错**(否则 log 的 raw write(2) 插进 render 的转义序列中段 → 区几何错乱、spinner 堆叠)。
            if (g_stderr_enabled) std.debug.print("{s}", .{total});
            if (g_log_file_fd) |fd| writeAll(fd, total);
        }
        return;
    };

    // 追加 '\n'
    const total_len = msg_buf_start + msg.len;
    if (total_len + 1 < buf.len) {
        buf[total_len] = '\n';
        const total = buf[0 .. total_len + 1];
        // 终端 log 走 std.debug.print(持 lockStdErr,与渲染 flush 同锁)→ 与 render 字节级互斥,
        // 不会把 log 插进 render 的转义序列中段。见上方截断分支同注。
        if (g_stderr_enabled) std.debug.print("{s}", .{total});
        if (g_log_file_fd) |fd| writeAll(fd, total);
    }
}

/// 交互式 TUI 拥有终端时调 `setStderrEnabled(false)`,禁止日志注入渲染流(见 g_stderr_enabled)。
/// 日志仍写文件(若 METACODES_LOG_FILE 设置)。verbose / headless / 非 tty 不调,保留 stderr。
pub fn setStderrEnabled(enabled: bool) void {
    lock();
    defer unlock();
    g_stderr_enabled = enabled;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const n = pfs.write(fd, bytes[total..][0 .. bytes.len - total]);
        if (n <= 0) return;
        total += @as(usize, @intCast(n));
    }
}

// ============================================================================
// 便捷 API
// ============================================================================

pub fn debug(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.debug, module, null, fmt, args);
}
pub fn info(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.info, module, null, fmt, args);
}
pub fn warn(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.warn, module, null, fmt, args);
}
pub fn err(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.err, module, null, fmt, args);
}

/// 带 request_id 的日志变体：与 debug/info/warn/err 同样级别，多一个 id 上下文。
/// 用于 HTTP 请求生命周期、Agent turn、工具调用等需要把多条日志串起来的场景。
pub fn debugId(module: []const u8, id: RequestId, comptime fmt: []const u8, args: anytype) void {
    logImpl(.debug, module, id, fmt, args);
}
pub fn infoId(module: []const u8, id: RequestId, comptime fmt: []const u8, args: anytype) void {
    logImpl(.info, module, id, fmt, args);
}
pub fn warnId(module: []const u8, id: RequestId, comptime fmt: []const u8, args: anytype) void {
    logImpl(.warn, module, id, fmt, args);
}
pub fn errId(module: []const u8, id: RequestId, comptime fmt: []const u8, args: anytype) void {
    logImpl(.err, module, id, fmt, args);
}

// ============================================================================
// RequestId
// ============================================================================

/// 12-char hex 字符串，用于把一次 HTTP 请求（或 agent turn / 工具调用）的所有
/// 日志串起来。格式：seed(4B hex=8 char) + seq(2B hex=4 char) = 12 字符。
/// seq 每次 genRequestId 递增，保证同进程内不撞；seed 进程启动时取时钟低位，
/// 让多进程的 id 前缀也大概率不同（够 grep 用，不是密码学 ID）。
pub const RequestId = struct {
    bytes: [12]u8,

    pub fn asSlice(self: *const RequestId) []const u8 {
        return self.bytes[0..];
    }
};

/// 生成新 request id。线程安全。
pub fn genRequestId() RequestId {
    if (!g_initialized) initFromEnv();
    const seq = g_reqid_seq.fetchAdd(1, .monotonic);
    var id: RequestId = undefined;
    // 写 seed (32bit => 8 hex)
    _ = std.fmt.bufPrint(id.bytes[0..8], "{x:0>8}", .{g_reqid_seed}) catch unreachable;
    // 写 seq 低 16 bit => 4 hex。超出 65535 次后 wrap，够用
    _ = std.fmt.bufPrint(id.bytes[8..12], "{x:0>4}", .{@as(u16, @truncate(seq))}) catch unreachable;
    return id;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseLogSpec accepts a bare level token as the global default" {
    // p5 生产取证:METACODES_LOG=warn 无冒号被静默跳过,默认停在 .err,
    // 三轮评估的 warn 诊断全部被抑制(stderr 文件 0 字节)。
    const previous = snapshotForTest();
    defer restoreForTest(previous);
    try parseLogSpec("warn");
    try std.testing.expectEqual(Level.warn, g_default_level);
    try parseLogSpec("kg:debug,info");
    try std.testing.expectEqual(Level.info, g_default_level);
    try std.testing.expectEqual(Level.debug, effectiveLevel("kg"));
    // 无效裸 token 不动默认级别。
    try parseLogSpec("bogus");
    try std.testing.expectEqual(Level.info, g_default_level);
}

test "Level ordering" {
    try testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.info));
    try testing.expect(@intFromEnum(Level.warn) < @intFromEnum(Level.err));
}

test "effectiveLevel: default + filter" {
    const previous = snapshotForTest();
    defer restoreForTest(previous);
    // 重置状态
    g_default_level = .warn;
    g_module_filters = &.{};
    try testing.expect(effectiveLevel("anything") == .warn);

    var filters = [_]ModuleFilter{.{ .name = "stream", .level = .debug }};
    g_module_filters = &filters;
    try testing.expect(effectiveLevel("stream") == .debug);
    try testing.expect(effectiveLevel("agent") == .warn);
}

test "enableVerbose does not downgrade above info" {
    const previous = snapshotForTest();
    defer restoreForTest(previous);
    g_default_level = .debug;
    enableVerbose();
    try testing.expect(g_default_level == .debug); // debug 比 info 更详细，不下调
    g_default_level = .err;
    enableVerbose();
    try testing.expect(g_default_level == .info);
}

test "logImpl is no-op when level too low" {
    const previous = snapshotForTest();
    defer restoreForTest(previous);
    // 静默测试：只要不 panic 就行
    g_default_level = .err;
    g_module_filters = &.{};
    g_initialized = true;
    debug("test", "should be filtered out: {d}", .{42});
    info("test", "also filtered: {s}", .{"x"});
    // error 会真写 stderr（但 bufPrint 失败不 panic）——测试不验证输出
}

test "RequestId unique and stable format" {
    const previous = snapshotForTest();
    defer restoreForTest(previous);
    g_initialized = true;
    g_reqid_seed = 0xABCD_1234;
    g_reqid_seq.store(0, .monotonic);

    const a = genRequestId();
    const b = genRequestId();
    try testing.expectEqual(@as(usize, 12), a.bytes.len);
    try testing.expectEqualStrings("abcd12340000", a.asSlice());
    try testing.expectEqualStrings("abcd12340001", b.asSlice());
}

test "debugId smoke (does not panic)" {
    const previous = snapshotForTest();
    defer restoreForTest(previous);
    g_default_level = .err;
    g_module_filters = &.{};
    g_initialized = true;
    const id = genRequestId();
    debugId("test", id, "filtered debug {d}", .{7});
    infoId("test", id, "filtered info {s}", .{"ok"});
    warnId("test", id, "this writes", .{});
}
