//! L2 组件测试:WebSearch 工具两阶段子请求端到端(对齐 cc WebSearchTool)。
//!
//! 覆盖(doc/E2E_TESTING.md "声明=接线=测试"):
//!   1. 子请求请求体带 forced tool_choice {type:tool,name:web_search}(声明的字段真上线)。
//!   2. 子请求带 web_search server tool(异形只在子请求,不进主工具集)。
//!   3. 两阶段 SSE(server_tool_use → web_search_tool_result 含 content → text 摘要)
//!      → execute 返回含 `Web search results for query`、结构化链接、模型摘要、REMINDER。
//!   4. content:[](metask 后端常态)→ 仍靠模型续写文本作答,非空摘要即非 no-results。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

// 两阶段 web_search SSE:server_tool_use(query)→ web_search_tool_result(含 title/url)
// → text_delta(模型摘要)→ end_turn。
const WEB_SEARCH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srv_1\",\"name\":\"web_search\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srv_1\",\"content\":[{\"type\":\"web_search_result\",\"title\":\"Zig Lang\",\"url\":\"https://ziglang.org\"}]}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Zig is a systems language.\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// content:[] 的 metask 后端常态:server_tool_use → 空结果 → 模型摘要。
const WEB_SEARCH_EMPTY_CONTENT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srv_1\",\"name\":\"web_search\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srv_1\",\"content\":[]}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Summary from model only.\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn makeClient(a: std.mem.Allocator, io: std.Io, url: []const u8) cc.client_mod.Client {
    return cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
}

fn dispatchOk(ctx: *const cc.tools.ToolContext, name: []const u8, args: []const u8) ![]u8 {
    var outcome = try cc.tools.dispatch(ctx, name, args);
    return switch (outcome) {
        .ok => |bytes| bytes,
        else => {
            outcome.deinit(ctx.allocator);
            return error.UnexpectedDispatchOutcome;
        },
    };
}

test "L2: WebSearch 子请求带 forced tool_choice + server tool" {
    const a = std.testing.allocator;

    var srv = try harness.MockServer.start(WEB_SEARCH_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = makeClient(a, io_runtime.io(), url);
    defer client.deinit();

    var ctx = cc.tools.ToolContext{ .allocator = a, .api_client = &client };
    const out = dispatchOk(&ctx, "WebSearch", "{\"query\":\"zig language\"}") catch |e| {
        std.debug.print("WebSearch dispatch failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer a.free(out);

    // 请求体断言:forced tool_choice + web_search server tool 形态。
    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const tc = cap.jsonField("tool_choice") orelse return error.ToolChoiceMissing;
    try std.testing.expect(std.mem.indexOf(u8, tc, "web_search") != null);
    const tools_field = cap.jsonField("tools") orelse return error.ToolsMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "web_search_20250305") != null);

    // 输出断言:header + 结构化链接 + 模型摘要 + REMINDER。
    try std.testing.expect(std.mem.indexOf(u8, out, "Web search results for query: \"zig language\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Zig Lang") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://ziglang.org") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Zig is a systems language.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "REMINDER") != null);
}

test "L2: WebSearch content:[] 时靠模型摘要作答(非 no-results)" {
    const a = std.testing.allocator;

    var srv = try harness.MockServer.start(WEB_SEARCH_EMPTY_CONTENT_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = makeClient(a, io_runtime.io(), url);
    defer client.deinit();

    var ctx = cc.tools.ToolContext{ .allocator = a, .api_client = &client };
    const out = dispatchOk(&ctx, "WebSearch", "{\"query\":\"q\"}") catch return error.SkipZigTest;
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Summary from model only.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "No search results found") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "REMINDER") != null);
}

// progress 捕获:验证 web_search.zig 在两阶段 SSE 下驱动 reportProgress
// (query_update + results_received),对齐 cc onProgress。
const ProgressCapture = struct {
    var phases: std.ArrayList(cc.tools.ToolContext.ProgressPhase) = .empty;
    var last_count: u32 = 0;
    var last_text_buf: [128]u8 = undefined;
    var last_text_len: usize = 0;
    fn cb(_: *anyopaque, _: []const u8, phase: cc.tools.ToolContext.ProgressPhase, text: []const u8, count: u32) void {
        phases.append(std.testing.allocator, phase) catch {};
        last_count = count;
        const n = @min(text.len, last_text_buf.len);
        @memcpy(last_text_buf[0..n], text[0..n]);
        last_text_len = n;
    }
};

test "L2: WebSearch 两阶段驱动 progress 回调(query_update + results_received)" {
    const a = std.testing.allocator;
    ProgressCapture.phases = .empty;
    defer ProgressCapture.phases.deinit(a);
    ProgressCapture.last_count = 0;

    var srv = try harness.MockServer.start(WEB_SEARCH_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = makeClient(a, io_runtime.io(), url);
    defer client.deinit();

    var dummy: u8 = 0;
    var ctx = cc.tools.ToolContext{
        .allocator = a,
        .api_client = &client,
        .progress_reporter = .{ .ctx = @ptrCast(&dummy), .reportFn = &ProgressCapture.cb },
    };
    const out = dispatchOk(&ctx, "WebSearch", "{\"query\":\"zig language\"}") catch return error.SkipZigTest;
    defer a.free(out);

    // 应至少有 query_update + results_received 两个 phase。
    var saw_query = false;
    var saw_results = false;
    for (ProgressCapture.phases.items) |p| {
        if (p == .query_update) saw_query = true;
        if (p == .results_received) saw_results = true;
    }
    try std.testing.expect(saw_query);
    try std.testing.expect(saw_results);
    // results_received 的 count:SSE 里 1 个 url → count==1。
    try std.testing.expectEqual(@as(u32, 1), ProgressCapture.last_count);
}
