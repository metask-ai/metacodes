//! L2 组件测试:工具并发执行(批1 对齐 cc isConcurrencySafe + 分批)。
//!
//! 验证:① isConcurrencySafe 分类 ② executeSlots 对 safe 批并发跑、结果按原 index 回填
//! ③ denied slot 不执行、内容保留 ④ 结果顺序严格等于 slot 顺序(tool_result 不能乱序)。
//! 用 Glob(spawn ripgrep,离线可跑)做真实并发执行。

const std = @import("std");
const cc = @import("cc");

const tool_exec = cc.tool_exec;
const tools = cc.tools;

test "L2 并发: isConcurrencySafe 分类" {
    try std.testing.expect(tools.isConcurrencySafe("Read"));
    try std.testing.expect(tools.isConcurrencySafe("Glob"));
    try std.testing.expect(tools.isConcurrencySafe("Grep"));
    try std.testing.expect(tools.isConcurrencySafe("WebFetch"));
    try std.testing.expect(!tools.isConcurrencySafe("Write"));
    try std.testing.expect(!tools.isConcurrencySafe("Edit"));
    try std.testing.expect(!tools.isConcurrencySafe("Bash"));
    try std.testing.expect(!tools.isConcurrencySafe("Task"));
}

fn mkdir(p: [*:0]const u8) void {
    _ = std.c.mkdir(p, 0o755);
}
fn touch(p: [*:0]const u8) void {
    const fd = std.c.open(p, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.close(fd);
}

test "L2 并发: 3 个 Glob safe 批并发执行,结果按原顺序回填" {
    const a = std.testing.allocator;
    // 准备 3 个目录各含一个独特文件
    mkdir("/tmp/cc-conc");
    mkdir("/tmp/cc-conc/d0");
    mkdir("/tmp/cc-conc/d1");
    mkdir("/tmp/cc-conc/d2");
    touch("/tmp/cc-conc/d0/aaa.txt");
    touch("/tmp/cc-conc/d1/bbb.txt");
    touch("/tmp/cc-conc/d2/ccc.txt");
    defer {
        _ = std.c.unlink("/tmp/cc-conc/d0/aaa.txt");
        _ = std.c.unlink("/tmp/cc-conc/d1/bbb.txt");
        _ = std.c.unlink("/tmp/cc-conc/d2/ccc.txt");
    }

    var slots = [_]tool_exec.Slot{
        .{ .decision = .run, .name = "Glob", .id = "t0", .input = "{\"pattern\":\"*.txt\",\"path\":\"/tmp/cc-conc/d0\"}" },
        .{ .decision = .run, .name = "Glob", .id = "t1", .input = "{\"pattern\":\"*.txt\",\"path\":\"/tmp/cc-conc/d1\"}" },
        .{ .decision = .run, .name = "Glob", .id = "t2", .input = "{\"pattern\":\"*.txt\",\"path\":\"/tmp/cc-conc/d2\"}" },
    };
    const ctx = cc.tool_context.ToolContext{ .allocator = a };
    tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    defer for (&slots) |*s| if (s.content) |c| a.free(c);

    // 每个 slot 拿到自己目录的结果(顺序未乱:t0→aaa,t1→bbb,t2→ccc)
    try std.testing.expect(slots[0].content != null and std.mem.indexOf(u8, slots[0].content.?, "aaa.txt") != null);
    try std.testing.expect(slots[1].content != null and std.mem.indexOf(u8, slots[1].content.?, "bbb.txt") != null);
    try std.testing.expect(slots[2].content != null and std.mem.indexOf(u8, slots[2].content.?, "ccc.txt") != null);
    // 不串台:t0 不含 bbb/ccc
    try std.testing.expect(std.mem.indexOf(u8, slots[0].content.?, "bbb.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, slots[0].content.?, "ccc.txt") == null);
}

test "L2 并发: denied slot 不执行,content 保留" {
    const a = std.testing.allocator;
    var slots = [_]tool_exec.Slot{
        .{ .decision = .denied, .name = "Glob", .id = "x", .input = "{}", .content = try a.dupe(u8, "{\"error\":\"denied\"}"), .is_error = true },
    };
    defer for (&slots) |*s| if (s.content) |c| a.free(c);
    const ctx = cc.tool_context.ToolContext{ .allocator = a };
    tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    // denied 的 content 没被覆盖
    try std.testing.expectEqualStrings("{\"error\":\"denied\"}", slots[0].content.?);
    try std.testing.expect(slots[0].is_error);
}

test "L2 并发: unsafe 工具串行单跑(未知工具→错误,不崩)" {
    const a = std.testing.allocator;
    var slots = [_]tool_exec.Slot{
        .{ .decision = .run, .name = "__unknown__", .id = "u", .input = "{}" },
    };
    defer for (&slots) |*s| if (s.content) |c| a.free(c);
    const ctx = cc.tool_context.ToolContext{ .allocator = a };
    tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    try std.testing.expect(slots[0].is_error);
    try std.testing.expect(slots[0].content != null and std.mem.indexOf(u8, slots[0].content.?, "UnknownTool") != null);
}

test "L2 并发: per-message 聚合预算(多大结果合计超 200k → 落盘最大的)" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-budget-home", 0o755);
    // 3 个 denied slot 各预填 ~80k 内容(decision=.denied 让 executeSlots 不执行,只走聚合预算)
    const big = try a.alloc(u8, 80_000);
    defer a.free(big);
    @memset(big, 'Z');
    var slots = [_]tool_exec.Slot{
        .{ .decision = .denied, .name = "Grep", .id = "a", .input = "{}", .content = try a.dupe(u8, big), .is_error = false },
        .{ .decision = .denied, .name = "Grep", .id = "b", .input = "{}", .content = try a.dupe(u8, big), .is_error = false },
        .{ .decision = .denied, .name = "Grep", .id = "c", .input = "{}", .content = try a.dupe(u8, big), .is_error = false },
    };
    defer for (&slots) |*s| if (s.content) |c| a.free(c);
    const ctx = cc.tool_context.ToolContext{ .allocator = a, .home_dir = "/tmp/cc-budget-home" };
    tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });

    // 合计 240k > 200k → 至少一个被落盘(preview)
    var persisted_count: usize = 0;
    var total: usize = 0;
    for (slots) |s| {
        const c = s.content.?;
        total += c.len;
        if (std.mem.indexOf(u8, c, "\"persisted\":true") != null) persisted_count += 1;
    }
    try std.testing.expect(persisted_count >= 1);
    try std.testing.expect(total <= 200_000); // 落盘后合计达标
}
