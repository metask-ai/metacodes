//! Bounded recovery tool for session-scoped tool-result artifacts.

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const common = @import("common.zig");
const artifact = @import("../core/tool_result_artifact.zig");

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
    const ceiling = @min(artifact.MAX_READ_BYTES, ctx.result_budget.per_result_bytes);
    const requested_limit = (try parseOptionalU64(args, "limit")) orelse ceiling;
    if (requested_limit == 0 or requested_limit > artifact.MAX_READ_BYTES) return error.InvalidReadLimit;
    const limit = @min(requested_limit, ceiling);
    var chunk = try artifact.readChunk(ctx.allocator, ctx.artifact_root, artifact_id, offset, @intCast(limit));
    defer chunk.deinit();
    if (ctx.tool_result_metrics) |metrics| metrics.recordRecovery(chunk.bytes.len);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"schema_version\":\"metacodes.read-artifact.v1\",\"artifact_id\":");
    try std.json.Stringify.encodeJsonString(artifact_id, .{}, writer);
    try writer.print(",\"offset\":{d},\"returned_bytes\":{d},\"total_bytes\":{d},\"next_offset\":", .{ chunk.offset, chunk.bytes.len, chunk.total_bytes });
    if (chunk.next_offset) |next| try writer.print("{d}", .{next}) else try writer.writeAll("null");
    try writer.print(",\"truncated\":{s}", .{if (chunk.next_offset != null) "true" else "false"});
    if (std.unicode.utf8ValidateSlice(chunk.bytes)) {
        try writer.writeAll(",\"encoding\":\"utf-8\",\"data\":");
        try std.json.Stringify.encodeJsonString(chunk.bytes, .{}, writer);
    } else {
        const encoder = std.base64.standard.Encoder;
        const encoded = try ctx.allocator.alloc(u8, encoder.calcSize(chunk.bytes.len));
        defer ctx.allocator.free(encoded);
        _ = encoder.encode(encoded, chunk.bytes);
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
    try std.testing.expectEqual(@as(i64, 8 * 1024), parsed.value.object.get("returned_bytes").?.integer);
    // Nothing is lost: the remainder is reachable through next_offset.
    try std.testing.expectEqual(@as(i64, 8 * 1024), parsed.value.object.get("next_offset").?.integer);
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);

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
    try std.testing.expectEqual(@as(i64, 32 * 1024), wide_parsed.value.object.get("returned_bytes").?.integer);

    // An explicit request above the protocol maximum is still an error, not a
    // silent clamp: the envelope advertises 32768 and the model should learn
    // when it asked for something the tool never offers.
    const oversize = try std.fmt.allocPrint(allocator, "{{\"artifact_id\":\"{s}\",\"limit\":32769}}", .{receipt.id()});
    defer allocator.free(oversize);
    try std.testing.expectError(error.InvalidReadLimit, execute(&wide_ctx, oversize));
}
