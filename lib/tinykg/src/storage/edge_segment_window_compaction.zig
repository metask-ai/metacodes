const std = @import("std");

/// Owns one already-selected edge-segment window compaction transaction:
/// validate the window, open its sources, write both ordered directions,
/// assemble the replacement manifest, publish it, then update metadata.
/// Concrete CSR/mmap resources, merge streams, sidecar codecs, and Store I/O
/// remain in the stable storage facade behind `Ops`.
pub fn EdgeSegmentWindowCompaction(comptime Ops: type) type {
    return struct {
        pub fn compact(
            context: anytype,
            target_path: []const u8,
            entries: []const Ops.OwnedEntryType,
            start: usize,
            count: usize,
            compacted_edges: u64,
        ) !u64 {
            const full_range = start == 0 and count == entries.len;
            if (!full_range and
                (count <= 1 or count > entries.len or start > entries.len - count))
            {
                return error.InvalidRecord;
            }
            if (try Ops.pathExists(context, target_path)) return error.AlreadyExists;

            const selected = entries[start..][0..count];
            var sources = try Ops.openSources(context, selected);
            defer Ops.deinitSources(context, &sources);

            var target = try Ops.createTarget(context, target_path);
            errdefer Ops.deinitTarget(context, &target);
            var target_unpublished = true;
            errdefer if (target_unpublished) Ops.deleteUnpublishedTarget(context, target_path);

            const forward_summary = try Ops.writeDirection(
                context,
                &target,
                &sources,
                .forward,
                compacted_edges,
            );
            const reverse_summary = try Ops.writeDirection(
                context,
                &target,
                &sources,
                .reverse,
                compacted_edges,
            );

            if (full_range) {
                const written_summary = try Ops.summarizeDirections(
                    context,
                    forward_summary,
                    reverse_summary,
                );
                const id_index = try Ops.writeIdIndex(
                    context,
                    target_path,
                    selected,
                    written_summary,
                );
                const next_entries = [_]Ops.EntryType{
                    Ops.replacementEntry(target_path, compacted_edges, written_summary, id_index),
                };

                // Publication may already have advanced CURRENT when it
                // reports an error. From this point onward the target must be
                // preserved; an unreferenced directory is safe for later GC.
                target_unpublished = false;
                try Ops.publishManifest(context, &next_entries);
                try Ops.updateMetadata(context, &next_entries);
                Ops.deinitTarget(context, &target);
                return compacted_edges;
            }

            var next_entries = std.ArrayList(Ops.EntryType).empty;
            defer next_entries.deinit(Ops.allocator(context));
            try next_entries.ensureTotalCapacity(
                Ops.allocator(context),
                entries.len - count + 1,
            );
            for (entries[0..start]) |entry| {
                next_entries.appendAssumeCapacity(Ops.copyEntry(entry));
            }

            const written_summary = try Ops.summarizeDirections(
                context,
                forward_summary,
                reverse_summary,
            );
            const id_index = try Ops.writeIdIndex(
                context,
                target_path,
                selected,
                written_summary,
            );
            next_entries.appendAssumeCapacity(
                Ops.replacementEntry(target_path, compacted_edges, written_summary, id_index),
            );
            for (entries[start + count ..]) |entry| {
                next_entries.appendAssumeCapacity(Ops.copyEntry(entry));
            }

            target_unpublished = false;
            try Ops.publishManifest(context, next_entries.items);
            try Ops.updateMetadata(context, next_entries.items);
            Ops.deinitTarget(context, &target);
            return compacted_edges;
        }
    };
}

const TestDirection = enum {
    forward,
    reverse,
};

const TestOwnedEntry = struct {
    id: u8,
    edge_count: u64,
};

const TestEntry = struct {
    id: u8,
    edge_count: u64,
    path: []const u8,
};

const TestSources = struct {};
const TestTarget = struct {};

const TestDirectionSummary = struct {
    direction: TestDirection,
};

const TestWrittenSummary = struct {
    replacement_id: u8,
};

const TestIdIndex = struct {
    replacement_id: u8,
};

const TestPhase = enum {
    path_exists,
    open_sources,
    create_target,
    write_forward,
    write_reverse,
    summarize,
    write_id_index,
    publish_manifest,
    update_metadata,
    delete_target,
    deinit_target,
    deinit_sources,
};

const TestContext = struct {
    phases: [64]TestPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPhase = null,
    target_exists: bool = false,
    target_deleted: usize = 0,
    target_deinited: usize = 0,
    sources_deinited: usize = 0,
    manifest_published: bool = false,
    published_entries: [8]TestEntry = undefined,
    published_count: usize = 0,

    fn record(self: *TestContext, phase: TestPhase) !void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
        if (self.fail_at == phase) return error.InjectedFailure;
    }

    fn recordCleanup(self: *TestContext, phase: TestPhase) void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
    }

    fn recorded(self: *const TestContext) []const TestPhase {
        return self.phases[0..self.phase_count];
    }
};

const TestOps = struct {
    pub const OwnedEntryType = TestOwnedEntry;
    pub const EntryType = TestEntry;

    pub fn allocator(_: *TestContext) std.mem.Allocator {
        return std.testing.allocator;
    }

    pub fn pathExists(context: *TestContext, _: []const u8) !bool {
        try context.record(.path_exists);
        return context.target_exists;
    }

    pub fn openSources(context: *TestContext, _: []const TestOwnedEntry) !TestSources {
        try context.record(.open_sources);
        return .{};
    }

    pub fn deinitSources(context: *TestContext, _: *TestSources) void {
        context.recordCleanup(.deinit_sources);
        context.sources_deinited += 1;
    }

    pub fn createTarget(context: *TestContext, _: []const u8) !TestTarget {
        try context.record(.create_target);
        return .{};
    }

    pub fn deinitTarget(context: *TestContext, _: *TestTarget) void {
        context.recordCleanup(.deinit_target);
        context.target_deinited += 1;
    }

    pub fn deleteUnpublishedTarget(context: *TestContext, _: []const u8) void {
        context.recordCleanup(.delete_target);
        context.target_deleted += 1;
    }

    pub fn writeDirection(
        context: *TestContext,
        _: *TestTarget,
        _: *TestSources,
        direction: TestDirection,
        _: u64,
    ) !TestDirectionSummary {
        try context.record(switch (direction) {
            .forward => .write_forward,
            .reverse => .write_reverse,
        });
        return .{ .direction = direction };
    }

    pub fn summarizeDirections(
        context: *TestContext,
        forward: TestDirectionSummary,
        reverse: TestDirectionSummary,
    ) !TestWrittenSummary {
        try context.record(.summarize);
        if (forward.direction != .forward or reverse.direction != .reverse) {
            return error.InvalidRecord;
        }
        return .{ .replacement_id = 99 };
    }

    pub fn writeIdIndex(
        context: *TestContext,
        _: []const u8,
        _: []const TestOwnedEntry,
        summary: TestWrittenSummary,
    ) !TestIdIndex {
        try context.record(.write_id_index);
        return .{ .replacement_id = summary.replacement_id };
    }

    pub fn copyEntry(entry: TestOwnedEntry) TestEntry {
        return .{
            .id = entry.id,
            .edge_count = entry.edge_count,
            .path = "old",
        };
    }

    pub fn replacementEntry(
        path: []const u8,
        edge_count: u64,
        summary: TestWrittenSummary,
        id_index: TestIdIndex,
    ) TestEntry {
        std.debug.assert(summary.replacement_id == id_index.replacement_id);
        return .{
            .id = summary.replacement_id,
            .edge_count = edge_count,
            .path = path,
        };
    }

    pub fn publishManifest(context: *TestContext, entries: []const TestEntry) !void {
        try context.record(.publish_manifest);
        context.manifest_published = true;
        context.published_count = entries.len;
        @memcpy(context.published_entries[0..entries.len], entries);
    }

    pub fn updateMetadata(context: *TestContext, entries: []const TestEntry) !void {
        if (!context.manifest_published) return error.InvalidOrder;
        try context.record(.update_metadata);
        try std.testing.expectEqual(context.published_count, entries.len);
    }
};

const test_compaction = EdgeSegmentWindowCompaction(TestOps);

const test_entries = [_]TestOwnedEntry{
    .{ .id = 1, .edge_count = 3 },
    .{ .id = 2, .edge_count = 4 },
    .{ .id = 3, .edge_count = 5 },
    .{ .id = 4, .edge_count = 6 },
};

test "edge segment window compaction rejects invalid ranges before mutation" {
    var context = TestContext{};
    try std.testing.expectError(
        error.InvalidRecord,
        test_compaction.compact(&context, "target", &test_entries, 3, 2, 11),
    );
    try std.testing.expectEqual(@as(usize, 0), context.phase_count);
}

test "edge segment window compaction rejects an existing target before opening sources" {
    var context = TestContext{ .target_exists = true };
    try std.testing.expectError(
        error.AlreadyExists,
        test_compaction.compact(&context, "target", &test_entries, 1, 2, 9),
    );
    try std.testing.expectEqualSlices(TestPhase, &.{.path_exists}, context.recorded());
}

test "edge segment window compaction writes forward then reverse and cleans an unpublished target" {
    var context = TestContext{ .fail_at = .write_reverse };
    try std.testing.expectError(
        error.InjectedFailure,
        test_compaction.compact(&context, "target", &test_entries, 1, 2, 9),
    );
    try std.testing.expectEqualSlices(TestPhase, &.{
        .path_exists,
        .open_sources,
        .create_target,
        .write_forward,
        .write_reverse,
        .delete_target,
        .deinit_target,
        .deinit_sources,
    }, context.recorded());
    try std.testing.expectEqual(@as(usize, 1), context.target_deleted);
    try std.testing.expectEqual(@as(usize, 1), context.target_deinited);
    try std.testing.expectEqual(@as(usize, 1), context.sources_deinited);
}

test "edge segment window compaction replaces one interior window in order" {
    var context = TestContext{};
    try std.testing.expectEqual(
        @as(u64, 9),
        try test_compaction.compact(&context, "target", &test_entries, 1, 2, 9),
    );
    try std.testing.expectEqual(@as(usize, 3), context.published_count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 99, 4 }, &.{
        context.published_entries[0].id,
        context.published_entries[1].id,
        context.published_entries[2].id,
    });
    try std.testing.expectEqualStrings("target", context.published_entries[1].path);
    try std.testing.expectEqual(@as(usize, 0), context.target_deleted);
    try std.testing.expectEqual(@as(usize, 1), context.target_deinited);
    try std.testing.expectEqual(@as(usize, 1), context.sources_deinited);
}

test "edge segment window compaction publishes a full range as one entry" {
    var context = TestContext{};
    try std.testing.expectEqual(
        @as(u64, 18),
        try test_compaction.compact(&context, "full", &test_entries, 0, test_entries.len, 18),
    );
    try std.testing.expectEqual(@as(usize, 1), context.published_count);
    try std.testing.expectEqual(@as(u8, 99), context.published_entries[0].id);
    try std.testing.expectEqual(@as(u64, 18), context.published_entries[0].edge_count);
    try std.testing.expectEqualStrings("full", context.published_entries[0].path);
}

test "edge segment window compaction preserves the target after publication begins" {
    var context = TestContext{ .fail_at = .publish_manifest };
    try std.testing.expectError(
        error.InjectedFailure,
        test_compaction.compact(&context, "target", &test_entries, 1, 2, 9),
    );
    try std.testing.expectEqual(@as(usize, 0), context.target_deleted);
    try std.testing.expectEqual(@as(usize, 1), context.target_deinited);
    try std.testing.expectEqual(@as(usize, 1), context.sources_deinited);
}

test "edge segment window compaction updates metadata only after manifest publication" {
    var context = TestContext{ .fail_at = .update_metadata };
    try std.testing.expectError(
        error.InjectedFailure,
        test_compaction.compact(&context, "target", &test_entries, 1, 2, 9),
    );
    const publish_index = std.mem.indexOfScalar(TestPhase, context.recorded(), .publish_manifest).?;
    const metadata_index = std.mem.indexOfScalar(TestPhase, context.recorded(), .update_metadata).?;
    try std.testing.expect(publish_index < metadata_index);
    try std.testing.expect(context.manifest_published);
    try std.testing.expectEqual(@as(usize, 0), context.target_deleted);
}
