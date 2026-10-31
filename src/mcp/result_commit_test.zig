//! The projector's sealed results at the batch commit boundary. These tests
//! drive `core/tool_exec`, the kernel that owns that boundary, so they live
//! outside the client's import closure (`subsystem:boundary`).

const std = @import("std");
const result_stream = @import("result_stream.zig");
const project = result_stream.project;
const MAX_RESPONSE_BYTES = result_stream.MAX_RESPONSE_BYTES;
const writeSuccessfulResultOfSize = result_stream.writeSuccessfulResultOfSize;
const fillSessionArtifactQuota = result_stream.fillSessionArtifactQuota;
const artifact_store = @import("../core/tool_result_artifact.zig");
const result_budget = @import("../core/result_budget.zig");
const tool_result = @import("../core/tool_result.zig");

/// What `tool_exec.publishSealedResults` does with a sealed body at the batch
/// commit boundary; the failure-policy tests drive it directly.
const TestCommitted = struct {
    content: []u8,
    is_error: bool,
    fn deinit(self: *TestCommitted, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

fn testCommitSealed(allocator: std.mem.Allocator, body: *tool_result.ToolResultBody) !TestCommitted {
    const tool_exec = @import("../core/tool_exec.zig");
    var rendered = try body.render(allocator);
    defer rendered.deinit(allocator);
    var slots = [_]tool_exec.Slot{.{
        .decision = .run,
        .name = "mock__tool",
        .id = "sid",
        .input = "{}",
        .content = try allocator.dupe(u8, rendered.bytes),
        .sealed = body.takeSealedHandles(),
    }};
    errdefer for (&slots) |*slot| slot.deinit(allocator);
    try tool_exec.publishSealedResults(&slots, allocator, .{ .bytes = [_]u8{'0'} ** 12 });
    const content = slots[0].content.?;
    slots[0].content = null;
    const is_error = slots[0].is_error;
    for (&slots) |*slot| slot.deinit(allocator);
    return .{ .content = content, .is_error = is_error };
}

test "stream projector rejects over-ceiling result when publication fails" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try fillSessionArtifactQuota(allocator, root);
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try writeSuccessfulResultOfSize(&capture, 96 * 1024);
    try capture.seal();

    const budget = result_budget.Budget.fromModel(1_000_000);
    try std.testing.expectEqual(result_budget.PER_RESULT_MAX_BYTES, budget.per_result_bytes);
    var outcome = try project(
        allocator,
        &capture,
        root,
        7,
        .modern_2026_07_28,
        .{},
        budget,
        true,
        true,
    );
    defer if (outcome == .result) outcome.result.deinit(allocator);
    // Above the ceiling the commit boundary cannot keep the bytes inline: the
    // slot becomes the bounded ArtifactPublishFailed tool error — fail closed,
    // as the projector's resource_limit diagnostic was at call time.
    try std.testing.expect(outcome == .result);
    try std.testing.expect(outcome.result == .sealed);
    var committed = try testCommitSealed(allocator, &outcome.result);
    defer committed.deinit(allocator);
    try std.testing.expect(committed.is_error);
    // `ArtifactPublishFailed` renders as the `io_error` tool error whose detail
    // names the boundary.
    try std.testing.expect(std.mem.indexOf(u8, committed.content, "\"io_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, committed.content, "failed at the batch commit boundary") != null);
}

test "stream projector retains bounded result inline when publication fails" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try fillSessionArtifactQuota(allocator, root);
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try writeSuccessfulResultOfSize(&capture, 30_000);
    try capture.seal();

    const budget = result_budget.Budget.fromModel(200_000);
    var outcome = try project(
        allocator,
        &capture,
        root,
        7,
        .modern_2026_07_28,
        .{},
        budget,
        true,
        true,
    );
    defer if (outcome == .result) outcome.result.deinit(allocator);
    try std.testing.expect(outcome == .result);
    // Sealed regardless of the full quota (#73): the failure surfaces at the
    // batch commit boundary, where the loop's policy keeps a result within the
    // inline-retention ceiling as bytes.
    try std.testing.expect(outcome.result == .sealed);
    var committed = try testCommitSealed(allocator, &outcome.result);
    defer committed.deinit(allocator);
    try std.testing.expect(!committed.is_error);
    try std.testing.expectEqual(@as(usize, 30_000), committed.content.len);
}
