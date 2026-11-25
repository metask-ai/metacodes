//! L2: the end-of-run learning turn (doc/LEARNING_TURN_DESIGN.md §2.1, step 5)
//! and the CLI wiring of both forms (step 6). After the headless host check,
//! one bounded no-tools provider request turns the verdict into lessons the
//! host writes through `KgClient.remember` under the bound header; observe
//! mode, a tainted verdict and broken caps spend nothing or store nothing.
//! The flags and METACODES_LEARNING_TURN change the real run options; a
//! learning turn with no verdict source is refused. Real TinyKG where a lesson
//! is written; a mock provider for the request.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const tinykg_binary = @import("tinykg_binary");

const learning = cc.learning_turn;
const end_of_run = cc.learning_end_of_run;
const lesson = cc.kg_lesson;
const KgClient = cc.kg_client.KgClient;

const TASK = "etag";
const RUN = "0123456789abcdef01234567";
const HEADER_FAILED = "lesson-v1 verdict=failed task=" ++ TASK ++ " run=" ++ RUN;

fn textSse(allocator: std.mem.Allocator, text: []const u8, input_tokens: u64) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(text, .{}, &escaped.writer);
    const encoded = try escaped.toOwnedSlice();
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":{d},\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":40}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ input_tokens, encoded },
    );
}

const Kg = struct {
    client: KgClient,
    store: []u8,
    bin: []u8,

    fn open(allocator: std.mem.Allocator, root: []const u8) !?Kg {
        const bin = tinykg_binary.find(allocator) orelse return null;
        errdefer allocator.free(bin);
        const store = try std.fmt.allocPrint(allocator, "{s}/learning-eor.kg", .{root});
        errdefer allocator.free(store);
        var client = try KgClient.init(allocator, .{
            .state_root = root,
            .domain = "proj-learning-end-of-run",
            .config_bin = bin,
            .config_store = store,
            .env_bin = "",
            .env_store = "",
        });
        client.ensureReady();
        if (!client.ready) {
            client.deinit();
            allocator.free(store);
            allocator.free(bin);
            return null;
        }
        return .{ .client = client, .store = store, .bin = bin };
    }

    fn close(self: *Kg, allocator: std.mem.Allocator) void {
        self.client.deinit();
        allocator.free(self.store);
        allocator.free(self.bin);
    }
};

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

const Served = struct {
    outcome: end_of_run.Outcome,
    requests: usize,
    body: ?[]u8 = null,

    fn deinit(self: *Served, allocator: std.mem.Allocator) void {
        if (self.body) |bytes| allocator.free(bytes);
    }
};

/// One end-of-run learning turn against a mock provider that answers
/// `responses` in order.
fn serve(
    allocator: std.mem.Allocator,
    kg: *KgClient,
    responses: []const []const u8,
    input: end_of_run.Input,
    max_tokens: u32,
) !Served {
    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    client.max_tokens_override = max_tokens;
    const outcome = end_of_run.run(allocator, .{ .kg = kg, .provider = client.provider(), .session = "sess-1" }, input);
    var served = Served{ .outcome = outcome, .requests = server.requestCount() };
    if (server.requestAt(0)) |request| served.body = try allocator.dupe(u8, request.body());
    return served;
}

fn failedEvidence(allocator: std.mem.Allocator) !cc.host_check.Evidence {
    return .{
        .grounding = .failed,
        .verdict_text = try allocator.dupe(u8, "The host ran the pinned check `sh run_tests` when you stopped.\nResult: FAILED (exit code 1), 1/2 passed.\nFailing:\n- tests/t.py::test_weak: weak tag compared raw\n"),
    };
}

fn envelope(allocator: std.mem.Allocator, header: []const u8, body: []const u8, supersedes: ?u64) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("{s}\nholds_when: the validator returns weak ETags\nuncertain: whether strong tags fail too\nlesson: {s}", .{ header, body });
    if (supersedes) |id| try aw.writer.print("\nsupersedes: {d}", .{id});
    return aw.toOwnedSlice();
}

test "L2 end-of-run learning: a failed host verdict → one no-tools request → the bound lesson is stored, a lying one is refused" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);
    // A stored lesson for the task: the packet lists it and a supersedes may name it.
    const seed = try envelope(a, "lesson-v1 verdict=failed task=" ++ TASK ++ " run=trial-6", "compare tags as raw strings", null);
    defer a.free(seed);
    const seed_id = try kg.client.remember(.observation, seed, lesson.SCHEMA_TYPE, false);

    const good = try envelope(a, HEADER_FAILED, "strip the W/ prefix before comparing", seed_id);
    defer a.free(good);
    const lying = try envelope(a, "lesson-v1 verdict=passed task=" ++ TASK ++ " run=" ++ RUN, "it works", null);
    defer a.free(lying);
    const reply_text = try std.fmt.allocPrint(a, "Two lessons.\n{s}\n---\n{s}\n", .{ good, lying });
    defer a.free(reply_text);
    const reply = try textSse(a, reply_text, 900);
    defer a.free(reply);
    var evidence = try failedEvidence(a);
    defer evidence.deinit(a);

    var served = try serve(a, &kg.client, &.{reply}, .{
        .mode = .enforce,
        .evidence = &evidence,
        .task_hint = TASK,
        .run_label = RUN,
        .final_note = "I think the comparison is fixed",
    }, 1024);
    defer served.deinit(a);

    try std.testing.expectEqual(@as(usize, 1), served.requests);
    try std.testing.expectEqual(@as(u8, 1), served.outcome.requests);
    try std.testing.expect(served.outcome.degraded == null);
    const body = served.body.?;
    // The request carries the verdict, the bound header, the stored lesson and
    // the note; it offers no tools and its system prompt is the frozen role.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "You review one finished attempt") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, end_of_run.MARKER) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, HEADER_FAILED) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tests/t.py::test_weak") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "compare tags as raw strings") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "I think the comparison is fixed") != null);
    // The caps the request ran under (self_evolution's author max_tokens bound).
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);

    const report = served.outcome.report;
    try std.testing.expect(report.enforced);
    try std.testing.expectEqual(learning.Grounding.failed, report.grounding);
    try std.testing.expectEqual(learning.Decision.distill, report.decision);
    try std.testing.expectEqual(@as(u8, 1), report.passes);
    try std.testing.expectEqual(@as(u32, 1), report.distill_turns);
    try std.testing.expectEqual(@as(u8, 1), report.lessons_accepted);
    try std.testing.expectEqual(@as(u32, 1), report.lessons_refused);
    try std.testing.expectEqual(@as(u64, 900), served.outcome.usage.input_tokens);

    // Durable state: the new lesson retires the seed; the lie never landed.
    const stored = try lesson.collectForTask(a, &kg.client, TASK, 8);
    defer lesson.freeStored(a, stored);
    try std.testing.expectEqual(@as(usize, 1), stored.len);
    try std.testing.expectEqual(lesson.Verdict.failed, stored[0].envelope.verdict);
    try std.testing.expectEqualStrings(RUN, stored[0].envelope.run);
    try std.testing.expectEqual(@as(?u64, seed_id), stored[0].envelope.supersedes);
    try std.testing.expectEqualStrings(good, stored[0].text);
}

test "L2 end-of-run learning: observe and tainted spend no request; a provider over the output cap is refused before sending" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);
    const good = try envelope(a, HEADER_FAILED, "x", null);
    defer a.free(good);
    const reply = try textSse(a, good, 10);
    defer a.free(reply);
    var evidence = try failedEvidence(a);
    defer evidence.deinit(a);
    const base: end_of_run.Input = .{ .mode = .observe, .evidence = &evidence, .task_hint = TASK, .run_label = RUN };

    {
        var served = try serve(a, &kg.client, &.{reply}, base, 1024);
        defer served.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), served.requests);
        try std.testing.expect(!served.outcome.report.enforced);
        try std.testing.expectEqual(learning.Decision.distill, served.outcome.report.decision);
        try std.testing.expectEqual(@as(u8, 0), served.outcome.report.passes);
    }
    {
        var tainted = cc.host_check.Evidence{ .grounding = .tainted };
        var input = base;
        input.mode = .enforce;
        input.evidence = &tainted;
        var served = try serve(a, &kg.client, &.{reply}, input, 1024);
        defer served.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), served.requests);
        try std.testing.expectEqual(learning.Decision.none_tainted, served.outcome.report.decision);
    }
    {
        var input = base;
        input.mode = .enforce;
        var served = try serve(a, &kg.client, &.{reply}, input, @intCast(cc.self_evolution.AUTHOR_MAX_OUTPUT_TOKENS + 1));
        defer served.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), served.requests);
        try std.testing.expectEqualStrings("OutputCapNotEnforcedByProvider", served.outcome.degraded.?);
        try std.testing.expectEqual(@as(u8, 0), served.outcome.report.passes);
    }
    const stored = try lesson.collectForTask(a, &kg.client, TASK, 8);
    defer lesson.freeStored(a, stored);
    try std.testing.expectEqual(@as(usize, 0), stored.len);
}

test "L2 end-of-run learning: usage over the author caps stores nothing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);
    const good = try envelope(a, HEADER_FAILED, "x", null);
    defer a.free(good);
    const reply = try textSse(a, good, cc.self_evolution.AUTHOR_MAX_INPUT_TOKENS + 1);
    defer a.free(reply);
    var evidence = try failedEvidence(a);
    defer evidence.deinit(a);
    var served = try serve(a, &kg.client, &.{reply}, .{ .mode = .enforce, .evidence = &evidence, .task_hint = TASK, .run_label = RUN }, 1024);
    defer served.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), served.requests);
    try std.testing.expectEqualStrings("UsageExceededCaps", served.outcome.degraded.?);
    try std.testing.expectEqual(@as(u8, 0), served.outcome.report.lessons_accepted);
    const stored = try lesson.collectForTask(a, &kg.client, TASK, 8);
    defer lesson.freeStored(a, stored);
    try std.testing.expectEqual(@as(usize, 0), stored.len);
}

test "L2 end-of-run learning: the pinned host check fills the evidence the turn learns from" {
    // runAndIngest spawns /bin/sh, as in production on the evaluation hosts.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var kg = (try Kg.open(a, root)) orelse return error.SkipZigTest;
    defer kg.close(a);
    const ppaths = @import("platform").paths;
    ppaths.setEnv(cc.host_check.CHECK_ENV, "printf 'FAILED tests/hc.py::TestH::test_weak - AssertionError: raw W/ tag\\n'; exit 1");
    defer ppaths.unsetEnv(cc.host_check.CHECK_ENV);
    const pin = cc.host_check.Pin.fromEnv() orelse return error.TestExpectedPin;

    var evidence: cc.host_check.Evidence = .{};
    defer evidence.deinit(a);
    const summary = cc.host_check.runAndIngestWithEvidence(a, &kg.client, &pin, TASK, "note", 7, &evidence) orelse
        return error.TestExpectedSummary;
    try std.testing.expectEqual(@as(usize, 1), summary.ingested);
    try std.testing.expectEqual(learning.Grounding.failed, evidence.grounding);
    const text = evidence.verdict_text.?;
    try std.testing.expect(std.mem.indexOf(u8, text, "Result: FAILED (exit code 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tests/hc.py::TestH::test_weak") != null);

    const good = try envelope(a, HEADER_FAILED, "strip W/ before comparing", null);
    defer a.free(good);
    const reply = try textSse(a, good, 10);
    defer a.free(reply);
    var served = try serve(a, &kg.client, &.{reply}, .{ .mode = .enforce, .evidence = &evidence, .task_hint = TASK, .run_label = RUN }, 1024);
    defer served.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), served.requests);
    try std.testing.expect(std.mem.indexOf(u8, served.body.?, "tests/hc.py::TestH::test_weak") != null);
    try std.testing.expectEqual(@as(u8, 1), served.outcome.report.lessons_accepted);

    // A tampered pin runs nothing: the evidence says unavailable, no lesson follows.
    ppaths.setEnv(cc.host_check.CHECK_ENV, "echo tampered; exit 0");
    var refused: cc.host_check.Evidence = .{};
    defer refused.deinit(a);
    try std.testing.expect(cc.host_check.runAndIngestWithEvidence(a, &kg.client, &pin, TASK, "", 8, &refused) == null);
    try std.testing.expectEqual(learning.Grounding.unavailable, refused.grounding);
    try std.testing.expect(refused.verdict_text == null);
}

// ── CLI wiring (step 6) ───────────────────────────────────────────────────

fn parse(arena: std.mem.Allocator, argv: []const [*:0]const u8) cc.types_mod.Config {
    return cc.parseArgsForTest(argv, arena);
}

test "L2 learning-turn flags: no verdict source is refused, like --check-gate without --host-check" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolve = cc.resolveLearningTurn;
    // Alone, in either mode, REPL or print mode: refused.
    for ([_][]const [*:0]const u8{
        &.{ "metacodes", "--learning-turn" },
        &.{ "metacodes", "--learning-turn-observe" },
        &.{ "metacodes", "-p", "hi", "--learning-turn" },
        // --host-check without the gate gives the in-run turn no verdict.
        &.{ "metacodes", "--host-check", "make check", "--learning-turn" },
    }) |argv| {
        var config = parse(arena, argv);
        try std.testing.expect(config.parse_error == null);
        const refusal = resolve(&config, .{}, arena) orelse return error.TestExpectedRefusal;
        try std.testing.expect(std.mem.indexOf(u8, refusal, "needs a verdict source") != null);
    }
    // The env source counts only in print mode.
    {
        var config = parse(arena, &.{ "metacodes", "--learning-turn" });
        try std.testing.expect(resolve(&config, .{ .host_check_armed = true }, arena) != null);
    }
    // The check gate is a source anywhere; the env host check in print mode.
    {
        var config = parse(arena, &.{ "metacodes", "--host-check", "make check", "--check-gate-observe", "--learning-turn" });
        try std.testing.expect(resolve(&config, .{}, arena) == null);
        try std.testing.expect(config.learning_turn);
    }
    {
        var config = parse(arena, &.{ "metacodes", "-p", "hi", "--learning-turn-observe" });
        try std.testing.expect(resolve(&config, .{ .host_check_armed = true }, arena) == null);
        try std.testing.expect(config.learning_turn_observe and !config.learning_turn);
    }
    // Nothing asked for: nothing refused, whatever the environment holds.
    {
        var config = parse(arena, &.{"metacodes"});
        try std.testing.expect(resolve(&config, .{ .mode = "enforce" }, arena) == null);
        try std.testing.expect(!config.learning_turn and !config.learning_turn_observe);
    }
}

test "L2 learning-turn flags: METACODES_LEARNING_TURN arms print mode only; a flag wins; a bad value is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolve = cc.resolveLearningTurn;
    {
        var config = parse(arena, &.{ "metacodes", "-p", "hi" });
        try std.testing.expect(resolve(&config, .{ .mode = "enforce", .host_check_armed = true }, arena) == null);
        try std.testing.expect(config.learning_turn);
    }
    {
        var config = parse(arena, &.{ "metacodes", "-p", "hi" });
        try std.testing.expect(resolve(&config, .{ .mode = "observe", .host_check_armed = true }, arena) == null);
        try std.testing.expect(config.learning_turn_observe and !config.learning_turn);
    }
    {
        // A flag wins over the environment.
        var config = parse(arena, &.{ "metacodes", "-p", "hi", "--learning-turn-observe" });
        try std.testing.expect(resolve(&config, .{ .mode = "enforce", .host_check_armed = true }, arena) == null);
        try std.testing.expect(!config.learning_turn);
    }
    {
        // Print mode with the variable but no verdict source: refused.
        var config = parse(arena, &.{ "metacodes", "-p", "hi" });
        try std.testing.expect(resolve(&config, .{ .mode = "enforce" }, arena) != null);
    }
    {
        var config = parse(arena, &.{ "metacodes", "-p", "hi" });
        const refusal = resolve(&config, .{ .mode = "on" }, arena) orelse return error.TestExpectedRefusal;
        try std.testing.expect(std.mem.indexOf(u8, refusal, learning.MODE_ENV) != null);
    }
}
