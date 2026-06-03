//! WebSearch:普通函数工具(对齐 mecode WebSearchHandler)。
//!
//! 根因背景:把 Anthropic server-tool 异形对象 `{"type":"web_search_...","name":"web_search"}`
//! 直接放进主请求 tools 数组,会毒化 OpenAI-compat 后端(metask/MiniMax)的 function-calling
//! 解析,模型退回 Bash(二分实证)。mecode 的解法:WebSearch 是普通 {name,desc,input_schema}
//! 函数工具,真正搜索在**隔离子请求**里用 server tool 完成——server-tool 异形只出现在那个
//! 单工具子请求里,不污染主对话工具集。
//!
//! execute:用 ctx.api_client 发一次性子请求(user=query + 仅 web_search server tool),
//! drain 文本(EventIterator 已把 web_search_tool_result 渲染进文本流),返回给模型。

const std = @import("std");
const common = @import("common.zig");
const types = @import("../types.zig");
const json_mod = @import("../json.zig");
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
    const msgs = [_]types.ApiMessage{.{ .role = .user, .content = &.{.{ .text = query }} }};

    var stream = client.sendMessageStreamFull(&msgs, null, &tools_one, ctx.abort, null) catch |err| {
        setDetail(ctx, allocator, "web search request failed: {s}", .{@errorName(err)});
        return error.WebSearchFailed;
    };
    defer stream.deinit();
    stream.user_query = query; // 让结果显示真实 query

    // drain 文本(web_search 结果由 EventIterator 渲染进文本流)。
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    while (true) {
        const ev = stream.next() catch |err| {
            setDetail(ctx, allocator, "web search stream error: {s}", .{@errorName(err)});
            return error.WebSearchFailed;
        };
        const e = ev orelse break;
        switch (e) {
            .text => |t| {
                defer allocator.free(t);
                try out.appendSlice(allocator, t);
            },
            // 子请求只带 server tool,不会有 client tool_use;其余事件(usage/done)无需处理。
            else => {},
        }
    }

    const text = std.mem.trim(u8, out.items, " \t\r\n");
    if (text.len == 0) {
        return try std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\",\"results\":\"no results\"}}", .{query});
    }
    // 返回纯文本结果(已含渲染好的标题/URL 行)。
    return try allocator.dupe(u8, text);
}

fn setDetail(ctx: *const ToolContext, allocator: std.mem.Allocator, comptime fmt: []const u8, a: anytype) void {
    const slot = ctx.error_detail orelse return;
    slot.* = std.fmt.allocPrint(allocator, fmt, a) catch null;
}
