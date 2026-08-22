//! StreamJsonBackend:headless `--stream-json` 的实时 NDJSON 发射器。
//!
//! 消费 agent_loop 的 CoreEvent,把与"运行中止损/定位"相关的事件逐行序列化
//! (每行一个 JSON,写完即 flush 到 sink)。与 `--json` 收尾的
//! `{"type":"result",...}` 行同一命名空间:消费侧(trace.py `final_result`)
//! 本就按 `type=="result"` 过滤事件列表,增量行完全前向兼容。
//!
//! 设计约束:
//! - **borrow slice 纪律**:emit 返回前必须消费完事件字节(本后端当场序列化
//!   写出,零保留)。
//! - **线程安全**:tool_progress/tool_result 可能来自工具线程,行构造+写出
//!   在互斥锁内,一行一次 write(sink 侧不再拼接,防交错)。
//! - **截断纪律**(2026-08-19 血泪):所有截断退到 UTF-8 码点边界,且显式
//!   携带 `"truncated":true`——静默截断是本战役头号惯犯。
//! - 渲染性事件(spinner/卡片/config)与 subagent 树事件忽略;这里是运行
//!   时间线,不是 UI。

const std = @import("std");
const ui_backend = @import("../core/protocol/ui_backend.zig");

const CoreEvent = ui_backend.CoreEvent;
const UiEvent = ui_backend.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;
const Mutex = @import("platform").sync.Mutex;

/// 单条 input/content 预览的截断上限(字节;码点边界回退后可能更短)。
pub const MAX_FIELD_PREVIEW: usize = 2048;

pub const Sink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, line: []const u8) void,

    pub fn write(self: *const Sink, line: []const u8) void {
        self.writeFn(self.ctx, line);
    }
};

pub const StreamJsonBackend = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, sink: Sink) StreamJsonBackend {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn backend(self: *StreamJsonBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    fn pollThunk(_: *anyopaque, _: SessionId) ?UiEvent {
        return null; // 纯观测,无输入端
    }

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *StreamJsonBackend = @ptrCast(@alignCast(ctx));
        self.emitEvent(ev);
    }

    fn emitEvent(self: *StreamJsonBackend, ev: CoreEvent) void {
        // 行构造失败(OOM)丢事件不致命,但不静默(与 DiagnosticsBackend 同则)。
        self.tryEmit(ev) catch {
            @import("../util/log.zig").warn("stream", "dropped stream-json event (OOM)", .{});
        };
    }

    fn tryEmit(self: *StreamJsonBackend, ev: CoreEvent) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        switch (ev) {
            .text_chunk => |text| {
                if (text.len == 0) return;
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.encodeJsonString(text, .{}, w);
                try w.writeAll("}\n");
            },
            .thinking_chunk => |text| {
                if (text.len == 0) return;
                try w.writeAll("{\"type\":\"thinking\",\"text\":");
                try std.json.Stringify.encodeJsonString(text, .{}, w);
                try w.writeAll("}\n");
            },
            .tool_start => |t| {
                try w.writeAll("{\"type\":\"tool_start\",\"id\":");
                try std.json.Stringify.encodeJsonString(t.id, .{}, w);
                try w.writeAll(",\"name\":");
                try std.json.Stringify.encodeJsonString(t.name, .{}, w);
                try w.writeAll(",\"input\":");
                try writePreview(w, t.input);
                try w.print(",\"input_bytes\":{d}", .{t.input.len});
                if (t.input.len > MAX_FIELD_PREVIEW) try w.writeAll(",\"truncated\":true");
                try w.writeAll("}\n");
            },
            .tool_result => |t| {
                try w.writeAll("{\"type\":\"tool_result\",\"id\":");
                try std.json.Stringify.encodeJsonString(t.id, .{}, w);
                try w.writeAll(",\"name\":");
                try std.json.Stringify.encodeJsonString(t.name, .{}, w);
                try w.print(",\"is_error\":{},\"elapsed_ms\":{d},\"content_bytes\":{d},\"content\":", .{
                    t.is_error, t.elapsed_ms, t.content.len,
                });
                try writePreview(w, t.content);
                if (t.content.len > MAX_FIELD_PREVIEW) try w.writeAll(",\"truncated\":true");
                try w.writeAll("}\n");
            },
            .usage => |u| {
                try w.print(
                    "{{\"type\":\"usage\",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_input_tokens\":{d},\"cache_creation_input_tokens\":{d}}}\n",
                    .{ u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens },
                );
            },
            .diag_turn_begin => |d| try w.print("{{\"type\":\"turn_begin\",\"turn\":{d}}}\n", .{d.turn}),
            .diag_turn_end => |d| try w.print(
                "{{\"type\":\"turn_end\",\"turn\":{d},\"tool_calls\":{d}}}\n",
                .{ d.turn, d.tool_calls },
            ),
            .diag_run_end => |d| try w.print(
                "{{\"type\":\"run_end\",\"turns\":{d},\"tool_calls\":{d},\"stop_reason\":\"{s}\"}}\n",
                .{ d.turns, d.tool_calls, d.stop_reason_name },
            ),
            .context_warning => |c| try w.print(
                "{{\"type\":\"context_warning\",\"current_tokens\":{d},\"auto_compact_threshold\":{d}}}\n",
                .{ c.current_tokens, c.auto_compact_threshold },
            ),
            .auto_compact => |c| try w.print(
                "{{\"type\":\"auto_compact\",\"dropped\":{d},\"kept\":{d}}}\n",
                .{ c.dropped, c.kept },
            ),
            // 输出语义定性(见 core/output_semantics.zig)。**没有它,本流的消费者只能看到一串
            // 无差别的 `text` 行**:分不清工具前的过程说明与最终答案,拼不回 max_tokens 续写,
            // 也丢不掉被回滚的残片——正是这条协议要消灭的重复状态机。
            // 消费者:按 `index` 把 `text` 行归段,收到本行后按 `disposition` 处置
            // (`discarded` → 丢弃该段已缓冲字节;`final`+`continued` 同 `group` 拼成答案)。
            // 增量 type,按本文件头的前向兼容约定,老消费者按 type 过滤即可无视。
            .output_segment_begin => |seg| try w.print(
                "{{\"type\":\"output_segment_begin\",\"index\":{d},\"turn\":{d},\"group\":{d}}}\n",
                .{ seg.index, seg.turn, seg.group },
            ),
            .output_segment_end => |seg| try w.print(
                "{{\"type\":\"output_segment_end\",\"index\":{d},\"turn\":{d},\"group\":{d},\"disposition\":\"{s}\",\"bytes\":{d}}}\n",
                .{ seg.index, seg.turn, seg.group, @tagName(seg.disposition), seg.bytes },
            ),
            else => return, // 渲染/roster/config 事件不入运行时间线
        }
        const line = aw.written();
        if (line.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sink.write(line);
    }
};

/// 把 s 的前 MAX_FIELD_PREVIEW 字节(退到码点边界)作为 JSON 字符串写出。
fn writePreview(w: *std.Io.Writer, s: []const u8) !void {
    var end: usize = @min(s.len, MAX_FIELD_PREVIEW);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    try std.json.Stringify.encodeJsonString(s[0..end], .{}, w);
}

// ── 测试 ─────────────────────────────────────────────────────────────────

const CaptureSink = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    lines: usize = 0,

    fn sink(self: *CaptureSink) Sink {
        return .{ .ctx = @ptrCast(self), .writeFn = &writeFn };
    }
    fn writeFn(ctx: *anyopaque, line: []const u8) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.buf.appendSlice(self.allocator, line) catch {};
        self.lines += 1;
    }
};

test "StreamJsonBackend: 事件→NDJSON 行,每行合法 JSON,忽略渲染事件" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    be.emitEvent(sid, .{ .tool_start = .{ .id = "t1", .name = "Bash", .input = "{\"command\":\"ls\"}" } });
    be.emitEvent(sid, .{ .text_chunk = "hello \"world\"\n" });
    be.emitEvent(sid, .stream_begin); // 渲染事件:应被忽略
    be.emitEvent(sid, .{ .tool_result = .{ .id = "t1", .name = "Bash", .input = "", .content = "ok", .is_error = false, .elapsed_ms = 12 } });
    be.emitEvent(sid, .{ .usage = .{ .input_tokens = 10, .output_tokens = 5 } });

    try std.testing.expectEqual(@as(usize, 4), cap.lines);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cap.buf.items, "\n"), '\n');
    var kinds = std.ArrayList([]const u8).empty;
    defer {
        for (kinds.items) |k| a.free(k);
        kinds.deinit(a);
    }
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        try kinds.append(a, try a.dupe(u8, parsed.value.object.get("type").?.string));
    }
    try std.testing.expectEqual(@as(usize, 4), kinds.items.len);
    try std.testing.expectEqualStrings("tool_start", kinds.items[0]);
    try std.testing.expectEqualStrings("text", kinds.items[1]);
    try std.testing.expectEqualStrings("tool_result", kinds.items[2]);
    try std.testing.expectEqualStrings("usage", kinds.items[3]);
}

test "StreamJsonBackend: 输出段定性进时间线,消费者不必自建 final 状态机" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    // 工具前的过程说明 → commentary;续写两段 → continued + final(同 group)。
    be.emitEvent(sid, .{ .output_segment_begin = .{ .index = 0, .turn = 1, .group = 0 } });
    be.emitEvent(sid, .{ .text_chunk = "looking…" });
    be.emitEvent(sid, .{ .output_segment_end = .{ .index = 0, .turn = 1, .group = 0, .disposition = .commentary, .bytes = 9 } });
    be.emitEvent(sid, .{ .output_segment_begin = .{ .index = 1, .turn = 2, .group = 1 } });
    be.emitEvent(sid, .{ .text_chunk = "half " });
    be.emitEvent(sid, .{ .output_segment_end = .{ .index = 1, .turn = 2, .group = 1, .disposition = .continued, .bytes = 5 } });
    be.emitEvent(sid, .{ .output_segment_begin = .{ .index = 2, .turn = 2, .group = 1 } });
    be.emitEvent(sid, .{ .text_chunk = "done" });
    be.emitEvent(sid, .{ .output_segment_end = .{ .index = 2, .turn = 2, .group = 1, .disposition = .final, .bytes = 4 } });

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cap.buf.items, "\n"), '\n');
    var open_index: ?i64 = null;
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(a);
    var buffered: std.ArrayList(u8) = .empty;
    defer buffered.deinit(a);
    var saw_final = false;

    // 一个**只看这条流**的消费者:按 index 归段,按 disposition 处置。
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const kind = obj.get("type").?.string;
        if (std.mem.eql(u8, kind, "output_segment_begin")) {
            open_index = obj.get("index").?.integer;
            buffered.clearRetainingCapacity();
        } else if (std.mem.eql(u8, kind, "text")) {
            try std.testing.expect(open_index != null); // 文本永远落在某个段内
            try buffered.appendSlice(a, obj.get("text").?.string);
        } else if (std.mem.eql(u8, kind, "output_segment_end")) {
            try std.testing.expectEqual(open_index.?, obj.get("index").?.integer);
            const disposition = obj.get("disposition").?.string;
            if (std.mem.eql(u8, disposition, "continued") or std.mem.eql(u8, disposition, "final")) {
                try answer.appendSlice(a, buffered.items);
                if (std.mem.eql(u8, disposition, "final")) saw_final = true;
            }
            open_index = null;
            buffered.clearRetainingCapacity();
        }
    }
    try std.testing.expect(saw_final);
    try std.testing.expectEqualStrings("half done", answer.items); // commentary 不在答案里
}

test "StreamJsonBackend: 超限 input 截断到码点边界且显式标注" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    // 中文填充:MAX_FIELD_PREVIEW 处大概率切进 3 字节码点中间。
    var big = std.ArrayList(u8).empty;
    defer big.deinit(a);
    while (big.items.len < MAX_FIELD_PREVIEW + 64) try big.appendSlice(a, "判定");
    be.emitEvent(sid, .{ .tool_start = .{ .id = "t2", .name = "Bash", .input = big.items } });

    const line = std.mem.trimEnd(u8, cap.buf.items, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("truncated").?.bool);
    const input = obj.get("input").?.string;
    try std.testing.expect(input.len <= MAX_FIELD_PREVIEW);
    try std.testing.expect(std.unicode.utf8ValidateSlice(input));
    try std.testing.expectEqual(@as(i64, @intCast(big.items.len)), obj.get("input_bytes").?.integer);
}

test "StreamJsonBackend: run() 同款 tee 组合——usage 记账腿与流式腿同时生效" {
    const a = std.testing.allocator;
    const writer_backend = @import("../core/writer_backend.zig");
    const tee_backend_mod = @import("../core/tee_backend.zig");
    const UsageTotals = @import("../core/usage.zig").UsageTotals;

    var usage = UsageTotals{};
    var wb = writer_backend.WriterBackend.initNullWithUsage(&usage);
    var wb_be = wb.backend();
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    var sjb_be = sjb.backend();
    var stream_tee = tee_backend_mod.TeeBackend{ .primary = &wb_be, .secondary = &sjb_be };
    const be = stream_tee.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    be.emitEvent(sid, .{ .tool_start = .{ .id = "t1", .name = "Bash", .input = "{}" } });
    be.emitEvent(sid, .{ .usage = .{ .input_tokens = 7, .output_tokens = 3 } });
    be.emitEvent(sid, .{ .tool_result = .{ .id = "t1", .name = "Bash", .input = "", .content = "done", .is_error = false } });

    // 流式腿:三行 NDJSON 到 sink。
    try std.testing.expectEqual(@as(usize, 3), cap.lines);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "\"type\":\"tool_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "\"type\":\"tool_result\"") != null);
    // 记账腿:usage 照常累计(tee 不吞 primary)。
    try std.testing.expectEqual(@as(u64, 7), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 3), usage.output_tokens);
}
