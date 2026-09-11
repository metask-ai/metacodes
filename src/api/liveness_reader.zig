//! 字节级流活性适配器:把 `RequestAbortRegistry.touch` 挂在传输层读上,而不是挂在
//! "解析出一个语义事件"上。
//!
//! 病根(2026-09-11 真实故障):`StreamResponse.next` 只在 `EventIterator.next` 返回一个
//! 语义事件后才 touch。而 tool_use 的参数是一串 `input_json_delta`,迭代器用 `continue`
//! 累积它们直到 `content_block_stop` 才吐事件;ping / content_block_start / unknown 同样
//! `continue`。于是一个 126 秒的合法工具调用——字节每秒都在到——被空闲监视判成 stall
//! 杀掉(`METACODES_STREAM_IDLE_TIMEOUT_MS=3000` + 每秒一帧 delta 的 mock 可稳定复现)。
//! 三个 provider client(anthropic/openai/gemini)各自一份同样的记账。
//!
//! 修法:在 `std.Io.Reader` 层包一层——每次底层 `stream` 真的搬回了字节,就 touch 一次。
//! 字节是"对端活着"的唯一证据,和上层认不认识这些字节无关。`takeDelimiter` 快路径与
//! `streamDelimiterLimit` 慢路径都经由 `vtable.stream` 取字节,所以一个 40KB 的超长 delta 行
//! 在被切成行之前就已经在续命。
//!
//! 形状仿 `std.Io.Reader.Limited`:借用内层 reader,不拥有;有自己的 buffer(与内层
//! transfer buffer 等大即可,行的快/慢路径判定不变)。`discard`/`readVec`/`rebase`
//! 用默认实现——它们都落到 `stream`,记账天然覆盖。

const std = @import("std");
const RequestAbortRegistry = @import("provider.zig").RequestAbortRegistry;

pub const LivenessReader = struct {
    inner: *std.Io.Reader,
    registry: *RequestAbortRegistry,
    /// 注册表里这条请求的键(与 registerMonitored 传的 ctx 相同)。
    ctx: *anyopaque,
    interface: std.Io.Reader,

    /// 借用 `inner`/`registry`/`buffer`,全部不拥有;`interface` 内含 buffer 指针,
    /// 构造后 self 不可移动(与 EventIterator 借 reader 地址的契约一致)。
    pub fn init(inner: *std.Io.Reader, registry: *RequestAbortRegistry, ctx: *anyopaque, buffer: []u8) LivenessReader {
        return .{
            .inner = inner,
            .registry = registry,
            .ctx = ctx,
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
        // 只有真搬回字节才算活着;0 字节的返回(允许,不代表 EOF)不续命。
        if (n > 0) self.registry.touch(self.ctx);
        return n;
    }
};

const testing = std.testing;

const Probe = struct {
    fn shutdown(_: *anyopaque) void {}
};

test "LivenessReader: every transport read that delivers bytes restarts the idle clock, EOF and empty reads do not" {
    const a = testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe: u8 = 0;
    // Limit 0: no monitor thread; the slot still keeps its activity stamp.
    try registry.registerMonitored(a, null, @ptrCast(&probe), Probe.shutdown, 0);
    defer registry.unregister(@ptrCast(&probe));

    var fixed: std.Io.Reader = .fixed("data: a\nbb\n");
    var buf: [4]u8 = undefined; // tiny on purpose: the first line needs several underlying reads
    var lr = LivenessReader.init(&fixed, &registry, @ptrCast(&probe), &buf);
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

test "LivenessReader: an unregistered ctx is a harmless no-op touch" {
    const a = testing.allocator;
    var registry = RequestAbortRegistry{};
    defer registry.deinit(a);
    var probe: u8 = 0;
    var fixed: std.Io.Reader = .fixed("x\n");
    var buf: [8]u8 = undefined;
    var lr = LivenessReader.init(&fixed, &registry, @ptrCast(&probe), &buf);
    try testing.expectEqualStrings("x", (try lr.interface.takeDelimiter('\n')).?);
}
