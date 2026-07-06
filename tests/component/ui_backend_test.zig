//! L2 组件测试:UI 解耦协议 + backend(阶段 A)。
//!
//! 两部分:
//! 1. **Mock backend**(收 CoreEvent 进 ArrayList)+ 事件序列断言——证明"换 UI
//!    后端"真可行(plan §可测试性:agent_loop 未来能用 mock backend 纯测)。
//! 2. **TuiBackend 适配**:emit(CoreEvent) → 断言 RenderRegion 状态变化;
//!    poll(MsgQueue/AbortSignal) → 断言产出对应 UiEvent。
//!
//! 全内存级:RenderRegion 用 /dev/null fd 构造,generating=false 故 emit 不触发
//! 终端 IO(只改 ui 状态)。

const std = @import("std");
const testing = std.testing;
const cc = @import("cc");

const ui_event = cc.ui_event;
const ui_backend = cc.ui_backend;
const tui_backend = cc.tui_backend;
const render_region = cc.tui_render_region;
const theme_mod = cc.tui_theme;
const msg_queue = cc.repl_msg_queue;
const abort = cc.util_abort;

const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;

// ---------------------------------------------------------------------------
// Part 1:Mock backend —— 收 CoreEvent 进 ArrayList,证明 vtable 契约可换实现。
// ---------------------------------------------------------------------------

const MockBackend = struct {
    events: std.ArrayList(CoreEvent) = .empty,
    allocator: std.mem.Allocator,
    /// poll 预置事件队列(测 UI→core 方向)。
    pending: std.ArrayList(UiEvent) = .empty,
    poll_idx: usize = 0,

    fn init(allocator: std.mem.Allocator) MockBackend {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *MockBackend) void {
        self.events.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    fn backend(self: *MockBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        // 注:mock 直接存 CoreEvent(含 borrow slice)。测试里 slice 指向静态字面量,
        // 生命周期覆盖整个测试,安全。真实后端必须同步拷贝。
        self.events.append(self.allocator, ev) catch unreachable;
    }
    fn pollThunk(ctx: *anyopaque, _: SessionId) ?UiEvent {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        if (self.poll_idx >= self.pending.items.len) return null;
        defer self.poll_idx += 1;
        return self.pending.items[self.poll_idx];
    }
};

/// 测试用的占位 session(N=1,所有调用都用它)。
const S: SessionId = SessionId.single;

test "mock backend: emit 序列被完整记录" {
    var mb = MockBackend.init(testing.allocator);
    defer mb.deinit();
    const be = mb.backend();

    be.emitEvent(S, .{ .text_chunk = "hi" });
    be.emitEvent(S, .{ .tool_start = .{ .id = "t1", .name = "Bash", .input = "{}" } });
    be.emitEvent(S, .{ .tool_progress = .{ .id = "t1", .text = "running" } });
    be.emitEvent(S, .{ .tool_result = .{ .id = "t1", .name = "Bash", .input = "{}", .content = "ok", .is_error = false } });
    be.emitEvent(S, .stream_done);

    try testing.expectEqual(@as(usize, 5), mb.events.items.len);
    try testing.expectEqualStrings("hi", mb.events.items[0].text_chunk);
    try testing.expectEqualStrings("Bash", mb.events.items[1].tool_start.name);
    try testing.expectEqualStrings("running", mb.events.items[2].tool_progress.text);
    try testing.expect(!mb.events.items[3].tool_result.is_error);
    try testing.expectEqual(CoreEvent.stream_done, mb.events.items[4]);
}

test "mock backend: poll 按序产出 UiEvent" {
    var mb = MockBackend.init(testing.allocator);
    defer mb.deinit();
    try mb.pending.append(testing.allocator, .{ .interrupt = .user_ctrl_c });
    try mb.pending.append(testing.allocator, .{ .queue_message = "next" });
    const be = mb.backend();

    const e1 = be.pollEvent(S) orelse return error.NoEvent;
    try testing.expectEqual(abort.Reason.user_ctrl_c, e1.interrupt);
    const e2 = be.pollEvent(S) orelse return error.NoEvent;
    try testing.expectEqualStrings("next", e2.queue_message);
    try testing.expect(be.pollEvent(S) == null); // 耗尽返 null
}

// ---------------------------------------------------------------------------
// Part 2:TuiBackend 适配 —— emit → RenderRegion 状态,poll → UiEvent。
// ---------------------------------------------------------------------------

fn makeRegion(allocator: std.mem.Allocator) !render_region.RenderRegion {
    // /dev/null fd:getSize 失败回退 24x80;generating=false 故 emit 不写终端。
    const fd = std.c.open("/dev/null", std.c.O{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenDevNull;
    const th = theme_mod.select(.dark, .none);
    return render_region.RenderRegion.init(allocator, fd, th, .none);
}

test "TuiBackend.emit: set_current_tool / clear_current_tool → spinner 状态" {
    var region = try makeRegion(testing.allocator);
    defer region.deinit();
    var tb = tui_backend.TuiBackend.init(&region);
    const be = tb.backend();

    be.emitEvent(S, .{ .set_current_tool = .{ .name = "Grep" } });
    try testing.expectEqualStrings("Grep", region.ui.tools.currentSlice());

    be.emitEvent(S, .clear_current_tool);
    try testing.expectEqual(@as(usize, 0), region.ui.tools.currentSlice().len);
}

test "TuiBackend.emit: tool_start(普通工具)→ backend 自决喂 spinner(spinner_fed)" {
    var region = try makeRegion(testing.allocator);
    defer region.deinit();
    var tb = tui_backend.TuiBackend.init(&region);
    const be = tb.backend();
    be.emitEvent(S, .{ .tool_start = .{ .id = "x", .name = "Grep", .input = "{}" } });
    // 层泄漏修复后:spinner 喂归 backend。普通工具(showStartCard,非进度卡)→ 喂第一个。
    try testing.expectEqualStrings("Grep", region.ui.tools.currentSlice());
    // clear_current_tool 重置 spinner_fed,清当前工具。
    be.emitEvent(S, .clear_current_tool);
    try testing.expectEqual(@as(usize, 0), region.ui.tools.currentSlice().len);
}

test "TuiBackend.emit: tool_start(WebSearch) → backend 自决进度卡 addToolCard + progress + clear" {
    var region = try makeRegion(testing.allocator);
    defer region.deinit();
    var tb = tui_backend.TuiBackend.init(&region);
    const be = tb.backend();

    be.emitEvent(S, .{ .tool_start = .{ .id = "ws1", .name = "WebSearch", .input = "{}" } });
    try testing.expectEqual(@as(u8, 1), region.ui.tools.cards_len);
    try testing.expectEqualStrings("WebSearch", region.ui.tools.cards[0].nameSlice());

    be.emitEvent(S, .{ .tool_progress = .{ .id = "ws1", .text = "Found 3" } });
    try testing.expectEqualStrings("Found 3", region.ui.tools.cards[0].progressSlice());

    be.emitEvent(S, .{ .tool_result = .{ .id = "ws1", .name = "WebSearch", .input = "{}", .content = "", .is_error = false } });
    try testing.expectEqual(@as(u8, 0), region.ui.tools.cards_len);
}

test "TuiBackend.emit: 类A(Bash)live card 两态 + 双 tool_result 只 commit 一次(R1 守卫)" {
    // 对齐 cc 2.1.165:Bash 执行期动态卡,完成 commit 进 scrollback(过去式标题)。
    // 关键:agent_loop 对每工具发两次 tool_result——:632 空 content / :668 真 content。
    // 只认 content.len>0 做 commit,:632 空事件 no-op,防双 commit。本测守卫这个坑。
    var region = try makeRegion(testing.allocator);
    defer region.deinit();
    var tb = tui_backend.TuiBackend.init(&region);
    // commitToolCard 需 theme+alloc(production 在 loop.zig 构造时设);测试显式设上。
    tb.theme = &region.theme;
    tb.alloc = testing.allocator;
    const be = tb.backend();

    // tool_start:类A 占动态卡 + 喂底部 spinner(卡 + spinner 并存)。
    be.emitEvent(S, .{ .tool_start = .{ .id = "b1", .name = "Bash", .input =
        \\{"command":"echo hi"}
    } });
    try testing.expectEqual(@as(u8, 1), region.ui.tools.cards_len);
    try testing.expectEqualStrings("Bash", region.ui.tools.cards[0].nameSlice());
    try testing.expectEqualStrings("Bash", region.ui.tools.currentSlice()); // spinner 也喂了

    // 第一次 tool_result(agent_loop:632 空事件):content="" → no-op,卡不动。
    be.emitEvent(S, .{ .tool_result = .{ .id = "b1", .name = "Bash", .input =
        \\{"command":"echo hi"}
    , .content = "", .is_error = false } });
    try testing.expectEqual(@as(u8, 1), region.ui.tools.cards_len); // 卡仍在,未 commit

    // 第二次 tool_result(agent_loop:668 真事件):content 非空 → commit + 清卡。
    be.emitEvent(S, .{ .tool_result = .{ .id = "b1", .name = "Bash", .input =
        \\{"command":"echo hi"}
    , .content =
        \\{"stdout":"hi\n","exit_code":0}
    , .is_error = false, .elapsed_ms = 100 } });
    try testing.expectEqual(@as(u8, 0), region.ui.tools.cards_len); // 卡已 commit 移除
}

test "TuiBackend.emit: usage 累加进 usage_acc" {
    var region = try makeRegion(testing.allocator);
    defer region.deinit();
    var acc = cc.app_module.UsageTotals{};
    var tb = tui_backend.TuiBackend.init(&region);
    tb.usage_acc = &acc;
    const be = tb.backend();

    be.emitEvent(S, .{ .usage = .{ .input_tokens = 100, .output_tokens = 20 } });
    be.emitEvent(S, .{ .usage = .{ .input_tokens = 5, .output_tokens = 3, .cache_read_input_tokens = 50 } });

    try testing.expectEqual(@as(u64, 105), acc.input_tokens);
    try testing.expectEqual(@as(u64, 23), acc.output_tokens);
    try testing.expectEqual(@as(u64, 50), acc.cache_read_input_tokens);
}

test "TuiBackend.poll: AbortSignal → interrupt(优先于 queue)" {
    var region = try makeRegion(testing.allocator);
    defer region.deinit();
    var q = msg_queue.MsgQueue.init(testing.allocator);
    defer q.deinit();
    var sig = abort.AbortSignal.init();

    var tb = tui_backend.TuiBackend.init(&region);
    tb.queue = &q;
    tb.abort_signal = &sig;
    const be = tb.backend();

    // 未中断 + 空队列 → null
    try testing.expect(be.pollEvent(S) == null);

    // 入队一条 + 触发中断:interrupt 优先
    _ = q.push("queued");
    sig.abort(.timeout);
    const e = be.pollEvent(S) orelse return error.NoEvent;
    try testing.expectEqual(abort.Reason.timeout, e.interrupt);
}

test "TuiBackend.poll: 仅队列有消息 → queue_message" {
    var region = try makeRegion(testing.allocator);
    defer region.deinit();
    var q = msg_queue.MsgQueue.init(testing.allocator);
    defer q.deinit();

    var tb = tui_backend.TuiBackend.init(&region);
    tb.queue = &q;
    const be = tb.backend();

    _ = q.push("hello");
    const e = be.pollEvent(S) orelse return error.NoEvent;
    try testing.expectEqualStrings("hello", e.queue_message);
    testing.allocator.free(e.queue_message); // poll 转移所有权,调用方 free
    try testing.expect(be.pollEvent(S) == null); // 取完返 null
}

// ---------------------------------------------------------------------------
// Part 3:WriterBackend 字节锁 —— 喂 CoreEvent,断言 sink 收到的字节 == legacy 串。
// 这是阶段 B1 原子切换前的字节精确保险:print-only 路径(DebugWriter/Sink)的输出
// 必须和旧 agent_loop 直 print 逐字节一致。
// ---------------------------------------------------------------------------

const writer_backend = cc.writer_backend;

const CaptureSink = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) CaptureSink {
        return .{ .allocator = a };
    }
    fn deinit(self: *CaptureSink) void {
        self.buf.deinit(self.allocator);
    }
    fn sink(ctx: *anyopaque, bytes: []const u8) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.buf.appendSlice(self.allocator, bytes) catch unreachable;
    }
};

test "WriterBackend 字节锁: stream_begin/text/stream_done(colorize) == legacy 括号" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .colorize = true };
    const be = wb.backend();

    be.emitEvent(S, .stream_begin);
    be.emitEvent(S, .{ .text_chunk = "hello world" });
    be.emitEvent(S, .stream_done);
    // legacy:print("\x1b[32m") + print("{s}",text) + print("\x1b[0m\n")
    try testing.expectEqualStrings("\x1b[32mhello world\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: !colorize → 无括号,stream_done 仍发 \\n" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .colorize = false };
    const be = wb.backend();

    be.emitEvent(S, .stream_begin); // 无 colorize → 不发
    be.emitEvent(S, .{ .text_chunk = "abc" });
    be.emitEvent(S, .stream_done); // 仍发 \n(legacy :422)
    try testing.expectEqualStrings("abc\n", cap.buf.items);
}

test "WriterBackend 字节锁: auto_compact == legacy 行" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink };
    const be = wb.backend();

    be.emitEvent(S, .{ .auto_compact = .{ .dropped = 5, .kept = 12 } });
    try testing.expectEqualStrings("\x1b[33m[auto-compacted 5 old messages, kept last 12]\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: context_warning visible" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink };
    const be = wb.backend();

    be.emitEvent(S, .{ .context_warning = .{
        .current_tokens = 160_000,
        .warning_threshold = 160_000,
        .auto_compact_threshold = 167_000,
        .blocking_limit = 177_000,
        .level = "medium",
    } });
    try testing.expectEqualStrings("\x1b[33m[context warning: 160000/160000 tokens, auto-compact at 167000, blocking at 177000]\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: retry 门控 + legacy 格式" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .colorize = true, .show_retry = true };
    const be = wb.backend();

    // attempt < 3 → 隐藏(降噪)
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 1, .max = 10, .delay_ms = 500 } });
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 2, .max = 10, .delay_ms = 500 } });
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);

    // attempt >= 3 → 显示(secs=ceil(2000/1000)=2)
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 3, .max = 10, .delay_ms = 2000 } });
    try testing.expectEqualStrings("\x1b[2mRetrying in 2s… (attempt 3/10)\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: !show_retry → 完全静默" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .show_retry = false };
    const be = wb.backend();
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 5, .max = 10, .delay_ms = 1000 } });
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

test "WriterBackend 字节锁: verbose tool_start(card=false) == legacy [Tool: name]" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .verbose = true };
    const be = wb.backend();
    be.emitEvent(S, .{ .tool_start = .{ .id = "t", .name = "Bash", .input = "{}" } });
    try testing.expectEqualStrings("\n\x1b[35m[Tool: Bash]\x1b[0m", cap.buf.items);
}

test "WriterBackend: 卡/spinner/progress/usage 事件全 no-op(print-only 不收卡字节)" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .verbose = false };
    const be = wb.backend();

    be.emitEvent(S, .{ .tool_start = .{ .id = "t", .name = "WebSearch", .input = "{}" } });
    be.emitEvent(S, .{ .set_current_tool = .{ .name = "Bash" } });
    be.emitEvent(S, .{ .tool_progress = .{ .id = "t", .text = "Found 3" } });
    be.emitEvent(S, .clear_current_tool);
    be.emitEvent(S, .{ .tool_result = .{ .id = "t", .name = "Bash", .input = "{}", .content = "ok", .is_error = false, .elapsed_ms = 10 } });
    be.emitEvent(S, .{ .usage = .{ .input_tokens = 5 } });
    be.emitEvent(S, .{ .phase_change = .generating });
    // verbose=false tool_start(card=false) 也不发 → 全程零字节。
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

test "WriterBackend.initNull: 丢弃一切 + poll 恒 null" {
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    be.emitEvent(S, .{ .text_chunk = "discarded" });
    be.emitEvent(S, .stream_done);
    try testing.expect(be.pollEvent(S) == null);
}
