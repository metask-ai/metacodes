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
/// 发流式请求并 drain 到底(只为让 MockServer 捕获完整请求;响应内容无关紧要)。
/// 任何序列化/传输错误都是失败,不是跳过:否则某个方言开始报 ImageInputUnsupported 时
/// 这些传输测试会全部静默变绿。
fn drainMessages(
    a: std.mem.Allocator,
    provider: cc.api_provider.Provider,
    messages: []const cc.types_mod.ApiMessage,
) !void {
    const handle = try provider.sendStreamRetry(messages, null, null, null, null, null, 1, 1, null, "");
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

// ── ⑯ 投影层:超限图片必须原样穿过 result_projection 到达 wire ──────────────────
//
// 上面 ①-⑥ 直接调 Provider vtable,绕开了 agent_loop 的一次性 tool-result 投影。
// 修复前:base64 超过 TOOL_RESULT_CONTEXT_MAX_BYTES(64 KiB)的图片结果在到达方言
// 序列化器之前就被 spillOne 换成 artifact 信封,extractImageResult 永不命中,三家
// provider 收到的是 base64 预览文本而不是图。本测试走真实 Read 工具 + 真实 agent_loop。

const pfs = @import("platform").fs;

/// Anthropic 脚本:模型对 `path` 发 Read tool_use(input 经 input_json_delta 累积)。
fn readToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

fn writeFixture(path: [*:0]const u8, content: []const u8) !void {
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = pfs.write(fd, content[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

test "L2 ⑯: 超过投影上限的真实 Read 图片经 agent_loop 到达 wire 仍是 image block,不被投影信封替换" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);

    // 60000 原始字节 → 80000 base64 字符:高于 TOOL_RESULT_CONTEXT_MAX_BYTES(64 KiB),
    // 不论模型窗口多大,修复前一定被 per-result 投影 spill。Read 只按扩展名定 media type、
    // 不校验图片魔数,确定性伪随机字节足够。
    const raw_len: usize = 60_000;
    const raw = try a.alloc(u8, raw_len);
    defer a.free(raw);
    var seed: u32 = 0x9E37_79B9;
    for (raw) |*byte| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        byte.* = @truncate(seed);
    }
    const path = try std.fmt.allocPrint(a, "{s}/big.png", .{root});
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try writeFixture(path_z, raw);

    const encoder = std.base64.standard.Encoder;
    const expected_b64 = try a.alloc(u8, encoder.calcSize(raw_len));
    defer a.free(expected_b64);
    _ = encoder.encode(expected_b64, raw);
    try std.testing.expect(expected_b64.len > cc.conversation.TOOL_RESULT_CONTEXT_MAX_BYTES);

    const tool_sse = try readToolSse(a, path);
    defer a.free(tool_sse);
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ tool_sse, ANTHROPIC_OK_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "look at big.png");

    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 3,
        .cwd_abs = root,
        .home_dir = root,
        // 真实 artifact store:修复前这里产生的是 *可恢复* 信封,不是失存储兜底。
        .artifact_root = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    const body = srv.lastRequest().?.body();
    // 图片本体以 Anthropic image source block 到达,base64 逐字节一致。
    const expected_block = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}}}", .{expected_b64});
    defer a.free(expected_block);
    try std.testing.expect(std.mem.indexOf(u8, body, expected_block) != null);
    // 投影信封绝不出现(schema 字面量在原文/JSON 转义两种形态下都无引号,可直接 grep)。
    try std.testing.expect(std.mem.indexOf(u8, body, cc.result_projection.SCHEMA) == null);
    // 原始 `{"type":"image",...}` JSON 也绝不作为转义文本发出。
    try std.testing.expect(std.mem.indexOf(u8, body, "{\\\"type\\\":\\\"image\\\"") == null);

    // 送达水位由真实请求推进:tool_result 所在的 user 消息随第二次请求发出 → delivered;
    // 最后的 assistant 回复之后没有再发请求 → 仍未送达。
    const items = conv.messages.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expect(items[2].blocks[0] == .tool_result);
    try std.testing.expect(items[2].delivered);
    try std.testing.expect(items[3].role == .assistant);
    try std.testing.expect(!items[3].delivered);
}

test "L2 ⑰: 第二次请求被 4xx 拒绝时 tool_result 保持未送达——水位只在请求上线时推进,不在每轮开头" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const raw = "PNG-ish fixture bytes, size is irrelevant for delivery";
    const path = try std.fmt.allocPrint(a, "{s}/small.png", .{root});
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try writeFixture(path_z, raw);

    // 第一轮 200(模型发 Read tool_use);第二轮 400(带着 tool_result 的请求被拒,没有流句柄)。
    const tool_sse = try readToolSse(a, path);
    defer a.free(tool_sse);
    var srv = try harness.MockServer.startHttpCassette(
        &[_][]const u8{ tool_sse, "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"nope\"}}" },
        &[_][]const u8{ "HTTP/1.1 200 OK", "HTTP/1.1 400 Bad Request" },
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "look at small.png");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 3,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);

    // 第一次请求上线 → 首条 user 消息已送达;第二次请求没有拿到流句柄 → tool_use/tool_result 未送达。
    const items = conv.messages.items;
    try std.testing.expect(items.len >= 3);
    try std.testing.expect(items[0].delivered);
    try std.testing.expect(items[1].role == .assistant and !items[1].delivered);
    try std.testing.expect(items[2].blocks[0] == .tool_result and !items[2].delivered);
}

test "L2 ⑱: 非 vision 网关模型(glm-5.2)Read 图片被执行期门控——wire 上是 capability_unsupported 错误(非占位/非图片),transcript 无 base64,错误结果照常送达" {
    const a = std.testing.allocator;
    const r = try runReadImageCase(a, "glm-5.2", null, null);
    defer r.deinit(a);
    try std.testing.expect(r.gated);
    try std.testing.expect(!r.image_on_wire);
    try std.testing.expect(!r.placeholder_on_wire);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "cannot receive images on this route") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"is_error\":true") != null);
    // 没有目录 → 如实说本路由没有模型声明 image_input,不编造候选。
    try std.testing.expect(std.mem.indexOf(u8, r.body, "no model on this route declares image input") != null);
    // 门控在读盘前:tool_result 是文本错误,不含图片 JSON,所以它是普通送达。
    try std.testing.expect(r.result_is_error);
    try std.testing.expect(!r.result_has_image_json);
    try std.testing.expect(r.delivered);
}

/// 一次"Read 图片 → 回复"的两轮会话(Anthropic 路由)。`catalog_json` 非 null 时先灌进
/// client 目录(模拟启动时 `/v1/models` 探测的结果)。返回第二次请求体的副本与判定位。
const ReadImageOutcome = struct {
    body: []u8,
    image_on_wire: bool,
    placeholder_on_wire: bool,
    gated: bool,
    delivered: bool,
    result_is_error: bool,
    result_has_image_json: bool,

    fn deinit(self: ReadImageOutcome, a: std.mem.Allocator) void {
        a.free(self.body);
    }
};

fn runReadImageCase(a: std.mem.Allocator, base_model: []const u8, override: ?[]const u8, catalog_json: ?[]const u8) !ReadImageOutcome {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const path = try std.fmt.allocPrint(a, "{s}/pic.png", .{root});
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try writeFixture(path_z, "tiny fixture; delivery semantics only");

    const tool_sse = try readToolSse(a, path);
    defer a.free(tool_sse);
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ tool_sse, ANTHROPIC_OK_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", base_model, url);
    defer client.deinit();
    if (catalog_json) |json| try client.catalog.loadFromModelsListJson(json);
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "look at pic.png");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 3,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        .model_override = override,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const body = srv.lastRequest().?.body();
    const items = conv.messages.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expect(items[0].delivered and items[1].delivered);
    try std.testing.expect(items[2].blocks[0] == .tool_result);
    try std.testing.expect(!items[3].delivered);
    const tr = items[2].blocks[0].tool_result;
    return .{
        .body = try a.dupe(u8, body),
        .image_on_wire = std.mem.indexOf(u8, body, "{\"type\":\"image\",\"source\":{\"type\":\"base64\"") != null,
        .placeholder_on_wire = std.mem.indexOf(u8, body, "was read successfully but omitted: this model does not support image input") != null,
        .gated = std.mem.indexOf(u8, body, "capability_unsupported") != null,
        .delivered = items[2].delivered,
        .result_is_error = tr.is_error,
        .result_has_image_json = std.mem.indexOf(u8, tr.content, "\"type\":\"image\"") != null,
    };
}

/// 跑一次"Read 图片 → 回复"的两轮会话,返回 (第二次请求体含图像块?, 被执行期门控?, tool_result 消息已送达?)。
fn runOverrideDelivery(a: std.mem.Allocator, base_model: []const u8, override: ?[]const u8) !struct { image_on_wire: bool, gated: bool, delivered: bool } {
    const r = try runReadImageCase(a, base_model, override, null);
    defer r.deinit(a);
    return .{ .image_on_wire = r.image_on_wire, .gated = r.gated, .delivered = r.delivered };
}

/// 与 dialect.zig 默认 Dialect 相同的 fail-closed 方言:profile 声称支持图像,serializeImagePart
/// 却返回 false——插件/运行时方言覆盖的真实形态。
fn failClosedResolve(_: *const anyopaque, _: cc.api_dialect.ProviderKind, _: []const u8) cc.api_dialect.Dialect {
    return .{ .ctx = undefined };
}

test "L2 ㉑: 运行时方言 profile 说支持图像但序列化器拒绝时——wire 是占位文本,含图消息不算送达" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const path = try std.fmt.allocPrint(a, "{s}/pic.png", .{root});
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try writeFixture(path_z, "fail-closed dialect fixture");

    const tool_sse = try readToolSse(a, path);
    defer a.free(tool_sse);
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ tool_sse, ANTHROPIC_OK_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    // vision 模型 + fail-closed 方言:能力表说能看图,序列化器实际发的是占位。
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    client.dialect_resolver = .{ .resolveFn = failClosedResolve };
    try std.testing.expect(client.provider().supports(.image_input));
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "look at pic.png");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 3,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "was read successfully but omitted: this model does not support image input") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\",\"source\"") == null);
    const items = conv.messages.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expect(items[0].delivered and items[1].delivered);
    try std.testing.expect(items[2].blocks[0] == .tool_result and !items[2].delivered);
}

test "L2 ㉒: 请求级图片字节上限——历史里最老的已送达图片被清成 stub,wire 上只剩上限内的图片" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "look at both pictures");
    const T = struct {
        fn imageTurn(c: *cc.conversation.Conversation, al: std.mem.Allocator, id: []const u8, fill: u8) !void {
            const tu = try al.alloc(cc.core_message.Block, 1);
            tu[0] = .{ .tool_use = .{ .id = try al.dupe(u8, id), .name = try al.dupe(u8, "Read"), .input = try al.dupe(u8, "{}") } };
            try c.append(.{ .role = .assistant, .blocks = tu });
            const data = try al.alloc(u8, 4096);
            defer al.free(data);
            @memset(data, fill);
            const img = try std.fmt.allocPrint(al, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{data});
            const blocks = try al.alloc(cc.core_message.Block, 1);
            blocks[0] = .{ .tool_result = .{ .tool_use_id = try al.dupe(u8, id), .content = img, .is_error = false } };
            try c.append(.{ .role = .user, .blocks = blocks });
        }
    };
    try T.imageTurn(&conv, a, "t1", 'A');
    try T.imageTurn(&conv, a, "t2", 'B');
    // Both pictures were delivered by earlier requests.
    conv.markDelivered(.{ .image_placeholder_ids = &.{} });
    const one = conv.messages.items[2].blocks[0].tool_result.content.len;

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{
        .max_turns = 1,
        .image_request_bytes_cap = one + 64,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    const body = srv.lastRequest().?.body();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "{\"type\":\"image\",\"source\":{\"type\":\"base64\""));
    try std.testing.expect(std.mem.indexOf(u8, body, "BBBB") != null); // the newer picture survives
    try std.testing.expect(std.mem.startsWith(u8, conv.messages.items[2].blocks[0].tool_result.content, cc.conversation.TOOL_RESULT_CLEARED_STUB));
}

/// 一轮 Read(image):assistant tool_use + user 图像结果(4096 字节 `fill` 的 base64 载荷)。
fn appendImageTurn(c: *cc.conversation.Conversation, al: std.mem.Allocator, id: []const u8, fill: u8) !void {
    const tu = try al.alloc(cc.core_message.Block, 1);
    tu[0] = .{ .tool_use = .{ .id = try al.dupe(u8, id), .name = try al.dupe(u8, "Read"), .input = try al.dupe(u8, "{}") } };
    try c.append(.{ .role = .assistant, .blocks = tu });
    const data = try al.alloc(u8, 4096);
    defer al.free(data);
    @memset(data, fill);
    const img = try std.fmt.allocPrint(al, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{data});
    const blocks = try al.alloc(cc.core_message.Block, 1);
    blocks[0] = .{ .tool_result = .{ .tool_use_id = try al.dupe(u8, id), .content = img, .is_error = false } };
    try c.append(.{ .role = .user, .blocks = blocks });
}

test "L2 ㉔: 一等用户图片占掉额度后,新读入的图片结果在投影阶段被 spill,wire 上只有用户图片" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const raw = try a.alloc(u8, 4096);
    defer a.free(raw);
    @memset(raw, 0x42);
    const path = try std.fmt.allocPrint(a, "{s}/fresh.png", .{root});
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    try writeFixture(path_z, raw);

    const tool_sse = try readToolSse(a, path);
    defer a.free(tool_sse);
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ tool_sse, ANTHROPIC_OK_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    // 用户先贴了一张一等图片(4096 字节 base64):它永远不可裁剪,只能压缩新结果的额度。
    const user_png = "A" ** 4096;
    const inputs = [_]cc.core_message.ImageInput{.{ .media_type = "image/png", .data = user_png }};
    {
        // Ownership moves into the conversation on append: the errdefer must not
        // outlive the append, or a later failed assertion double-frees the blocks.
        var user_msg = try cc.core_message.userMessageWithImages(a, "compare with fresh.png", &inputs);
        errdefer user_msg.deinit(a);
        try conv.append(user_msg);
    }
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 3,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        // 额度只够用户图片 + 1000 字节:新读入的 5.4 KB 图片结果必须在投影阶段 spill 成信封。
        .image_request_bytes_cap = user_png.len + 1000,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const body = srv.lastRequest().?.body();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "{\"type\":\"image\",\"source\":{\"type\":\"base64\""));
    try std.testing.expect(std.mem.indexOf(u8, body, cc.result_projection.SCHEMA) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "QkJCQkJC") == null); // the fresh picture's base64 never reaches the wire
}

test "L2 ㉓: transcript resume 后(送达标记随 transcript 持久化)请求级图片上限仍生效——最老的已送达图片被裁掉,wire 上只剩一张" {
    const a = std.testing.allocator;
    const tmp_home = "/tmp/cc-zig-image-cap-resume-l2";
    cc.util_fs.testing.rmrfBestEffort(tmp_home);
    defer cc.util_fs.testing.rmrfBestEffort(tmp_home);
    var writer = try cc.transcript.Writer.init(a, "/dummy", tmp_home, "claude-sonnet-4-20250514", cc.transcript.genSessionId());
    defer writer.deinit();
    {
        // 会话 A:两轮已被回复的图片 + 新的 user 提问,落盘。
        var conv_a = cc.conversation.Conversation.init(a);
        defer conv_a.deinit();
        try conv_a.appendText(.user, "look at both pictures");
        try appendImageTurn(&conv_a, a, "t1", 'A');
        try conv_a.appendText(.assistant, "saw the first");
        try appendImageTurn(&conv_a, a, "t2", 'B');
        try conv_a.appendText(.assistant, "saw the second");
        // Both pictures were carried natively by accepted requests of session A.
        conv_a.markDelivered(.{ .image_placeholder_ids = &.{} });
        try conv_a.appendText(.user, "and now?");
        writer.flush(&conv_a);
    }
    // 会话 B:恢复 → 水位随 transcript 持久化:两张图片的块级标记为 true,新提问为 false。
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try cc.transcript.loadTranscript(&conv, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 8), conv.messages.items.len);
    try std.testing.expect(conv.messages.items[2].blocks[0].tool_result.delivered);
    try std.testing.expect(conv.messages.items[5].blocks[0].tool_result.delivered);
    try std.testing.expect(!conv.messages.items[7].delivered);
    const one = conv.messages.items[2].blocks[0].tool_result.content.len;

    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{
        .max_turns = 1,
        .image_request_bytes_cap = one + 64,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    // 被 assistant 回复过的最老图片被裁掉;wire 上只有第二张。
    const body = srv.lastRequest().?.body();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "{\"type\":\"image\",\"source\":{\"type\":\"base64\""));
    try std.testing.expect(std.mem.indexOf(u8, body, "BBBB") != null);
    try std.testing.expect(std.mem.startsWith(u8, conv.messages.items[2].blocks[0].tool_result.content, cc.conversation.TOOL_RESULT_CLEARED_STUB));
}

test "L2 ⑲: model_override 决定门控与送达——基础模型非 vision、override 为 vision 时 Read 放行,图片上 wire 且送达" {
    const a = std.testing.allocator;
    const r = try runOverrideDelivery(a, "glm-5.2", "claude-sonnet-4-20250514");
    try std.testing.expect(!r.gated);
    try std.testing.expect(r.image_on_wire);
    try std.testing.expect(r.delivered);
}

test "L2 ⑳: model_override 决定门控——基础模型 vision、override 非 vision 时 Read 按 override 的能力被门控,wire 上无图无占位" {
    const a = std.testing.allocator;
    const r = try runOverrideDelivery(a, "claude-sonnet-4-20250514", "glm-5.2");
    try std.testing.expect(r.gated);
    try std.testing.expect(!r.image_on_wire);
    // 错误结果是文本,照常送达(占位路径才是"含图消息不算送达")。
    try std.testing.expect(r.delivered);
}

test "L2 ㉕: 目录声明 image_input=true 的非 Claude 名(glm-5.3-flash)经 Anthropic 路由——家族表不认识它,目录说了算:原生 image block 上 wire 且送达" {
    const a = std.testing.allocator;
    const catalog = "{\"data\":[{\"id\":\"GLM-5.3-Flash\",\"max_input_tokens\":200000,\"capabilities\":{\"thinking\":{\"supported\":true},\"image_input\":{\"supported\":true}}}]}";
    // 没有目录时家族表 fail-closed(会被门控)。
    const without = try runReadImageCase(a, "glm-5.3-flash", null, null);
    defer without.deinit(a);
    try std.testing.expect(without.gated);
    try std.testing.expect(!without.image_on_wire);
    // 目录声明 supported=true(模型名大小写与目录不同也命中)→ 门控放行、序列化发原生块。
    const with = try runReadImageCase(a, "glm-5.3-flash", null, catalog);
    defer with.deinit(a);
    try std.testing.expect(!with.gated);
    try std.testing.expect(with.image_on_wire);
    try std.testing.expect(!with.placeholder_on_wire);
    try std.testing.expect(with.delivered);
    try std.testing.expect(with.result_has_image_json);
}

test "L2 ㉖: 目录声明 image_input=false 覆盖家族表——Claude 名在这条路由上收不了图,Read 被门控,wire 上无图无占位" {
    const a = std.testing.allocator;
    const catalog = "{\"data\":[{\"id\":\"claude-sonnet-4-20250514\",\"capabilities\":{\"image_input\":{\"supported\":false}}}]}";
    const r = try runReadImageCase(a, "claude-sonnet-4-20250514", null, catalog);
    defer r.deinit(a);
    try std.testing.expect(r.gated);
    try std.testing.expect(!r.image_on_wire);
    try std.testing.expect(!r.placeholder_on_wire);
    try std.testing.expect(r.delivered);
}

test "L2 ㉗: 非 vision 活动模型读图——错误 detail 点名活动模型,并列出目录里声明能看图的模型" {
    const a = std.testing.allocator;
    const catalog = "{\"data\":[" ++
        "{\"id\":\"GLM-5.2\",\"capabilities\":{\"image_input\":{\"supported\":false}}}," ++
        "{\"id\":\"glm-5.3-flash\",\"capabilities\":{\"image_input\":{\"supported\":true}}}," ++
        "{\"id\":\"claude-sonnet-4-6\",\"capabilities\":{\"image_input\":{\"supported\":true}}}," ++
        "{\"id\":\"deepseek-chat\",\"capabilities\":{\"image_input\":{\"supported\":false}}}]}";
    const r = try runReadImageCase(a, "GLM-5.2", null, catalog);
    defer r.deinit(a);
    try std.testing.expect(r.gated);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "GLM-5.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "glm-5.3-flash, claude-sonnet-4-6") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "deepseek-chat") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "Switch with /model <id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "no model on this route declares image input") == null);
}

test "L2 ㉘(issue #112): 非 Claude 的已知 vision 家族(gpt-5.6-sol)经 Anthropic 兼容路由——不再因名字不含 claude 被拒,image block 上 wire" {
    const a = std.testing.allocator;
    const r = try runReadImageCase(a, "gpt-5.6-sol", null, null);
    defer r.deinit(a);
    try std.testing.expect(!r.gated);
    try std.testing.expect(r.image_on_wire);
    try std.testing.expect(r.delivered);
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
    _ = harness.normalizeSlashes(root_buffer[0..root_len]); // Windows: JSON 字面量里的反斜杠会被当转义

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
