const std = @import("std");
const cc = @import("cc");

test "L2 FormalAuditTask schema is TinyKG-gated and reaches fail-closed runtime" {
    const allocator = std.testing.allocator;
    // Tool descriptions are independently allocated along with the returned
    // definition slice. Production owns them in a session arena; mirror that
    // lifecycle here instead of freeing only the outer slice.
    var definition_arena = std.heap.ArenaAllocator.init(allocator);
    defer definition_arena.deinit();
    const definition_allocator = definition_arena.allocator();
    const enabled_ctx = cc.tool_prompt_ctx.PromptContext{ .tinykg_enabled = true };
    const enabled = try cc.tools.toToolDefinitionsFull(definition_allocator, null, &enabled_ctx);
    const definition = findDefinition(enabled, "FormalAuditTask") orelse return error.MissingFormalAuditTask;
    try std.testing.expect(definition.deferred);
    const specs = definition.input_schema.prop_specs orelse return error.MissingFormalAuditSchema;
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    try std.testing.expectEqualStrings("root_task_id", specs[0].name);
    try std.testing.expectEqualStrings("integer", specs[0].type);
    try std.testing.expectEqualStrings("root_task_id", definition.input_schema.required.?[0]);

    const disabled_ctx = cc.tool_prompt_ctx.PromptContext{ .tinykg_enabled = false };
    const disabled = try cc.tools.toToolDefinitionsFull(definition_allocator, null, &disabled_ctx);
    try std.testing.expect(findDefinition(disabled, "FormalAuditTask") == null);

    const tool = cc.tools.getTool("FormalAuditTask") orelse return error.MissingFormalAuditTask;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const ctx = cc.tool_context.ToolContext{
        .allocator = allocator,
        .home_dir = root_buffer[0..root_len],
    };
    const receipt = try cc.tools.executeTool(tool, &ctx, "{\"root_task_id\":1}");
    defer allocator.free(receipt);
    const Probe = struct {
        schema_version: []const u8,
        artifact_bundle: struct {
            authoritative_raw_evidence: bool,
            persisted: bool,
        },
        pipeline: struct {
            admitted: bool,
            failure_kind: []const u8,
            telemetry_persisted: bool,
        },
    };
    var parsed = try std.json.parseFromSlice(Probe, allocator, receipt, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(cc.formal_task_audit.RECEIPT_SCHEMA, parsed.value.schema_version);
    try std.testing.expect(!parsed.value.pipeline.admitted);
    try std.testing.expect(parsed.value.artifact_bundle.authoritative_raw_evidence);
    try std.testing.expect(parsed.value.artifact_bundle.persisted);
    // A host may intentionally set the deployment env while running tests.
    // With no KgClient this is either absent config or the next fail-closed
    // boundary; it can never become an admission.
    try std.testing.expect(
        std.mem.eql(u8, parsed.value.pipeline.failure_kind, "config_missing") or
            std.mem.eql(u8, parsed.value.pipeline.failure_kind, "config_invalid") or
            std.mem.eql(u8, parsed.value.pipeline.failure_kind, "tinykg_unavailable"),
    );
    try std.testing.expect(parsed.value.pipeline.telemetry_persisted);

    try std.testing.expectError(
        error.InvalidArguments,
        cc.tools.executeTool(tool, &ctx, "{}"),
    );
}

fn findDefinition(definitions: []const cc.json_mod.ToolDefinition, name: []const u8) ?cc.json_mod.ToolDefinition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

test "L2 native formal audit consumes a real TinyKG task snapshot" {
    const raw_checker = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_PATH") orelse return error.SkipZigTest;
    const raw_hash = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_SHA256") orelse return error.SkipZigTest;
    const checker_path = std.mem.span(raw_checker);
    const hash_text = std.mem.span(raw_hash);
    if (hash_text.len != 64) return error.SkipZigTest;
    var expected_sha256: [64]u8 = undefined;
    @memcpy(&expected_sha256, hash_text);

    const allocator = std.testing.allocator;
    const tinykg_bin = findTinyKg(allocator) orelse return error.SkipZigTest;
    defer allocator.free(tinykg_bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const store_path = try std.fmt.allocPrint(allocator, "{s}/formal-real.kg", .{root});
    defer allocator.free(store_path);
    var kg = try cc.kg_client.KgClient.init(allocator, .{
        .home = root,
        .domain = "formal-audit-l2",
        .config_bin = tinykg_bin,
        .config_store = store_path,
        .env_bin = "",
        .env_store = "",
        .env_dev = "",
    });
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const root_task_id = try kg.createTask("real TinyKG snapshot formal audit root", "task");
    // Current TinyKG deployments may predate the task-snapshot capability.
    // Keep that product dependency visible as an explicit skip instead of
    // fabricating a KgClient or treating a fixture as real integration.
    const capability_probe = kg.taskSnapshot(root_task_id) catch |err| {
        std.debug.print("formal TinyKG L2 skipped: task-snapshot unavailable ({s}); TinyKG must ship tinykg-task-snapshot-v1\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    kg.allocator.free(capability_probe);

    const telemetry_path = try std.fmt.allocPrint(allocator, "{s}/events-v1.jsonl", .{root});
    defer allocator.free(telemetry_path);
    const args = try std.fmt.allocPrint(allocator, "{{\"root_task_id\":{d}}}", .{root_task_id});
    defer allocator.free(args);
    const ctx = cc.tool_context.ToolContext{
        .allocator = allocator,
        .home_dir = root,
        .kg = &kg,
    };
    const receipt = try cc.formal_task_audit.executeWithConfig(
        &ctx,
        args,
        .{ .checker_path = checker_path, .expected_sha256 = expected_sha256 },
        telemetry_path,
    );
    defer allocator.free(receipt);
    const Probe = struct {
        identity: ?struct { root_task_id: u64, snapshot_bytes: usize },
        checker: ?struct { provenance: ?struct { schema_version: []const u8 } },
        pipeline: struct {
            admitted: bool,
            telemetry_persisted: bool,
            failure_kind: []const u8,
            source_error: ?[]const u8,
            source_detail: ?[]const u8,
        },
        transaction: struct { commit: []const u8 },
    };
    var parsed = try std.json.parseFromSlice(Probe, allocator, receipt, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!parsed.value.pipeline.admitted) std.debug.print("formal real TinyKG receipt: {s}\n", .{receipt});
    const identity = parsed.value.identity orelse return error.MissingFormalIdentity;
    const checker = parsed.value.checker orelse return error.MissingFormalChecker;
    const checker_provenance = checker.provenance orelse return error.MissingFormalProvenance;
    try std.testing.expectEqual(root_task_id, identity.root_task_id);
    try std.testing.expect(identity.snapshot_bytes > 0);
    try std.testing.expectEqualStrings(cc.formal_provenance.MANIFEST_SCHEMA, checker_provenance.schema_version);
    try std.testing.expect(parsed.value.pipeline.admitted);
    try std.testing.expect(parsed.value.pipeline.telemetry_persisted);
    try std.testing.expectEqualStrings("not_applicable_read_only", parsed.value.transaction.commit);
}

test "L2 native Lean derives reversible memory supersession from observed nodes" {
    const raw_checker = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_PATH") orelse return error.SkipZigTest;
    const raw_hash = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_SHA256") orelse return error.SkipZigTest;
    const checker_path = std.mem.span(raw_checker);
    const hash_text = std.mem.span(raw_hash);
    if (hash_text.len != 64) return error.SkipZigTest;
    var expected_sha256: [64]u8 = undefined;
    @memcpy(&expected_sha256, hash_text);

    const revision = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const snapshot =
        \\{"schema_version":"tinykg-memory-migration-snapshot-v1","revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","bounded":true,"truncated":false,"source":{"id":11,"kind":"observation","schema_type":"lesson","current_generation":true,"retrieval_excluded":false,"contradicted":false},"replacement":{"id":12,"kind":"observation","schema_type":"lesson","current_generation":true,"retrieval_excluded":false,"contradicted":false},"evidence":{"id":13,"kind":"verification","schema_type":"verification","current_generation":true,"retrieval_excluded":false,"contradicted":false},"deprecated_edge_exists":false}
    ;
    const proposal =
        \\{"schema_version":"metacodes-memory-migration-proposal-v1","operation":"memory_supersede_existing","source_id":11,"replacement_id":12,"evidence_id":13,"effect":"add_deprecated_by_and_exclude_source","rollback":"remove_deprecated_by_and_restore_source","snapshot_revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}
    ;
    var admitted = try cc.formal_memory_migration.evaluate(
        std.testing.allocator,
        snapshot,
        proposal,
        .{ .checker_path = checker_path, .expected_sha256 = expected_sha256 },
        null,
    );
    defer admitted.deinit();
    try std.testing.expect(admitted.checkerAdmitted());
    try std.testing.expect(std.mem.indexOf(u8, admitted.request, "preserves_tasks") == null);
    try std.testing.expect(std.mem.indexOf(u8, admitted.request, "preserves_evidence") == null);
    try std.testing.expectEqual(
        cc.formal_memory_migration.CommitGate.cas_unavailable,
        admitted.commitGate(revision, false),
    );
    try std.testing.expectEqual(
        cc.formal_memory_migration.CommitGate.stale_revision,
        admitted.commitGate("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", true),
    );
    try std.testing.expectEqual(
        cc.formal_memory_migration.CommitGate.ready_for_cas,
        admitted.commitGate(revision, true),
    );

    // Same proposal, but the observed replacement belongs to a different
    // schema type. Zig transmits the records unchanged; Lean must block it.
    const schema_drift_snapshot =
        \\{"schema_version":"tinykg-memory-migration-snapshot-v1","revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","bounded":true,"truncated":false,"source":{"id":11,"kind":"observation","schema_type":"lesson","current_generation":true,"retrieval_excluded":false,"contradicted":false},"replacement":{"id":12,"kind":"observation","schema_type":"bug","current_generation":true,"retrieval_excluded":false,"contradicted":false},"evidence":{"id":13,"kind":"verification","schema_type":"verification","current_generation":true,"retrieval_excluded":false,"contradicted":false},"deprecated_edge_exists":false}
    ;
    var blocked = try cc.formal_memory_migration.evaluate(
        std.testing.allocator,
        schema_drift_snapshot,
        proposal,
        .{ .checker_path = checker_path, .expected_sha256 = expected_sha256 },
        null,
    );
    defer blocked.deinit();
    try std.testing.expect(!blocked.checkerAdmitted());
    const verdict = blocked.invocation.verdict orelse return error.MissingMemoryVerdict;
    try std.testing.expect(!verdict.admitted);
    try std.testing.expectEqual(
        cc.formal_memory_migration.CommitGate.checker_blocked,
        blocked.commitGate(revision, true),
    );
    var found_schema_reason = false;
    for (verdict.reasons) |reason| {
        if (reason == .schema_not_preserved) found_schema_reason = true;
    }
    try std.testing.expect(found_schema_reason);

    // Optional persistent paper artifact. Normal unit tests remain hermetic;
    // a release/evaluation run opts in with one absolute index path.
    if (std.c.getenv("METACODES_TEST_FORMAL_EVIDENCE_PATH")) |raw_path| {
        const evidence_path = std.mem.span(raw_path);
        if (std.fs.path.isAbsolute(evidence_path)) {
            var persisted = try cc.formal_memory_migration.persistMechanismEvidence(
                std.testing.allocator,
                evidence_path,
                &admitted,
                cc.util_time.nowWallNs(),
                cc.util_time.nowNs(),
            );
            defer persisted.deinit();
            try std.testing.expect(persisted.receipt.len > 0);
            const parent = std.fs.path.dirname(evidence_path) orelse return error.InvalidEvidencePath;
            const bundle_dir = try std.fmt.allocPrint(
                std.testing.allocator,
                "{s}/{s}/{s}",
                .{ parent, cc.formal_artifact_store.ARTIFACT_DIR_NAME, persisted.event_id[0..] },
            );
            defer std.testing.allocator.free(bundle_dir);
            const verified_bundle = try cc.formal_artifact_store.verifyBundle(
                std.testing.allocator,
                bundle_dir,
            );
            try std.testing.expectEqualStrings(
                persisted.manifest_sha256[0..],
                verified_bundle.manifest_sha256[0..],
            );
            var blocked_evidence = try cc.formal_memory_migration.persistMechanismEvidence(
                std.testing.allocator,
                evidence_path,
                &blocked,
                cc.util_time.nowWallNs(),
                cc.util_time.nowNs(),
            );
            defer blocked_evidence.deinit();
            const blocked_bundle_dir = try std.fmt.allocPrint(
                std.testing.allocator,
                "{s}/{s}/{s}",
                .{ parent, cc.formal_artifact_store.ARTIFACT_DIR_NAME, blocked_evidence.event_id[0..] },
            );
            defer std.testing.allocator.free(blocked_bundle_dir);
            const verified_blocked = try cc.formal_artifact_store.verifyBundle(
                std.testing.allocator,
                blocked_bundle_dir,
            );
            try std.testing.expectEqualStrings(
                blocked_evidence.manifest_sha256[0..],
                verified_blocked.manifest_sha256[0..],
            );
        }
    }
}

fn findTinyKg(allocator: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("METACODES_KG_BIN")) |raw| {
        const path = std.mem.span(raw);
        if (isExecutable(path)) return allocator.dupe(u8, path) catch null;
    }
    const raw_home = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(raw_home);
    const candidates = [_][]const u8{
        "prj/cc-t2z/metacodes/zig-out/vendor/tinykg/tinykg",
        "prj/tinykg/zig-out/bin/tinykg",
    };
    for (candidates) |relative| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, relative }) catch continue;
        if (isExecutable(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn isExecutable(path: []const u8) bool {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return false;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return std.c.access(buffer[0..path.len :0].ptr, std.c.X_OK) == 0;
}
