const std = @import("std");
const cc = @import("cc");

const revision_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const revision_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const build_id = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

const Fake = struct {
    allocator: std.mem.Allocator,
    capabilities_ok: bool = true,
    drift_snapshot: bool = false,
    mismatched_snapshot_ids: bool = false,
    malformed_receipt: bool = false,
    invalid_post_state: bool = false,
    snapshot_calls: usize = 0,
    commit_calls: usize = 0,
    post_state_calls: usize = 0,
    last_commit_request: ?[]u8 = null,

    fn deinit(self: *Fake) void {
        if (self.last_commit_request) |bytes| self.allocator.free(bytes);
    }

    fn transport(self: *Fake) cc.kg_memory_migration_adapter.StoragePrimitives {
        return .{
            .ptr = self,
            .capabilities_fn = capabilities,
            .snapshot_fn = snapshot,
            .commit_fn = commit,
            .post_state_fn = postState,
        };
    }

    fn cast(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn capabilities(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self = cast(ptr);
        const rollback = if (self.capabilities_ok)
            ",\"tinykg-memory-migration-rollback-v1\""
        else
            "";
        return std.fmt.allocPrint(
            allocator,
            "{{\"schema_version\":\"tinykg-capabilities-v1\",\"capabilities\":[\"tinykg-memory-migration-snapshot-v1\",\"tinykg-memory-migration-commit-v1\"{s}],\"build_id\":\"{s}\"}}",
            .{ rollback, build_id },
        );
    }

    fn snapshot(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        source: cc.kg_memory_migration_adapter.Source,
    ) ![]u8 {
        const self = cast(ptr);
        self.snapshot_calls += 1;
        const source_schema = if (self.drift_snapshot and self.snapshot_calls == 2) "drifted" else "lesson";
        const observed_source_id = if (self.mismatched_snapshot_ids) source.source_id + 100 else source.source_id;
        return std.fmt.allocPrint(
            allocator,
            "{{\"schema_version\":\"tinykg-memory-migration-snapshot-v1\",\"revision\":\"{s}\",\"bounded\":true,\"truncated\":false,\"source\":{{\"id\":{d},\"kind\":\"observation\",\"schema_type\":\"{s}\",\"current_generation\":true,\"retrieval_excluded\":false,\"contradicted\":false}},\"replacement\":{{\"id\":{d},\"kind\":\"observation\",\"schema_type\":\"lesson\",\"current_generation\":true,\"retrieval_excluded\":false,\"contradicted\":false}},\"evidence\":{{\"id\":{d},\"kind\":\"verification\",\"schema_type\":\"verification\",\"current_generation\":true,\"retrieval_excluded\":false,\"contradicted\":false}},\"deprecated_edge_exists\":false}}",
            .{ revision_a, observed_source_id, source_schema, source.replacement_id, source.evidence_id },
        );
    }

    fn commit(ptr: *anyopaque, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
        const self = cast(ptr);
        self.commit_calls += 1;
        self.last_commit_request = try self.allocator.dupe(u8, request);
        if (self.malformed_receipt) return allocator.dupe(u8, "{\"committed\":true}");

        const Request = struct {
            request_id: []const u8,
            proposal_sha256: []const u8,
            checker_verdict_sha256: []const u8,
            snapshot_sha256: []const u8,
            source_id: u64,
            replacement_id: u64,
            evidence_id: u64,
        };
        var parsed = try std.json.parseFromSlice(Request, allocator, request, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return std.fmt.allocPrint(
            allocator,
            "{{\"schema_version\":\"tinykg-memory-migration-receipt-v1\",\"operation\":\"memory_supersede_existing\",\"request_id\":\"{s}\",\"proposal_sha256\":\"{s}\",\"checker_verdict_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"previous_revision\":\"{s}\",\"revision\":\"{s}\",\"source_id\":{d},\"replacement_id\":{d},\"evidence_id\":{d},\"effect\":\"add_deprecated_by_and_exclude_source\",\"rollback\":\"remove_deprecated_by_and_restore_source\",\"committed\":true,\"rollback_token\":\"rollback-token-1\",\"build_id\":\"{s}\"}}",
            .{ parsed.value.request_id, parsed.value.proposal_sha256, parsed.value.checker_verdict_sha256, parsed.value.snapshot_sha256, revision_a, revision_b, parsed.value.source_id, parsed.value.replacement_id, parsed.value.evidence_id, build_id },
        );
    }

    fn postState(ptr: *anyopaque, allocator: std.mem.Allocator, rollback_token: []const u8) ![]u8 {
        const self = cast(ptr);
        self.post_state_calls += 1;
        return std.fmt.allocPrint(
            allocator,
            "{{\"schema_version\":\"tinykg-memory-migration-post-state-v1\",\"revision\":\"{s}\",\"source_id\":11,\"replacement_id\":12,\"evidence_id\":13,\"deprecated_edge_exists\":true,\"source_retrieval_excluded\":{s},\"replacement_current_generation\":true,\"evidence_present\":true,\"rollback_token\":\"{s}\",\"build_id\":\"{s}\"}}",
            .{ revision_b, if (self.invalid_post_state) "false" else "true", rollback_token, build_id },
        );
    }
};

fn checkerConfig() ?cc.formal_runtime.Config {
    const raw_checker = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_PATH") orelse return null;
    const raw_hash = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_SHA256") orelse return null;
    const hash = std.mem.span(raw_hash);
    if (hash.len != 64) return null;
    var expected: [64]u8 = undefined;
    @memcpy(&expected, hash);
    return .{ .checker_path = std.mem.span(raw_checker), .expected_sha256 = expected };
}

test "L2 governed memory transaction crosses TinyKG sensor Lean checker CAS receipt and post-state" {
    const config = checkerConfig() orelse return error.SkipZigTest;
    var fake = Fake{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var result = try cc.kg_memory_migration_adapter.execute(
        std.testing.allocator,
        fake.transport(),
        .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
        config,
        null,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), fake.snapshot_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.commit_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.post_state_calls);
    try std.testing.expect(std.mem.indexOf(u8, fake.last_commit_request.?, result.evaluation.proposal_sha256[0..]) != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.last_commit_request.?, "checker_verdict_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.pipeline_receipt, "\"atomic_commit_verified\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.pipeline_receipt, "\"quality_evidence\":false") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const index_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/events.jsonl", .{root});
    defer std.testing.allocator.free(index_path);
    var persisted = try cc.kg_memory_migration_adapter.persistEvidence(
        std.testing.allocator,
        index_path,
        &result,
        cc.util_time.nowWallNs(),
        cc.util_time.nowNs(),
    );
    defer persisted.deinit();
    const bundle_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/{s}",
        .{ root, cc.formal_artifact_store.ARTIFACT_DIR_NAME, persisted.event_id[0..] },
    );
    defer std.testing.allocator.free(bundle_path);
    const verified = try cc.formal_artifact_store.verifyBundle(std.testing.allocator, bundle_path);
    // 13 files: the transaction has no separate raw sensor source file; both
    // validated snapshots, checker artifacts, commit and post-state are bound.
    try std.testing.expectEqual(@as(usize, 13), verified.files_verified);
    try std.testing.expectEqualSlices(u8, persisted.manifest_sha256[0..], verified.manifest_sha256[0..]);
}

test "L2 governed memory transaction fails closed before CAS when capability or reobservation drifts" {
    const config = checkerConfig() orelse return error.SkipZigTest;
    var unavailable = Fake{ .allocator = std.testing.allocator, .capabilities_ok = false };
    defer unavailable.deinit();
    try std.testing.expectError(
        error.AtomicMigrationUnavailable,
        cc.kg_memory_migration_adapter.execute(
            std.testing.allocator,
            unavailable.transport(),
            .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
            config,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), unavailable.commit_calls);

    var drift = Fake{ .allocator = std.testing.allocator, .drift_snapshot = true };
    defer drift.deinit();
    try std.testing.expectError(
        error.SnapshotDrift,
        cc.kg_memory_migration_adapter.execute(
            std.testing.allocator,
            drift.transport(),
            .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
            config,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), drift.commit_calls);
}

test "L2 prepared memory migration freezes exact host commit bytes before side effect" {
    const config = checkerConfig() orelse return error.SkipZigTest;
    var fake = Fake{ .allocator = std.testing.allocator };
    defer fake.deinit();
    var prepared = try cc.kg_memory_migration_adapter.prepare(
        std.testing.allocator,
        fake.transport(),
        .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
        config,
        null,
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.snapshot_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.commit_calls);
    try std.testing.expect(std.mem.indexOf(u8, prepared.commit_request, "\"expected_revision\":\"aaaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.commit_request, "\"checker_verdict_sha256\":") != null);

    var result = try cc.kg_memory_migration_adapter.commitPrepared(
        fake.transport(),
        &prepared,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.commit_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.post_state_calls);
}

test "L2 prepared memory migration is single-attempt even after indeterminate commit" {
    const config = checkerConfig() orelse return error.SkipZigTest;
    var fake = Fake{ .allocator = std.testing.allocator, .malformed_receipt = true };
    defer fake.deinit();
    var prepared = try cc.kg_memory_migration_adapter.prepare(
        std.testing.allocator,
        fake.transport(),
        .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
        config,
        null,
    );
    defer prepared.deinit();
    try std.testing.expectError(
        error.IndeterminateCommit,
        cc.kg_memory_migration_adapter.commitPrepared(fake.transport(), &prepared),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.commit_calls);
    try std.testing.expectError(
        error.PreparedAlreadyConsumed,
        cc.kg_memory_migration_adapter.commitPrepared(fake.transport(), &prepared),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.commit_calls);
}

test "L2 governed memory transaction rejects a sensor snapshot not bound to requested ids" {
    const config = checkerConfig() orelse return error.SkipZigTest;
    var fake = Fake{ .allocator = std.testing.allocator, .mismatched_snapshot_ids = true };
    defer fake.deinit();
    try std.testing.expectError(
        error.SnapshotSourceMismatch,
        cc.kg_memory_migration_adapter.execute(
            std.testing.allocator,
            fake.transport(),
            .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
            config,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.commit_calls);
}

test "L2 governed memory transaction refuses forged receipt and invalid post-state" {
    const config = checkerConfig() orelse return error.SkipZigTest;
    var forged = Fake{ .allocator = std.testing.allocator, .malformed_receipt = true };
    defer forged.deinit();
    try std.testing.expectError(
        error.IndeterminateCommit,
        cc.kg_memory_migration_adapter.execute(
            std.testing.allocator,
            forged.transport(),
            .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
            config,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), forged.commit_calls);
    try std.testing.expectEqual(@as(usize, 0), forged.post_state_calls);

    var invalid_post = Fake{ .allocator = std.testing.allocator, .invalid_post_state = true };
    defer invalid_post.deinit();
    try std.testing.expectError(
        error.IndeterminateCommit,
        cc.kg_memory_migration_adapter.execute(
            std.testing.allocator,
            invalid_post.transport(),
            .{ .source_id = 11, .replacement_id = 12, .evidence_id = 13 },
            config,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), invalid_post.commit_calls);
    try std.testing.expectEqual(@as(usize, 1), invalid_post.post_state_calls);
}
