//! 预置应答队列(Stage 3,doc/E2E_FRAMEWORK_DESIGN.md)。
//!
//! 问题:e2e 框架用 stdin 管道喂 REPL 行流,**独占了 fd 0**。权限 `.ask`
//! (permission/prompt.zig)和 AskUserQuestion(tools/ask_user.zig)在非 tty 时
//! 也想从 fd 0 读应答 → 与 REPL 行流抢同一 fd,纯框架层无解。
//!
//! 解法:加一个**与 fd 0 分离**的预置应答通道。`--answers-file <path>` /
//! `METACODES_ANSWERS` env 加载一个应答队列(每行一条),非 tty 时权限/
//! AskUserQuestion 从队列**按序弹出**,而非读 fd 0。
//!
//! 设计:process-global(对齐 prompt.zig 的 g_home/setPersistContext 惯例)。
//! 理由:`prompt.ask` 无 ctx 参数,全局是唯一对两个 fd-0 消费者都对称的注入点。
//! 应答是 session 级一次性资源,process-global 也语义正确。
//!
//! 队列耗尽 → pop() 返 null,调用方用安全默认(权限=deny,AskUserQuestion=NotATty)。

const std = @import("std");
const pfs = @import("platform").fs;
const log = @import("../util/log.zig");

/// 应答列表,借用 loader 的 allocator(main 里是 arena,进程级存活)。
var g_answers: []const []const u8 = &.{};
var g_pos: usize = 0;
/// 队列是否曾被加载(--answers-file/METACODES_ANSWERS 设过)。
/// 与 isActive() 区分:加载过但耗尽 → loaded=true, active=false →
/// 调用方应走"安全默认"(deny / 第一项),**绝不**退回 fd 0 阻塞读
/// (非交互预置模式下 fd 0 被 REPL 行流独占,读它会死等)。
var g_loaded: bool = false;
/// backing 存储:静态固定上限,避免依赖 caller allocator 生命周期。
const MAX_ANSWERS = 256;
const MAX_ANSWER_LEN = 512;
var g_backing: [MAX_ANSWERS][MAX_ANSWER_LEN]u8 = undefined;
var g_slices: [MAX_ANSWERS][]const u8 = undefined;

/// 从原始字节加载(按非空行切;trim \r 和首尾空白)。幂等覆盖。
pub fn load(source: []const u8) void {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        if (n >= MAX_ANSWERS) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const copy_len = @min(line.len, MAX_ANSWER_LEN);
        @memcpy(g_backing[n][0..copy_len], line[0..copy_len]);
        g_slices[n] = g_backing[n][0..copy_len];
        n += 1;
    }
    g_answers = g_slices[0..n];
    g_pos = 0;
    g_loaded = true;
    log.info("answers", "loaded {d} answer(s) from queue", .{n});
}

/// 从文件加载。读失败返 error(caller 决定是否致命)。
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len + 1 > pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    load(all.items);
}

/// 弹出下一条应答(按序)。耗尽返 null。
pub fn pop() ?[]const u8 {
    if (g_pos >= g_answers.len) return null;
    const a = g_answers[g_pos];
    g_pos += 1;
    return a;
}

/// 队列是否已加载(有应答可弹)。用于非 tty 决定是否走应答通道而非 fd 0 / NotATty。
pub fn isActive() bool {
    return g_answers.len > 0 and g_pos < g_answers.len;
}

/// 队列是否曾被加载(--answers-file/METACODES_ANSWERS 设过)。
/// 即使已耗尽也返 true → 调用方走安全默认而非阻塞读 fd 0。
pub fn wasLoaded() bool {
    return g_loaded;
}

/// 测试用:重置队列状态。
pub fn resetForTest() void {
    g_answers = &.{};
    g_pos = 0;
    g_loaded = false;
}

// ============================================================================
// Tests
// ============================================================================

test "load + pop 顺序 + 耗尽" {
    load("y\nn\nThe blue one\n");
    try std.testing.expectEqualStrings("y", pop().?);
    try std.testing.expectEqualStrings("n", pop().?);
    try std.testing.expectEqualStrings("The blue one", pop().?);
    try std.testing.expect(pop() == null);
    resetForTest();
}

test "空行被跳过 + isActive" {
    load("\n  \na\n\nb\n");
    try std.testing.expect(isActive());
    try std.testing.expectEqualStrings("a", pop().?);
    try std.testing.expectEqualStrings("b", pop().?);
    try std.testing.expect(!isActive());
    try std.testing.expect(pop() == null);
    resetForTest();
}

test "CRLF trim" {
    load("y\r\nn\r\n");
    try std.testing.expectEqualStrings("y", pop().?);
    try std.testing.expectEqualStrings("n", pop().?);
    resetForTest();
}
