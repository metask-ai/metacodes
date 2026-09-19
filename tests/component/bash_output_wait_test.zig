//! L2: schema-declared BashOutput wait_ms reaches the real dispatcher and envelope.

const std = @import("std");
const cc = @import("cc");

fn inlineBytes(outcome: anytype) ![]const u8 {
    return switch (outcome.*) {
        .ok => |body| switch (body) {
            .@"inline" => |result| result.bytes,
            else => error.UnexpectedBashOutputBody,
        },
        else => error.UnexpectedBashOutputOutcome,
    };
}

test "BashOutput L2 wait_ms schema drives a visible wait and waited_ms" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var jobs = try cc.job_registry.JobRegistry.init(allocator);
    defer jobs.deinit();
    var ctx = cc.tools.ToolContext{ .allocator = allocator, .jobs = &jobs };

    const delayed = try jobs.spawnBackground("sleep 0.25; printf schema", null);
    var delayed_input: [256]u8 = undefined;
    const delayed_json = try std.fmt.bufPrint(
        &delayed_input,
        "{{\"job_id\":\"{s}\",\"wait_ms\":500}}",
        .{delayed.idSlice()},
    );
    const started = cc.util_time.nowMs();
    var delayed_outcome = try cc.tools.dispatch(&ctx, "BashOutput", delayed_json);
    defer delayed_outcome.deinit(allocator);
    const delayed_bytes = try inlineBytes(&delayed_outcome);
    try std.testing.expect(cc.util_time.nowMs() - started >= 150);
    var delayed_body = try std.json.parseFromSlice(std.json.Value, allocator, delayed_bytes, .{});
    defer delayed_body.deinit();
    try std.testing.expectEqualStrings("schema", delayed_body.value.object.get("stdout").?.string);
    try std.testing.expect(delayed_body.value.object.get("waited_ms").?.integer > 0);

    const snapshot = try jobs.spawnBackground("sleep 1", null);
    var snapshot_input: [256]u8 = undefined;
    const snapshot_json = try std.fmt.bufPrint(
        &snapshot_input,
        "{{\"job_id\":\"{s}\",\"wait_ms\":0}}",
        .{snapshot.idSlice()},
    );
    const snapshot_started = cc.util_time.nowMs();
    var snapshot_outcome = try cc.tools.dispatch(&ctx, "BashOutput", snapshot_json);
    defer snapshot_outcome.deinit(allocator);
    const snapshot_bytes = try inlineBytes(&snapshot_outcome);
    try std.testing.expect(cc.util_time.nowMs() - snapshot_started < 2000);
    var snapshot_body = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_bytes, .{});
    defer snapshot_body.deinit();
    try std.testing.expectEqual(@as(i64, 0), snapshot_body.value.object.get("waited_ms").?.integer);
    try std.testing.expectEqualStrings("running", snapshot_body.value.object.get("status").?.string);
}
