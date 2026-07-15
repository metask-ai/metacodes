//! Status line：REPL 每次输出 prompt 前渲染一行，显示 model / mode / tokens / bg jobs。
//!
//! 不是真正的"fixed bottom row"——那要 termios 和 cursor 控制。
//! 本期 MVP：prompt 上方打印一行（ANSI dim color），简单、不占 raw mode 控制权。
//!
//! 非 TTY 时：不打印（避免污染 pipe 输出）。
//!
//! 原子性：所有内容先拼到一个 stack buffer，再**一次** write(2)。
//! 避免多次 std.debug.print 的间隙被其他线程日志切入导致换行错乱。

const std = @import("std");
const app_mod = @import("../app.zig");

/// 渲染 status 行到 stderr（与 prompt 同通道）。只在 TTY 下调用。
pub fn render(app: *const app_mod.App) void {
    const u = app.usage;
    const total_tokens = u.input_tokens + u.output_tokens;
    const cost = u.costUsd(app.activeModel());

    const mode_str = switch (app.config.permission_mode) {
        .default => "default",
        .accept_edits => "acceptEdits",
        .plan => "plan",
        .auto => "auto",
        .dont_ask => "dontAsk",
        .bypass_permissions => "bypassPermissions",
        .prompt => "prompt", // legacy alias = default
        .bypass => "bypass", // legacy alias = bypass_permissions
    };

    var tok_buf: [16]u8 = undefined;
    const tok_str = formatTokens(&tok_buf, total_tokens);

    // 后台任务数 + cron 数(>0 才显示)
    const bg_count = if (app.jobs) |*j| j.runningCount() else 0;
    const cron_count = app.cron_registry.count();

    var extra_buf: [96]u8 = undefined;
    var extra: []const u8 = "";
    var jb: [40]u8 = undefined;
    var jobs_seg: []const u8 = "";
    if (bg_count > 0 and cron_count > 0) {
        jobs_seg = std.fmt.bufPrint(&jb, " | {d}bg | {d}cron", .{ bg_count, cron_count }) catch "";
    } else if (bg_count > 0) {
        jobs_seg = std.fmt.bufPrint(&jb, " | {d}bg", .{bg_count}) catch "";
    } else if (cron_count > 0) {
        jobs_seg = std.fmt.bufPrint(&jb, " | {d}cron", .{cron_count}) catch "";
    }
    // SW5:有 team 时显示 roster 段(N 活着,M 忙)。计数排除已终止尸体(误导 8👥 0⚙)。
    var tb: [40]u8 = undefined;
    const team_seg = teamSegmentFor(app.swarm.teammates, &tb);
    extra = std.fmt.bufPrint(&extra_buf, "{s}{s}", .{ jobs_seg, team_seg }) catch jobs_seg;

    // 一次性拼接成一行(theme.dim + 内容 + reset + 换行)再写
    const th = app.theme;
    var line_buf: [384]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}[{s} | {s} | {s} tok | ${d:.4}{s}]{s}\n", .{
        th.dim,
        app.activeModel(),
        mode_str,
        tok_str,
        cost,
        extra,
        th.reset,
    }) catch return; // 超 buf 截断:静默跳过渲染
    writeAll(2, line);
}

/// SW5:roster 状态段(纯函数,可测)。`" | 3👥 2⚙"` = 3 活着,2 在忙。
/// total=0 → 空段(无 team 不显示)。
pub fn swarmSegment(buf: []u8, total: usize, working: usize) []const u8 {
    if (total == 0) return "";
    return std.fmt.bufPrint(buf, " | {d}\u{1F465} {d}\u{2699}", .{ total, working }) catch "";
}

/// render 的 roster 段接线(可测):无 registry / 无活着队友 → 空;否则 liveCount👥 workingCount⚙。
/// teammates 是 ?*Registry(const 浅层),值捕获即拿到可用指针,无需 @constCast。
pub fn teamSegmentFor(teammates: ?*@import("../swarm/teammate.zig").TeammateRegistry, buf: []u8) []const u8 {
    const reg = teammates orelse return "";
    const live = reg.liveCount();
    if (live == 0) return "";
    return swarmSegment(buf, live, reg.workingCount());
}

/// 循环写入直到完成或 write 返 0/错误。保证不短写造成行混乱。
fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + total, bytes.len - total);
        if (n <= 0) return; // 无法进一步写入就放弃（status line 不关键）
        total += @as(usize, @intCast(n));
    }
}

/// 把 token 数格式成紧凑字符串：< 1K → 原样；< 1M → "1.2K"；>= 1M → "1.23M"。
/// 写入 buf 并返回实际 slice。
fn formatTokens(buf: []u8, n: u64) []const u8 {
    if (n < 1000) {
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch buf[0..0];
    } else if (n < 1_000_000) {
        const k = @as(f64, @floatFromInt(n)) / 1000.0;
        return std.fmt.bufPrint(buf, "{d:.1}K", .{k}) catch buf[0..0];
    } else {
        const m = @as(f64, @floatFromInt(n)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}M", .{m}) catch buf[0..0];
    }
}

test "formatTokens ranges" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatTokens(&buf, 0));
    try std.testing.expectEqualStrings("999", formatTokens(&buf, 999));
    try std.testing.expectEqualStrings("1.0K", formatTokens(&buf, 1000));
    try std.testing.expectEqualStrings("12.3K", formatTokens(&buf, 12345));
    try std.testing.expectEqualStrings("1.23M", formatTokens(&buf, 1_234_567));
}

test "swarmSegment: 有 team 显示 roster 段;空 team 空段" {
    var buf: [40]u8 = undefined;
    const seg = swarmSegment(&buf, 3, 2);
    try std.testing.expect(std.mem.indexOf(u8, seg, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, seg, "2") != null);
    try std.testing.expectEqualStrings("", swarmSegment(&buf, 0, 0));
}

test "teamSegmentFor: 接线路径(真 registry + 假 entry)渲染 roster 段" {
    const TeammateRegistry = @import("../swarm/teammate.zig").TeammateRegistry;
    var buf: [40]u8 = undefined;
    // 无 registry → 空。
    try std.testing.expectEqualStrings("", teamSegmentFor(null, &buf));
    // 有 registry 但无队友 → 空。
    var reg = try TeammateRegistry.init(std.testing.allocator, "k", null, "m", .anthropic, "/tmp");
    defer reg.deinit();
    try std.testing.expectEqualStrings("", teamSegmentFor(&reg, &buf));
    // 2 队友(1 working + 1 idle)→ 段显示 "2👥 1⚙"。
    try reg.pushTestEntry("alice", .working);
    try reg.pushTestEntry("bob", .idle);
    const seg = teamSegmentFor(&reg, &buf);
    try std.testing.expect(std.mem.indexOf(u8, seg, "2") != null); // 2 live
    try std.testing.expect(std.mem.indexOf(u8, seg, "1") != null); // 1 working
    try std.testing.expect(std.mem.indexOf(u8, seg, "\u{1F465}") != null); // 👥
    // terminated 尸体不计入 live。
    try reg.pushTestEntry("dead", .terminated);
    const seg2 = teamSegmentFor(&reg, &buf);
    try std.testing.expect(std.mem.indexOf(u8, seg2, "2") != null); // 仍 2 live(dead 不算)
}
