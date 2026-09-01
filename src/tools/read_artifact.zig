//! Bounded recovery tool for session-scoped tool-result artifacts.

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const common = @import("common.zig");
const artifact = @import("../core/tool_result_artifact.zig");
const result_budget = @import("../core/result_budget.zig");

/// Fixed JSON scaffolding of one recovery envelope: schema version, artifact
/// id, the four byte counters, the truncation flag, the encoding and the field
/// name of the payload. Measured at ~230 bytes; rounded up so a chunk sized
/// against the remaining allowance cannot push the rendered envelope past the
/// per-result budget it was derived from.
const ENVELOPE_OVERHEAD_BYTES: usize = 256;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const artifact_id = common.extractJsonArg(args, "artifact_id") orelse return error.MissingArtifactId;
    const offset = (try parseOptionalU64(args, "offset")) orelse 0;
    // Recovery is exempt from the projection budget, because spilling a
    // recovery result would make its own recovery recurse. That exemption
    // removes the only other bound, so it has to be replaced here rather than
    // left off: at the 8KiB budget floor an unbounded 32KiB read is four times
    // what one result may cost, and nothing downstream can trim it.
    // `MAX_READ_BYTES` stays the hard protocol maximum an explicit request may
    // name; the budget then clamps what one call actually returns, and
    // `next_offset` carries the rest exactly as it does for any short read.
    const ceiling = @max(1, @min(artifact.MAX_READ_BYTES, ctx.result_budget.per_result_bytes));
    const requested_limit = (try parseOptionalU64(args, "limit")) orelse ceiling;
    if (requested_limit == 0 or requested_limit > artifact.MAX_READ_BYTES) return error.InvalidReadLimit;
    const limit = @min(requested_limit, ceiling);
    var chunk = try artifact.readChunk(ctx.allocator, ctx.artifact_root, artifact_id, offset, @intCast(limit));
    defer chunk.deinit();

    // The chunk is JSON-escaped - or base64'd - into `data`, so `limit` bounds
    // the *source* bytes and not what the model is charged for. A quote-dense
    // chunk doubles and a chunk of control bytes sextuples, which would put
    // the recovery for an over-budget result further over the budget than the
    // result was. Reading `limit` source bytes is the right upper bound (an
    // encoded byte never costs less than its source byte); the cut back to the
    // encoded ceiling happens here, and `next_offset` carries the difference
    // exactly as it does for any short read.
    const utf8 = std.unicode.utf8ValidateSlice(chunk.bytes);
    const kept = result_budget.headCut(chunk.bytes, ceiling -| ENVELOPE_OVERHEAD_BYTES, !utf8);
    const data = chunk.bytes[0..kept];
    const next_offset: ?u64 = if (chunk.offset + kept < chunk.total_bytes)
        chunk.offset + kept
    else
        null;
    if (ctx.tool_result_metrics) |metrics| metrics.recordRecovery(data.len);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"schema_version\":\"metacodes.read-artifact.v1\",\"artifact_id\":");
    try std.json.Stringify.encodeJsonString(artifact_id, .{}, writer);
    try writer.print(",\"offset\":{d},\"returned_bytes\":{d},\"total_bytes\":{d},\"next_offset\":", .{ chunk.offset, data.len, chunk.total_bytes });
    if (next_offset) |next| try writer.print("{d}", .{next}) else try writer.writeAll("null");
    try writer.print(",\"truncated\":{s}", .{if (next_offset != null) "true" else "false"});
    if (utf8) {
        try writer.writeAll(",\"encoding\":\"utf-8\",\"data\":");
        try std.json.Stringify.encodeJsonString(data, .{}, writer);
    } else {
        const encoder = std.base64.standard.Encoder;
        const encoded = try ctx.allocator.alloc(u8, encoder.calcSize(data.len));
        defer ctx.allocator.free(encoded);
        _ = encoder.encode(encoded, data);
        try writer.writeAll(",\"encoding\":\"base64\",\"data\":");
        try std.json.Stringify.encodeJsonString(encoded, .{}, writer);
    }
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

fn parseOptionalU64(args: []const u8, key: []const u8) !?u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, args, .{}) catch return error.InvalidArtifactArgs;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArtifactArgs;
    const value = parsed.value.object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return error.InvalidArtifactArgs;
    return @intCast(value.integer);
}

test "ReadArtifact returns bounded stable envelope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const receipt = try artifact.persist(allocator, root, "0123456789abcdef");
    var ctx = ToolContext{ .allocator = allocator, .artifact_root = root };
    const args = try std.fmt.allocPrint(allocator, "{{\"artifact_id\":\"{s}\",\"offset\":4,\"limit\":5}}", .{receipt.id()});
    defer allocator.free(args);
    const result = try execute(&ctx, args);
    defer allocator.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("45678", parsed.value.object.get("data").?.string);
    try std.testing.expectEqual(@as(i64, 9), parsed.value.object.get("next_offset").?.integer);
}

test "ReadArtifact rejects malformed and negative ranges instead of defaulting" {
    const ctx = ToolContext{ .allocator = std.testing.allocator };
    try std.testing.expectError(error.InvalidArtifactArgs, execute(&ctx, "{\"artifact_id\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"offset\":"));
    try std.testing.expectError(error.InvalidArtifactArgs, execute(&ctx, "{\"artifact_id\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"offset\":-1}"));
}

test "ReadArtifact clamps a recovery read to the per-result budget" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const payload = try allocator.alloc(u8, 40 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'R');
    const receipt = try artifact.persist(allocator, root, payload);

    // Floor budget: 8KiB per result. An explicit 32KiB request is legal at the
    // protocol level but must not return four budgets' worth of bytes.
    var floor_ctx = ToolContext{ .allocator = allocator, .artifact_root = root };
    const args = try std.fmt.allocPrint(allocator, "{{\"artifact_id\":\"{s}\",\"offset\":0,\"limit\":32768}}", .{receipt.id()});
    defer allocator.free(args);
    const clamped = try execute(&floor_ctx, args);
    defer allocator.free(clamped);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, clamped, .{});
    defer parsed.deinit();
    // The budget buys the whole envelope, not just its payload, so the chunk
    // is the budget minus the envelope's own scaffolding.
    const floor_payload: i64 = 8 * 1024 - ENVELOPE_OVERHEAD_BYTES;
    try std.testing.expectEqual(floor_payload, parsed.value.object.get("returned_bytes").?.integer);
    // Nothing is lost: the remainder is reachable through next_offset.
    try std.testing.expectEqual(floor_payload, parsed.value.object.get("next_offset").?.integer);
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
    try std.testing.expect(clamped.len <= 8 * 1024);

    // A wide window keeps the full protocol maximum available.
    var wide_ctx = ToolContext{
        .allocator = allocator,
        .artifact_root = root,
        .result_budget = .fromModel(1_000_000),
    };
    const wide = try execute(&wide_ctx, args);
    defer allocator.free(wide);
    var wide_parsed = try std.json.parseFromSlice(std.json.Value, allocator, wide, .{});
    defer wide_parsed.deinit();
    try std.testing.expectEqual(
        @as(i64, 32 * 1024 - ENVELOPE_OVERHEAD_BYTES),
        wide_parsed.value.object.get("returned_bytes").?.integer,
    );

    // An explicit request above the protocol maximum is still an error, not a
    // silent clamp: the envelope advertises 32768 and the model should learn
    // when it asked for something the tool never offers.
    const oversize = try std.fmt.allocPrint(allocator, "{{\"artifact_id\":\"{s}\",\"limit\":32769}}", .{receipt.id()});
    defer allocator.free(oversize);
    try std.testing.expectError(error.InvalidReadLimit, execute(&wide_ctx, oversize));
}

test "a recovery read is bounded in the bytes the model is charged for" {
    // The recovery tool is exempt from the projection pass, so its own bound
    // is the only one. Cutting on source length let a quote-dense chunk render
    // at twice the per-result budget and a chunk of control bytes at 4/3 of it
    // - the recovery for an over-budget result coming back further over the
    // budget than the result had been.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const budget = result_budget.Budget.fromModel(200_000);

    for ([_]u8{ '"', '\n', 0x01, 'R' }) |fill| {
        const payload = try allocator.alloc(u8, 128 * 1024);
        defer allocator.free(payload);
        @memset(payload, fill);
        const receipt = try artifact.persist(allocator, root, payload);
        var ctx = ToolContext{ .allocator = allocator, .artifact_root = root, .result_budget = budget };
        const args = try std.fmt.allocPrint(
            allocator,
            "{{\"artifact_id\":\"{s}\",\"limit\":32768}}",
            .{receipt.id()},
        );
        defer allocator.free(args);
        const out = try execute(&ctx, args);
        defer allocator.free(out);
        try std.testing.expect(out.len <= budget.per_result_bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
        defer parsed.deinit();
        // Nothing is lost: what did not fit is reachable through next_offset,
        // and the two agree byte for byte.
        const returned = parsed.value.object.get("returned_bytes").?.integer;
        try std.testing.expect(returned > 0);
        try std.testing.expect(parsed.value.object.get("truncated").?.bool);
        try std.testing.expectEqual(returned, parsed.value.object.get("next_offset").?.integer);
    }
}
