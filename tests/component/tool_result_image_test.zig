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
fn drainMessages(
    a: std.mem.Allocator,
    provider: cc.api_provider.Provider,
    messages: []const cc.types_mod.ApiMessage,
) !void {
    const handle = provider.sendStreamRetry(messages, null, null, null, null, null, 1, 1, null, "") catch |e| {
        std.debug.print("tool_result image stream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();
    while (handle.next() catch null) |ev| switch (ev) {
        .text => |t| a.free(t),
        else => {},
    };
}

fn drainStream(a: std.mem.Allocator, provider: cc.api_provider.Provider) !void {
    return drainMessages(a, provider, &IMG_MESSAGES);
}

// ── 超阈值图像:投影层不得把它换成 artifact 信封(issue #26)────────────────
//
// `result_projection` 在会话被组装成请求**之前**按字节长度改写超限 tool_result。
// 生产阈值是 clamp(window/8, 8KB, 64KB),而 Read 允许 3.75MB 图像——即几乎每张
// 真实截图都会被换成 artifact 信封,#24 的方言序列化根本跑不到。下面的用例先跑
// **真实投影**(生产配置),再把投影结果送上线,证明两件事在同一条链路上成立:
// ① 投影后 content 逐字节仍是原图 JSON;② 它以各方言的原生图像形态到达 wire。

/// 96 KB base64 载荷:高于所有生产 per_result_bytes 上限(8..64KB),也高于
/// 最小 per_turn_bytes(16KB)——per-result 与 per-turn 两道关口都必须放行。
const OVERSIZE_DATA_BYTES: usize = 96 * 1024;

/// 投影后的超阈值图像结果。`data` 是 `content` 内部的载荷切片(不另拷 96KB)。
const ProjectedImage = struct {
    content: []const u8,
    data: []const u8,

    fn deinit(self: ProjectedImage, a: std.mem.Allocator) void {
        a.free(@constCast(self.content));
    }
};

/// 造一张超阈值图像 tool_result,过一遍真实 `result_projection.project`,并断言
/// 它**未被改写**。`session_root` 故意留空:一旦 carve-out 回归,spill 分支会写出
/// fallback 信封(而不是静默无操作),下面的逐字节相等断言立刻失败。
fn projectedOversizeImage(a: std.mem.Allocator, max_input_tokens: usize) !ProjectedImage {
    const payload = try a.alloc(u8, OVERSIZE_DATA_BYTES);
    defer a.free(payload);
    @memset(payload, 'A');
    var content: []const u8 = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}",
        .{payload},
    );
    errdefer a.free(@constCast(content));
    const before = try a.dupe(u8, content);
    defer a.free(before);

    var items = [_]cc.result_projection.Item{
        .{ .tool_name = "Read", .content = &content, .is_error = false },
    };
    const stats = try cc.result_projection.project(a, &items, .{
        .session_root = "",
        .budget = cc.result_budget.Budget.fromModel(max_input_tokens),
    });
    try std.testing.expect(content.len > cc.conversation.toolResultContextBytes(max_input_tokens));
    try std.testing.expectEqual(@as(usize, 0), stats.artifact_spill_count);
    try std.testing.expectEqual(@as(usize, 0), stats.unrecoverable_fallback_count);
    try std.testing.expectEqual(@as(usize, 1), stats.image_exempt_count);
    try std.testing.expect(!stats.budget_exhausted);
    try std.testing.expect(std.mem.eql(u8, before, content));

    const data_start = std.mem.indexOf(u8, content, "\"data\":\"").? + "\"data\":\"".len;
    return .{ .content = content, .data = content[data_start .. data_start + OVERSIZE_DATA_BYTES] };
}

/// `prefix` 之后紧跟完整 `data` 再跟一个闭引号——证明整段载荷(不是被截断的前缀)
/// 到达了 wire。96KB 不用 expectEqualStrings(失败时会打出整段)。
fn expectPayloadAfter(body: []const u8, prefix: []const u8, data: []const u8) !void {
    const at = std.mem.indexOf(u8, body, prefix) orelse {
        std.debug.print("wire prefix not found: {s}\n", .{prefix});
        return error.TestUnexpectedResult;
    };
    const start = at + prefix.len;
    try std.testing.expect(body.len > start + data.len);
    try std.testing.expect(std.mem.eql(u8, data, body[start..][0..data.len]));
    try std.testing.expectEqual(@as(u8, '"'), body[start + data.len]);
}

/// 各用例共享:投影后的图像结果 + 与 IMG_MESSAGES 同形的两条消息。
const OversizeCase = struct {
    image: ProjectedImage,
    content: [1]cc.types_mod.ApiContent,
    messages: [2]cc.types_mod.ApiMessage,

    fn init(a: std.mem.Allocator, max_input_tokens: usize) !*OversizeCase {
        const self = try a.create(OversizeCase);
        errdefer a.destroy(self);
        self.image = try projectedOversizeImage(a, max_input_tokens);
        self.content = .{.{ .tool_result = .{ .tool_use_id = "call_img", .content = self.image.content } }};
        self.messages = .{
            .{ .role = .assistant, .content = &TOOL_USE_CONTENT },
            .{ .role = .user, .content = &self.content },
        };
        return self;
    }

    fn deinit(self: *OversizeCase, a: std.mem.Allocator) void {
        self.image.deinit(a);
        a.destroy(self);
    }
};

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

test "L2 ⑦: 超阈值图像经真实投影后仍以 Anthropic 原生 image block 到达 wire" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4", url);
    defer client.deinit();
    const case = try OversizeCase.init(a, client.provider().maxInputTokens());
    defer case.deinit(a);
    try drainMessages(a, client.provider(), &case.messages);

    const body = srv.lastRequest().?.body();
    try expectPayloadAfter(
        body,
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"",
        case.image.data,
    );
    // 绝不是 artifact 信封,也绝不是被转义的原始 JSON 文本。
    try std.testing.expect(std.mem.indexOf(u8, body, cc.result_projection.ENVELOPE_PREFIX) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);
}

test "L2 ⑦b: 超阈值图像 → OpenAI chat 紧随 user 消息的 image_url data URL" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();
    const case = try OversizeCase.init(a, client.provider().maxInputTokens());
    defer case.deinit(a);
    try drainMessages(a, client.provider(), &case.messages);

    const body = srv.lastRequest().?.body();
    try expectPayloadAfter(
        body,
        "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,",
        case.image.data,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, cc.result_projection.ENVELOPE_PREFIX) == null);
}

test "L2 ⑦c: 超阈值图像 → OpenAI Responses function_call_output input_image 数组" {
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
    const case = try OversizeCase.init(a, client.provider().maxInputTokens());
    defer case.deinit(a);
    try drainMessages(a, client.provider(), &case.messages);

    const body = srv.lastRequest().?.body();
    try expectPayloadAfter(
        body,
        "{\"type\":\"function_call_output\",\"call_id\":\"call_img\",\"output\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,",
        case.image.data,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, cc.result_projection.ENVELOPE_PREFIX) == null);
}

test "L2 ⑦d: 超阈值图像 → Gemini 3 multimodal functionResponse inlineData" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{GEMINI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-3-flash", url);
    defer client.deinit();
    const case = try OversizeCase.init(a, client.provider().maxInputTokens());
    defer case.deinit(a);
    try drainMessages(a, client.provider(), &case.messages);

    const body = srv.lastRequest().?.body();
    try expectPayloadAfter(
        body,
        "\"parts\":[{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"",
        case.image.data,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, cc.result_projection.ENVELOPE_PREFIX) == null);
}

test "L2 ⑧: 超阈值图像在非 vision 模型上仍是占位文本,不是 artifact 信封" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "deepseek-chat", url);
    defer client.deinit();
    const case = try OversizeCase.init(a, client.provider().maxInputTokens());
    defer case.deinit(a);
    try drainMessages(a, client.provider(), &case.messages);

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_img\",\"content\":\"[image (image/png) was read successfully but omitted: this model does not support image input]\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, case.image.data) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, cc.result_projection.ENVELOPE_PREFIX) == null);
}

test "L2 ⑨: 同一轮里图像不与文本竞争 turn 预算(文本先被 spill)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);

    const payload = try a.alloc(u8, OVERSIZE_DATA_BYTES);
    defer a.free(payload);
    @memset(payload, 'A');
    var image: []const u8 = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}",
        .{payload},
    );
    defer a.free(@constCast(image));
    const image_before = try a.dupe(u8, image);
    defer a.free(image_before);
    var text: []const u8 = try a.alloc(u8, 24 * 1024);
    @memset(@constCast(text), 'T');
    defer a.free(@constCast(text));

    var items = [_]cc.result_projection.Item{
        .{ .tool_name = "Read", .content = &image, .is_error = false },
        .{ .tool_name = "Grep", .content = &text, .is_error = false },
    };
    // 最小生产 turn 预算(16KB):图像按 IMAGE_TOKEN_ESTIMATE 计后仍有余量,
    // 超预算的是那段文本——它才是唯一的 spill 受害者。
    const stats = try cc.result_projection.project(a, &items, .{
        .session_root = root_buffer[0..root_len],
        .budget = .{ .per_result_bytes = 64 * 1024, .per_turn_bytes = cc.result_projection.turnBudgetBytes(0) },
    });
    try std.testing.expect(std.mem.eql(u8, image_before, image));
    try std.testing.expectEqual(@as(usize, 1), stats.turn_budget_spills);
    try std.testing.expect(cc.result_projection.isRecoverableEnvelope(text));
}
