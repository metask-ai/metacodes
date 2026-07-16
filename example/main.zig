//! metacodes-core 最小示例:用库跑一轮 agent loop,自定义一个把 CoreEvent 打到 stdout
//! 的 backend。证明库可被独立 Zig 程序经 module 消费,无需任何 UI/CLI 依赖。
//!
//! 跑法(默认打真端点,需要有效 key):
//!   METACODES_API_KEY=sk-... zig build example
//! 离线/无 key:把库消费端指向 repo 自带的 mock server(见 doc/LIB_API.md 跑法节),
//!   或仅用此程序观察 backend 接线(连接失败时 run 返 api_error,程序正常退出)。

const std = @import("std");
const mc = @import("metacodes-core");

const CoreEvent = mc.protocol.ui_event.CoreEvent;
const UiEvent = mc.protocol.ui_event.UiEvent;
const UiBackend = mc.protocol.ui_backend.UiBackend;

/// 最小自定义前端:把语义 CoreEvent 打印到 stdout。真实前端在此渲染 TUI/GUI/网页。
const PrintBackend = struct {
    fn emit(ctx: *anyopaque, _: mc.session_id.SessionId, ev: CoreEvent) void {
        _ = ctx;
        switch (ev) {
            .text_chunk => |t| std.debug.print("{s}", .{t}),
            .tool_start => |s| std.debug.print("\n[tool_start] {s} {s}\n", .{ s.name, s.input }),
            .tool_result => |r| std.debug.print("[tool_result] {s} (is_error={})\n", .{ r.name, r.is_error }),
            .stream_done => std.debug.print("\n", .{}),
            else => {}, // usage/phase_change/retry/auto_compact/… 此 demo 略
        }
    }
    fn poll(ctx: *anyopaque, _: mc.session_id.SessionId) ?UiEvent {
        _ = ctx;
        return null; // 无输入注入(不打断、不续发消息)
    }
    fn backend(self: *PrintBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();

    const api_key = if (std.c.getenv("METACODES_API_KEY")) |k|
        std.mem.span(k)
    else {
        // 内置 demo token 已随多 provider 重构移除(不再仓库内置密钥);
        // 例子演示库消费,需真跑请设 METACODES_API_KEY。
        std.debug.print("set METACODES_API_KEY to run this example against a live endpoint\n", .{});
        return;
    };

    var client = mc.client.Client.init(a, init.io, api_key, "claude-3-5-haiku-20241022");

    var conv = mc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "Reply with a single word: hello");

    var perm = mc.permission.PermissionContext{ .allocator = a };

    const tool_defs: []const mc.json.ToolDefinition = &.{}; // 此 demo 不开工具

    var pb = PrintBackend{};
    const be = pb.backend();

    const result = mc.agent_loop.run(
        &conv,
        client.provider(), // 中立 Provider vtable(多 provider 重构后 run 收值非 *Client)
        tool_defs,
        &perm,
        .{ .max_turns = 2, .emit_tool_cards = false, .colorize = false },
        &be,
        a,
    ) catch |err| {
        std.debug.print("\n[example] run error: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print(
        "\n[example] done: stop={s} turns={d} tool_calls={d}\n",
        .{ @tagName(result.stop_reason), result.turns, result.tool_calls },
    );
}
