const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const platform = @import("platform");

const LossyProxy = harness.LossyProxy;

const CLOSE_WAIT_MS: i64 = LossyProxy.HOLD_MS + 1_000;
const PROMPT_MS: i64 = 2_000;

const Stopwatch = struct {
    begun: std.Io.Timestamp,

    fn start() Stopwatch {
        return .{ .begun = std.Io.Timestamp.now(clock(), .awake) };
    }

    fn ms(self: Stopwatch) i64 {
        return self.begun.durationTo(std.Io.Timestamp.now(clock(), .awake)).toMilliseconds();
    }

    fn clock() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }
};

fn urlOf(buf: []u8, proxy: *const LossyProxy, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ proxy.port, path });
}

fn connectionValue(raw: []const u8) []const u8 {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "connection")) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return "(no such header)";
}

fn asksKeepAlive(raw: []const u8) bool {
    return LossyProxy.connectionHeaders(raw, null) == 1 and
        LossyProxy.connectionHeaders(raw, "keep-alive") == 1 and
        LossyProxy.connectionHeaders(raw, "close") == 0;
}

fn expectKeptOpen(site: []const u8, proxy: *LossyProxy, index: usize, outcome: anyerror!void) !void {
    const raw = proxy.requestAt(index) orelse {
        std.debug.print("{s}: no request reached the server\n", .{site});
        return error.TestExpectedRequest;
    };
    const asked = asksKeepAlive(raw);
    const failure: ?anyerror = if (outcome) |_| null else |err| err;
    const cut = proxy.cutCount() > 0;
    const closed_ms: ?i64 = if (cut or !proxy.waitForCloses(index + 1, CLOSE_WAIT_MS))
        null
    else
        proxy.closeLatencyMs(index) catch null;
    if (asked and failure == null and closed_ms != null and closed_ms.? < PROMPT_MS) return;
    std.debug.print("{s}: the request said connection: {s}\n", .{ site, connectionValue(raw) });
    if (failure) |err| {
        std.debug.print("{s}: the call failed with {s}\n", .{ site, @errorName(err) });
    } else {
        std.debug.print("{s}: the call finished\n", .{site});
    }
    if (cut) {
        std.debug.print("{s}: the server cut its answer and closed the connection\n", .{site});
    } else if (closed_ms) |ms| {
        std.debug.print("{s}: the client closed the connection {d} ms after the answer\n", .{ site, ms });
    } else {
        std.debug.print("{s}: the client did not close the connection the server held\n", .{site});
    }
    return error.TestExpectedKeptOpenConnection;
}

const JEV_QUESTIONS = [_]cc.jev_question.Named{
    .{ .name = "needs_enumeration", .question = .{ .boolean = .{
        .description = "Does answering this request require counting or listing several matching items?",
        .when_true = "The answer is a count or a complete list.",
        .when_false = "The answer is a single fact or an action.",
    } } },
};

const JEV_ANSWER =
    "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"false\":0.08,\"true\":0.92},\"type\":\"boolean\"}}," ++
    "\"model\":\"metask-jev-4b\",\"usage\":{\"provider\":\"self-hosted\",\"tariff\":\"none\"}}";

fn askAdvisor(a: std.mem.Allocator, client: *cc.jev_client.Client) !void {
    var answers = try client.ask(a, null, "User request: list the releases", &JEV_QUESTIONS);
    defer answers.deinit();
    try std.testing.expectEqual(@as(u8, 92), cc.jev_question.percent(answers.probTrue(0)));
}

test "L2 #661 System-One: the advisor request asks the server to keep the connection open, and its answer arrives whole" {
    const a = std.testing.allocator;
    var proxy = try LossyProxy.start(JEV_ANSWER, .{ .content_type = "application/json", .framing = .content_length, .cut_at = JEV_ANSWER.len / 2 });
    defer proxy.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var origin_buf: [64]u8 = undefined;
    var client = try cc.jev_client.Client.init(a, io_runtime.io(), .{ .origin = try urlOf(&origin_buf, proxy, ""), .timeout_ms = 10_000 });
    defer client.deinit();
    try expectKeptOpen("System-One", proxy, 0, askAdvisor(a, &client));
    try std.testing.expectEqual(@as(usize, 1), proxy.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, proxy.requestAt(0).?, "POST /v1/systemone HTTP/1.1\r\n"));
}

const KG_BUILD_ID = "sha256:" ++ "0" ** 64;
const KG_DIGEST = "1" ** 64;
const KG_REQUEST_ID = "request-661";
const KG_READY = "{\"ok\":true,\"ready\":true,\"degraded\":false}";
const KG_ANSWER = std.fmt.comptimePrint(
    "{{\"protocolVersion\":{d},\"controlPlaneVersion\":{d},\"implementation\":\"metacodes-kgd\"," ++
        "\"schemaMode\":\"server-canonical\",\"requestId\":\"{s}\",\"buildId\":\"{s}\"," ++
        "\"engine\":{{\"implementation\":\"tinykg-cli\",\"version\":\"1.0.0\",\"binarySha256\":\"{s}\",\"metadataValid\":true}}," ++
        "\"capabilities\":[\"{s}\"],\"schemaDigest\":\"{s}\",\"commitState\":\"none\",\"generation\":0," ++
        "\"ok\":true,\"stdout\":\"store ok\",\"stderr\":\"\"}}",
    .{
        cc.kg_transport.protocol_version,
        cc.kg_transport.control_plane_version,
        KG_REQUEST_ID,
        KG_BUILD_ID,
        KG_DIGEST,
        cc.kg_transport.task_hierarchy_capability,
        KG_DIGEST,
    },
);

fn kgTransport(a: std.mem.Allocator, io: std.Io, url: []const u8) !cc.kg_transport.WebTransport {
    return cc.kg_transport.WebTransport.init(a, .{
        .io = io,
        .url = url,
        .api_key = "key-661",
        .expected_build_id = KG_BUILD_ID,
        .timeout_ms = 10_000,
    });
}

fn probeReady(transport: *cc.kg_transport.WebTransport) !void {
    const readiness = try transport.ready();
    try std.testing.expect(readiness.ok and readiness.ready and !readiness.degraded);
}

fn runStoreInfo(a: std.mem.Allocator, transport: *cc.kg_transport.WebTransport) !void {
    const result = try transport.runWithRequestId("store-info", &.{}, false, KG_REQUEST_ID);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("store ok", result.stdout);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
}

test "L2 #661 TinyKG: the readiness probe and a command ask the server to keep the connection open, and their answers arrive whole" {
    const a = std.testing.allocator;
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;

    var ready_proxy = try LossyProxy.start(KG_READY, .{ .content_type = "application/json", .framing = .content_length, .cut_at = KG_READY.len / 2 });
    defer ready_proxy.stop();
    var ready_transport = try kgTransport(a, io_runtime.io(), try urlOf(&url_buf, ready_proxy, ""));
    defer ready_transport.deinit();
    try expectKeptOpen("TinyKG readiness probe", ready_proxy, 0, probeReady(&ready_transport));
    try std.testing.expectEqual(@as(usize, 1), ready_proxy.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, ready_proxy.requestAt(0).?, "GET /api/ready HTTP/1.1\r\n"));

    var run_proxy = try LossyProxy.start(KG_ANSWER, .{ .content_type = "application/json", .framing = .content_length, .cut_at = KG_ANSWER.len / 2 });
    defer run_proxy.stop();
    var run_transport = try kgTransport(a, io_runtime.io(), try urlOf(&url_buf, run_proxy, ""));
    defer run_transport.deinit();
    try expectKeptOpen("TinyKG command", run_proxy, 0, runStoreInfo(a, &run_transport));
    try std.testing.expectEqual(@as(usize, 1), run_proxy.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, run_proxy.requestAt(0).?, "POST /api/run HTTP/1.1\r\n"));
}

const SEALED_RESPONSE = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"skills\":[]}}";
const SEALED_STREAM =
    ": keepalive\n\n" ++
    "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n" ++
    "event: message\ndata: " ++ SEALED_RESPONSE ++ "\n\n";

fn discover(a: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    var client = try cc.skills_sealed_transport.Client.init(a, io, url, "");
    defer client.deinit();
    var response = try client.call(.discover, "{}", null);
    defer response.deinit();
    switch (response.response) {
        .result => |result| try std.testing.expect(std.mem.indexOf(u8, result, "skills") != null),
        .err => return error.TestExpectedResult,
    }
    try std.testing.expectEqual(@as(u16, 200), client.last_http_status);
}

test "L2 #661 sealed skills: a call asks the gateway to keep the connection open, and a JSON answer or a stream whose last message is the response arrives whole" {
    const a = std.testing.allocator;
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;

    var json_proxy = try LossyProxy.start(SEALED_RESPONSE, .{ .content_type = "application/json", .framing = .content_length, .cut_at = SEALED_RESPONSE.len / 2 });
    defer json_proxy.stop();
    try expectKeptOpen("sealed skills, JSON answer", json_proxy, 0, discover(a, io_runtime.io(), try urlOf(&url_buf, json_proxy, "/ssp")));
    try std.testing.expectEqual(@as(usize, 1), json_proxy.requestCount());

    var stream_proxy = try LossyProxy.start(SEALED_STREAM, .{ .content_type = "text/event-stream", .cut_at = SEALED_STREAM.len - SEALED_RESPONSE.len / 2 });
    defer stream_proxy.stop();
    try expectKeptOpen("sealed skills, event-stream answer", stream_proxy, 0, discover(a, io_runtime.io(), try urlOf(&url_buf, stream_proxy, "/ssp")));
    try std.testing.expectEqual(@as(usize, 1), stream_proxy.requestCount());
}

const OTLP_ANSWER = "{\"partialSuccess\":{}}";

fn exportOneSpan(a: std.mem.Allocator, endpoint_url: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    const endpoint = arena.allocator().dupe(u8, endpoint_url) catch |err| {
        arena.deinit();
        return err;
    };
    const exporter = try cc.telemetry.Exporter.start(a, arena, .{
        .endpoint = endpoint,
        .protocol = .http_json,
        .timeout_ms = 3_000,
        .schedule_delay_ms = 60_000,
        .resource = &.{},
    }, "0.0.0-test");
    defer exporter.shutdown();
    const span: cc.telemetry.span.Span = .{
        .trace_id = .random(),
        .span_id = .random(),
        .name = "probe-661",
        .start_unix_nano = 1,
        .end_unix_nano = 2,
    };
    exporter.enqueue(&span);
    try std.testing.expect(exporter.forceFlush(5_000));
    const stats = exporter.snapshotStats();
    try std.testing.expectEqual(@as(u64, 1), stats.exported);
    try std.testing.expectEqual(@as(u64, 0), stats.failed_batches);
}

test "L2 #661 OTLP export: a batch asks the collector to keep the connection open, and counts as exported once its answer arrives" {
    const a = std.testing.allocator;
    var proxy = try LossyProxy.start(OTLP_ANSWER, .{ .content_type = "application/json", .framing = .content_length, .cut_at = OTLP_ANSWER.len / 2 });
    defer proxy.stop();
    var url_buf: [64]u8 = undefined;
    try expectKeptOpen("OTLP export", proxy, 0, exportOneSpan(a, try urlOf(&url_buf, proxy, "/v1/traces")));
    try std.testing.expectEqual(@as(usize, 1), proxy.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, proxy.requestAt(0).?, "POST /v1/traces HTTP/1.1\r\n"));
}

const SSE_NOTICE = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}";
const SSE_STREAM =
    "event: endpoint\ndata: /messages\n\n" ++
    "event: message\ndata: " ++ SSE_NOTICE ++ "\n\n";
const SSE_CUT_AT = SSE_STREAM.len - SSE_NOTICE.len / 2;

fn openStream(a: std.mem.Allocator, io: std.Io, url: []const u8) !*cc.mcp_transport_sse.SseTransport {
    return cc.mcp_transport_sse.SseTransport.create(a, io, url, &.{}, .{ .deadline_ms = cc.util_time.nowMs() + 5_000 });
}

fn readStreamToItsEnd(a: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const transport = try openStream(a, io, url);
    defer transport.close();
    const message = try transport.recvLine();
    defer a.free(message);
    try std.testing.expectEqualStrings(SSE_NOTICE, message);
    const watch = Stopwatch.start();
    try std.testing.expectError(error.McpStreamClosed, transport.recvLine());
    try std.testing.expect(watch.ms() < PROMPT_MS);
}

test "L2 #661 MCP legacy SSE: the event stream asks the server to keep the connection open, ends at its closing chunk, and opens again on a new connection" {
    const a = std.testing.allocator;
    var proxy = try LossyProxy.start(SSE_STREAM, .{ .cut_at = SSE_CUT_AT });
    defer proxy.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try urlOf(&url_buf, proxy, "/sse");
    try expectKeptOpen("MCP legacy SSE stream", proxy, 0, readStreamToItsEnd(a, io_runtime.io(), url));
    try expectKeptOpen("MCP legacy SSE stream, opened again", proxy, 1, readStreamToItsEnd(a, io_runtime.io(), url));
    try std.testing.expectEqual(@as(usize, 2), proxy.acceptedCount());
    try std.testing.expectEqual(@as(usize, 0), proxy.reusedCount());
    try std.testing.expect(std.mem.startsWith(u8, proxy.requestAt(0).?, "GET /sse HTTP/1.1\r\n"));
}

test "L2 #661 MCP legacy SSE: a stream the server drops before its closing chunk ends at once with an error" {
    const a = std.testing.allocator;
    var proxy = try LossyProxy.start(SSE_STREAM, .{ .cut_at = SSE_CUT_AT, .cut_always = true });
    defer proxy.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    const transport = try openStream(a, io_runtime.io(), try urlOf(&url_buf, proxy, "/sse"));
    defer transport.close();
    const watch = Stopwatch.start();
    try std.testing.expectError(error.McpConnectFailed, transport.recvLine());
    try std.testing.expect(watch.ms() < PROMPT_MS);
    const raw = proxy.requestAt(0).?;
    if (!asksKeepAlive(raw)) {
        std.debug.print("MCP legacy SSE stream: the request said connection: {s}\n", .{connectionValue(raw)});
        return error.TestExpectedKeepAlive;
    }
}
