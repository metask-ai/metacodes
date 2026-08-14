//! Bounded recovery tool for session-scoped tool-result artifacts.

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const common = @import("common.zig");
const artifact = @import("../core/tool_result_artifact.zig");

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const artifact_id = common.extractJsonArg(args, "artifact_id") orelse return error.MissingArtifactId;
    const offset = (try parseOptionalU64(args, "offset")) orelse 0;
    const requested_limit = (try parseOptionalU64(args, "limit")) orelse 16 * 1024;
    if (requested_limit == 0 or requested_limit > artifact.MAX_READ_BYTES) return error.InvalidReadLimit;
    var chunk = try artifact.readChunk(ctx.allocator, ctx.artifact_root, artifact_id, offset, @intCast(requested_limit));
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
