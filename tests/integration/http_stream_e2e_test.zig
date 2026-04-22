const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const MockServer = harness.MockServer;

test "MockServer + std.http.Client + EventIterator: text_delta event" {
    const a = std.testing.allocator;

    const sse_body =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hello\"}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var srv = try MockServer.start(sse_body, 0);
    defer srv.stop();

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = std.http.Client{ .allocator = a, .io = io };
    defer client.deinit();

    const url = try srv.urlOwned(a);
    defer a.free(url);
    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{});
    try req.sendBodyComplete(@constCast("{}"));

    var redirect_buf: [4096]u8 = undefined;
    var http_resp = try req.receiveHead(&redirect_buf);
    defer req.deinit();

    try std.testing.expect(http_resp.head.status == .ok);

    var transfer_buf: [8192]u8 = undefined;
    const reader = http_resp.reader(&transfer_buf);

    var it = cc.api_stream.EventIterator.init(reader);

    const e1 = (try it.next(a)).?;
    defer e1.deinit(a);
    try std.testing.expect(@as(std.meta.Tag(cc.api_stream.Event), e1) == .text_delta);
    try std.testing.expectEqualStrings("hello", e1.text_delta);

    const e2 = (try it.next(a)).?;
    defer e2.deinit(a);
    try std.testing.expect(@as(std.meta.Tag(cc.api_stream.Event), e2) == .done);
}

test "MockServer + EventIterator: abort cuts stream" {
    const a = std.testing.allocator;

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(a);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try body_buf.appendSlice(a, "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"x\"}}\n\n");
    }

    var srv = try MockServer.start(body_buf.items, 100);
    defer srv.stop();

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();

    var client = std.http.Client{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();

    const url = try srv.urlOwned(a);
    defer a.free(url);
    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{});
    try req.sendBodyComplete(@constCast("{}"));

    var redirect_buf: [4096]u8 = undefined;
    var http_resp = try req.receiveHead(&redirect_buf);
    defer req.deinit();

    var transfer_buf: [8192]u8 = undefined;
    const reader = http_resp.reader(&transfer_buf);

    var sig = cc.util_abort.AbortSignal.init();
    var it = cc.api_stream.EventIterator.initWithAbort(reader, &sig);

    const e1 = (try it.next(a)).?;
    defer e1.deinit(a);
    try std.testing.expect(std.mem.eql(u8, e1.text_delta, "x"));

    sig.abort(.user_ctrl_c);
    try std.testing.expectError(error.Aborted, it.next(a));
}
