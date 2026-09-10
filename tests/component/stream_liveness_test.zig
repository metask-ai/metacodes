//! 流存活性 L2:对端"连接活着、字节不来"时,请求必须在有界时间内结束,不能永远等。
//!
//! 2026-09-10 的真实故障:TaskBatch 派出的一个子 agent 的第一个请求在网关侧沉默,ESTABLISHED
//! 连接 40 分钟没有一个字节;子 agent 线程卡在 readv,看门狗/Ctrl+C 的 abort 标志只在事件之间
//! 被检查,主线程 join 整批,TUI 冻死。修法分三层,本文件逐层用真 HTTP 链路证明:
//!   ① 收头阶段沉默 → 注册表空闲监视 shutdown 连接 → TransientNetwork → sendStreamRetry 重试成功;
//!   ② 正文阶段沉默 → StreamStalled → 本轮以 api_error 结束(不挂死);
//!   ③ TaskBatch 并发:一个 item 沉默,整批仍在空闲上限的量级内返回;
//!   ④ 父 abort → watchdog 同时 provider.cancel:空闲上限远大于等待时间也能立即叫醒子 agent。
//! MockServer 的沉默模式(startCassetteSilent)是"不关连接"的故障——与 flaky/midstream_cut
//! (服务端关连接)互补:那两种此前已有覆盖,这一种此前不可测,所以缺口活到了生产。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const OK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"alive\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// 正文前两个事件的字节数:沉默模式发完这些再停,模拟"流开始了、中途对端不再发"。
const MID_STREAM_PREFIX: usize = blk: {
    const first = std.mem.indexOf(u8, OK_SSE, "\n\n").? + 2;
    const second = std.mem.indexOfPos(u8, OK_SSE, first, "\n\n").? + 2;
    break :blk second;
};

/// 测试用空闲上限:秒级可复现,又远大于 MockServer 正常回包的耗时。
const IDLE_MS: u64 = 400;
/// 单个用例的墙钟上限:空闲上限 + 监视 tick + 一次重试退避(≤625ms)+ 余量。真挂死会远超。
const BOUND_MS: i64 = 8_000;

fn runOneTurn(a: std.mem.Allocator, client: *cc.client_mod.Client, abort: ?*const cc.util_abort.AbortSignal) !cc.agent_loop.RunResult {
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    return cc.agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 1,
        .abort = abort,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
}

test "L2 liveness ①: 收头阶段对端沉默 → 空闲监视 shutdown 连接 → 重试第二次成功,耗时有界" {
    const a = std.testing.allocator;
    // 响应 0 一个字节都不发(连响应头都没有),响应 1 正常。
    var srv = try harness.MockServer.startCassetteSilent(&[_][]const u8{ OK_SSE, OK_SSE }, 0, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();
    client.stream_idle_timeout_ms = IDLE_MS;

    const t0 = cc.util_time.nowMs();
    const result = try runOneTurn(a, &client, null);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    try std.testing.expect(elapsed >= @as(i64, @intCast(IDLE_MS)));
    try std.testing.expect(elapsed < BOUND_MS);
}

test "L2 liveness ②: 正文阶段对端沉默 → StreamStalled 结束本轮(api_error),不挂死也不空转重试" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteSilent(&[_][]const u8{OK_SSE}, 0, MID_STREAM_PREFIX);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();
    client.stream_idle_timeout_ms = IDLE_MS;

    const t0 = cc.util_time.nowMs();
    const result = try runOneTurn(a, &client, null);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(elapsed >= @as(i64, @intCast(IDLE_MS)));
    try std.testing.expect(elapsed < BOUND_MS);
}

test "L2 liveness: StreamStalled 归为可重试错误(与 TransientNetwork 同类)" {
    try std.testing.expect(cc.client_mod.isRetriableError(error.StreamStalled));
    try std.testing.expect(cc.client_mod.isRetriableError(error.TransientNetwork));
    try std.testing.expect(!cc.client_mod.isRetriableError(error.RequestFailed));
}

fn batchCtx(a: std.mem.Allocator, client: *cc.client_mod.Client, reg: *cc.agent_job_registry.AgentJobRegistry, perm: *const cc.permission.PermissionContext, abort: ?*const cc.util_abort.AbortSignal) cc.tool_context.ToolContext {
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    return .{
        .allocator = a,
        .api_client = client,
        .tool_defs = empty_defs,
        .permission_ctx = @constCast(perm),
        .agent_jobs = reg,
        .agent_depth = 0,
        .abort = abort,
    };
}

test "L2 liveness ③: TaskBatch 并发——一个 item 对端沉默,整批仍有界返回(沉默项经重试完成)" {
    const a = std.testing.allocator;
    // 3 个 item 并发各发一个请求;响应 1 沉默(无字节),其余正常。沉默项被空闲监视叫醒后重试,
    // 第 4 个请求拿到 cassette 末条 → 3 个都 completed,请求总数 4。
    var srv = try harness.MockServer.startCassetteSilent(&[_][]const u8{ OK_SSE, OK_SSE, OK_SSE }, 1, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(std.heap.c_allocator, "k", url, "claude-3-5-haiku-20241022", .anthropic);
    defer reg.deinit();
    reg.stream_idle_timeout_ms = IDLE_MS;
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = batchCtx(a, &client, &reg, &perm, null);

    const t0 = cc.util_time.nowMs();
    const res = try cc.tools_task_batch.execute(&ctx,
        \\{"prompt_template":"handle {x}","items":[{"x":"a"},{"x":"b"},{"x":"c"}]}
    );
    defer a.free(res);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expect(std.mem.indexOf(u8, res, "\"total\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"completed\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"failed\":0") != null);
    try std.testing.expectEqual(@as(usize, 4), srv.requestCount());
    try std.testing.expect(elapsed < BOUND_MS);
}

fn abortAfter(signal: *cc.util_abort.AbortSignal, delay_ms: u64) void {
    cc.util_time.sleepMs(delay_ms);
    signal.abort(.user_ctrl_c);
}

test "L2 liveness ④: 父 abort → watchdog 同时 cancel 在飞请求:空闲上限 60s 也能在秒级叫醒沉默的子 agent" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteSilent(&[_][]const u8{OK_SSE}, 0, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(std.heap.c_allocator, "k", url, "claude-3-5-haiku-20241022", .anthropic);
    defer reg.deinit();
    reg.stream_idle_timeout_ms = 60_000; // 空闲监视故意远大于用例时长:只有 cancel 能救
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var parent = cc.util_abort.AbortSignal.init();
    var ctx = batchCtx(a, &client, &reg, &perm, &parent);

    const aborter = try std.Thread.spawn(.{}, abortAfter, .{ &parent, 300 });
    defer aborter.join();
    const t0 = cc.util_time.nowMs();
    const res = try cc.tools_task_batch.execute(&ctx,
        \\{"prompt_template":"handle {x}","items":[{"x":"a"}]}
    );
    defer a.free(res);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expect(std.mem.indexOf(u8, res, "\"total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"completed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"failed\":1") != null);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(elapsed < BOUND_MS);
}
