//! L2: the inline threshold at the tool layer is the projection layer's
//! per-result budget, and the two layers agree at the seam.
//!
//! T1 is the defect: a result between `per_result_bytes` and the old 64KB
//! constant was lifted into memory by the tool layer and then spilled back
//! to the CAS by projection - the same bytes handled twice. T2 is the case
//! that cannot be removed: siblings in the same turn drive the water line
//! below `per_result_bytes`, so a result the tool layer correctly inlined is
//! still spilled - and that second transfer has to be lossless. T3 pins the
//! seam itself from both sides.
//!
//! No Windows skip: nothing here spawns a process or probes POSIX file modes.
//! The artifact layer runs on Windows in production, and `result_spool`'s own
//! test runs there; a skip would let the Windows gate go green without these.

const std = @import("std");
const cc = @import("cc");

const artifact = cc.tool_result_artifact;
const projection = cc.result_projection;
const result_budget = cc.result_budget;

const WINDOW: usize = 200_000; // per_result 25,000 / per_turn 204,800

fn tmpRoot(tmp: *std.testing.TmpDir, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

/// One complete byte-zero capture of `len` bytes filled with `fill`, finished
/// exactly the way the native tools finish theirs.
fn captureBody(
    allocator: std.mem.Allocator,
    root: []const u8,
    len: usize,
    fill: u8,
    budget: result_budget.Budget,
) !cc.tool_result.ToolResultBody {
    var capture = try artifact.Capture.begin(allocator, root, artifact.MAX_ARTIFACT_BYTES);
    defer capture.deinit();
    const payload = try allocator.alloc(u8, len);
    defer allocator.free(payload);
    @memset(payload, fill);
    try capture.write(payload);
    try capture.seal();
    return cc.result_spool.finishCaptureAsBody(allocator, root, &capture, .text_utf8, true, budget);
}

/// The bytes production commits for a body (`tool_exec` renders the same
/// way), as one owned slice the projection pass may replace.
fn committed(allocator: std.mem.Allocator, body: *cc.tool_result.ToolResultBody) ![]const u8 {
    var rendered = try body.render(allocator);
    defer rendered.deinit(allocator);
    return try allocator.dupe(u8, rendered.bytes);
}

const Envelope = struct {
    artifact_id: []const u8,
    head: u64,
    tail: u64,
    omitted: u64,

    fn parse(allocator: std.mem.Allocator, content: []const u8) !struct { parsed: std.json.Parsed(std.json.Value), env: Envelope } {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        errdefer parsed.deinit();
        const o = parsed.value.object;
        try std.testing.expectEqualStrings("artifact", o.get("projection").?.string);
        try std.testing.expect(o.get("recoverable").?.bool);
        return .{ .parsed = parsed, .env = .{
            .artifact_id = o.get("artifact_id").?.string,
            .head = @intCast(o.get("preview_head_bytes").?.integer),
            .tail = @intCast(o.get("preview_tail_bytes").?.integer),
            .omitted = @intCast(o.get("omitted_bytes").?.integer),
        } };
    }
};

test "T1 inline threshold: a result above per_result is published once by the tool layer and never written again by projection" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const budget = result_budget.Budget.fromModel(WINDOW);
    // Inside the old dead zone: above per_result (25,000), below the old 64KB.
    const size: usize = 40_000;
    try std.testing.expect(size > budget.per_result_bytes);

    var body = try captureBody(a, root, size, 'x', budget);
    defer body.deinit(a);
    // Tool layer: not lifted into memory.
    try std.testing.expect(body == .artifact);

    const before = artifact.sessionUsage(root);
    try std.testing.expect(before.observed);

    var content = try committed(a, &body);
    defer a.free(@constCast(content));
    var items = [_]projection.Item{.{ .tool_name = "Grep", .content = &content, .is_error = false }};
    const stats = try projection.project(a, &items, .{ .session_root = root, .budget = budget });

    // Projection grows the 1536-byte streaming preview to the budget - a
    // bounded read of head and tail - and writes nothing: no re-inline, no
    // pressure spill, and the store holds exactly the bytes it held before.
    //
    // `artifact_spill_count` is 1 here and that is *correct*: the accounting
    // pass counts every result that lives in an artifact this turn, including
    // one the tool layer committed (result_projection.zig, the
    // `recoverableEnvelopeOriginalBytes` branch) - it is not "spilled by this
    // pass". The first draft of this test read it that way and went red on
    // the fixed code. What "not written again" actually looks like is below:
    // the same artifact id survives (a second spill would mint a new one),
    // the original size is what got accounted, and the store did not grow.
    try std.testing.expectEqual(@as(usize, 1), stats.artifact_spill_count);
    try std.testing.expectEqual(@as(usize, 0), stats.turn_budget_spills);
    try std.testing.expectEqual(@as(usize, 1), stats.envelope_regrown_count);
    try std.testing.expectEqual(@as(usize, 0), stats.envelope_reinlined_count);
    try std.testing.expectEqual(size, stats.raw_bytes);
    const after = artifact.sessionUsage(root);
    try std.testing.expect(after.observed);
    try std.testing.expectEqual(before.used_bytes, after.used_bytes);

    var parsed = try Envelope.parse(a, content);
    defer parsed.parsed.deinit();
    try std.testing.expectEqualStrings(body.artifact.stored.id(), parsed.env.artifact_id);
    try std.testing.expectEqual(@as(u64, size), parsed.env.head + parsed.env.tail + parsed.env.omitted);
    // And the regrown preview actually used the budget: far more than the
    // 1536 streaming bytes, still inside one result's allowance.
    try std.testing.expect(parsed.env.head + parsed.env.tail > 1536);
    try std.testing.expect(content.len <= budget.per_result_bytes);
}

test "T2 inline threshold: siblings that drive the water line below per_result force a second transfer, and it loses nothing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const budget = result_budget.Budget.fromModel(WINDOW);

    const BIG: usize = 24_000; // under per_result: the tool layer is right to inline it
    const SMALL: usize = 3_000;
    const n_big = 8;
    const n_small = 10;
    // Priced at the per-result ceiling the turn does not fit: 222,000 > 204,800.
    try std.testing.expect(n_big * BIG + n_small * SMALL > budget.per_turn_bytes);

    var originals: [n_big + n_small][]u8 = undefined;
    var contents: [n_big + n_small][]const u8 = undefined;
    var items: [n_big + n_small]projection.Item = undefined;
    var built: usize = 0;
    defer {
        for (originals[0..built]) |o| a.free(o);
        for (contents[0..built]) |c| a.free(@constCast(c));
    }
    for (0..n_big + n_small) |i| {
        const len: usize = if (i < n_big) BIG else SMALL;
        const fill: u8 = if (i < n_big) 'A' + @as(u8, @intCast(i)) else 'a' + @as(u8, @intCast(i - n_big));
        var body = try captureBody(a, root, len, fill, budget);
        defer body.deinit(a);
        // Every one of the eighteen is correctly inlined by the tool layer.
        try std.testing.expect(body == .@"inline");
        originals[i] = try a.dupe(u8, body.@"inline".bytes);
        contents[i] = try committed(a, &body);
        built += 1;
        items[i] = .{ .tool_name = "Grep", .content = &contents[i], .is_error = false };
    }

    const stats = try projection.project(a, &items, .{ .session_root = root, .budget = budget });

    // The water line lands at 21,850: every big result spills, every small one
    // is left untouched, and the turn comes out exactly on budget.
    try std.testing.expectEqual(@as(usize, n_big), stats.artifact_spill_count);
    try std.testing.expectEqual(@as(usize, n_big), stats.turn_budget_spills);
    try std.testing.expect(!stats.budget_exhausted);
    var total: usize = 0;
    for (contents) |c| total += c.len;
    try std.testing.expect(total <= budget.per_turn_bytes);

    for (n_big..n_big + n_small) |i| try std.testing.expectEqualSlices(u8, originals[i], contents[i]);

    for (0..n_big) |i| {
        var parsed = try Envelope.parse(a, contents[i]);
        defer parsed.parsed.deinit();
        try std.testing.expectEqual(@as(u64, BIG), parsed.env.head + parsed.env.tail + parsed.env.omitted);
        // Lossless: the artifact reads back byte-for-byte.
        var chunk = try artifact.readChunk(a, root, parsed.env.artifact_id, 0, BIG);
        defer chunk.deinit();
        try std.testing.expectEqual(@as(u64, BIG), chunk.total_bytes);
        try std.testing.expectEqualSlices(u8, originals[i], chunk.bytes);
    }
}

test "T3 inline threshold: the seam is per_result_bytes exactly, from both sides" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const budget = result_budget.Budget.fromModel(WINDOW);
    const edge = budget.per_result_bytes;

    // At the budget: inline at the tool layer, and projection agrees.
    {
        var body = try captureBody(a, root, edge, 'e', budget);
        defer body.deinit(a);
        try std.testing.expect(body == .@"inline");
        var content = try committed(a, &body);
        defer a.free(@constCast(content));
        var items = [_]projection.Item{.{ .tool_name = "Grep", .content = &content, .is_error = false }};
        const stats = try projection.project(a, &items, .{ .session_root = root, .budget = budget });
        try std.testing.expectEqual(@as(usize, 0), stats.artifact_spill_count);
        try std.testing.expectEqual(edge, content.len);
    }
    // One byte over: the tool layer publishes; nothing is materialized.
    {
        var body = try captureBody(a, root, edge + 1, 'f', budget);
        defer body.deinit(a);
        try std.testing.expect(body == .artifact);
    }
    // The same byte count under a larger window stays inline: the seam moves
    // with the budget, which is the whole point of not owning a constant.
    {
        const wide = result_budget.Budget.fromModel(1_000_000);
        var body = try captureBody(a, root, edge + 1, 'g', wide);
        defer body.deinit(a);
        try std.testing.expect(body == .@"inline");
    }
}

test "T4 inline threshold: a tool-layer envelope is not a structured tool result, a JSON body still is" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const budget = result_budget.Budget.fromModel(WINDOW);

    // A text result the tool layer published: its envelope is JSON, the
    // result is not. Before the fix this counted as structured, and with the
    // tool layer publishing everything above per_result it inflated the
    // metric for every large Grep.
    var text_body = try captureBody(a, root, 40_000, 't', budget);
    defer text_body.deinit(a);
    try std.testing.expect(text_body == .artifact);
    var text_content = try committed(a, &text_body);
    defer a.free(@constCast(text_content));

    // A JSON body the tool itself emitted, inline: this is what the counter
    // is for.
    var json_content: []const u8 = try a.dupe(u8, "{\"schema_version\":\"metacodes.bash-result.v2\",\"stdout\":\"ok\",\"exit_code\":0}");
    defer a.free(@constCast(json_content));

    var items = [_]projection.Item{
        .{ .tool_name = "Grep", .content = &text_content, .is_error = false },
        .{ .tool_name = "Bash", .content = &json_content, .is_error = false },
    };
    const stats = try projection.project(a, &items, .{ .session_root = root, .budget = budget });
    try std.testing.expectEqual(@as(usize, 1), stats.structured_result_count);
    try std.testing.expectEqual(@as(usize, 0), stats.turn_budget_spills);
}
