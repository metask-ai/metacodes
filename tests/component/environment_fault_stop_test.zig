//! L2 组件测试:**环境故障出现即告知,累计 3 次即停**(agent_loop 的 environment_fault 熔断)。
//!
//! 事故 2026-09-22:agent 的 cwd 被自己改名后,每次 Bash 都撞同一个环境故障,模型试了 383 次
//! 直到 400 轮上限——预算型 backstop 正确触发了,但它是在损失发生之后。环境故障
//! (`system_error` + `recoverable:false`)换命令重试不可能修好,所以:每次出现都发一条
//! `environment_fault` 事件让用户看见;累计到 MAX_ENVIRONMENT_FAULTS 后以 `.tool_loop` 收口。
//!
//! 手法对齐 weak_model_test:讲 OpenAI 协议的 MockServer 喂 tool_call 卡带,驱动同一个
//! agent_loop.run;工具是一个只会返 `error.WorkingDirectoryUnavailable` 的动态工具——它经
//! tool_error 的 ERROR_MAP 落成 `working_dir_unavailable / system_error / recoverable:false`,
//! 与真 Bash 撞到消失的 cwd 时完全同形。跨模块:agent_loop + tool_exec + tool_error +
//! writer_backend + MockServer(≥3,合 L2)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const openai = cc.api_openai;
const writer_backend = cc.writer_backend;

const FINAL_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

fn callSse(comptime id: []const u8, comptime tool: []const u8) []const u8 {
    return "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"" ++ id ++ "\",\"type\":\"function\",\"function\":{\"name\":\"" ++ tool ++ "\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
}

/// 只会撞环境故障的工具:错误名经 ERROR_MAP → working_dir_unavailable / system_error / recoverable:false。
fn brokenExec(_: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return error.WorkingDirectoryUnavailable;
}

/// 撞可重试 system_error 的工具(Timeout → recoverable:true):证明计数只数不可恢复的。
fn slowExec(_: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return error.Timeout;
}

/// 把 WriterBackend 的字节收进内存,断言用户看到了什么。
const Capture = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn sink(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.bytes.appendSlice(self.allocator, chunk) catch {};
    }

    fn deinit(self: *Capture) void {
        self.bytes.deinit(self.allocator);
    }

    fn has(self: *const Capture, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.bytes.items, needle) != null;
    }
};

const Outcome = struct {
    stop_reason: agent_loop.StopReason,
    requests: usize,
};

fn runCassette(a: std.mem.Allocator, bodies: []const []const u8, capture: *Capture) !Outcome {
    var srv = try harness.MockServer.startCassette(bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "k", "gpt-4o", url);
    defer client.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("broken_tool", "Always hits an environment fault", &.{}, brokenExec, null, false);
    try dyn.register("slow_tool", "Always times out (recoverable)", &.{}, slowExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "do the thing");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);

    var render = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(capture), .sink = Capture.sink };
    const be = render.backend();
    const result = try agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 8, .dyn_registry = &dyn }, &be, a);
    return .{ .stop_reason = result.stop_reason, .requests = srv.requestCount() };
}

test "环境故障:第 3 次后以 tool_loop 停,每次都告知用户,第 4 次模型请求不再发出" {
    const a = std.testing.allocator;
    var capture = Capture{ .allocator = a };
    defer capture.deinit();
    const bodies = [_][]const u8{ callSse("c1", "broken_tool"), callSse("c2", "broken_tool"), callSse("c3", "broken_tool"), FINAL_SSE };
    const out = try runCassette(a, &bodies, &capture);
    try std.testing.expectEqual(agent_loop.StopReason.tool_loop, out.stop_reason);
    // 三次故障 = 三次模型请求;卡带里的 FINAL 从未被取用。
    try std.testing.expectEqual(@as(usize, 3), out.requests);
    try std.testing.expect(capture.has("environment fault 1/3 [broken_tool · working_dir_unavailable]"));
    try std.testing.expect(capture.has("environment fault 2/3"));
    try std.testing.expect(capture.has("environment fault 3/3"));
    try std.testing.expect(capture.has("stopping this run"));
}

test "环境故障:2 次不停,模型自己收尾 → end_turn;告知了 2 次,没有第 3 次" {
    const a = std.testing.allocator;
    var capture = Capture{ .allocator = a };
    defer capture.deinit();
    const bodies = [_][]const u8{ callSse("c1", "broken_tool"), callSse("c2", "broken_tool"), FINAL_SSE };
    const out = try runCassette(a, &bodies, &capture);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), out.requests);
    try std.testing.expect(capture.has("environment fault 2/3"));
    try std.testing.expect(!capture.has("environment fault 3/3"));
    try std.testing.expect(!capture.has("stopping this run"));
}

test "可恢复的 system_error(Timeout)不计数:3 次超时照常跑到 end_turn,不告知环境故障" {
    const a = std.testing.allocator;
    var capture = Capture{ .allocator = a };
    defer capture.deinit();
    const bodies = [_][]const u8{ callSse("c1", "slow_tool"), callSse("c2", "slow_tool"), callSse("c3", "slow_tool"), FINAL_SSE };
    const out = try runCassette(a, &bodies, &capture);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.stop_reason);
    try std.testing.expectEqual(@as(usize, 4), out.requests);
    try std.testing.expect(!capture.has("environment fault"));
}
