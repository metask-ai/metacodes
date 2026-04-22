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
var g_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var g_log_file_fd: ?std.c.fd_t = null;
var g_initialized: bool = false;

fn lock() void {
    _ = std.c.pthread_mutex_lock(&g_mutex);
}
fn unlock() void {
    _ = std.c.pthread_mutex_unlock(&g_mutex);
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
        const fd = std.c.open(path_c, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) {
            g_log_file_fd = fd;
        }
    }
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

/// 解析 "stream:debug,agent:info,*:warn" 这种字符串
fn parseLogSpec(spec: []const u8) !void {
    // 简化：最多 16 个 filter
    var buf: [16]ModuleFilter = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |entry| {
        if (n >= buf.len) break;
        const trimmed = std.mem.trim(u8, entry, " \t");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..colon];
        const lvl_str = trimmed[colon + 1 ..];
        const lvl: Level = if (std.mem.eql(u8, lvl_str, "debug"))
            .debug
        else if (std.mem.eql(u8, lvl_str, "info"))
            .info
        else if (std.mem.eql(u8, lvl_str, "warn"))
            .warn
        else if (std.mem.eql(u8, lvl_str, "error"))
            .err
        else
            continue;

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
fn logImpl(level: Level, module: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!g_initialized) initFromEnv();
    if (@intFromEnum(level) < @intFromEnum(effectiveLevel(module))) return;

    lock();
    defer unlock();

    // 固定格式：[LEVEL module] msg
    var buf: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s}[{s} {s}]\x1b[0m ", .{
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
            writeAll(2, total);
            if (g_log_file_fd) |fd| writeAll(fd, total);
        }
        return;
    };

    // 追加 '\n'
    const total_len = msg_buf_start + msg.len;
    if (total_len + 1 < buf.len) {
        buf[total_len] = '\n';
        const total = buf[0 .. total_len + 1];
        writeAll(2, total);
        if (g_log_file_fd) |fd| writeAll(fd, total);
    }
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + total, bytes.len - total);
        if (n <= 0) return;
        total += @as(usize, @intCast(n));
    }
}

// ============================================================================
// 便捷 API
// ============================================================================

pub fn debug(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.debug, module, fmt, args);
}
pub fn info(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.info, module, fmt, args);
}
pub fn warn(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.warn, module, fmt, args);
}
pub fn err(module: []const u8, comptime fmt: []const u8, args: anytype) void {
    logImpl(.err, module, fmt, args);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Level ordering" {
    try testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.info));
    try testing.expect(@intFromEnum(Level.warn) < @intFromEnum(Level.err));
}

test "effectiveLevel: default + filter" {
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
    g_default_level = .debug;
    enableVerbose();
    try testing.expect(g_default_level == .debug); // debug 比 info 更详细，不下调
    g_default_level = .err;
    enableVerbose();
    try testing.expect(g_default_level == .info);
}

test "logImpl is no-op when level too low" {
    // 静默测试：只要不 panic 就行
    g_default_level = .err;
    g_module_filters = &.{};
    debug("test", "should be filtered out: {d}", .{42});
    info("test", "also filtered: {s}", .{"x"});
    // error 会真写 stderr（但 bufPrint 失败不 panic）——测试不验证输出
}
