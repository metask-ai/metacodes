//! 9 段结构化 compact 摘要(补真缺口,对齐 cc services/compact/prompt.ts)。
//!
//! cc-zig 原 auto-compact 是"留最近 N 条、丢老的"——丢得多、丢失早期上下文。
//! cc 的做法:调模型把要丢的历史总结成 9 段结构化 summary,替换老消息,保真。
//! 本模块:把"要丢的消息"拼成一段文本,带 9 段指令调模型(无工具),返回 summary。
//! 失败/无 client → 返 null,caller 退回纯 compactKeepRecent(降级不阻断)。

const std = @import("std");
const client_mod = @import("../client.zig");
const types = @import("../types.zig");
const msg = @import("message.zig");
const Conversation = @import("conversation.zig").Conversation;
const log = @import("../util/log.zig");

/// 9 段结构化摘要 system prompt(对齐 cc compact/prompt.ts 的分段)。
const COMPACT_SYSTEM =
    \\You are summarizing a software-engineering conversation so it can continue after older
    \\messages are dropped. Capture ALL technical detail needed to resume seamlessly. Output
    \\EXACTLY these 9 sections (markdown headers), each concise but complete. Do NOT use tools.
    \\
    \\1. Primary Request and Intent — what the user explicitly asked for.
    \\2. Key Technical Concepts — frameworks, languages, patterns in play.
    \\3. Files and Code Sections — specific files touched + why they matter (include key paths).
    \\4. Errors and Fixes — errors hit and how they were resolved.
    \\5. Problem Solving — problems solved and ongoing troubleshooting.
    \\6. All User Messages — list the user's non-tool-result messages (intent trail).
    \\7. Pending Tasks — what remains to do.
    \\8. Current Work — precisely what was being worked on just before this summary.
    \\9. Optional Next Step — the immediate next step, with a direct quote if relevant.
;

/// 生成要丢消息的 9 段摘要。client 为 null 或调用失败 → null(caller 降级)。
/// drop_msgs 是即将被丢弃的消息切片(borrowed)。返回 owned summary 文本。
pub fn summarize(
    allocator: std.mem.Allocator,
    provider: @import("../api/provider.zig").Provider,
    drop_msgs: []const msg.Message,
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
        };
        transcript_buf.append(allocator, '\n') catch return null;
    }

    const user_text = std.fmt.allocPrint(allocator, "Summarize this conversation into the 9 sections:\n\n{s}", .{transcript_buf.items}) catch return null;
    defer allocator.free(user_text);

    const api_msgs = [_]types.ApiMessage{.{
        .role = .user,
        .content = &[_]types.ApiContent{.{ .text = user_text }},
    }};
    const resp = provider.send(&api_msgs, COMPACT_SYSTEM, null) catch |err| {
        log.warn("compact", "summarize API call failed: {s} (falling back to keep-recent)", .{@errorName(err)});
        return null;
    };
    if (resp.content.len == 0) return null;
    return allocator.dupe(u8, resp.content) catch null;
}
