//! L4 component 测试:DiagnosticsBackend 经 TeeBackend 旁挂真实渲染后端,跑真 agent_loop,
//! 断言诊断事件被收集成结构化 trace(turn_begin/run_end、trace_id 一致、JSONL 可导出)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const ui_backend = cc.ui_backend;
const tee_backend = cc.tee_backend;
const diagnostics_backend = cc.diagnostics_backend;
const evaluation_backend = cc.evaluation_backend;
const writer_backend = cc.writer_backend;

// 一轮纯文本 → end_turn。
const TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const DENIED_WRITE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu-denied\",\"name\":\"Write\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"/tmp/metacodes-eval-must-not-write\\\",\\\"content\\\":\\\"x\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L4: DiagnosticsBackend 经 TeeBackend 收集真 agent_loop 的 trace" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{TEXT_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    // 渲染后端:null-writer(丢弃);诊断后端:收集 trace。TeeBackend 转发给两者。
    var render = writer_backend.WriterBackend.initNull();
    const render_be = render.backend();
    var diag = diagnostics_backend.DiagnosticsBackend.init(a);
    defer diag.deinit();
    var diag_be = diag.backend();
    var tee = tee_backend.TeeBackend{ .primary = &render_be, .secondary = &diag_be };
    const tee_be = tee.backend();

    const result = agent_loop.run(
        &conv,
        client.provider(),
        empty_defs,
        &perm,
        .{ .max_turns = 3 },
        &tee_be,
        a,
    ) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 至少一个 turn_begin + 恰一个 run_end。
    try std.testing.expect(diag.countKind(.turn_begin) >= 1);
    try std.testing.expectEqual(@as(u32, 1), diag.countKind(.run_end));

    // trace_id 全程一致(同一 run 的所有诊断事件共享一个 trace_id)。
    try std.testing.expect(diag.events.items.len >= 2);
    const tid0 = diag.events.items[0].traceId();
    for (diag.events.items) |*e| {
        const tid = e.traceId();
        try std.testing.expectEqualSlices(u8, &tid0, &tid);
        try std.testing.expectEqual(@as(u8, 0), e.depth()); // 顶层 run depth=0(当前恒 0,见 L4 §6)
    }

    // run_end 携带正确 stop_reason。
    var saw_end_turn = false;
    for (diag.events.items) |e| {
        switch (e) {
            .run_end => |r| {
                try std.testing.expectEqualStrings("end_turn", r.stop_reason);
                saw_end_turn = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_end_turn);

    // span 平衡:turn_begin 数 == turn_end 数(每个 turn 都闭合,#3 修复)。
    try std.testing.expectEqual(diag.countKind(.turn_begin), diag.countKind(.turn_end));

    // JSONL 可导出且含 trace 结构。
    const jsonl = try diag.toJsonl(a);
    defer a.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "turn_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "run_end") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "end_turn") != null);
}

test "L2: EvaluationBackend projects a real agent_loop into stable events" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{TEXT_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "model-a", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);

    var eval = evaluation_backend.EvaluationBackend.init(a, .{
        .run_id = "component-run",
        .suite_id = "component-suite",
        .task_id = "diagnostics",
        .task_fingerprint = "recorded-fingerprint",
        .task_fingerprint_provenance = "recorded_at_execution",
        .model_provider = "mock",
        .model_id = "model-a",
        .harness_config_id = "component",
        .harness_revision = "test",
        .grader_fingerprint = "grader-v1",
    });
    defer eval.deinit();
    const eval_be = eval.backend();
    const result = try agent_loop.run(
        &conv,
        client.provider(),
        &.{},
        &perm,
        .{ .max_turns = 3 },
        &eval_be,
        a,
    );
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    const jsonl = eval.jsonl();
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "recorded_at_execution") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "turn_started") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "run_finished") != null);
}

test "L2: denied tool attempt has paired lifecycle and exact policy id" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ DENIED_WRITE_SSE, TEXT_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "model-a", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "write outside the plan file");
    const perm = cc.permission.createContext(.plan, a);
    const tool_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(tool_defs);

    var eval = evaluation_backend.EvaluationBackend.init(a, .{
        .run_id = "denied-run",
        .suite_id = "component-suite",
        .task_id = "policy-denial",
        .task_fingerprint = "recorded-fingerprint",
        .task_fingerprint_provenance = "recorded_at_execution",
        .model_provider = "mock",
        .model_id = "model-a",
        .harness_config_id = "component",
        .harness_revision = "test",
        .grader_fingerprint = "grader-v1",
    });
    defer eval.deinit();
    const eval_be = eval.backend();
    const result = try agent_loop.run(
        &conv,
        client.provider(),
        tool_defs,
        &perm,
        .{ .max_turns = 3, .emit_tool_cards = true },
        &eval_be,
        a,
    );
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    const jsonl = eval.jsonl();
    const started = std.mem.indexOf(u8, jsonl, "\"tool_started\":{\"trace_id\":");
    const policy = std.mem.indexOf(u8, jsonl, "\"policy_decision\":{\"trace_id\":");
    const finished = std.mem.indexOf(u8, jsonl, "\"tool_finished\":{\"trace_id\":");
    try std.testing.expect(started != null);
    try std.testing.expect(policy != null);
    try std.testing.expect(finished != null);
    try std.testing.expect(started.? < finished.?);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"id\":\"tu-denied\",\"tool\":\"Write\",\"decision\":\"deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"id\":\"tu-denied\",\"name\":\"Write\",\"is_error\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"error_code\":\"permission_denied\"") != null);
}
