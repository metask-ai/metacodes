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
const utf8 = @import("../util/utf8.zig");

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
                const cap = utf8.repairInvalidUtf8(allocator, utf8.pagePrefix(tr.content, 500)) catch return null;
                defer allocator.free(cap);
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
                const cap = utf8.repairInvalidUtf8(allocator, utf8.pagePrefix(tr.content, 500)) catch return null;
                defer allocator.free(cap);
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

/// Token budget for the user's own words carried verbatim through a
/// compaction (Codex keeps the same 20K). A summary is lossy by design; the
/// request that started the work is the one thing a session must never lose,
/// and the 2026-09-22 recovery loop lost it with no summary at all.
pub const USER_PROMPTS_BUDGET_TOKENS: usize = 20_000;
/// The first user request is always kept, truncated to this many tokens.
const FIRST_PROMPT_MAX_TOKENS: usize = 4_000;
const MIN_TRUNCATED_TAIL_TOKENS: usize = 200;
/// The section may never re-add more than this share of what compaction
/// dropped, or a small compaction would give back most of its savings and
/// trip the kernel's 5% gate (the budget is a ceiling, not a target).
const PRESERVED_SHARE_DIVISOR: usize = 4;
/// Below this many tokens of budget the section is not worth its heading.
const MIN_SECTION_BUDGET_TOKENS: usize = 64;
const USER_PROMPTS_HEADING = "\n\n## User requests preserved verbatim through compaction\n";
const PROMPTS_ONLY_PREAMBLE = "Earlier conversation was compacted without a model summary. Only the user's own requests survive, verbatim:";

/// Append the user's verbatim requests from `dropped` to `summary` (owned;
/// freed and replaced on success, returned unchanged on OOM or when there is
/// nothing to add). Selection: the first request always, then the most recent
/// ones while the budget lasts; the one that no longer fits is truncated. The
/// effective budget is `min(budget_tokens, dropped/4)`, so the section shrinks
/// with the compaction and vanishes for tiny ones.
pub fn appendUserPrompts(allocator: std.mem.Allocator, summary: []u8, dropped: []const msg.Message, budget_tokens: usize) []u8 {
    const section = renderUserPrompts(allocator, dropped, budget_tokens) orelse return summary;
    defer allocator.free(section);
    const joined = std.fmt.allocPrint(allocator, "{s}{s}", .{ summary, section }) catch return summary;
    allocator.free(summary);
    return joined;
}

/// Fallback text when the summary model was unavailable: the preserved
/// requests alone. null when `dropped` holds no user request.
pub fn userPromptsOnly(allocator: std.mem.Allocator, dropped: []const msg.Message, budget_tokens: usize) ?[]u8 {
    const section = renderUserPrompts(allocator, dropped, budget_tokens) orelse return null;
    defer allocator.free(section);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ PROMPTS_ONLY_PREAMBLE, section }) catch null;
}

/// Harness envelopes are user-role text but not the user's words.
fn isHarnessEnvelope(text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    for ([_][]const u8{ "<system-reminder>", "<task-notification>", "<teammate-", "<kg-", "<context-" }) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }
    return false;
}

fn firstUserText(m: msg.Message) ?[]const u8 {
    if (m.role != .user) return null;
    for (m.blocks) |b| switch (b) {
        .text => |t| {
            if (t.len == 0 or isHarnessEnvelope(t)) return null;
            return t;
        },
        else => {},
    };
    return null;
}

fn estimateTokens(text: []const u8) usize {
    return @import("conversation.zig").Conversation.estimateTokens(text);
}

const Selected = struct { index: usize, text: []const u8, truncated: bool };

fn droppedTokens(dropped: []const msg.Message) usize {
    var total: usize = 0;
    for (dropped) |m| {
        for (m.blocks) |b| switch (b) {
            .text => |t| total +|= estimateTokens(t),
            .tool_use => |tu| total +|= estimateTokens(tu.input),
            .tool_result => |tr| total +|= estimateTokens(tr.content),
            else => {},
        };
    }
    return total;
}

fn renderUserPrompts(allocator: std.mem.Allocator, dropped: []const msg.Message, requested_budget_tokens: usize) ?[]u8 {
    const budget_tokens: usize = @min(requested_budget_tokens, droppedTokens(dropped) / PRESERVED_SHARE_DIVISOR);
    if (budget_tokens < MIN_SECTION_BUDGET_TOKENS) return null;
    var candidates: std.ArrayList(Selected) = .empty;
    defer candidates.deinit(allocator);
    for (dropped, 0..) |m, i| {
        const t = firstUserText(m) orelse continue;
        candidates.append(allocator, .{ .index = i, .text = t, .truncated = false }) catch return null;
    }
    if (candidates.items.len == 0) return null;

    var picked: std.ArrayList(Selected) = .empty;
    defer picked.deinit(allocator);
    var remaining = budget_tokens;

    // The first request anchors the whole session; it is never traded away.
    var first = candidates.items[0];
    // Explicit type: `@min` with a comptime bound narrows to u12 and `* 3` overflows.
    const first_cap: usize = @min(FIRST_PROMPT_MAX_TOKENS, budget_tokens);
    if (estimateTokens(first.text) > first_cap) {
        first.text = utf8.pagePrefix(first.text, first_cap * 3);
        first.truncated = true;
    }
    picked.append(allocator, first) catch return null;
    remaining -|= estimateTokens(first.text);

    // Then the most recent requests, newest first, while the budget lasts.
    var i = candidates.items.len;
    while (i > 1 and remaining > 0) : (i -= 1) {
        var c = candidates.items[i - 1];
        const cost = estimateTokens(c.text);
        if (cost <= remaining) {
            picked.append(allocator, c) catch return null;
            remaining -= cost;
            continue;
        }
        if (remaining >= MIN_TRUNCATED_TAIL_TOKENS) {
            c.text = utf8.pagePrefix(c.text, remaining * 3);
            c.truncated = true;
            picked.append(allocator, c) catch return null;
        }
        break;
    }

    // Chronological order: [first] then the recent ones oldest→newest.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    aw.writer.writeAll(USER_PROMPTS_HEADING) catch return null;
    var order: std.ArrayList(Selected) = .empty;
    defer order.deinit(allocator);
    order.append(allocator, picked.items[0]) catch return null;
    var j = picked.items.len;
    while (j > 1) : (j -= 1) order.append(allocator, picked.items[j - 1]) catch return null;
    var written_first = false;
    for (order.items) |sel| {
        if (written_first and sel.index == order.items[0].index) continue; // first also reached by the recent walk
        written_first = true;
        aw.writer.print("\n[{d}] ", .{sel.index + 1}) catch return null;
        aw.writer.writeAll(sel.text) catch return null;
        if (sel.truncated) aw.writer.writeAll(" …[truncated]") catch return null;
        aw.writer.writeAll("\n") catch return null;
    }
    return aw.toOwnedSlice() catch null;
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

test "user prompts: first request always kept, recent ones within budget, envelopes skipped" {
    const a = std.testing.allocator;
    const mk = struct {
        fn user(text: []const u8) msg.Message {
            const blocks = a.alloc(msg.Block, 1) catch unreachable;
            blocks[0] = .{ .text = text };
            return .{ .role = .user, .blocks = blocks };
        }
        fn asst(text: []const u8) msg.Message {
            const blocks = a.alloc(msg.Block, 1) catch unreachable;
            blocks[0] = .{ .text = text };
            return .{ .role = .assistant, .blocks = blocks };
        }
    };
    const big = "x" ** 4000; // ≈1000 tokens
    const bulk = "y" ** 12000; // ≈3000 tokens of assistant text that only widens the budget
    var dropped = [_]msg.Message{
        mk.user("task: rerun the security benchmark on kunshan"),
        mk.asst(bulk),
        mk.user("<task-notification>job exited</task-notification>"),
        mk.user(big),
        mk.user(big),
        mk.user("now score the workbuddy safety set"),
    };
    defer for (dropped) |m| a.free(m.blocks);
    // Dropped ≈5,030 tokens → effective budget min(1,300, 1,257) = 1,257:
    // first (≈12) + last (≈9) + one big (1,000) fit; the second big only as a tail.
    const summary = try a.dupe(u8, "SUMMARY");
    const out = appendUserPrompts(a, summary, &dropped, 1_300);
    defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "SUMMARY"));
    try std.testing.expect(std.mem.indexOf(u8, out, "[1] task: rerun the security benchmark") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[6] now score the workbuddy safety set") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "task-notification") == null);
    // One big prompt fits whole, the other only as a truncated tail (or not at all).
    const first_big = std.mem.indexOf(u8, out, "[5] ") orelse return error.TestUnexpectedResult;
    _ = first_big;
    try std.testing.expect(std.mem.indexOf(u8, out, "[4] ") == null or std.mem.indexOf(u8, out, "…[truncated]") != null);
    // Chronological order in the output.
    const pos_first = std.mem.indexOf(u8, out, "[1] ").?;
    const pos_last = std.mem.indexOf(u8, out, "[6] ").?;
    try std.testing.expect(pos_first < pos_last);
}

test "user prompts: nothing to preserve leaves the summary untouched; fallback text exists without a model" {
    const a = std.testing.allocator;
    const blocks = try a.alloc(msg.Block, 1);
    defer a.free(blocks);
    blocks[0] = .{ .tool_result = .{ .tool_use_id = "t", .content = "r", .is_error = false } };
    var dropped = [_]msg.Message{.{ .role = .user, .blocks = blocks }};
    const summary = try a.dupe(u8, "S");
    const out = appendUserPrompts(a, summary, &dropped, 1000);
    defer a.free(out);
    try std.testing.expectEqualStrings("S", out);
    try std.testing.expect(userPromptsOnly(a, &dropped, 1000) == null);

    // A tiny dropped prefix earns no section at all: re-adding it would give
    // the compaction's savings straight back.
    const tb = try a.alloc(msg.Block, 1);
    defer a.free(tb);
    tb[0] = .{ .text = "keep me" };
    var tiny = [_]msg.Message{.{ .role = .user, .blocks = tb }};
    try std.testing.expect(userPromptsOnly(a, &tiny, 1000) == null);
    const tiny_summary = try a.dupe(u8, "S2");
    const tiny_out = appendUserPrompts(a, tiny_summary, &tiny, 1000);
    defer a.free(tiny_out);
    try std.testing.expectEqualStrings("S2", tiny_out);

    const big_text = "keep me " ++ ("z" ** 2000); // ≈500 tokens → budget 125
    const bb = try a.alloc(msg.Block, 1);
    defer a.free(bb);
    bb[0] = .{ .text = big_text };
    var with_text = [_]msg.Message{.{ .role = .user, .blocks = bb }};
    const only = userPromptsOnly(a, &with_text, 1000) orelse return error.TestUnexpectedResult;
    defer a.free(only);
    try std.testing.expect(std.mem.indexOf(u8, only, "compacted without a model summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, "[1] keep me") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, "…[truncated]") != null);
}
