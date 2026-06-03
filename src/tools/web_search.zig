//! WebSearch:普通函数工具(对齐 cc WebSearchTool / mecode WebSearchHandler)。
//!
//! 根因背景:把 Anthropic server-tool 异形对象 `{"type":"web_search_...","name":"web_search"}`
//! 直接放进主请求 tools 数组,会毒化 OpenAI-compat 后端(metask/MiniMax)的 function-calling
//! 解析,模型退回 Bash(二分实证)。解法(对齐 cc/mecode):WebSearch 是普通函数工具,
//! 真正搜索在**隔离子请求**里用 server tool 完成——异形只出现在那个单工具子请求,不污染
//! 主对话工具集。子 agent 被异形毒化无所谓(它只干搜索这一件事)。
//!
//! 两阶段交互(对齐 cc makeOutputFromSearchResponse):子请求里模型发 server_tool_use →
//! 后端回 web_search_tool_result(结构化结果块)→ 模型据此续写文本摘要。本 execute 收集:
//!   - .web_search_result 事件的 content_json → title/url 链接(结构化结果)
//!   - .text 事件 → 模型续写摘要
//! 按 cc mapToolResultToToolResultBlockParam 格式化:query 头 + 摘要 + Links + REMINDER。
//! 注:metask 后端常 content:[](不透传结果数组),此时结果全靠模型续写文本。
//!
//! tool_choice 强制 web_search(对齐 cc 弱模型路径):保证模型必发搜索而非闲聊。

const std = @import("std");
const common = @import("common.zig");
const types = @import("../types.zig");
const json_mod = @import("../json.zig");
const api_stream = @import("../api/stream.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const query = common.extractJsonArg(args, "query") orelse return error.MissingQuery;
    if (query.len == 0) return error.EmptyQuery;
    const client = ctx.api_client orelse return error.WebSearchUnavailable;

    // 隔离子请求:只带 web_search server tool(异形形态只在此处出现,不进主工具集)。
    const tools_one = [_]json_mod.ToolDefinition{.{
        .name = "web_search",
        .description = "",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .server_type = "web_search_20250305",
    }};
    // prompt + system 对齐 cc WebSearchTool.call:
    //   user = "Perform a web search for the query: <query>"
    //   system = "You are an assistant for performing a web search tool use"
    const search_prompt = try std.fmt.allocPrint(allocator, "Perform a web search for the query: {s}", .{query});
    defer allocator.free(search_prompt);
    const sys_prompt = "You are an assistant for performing a web search tool use";
    const msgs = [_]types.ApiMessage{.{ .role = .user, .content = &.{.{ .text = search_prompt }} }};

    // tool_choice 强制 web_search(对齐 cc 弱模型路径):保证模型必发搜索。
    const tc = json_mod.ToolChoice{ .type = "tool", .name = "web_search" };

    var stream = client.sendMessageStreamFull(&msgs, sys_prompt, &tools_one, ctx.abort, null, tc) catch |err| {
        setDetail(ctx, allocator, "web search request failed: {s}", .{@errorName(err)});
        return error.WebSearchFailed;
    };
    defer stream.deinit();
    stream.user_query = query; // 让 UI 装饰显示真实 query

    // 收集:模型续写摘要(model_text)+ 结构化结果链接(links)。
    var model_text: std.ArrayList(u8) = .empty;
    defer model_text.deinit(allocator);
    var links: std.ArrayList(u8) = .empty;
    defer links.deinit(allocator);

    while (true) {
        const ev = stream.next() catch |err| {
            setDetail(ctx, allocator, "web search stream error: {s}", .{@errorName(err)});
            return error.WebSearchFailed;
        };
        const e = ev orelse break;
        switch (e) {
            .text => |t| {
                defer allocator.free(t);
                try model_text.appendSlice(allocator, t);
            },
            .web_search_query => |q| {
                defer allocator.free(q);
                // 对齐 cc query_update:刷新 TUI 第二行 `Searching: <query>`。
                ctx.reportProgress(.query_update, q, 0);
            },
            .web_search_result => |w| {
                defer allocator.free(w.ui_text); // 子请求不显示 UI 装饰
                defer allocator.free(w.content_json);
                // content_json 是原始结果数组(metask 常 "[]")。渲染成 `- title — url` 行。
                const rendered = try api_stream.renderWebSearchResults(allocator, w.content_json);
                defer allocator.free(rendered);
                try links.appendSlice(allocator, rendered);
                // 对齐 cc search_results_received:刷新第二行 `Found N results`。
                // count = content_json 里 "url" 字段数(metask content:[] → 0)。
                const count = countOccurrences(w.content_json, "\"url\"");
                ctx.reportProgress(.results_received, query, @intCast(count));
            },
            // 子请求只带 server tool,不会有 client tool_use;usage/done 无需处理。
            else => {},
        }
    }

    const text = std.mem.trim(u8, model_text.items, " \t\r\n");
    const link_text = std.mem.trim(u8, links.items, " \t\r\n");
    // 空结果(模型既没续写摘要、后端也没透传结果)→ 对齐 cc/mecode no_results。
    if (text.len == 0 and link_text.len == 0) {
        return try std.fmt.allocPrint(allocator, "No search results found for: {s}", .{query});
    }

    // 输出格式对齐 cc mapToolResultToToolResultBlockParam:
    //   Web search results for query: "<q>"
    //   <模型摘要>
    //   <结构化链接行>
    //   REMINDER: ...markdown hyperlinks.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("Web search results for query: \"{s}\"\n\n", .{query});
    if (text.len > 0) try out.writer.print("{s}\n\n", .{text});
    if (link_text.len > 0) try out.writer.print("{s}\n\n", .{link_text});
    try out.writer.writeAll("REMINDER: You MUST include the sources above in your response to the user using markdown hyperlinks.");
    return try out.toOwnedSlice();
}

fn setDetail(ctx: *const ToolContext, allocator: std.mem.Allocator, comptime fmt: []const u8, a: anytype) void {
    const slot = ctx.error_detail orelse return;
    slot.* = std.fmt.allocPrint(allocator, fmt, a) catch null;
}

/// 数 needle 在 haystack 中出现次数(用于从 content 数组数结果条数)。
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |i| : (pos = i + needle.len) n += 1;
    return n;
}
