const std = @import("std");

/// Owns the edge-segment manifest publication commit protocol. `Ops` keeps
/// entry validation, epoch naming, byte encoding, fsync, and rename mechanics
/// in the storage façade. Once an epoch may be visible, this controller never
/// asks the data plane to delete it: an orphan is recoverable, while deleting
/// a manifest that CURRENT may reference is corruption.
pub fn EdgeSegmentPublication(comptime Ops: type) type {
    return struct {
        pub fn publish(context: anytype, entries: anytype) !void {
            const epoch_path = try Ops.prepareEpoch(context, entries);
            defer Ops.releaseEpochPath(context, epoch_path);

            try Ops.writeEpoch(context, epoch_path, entries);
            try Ops.commitCurrent(context, epoch_path);
        }
    };
}

const TestFailure = enum {
    none,
    prepare,
    epoch_write,
    current_commit,
};

const TestPhase = enum {
    prepare,
    write_epoch,
    commit_current,
    release_path,
};

const TestContext = struct {
    phases: [4]TestPhase = undefined,
    phase_count: usize = 0,
    failure: TestFailure = .none,
    epoch_visible: bool = false,
    current_visible: bool = false,

    fn record(self: *TestContext, phase: TestPhase) void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
    }

    fn recorded(self: *const TestContext) []const TestPhase {
        return self.phases[0..self.phase_count];
    }
};

const TestOps = struct {
    fn prepareEpoch(context: *TestContext, entries: anytype) ![]const u8 {
        _ = entries;
        context.record(.prepare);
        if (context.failure == .prepare) return error.InvalidRecord;
        return "edge-segment-epoch";
    }

    fn releaseEpochPath(context: *TestContext, epoch_path: []const u8) void {
        _ = epoch_path;
        context.record(.release_path);
    }

    fn writeEpoch(context: *TestContext, epoch_path: []const u8, entries: anytype) !void {
        _ = epoch_path;
        _ = entries;
        context.record(.write_epoch);
        // Model an error after the epoch rename may already be visible. The
        // controller must preserve it regardless of whether the call returns.
        context.epoch_visible = true;
        if (context.failure == .epoch_write) return error.AccessDenied;
    }

    fn commitCurrent(context: *TestContext, epoch_path: []const u8) !void {
        _ = epoch_path;
        context.record(.commit_current);
        if (context.failure == .current_commit) return error.AccessDenied;
        context.current_visible = true;
    }
};

const test_publication = EdgeSegmentPublication(TestOps);

test "edge segment publication writes epoch before committing current" {
    var context = TestContext{};

    try test_publication.publish(&context, &.{@as(u8, 1)});

    try std.testing.expectEqualSlices(TestPhase, &.{
        .prepare,
        .write_epoch,
        .commit_current,
        .release_path,
    }, context.recorded());
    try std.testing.expect(context.epoch_visible);
    try std.testing.expect(context.current_visible);
}

test "edge segment publication prepare failure performs no mutation" {
    var context = TestContext{ .failure = .prepare };

    try std.testing.expectError(error.InvalidRecord, test_publication.publish(&context, &.{@as(u8, 1)}));

    try std.testing.expectEqualSlices(TestPhase, &.{.prepare}, context.recorded());
    try std.testing.expect(!context.epoch_visible);
    try std.testing.expect(!context.current_visible);
}

test "edge segment publication epoch error never advances current" {
    var context = TestContext{ .failure = .epoch_write };

    try std.testing.expectError(error.AccessDenied, test_publication.publish(&context, &.{@as(u8, 1)}));

    try std.testing.expectEqualSlices(TestPhase, &.{
        .prepare,
        .write_epoch,
        .release_path,
    }, context.recorded());
    try std.testing.expect(context.epoch_visible);
    try std.testing.expect(!context.current_visible);
}

test "edge segment publication current error preserves visible epoch" {
    var context = TestContext{ .failure = .current_commit };

    try std.testing.expectError(error.AccessDenied, test_publication.publish(&context, &.{@as(u8, 1)}));

    try std.testing.expectEqualSlices(TestPhase, &.{
        .prepare,
        .write_epoch,
        .commit_current,
        .release_path,
    }, context.recorded());
    try std.testing.expect(context.epoch_visible);
    try std.testing.expect(!context.current_visible);
}
