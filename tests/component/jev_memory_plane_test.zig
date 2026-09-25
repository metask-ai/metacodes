//! L2 component test: the System-One (Jev) memory plane against a real TinyKG
//! store and a mock judge.
//!
//! Declaration = wiring = evidence for every consumer of `src/jev/advisor.zig`:
//! - scoped recall: shadow leaves the injected bytes and the v1 receipt exactly
//!   as without an advisor while recording the judgment; advisory reranks the
//!   pool by the judge, keeps the most probable candidate when none clears the
//!   judge floor, and never consults the judge below the BM25 floor; a judge
//!   that is down falls back to the BM25 floor byte for byte;
//! - KgRemember: advisory surfaces a contradiction the prefix test cannot see,
//!   shadow journals the same judgment with an unchanged result, and the
//!   memory is written either way;
//! - enumeration intent: in advisory mode a positive judgment arms only the
//!   coverage reminder (never the rejecting repair); in shadow mode the request
//!   bytes are untouched and the judgment is journaled.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const tinykg_binary = @import("tinykg_binary.zig");

const KgClient = cc.kg_client.KgClient;
const Event = cc.tools.tool_observation.Event;

fn makeKg(a: std.mem.Allocator, bin: []const u8, store: []const u8, domain: []const u8) !KgClient {
    return KgClient.init(a, .{
        .home = "/tmp",
        .domain = domain,
        .config_bin = bin,
        .config_store = store,
        .env_bin = "",
        .env_store = "",
    });
}

/// A judge answer body in the service's own shape, one boolean per name.
fn answersBody(a: std.mem.Allocator, answers: []const struct { []const u8, f64 }) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\"answers\":{");
    for (answers, 0..) |answer, index| {
        if (index > 0) try out.append(a, ',');
        try out.print(a, "\"{s}\":{{\"probabilities\":{{\"false\":{d},\"true\":{d}}},\"type\":\"boolean\"}}", .{ answer[0], 1.0 - answer[1], answer[1] });
    }
    try out.appendSlice(a, "},\"model\":\"metask-jev-4b\",\"usage\":{\"provider\":\"self-hosted\",\"tariff\":\"none\"}}");
    return out.toOwnedSlice(a);
}

fn startRuntime(a: std.mem.Allocator, io: std.Io, srv: *const harness.MockServer, mode: cc.jev_advisor.Mode) !*cc.jev_runtime.Runtime {
    var origin_buf: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}", .{srv.port});
    return cc.jev_runtime.Runtime.create(a, io, .{ .origin = origin, .mode = mode }, "");
}

fn expectSameInjection(expected: cc.kg_scoped_recall.BuildResult, actual: cc.kg_scoped_recall.BuildResult) !void {
    if (expected.text) |text| {
        try std.testing.expectEqualStrings(text, actual.text orelse return error.MissingInjection);
    } else try std.testing.expect(actual.text == null);
    try std.testing.expectEqualStrings(expected.receipt.status, actual.receipt.status);
    try std.testing.expectEqualSlices(u8, &expected.receipt.query_sha256, &actual.receipt.query_sha256);
    try std.testing.expectEqual(expected.receipt.result_count, actual.receipt.result_count);
    try std.testing.expectEqual(expected.receipt.injected_count, actual.receipt.injected_count);
    try std.testing.expectEqual(expected.receipt.injected_bytes, actual.receipt.injected_bytes);
    try std.testing.expectEqualSlices(u8, &expected.receipt.injection_sha256, &actual.receipt.injection_sha256);
}

fn containsNode(text: []const u8, node_id: u64) bool {
    var buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "node_id={d} ", .{node_id}) catch return false;
    return std.mem.indexOf(u8, text, needle) != null;
}

const DecisionSink = struct {
    count: usize = 0,
    decision: cc.tools.tool_observation.SystemOneDecision = .recall_relevance,
    mode: cc.tools.tool_observation.SystemOneMode = .shadow,
    outcome: cc.tools.tool_observation.SystemOneOutcome = .answered,
    actuated: bool = false,
    judged: u32 = 0,
    positive: u32 = 0,
    changed: u32 = 0,

    fn emit(raw: *anyopaque, event: Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .system_one_decision => |record| {
                self.count += 1;
                self.decision = record.decision;
                self.mode = record.mode;
                self.outcome = record.outcome;
                self.actuated = record.actuated;
                self.judged = record.judged;
                self.positive = record.positive;
                self.changed = record.changed;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

test "L2 jev memory plane: scoped recall shadow keeps baseline bytes, advisory follows the judge" {
    const a = std.testing.allocator;
    const bin = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    _ = harness.normalizeSlashes(pbuf[0..dir_len]);
    const store = try std.fmt.allocPrint(a, "{s}/jev-recall.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeKg(a, bin, store, "proj-jev-recall");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    _ = try kg.remember(.observation, "zorblax parser rejects tab characters in indentation", "module", false);
    _ = try kg.remember(.observation, "zorblax parser converts tab characters in indentation to four spaces unless strict mode is on", "decision", false);
    _ = try kg.remember(.observation, "zorblax cache eviction uses LRU with 64 entries", "module", false);

    const query = "How does the zorblax parser treat tab characters in indentation?";
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, query);
    var ab = cc.abort.AbortSignal.init();

    // The rank order the judge sees: the same deterministic BM25 as the builder.
    const ranked = try kg.recall(query, cc.jev_advisor.MAX_RECALL_CANDIDATES, false);
    defer {
        for (ranked) |*hit| hit.deinit(kg.allocator);
        kg.allocator.free(ranked);
    }
    try std.testing.expectEqual(@as(usize, 3), ranked.len);
    // Fixture precondition: two parser memories inside the BM25 band (score
    // at least half the top), the cache memory outside it.
    try std.testing.expect(ranked[1].score >= ranked[0].score * 0.5);
    try std.testing.expect(ranked[2].score < ranked[0].score * 0.5);

    var baseline = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{});
    defer baseline.deinit(a);
    try std.testing.expect(baseline.system_one == null);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    // The judge finds only the second-ranked memory relevant.
    const second_only = try answersBody(a, &.{ .{ "c0", 0.05 }, .{ "c1", 0.97 }, .{ "c2", 0.02 } });
    defer a.free(second_only);

    // Shadow: the judge is asked and recorded, the injection is the baseline's.
    {
        var srv = try harness.MockServer.start(second_only, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .shadow);
        defer runtime.destroy(a);
        var shadow = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{ .advisor = &runtime.advisor });
        defer shadow.deinit(a);
        try expectSameInjection(baseline, shadow);
        const record = shadow.system_one orelse return error.MissingSystemOneRecord;
        try std.testing.expectEqual(cc.jev_advisor.Outcome.answered, record.audit.outcome);
        try std.testing.expectEqualStrings("metask-jev-4b", record.audit.model());
        try std.testing.expectEqual(@as(u32, 3), record.judged);
        try std.testing.expectEqual(@as(u32, 1), record.positive);
        try std.testing.expect(!record.actuated);
        try std.testing.expectEqualSlices(u8, &.{1}, record.judged_selection.slice());
        try std.testing.expectEqual(ranked[1].node_id, record.node_ids[1]);
        try std.testing.expectEqual(@as(u8, 97), record.percents[1]);
        // The judge saw the request and every candidate under its catalog.
        const sent = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, sent, "request: How does the zorblax parser") != null);
        try std.testing.expect(std.mem.indexOf(u8, sent, "candidates[2] (") != null);
        try std.testing.expect(std.mem.indexOf(u8, sent, "\"c2\":{\"type\":\"boolean\"") != null);
    }

    // Advisory: the injection follows the judge.
    {
        var srv = try harness.MockServer.start(second_only, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        var advisory = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{ .advisor = &runtime.advisor });
        defer advisory.deinit(a);
        const text = advisory.text orelse return error.MissingInjection;
        try std.testing.expect(containsNode(text, ranked[1].node_id));
        try std.testing.expect(!containsNode(text, ranked[0].node_id));
        try std.testing.expect(!containsNode(text, ranked[2].node_id));
        try std.testing.expectEqualStrings("injected", advisory.receipt.status);
        try std.testing.expectEqual(@as(usize, 1), advisory.receipt.injected_count);
        const record = advisory.system_one orelse return error.MissingSystemOneRecord;
        try std.testing.expectEqual(cc.kg_scoped_recall.selectionDelta(record.baseline, record.judged_selection), record.changed);
        try std.testing.expectEqual(record.changed > 0, record.actuated);
    }

    // Advisory, nothing clears the judge floor: BM25 already admitted the
    // pool, so the single best candidate by judge and BM25 together (here the
    // BM25 top hit) is injected.
    {
        const weak = try answersBody(a, &.{ .{ "c0", 0.30 }, .{ "c1", 0.05 }, .{ "c2", 0.05 } });
        defer a.free(weak);
        var srv = try harness.MockServer.start(weak, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        var advisory = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{ .advisor = &runtime.advisor });
        defer advisory.deinit(a);
        const text = advisory.text orelse return error.MissingInjection;
        try std.testing.expect(containsNode(text, ranked[0].node_id));
        try std.testing.expect(!containsNode(text, ranked[1].node_id));
        try std.testing.expectEqual(@as(usize, 1), advisory.receipt.injected_count);
        try std.testing.expectEqual(@as(u32, 0), advisory.system_one.?.positive);
    }

    // The judge's favourite outside the BM25 band is never injected (the
    // paid procedural pilot's failure: a sibling's diff at 1/9 of the top
    // score displaced the protocol memory); the band's best stands in.
    {
        const out_of_band = try answersBody(a, &.{ .{ "c0", 0.10 }, .{ "c1", 0.10 }, .{ "c2", 0.99 } });
        defer a.free(out_of_band);
        var srv = try harness.MockServer.start(out_of_band, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        var advisory = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{ .advisor = &runtime.advisor });
        defer advisory.deinit(a);
        const text = advisory.text orelse return error.MissingInjection;
        try std.testing.expect(!containsNode(text, ranked[2].node_id));
        try std.testing.expect(containsNode(text, ranked[0].node_id));
        try std.testing.expectEqual(@as(usize, 1), advisory.receipt.injected_count);
        try std.testing.expectEqual(@as(u32, 1), advisory.system_one.?.positive);
    }

    // Below the BM25 floor the answer is absent for both policies: the judge
    // is never asked, and nothing is injected or recorded.
    {
        var weak_conv = cc.conversation.Conversation.init(a);
        defer weak_conv.deinit();
        // "zorblax" is in every memory, so it carries almost no BM25 weight.
        try weak_conv.appendText(.user, "Is the zorblax project still active this year?");
        var weak_baseline = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &weak_conv, &ab, .{});
        defer weak_baseline.deinit(a);
        try std.testing.expectEqualStrings("below_floor", weak_baseline.receipt.status);

        var srv = try harness.MockServer.start(second_only, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        var advisory = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &weak_conv, &ab, .{ .advisor = &runtime.advisor });
        defer advisory.deinit(a);
        try expectSameInjection(weak_baseline, advisory);
        try std.testing.expect(advisory.system_one == null);
        try std.testing.expectEqual(@as(usize, 0), srv.requestCount());
    }

    // An advisor narrowed away from scoped recall leaves it byte for byte.
    {
        var srv = try harness.MockServer.start(second_only, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        runtime.advisor.surfaces = .initOne(.recall_evidence);
        var narrowed = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{ .advisor = &runtime.advisor });
        defer narrowed.deinit(a);
        try expectSameInjection(baseline, narrowed);
        try std.testing.expect(narrowed.system_one == null);
        try std.testing.expectEqual(@as(usize, 0), srv.requestCount());
    }

    // A judge that is down leaves the baseline intact, in any mode.
    {
        var srv = try harness.MockServer.startWithStatus("{\"error\":\"down\"}", 0, "HTTP/1.1 503 Service Unavailable");
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        var degraded = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{ .advisor = &runtime.advisor });
        defer degraded.deinit(a);
        try expectSameInjection(baseline, degraded);
        const record = degraded.system_one orelse return error.MissingSystemOneRecord;
        try std.testing.expectEqual(cc.jev_advisor.Outcome.unavailable, record.audit.outcome);
        try std.testing.expect(!record.actuated);
        try std.testing.expectEqual(@as(u32, 0), record.judged);
    }
}

test "L2 jev memory plane: the recall judge reads the query-focused window of a long memory" {
    const a = std.testing.allocator;
    const bin = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    _ = harness.normalizeSlashes(pbuf[0..dir_len]);
    const store = try std.fmt.allocPrint(a, "{s}/jev-window.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeKg(a, bin, store, "proj-jev-window");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    // The decision sits in the middle of a long note: neither the head nor
    // the tail of the recall excerpt reaches it.
    const decision = "Decision: the frobnicator retry limit is seven attempts.";
    const note = "Weekly sync notes. " ++ "Discussed unrelated budget items again. " ** 30 ++
        decision ++ " Closing remarks on unrelated staffing topics. " ** 30;
    _ = try kg.remember(.observation, note, "decision", false);
    _ = try kg.remember(.observation, "frobnicator dashboards moved to the new cluster", "module", false);

    const query = "What is the retry limit of the frobnicator?";
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, query);
    var ab = cc.abort.AbortSignal.init();

    const ranked = try kg.recall(query, cc.jev_advisor.MAX_RECALL_CANDIDATES, false);
    defer {
        for (ranked) |*hit| hit.deinit(kg.allocator);
        kg.allocator.free(ranked);
    }
    var long_hit: ?*const cc.kg_client.RecallHit = null;
    for (ranked) |*hit| {
        if (std.mem.startsWith(u8, hit.text, "Weekly sync notes.")) long_hit = hit;
    }
    const hit = long_hit orelse return error.MissingLongMemory;
    try std.testing.expect(std.mem.indexOf(u8, hit.text, decision) == null);
    try std.testing.expect(std.mem.indexOf(u8, hit.focus_text, decision) != null);
    try std.testing.expect(hit.focus_text.len <= cc.jev_excerpt.JUDGE_WINDOW_BYTES);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const body = try answersBody(a, &.{ .{ "c0", 0.9 }, .{ "c1", 0.1 } });
    defer a.free(body);
    var srv = try harness.MockServer.start(body, 0);
    defer srv.stop();
    const runtime = try startRuntime(a, io_runtime.io(), srv, .shadow);
    defer runtime.destroy(a);
    var shadow = try cc.kg_scoped_recall.buildWithReceipt(a, &kg, &conv, &ab, .{ .advisor = &runtime.advisor });
    defer shadow.deinit(a);
    try std.testing.expect(shadow.system_one != null);
    const sent = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, sent, decision) != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Weekly sync notes.") == null);
}

fn rememberWithJudge(
    a: std.mem.Allocator,
    bin: []const u8,
    dir: []const u8,
    name: []const u8,
    advisor: ?*cc.jev_advisor.Advisor,
    sink: *DecisionSink,
) !struct { output: []u8, existing_id: u64 } {
    const store = try std.fmt.allocPrint(a, "{s}/{s}.kg", .{ dir, name });
    defer a.free(store);
    var kg = try makeKg(a, bin, store, name);
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const existing_id = try kg.remember(.observation, "The user prefers English replies in every session.", "user_preference", false);
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .kg = &kg,
        .jev = advisor,
        .tool_observer = sink.sink(),
    };
    const output = try cc.kg_tools.executeRemember(&ctx, "{\"text\":\"The user now prefers Chinese replies in every session.\",\"kind\":\"user_preference\"}");
    errdefer a.free(output);
    // The write happened regardless of the judge.
    const hits = try kg.recall("prefers Chinese replies", 3, false);
    defer {
        for (hits) |*hit| hit.deinit(kg.allocator);
        kg.allocator.free(hits);
    }
    var stored = false;
    for (hits) |hit| {
        if (std.mem.indexOf(u8, hit.text, "Chinese replies") != null) stored = true;
    }
    try std.testing.expect(stored);
    return .{ .output = output, .existing_id = existing_id };
}

test "L2 jev memory plane: KgRemember advisory surfaces a contradiction, shadow only journals it" {
    const a = std.testing.allocator;
    const bin = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    _ = harness.normalizeSlashes(pbuf[0..dir_len]);
    const dir = pbuf[0..dir_len];

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const contradiction = try answersBody(a, &.{ .{ "same0", 0.10 }, .{ "contradicts0", 0.93 } });
    defer a.free(contradiction);

    // Without an advisor: the prefix test sees no duplicate and says nothing.
    {
        var sink: DecisionSink = .{};
        const result = try rememberWithJudge(a, bin, dir, "jev-remember-off", null, &sink);
        defer a.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "\"relations\"") == null);
        try std.testing.expectEqual(@as(usize, 0), sink.count);
    }
    // Shadow: same result shape, the judgment is journaled.
    {
        var srv = try harness.MockServer.start(contradiction, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .shadow);
        defer runtime.destroy(a);
        var sink: DecisionSink = .{};
        const result = try rememberWithJudge(a, bin, dir, "jev-remember-shadow", &runtime.advisor, &sink);
        defer a.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "\"relations\"") == null);
        try std.testing.expectEqual(@as(usize, 1), sink.count);
        try std.testing.expectEqual(cc.tools.tool_observation.SystemOneDecision.memory_relation, sink.decision);
        try std.testing.expectEqual(cc.tools.tool_observation.SystemOneMode.shadow, sink.mode);
        try std.testing.expect(!sink.actuated);
        try std.testing.expectEqual(@as(u32, 2), sink.judged);
        try std.testing.expectEqual(@as(u32, 1), sink.positive);
        try std.testing.expectEqual(@as(u32, 1), sink.changed);
        const sent = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, sent, "new_memory: The user now prefers Chinese replies") != null);
        try std.testing.expect(std.mem.indexOf(u8, sent, "existing[0]: ") != null);
    }
    // Advisory: the contradiction reaches the model with the conflicting node.
    {
        var srv = try harness.MockServer.start(contradiction, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        var sink: DecisionSink = .{};
        const result = try rememberWithJudge(a, bin, dir, "jev-remember-advisory", &runtime.advisor, &sink);
        defer a.free(result.output);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
        defer parsed.deinit();
        const relations = parsed.value.object.get("relations") orelse return error.MissingRelations;
        try std.testing.expectEqualStrings("system_one", relations.object.get("judge").?.string);
        const contradicts = relations.object.get("contradicts").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), contradicts.len);
        try std.testing.expectEqual(@as(i64, @intCast(result.existing_id)), contradicts[0].object.get("node_id").?.integer);
        try std.testing.expectEqual(@as(i64, 93), contradicts[0].object.get("percent").?.integer);
        try std.testing.expectEqual(@as(usize, 0), relations.object.get("same_fact").?.array.items.len);
        try std.testing.expect(sink.actuated);
        try std.testing.expectEqual(cc.tools.tool_observation.SystemOneMode.advisory, sink.mode);
    }
}

const ENUMERATION_SEED_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"seed\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"seed1\",\"name\":\"KgRecall\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"graduation ceremony\\\",\\\"lexical_plan\\\":{\\\"schema_version\\\":\\\"lexical-query-plan-v3\\\",\\\"intent\\\":\\\"fact_lookup\\\",\\\"stage\\\":\\\"seed\\\",\\\"variants\\\":[{\\\"kind\\\":\\\"exact\\\",\\\"text\\\":\\\"graduation ceremony\\\"}]}}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ENUMERATION_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Two\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn runEnumerationTurn(
    a: std.mem.Allocator,
    bin: []const u8,
    dir: []const u8,
    name: []const u8,
    mode: cc.jev_advisor.Mode,
    sink: *DecisionSink,
) !struct { after_seed: []u8, stop_reason: cc.agent_loop.StopReason, turns: u32 } {
    const store = try std.fmt.allocPrint(a, "{s}/{s}.kg", .{ dir, name });
    defer a.free(store);
    var kg = try makeKg(a, bin, store, name);
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    _ = try kg.remember(.observation, "attended sister graduation ceremony in May", "observation", false);
    _ = try kg.remember(.observation, "attended cousin graduation ceremony in June", "observation", false);

    const responses = [_][]const u8{ ENUMERATION_SEED_SSE, ENUMERATION_FINAL_SSE };
    var provider_srv = try harness.MockServer.startCassette(&responses, 0);
    defer provider_srv.stop();
    const url = try provider_srv.urlOwned(a);
    defer a.free(url);

    // The seed KgRecall is judged first (evidence over its two hits), then the
    // tool-result boundary asks the enumeration question.
    const evidence_body = try answersBody(a, &.{ .{ "c0", 0.90 }, .{ "c1", 0.88 }, .{ "sufficient", 0.30 } });
    defer a.free(evidence_body);
    const judge_body = try answersBody(a, &.{.{ "needs_enumeration", 0.93 }});
    defer a.free(judge_body);
    var judge_srv = try harness.MockServer.startCassette(&.{ evidence_body, judge_body }, 0);
    defer judge_srv.stop();

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const runtime = try startRuntime(a, io_runtime.io(), judge_srv, mode);
    defer runtime.destroy(a);
    var api_client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer api_client.deinit();

    const enabled = [_][]const u8{ "KgRecall", "KgContext" };
    var defs_arena = std.heap.ArenaAllocator.init(a);
    defer defs_arena.deinit();
    var prompt_context = cc.tools.PromptContext{ .enabled_tool_names = &enabled };
    const defs = try cc.tools.toToolDefinitionsFull(defs_arena.allocator(), null, &prompt_context);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    // No counting phrase: only the judge can recognise the enumeration.
    try conv.appendText(.user, "Which graduation ceremonies did I attend this year?");
    const permission = cc.permission.createContext(.bypass_permissions, a);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const run_result = try cc.agent_loop.run(&conv, api_client.provider(), defs, &permission, .{
        .max_turns = 4,
        .kg = &kg,
        .jev = &runtime.advisor,
        .tool_observer = sink.sink(),
        .project_dir = dir,
        .cwd_abs = dir,
    }, &backend, a);
    try std.testing.expectEqual(@as(usize, 2), judge_srv.requestCount());
    const after_seed = provider_srv.requestAt(1) orelse return error.NoRequestCaptured;
    return .{ .after_seed = try a.dupe(u8, after_seed.body()), .stop_reason = run_result.stop_reason, .turns = run_result.turns };
}

test "L2 jev memory plane: enumeration judge arms only the soft reminder" {
    const a = std.testing.allocator;
    const bin = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    _ = harness.normalizeSlashes(pbuf[0..dir_len]);
    const dir = pbuf[0..dir_len];

    // Advisory: the reminder reaches the next request, and the premature final
    // answer is still accepted (the rejecting repair stays deterministic).
    {
        var sink: DecisionSink = .{};
        const result = try runEnumerationTurn(a, bin, dir, "jev-enum-advisory", .advisory, &sink);
        defer a.free(result.after_seed);
        try std.testing.expect(std.mem.indexOf(u8, result.after_seed, "lexical-coverage-obligation") != null);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        try std.testing.expectEqual(@as(u32, 2), result.turns);
        try std.testing.expectEqual(@as(usize, 2), sink.count);
        try std.testing.expectEqual(cc.tools.tool_observation.SystemOneDecision.enumeration_intent, sink.decision);
        try std.testing.expect(sink.actuated);
        try std.testing.expectEqual(@as(u32, 1), sink.positive);
    }
    // Shadow: identical judgment, journaled, request untouched.
    {
        var sink: DecisionSink = .{};
        const result = try runEnumerationTurn(a, bin, dir, "jev-enum-shadow", .shadow, &sink);
        defer a.free(result.after_seed);
        try std.testing.expect(std.mem.indexOf(u8, result.after_seed, "lexical-coverage-obligation") == null);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        try std.testing.expectEqual(@as(usize, 2), sink.count);
        try std.testing.expectEqual(cc.tools.tool_observation.SystemOneDecision.enumeration_intent, sink.decision);
        try std.testing.expect(!sink.actuated);
        try std.testing.expectEqual(@as(u32, 1), sink.positive);
    }
}

fn recallWithJudge(
    a: std.mem.Allocator,
    bin: []const u8,
    dir: []const u8,
    name: []const u8,
    advisor: *cc.jev_advisor.Advisor,
    sink: *DecisionSink,
) !struct { output: []u8, ids: [2]u64 } {
    const store = try std.fmt.allocPrint(a, "{s}/{s}.kg", .{ dir, name });
    defer a.free(store);
    var kg = try makeKg(a, bin, store, name);
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const first = try kg.remember(.observation, "quokka deploy uses a blue green switch behind the load balancer", "decision", false);
    const second = try kg.remember(.observation, "quokka dashboard colors follow the brand palette", "observation", false);
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .kg = &kg,
        .jev = advisor,
        .jev_request = "How does the quokka deploy switch traffic?",
        .tool_observer = sink.sink(),
    };
    const output = try cc.kg_tools.executeRecall(&ctx, "{\"query\":\"quokka deploy\"}");
    return .{ .output = output, .ids = .{ first, second } };
}

test "L2 jev memory plane: KgRecall evidence annotation is advisory-only and journaled" {
    const a = std.testing.allocator;
    const bin = tinykg_binary.find(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    _ = harness.normalizeSlashes(pbuf[0..dir_len]);
    const dir = pbuf[0..dir_len];

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const body = try answersBody(a, &.{ .{ "c0", 0.91 }, .{ "c1", 0.07 }, .{ "sufficient", 0.84 } });
    defer a.free(body);

    // Advisory: the envelope carries per-node relevance and sufficiency.
    {
        var srv = try harness.MockServer.start(body, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        var sink: DecisionSink = .{};
        const result = try recallWithJudge(a, bin, dir, "jev-recall-advisory", &runtime.advisor, &sink);
        defer a.free(result.output);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
        defer parsed.deinit();
        const block = parsed.value.object.get("system_one") orelse return error.MissingEvidenceBlock;
        try std.testing.expectEqualStrings("metacodes.jev.recall-evidence.v2", block.object.get("question_set").?.string);
        try std.testing.expectEqual(@as(i64, 84), block.object.get("sufficient").?.integer);
        const relevance = block.object.get("relevance").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), relevance.len);
        // Relevance is keyed by the node ids the hits array exposed, in rank order.
        const hits = parsed.value.object.get("hits").?.array.items;
        try std.testing.expectEqual(hits[0].object.get("node_id").?.integer, relevance[0].object.get("node_id").?.integer);
        try std.testing.expectEqual(@as(i64, 91), relevance[0].object.get("percent").?.integer);
        try std.testing.expectEqual(@as(i64, 7), relevance[1].object.get("percent").?.integer);
        try std.testing.expect(sink.actuated);
        try std.testing.expectEqual(@as(u32, 2), sink.judged);
        try std.testing.expectEqual(@as(u32, 1), sink.positive);
        // The judge saw the tool query first and the run's user request after it.
        const sent = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, sent, "request: recall query: quokka deploy\\nuser request: How does the quokka deploy") != null);
        try std.testing.expect(std.mem.indexOf(u8, sent, "\"sufficient\":{\"type\":\"boolean\"") != null);
    }
    // Shadow: same judgment journaled, envelope untouched.
    {
        var srv = try harness.MockServer.start(body, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .shadow);
        defer runtime.destroy(a);
        var sink: DecisionSink = .{};
        const result = try recallWithJudge(a, bin, dir, "jev-recall-shadow", &runtime.advisor, &sink);
        defer a.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "\"system_one\"") == null);
        try std.testing.expectEqual(@as(usize, 1), sink.count);
        try std.testing.expect(!sink.actuated);
        try std.testing.expectEqual(@as(u32, 2), sink.judged);
    }
    // METACODES_JEV_DECISIONS without recall_evidence: KgRecall behaves as if
    // no advisor were installed — no request, no journal entry, no block.
    {
        var srv = try harness.MockServer.start(body, 0);
        defer srv.stop();
        const runtime = try startRuntime(a, io_runtime.io(), srv, .advisory);
        defer runtime.destroy(a);
        runtime.advisor.surfaces = .initOne(.scoped_recall);
        var sink: DecisionSink = .{};
        const result = try recallWithJudge(a, bin, dir, "jev-recall-narrowed", &runtime.advisor, &sink);
        defer a.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "\"system_one\"") == null);
        try std.testing.expectEqual(@as(usize, 0), sink.count);
        try std.testing.expectEqual(@as(usize, 0), srv.requestCount());
    }
}
