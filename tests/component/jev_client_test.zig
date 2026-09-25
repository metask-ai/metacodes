//! L2 component test: the Jev System-One transport against a real socket.
//!
//! Proves the wiring AGENTS.md asks for at the transport boundary: the typed
//! questions reach the real request body byte for byte, every service outcome
//! maps to its documented error, and a stalled service is bounded by the
//! end-to-end deadline and then by the breaker instead of by the OS.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const jev = cc.jev_client;
const question = cc.jev_question;

const questions = [_]question.Named{
    .{ .name = "needs_enumeration", .question = .{ .boolean = .{
        .description = "Does answering this request require counting or listing several matching items?",
        .when_true = "The answer is a count or a complete list.",
        .when_false = "The answer is a single fact or an action.",
    } } },
    .{ .name = "kind", .question = .{ .choice = .{
        .description = "Which memory type fits?",
        .options = &.{
            .{ .label = "decision", .criterion = "A rule the project adopted." },
            .{ .label = "bug", .criterion = "A defect and its fix." },
        },
    } } },
};

const ANSWER_BODY =
    "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"false\":0.08,\"true\":0.92},\"type\":\"boolean\"}," ++
    "\"kind\":{\"probabilities\":{\"bug\":0.3,\"decision\":0.7},\"type\":\"enum\"}}," ++
    "\"model\":\"metask-jev-4b\",\"usage\":{\"provider\":\"self-hosted\",\"tariff\":\"none\"}}";

fn originFor(buf: []u8, srv: *const harness.MockServer) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{srv.port});
}

test "L2 jev: typed questions reach the wire and calibrated answers come back" {
    const a = std.testing.allocator;
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var srv = try harness.MockServer.start(ANSWER_BODY, 0);
    defer srv.stop();
    var origin_buf: [64]u8 = undefined;
    var client = try jev.Client.init(a, io_runtime.io(), .{ .origin = try originFor(&origin_buf, srv) });
    defer client.deinit();

    var answers = try client.ask(a, null, "User request: how many releases failed?", &questions);
    defer answers.deinit();
    try std.testing.expectEqualStrings("metask-jev-4b", answers.model);
    try std.testing.expectEqual(@as(u8, 92), question.percent(answers.probTrue(0)));
    try std.testing.expectEqual(@as(usize, 0), question.argmax(answers.distribution(1)));

    // The exact serialized request is what reached the socket.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    try question.writeRequest(&expected, a, "User request: how many releases failed?", &questions);
    const captured = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings(expected.items, captured.body());
    try std.testing.expect(std.mem.startsWith(u8, captured.raw, "POST /v1/systemone HTTP/1.1\r\n"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(captured.raw, "content-type: application/json") != null);
}

test "L2 jev: refusals, server errors and malformed answers map to distinct errors" {
    const a = std.testing.allocator;
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var origin_buf: [64]u8 = undefined;
    {
        var srv = try harness.MockServer.startWithStatus("{\"error\":\"422 over context limit\"}", 0, "HTTP/1.1 422 Unprocessable Entity");
        defer srv.stop();
        var client = try jev.Client.init(a, io_runtime.io(), .{ .origin = try originFor(&origin_buf, srv) });
        defer client.deinit();
        try std.testing.expectError(error.Rejected, client.ask(a, null, "state", &questions));
        // A refusal is about this request, not the service: the breaker stays closed.
        try std.testing.expectEqual(@as(u64, 0), client.breaker_backoff_ms);
    }
    {
        var srv = try harness.MockServer.start("{\"error\":{\"kind\":\"supported types are enum and boolean.\"}}", 0);
        defer srv.stop();
        var client = try jev.Client.init(a, io_runtime.io(), .{ .origin = try originFor(&origin_buf, srv) });
        defer client.deinit();
        try std.testing.expectError(error.Rejected, client.ask(a, null, "state", &questions));
    }
    {
        var srv = try harness.MockServer.startWithStatus("{\"error\":\"boom\"}", 0, "HTTP/1.1 500 Internal Server Error");
        defer srv.stop();
        var client = try jev.Client.init(a, io_runtime.io(), .{ .origin = try originFor(&origin_buf, srv) });
        defer client.deinit();
        try std.testing.expectError(error.Unavailable, client.ask(a, null, "state", &questions));
        try std.testing.expectEqual(jev.BREAKER_INITIAL_MS, client.breaker_backoff_ms);
    }
    {
        var srv = try harness.MockServer.start("{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"true\":0.9,\"false\":0.9}}}}", 0);
        defer srv.stop();
        var client = try jev.Client.init(a, io_runtime.io(), .{ .origin = try originFor(&origin_buf, srv) });
        defer client.deinit();
        try std.testing.expectError(error.MalformedResponse, client.ask(a, null, "state", &questions));
        try std.testing.expectEqual(jev.BREAKER_INITIAL_MS, client.breaker_backoff_ms);
    }
}

test "L2 jev: a service that does not declare itself free is refused" {
    const a = std.testing.allocator;
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var origin_buf: [64]u8 = undefined;
    const priced = [_][]const u8{
        // TypeSafe-cloud-shaped usage: tokens but no tariff declaration.
        "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"false\":0.08,\"true\":0.92}}," ++
            "\"kind\":{\"probabilities\":{\"bug\":0.3,\"decision\":0.7}}},\"model\":\"jev-1\",\"usage\":{\"input_tokens\":90,\"output_tokens\":0}}",
        "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"false\":0.08,\"true\":0.92}}," ++
            "\"kind\":{\"probabilities\":{\"bug\":0.3,\"decision\":0.7}}},\"model\":\"jev-1\",\"usage\":{\"tariff\":\"usd-per-token\"}}",
    };
    for (priced) |body| {
        var srv = try harness.MockServer.start(body, 0);
        defer srv.stop();
        var client = try jev.Client.init(a, io_runtime.io(), .{ .origin = try originFor(&origin_buf, srv) });
        defer client.deinit();
        try std.testing.expectError(error.PricedService, client.ask(a, null, "state", &questions));
        try std.testing.expectEqual(jev.BREAKER_INITIAL_MS, client.breaker_backoff_ms);
    }
}

test "L2 jev: a pinned model refuses answers from any other model" {
    const a = std.testing.allocator;
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var origin_buf: [64]u8 = undefined;
    {
        var srv = try harness.MockServer.start(ANSWER_BODY, 0);
        defer srv.stop();
        var client = try jev.Client.init(a, io_runtime.io(), .{
            .origin = try originFor(&origin_buf, srv),
            .expected_model = "metask-jev-4b-v2",
        });
        defer client.deinit();
        try std.testing.expectError(error.ModelMismatch, client.ask(a, null, "state", &questions));
    }
    {
        var srv = try harness.MockServer.start(ANSWER_BODY, 0);
        defer srv.stop();
        var client = try jev.Client.init(a, io_runtime.io(), .{
            .origin = try originFor(&origin_buf, srv),
            .expected_model = "metask-jev-4b",
        });
        defer client.deinit();
        var answers = try client.ask(a, null, "state", &questions);
        defer answers.deinit();
        try std.testing.expectEqualStrings("metask-jev-4b", answers.model);
    }
}

test "L2 jev: a stalled service costs one deadline, then the breaker fails fast" {
    const a = std.testing.allocator;
    // std.testing.io does not run Select tasks concurrently; the deadline
    // race needs a real threaded Io.
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var srv = try harness.MockServer.startCassetteSilent(&.{ANSWER_BODY}, 0, 0);
    defer srv.stop();
    var origin_buf: [64]u8 = undefined;
    var client = try jev.Client.init(a, io_runtime.io(), .{
        .origin = try originFor(&origin_buf, srv),
        .timeout_ms = 300,
    });
    defer client.deinit();

    const started = cc.util_time.nowMs();
    try std.testing.expectError(error.Unavailable, client.ask(a, null, "state", &questions));
    const waited = cc.util_time.nowMs() - started;
    try std.testing.expect(waited >= 300);
    try std.testing.expect(waited < 2_000);
    try std.testing.expectEqual(jev.BREAKER_INITIAL_MS, client.breaker_backoff_ms);

    // Breaker open: no second connection, no second deadline.
    const second_started = cc.util_time.nowMs();
    try std.testing.expectError(error.Unavailable, client.ask(a, null, "state", &questions));
    try std.testing.expect(cc.util_time.nowMs() - second_started < 100);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 jev: an abort while waiting propagates as Aborted and leaves the breaker closed" {
    const a = std.testing.allocator;
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var srv = try harness.MockServer.startCassetteSilent(&.{ANSWER_BODY}, 0, 0);
    defer srv.stop();
    var origin_buf: [64]u8 = undefined;
    var client = try jev.Client.init(a, io_runtime.io(), .{
        .origin = try originFor(&origin_buf, srv),
        .timeout_ms = 10_000,
    });
    defer client.deinit();

    var signal = cc.util_abort.AbortSignal.init();
    const Aborter = struct {
        fn run(s: *cc.util_abort.AbortSignal) void {
            cc.util_time.sleepMs(150);
            s.abort(.user_interrupt);
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&signal});
    const started = cc.util_time.nowMs();
    try std.testing.expectError(error.Aborted, client.ask(a, &signal, "state", &questions));
    thread.join();
    try std.testing.expect(cc.util_time.nowMs() - started < 2_000);
    try std.testing.expectEqual(@as(u64, 0), client.breaker_backoff_ms);
}
