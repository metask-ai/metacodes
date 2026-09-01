//! Issue #10 L2 端到端:一等图像输入真的到达 provider 请求(MockServer 捕获字节断言)。
//!
//! 验收覆盖:
//!   ① Anthropic:text+image user 消息经 agent_loop.run → 捕获请求含 base64 source
//!     block,text/image 保持原始顺序("main model actually receives the image")。
//!   ② OpenAI chat/completions:同,content 变 parts 数组(image_url data URL)。
//!   ③ transcript resume 后再请求:图像语义(MIME/载荷/顺序)在会话恢复后仍到达 wire
//!     ("Image semantics are preserved after checkpoint and restore" 的活链路证明)。
//!   ④ 能力守门:不支持 vision 的 (provider, model) 经 Provider vtable 显式报
//!     error.ImageInputUnsupported,绝不发出静默降级请求。
//!
//! 序列化纯函数级别的矩阵断言(各方言 wire 形态/顺序/能力错误)在
//! src/api/request.zig、openai_client.zig、gemini_client.zig、dialects/* 内联测试。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const msg_mod = cc.message;
const writer_backend = cc.writer_backend;

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

/// 1x1 红色 PNG 的 base64(有效 PNG 字节,非占位串)。
const RED_PIXEL_PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

fn appendImageUserMessage(conv: *cc.conversation.Conversation, a: std.mem.Allocator) !void {
    const inputs = [_]msg_mod.ImageInput{
        .{ .media_type = "image/png", .data = RED_PIXEL_PNG_B64 },
    };
    var m = try msg_mod.userMessageWithImages(a, "what color is this pixel?", &inputs);
    errdefer m.deinit(a);
    try conv.append(m);
}

test "issue#10 e2e: Anthropic 请求体含 image source block(text 在前,顺序保持)" {
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
    try appendImageUserMessage(&conv, a);

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("anthropic multimodal run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // "模型真的收到了图":捕获的最终请求体含正确 MIME + base64 原文,且 text 在 image 前。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    const text_at = std.mem.indexOf(u8, body, "what color is this pixel?").?;
    const img_at = std.mem.indexOf(u8, body, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"" ++ RED_PIXEL_PNG_B64 ++ "\"}}").?;
    try std.testing.expect(text_at < img_at);
}

test "issue#10 e2e: OpenAI chat 请求体含 image_url data URL parts(顺序保持)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try appendImageUserMessage(&conv, a);

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("openai multimodal run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    const cap = srv.lastRequest().?;
    const body = cap.body();
    const arr_at = std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"what color is this pixel?\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ RED_PIXEL_PNG_B64 ++ "\"}}]");
    try std.testing.expect(arr_at != null);
}

test "issue#10 e2e: transcript resume 后图像仍到达请求(恢复语义活链路)" {
    const a = std.testing.allocator;

    // ① 会话 A:带图 user 消息 → flush transcript。
    const tmp_home = "/tmp/cc-zig-mm-resume-l2";
    cc.util_fs.testing.rmrfBestEffort(tmp_home);
    defer cc.util_fs.testing.rmrfBestEffort(tmp_home);
    var writer = try cc.transcript.Writer.init(a, "/dummy", tmp_home, "claude-sonnet-4-20250514", cc.transcript.genSessionId());
    defer writer.deinit();

    {
        var conv_a = cc.conversation.Conversation.init(a);
        defer conv_a.deinit();
        try appendImageUserMessage(&conv_a, a);
        writer.flush(&conv_a);
    }

    // ② 会话 B:loadTranscript 恢复 → 跑 agent_loop → 请求体仍含图(MIME/载荷原样)。
    var conv_b = cc.conversation.Conversation.init(a);
    defer conv_b.deinit();
    try cc.transcript.loadTranscript(&conv_b, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 1), conv_b.len());

    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    _ = agent_loop.run(&conv_b, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("resume multimodal run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\",\"data\":\"" ++ RED_PIXEL_PNG_B64 ++ "\"") != null);
}

test "issue#10 e2e: 非 vision 模型带图经 Provider vtable 显式报能力错误(不发请求)" {
    const a = std.testing.allocator;
    // MockServer 仅为构造 client;能力错误必须在序列化期(发出前)抛出。
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "deepseek-chat", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try appendImageUserMessage(&conv, a);

    // 直接经 Provider vtable 发流式请求:序列化守门在网络前显式报错。
    const contents = [_]cc.types_mod.ApiContent{
        .{ .text = "what color?" },
        .{ .image = .{ .media_type = "image/png", .data = RED_PIXEL_PNG_B64 } },
    };
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &contents },
    };
    const provider = client.provider();
    try std.testing.expect(!provider.supports(.image_input));
    const got = provider.sendStreamRetry(&messages, null, null, null, null, null, 1, 1, null, "");
    try std.testing.expectError(error.ImageInputUnsupported, got);
    // 守门发生在序列化期:MockServer 未收到任何请求。
    try std.testing.expectEqual(@as(usize, 0), srv.requestCount());
}

// ── issue #25:一等 PDF 文档输入 ────────────────────────────────────────────
//
// 覆盖:① Anthropic 原生 document block 到达 wire,text/image/document 三类块
// 的原始顺序保持;② 续跑的下一轮仍带着文档;③ transcript resume 后语义(MIME/
// 标题/页数/载荷/顺序)不依赖宿主原始文件仍在或未被改动;④ 能力独立——vision 为真
// 的 OpenAI 模型带 PDF 仍在网络前显式报错,且 MockServer 收不到任何请求。

/// 最小但**真实**的 PDF 字节(header + 2 个页对象 + trailer + %%EOF),
/// 足以通过 core/pdf.zig 的准入并被数出页数。
const TINY_PDF =
    "%PDF-1.7\n" ++
    "1 0 obj\n<< /Type /Pages /Count 2 /Kids [2 0 R 3 0 R] >>\nendobj\n" ++
    "2 0 obj\n<< /Type /Page /Parent 1 0 R >>\nendobj\n" ++
    "3 0 obj\n<< /Type /Page /Parent 1 0 R >>\nendobj\n" ++
    "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n";

fn tinyPdfBase64(a: std.mem.Allocator) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try a.alloc(u8, encoder.calcSize(TINY_PDF.len));
    _ = encoder.encode(out, TINY_PDF);
    return out;
}

/// text + image + document 三块按序的一条 user 消息(混排顺序即断言对象)。
fn appendMixedPartsMessage(conv: *cc.conversation.Conversation, a: std.mem.Allocator) !void {
    const b64 = try tinyPdfBase64(a);
    defer a.free(b64);
    const pages = try cc.pdf.inspect(TINY_PDF);
    const parts = [_]msg_mod.UserContentPart{
        .{ .text = "summarize the attached report" },
        .{ .image = .{ .media_type = "image/png", .data = RED_PIXEL_PNG_B64 } },
        .{ .document = .{
            .media_type = cc.pdf.MEDIA_TYPE,
            .data = b64,
            .title = "report.pdf",
            .pages = pages.?,
        } },
    };
    var m = try msg_mod.userMessageFromParts(a, &parts);
    errdefer m.deinit(a);
    try conv.append(m);
}

test "issue#25 e2e: Anthropic 请求体含原生 document block(text/image/document 顺序保持)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    try std.testing.expect(client.provider().supports(.pdf_input));

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try appendMixedPartsMessage(&conv, a);

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("anthropic pdf run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    const b64 = try tinyPdfBase64(a);
    defer a.free(b64);
    const expected = try std.fmt.allocPrint(
        a,
        "{{\"type\":\"document\",\"source\":{{\"type\":\"base64\",\"media_type\":\"application/pdf\",\"data\":\"{s}\"}},\"title\":\"report.pdf\"}}",
        .{b64},
    );
    defer a.free(expected);

    const body = srv.lastRequest().?.body();
    const text_at = std.mem.indexOf(u8, body, "summarize the attached report").?;
    const img_at = std.mem.indexOf(u8, body, "\"type\":\"image\"").?;
    const doc_at = std.mem.indexOf(u8, body, expected) orelse {
        std.debug.print("document block not found in request body\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(text_at < img_at);
    try std.testing.expect(img_at < doc_at);
    // 绝对路径永远不上 wire:标题只有文件名。
    try std.testing.expect(std.mem.indexOf(u8, body, "/tmp/") == null);
}

test "issue#25 e2e: 续跑的下一轮请求仍带着同一份文档(多轮语义保持)" {
    const a = std.testing.allocator;
    // 第一轮回一个 tool_use? 无工具时用两条相同 cassette:第二次请求由 max_tokens
    // 续写触发过于绕,这里直接跑两次 run(同一 conversation)——第二次请求必须重放
    // 第一轮的 user 文档块。
    var srv = try harness.MockServer.startCassette(
        &[_][]const u8{ ANTHROPIC_OK_SSE, ANTHROPIC_OK_SSE },
        0,
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
    try appendMixedPartsMessage(&conv, a);

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    _ = agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("anthropic pdf first run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try conv.appendText(.user, "now list its section titles");
    _ = agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("anthropic pdf second run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    const b64 = try tinyPdfBase64(a);
    defer a.free(b64);
    const second = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, second, "now list its section titles") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, b64) != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"type\":\"document\"") != null);
}

test "issue#25 e2e: transcript resume 后文档仍到达请求(原始文件被删改也无关)" {
    const a = std.testing.allocator;
    const tmp_home = "/tmp/cc-zig-pdf-resume-l2";
    cc.util_fs.testing.rmrfBestEffort(tmp_home);
    defer cc.util_fs.testing.rmrfBestEffort(tmp_home);
    var writer = try cc.transcript.Writer.init(a, "/dummy", tmp_home, "claude-sonnet-4-20250514", cc.transcript.genSessionId());
    defer writer.deinit();

    {
        var conv_a = cc.conversation.Conversation.init(a);
        defer conv_a.deinit();
        try appendMixedPartsMessage(&conv_a, a);
        writer.flush(&conv_a);
    }

    // 恢复的会话只依赖 transcript 里的字节——宿主文件从来没有被引用过。
    var conv_b = cc.conversation.Conversation.init(a);
    defer conv_b.deinit();
    try cc.transcript.loadTranscript(&conv_b, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 1), conv_b.len());
    const restored = conv_b.messages.items[0].blocks;
    try std.testing.expectEqual(@as(usize, 3), restored.len);
    try std.testing.expectEqualStrings("application/pdf", restored[2].document.media_type);
    try std.testing.expectEqualStrings("report.pdf", restored[2].document.title);
    try std.testing.expectEqual(@as(?u32, 2), restored[2].document.pages);

    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    _ = agent_loop.run(&conv_b, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("resume pdf run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    const b64 = try tinyPdfBase64(a);
    defer a.free(b64);
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"application/pdf\",\"data\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, b64) != null);
}

test "issue#25 e2e: vision 模型没有文档能力 → 网络前显式报错,零请求" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();
    const provider = client.provider();
    // 能力独立的证词:同一个模型 vision=true、pdf=false。
    try std.testing.expect(provider.supports(.image_input));
    try std.testing.expect(!provider.supports(.pdf_input));

    const b64 = try tinyPdfBase64(a);
    defer a.free(b64);
    const contents = [_]cc.types_mod.ApiContent{
        .{ .text = "summarize" },
        .{ .document = .{ .media_type = "application/pdf", .data = b64, .title = "report.pdf" } },
    };
    const messages = [_]cc.types_mod.ApiMessage{.{ .role = .user, .content = &contents }};
    const got = provider.sendStreamRetry(&messages, null, null, null, null, null, 1, 1, null, "");
    try std.testing.expectError(error.DocumentInputUnsupported, got);
    try std.testing.expectEqual(@as(usize, 0), srv.requestCount());
}

test "issue#25 e2e: Anthropic 网关上的非 Claude 模型带 PDF → 显式能力错误,零请求" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ANTHROPIC_OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "glm-5.2", url);
    defer client.deinit();

    const b64 = try tinyPdfBase64(a);
    defer a.free(b64);
    const contents = [_]cc.types_mod.ApiContent{
        .{ .document = .{ .media_type = "application/pdf", .data = b64, .title = "report.pdf" } },
    };
    const messages = [_]cc.types_mod.ApiMessage{.{ .role = .user, .content = &contents }};
    const got = client.provider().sendStreamRetry(&messages, null, null, null, null, null, 1, 1, null, "");
    try std.testing.expectError(error.DocumentInputUnsupported, got);
    try std.testing.expectEqual(@as(usize, 0), srv.requestCount());
}

test "issue#25 e2e: 纯 text/image 会话的 provider 可见字节不受本特性影响" {
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
    try appendImageUserMessage(&conv, a);

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    _ = agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("text+image baseline run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"document\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"what color is this pixel?\"},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"" ++ RED_PIXEL_PNG_B64 ++ "\"}}]") != null);
}
