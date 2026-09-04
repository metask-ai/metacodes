//! L2 组件测试:工具并发执行(批1 对齐 cc isConcurrencySafe + 分批)。
//!
//! 验证:① isConcurrencySafe 分类 ② executeSlots 对 safe 批并发跑、结果按原 index 回填
//! ③ denied slot 不执行、内容保留 ④ 结果顺序严格等于 slot 顺序(tool_result 不能乱序)。
//! 用 Glob(spawn ripgrep,离线可跑)做真实并发执行。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const tool_exec = cc.tool_exec;
const tools = cc.tools;

test "L2 并发: isConcurrencySafe 分类" {
    try std.testing.expect(tools.isConcurrencySafe("Read"));
    try std.testing.expect(tools.isConcurrencySafe("Glob"));
    try std.testing.expect(tools.isConcurrencySafe("Grep"));
    try std.testing.expect(tools.isConcurrencySafe("WebFetch"));
    // 静态 API 保守为 false；tool_exec 只在有 provider factory 时动态升级。
    try std.testing.expect(!tools.isConcurrencySafe("WebSearch"));
    try std.testing.expect(!tools.isConcurrencySafe("Write"));
    try std.testing.expect(!tools.isConcurrencySafe("Edit"));
    try std.testing.expect(!tools.isConcurrencySafe("Bash"));
    try std.testing.expect(!tools.isConcurrencySafe("Task"));
}

test "L2 #5: 没有 provider factory 时两个 WebSearch 不重叠使用 session client" {
    const Probe = struct {
        active: std.atomic.Value(usize) = .init(0),
        max_active: std.atomic.Value(usize) = .init(0),

        fn dispatch(raw: *const anyopaque, tool_ctx: *const tools.ToolContext, _: []const u8, _: []const u8) anyerror!tools.ToolDispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            const now = self.active.fetchAdd(1, .acq_rel) + 1;
            if (now > self.max_active.load(.acquire)) self.max_active.store(now, .release);
            defer _ = self.active.fetchSub(1, .acq_rel);

            // 若 executeSlots 错把 WebSearch 放进并发批，第一项会等到第二项进入，
            // max_active 必然变成 2；串行路径则有限等待后返回，再执行第二项。
            if (now == 1) {
                for (0..100_000) |_| {
                    if (self.active.load(.acquire) > 1) break;
                    std.Thread.yield() catch {};
                }
            }
            return .{ .ok = tools.ToolResultBody.initInline(try tool_ctx.allocator.dupe(u8, "ok")) };
        }
        fn metadata(_: *const anyopaque, _: []const u8) ?tools.ToolMeta {
            // .external(非 host)→ 并发判定继续走名字/输入分类,WebSearch 保持串行语义。
            return .{ .kind = .external, .category = .execute, .replay = .never, .prefetch_safe = false };
        }
        fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
            return if (index == 0) "WebSearch" else null;
        }
        fn dispatcher(self: *@This()) tools.ToolDispatcher {
            return .{
                .ctx = @ptrCast(self),
                .dispatchFn = dispatch,
                .metadataFn = metadata,
                .nameAtFn = nameAt,
            };
        }
    };

    const a = std.testing.allocator;
    var probe = Probe{};
    var slots = [_]tool_exec.Slot{
        .{ .decision = .run, .name = "WebSearch", .id = "ws1", .input = "{\"query\":\"one\"}" },
        .{ .decision = .run, .name = "WebSearch", .id = "ws2", .input = "{\"query\":\"two\"}" },
    };
    defer for (&slots) |*slot| slot.deinit(a);
    const ctx = tools.ToolContext{ .allocator = a, .tool_dispatcher = probe.dispatcher() };

    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    try std.testing.expectEqual(@as(usize, 1), probe.max_active.load(.acquire));
    try std.testing.expectEqualStrings("ok", slots[0].content.?);
    try std.testing.expectEqualStrings("ok", slots[1].content.?);
}

test "L2 WebSearch 独立 provider 让混合批并发且 Read 不被隔离" {
    const Probe = struct {
        active: std.atomic.Value(usize) = .init(0),
        max_active: std.atomic.Value(usize) = .init(0),
        web_active: std.atomic.Value(bool) = .init(false),
        web_overlap: std.atomic.Value(bool) = .init(false),

        fn dispatch(raw: *const anyopaque, tool_ctx: *const tools.ToolContext, name: []const u8, _: []const u8) anyerror!tools.ToolDispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            const now = self.active.fetchAdd(1, .acq_rel) + 1;
            var seen = self.max_active.load(.acquire);
            while (now > seen) {
                seen = self.max_active.cmpxchgWeak(seen, now, .acq_rel, .acquire) orelse break;
            }
            const is_web = std.mem.eql(u8, name, "WebSearch");
            if (is_web) {
                if (now > 1) self.web_overlap.store(true, .release);
                self.web_active.store(true, .release);
            } else if (self.web_active.load(.acquire)) {
                self.web_overlap.store(true, .release);
            }
            // A provider factory makes all four slots one safe batch. Wait for
            // the whole batch so the assertion is scheduler-deterministic. The
            // wait is wall-clock bounded, not iteration bounded: 100k yields
            // elapse in milliseconds when nothing else is runnable (Windows
            // SwitchToThread returns at once), and on a loaded runner (CI ran
            // the AgentCore gate on the same box) the fourth slot's thread was
            // not scheduled yet, so the peak read 3. A batch that genuinely
            // never runs concurrently still fails: it never reaches 4 and the
            // deadline expires.
            const deadline = cc.util_time.nowMs() + 5_000;
            while (self.active.load(.acquire) != 4 and cc.util_time.nowMs() < deadline) {
                cc.util_time.sleepMs(1);
            }
            if (is_web) self.web_active.store(false, .release);
            _ = self.active.fetchSub(1, .acq_rel);
            return .{ .ok = tools.ToolResultBody.initInline(try tool_ctx.allocator.dupe(u8, "ok")) };
        }
        fn metadata(_: *const anyopaque, _: []const u8) ?tools.ToolMeta {
            // .external(非 host)→ WebSearch/Read 的并发能力仍由名字/输入分类决定。
            return .{ .kind = .external, .category = .execute, .replay = .never, .prefetch_safe = false };
        }
        fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
            return switch (index) {
                0 => "WebSearch",
                1 => "Read",
                else => null,
            };
        }
        fn dispatcher(self: *@This()) tools.ToolDispatcher {
            return .{
                .ctx = @ptrCast(self),
                .dispatchFn = dispatch,
                .metadataFn = metadata,
                .nameAtFn = nameAt,
            };
        }
    };

    const a = std.testing.allocator;
    var probe = Probe{};
    const DummyFactory = struct {
        fn make(_: *anyopaque) anyerror!cc.api_provider_factory.OwnedProvider {
            return error.TestFactoryMustNotRun;
        }
    };
    var dummy: u8 = 0;
    var slots = [_]tool_exec.Slot{
        .{ .decision = .run, .name = "WebSearch", .id = "ws1", .input = "{}" },
        .{ .decision = .run, .name = "Read", .id = "r1", .input = "{}" },
        .{ .decision = .run, .name = "Read", .id = "r2", .input = "{}" },
        .{ .decision = .run, .name = "WebSearch", .id = "ws2", .input = "{}" },
    };
    defer for (&slots) |*slot| slot.deinit(a);
    const ctx = tools.ToolContext{
        .allocator = a,
        .tool_dispatcher = probe.dispatcher(),
        .provider_factory = .{ .ctx = @ptrCast(&dummy), .makeFn = &DummyFactory.make },
    };

    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    try std.testing.expectEqual(@as(usize, 4), probe.max_active.load(.acquire));
    try std.testing.expect(probe.web_overlap.load(.acquire));
}

fn mkdir(p: [*:0]const u8) void {
    _ = std.c.mkdir(p, 0o755);
}
fn touch(p: [*:0]const u8) void {
    const fd = pfs.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd >= 0) pfs.close(fd);
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
    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
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
    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
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
    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    try std.testing.expect(slots[0].is_error);
    // P0.6:UnknownTool 错误现在附"does not exist + 可用工具清单"引导(而非旧的裸 "UnknownTool"),
    // 弱模型据此自纠。断言错误码(unknown_tool)在,且含引导文案 + 至少一个真工具名。
    const content = slots[0].content.?;
    try std.testing.expect(std.mem.indexOf(u8, content, "unknown_tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "does not exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Read") != null); // 可用工具清单含 Read
}

test "L2 并发: executeSlots 保留聚合大结果给 hook/UI 后置投影" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-budget-home", 0o755);
    // 3 个 denied slot 各预填 ~80k 内容。dispatch 层必须保持原字节；
    // agent_loop 才是唯一投影提交点。
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
    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });

    var total: usize = 0;
    for (slots) |s| {
        const c = s.content.?;
        total += c.len;
        try std.testing.expectEqual(@as(usize, 80_000), c.len);
        try std.testing.expectEqual(@as(u8, 'Z'), c[0]);
    }
    try std.testing.expectEqual(@as(usize, 240_000), total);
}

test "L2 并发: per-input 分类(Bash readonly safe / 写 unsafe)" {
    try std.testing.expect(tools.isConcurrencySafeInput("Bash", "{\"command\":\"ls -la\"}"));
    try std.testing.expect(tools.isConcurrencySafeInput("Bash", "{\"command\":\"git status\"}"));
    try std.testing.expect(!tools.isConcurrencySafeInput("Bash", "{\"command\":\"rm -rf x\"}"));
    try std.testing.expect(!tools.isConcurrencySafeInput("Bash", "{\"command\":\"echo hi > f\"}"));
    // 非 Bash 沿用名单
    try std.testing.expect(tools.isConcurrencySafeInput("Read", "{\"file_path\":\"/x\"}"));
    try std.testing.expect(!tools.isConcurrencySafeInput("Write", "{\"file_path\":\"/x\",\"content\":\"y\"}"));
}

test "L2 并发: executeSlots 对 Read/Grep 都不提前投影" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-budget-home2", 0o755);
    // ReadArtifact 的防环由 result_projection 的 inline-only policy 保证；
    // dispatch 层不再按工具名做持久化分叉。
    const big = try a.alloc(u8, 90_000);
    defer a.free(big);
    @memset(big, 'R');
    var slots = [_]tool_exec.Slot{
        .{ .decision = .denied, .name = "Read", .id = "r", .input = "{}", .content = try a.dupe(u8, big), .is_error = false },
        .{ .decision = .denied, .name = "Grep", .id = "g1", .input = "{}", .content = try a.dupe(u8, big), .is_error = false },
        .{ .decision = .denied, .name = "Grep", .id = "g2", .input = "{}", .content = try a.dupe(u8, big), .is_error = false },
    };
    defer for (&slots) |*s| if (s.content) |c| a.free(c);
    const ctx = cc.tool_context.ToolContext{ .allocator = a, .home_dir = "/tmp/cc-budget-home2" };
    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });

    for (slots) |slot| {
        try std.testing.expectEqual(@as(usize, 90_000), slot.content.?.len);
        try std.testing.expectEqual(@as(u8, 'R'), slot.content.?[0]);
    }
}
