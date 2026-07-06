//! KG 注入段构建(设计 v3-final §5)。
//!
//! 渐进披露:注入段只是启动快照(plan root 标题 + ready 前 3 + 计数 + 时效声明),
//! 实时真相靠 TaskList。**空态零输出**(无 kg_root / frontier 空 → 一个字不注入)。
//! 预算:记忆通道合计目标 300-600 tok(本段自身 ≤ ~40 行硬截断兜底)。
//!
//! 线程模型:App init 派后台线程跑 buildSummary(store-info/frontier 可能被目录锁
//! 卡最长 35s,绝不阻塞启动);产物是**不可变快照字符串**,主线程 turn 边界取用
//! (Linus 条件 4 方案 a:零锁,单向 handoff,经 atomic flag)。

const std = @import("std");
const client_mod = @import("client.zig");

pub const MAX_READY_SHOWN: usize = 3;

/// 读 per-project 指针文件(kg_root / kg_inbox;设计 §2)。缺失/空/非数字 → null。
/// 线程安全:路径缓冲在栈上(主线程 /kg 与后台构建线程都会调)。
pub fn readIdPointer(allocator: std.mem.Allocator, projects_dir: []const u8, name: []const u8) ?u64 {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ projects_dir, name }, 0) catch return null;
    defer allocator.free(path);
    const f = std.c.fopen(path.ptr, "r") orelse return null;
    defer _ = std.c.fclose(f);
    var buf: [32]u8 = undefined;
    const n = std.c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    const s = std.mem.trim(u8, buf[0..n], " \r\n\t");
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// 写指针文件(plan 落图/inbox 懒建时用;P2 主用,P1 供测试与 /kg)。
pub fn writeIdPointer(allocator: std.mem.Allocator, projects_dir: []const u8, name: []const u8, id: u64) !void {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ projects_dir, name }, 0) catch return error.OutOfMemory;
    defer allocator.free(path);
    const f = std.c.fopen(path.ptr, "w") orelse return error.WriteFailed;
    defer _ = std.c.fclose(f);
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch unreachable;
    _ = std.c.fwrite(s.ptr, 1, s.len, f);
}

/// 删指针文件(stale 防御:root NotFound → 清指针,设计 §3)。
pub fn clearIdPointer(allocator: std.mem.Allocator, projects_dir: []const u8, name: []const u8) void {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ projects_dir, name }, 0) catch return;
    defer allocator.free(path);
    _ = std.c.unlink(path.ptr);
}

/// 构建注入段。返回 null = 空态(零输出);否则 owned 字符串。
/// 在后台线程调用(内部 spawn tinykg;主线程绝不直接调)。
pub fn buildSummary(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    projects_dir: []const u8,
) ?[]u8 {
    if (!kg.ready) return null;
    const root_id = readIdPointer(allocator, projects_dir, "kg_root") orelse return null;

    // stale 防御:root 不存在/非 task → 清指针,空态。
    const is_task = kg.nodeIsTask(root_id) catch return null;
    if (!is_task) {
        clearIdPointer(allocator, projects_dir, "kg_root");
        return null;
    }

    const rows = kg.frontier(root_id, 50) catch return null;
    defer {
        for (rows) |*r| r.deinit(allocator);
        allocator.free(rows);
    }
    if (rows.len == 0) return null; // 空 frontier:图存在但无开放任务 → 不占预算

    return renderSummary(allocator, root_id, rows) catch null;
}

/// 纯渲染(可单测):frontier rows → 注入段文本。
pub fn renderSummary(allocator: std.mem.Allocator, root_id: u64, rows: []const client_mod.FrontierRow) ![]u8 {
    var ready_count: usize = 0;
    var blocked_count: usize = 0;
    for (rows) |r| {
        if (r.readiness == .ready) ready_count += 1 else blocked_count += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPrint(&out, allocator, "# Knowledge Graph — 持久任务图(root {d})\n", .{root_id});
    try appendPrint(&out, allocator, "开放任务:{d} ready / {d} blocked(共 {d})\n", .{ ready_count, blocked_count, rows.len });
    var shown: usize = 0;
    for (rows) |r| {
        if (r.readiness != .ready) continue;
        if (shown >= MAX_READY_SHOWN) break;
        shown += 1;
        try appendPrint(&out, allocator, "- [{d}] {s}\n", .{ r.task_id, firstLineTrunc(r.text, 120) });
    }
    if (ready_count > MAX_READY_SHOWN) try appendPrint(&out, allocator, "- …还有 {d} 个 ready 任务\n", .{ready_count - MAX_READY_SHOWN});
    try out.appendSlice(allocator, "此为启动快照,以 TaskList 实时结果为准。\n");
    return out.toOwnedSlice(allocator);
}

fn appendPrint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn firstLineTrunc(text: []const u8, max: usize) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var end = @min(line_end, max);
    while (end > 0 and (text[end - 1] & 0xC0) == 0x80) end -= 1; // UTF-8 边界
    return text[0..end];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "renderSummary 空态外的完整渲染:计数/ready 前3/快照声明" {
    const a = testing.allocator;
    var rows = [_]client_mod.FrontierRow{
        .{ .task_id = 11, .readiness = .ready, .text = @constCast("步骤一:读代码\n第二行不显示") },
        .{ .task_id = 12, .readiness = .missing_dependencies, .text = @constCast("步骤二") },
        .{ .task_id = 13, .readiness = .ready, .text = @constCast("步骤三") },
        .{ .task_id = 14, .readiness = .ready, .text = @constCast("步骤四") },
        .{ .task_id = 15, .readiness = .ready, .text = @constCast("步骤五") },
    };
    const s = try renderSummary(a, 1, &rows);
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "root 1") != null);
    try testing.expect(std.mem.indexOf(u8, s, "4 ready / 1 blocked(共 5)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[11] 步骤一:读代码") != null);
    try testing.expect(std.mem.indexOf(u8, s, "第二行不显示") == null); // 只取首行
    try testing.expect(std.mem.indexOf(u8, s, "[15]") == null); // 超出前3不列
    try testing.expect(std.mem.indexOf(u8, s, "还有 1 个 ready") != null);
    try testing.expect(std.mem.indexOf(u8, s, "以 TaskList 实时结果为准") != null);
}

test "指针文件读写清:round-trip + 缺失 null + 垃圾 null" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const dir = pbuf[0..dir_len];

    try testing.expect(readIdPointer(a, dir, "kg_root") == null); // 缺失
    try writeIdPointer(a, dir, "kg_root", 42);
    try testing.expectEqual(@as(?u64, 42), readIdPointer(a, dir, "kg_root"));
    clearIdPointer(a, dir, "kg_root");
    try testing.expect(readIdPointer(a, dir, "kg_root") == null);
}
