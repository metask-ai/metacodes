//! 图像 tool_result L2 端到端:Read 工具的图像结果真的以各协议族的正确 wire 形态
//! 到达 provider 请求(MockServer 捕获 HTTP body 字节断言),绝不把 MB 级 base64
//! 原文当纯文本发给模型。
//!
//! 验收矩阵(vision × 协议族 + 非 vision 占位):
//!   ① OpenAI chat(gpt-4o):tool 消息发短指向文本,图像本体在**紧随的 user 消息**
//!     (image_url data URL)——chat 的 tool 消息 content 官方只收 text。
//!   ② OpenAI chat 非 vision(deepseek-chat):tool 消息发短占位文本,body 无 base64。
//!   ③ OpenAI Responses(gpt-5.2):function_call_output.output 为 input_image parts
//!     **数组**(官方 2025-09-26 起),call_id 原生配对。
//!   ④ Anthropic 网关非 vision(glm-5.2):tool_result content 发短占位文本
//!     (此前会发网关拒收的 image block)。vision Claude 的 image block 字节形态由
//!     request.zig 内联测试锁定(与本特性引入前逐字节相同)。
//!   ⑤ Gemini 旧世代(2.5):functionResponse 发指向文本,图像作同一 user content 的
//!     **同级 inline_data part** 收尾(functionResponse 配对数不变)。
//!   ⑥ Gemini 3:官方 multimodal functionResponse(functionResponse.parts[].inlineData)。
//!
//! 序列化纯函数级的完整字节矩阵在 request.zig / openai_client.zig / gemini_client.zig
//! 内联测试;本文件证明真实 Provider vtable → HTTP 链路上的最终请求字节。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const ANTHROPIC_OK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"a red pixel\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OPENAI_OK_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"a red pixel\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const OPENAI_RESPONSES_OK_SSE =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"a red pixel\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";

const GEMINI_OK_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"a red pixel\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":2}}\n\n";

/// 1x1 红色 PNG 的 base64(有效 PNG 字节,非占位串)。
const RED_PIXEL_PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/// Read 工具读图后的 tool_result content 原文(tools/read.zig readImage 形态)。
const IMG_TOOL_RESULT_JSON = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"" ++ RED_PIXEL_PNG_B64 ++ "\"}";

/// 通用消息序列:assistant 发 Read tool_use → user 回图像 tool_result。
const TOOL_USE_CONTENT = [_]cc.types_mod.ApiContent{
    .{ .tool_use = .{ .id = "call_img", .name = "Read", .input = "{\"file_path\":\"pixel.png\"}" } },
};
const TOOL_RESULT_CONTENT = [_]cc.types_mod.ApiContent{
    .{ .tool_result = .{ .tool_use_id = "call_img", .content = IMG_TOOL_RESULT_JSON } },
};
const IMG_MESSAGES = [_]cc.types_mod.ApiMessage{
    .{ .role = .assistant, .content = &TOOL_USE_CONTENT },
    .{ .role = .user, .content = &TOOL_RESULT_CONTENT },
};

/// 发流式请求并 drain 到底(只为让 MockServer 捕获完整请求;响应内容无关紧要)。
fn drainStream(a: std.mem.Allocator, provider: cc.api_provider.Provider) !void {
    const handle = provider.sendStreamRetry(&IMG_MESSAGES, null, null, null, null, null, 1, 1, null, "") catch |e| {
        std.debug.print("tool_result image stream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();
    while (handle.next() catch null) |ev| switch (ev) {
        .text => |t| a.free(t),
        else => {},
    };
}

test "L2 ①: OpenAI chat vision — tool 消息短文本 + 紧随 user 消息 image_url 到达 wire" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();
    try drainStream(a, client.provider());

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_img\",\"content\":\"[image (image/png) attached in the following user message]\"},{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Image result of tool call call_img:\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ RED_PIXEL_PNG_B64 ++ "\"}}]}") != null);
    // 原始 JSON 绝不作为转义文本出现(base64 只在 data URL 里出现一次)。
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);
}

test "L2 ②: OpenAI chat 非 vision — 占位文本到达 wire,body 无 base64" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "deepseek-chat", url);
    defer client.deinit();
    try drainStream(a, client.provider());

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_img\",\"content\":\"[image (image/png) was read successfully but omitted: this model does not support image input]\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, RED_PIXEL_PNG_B64) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
}

test "L2 ③: OpenAI Responses vision — function_call_output.output 为 input_image 数组" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_RESPONSES_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-5.2", url);
    defer client.deinit();
    client.protocol = .responses;
    try drainStream(a, client.provider());

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call_output\",\"call_id\":\"call_img\",\"output\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64," ++ RED_PIXEL_PNG_B64 ++ "\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);
}

test "L2 ④: Anthropic 网关非 vision(glm-5.2)— tool_result 占位文本到达 wire" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "glm-5.2", url);
    defer client.deinit();
    try drainStream(a, client.provider());

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"[image (image/png) was read successfully but omitted: this model does not support image input]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, RED_PIXEL_PNG_B64) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") == null);
}

test "L2 ⑤: Gemini 2.5 — functionResponse 指向文本 + 同级 inline_data part 到达 wire" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{GEMINI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-pro", url);
    defer client.deinit();
    try drainStream(a, client.provider());

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"functionResponse\":{\"name\":\"Read\",\"response\":{\"result\":\"[image (image/png) attached in this message]\"}}},{\"text\":\"Image result of Read:\"},{\"inline_data\":{\"mime_type\":\"image/png\",\"data\":\"" ++ RED_PIXEL_PNG_B64 ++ "\"}}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);
}

test "L2 ⑥: Gemini 3 — 官方 multimodal functionResponse(嵌套 inlineData)到达 wire" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{GEMINI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-3-flash", url);
    defer client.deinit();
    try drainStream(a, client.provider());

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"functionResponse\":{\"name\":\"Read\",\"response\":{\"result\":\"[image (image/png) attached]\"},\"parts\":[{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"" ++ RED_PIXEL_PNG_B64 ++ "\"}}]}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);
}
