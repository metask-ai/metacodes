const std = @import("std");
const cc = @import("cc");
const platform = @import("platform");

const net = platform.net;
const AbortSignal = cc.abort.AbortSignal;
const WebTransport = cc.kg_transport.WebTransport;

const BUILD_ID = "sha256:" ++ "0" ** 64;
const DEADLINE_MS: u64 = 30_000;
const ABORT_AFTER_MS: u64 = 300;
const PROMPT_MS: i64 = 5_000;

fn clock() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn abortLater(signal: *AbortSignal) void {
    cc.util_time.sleepMs(ABORT_AFTER_MS);
    signal.abort(.user_interrupt);
}

fn silentTransport(a: std.mem.Allocator, io: std.Io, url_buf: []u8, port: u16) !WebTransport {
    return WebTransport.init(a, .{
        .io = io,
        .url = try std.fmt.bufPrint(url_buf, "http://127.0.0.1:{d}", .{port}),
        .api_key = "key-667",
        .expected_build_id = BUILD_ID,
        .timeout_ms = DEADLINE_MS,
    });
}

test "L2 #667 TinyKG: a read from a service that accepts and never answers gives way to its abort signal" {
    const a = std.testing.allocator;
    const listener = try net.listenLoopback(0, 16);
    defer net.closeSocket(listener.sock);
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    var transport = try silentTransport(a, io_runtime.io(), &url_buf, listener.port);
    defer transport.deinit();

    var signal = AbortSignal.init();
    const aborter = try platform.thread.spawn(.waiter, abortLater, .{&signal});
    defer aborter.join();
    const begun = std.Io.Timestamp.now(clock(), .awake);
    const outcome = transport.read("store-info", &.{}, &signal);
    const waited = begun.durationTo(std.Io.Timestamp.now(clock(), .awake)).toMilliseconds();
    if (outcome) |result| {
        result.deinit(a);
        return error.TestExpectedInterrupted;
    } else |err| try std.testing.expectEqual(cc.kg_transport.Error.Interrupted, err);
    if (waited >= PROMPT_MS) {
        std.debug.print("the read gave way {d} ms after its abort signal\n", .{waited - @as(i64, ABORT_AFTER_MS)});
        return error.TestExpectedPromptInterrupt;
    }
}

test "L2 #667 TinyKG: an already aborted read is never sent" {
    const a = std.testing.allocator;
    const listener = try net.listenLoopback(0, 16);
    defer net.closeSocket(listener.sock);
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    var transport = try silentTransport(a, io_runtime.io(), &url_buf, listener.port);
    defer transport.deinit();

    var signal = AbortSignal.init();
    signal.abort(.user_interrupt);
    try std.testing.expectError(cc.kg_transport.Error.Interrupted, transport.read("store-info", &.{}, &signal));
}
