//! Compact 摘要生成。默认模板对齐 metacode-rs core/templates/compact/*，
//! 并允许用 env 指定文件在不改代码的情况下 A/B 调 prompt。
//!
//! cc-zig 原 auto-compact 是"留最近 N 条、丢老的"——丢得多、丢失早期上下文。
//! cc 的做法:调模型把要丢的历史总结成 9 段结构化 summary,替换老消息,保真。
//! 本模块:把"要丢的消息"拼成一段文本,带 9 段指令调模型(无工具),返回 summary。
//! 失败/无 client → 返 null,caller 退回纯 compactKeepRecent(降级不阻断)。

const std = @import("std");
const pfs = @import("platform").fs;
const types = @import("../types.zig");
const msg = @import("message.zig");
const log = @import("../util/log.zig");
const json_mod = @import("../json.zig");
const provider_mod = @import("../api/provider.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const UsageDelta = @import("../api/stream.zig").UsageDelta;

const DEFAULT_COMPACT_SYSTEM = @embedFile("templates/compact/prompt.md");
const DEFAULT_SUMMARY_PREFIX = @embedFile("templates/compact/summary_prefix.md");
const COMPACT_PROMPT_FILE_ENV = "METACODES_COMPACT_PROMPT_FILE";
const COMPACT_SUMMARY_PREFIX_FILE_ENV = "METACODES_COMPACT_SUMMARY_PREFIX_FILE";

pub fn defaultSystemPrompt() []const u8 {
    return DEFAULT_COMPACT_SYSTEM;
}

pub fn defaultSummaryPrefix() []const u8 {
    return DEFAULT_SUMMARY_PREFIX;
}

/// 生成要丢消息的 9 段摘要。client 为 null 或调用失败 → null(caller 降级)。
/// drop_msgs 是即将被丢弃的消息切片(borrowed)。返回 owned summary 文本。
pub fn summarize(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    drop_msgs: []const msg.Message,
) ?[]u8 {
    return summarizeWithModel(allocator, provider, drop_msgs, null);
}

pub fn summarizeWithModel(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    drop_msgs: []const msg.Message,
    model_override: ?[]const u8,
) ?[]u8 {
    if (drop_msgs.len == 0) return null;

    // 把要丢的消息拼成一段可读文本(role: text/tool 摘要),作为待总结输入。
    var transcript_buf = std.ArrayList(u8).empty;
    defer transcript_buf.deinit(allocator);
    for (drop_msgs) |m| {
        const role = if (m.role == .user) "User" else "Assistant";
        transcript_buf.appendSlice(allocator, role) catch return null;
        transcript_buf.appendSlice(allocator, ": ") catch return null;
        for (m.blocks) |b| switch (b) {
            .text => |t| transcript_buf.appendSlice(allocator, t) catch return null,
            .tool_use => |tu| {
                transcript_buf.appendSlice(allocator, "[tool ") catch return null;
                transcript_buf.appendSlice(allocator, tu.name) catch return null;
                transcript_buf.appendSlice(allocator, "]") catch return null;
            },
            .tool_result => |tr| {
                const cap = tr.content[0..@min(tr.content.len, 500)];
                transcript_buf.appendSlice(allocator, "[result: ") catch return null;
                transcript_buf.appendSlice(allocator, cap) catch return null;
                transcript_buf.appendSlice(allocator, "]") catch return null;
            },
            .thinking => {},
            // provider 私有的加密推理续传状态:不可读,也不属于会话内容。
            .reasoning_item => {},
            .image => |img| {
                // 总结输入的占位标记(被压缩前缀整体替换为摘要,非 model-visible 会话内容)。
                transcript_buf.appendSlice(allocator, "[image ") catch return null;
                transcript_buf.appendSlice(allocator, img.media_type) catch return null;
                transcript_buf.appendSlice(allocator, "]") catch return null;
            },
        };
        transcript_buf.append(allocator, '\n') catch return null;
    }

    const user_text = std.fmt.allocPrint(allocator, "Summarize this conversation for compaction:\n\n{s}", .{transcript_buf.items}) catch return null;
    defer allocator.free(user_text);

    const system_prompt = loadTemplateOrDefault(allocator, COMPACT_PROMPT_FILE_ENV, DEFAULT_COMPACT_SYSTEM) catch return null;
    defer allocator.free(system_prompt);

    const api_msgs = [_]types.ApiMessage{.{
        .role = .user,
        .content = &[_]types.ApiContent{.{ .text = user_text }},
    }};
    const resp = provider.sendWithModel(
        &api_msgs,
        system_prompt,
        null,
        model_override,
    ) catch |err| {
        log.warn("compact", "summarize API call failed: {s} (falling back to keep-recent)", .{@errorName(err)});
        return null;
    };
    defer if (resp.content.len > 0) allocator.free(resp.content);
    if (resp.content.len == 0) return null;
    return applySummaryPrefix(allocator, resp.content) catch null;
}

/// Abortable summary transport used by CompactKernel. It uses the neutral
/// streaming provider path because that path exposes both AbortSignal and
/// provider usage; callers aggregate the returned delta exactly once.
pub fn summarizeAbortable(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    drop_msgs: []const msg.Message,
    model_override: ?[]const u8,
    abort: *const AbortSignal,
    usage_out: *UsageDelta,
) error{Aborted}!?[]u8 {
    usage_out.* = .{};
    if (drop_msgs.len == 0) return null;
    if (abort.isAborted()) return error.Aborted;

    var transcript_buf: std.ArrayList(u8) = .empty;
    defer transcript_buf.deinit(allocator);
    for (drop_msgs) |m| {
        const role = if (m.role == .user) "User" else "Assistant";
        transcript_buf.appendSlice(allocator, role) catch return null;
        transcript_buf.appendSlice(allocator, ": ") catch return null;
        for (m.blocks) |b| switch (b) {
            .text => |t| transcript_buf.appendSlice(allocator, t) catch return null,
            .tool_use => |tu| {
                transcript_buf.appendSlice(allocator, "[tool ") catch return null;
                transcript_buf.appendSlice(allocator, tu.name) catch return null;
                transcript_buf.appendSlice(allocator, "]") catch return null;
            },
            .tool_result => |tr| {
                const cap = tr.content[0..@min(tr.content.len, 500)];
                transcript_buf.appendSlice(allocator, "[result: ") catch return null;
                transcript_buf.appendSlice(allocator, cap) catch return null;
                transcript_buf.appendSlice(allocator, "]") catch return null;
            },
            .thinking => {},
            // provider 私有的加密推理续传状态:不可读,也不属于会话内容。
            .reasoning_item => {},
            .image => |img| {
                // 总结输入的占位标记(被压缩前缀整体替换为摘要,非 model-visible 会话内容)。
                transcript_buf.appendSlice(allocator, "[image ") catch return null;
                transcript_buf.appendSlice(allocator, img.media_type) catch return null;
                transcript_buf.appendSlice(allocator, "]") catch return null;
            },
        };
        transcript_buf.append(allocator, '\n') catch return null;
    }

    const user_text = std.fmt.allocPrint(
        allocator,
        "Summarize this conversation for compaction:\n\n{s}",
        .{transcript_buf.items},
    ) catch return null;
    defer allocator.free(user_text);
    const system_prompt = loadTemplateOrDefault(
        allocator,
        COMPACT_PROMPT_FILE_ENV,
        DEFAULT_COMPACT_SYSTEM,
    ) catch return null;
    defer allocator.free(system_prompt);
    const api_msgs = [_]types.ApiMessage{.{
        .role = .user,
        .content = &[_]types.ApiContent{.{ .text = user_text }},
    }};
    var stream = provider.sendStream(
        &api_msgs,
        system_prompt,
        null,
        abort,
        model_override,
        null,
        "",
    ) catch |err| {
        if (abort.isAborted() or err == error.Aborted) return error.Aborted;
        log.warn("compact", "summary stream failed: {s} (falling back to keep-recent)", .{@errorName(err)});
        return null;
    };
    defer stream.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    while (true) {
        if (abort.isAborted()) return error.Aborted;
        const event = stream.next() catch |err| {
            if (abort.isAborted() or err == error.Aborted) return error.Aborted;
            log.warn("compact", "summary stream read failed: {s} (falling back to keep-recent)", .{@errorName(err)});
            return null;
        } orelse break;
        switch (event) {
            .text => |bytes| {
                defer allocator.free(bytes);
                text.appendSlice(allocator, bytes) catch return null;
            },
            .thinking => |bytes| allocator.free(bytes), // 思考过程不进 summary
            // 摘要子请求是一次性的,没有下一轮可回传;续传项就地释放。
            .reasoning_item => |bytes| allocator.free(bytes),
            .usage => |delta| accumulateUsage(usage_out, delta),
            .tool_use_start => |tool| {
                allocator.free(tool.id);
                allocator.free(tool.name);
                allocator.free(tool.input_json);
            },
            .web_search_result => |result| {
                allocator.free(result.ui_text);
                allocator.free(result.content_json);
            },
            .web_search_query => |query| allocator.free(query),
            .done => {},
        }
    }
    if (abort.isAborted()) return error.Aborted;
    if (text.items.len == 0) return null;
    return applySummaryPrefix(allocator, text.items) catch return null;
}

fn accumulateUsage(total: *UsageDelta, delta: UsageDelta) void {
    total.input_tokens +|= delta.input_tokens;
    total.output_tokens +|= delta.output_tokens;
    total.cache_read_input_tokens +|= delta.cache_read_input_tokens;
    total.cache_creation_input_tokens +|= delta.cache_creation_input_tokens;
}

pub fn applySummaryPrefix(allocator: std.mem.Allocator, summary_suffix: []const u8) ![]u8 {
    const prefix = try loadTemplateOrDefault(allocator, COMPACT_SUMMARY_PREFIX_FILE_ENV, DEFAULT_SUMMARY_PREFIX);
    defer allocator.free(prefix);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ trimRightAscii(prefix, " \t\r\n"), summary_suffix });
}

/// 任务锚:把本 session 进行中的任务确定性写进 compact 摘要(不依赖模型自觉保留)。
/// compact 最容易丢的就是"我正在做哪个任务、做完要闭合"的闭环纪律——摘要有损,
/// 锚是硬保底。无 in_progress 任务 → null。返回 owned。
pub fn buildTaskAnchor(allocator: std.mem.Allocator, tasks: *@import("task_store.zig").TaskStore) ?[]u8 {
    var out = std.ArrayList(u8).empty;
    var count: usize = 0;
    for (tasks.tasks.items) |t| {
        if (t.status != .in_progress) continue;
        if (count >= 3) break; // 锚要小:最多 3 条
        count += 1;
        out.appendSlice(allocator, "- ") catch break;
        out.appendSlice(allocator, t.id) catch break;
        out.appendSlice(allocator, " ") catch break;
        out.appendSlice(allocator, t.subject) catch break;
        out.append(allocator, '\n') catch break;
    }
    defer out.deinit(allocator);
    if (count == 0) return null;
    return std.fmt.allocPrint(
        allocator,
        "\n\n## Active tasks(compact 任务锚)\n{s}继续推进以上进行中的任务;完成后用 TaskUpdate(status=completed)闭合,不要遗忘。",
        .{out.items},
    ) catch null;
}

/// 把任务锚拼到摘要尾部(summary owned 被消费,返回新 owned)。anchor null → 原样返回。
pub fn appendTaskAnchor(allocator: std.mem.Allocator, summary: []u8, anchor: ?[]const u8) []u8 {
    const a = anchor orelse return summary;
    const joined = std.fmt.allocPrint(allocator, "{s}{s}", .{ summary, a }) catch return summary;
    allocator.free(summary);
    return joined;
}

fn loadTemplateOrDefault(allocator: std.mem.Allocator, env_name: [:0]const u8, default_text: []const u8) ![]u8 {
    if (std.c.getenv(env_name.ptr)) |path_c| {
        const path = std.mem.span(path_c);
        if (path.len > 0) {
            return readFileAllocLimited(allocator, path, 128 * 1024) catch |err| {
                log.warn("compact", "failed to read {s}={s}: {s}; using embedded template", .{ env_name, path, @errorName(err) });
                return try allocator.dupe(u8, default_text);
            };
        }
    }
    return try allocator.dupe(u8, default_text);
}

fn readFileAllocLimited(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer pfs.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.readZ(fd, &buf) catch return error.ReadFailed;
        if (n == 0) break;
        if (out.items.len + n > limit) return error.FileTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn trimRightAscii(s: []const u8, chars: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and std.mem.indexOfScalar(u8, chars, s[end - 1]) != null) : (end -= 1) {}
    return s[0..end];
}

test "compact summary default templates match metacode-rs shape" {
    try std.testing.expect(std.mem.indexOf(u8, defaultSystemPrompt(), "CONTEXT CHECKPOINT COMPACTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, defaultSummaryPrefix(), "Another language model started") != null);
}

test "compact summary applies summary_prefix" {
    const a = std.testing.allocator;
    const out = try applySummaryPrefix(a, "handoff body");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Another language model started") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "handoff body"));
}

fn testSummarizeFreesProviderResponseContent() !void {
    const a = std.testing.allocator;
    var input = try msg.textMessage(.user, "hello", a);
    defer input.deinit(a);
    var ctx = struct {
        allocator: std.mem.Allocator,
    }{ .allocator = a };

    const Fake = struct {
        fn model(_: *anyopaque) []const u8 {
            return "fake";
        }
        fn send(ctx_ptr: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?[]const u8) anyerror!provider_mod.ApiResponse {
            const c: *@TypeOf(ctx) = @ptrCast(@alignCast(ctx_ptr));
            return .{ .content = try c.allocator.dupe(u8, "summary body") };
        }
        fn sendStream(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const @import("../util/abort.zig").AbortSignal, _: ?[]const u8, _: ?json_mod.ToolChoice, _: []const u8) anyerror!provider_mod.StreamHandle {
            return error.Unused;
        }
        fn sendStreamRetry(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const @import("../util/abort.zig").AbortSignal, _: ?[]const u8, _: ?json_mod.ToolChoice, _: u32, _: u64, _: ?provider_mod.RetryReporter, _: []const u8) anyerror!provider_mod.StreamHandle {
            return error.Unused;
        }
        fn maxTokens(_: *anyopaque) u32 {
            return 32_000;
        }
        fn maxInputTokens(_: *anyopaque) u32 {
            return 200_000;
        }
        fn reasoningEffort(_: *anyopaque) ?types.ReasoningEffort {
            return null;
        }
        fn supports(_: *anyopaque, _: provider_mod.Capability) bool {
            return false;
        }
    };

    const provider = provider_mod.Provider{
        .ctx = &ctx,
        .modelFn = Fake.model,
        .sendStreamFn = Fake.sendStream,
        .sendStreamRetryFn = Fake.sendStreamRetry,
        .sendFn = Fake.send,
        .maxTokensFn = Fake.maxTokens,
        .maxInputTokensFn = Fake.maxInputTokens,
        .reasoningEffortFn = Fake.reasoningEffort,
        .supportsFn = Fake.supports,
    };
    const summary = summarize(a, provider, &.{input}) orelse return error.TestUnexpectedResult;
    defer a.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "summary body") != null);
}

test "compact summary summarize frees provider response content" {
    try testSummarizeFreesProviderResponseContent();
}
