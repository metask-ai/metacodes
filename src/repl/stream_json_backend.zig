//! StreamJsonBackend:headless `--stream-json` 的实时 NDJSON 发射器。
//!
//! 消费 agent_loop 的 CoreEvent,把与"运行中止损/定位"相关的事件逐行序列化
//! (每行一个 JSON,写完即 flush 到 sink)。与 `--json` 收尾的
//! `{"type":"result",...}` 行同一命名空间:消费侧(trace.py `final_result`)
//! 本就按 `type=="result"` 过滤事件列表,增量行完全前向兼容。
//!
//! 设计约束:
//! - **borrow slice 纪律**:emit 返回前必须消费完事件字节(本后端当场序列化
//!   写出,零保留)。唯一例外是下文的 UTF-8 尾巴:至多 3 字节,拷进自有缓冲。
//! - **线程安全**:tool_progress/tool_result 可能来自工具线程,悬挂状态、行构造
//!   与写出在同一把互斥锁内,一行一次 write(sink 侧不再拼接,防交错)。
//! - **截断纪律**(2026-08-19 血泪):所有截断退到 UTF-8 码点边界,且显式
//!   携带 `"truncated":true`——静默截断是本战役头号惯犯。
//! - **UTF-8 纪律**(2026-09-05 WorkBuddy 现场):每一行都是合法 UTF-8。
//!   std.json 的 `encodeJsonString` 默认原样透传 0x80..0xFF,`Read` 一个 PDF 的
//!   tool_result 就曾把 `%\x93\x8c\x8b\x9e` 直送 stdout,消费端 strict decode 把整个
//!   cohort 判废。字符串字段一律走 `util/json.zig` 的规范编码器(非法字节 → U+FFFD,
//!   `*_bytes` 仍记原始长度);text/thinking 增量若在多字节字符中间断开,尾巴悬挂到
//!   下一个同种增量拼回(无损),块结束仍拼不上 → 一个 U+FFFD 独立成行(显式,不静默丢)。
//! - 渲染性事件(spinner/卡片/config)与 subagent 树事件忽略;这里是运行
//!   时间线,不是 UI。

const std = @import("std");
const ui_backend = @import("../core/protocol/ui_backend.zig");
const util_json = @import("../util/json.zig");

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

/// 增量种类:悬挂的尾巴只能被同种增量接续(text 块与 thinking 块不会交错)。
const ChunkKind = enum {
    text,
    thinking,

    fn linePrefix(self: ChunkKind) []const u8 {
        return switch (self) {
            .text => "{\"type\":\"text\",\"text\":\"",
            .thinking => "{\"type\":\"thinking\",\"text\":\"",
        };
    }

    /// 块结束仍拼不上的尾巴:一个丢失的字符 = 一个 U+FFFD,独立成行,type 同块。
    fn lostCharLine(self: ChunkKind) []const u8 {
        return switch (self) {
            .text => "{\"type\":\"text\",\"text\":\"\u{FFFD}\"}\n",
            .thinking => "{\"type\":\"thinking\",\"text\":\"\u{FFFD}\"}\n",
        };
    }
};

/// 跨增量悬挂的不完整 UTF-8 序列前缀。至多 3 字节(4 字节序列缺最后 1 字节),
/// 且由构造保证是 Unicode 表 3-7 意义下的合法前缀(见 incompleteUtf8Tail)。
const PendingTail = struct {
    kind: ChunkKind,
    /// 按 lead 字节该序列应有的总长(2..4)。
    need: u8,
    /// 已到手的字节数(1..3,恒 < need)。
    len: u8,
    bytes: [3]u8,

    fn init(kind: ChunkKind, need: u8, prefix: []const u8) PendingTail {
        var tail = PendingTail{ .kind = kind, .need = need, .len = @intCast(prefix.len), .bytes = undefined };
        @memcpy(tail.bytes[0..prefix.len], prefix);
        return tail;
    }

    fn slice(self: *const PendingTail) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const StreamJsonBackend = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    mutex: Mutex = .{},
    /// 上一个 text/thinking 增量末尾没凑齐的多字节字符(见文件头"UTF-8 纪律")。
    pending: ?PendingTail = null,

    pub fn init(allocator: std.mem.Allocator, sink: Sink) StreamJsonBackend {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn backend(self: *StreamJsonBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    /// 收口:仍悬挂的半个字符按 U+FFFD 独立成行写出。diag_run_end 进时间线时已做同样
    /// 的事;headless 在 run 返回后再显式调一次,兜住 run 报错提前返回、没走到 run_end
    /// 的路径。幂等。
    pub fn flush(self: *StreamJsonBackend) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushPendingLocked();
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
        // 悬挂状态、行构造与写出在同一把锁内:工具线程的 tool_result 不能插进主线程
        // "拼回半个字符 → 写行"的中间。
        self.mutex.lock();
        defer self.mutex.unlock();
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        switch (ev) {
            .text_chunk => |text| return self.emitChunkLocked(&aw, .text, text),
            .thinking_chunk => |text| return self.emitChunkLocked(&aw, .thinking, text),
            // 一次 provider 流结束 = 当前 text/thinking 块必然结束。本事件不入时间线,
            // 但要收口悬挂:拼不上的尾巴不能悄悄等到下一轮的第一个增量。
            .stream_done => return self.flushPendingLocked(),
            .tool_start => |t| {
                try w.writeAll("{\"type\":\"tool_start\",\"id\":");
                try util_json.writeJsonString(w, t.id);
                try w.writeAll(",\"name\":");
                try util_json.writeJsonString(w, t.name);
                try w.writeAll(",\"input\":");
                try writePreview(w, t.input);
                try w.print(",\"input_bytes\":{d}", .{t.input.len});
                if (t.input.len > MAX_FIELD_PREVIEW) try w.writeAll(",\"truncated\":true");
                try w.writeAll("}\n");
            },
            .tool_result => |t| {
                try w.writeAll("{\"type\":\"tool_result\",\"id\":");
                try util_json.writeJsonString(w, t.id);
                try w.writeAll(",\"name\":");
                try util_json.writeJsonString(w, t.name);
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
        // 任何进入时间线的非增量事件都终结当前块:悬挂的尾巴先按 U+FFFD 收口,再写本事件,
        // 行序即真实时间线。
        self.flushPendingLocked();
        self.sink.write(line);
    }

    fn flushPendingLocked(self: *StreamJsonBackend) void {
        const tail = self.pending orelse return;
        self.pending = null;
        self.sink.write(tail.kind.lostCharLine());
    }

    /// text/thinking 增量 → 一行。三步:接上一增量悬挂的序列头 → 编码正文 → 扣下本增量
    /// 末尾不完整的序列尾。整片都进了悬挂(如逐字节到达)则本次不产生行。
    fn emitChunkLocked(
        self: *StreamJsonBackend,
        aw: *std.Io.Writer.Allocating,
        kind: ChunkKind,
        chunk: []const u8,
    ) !void {
        if (chunk.len == 0) return;
        // 种类切换(text↔thinking)= 上一个块已结束,它的尾巴不可能被本增量接续。
        if (self.pending) |tail| {
            if (tail.kind != kind) self.flushPendingLocked();
        }
        const w = &aw.writer;
        try w.writeAll(kind.linePrefix());
        var rest = chunk;
        var wrote_content = false;

        if (self.pending) |tail| {
            self.pending = null;
            var joined: [4]u8 = undefined;
            @memcpy(joined[0..tail.len], tail.slice());
            const take: usize = @min(@as(usize, tail.need - tail.len), rest.len);
            @memcpy(joined[tail.len..][0..take], rest[0..take]);
            const have: usize = tail.len + take;
            if (have < tail.need) {
                // 本增量太短,连一个字符都凑不齐(极端:逐字节到达)。仍是合法前缀 → 全部
                // 字节继续悬挂,本次无可写出;否则悬挂的那个字符已丢:记 U+FFFD,本增量的
                // 字节一个不吞,交给下面的常规编码(各自 U+FFFD)。
                if (utf8PrefixValid(joined[0..have])) {
                    self.pending = PendingTail.init(kind, tail.need, joined[0..have]);
                    return;
                }
                try w.writeAll("\u{FFFD}");
            } else if (std.unicode.utf8ValidateSlice(joined[0..tail.need])) {
                // 拼成合法字符(JSON 里多字节字符无需转义);被吞掉的开头不再进正文编码。
                try w.writeAll(joined[0..tail.need]);
                rest = rest[take..];
            } else {
                // 接不上(本增量开头不是这个序列的续接字节):悬挂的字符已丢,记 U+FFFD;
                // 本增量一个字节不吞,原样交给常规编码。
                try w.writeAll("\u{FFFD}");
            }
            wrote_content = true;
        }

        // 本增量末尾"合法但不完整"的序列 → 扣下悬挂,等下一同种增量;垃圾尾巴不悬挂,
        // 交给编码器逐字节替换。
        var body = rest;
        if (incompleteUtf8Tail(rest)) |tail| {
            body = rest[0 .. rest.len - tail.len];
            self.pending = PendingTail.init(kind, tail.need, rest[body.len..]);
        }
        if (body.len > 0) {
            try util_json.writeJsonStringContents(w, body);
            wrote_content = true;
        }
        if (!wrote_content) return;
        try w.writeAll("\"}\n");
        self.sink.write(aw.written());
    }
};

/// 把 s 的前 MAX_FIELD_PREVIEW 字节(退到码点边界)作为 JSON 字符串写出。
/// 非法 UTF-8 字节由规范编码器替换为 U+FFFD(二进制工具输出常见),行仍严格可解码。
fn writePreview(w: *std.Io.Writer, s: []const u8) !void {
    var end: usize = @min(s.len, MAX_FIELD_PREVIEW);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    try util_json.writeJsonString(w, s[0..end]);
}

const IncompleteTail = struct { len: u8, need: u8 };

/// s 尾部"合法但不完整"的 UTF-8 序列:返回已到手的字节数与该序列应有的总长;尾部完整、
/// 或根本不是合法前缀 → null。只认 Unicode 表 3-7 的合法前缀(E0 后必须 A0..BF、ED 后
/// 80..9F、F0 后 90..BF、F4 后 80..8F);非法前缀不悬挂——交给编码器逐字节替换,免得把
/// 垃圾字节和下一增量开头的合法字符粘成一个"字符"。
fn incompleteUtf8Tail(s: []const u8) ?IncompleteTail {
    var cont: usize = 0;
    while (cont < 3 and cont < s.len and (s[s.len - 1 - cont] & 0xC0) == 0x80) cont += 1;
    if (cont >= s.len or cont == 3) return null; // 无 lead / 3 个 continuation 之后不可能还缺
    const lead_at = s.len - 1 - cont;
    const need = std.unicode.utf8ByteSequenceLength(s[lead_at]) catch return null;
    const have = cont + 1;
    if (need == 1 or have >= need) return null; // ASCII / 已完整(合法与否由编码器裁决)
    if (!utf8PrefixValid(s[lead_at..])) return null;
    return .{ .len = @intCast(have), .need = need };
}

/// p 是某个多字节序列的真前缀(p[0] 为 lead,其后为 continuation 字节,p.len < 序列长),
/// 判断它能否延展成合法序列(Unicode 表 3-7)。
fn utf8PrefixValid(p: []const u8) bool {
    const lead = p[0];
    switch (lead) {
        0xC2...0xDF => {}, // 2 字节序列:lead 本身即合法前缀
        0xE0...0xEF, 0xF0...0xF4 => {
            if (p.len >= 2) {
                const b1 = p[1];
                const ok = switch (lead) {
                    0xE0 => b1 >= 0xA0 and b1 <= 0xBF,
                    0xED => b1 >= 0x80 and b1 <= 0x9F, // 排除代理区 D800..DFFF
                    0xF0 => b1 >= 0x90 and b1 <= 0xBF,
                    0xF4 => b1 >= 0x80 and b1 <= 0x8F, // 不超过 U+10FFFF
                    else => b1 >= 0x80 and b1 <= 0xBF,
                };
                if (!ok) return false;
            }
            if (p.len >= 3 and (p[2] & 0xC0) != 0x80) return false;
        },
        else => return false, // 80..C1(continuation / overlong lead)、F5..FF
    }
    return true;
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

/// 测试裁判:整个输出必须是合法 UTF-8,且每一行都被 std.json 严格接受
/// (Scanner 会校验字符串内的 UTF-8——能 parse 即"严格可解码")。
fn expectStrictNdjson(a: std.mem.Allocator, buf: []const u8) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(buf));
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch |e| {
            std.debug.print("std.json rejected line: {x}\n", .{line});
            return e;
        };
        parsed.deinit();
    }
}

/// 消费者视角的重组:按 type 过滤,把各行 text 顺序拼接。owned。
fn joinTextLines(a: std.mem.Allocator, buf: []const u8, kind: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        if (!std.mem.eql(u8, obj.get("type").?.string, kind)) continue;
        try out.appendSlice(a, obj.get("text").?.string);
    }
    return out.toOwnedSlice(a);
}

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

test "StreamJsonBackend: tool_result 带二进制字节(PDF 头 %93 8C 8B 9E)→ 行仍是合法 UTF-8,严格可解码" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    // 2026-09-05 patron 现场原样:Read 一个 ReportLab PDF,第二行的二进制标记直送了 stdout。
    // id/name/input 同样是不可信字节,一并带脏。
    const pdf_head = "     1\t%PDF-1.3\n     2\t%\x93\x8c\x8b\x9e ReportLab Generated PDF document (opensource)\n";
    be.emitEvent(sid, .{ .tool_start = .{ .id = "call_\xff", .name = "Re\xc0ad", .input = "{\"file_path\":\"a\x93.pdf\"}" } });
    be.emitEvent(sid, .{ .tool_result = .{ .id = "call_\xff", .name = "Read", .input = "", .content = pdf_head, .is_error = false, .elapsed_ms = 1 } });

    try std.testing.expectEqual(@as(usize, 2), cap.lines);
    try expectStrictNdjson(a, cap.buf.items);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cap.buf.items, "\n"), '\n');
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, it.next().?, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("call_\u{FFFD}", obj.get("id").?.string);
        try std.testing.expectEqualStrings("Re\u{FFFD}ad", obj.get("name").?.string);
        try std.testing.expectEqualStrings("{\"file_path\":\"a\u{FFFD}.pdf\"}", obj.get("input").?.string);
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, it.next().?, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings(
            "     1\t%PDF-1.3\n     2\t%\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD} ReportLab Generated PDF document (opensource)\n",
            obj.get("content").?.string,
        );
        // 字节账仍记原始负载:替换只改变呈现,不篡改证据;未超限不得标 truncated。
        try std.testing.expectEqual(@as(i64, @intCast(pdf_head.len)), obj.get("content_bytes").?.integer);
        try std.testing.expect(obj.get("truncated") == null);
    }
}

test "StreamJsonBackend: 文本增量在多字节字符中间断开 → 跨行无损拼回,每行严格可解码" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    // "判定" = E5 88 A4 E5 AE 9A:第一刀切在"判"的第 2/3 字节之间;
    // "🎉" = F0 9F 8E 89:切成 1+1+2 字节,中间那片连一个字符都凑不齐,只能继续悬挂。
    be.emitEvent(sid, .{ .text_chunk = "结论:\xe5\x88" });
    try expectStrictNdjson(a, cap.buf.items); // 悬挂中:已写出的字节里没有半个字符
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "\xe5\x88") == null);
    be.emitEvent(sid, .{ .text_chunk = "\xa4定 \xf0" });
    be.emitEvent(sid, .{ .text_chunk = "\x9f" });
    try std.testing.expectEqual(@as(usize, 2), cap.lines); // 单字节片全进悬挂,不产生行
    be.emitEvent(sid, .{ .text_chunk = "\x8e\x89!" });

    try expectStrictNdjson(a, cap.buf.items);
    const joined = try joinTextLines(a, cap.buf.items, "text");
    defer a.free(joined);
    try std.testing.expectEqualStrings("结论:判定 🎉!", joined);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "\u{FFFD}") == null); // 无损:一个 U+FFFD 都没有
}

test "StreamJsonBackend: 块结束仍拼不上的尾巴 → 先以 U+FFFD 独立成行再写后续事件,行序即时间线" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    be.emitEvent(sid, .{ .text_chunk = "abc\xe5\x88" }); // "abc" 出行,E5 88 悬挂
    be.emitEvent(sid, .{ .thinking_chunk = "hmm" }); // 种类切换 = text 块结束 → 先 text U+FFFD 行
    be.emitEvent(sid, .{ .thinking_chunk = "\xe7\xbb" }); // 整片悬挂,无行
    be.emitEvent(sid, .{ .tool_start = .{ .id = "t1", .name = "Bash", .input = "{}" } }); // 时间线事件 = 块结束
    be.emitEvent(sid, .{ .text_chunk = "\xf0\x9f" }); // 整片悬挂,无行
    be.emitEvent(sid, .stream_done); // 流结束:不入时间线,但收口悬挂
    be.emitEvent(sid, .{ .text_chunk = "tail\xc3" }); // "tail" 出行,C3 悬挂
    be.emitEvent(sid, .{ .diag_run_end = .{ .trace_id = [_]u8{'t'} ** 12, .depth = 0, .turns = 1, .tool_calls = 1, .stop_reason_name = "end_turn" } });
    sjb.flush(); // 幂等:已收口,不再产生行

    try expectStrictNdjson(a, cap.buf.items);
    const Expect = struct { kind: []const u8, text: ?[]const u8 };
    const expected = [_]Expect{
        .{ .kind = "text", .text = "abc" },
        .{ .kind = "text", .text = "\u{FFFD}" },
        .{ .kind = "thinking", .text = "hmm" },
        .{ .kind = "thinking", .text = "\u{FFFD}" },
        .{ .kind = "tool_start", .text = null },
        .{ .kind = "text", .text = "\u{FFFD}" },
        .{ .kind = "text", .text = "tail" },
        .{ .kind = "text", .text = "\u{FFFD}" },
        .{ .kind = "run_end", .text = null },
    };
    try std.testing.expectEqual(expected.len, cap.lines);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cap.buf.items, "\n"), '\n');
    for (expected) |e| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, it.next().?, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings(e.kind, obj.get("type").?.string);
        if (e.text) |t| try std.testing.expectEqualStrings(t, obj.get("text").?.string);
    }
    try std.testing.expect(it.next() == null);
}

test "StreamJsonBackend: 悬挂尾巴接不上下一增量 → 尾巴记 U+FFFD,下一增量一个字节不吞" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    be.emitEvent(sid, .{ .text_chunk = "\xe7\xbb" }); // 整片悬挂
    be.emitEvent(sid, .{ .text_chunk = "abc" }); // 拼不上 → U+FFFD + "abc"
    be.emitEvent(sid, .{ .text_chunk = "\xe7\xbb" });
    be.emitEvent(sid, .{ .text_chunk = "\x93\xe7\xbb\x93" }); // 拼得上 → "结结"
    be.emitEvent(sid, .{ .text_chunk = "\xe0" });
    be.emitEvent(sid, .{ .text_chunk = "\x80x" }); // E0 80 是 overlong 前缀:尾巴 U+FFFD,0x80 自身 U+FFFD,x 原样

    try expectStrictNdjson(a, cap.buf.items);
    const joined = try joinTextLines(a, cap.buf.items, "text");
    defer a.free(joined);
    try std.testing.expectEqualStrings("\u{FFFD}abc结结\u{FFFD}\u{FFFD}x", joined);
}

test "StreamJsonBackend: 增量中段的非法字节逐字节 U+FFFD,相邻合法字符不受影响" {
    const a = std.testing.allocator;
    var cap = CaptureSink{ .allocator = a };
    defer cap.buf.deinit(a);
    var sjb = StreamJsonBackend.init(a, cap.sink());
    const be = sjb.backend();
    const sid = @import("../core/session_id.zig").SessionId.single;

    be.emitEvent(sid, .{ .text_chunk = "a\x93b判\xff\xfe定\x93\x8c\x8b\x9e" }); // 尾部的孤立 continuation 不是前缀,不悬挂
    be.emitEvent(sid, .{ .thinking_chunk = "x\xed\xa0\x80y" }); // CESU-8 代理编码:非法

    try expectStrictNdjson(a, cap.buf.items);
    try std.testing.expectEqual(@as(usize, 2), cap.lines);
    const text = try joinTextLines(a, cap.buf.items, "text");
    defer a.free(text);
    try std.testing.expectEqualStrings("a\u{FFFD}b判\u{FFFD}\u{FFFD}定\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}", text);
    const thinking = try joinTextLines(a, cap.buf.items, "thinking");
    defer a.free(thinking);
    try std.testing.expectEqualStrings("x\u{FFFD}\u{FFFD}\u{FFFD}y", thinking);
}

test "StreamJsonBackend: 合法 UTF-8 文本任意切分后经时间线重组逐字节相等(随机切分)" {
    const a = std.testing.allocator;
    const sid = @import("../core/session_id.zig").SessionId.single;
    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const rnd = prng.random();
    // 1/2/3/4 字节字符 + 需要转义的 ASCII 混排。
    const alphabet = [_][]const u8{ "a", "Z", " ", "\n", "\"", "\\", "\t", "é", "\u{7FF}", "\u{800}", "中", "判", "定", "\u{FFFD}", "🎉", "😀", "\u{10FFFF}" };
    var round: usize = 0;
    while (round < 64) : (round += 1) {
        var cap = CaptureSink{ .allocator = a };
        defer cap.buf.deinit(a);
        var sjb = StreamJsonBackend.init(a, cap.sink());
        const be = sjb.backend();
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        const n = rnd.intRangeAtMost(usize, 1, 40);
        var i: usize = 0;
        while (i < n) : (i += 1) try text.appendSlice(a, alphabet[rnd.uintLessThan(usize, alphabet.len)]);
        // 随机切片(含 1 字节片),模拟 provider 按字节切增量。
        var pos: usize = 0;
        while (pos < text.items.len) {
            const len = @min(rnd.intRangeAtMost(usize, 1, 5), text.items.len - pos);
            be.emitEvent(sid, .{ .text_chunk = text.items[pos .. pos + len] });
            pos += len;
        }
        sjb.flush(); // 完整合法文本:结尾不可能悬挂 → 不产生额外行
        try expectStrictNdjson(a, cap.buf.items);
        const joined = try joinTextLines(a, cap.buf.items, "text");
        defer a.free(joined);
        try std.testing.expectEqualStrings(text.items, joined);
    }
}

test "StreamJsonBackend: 随机字节流(含非法 UTF-8)任意切分后每一行仍合法 UTF-8 + 严格可解码" {
    const a = std.testing.allocator;
    const sid = @import("../core/session_id.zig").SessionId.single;
    var prng = std.Random.DefaultPrng.init(0xbadb17e5);
    const rnd = prng.random();
    var round: usize = 0;
    while (round < 64) : (round += 1) {
        var cap = CaptureSink{ .allocator = a };
        defer cap.buf.deinit(a);
        var sjb = StreamJsonBackend.init(a, cap.sink());
        const be = sjb.backend();
        var bytes: [48]u8 = undefined;
        rnd.bytes(&bytes);
        const total = rnd.intRangeAtMost(usize, 1, bytes.len);
        var pos: usize = 0;
        while (pos < total) {
            const len = @min(rnd.intRangeAtMost(usize, 1, 6), total - pos);
            const piece = bytes[pos .. pos + len];
            switch (rnd.uintLessThan(u8, 4)) {
                0 => be.emitEvent(sid, .{ .thinking_chunk = piece }),
                1 => be.emitEvent(sid, .{ .tool_result = .{ .id = piece, .name = "Bash", .input = "", .content = piece, .is_error = false } }),
                else => be.emitEvent(sid, .{ .text_chunk = piece }),
            }
            pos += len;
        }
        be.emitEvent(sid, .{ .diag_run_end = .{ .trace_id = [_]u8{'r'} ** 12, .depth = 0, .turns = 1, .tool_calls = 0, .stop_reason_name = "end_turn" } });
        try expectStrictNdjson(a, cap.buf.items);
    }
}

test "incompleteUtf8Tail: 只悬挂合法但不完整的序列前缀" {
    const Case = struct { s: []const u8, len: u8 };
    const cases = [_]Case{
        .{ .s = "", .len = 0 },
        .{ .s = "abc", .len = 0 },
        .{ .s = "判", .len = 0 },
        .{ .s = "\xe5", .len = 1 },
        .{ .s = "abc\xe5\x88", .len = 2 },
        .{ .s = "\xc3", .len = 1 },
        .{ .s = "\xf0", .len = 1 },
        .{ .s = "\xf0\x9f", .len = 2 },
        .{ .s = "\xf0\x9f\x8e", .len = 3 },
        .{ .s = "\xf0\x9f\x8e\x89", .len = 0 }, // 完整
        .{ .s = "\xe5\x88\xa4\xe5", .len = 1 },
        .{ .s = "\x93", .len = 0 }, // 孤立 continuation:不是前缀
        .{ .s = "\x93\x8c\x8b\x9e", .len = 0 },
        .{ .s = "\xe5\x88\x88\x88", .len = 0 }, // 3 个 continuation:不可能还缺
        .{ .s = "\xe0\x80", .len = 0 }, // overlong 前缀
        .{ .s = "\xed\xa0", .len = 0 }, // 代理区前缀
        .{ .s = "\xf4\x90", .len = 0 }, // > U+10FFFF
        .{ .s = "\xf5", .len = 0 },
        .{ .s = "\xc0", .len = 0 },
        .{ .s = "\xc1", .len = 0 },
        .{ .s = "\xff", .len = 0 },
        .{ .s = "\xe0\xa0", .len = 2 },
        .{ .s = "\xed\x9f", .len = 2 },
        .{ .s = "\xf0\x90", .len = 2 },
        .{ .s = "\xf4\x8f", .len = 2 },
        .{ .s = "\xf4\x8f\xbf", .len = 3 },
    };
    for (cases) |c| {
        const tail = incompleteUtf8Tail(c.s);
        const got: u8 = if (tail) |t| t.len else 0;
        std.testing.expectEqual(c.len, got) catch |e| {
            std.debug.print("incompleteUtf8Tail({x}) = {d}, want {d}\n", .{ c.s, got, c.len });
            return e;
        };
        if (tail) |t| {
            try std.testing.expect(t.len < t.need);
            try std.testing.expectEqual(
                @as(u8, try std.unicode.utf8ByteSequenceLength(c.s[c.s.len - t.len])),
                t.need,
            );
        }
    }
}
