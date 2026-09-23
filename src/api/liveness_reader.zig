//! 字节级流活性适配器:把 `RequestAbortRegistry` 的记账挂在传输层读上。
//!
//! 病根(2026-09-11 真实故障):`StreamResponse.next` 只在 `EventIterator.next` 返回一个
//! 语义事件后才 touch。而 tool_use 的参数是一串 `input_json_delta`,迭代器用 `continue`
//! 累积它们直到 `content_block_stop` 才吐事件;ping / content_block_start / unknown 同样
//! `continue`。于是一个 126 秒的合法工具调用——字节每秒都在到——被空闲监视判成 stall
//! 杀掉(`METACODES_STREAM_IDLE_TIMEOUT_MS=3000` + 每秒一帧 delta 的 mock 可稳定复现)。
//!
//! 第二个病根(2026-09-23 真实故障):修完上一条之后,"任何字节都续命"把网关每 15 秒一条的
//! `ping` 也当成了活着的证据。上游模型停止产出 55 分钟,网关一直 ping,空闲时钟一直复位,
//! 监视线程永远不会开火——用户只能自己 Ctrl+C。ping 证明的是"网关连接活着",不是
//! "模型在产出";两者必须分开记账。
//!
//! 所以本适配器有两种模式:
//! - `.bytes_are_progress`:非流式 body(auto-compact 那条路)——body 里没有保活,每个字节都是进展,
//!   直接 `touch`(续正文空闲时钟)。
//! - `.transport_only`:SSE 流——每次真搬回字节只 `touchTransport`(只更新"最近一次字节"的时间戳,
//!   供 stall 报告点名"网关 keepalive 仍在到达");**进展**由各 provider 的行解析器在拿到一条
//!   非保活行(`api/stream.zig` 的 `isKeepaliveLine`)时 `touch`。input_json_delta 帧是行,所以
//!   工具参数滴流照样续命;超长的单行在被切成行之前不续,但它至少以 KB/s 到达,远快于 10 分钟的
//!   正文下限。
//!
//! 形状仿 `std.Io.Reader.Limited`:借用内层 reader,不拥有;有自己的 buffer(与内层
//! transfer buffer 等大即可,行的快/慢路径判定不变)。`discard`/`readVec`/`rebase`
//! 用默认实现——它们都落到 `stream`,记账天然覆盖。

const std = @import("std");
const RequestAbortRegistry = @import("provider.zig").RequestAbortRegistry;

pub const Mode = enum {
    /// 每个搬回的字节都是模型产出的证据(非流式 body):`touch`。
    bytes_are_progress,
    /// 字节只证明连接活着(SSE 流,可能全是保活):`touchTransport`;进展由行解析器另行 `touch`。
    transport_only,
};

pub const LivenessReader = struct {
    inner: *std.Io.Reader,
    registry: *RequestAbortRegistry,
    /// 注册表里这条请求的键(与 registerMonitored 传的 ctx 相同)。
    ctx: *anyopaque,
    mode: Mode,
    interface: std.Io.Reader,

    /// 借用 `inner`/`registry`/`buffer`,全部不拥有;`interface` 内含 buffer 指针,
    /// 构造后 self 不可移动(与 EventIterator 借 reader 地址的契约一致)。
    pub fn init(inner: *std.Io.Reader, registry: *RequestAbortRegistry, ctx: *anyopaque, buffer: []u8, mode: Mode) LivenessReader {
        return .{
            .inner = inner,
            .registry = registry,
            .ctx = ctx,
            .mode = mode,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *LivenessReader = @fieldParentPtr("interface", r);
        const n = try self.inner.stream(w, limit);
        // 只有真搬回字节才算;0 字节的返回(允许,不代表 EOF)不记账。
        if (n > 0) switch (self.mode) {
            .bytes_are_progress => self.registry.touch(self.ctx),
            .transport_only => self.registry.touchTransport(self.ctx),
        };
        return n;
    }
};

const testing = std.testing;

const Probe = struct {
    fn shutdown(_: *anyopaque) void {}
};

test "LivenessReader(bytes_are_progress): every transport read that delivers bytes restarts the idle clock, EOF and empty reads do not" {
    const a = testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe: u8 = 0;
    // Limit 0: no monitor thread; the slot still keeps its activity stamp.
    try registry.registerMonitored(a, null, @ptrCast(&probe), Probe.shutdown, 0);
    defer registry.unregister(@ptrCast(&probe));

    var fixed: std.Io.Reader = .fixed("data: a\nbb\n");
    var buf: [4]u8 = undefined; // tiny on purpose: the first line needs several underlying reads
    var lr = LivenessReader.init(&fixed, &registry, @ptrCast(&probe), &buf, .bytes_are_progress);
    const r = &lr.interface;

    // Reset the stamp to a sentinel so a touch is observable even within one millisecond.
    // Slow path (line longer than the buffer → streamDelimiterLimit, as EventIterator.takeLine does).
    registry.slots.items[0].last_activity_ms = 0;
    var out: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&out);
    const n1 = try r.streamDelimiterLimit(&sink, '\n', .limited(64));
    try testing.expectEqual(@as(usize, 7), n1);
    try testing.expectEqualStrings("data: a", out[0..7]);
    try testing.expect(registry.slots.items[0].last_activity_ms > 0);
    r.toss(1);

    // Fast path (short line borrowed from the adaptor's own buffer via takeDelimiter).
    registry.slots.items[0].last_activity_ms = 0;
    const line2 = (try r.takeDelimiter('\n')).?;
    try testing.expectEqualStrings("bb", line2);
    try testing.expect(registry.slots.items[0].last_activity_ms > 0);

    // Exhausted: no bytes, no touch.
    registry.slots.items[0].last_activity_ms = 0;
    try testing.expect((try r.takeDelimiter('\n')) == null);
    try testing.expectEqual(@as(u64, 0), registry.slots.items[0].last_activity_ms);
}

test "LivenessReader(transport_only): bytes move the transport stamp only; the idle clock waits for a progress touch" {
    const a = testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe: u8 = 0;
    try registry.registerMonitored(a, null, @ptrCast(&probe), Probe.shutdown, 0);
    defer registry.unregister(@ptrCast(&probe));

    var fixed: std.Io.Reader = .fixed("event: ping\ndata: {\"type\":\"ping\"}\n");
    var buf: [64]u8 = undefined; // takeDelimiter 快路径要求整行放得进 buffer
    var lr = LivenessReader.init(&fixed, &registry, @ptrCast(&probe), &buf, .transport_only);
    const r = &lr.interface;
    registry.slots.items[0].last_activity_ms = 0;
    registry.slots.items[0].last_transport_ms = 0;
    try testing.expectEqualStrings("event: ping", (try r.takeDelimiter('\n')).?);
    try testing.expect(registry.slots.items[0].last_transport_ms > 0);
    try testing.expectEqual(@as(u64, 0), registry.slots.items[0].last_activity_ms);
    // The parser decides what is progress; a keepalive line never is (see stream.zig).
    try testing.expect(@import("stream.zig").isKeepaliveLine("event: ping"));
    try testing.expect(@import("stream.zig").isKeepaliveLine((try r.takeDelimiter('\n')).?));
    try testing.expectEqual(@as(u64, 0), registry.slots.items[0].last_activity_ms);
}

test "LivenessReader: an unregistered ctx is a harmless no-op touch" {
    const a = testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe: u8 = 0;
    var fixed: std.Io.Reader = .fixed("x\n");
    var buf: [8]u8 = undefined;
    var lr = LivenessReader.init(&fixed, &registry, @ptrCast(&probe), &buf, .transport_only);
    try testing.expectEqualStrings("x", (try lr.interface.takeDelimiter('\n')).?);
}
