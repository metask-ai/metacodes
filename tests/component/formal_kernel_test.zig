const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const FORMAL_TOOL_SSE_TEMPLATE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"formal-1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"formal-call\",\"name\":\"FormalAuditTask\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"root_task_id\\\":__ROOT_ID__}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FORMAL_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"formal-2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"formal audit receipt observed\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

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

test "L2 headless formal tool crosses registry, TinyKG sensor, compiled Lean, and receipt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const raw_checker = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_PATH") orelse return error.SkipZigTest;
    const raw_hash = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_SHA256") orelse return error.SkipZigTest;
    // This L2 intentionally exercises the production host-config seam. Avoid
    // clobbering a caller's deployment pin inside the aggregate test process.
    if (std.c.getenv("METACODES_FORMAL_KERNEL_PATH") != null or
        std.c.getenv("METACODES_FORMAL_KERNEL_SHA256") != null)
        return error.SkipZigTest;
    const checker_path = std.mem.span(raw_checker);
    const checker_hash = std.mem.span(raw_hash);
    if (!std.fs.path.isAbsolute(checker_path) or checker_hash.len != 64) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const checker_path_z = try allocator.dupeZ(u8, checker_path);
    defer allocator.free(checker_path_z);
    const checker_hash_z = try allocator.dupeZ(u8, checker_hash);
    defer allocator.free(checker_hash_z);
    if (setenv("METACODES_FORMAL_KERNEL_PATH", checker_path_z.ptr, 1) != 0)
        return error.SkipZigTest;
    defer _ = unsetenv("METACODES_FORMAL_KERNEL_PATH");
    if (setenv("METACODES_FORMAL_KERNEL_SHA256", checker_hash_z.ptr, 1) != 0)
        return error.SkipZigTest;
    defer _ = unsetenv("METACODES_FORMAL_KERNEL_SHA256");

    const tinykg_bin = findTinyKg(allocator) orelse return error.SkipZigTest;
    defer allocator.free(tinykg_bin);
    if (std.mem.indexOfScalar(u8, tinykg_bin, '"') != null) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const store_path = try std.fmt.allocPrint(allocator, "{s}/formal-headless.kg", .{root});
    defer allocator.free(store_path);
    var kg = try cc.kg_client.KgClient.init(allocator, .{
        .home = root,
        .domain = "formal-headless-l2",
        .config_bin = tinykg_bin,
        .config_store = store_path,
        .env_bin = "",
        .env_store = "",
        .env_dev = "",
    });
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const root_task_id = try kg.createTask("headless formal audit root", "task");
    try std.testing.expectEqual(cc.kg_client.TaskStatus.open, try kg.taskStatus(root_task_id));

    // The currently deployed TinyKG does not yet expose task-snapshot. Keep
    // that external dependency out of this metacodes mechanism L2 by wrapping
    // only this read command with a canonical fixture; every other command is
    // delegated to the real local TinyKG binary and isolated temp store.
    const wrapper = try installTaskSnapshotWrapper(allocator, root, tinykg_bin, root_task_id);
    allocator.free(kg.bin_path.?);
    kg.bin_path = wrapper; // KgClient owns the wrapper path from here.

    var id_buffer: [24]u8 = undefined;
    const root_id_text = try std.fmt.bufPrint(&id_buffer, "{d}", .{root_task_id});
    const tool_sse = try std.mem.replaceOwned(
        u8,
        allocator,
        FORMAL_TOOL_SSE_TEMPLATE,
        "__ROOT_ID__",
        root_id_text,
    );
    defer allocator.free(tool_sse);
    const responses = [_][]const u8{ tool_sse, FORMAL_FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "test-key",
        "claude-sonnet-4-20250514",
        url,
    );
    defer client.deinit();

    var definition_arena = std.heap.ArenaAllocator.init(allocator);
    defer definition_arena.deinit();
    const prompt_ctx = cc.tool_prompt_ctx.PromptContext{ .tinykg_enabled = true };
    const definitions = try cc.tools.toToolDefinitionsFull(
        definition_arena.allocator(),
        null,
        &prompt_ctx,
    );
    var activated = std.StringHashMap(void).init(allocator);
    defer activated.deinit();
    try activated.put("FormalAuditTask", {});

    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "Audit the bounded task graph and report the formal receipt.");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        definitions,
        &permission,
        .{
            .max_turns = 2,
            .kg = &kg,
            .home_dir = root,
            .activated_tools = &activated,
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());

    var receipt_bytes: ?[]const u8 = null;
    for (conversation.messages.items) |message| for (message.blocks) |block| switch (block) {
        .tool_result => |tool_result| if (std.mem.eql(u8, tool_result.tool_use_id, "formal-call")) {
            try std.testing.expect(!tool_result.is_error);
            receipt_bytes = tool_result.content;
        },
        else => {},
    };
    const receipt = receipt_bytes orelse return error.MissingFormalToolResult;
    const ReceiptProbe = struct {
        schema_version: []const u8,
        identity: ?struct { root_task_id: u64, snapshot_revision: []const u8 },
        checker: ?struct {
            expected_version: []const u8,
            actual_sha256: ?[]const u8,
            runtime_failure_kind: ?[]const u8,
        },
        verdict: ?struct { checker_admitted: bool, reason_codes: []const []const u8 },
        pipeline: struct { admitted: bool, failure_kind: []const u8, telemetry_persisted: bool },
        transaction: struct { commit: []const u8 },
    };
    var parsed = try std.json.parseFromSlice(
        ReceiptProbe,
        allocator,
        receipt,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(cc.formal_task_audit.RECEIPT_SCHEMA, parsed.value.schema_version);
    const identity = parsed.value.identity orelse return error.MissingFormalIdentity;
    const checker = parsed.value.checker orelse return error.MissingFormalChecker;
    const verdict = parsed.value.verdict orelse return error.MissingFormalVerdict;
    try std.testing.expectEqual(root_task_id, identity.root_task_id);
    try std.testing.expectEqual(@as(usize, 64), identity.snapshot_revision.len);
    try std.testing.expectEqualStrings(cc.formal_runtime.CHECKER_VERSION, checker.expected_version);
    try std.testing.expectEqualStrings(checker_hash, checker.actual_sha256 orelse return error.MissingFormalCheckerHash);
    try std.testing.expectEqualStrings("none", checker.runtime_failure_kind orelse return error.MissingFormalFailureKind);
    try std.testing.expect(verdict.checker_admitted);
    try std.testing.expectEqual(@as(usize, 0), verdict.reason_codes.len);
    if (!parsed.value.pipeline.admitted) std.debug.print("headless formal receipt: {s}\n", .{receipt});
    try std.testing.expect(parsed.value.pipeline.admitted);
    try std.testing.expectEqualStrings("none", parsed.value.pipeline.failure_kind);
    try std.testing.expect(parsed.value.pipeline.telemetry_persisted);
    try std.testing.expectEqualStrings("not_applicable_read_only", parsed.value.transaction.commit);

    // The formal tool is a read-only gate: invoking it through the real agent
    // path must not advance the canonical task lifecycle.
    try std.testing.expectEqual(cc.kg_client.TaskStatus.open, try kg.taskStatus(root_task_id));

    const final_text = try cc.repl_headless.lastAssistantText(&conversation, allocator);
    defer allocator.free(final_text);
    try std.testing.expectEqualStrings("formal audit receipt observed", final_text);
    const result_line = try cc.repl_headless.buildResultLine(
        allocator,
        final_text,
        result,
        &cc.app_module.UsageTotals{},
        "fixture-model",
    );
    defer allocator.free(result_line);
    try std.testing.expect(std.mem.indexOf(u8, result_line, "formal audit receipt observed") != null);
    try std.testing.expectEqual(@as(u8, 0), cc.repl_headless.exitCodeFor(result.stop_reason));

    // The same registry entry must fail closed before checker execution when
    // the host pin is tampered. This is not a model-visible override: only the
    // process owner can configure it, and the tool schema exposes no path/hash.
    var tampered_hash = try allocator.dupeZ(u8, checker_hash);
    defer allocator.free(tampered_hash);
    tampered_hash[0] = if (tampered_hash[0] == '0') '1' else '0';
    try std.testing.expectEqual(@as(c_int, 0), setenv(
        "METACODES_FORMAL_KERNEL_SHA256",
        tampered_hash.ptr,
        1,
    ));
    const formal_tool = cc.tools.getTool("FormalAuditTask") orelse return error.MissingFormalAuditTask;
    const args = try std.fmt.allocPrint(allocator, "{{\"root_task_id\":{d}}}", .{root_task_id});
    defer allocator.free(args);
    const tool_ctx = cc.tool_context.ToolContext{
        .allocator = allocator,
        .home_dir = root,
        .kg = &kg,
    };
    const blocked_receipt = try cc.tools.executeTool(formal_tool, &tool_ctx, args);
    defer allocator.free(blocked_receipt);
    const BlockedProbe = struct {
        checker: ?struct { runtime_failure_kind: ?[]const u8 },
        pipeline: struct { admitted: bool, failure_kind: []const u8, telemetry_persisted: bool },
    };
    var blocked = try std.json.parseFromSlice(
        BlockedProbe,
        allocator,
        blocked_receipt,
        .{ .ignore_unknown_fields = true },
    );
    defer blocked.deinit();
    const blocked_checker = blocked.value.checker orelse return error.MissingFormalChecker;
    try std.testing.expect(!blocked.value.pipeline.admitted);
    try std.testing.expectEqualStrings("runtime_failure", blocked.value.pipeline.failure_kind);
    try std.testing.expectEqualStrings(
        "checker_hash_mismatch",
        blocked_checker.runtime_failure_kind orelse return error.MissingFormalFailureKind,
    );
    try std.testing.expect(blocked.value.pipeline.telemetry_persisted);
    try std.testing.expectEqual(cc.kg_client.TaskStatus.open, try kg.taskStatus(root_task_id));
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

fn installTaskSnapshotWrapper(
    allocator: std.mem.Allocator,
    root: []const u8,
    real_tinykg: []const u8,
    root_task_id: u64,
) ![]u8 {
    const task_text = "headless formal audit root";
    const revision = "abababababababababababababababababababababababababababababababab";
    const snapshot = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"tinykg-task-snapshot-v1\",\"root_id\":{d},\"revision\":\"{s}\",\"summary\":{{\"task_count\":1,\"hierarchy_edge_count\":0,\"dependency_edge_count\":0,\"evidence_count\":0,\"verified_by_edge_count\":0,\"used_text_bytes\":{d},\"truncated\":false,\"truncate_reason\":null,\"max_tasks\":256,\"max_edges\":1024,\"max_chars\":200000}},\"tasks\":[{{\"id\":{d},\"status\":\"open\",\"claimed_by\":null,\"text\":\"{s}\"}}],\"hierarchy\":[],\"dependencies\":[],\"evidence\":[],\"verified_by\":[]}}",
        .{ root_task_id, revision, task_text.len, root_task_id, task_text },
    );
    defer allocator.free(snapshot);
    const wrapper = try std.fmt.allocPrint(allocator, "{s}/tinykg-formal-snapshot", .{root});
    errdefer allocator.free(wrapper);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nif [ \"$1\" = \"task-snapshot\" ]; then printf '%s' '{s}'; exit 0; fi\nexec \"{s}\" \"$@\"\n",
        .{ snapshot, real_tinykg },
    );
    defer allocator.free(script);
    try overwriteFile(allocator, wrapper, script);
    const wrapper_z = try allocator.dupeZ(u8, wrapper);
    defer allocator.free(wrapper_z);
    if (std.c.chmod(wrapper_z.ptr, 0o700) != 0) return error.SkipZigTest;
    return wrapper;
}

fn overwriteFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "w") orelse return error.WriteFailed;
    defer _ = std.c.fclose(file);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len)
        return error.WriteFailed;
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
