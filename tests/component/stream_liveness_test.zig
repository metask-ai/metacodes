//! 流存活性 L2:对端"连接活着、字节不来"时,请求必须在有界时间内结束,不能永远等。
//!
//! 2026-09-10 的真实故障:TaskBatch 派出的一个子 agent 的第一个请求在网关侧沉默,ESTABLISHED
//! 连接 40 分钟没有一个字节;子 agent 线程卡在 readv,看门狗/Ctrl+C 的 abort 标志只在事件之间
//! 被检查,主线程 join 整批,TUI 冻死。修法分三层,本文件逐层用真 HTTP 链路证明:
//!   ① 收头阶段沉默 → 注册表空闲监视 shutdown 连接 → TransientNetwork → sendStreamRetry 重试成功;
//!   ② 正文阶段沉默 → StreamStalled → 本轮以 api_error 结束(不挂死),TUI 文案点名 stall;
//!   ③ TaskBatch 并发:一个 item 沉默,整批仍在空闲上限的量级内返回;
//!   ④ 父 abort → watchdog 同时 provider.cancel:空闲上限远大于等待时间也能立即叫醒子 agent。
//! MockServer 的沉默模式(startCassetteSilent)是"不关连接"的故障——与 flaky/midstream_cut
//! (服务端关连接)互补:那两种此前已有覆盖,这一种此前不可测,所以缺口活到了生产。
//!
//! 2026-09-11 的第二次真实故障(PR #117 之后):一个 126s 的合法工具调用被判 stall。两个病根:
//!   (a) 空闲时钟按**语义事件**重置,而 tool_use 参数的 input_json_delta 串 / ping / unknown 事件
//!       全被迭代器 `continue` 掉——字节每秒都在到,时钟却一直不动;
//!   (b) 平的 120s 上限同样用于正文阶段,而 napi 网关把整个工具调用攒成一条 delta,生成期间零字节,
//!       20-40KB 的调用 = 120-200s 真实沉默,确定性被杀。
//! 本文件继续用真 HTTP 链路证明修法:
//!   ⑤ input_json_delta 帧滴流(帧间隔 < 上限,总时长 ≫ 上限)→ 按字节续命,完整 tool_use 收齐;
//!   ⑥ 只有 ping 的保活 → 算活着,本轮正常 end_turn;
//!   ⑦ 收头阶段用严上限,正文阶段用另一个(更大的)上限:两者独立生效;
//!   ⑧ 非流式(auto-compact 那条路)正文 stall 同样点名而不是塌缩成 RequestFailed。
//!   ⑨ napi 网关先发短文本,零字节沉默超过收头上限但未达正文上限,再突发完整 tool_use → 正常收齐。

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

/// 完整的 tool_use 参数,拆成 6 条 input_json_delta 滴流。老代码只在语义事件处 touch,而这 6 条
/// 全是 `continue`——content_block_start 到 content_block_stop 之间时钟一动不动。
const TOOL_INPUT_JSON = "{\"file_path\":\"/tmp/liveness.txt\",\"content\":\"0123456789\"}";
const TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Write\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"/tmp/live\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"ness.txt\\\",\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"content\\\":\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"01234\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"56789\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
/// TOOL_SSE 的 SSE 事件数(MockServer 每个事件之间 sleep chunk_delay)。
const TOOL_SSE_EVENTS: u64 = 11;

/// 只靠 ping 保活的响应:文本块开了之后是 6 个 ping,再来正文。ping 在迭代器里走 `else => continue`。
const PING_EVENT = "event: ping\ndata: {\"type\": \"ping\"}\n\n";
const PING_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    PING_EVENT ++ PING_EVENT ++ PING_EVENT ++ PING_EVENT ++ PING_EVENT ++ PING_EVENT ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"alive\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const PING_SSE_EVENTS: u64 = 12;

/// 测试用空闲上限:秒级可复现,又远大于 MockServer 正常回包的耗时。
const IDLE_MS: u64 = 400;
/// 滴流帧间隔:小于空闲上限(每一帧都该续命),但整条响应的总时长远超上限——
/// 只有按字节续命才能活过去,按语义事件续命必死。
const TRICKLE_MS: u32 = 150;
/// 单个用例的墙钟上限:空闲上限 + 监视 tick + 一次重试退避(≤625ms)+ 余量。真挂死会远超。
const BOUND_MS: i64 = 8_000;

/// last_error 是进程级单例:同一测试二进制里其它用例可能留下现场,用例开头先清场。
fn clearLastError() void {
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    _ = cc.api_last_error.take(&buf);
}

/// 读 TUI 会打印的那行错误现场(repl/loop.zig .api_error 分支消费的就是 last_error.take)。
fn takeLastError(buf: *[cc.api_last_error.SUMMARY_BUF_LEN]u8) ?[]const u8 {
    return cc.api_last_error.take(buf);
}

fn mkClient(a: std.mem.Allocator, io: std.Io, url: []const u8, head_ms: u64, body_ms: ?u64) cc.client_mod.Client {
    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "k", "claude-3-5-haiku-20241022", url);
    client.stream_idle_timeout_ms = head_ms;
    // 正文阶段默认按 max_tokens 放大到分钟级;测试显式给平上限,让正文 stall 秒级可复现
    // (或故意给大值,证明两个阶段的上限互不干扰)。
    client.stream_body_idle_timeout_ms = body_ms;
    return client;
}

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
    // 正文阶段上限故意远大于用例时长:收头阶段的严上限必须独立于它生效。
    var client = mkClient(a, io_rt.io(), url, IDLE_MS, 60_000);
    defer client.deinit();
    clearLastError();

    const t0 = cc.util_time.nowMs();
    const result = try runOneTurn(a, &client, null);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    try std.testing.expect(elapsed >= @as(i64, @intCast(IDLE_MS)));
    try std.testing.expect(elapsed < BOUND_MS);
    // 重试成功(HTTP 200)清掉收头 stall 的现场:陈旧错误不许活过一次成功。
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    try std.testing.expect(takeLastError(&buf) == null);
}

test "L2 liveness ②: 正文阶段对端沉默 → StreamStalled 结束本轮(api_error),不挂死也不空转重试,TUI 文案点名 stall" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteSilent(&[_][]const u8{OK_SSE}, 0, MID_STREAM_PREFIX);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = mkClient(a, io_rt.io(), url, IDLE_MS, IDLE_MS);
    defer client.deinit();
    clearLastError();

    const t0 = cc.util_time.nowMs();
    const result = try runOneTurn(a, &client, null);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(elapsed >= @as(i64, @intCast(IDLE_MS)));
    try std.testing.expect(elapsed < BOUND_MS);
    // TUI 打印的就是这行:必须点名"正文空闲超时"+ 空闲毫秒 + 生效的上限,而不是
    // "重试耗尽 / 后端错误 / 上下文超限"的猜谜文案。
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    const detail = takeLastError(&buf) orelse return error.TestExpectedLastError;
    const prefix = "正文空闲超时: ";
    try std.testing.expect(std.mem.startsWith(u8, detail, prefix));
    try std.testing.expect(std.mem.indexOf(u8, detail, " ms 内无任何字节(上限 400 ms)") != null);
    const idle_end = std.mem.indexOfPos(u8, detail, prefix.len, " ms").?;
    const idle_ms = try std.fmt.parseInt(u64, detail[prefix.len..idle_end], 10);
    try std.testing.expect(idle_ms >= IDLE_MS);
    try std.testing.expect(takeLastError(&buf) == null); // 读后清空
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

test "L2 liveness ⑤: input_json_delta 帧滴流(帧间隔 < 空闲上限,总时长 ≫ 上限)→ 按字节续命,完整 tool_use 收齐" {
    const a = std.testing.allocator;
    // 每个 SSE 事件之间 sleep TRICKLE_MS:任意相邻两帧的间隔都在上限之内,但从 content_block_start
    // 到 content_block_stop 之间没有任何语义事件,总时长 ≥ 10 × 150ms ≫ 400ms。
    var srv = try harness.MockServer.startCassette(&[_][]const u8{TOOL_SSE}, TRICKLE_MS);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = mkClient(a, io_rt.io(), url, IDLE_MS, IDLE_MS);
    defer client.deinit();
    clearLastError();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    const t0 = cc.util_time.nowMs();
    var handle = try client.provider().sendStream(empty, null, null, null, null, null, "");
    defer handle.deinit();
    var tool_input: ?[]const u8 = null;
    defer if (tool_input) |t| a.free(t);
    var tool_name_ok = false;
    var tool_uses: usize = 0;
    while (try handle.next()) |ev| switch (ev) {
        .text => |t| a.free(t),
        .thinking => |t| a.free(t),
        .tool_use_start => |tu| {
            defer a.free(tu.id);
            defer a.free(tu.name);
            tool_uses += 1;
            tool_name_ok = std.mem.eql(u8, tu.name, "Write");
            if (tool_input) |old| a.free(old);
            tool_input = tu.input_json;
        },
        else => {},
    };
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expectEqual(@as(usize, 1), tool_uses);
    try std.testing.expect(tool_name_ok);
    try std.testing.expectEqualStrings(TOOL_INPUT_JSON, tool_input.?);
    // 流确实活过了空闲上限好几倍——这不是"上限没触发"而是"字节续了命"。
    try std.testing.expect(elapsed >= @as(i64, @intCast((TOOL_SSE_EVENTS - 1) * TRICKLE_MS)));
    try std.testing.expect(elapsed < BOUND_MS);
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    try std.testing.expect(takeLastError(&buf) == null);
}

test "L2 liveness ⑥: 只有 ping 的保活也算活着 → 本轮正常 end_turn" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{PING_SSE}, TRICKLE_MS);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = mkClient(a, io_rt.io(), url, IDLE_MS, IDLE_MS);
    defer client.deinit();
    clearLastError();

    const t0 = cc.util_time.nowMs();
    const result = try runOneTurn(a, &client, null);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(elapsed >= @as(i64, @intCast((PING_SSE_EVENTS - 1) * TRICKLE_MS)));
    try std.testing.expect(elapsed < BOUND_MS);
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    try std.testing.expect(takeLastError(&buf) == null);
}

test "L2 liveness ⑦: 收头/正文阶段各用各的上限——正文沉默按正文上限判(更大),收头严上限不越界" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteSilent(&[_][]const u8{OK_SSE}, 0, MID_STREAM_PREFIX);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    const body_ms: u64 = 1_500;
    var client = mkClient(a, io_rt.io(), url, IDLE_MS, body_ms);
    defer client.deinit();
    clearLastError();

    const t0 = cc.util_time.nowMs();
    const result = try runOneTurn(a, &client, null);
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    // 若正文阶段仍按收头上限(400ms)判,这里会在 ~400-650ms 就结束。
    try std.testing.expect(elapsed >= @as(i64, @intCast(body_ms)));
    try std.testing.expect(elapsed < BOUND_MS);
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    const detail = takeLastError(&buf) orelse return error.TestExpectedLastError;
    try std.testing.expect(std.mem.startsWith(u8, detail, "正文空闲超时: "));
    try std.testing.expect(std.mem.indexOf(u8, detail, "(上限 1500 ms)") != null);
}

test "L2 liveness ⑧: 非流式请求正文阶段沉默 → StreamStalled 并点名(auto-compact 走的就是这条路)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteSilent(&[_][]const u8{OK_SSE}, 0, MID_STREAM_PREFIX);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = mkClient(a, io_rt.io(), url, IDLE_MS, IDLE_MS);
    defer client.deinit();
    clearLastError();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    const t0 = cc.util_time.nowMs();
    try std.testing.expectError(error.StreamStalled, client.sendMessage(empty, null, null));
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expect(elapsed >= @as(i64, @intCast(IDLE_MS)));
    try std.testing.expect(elapsed < BOUND_MS);
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    const detail = takeLastError(&buf) orelse return error.TestExpectedLastError;
    try std.testing.expect(std.mem.startsWith(u8, detail, "正文空闲超时: "));
}

test "L2 liveness ⑨: 短文本后零字节沉默超过收头上限,正文上限内突发完整 tool_use → 正常收齐不报 stall" {
    const a = std.testing.allocator;
    const delay_ms: u32 = 1_500;
    const body_ms: u64 = 6_000;
    // napi 网关实测形状:先发短文本,工具生成期间不发任何字节,完整参数只在一条长 SSE 行里到达。
    const content = "0123456789abcdef" ** 128;
    const input_json = "{\"file_path\":\"/tmp/burst.txt\",\"content\":\"" ++ content ++ "\"}";
    const prefix =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"开始撰写\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n";
    const body = prefix ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_burst\",\"name\":\"Write\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"/tmp/burst.txt\\\",\\\"content\\\":\\\"" ++ content ++ "\\\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1024}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var srv = try harness.MockServer.startCassetteDelayedBurst(&[_][]const u8{body}, 0, prefix.len, delay_ms);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = mkClient(a, io_rt.io(), url, 300, body_ms);
    defer client.deinit();
    clearLastError();
    // 失败时保留具体错误及 TUI 现场,便于区分正文 stall 与其它链路失败。
    errdefer |err| {
        var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
        std.debug.print("run test L2 liveness ⑨: expected normal stream, got {t}; last_error={s}\n", .{
            err, takeLastError(&buf) orelse "<null>",
        });
    }

    const empty: []const cc.types_mod.ApiMessage = &.{};
    const t0 = cc.util_time.nowMs();
    var handle = try client.provider().sendStream(empty, null, null, null, null, null, "");
    defer handle.deinit();
    var text_received = false;
    var tool_uses: usize = 0;
    var done = false;
    while (try handle.next()) |ev| switch (ev) {
        .text => |t| {
            defer a.free(t);
            try std.testing.expectEqualStrings("开始撰写", t);
            text_received = true;
        },
        .thinking => |t| a.free(t),
        .tool_use_start => |tu| {
            defer a.free(tu.id);
            defer a.free(tu.name);
            defer a.free(tu.input_json);
            tool_uses += 1;
            try std.testing.expectEqualStrings("Write", tu.name);
            try std.testing.expectEqualStrings(input_json, tu.input_json);
        },
        .done => done = true,
        else => {},
    };
    const elapsed = cc.util_time.nowMs() - t0;
    try std.testing.expect(text_received);
    try std.testing.expectEqual(@as(usize, 1), tool_uses);
    try std.testing.expect(done);
    // 只断言下界:沉默确实发生在网络上,不限制加载较重的 CI 的总耗时。
    try std.testing.expect(elapsed >= @as(i64, delay_ms));
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    try std.testing.expect(takeLastError(&buf) == null);
}
