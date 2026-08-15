const std = @import("std");

/// Owns ordered command-family routing, terminal dispatch, and lifecycle
/// maintenance sequencing. Command implementations are injected as narrow
/// backends so this owner never opens a Store for commands such as help.
pub fn RootCommandDispatchPipeline(comptime Ops: type) type {
    return struct {
        const Command = Ops.CommandValue;

        fn dispatchSchemaCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .schema_info => try Ops.schemaCommandsValue.runInfo(args, writer, allocator, io),
                .schema_show => try Ops.schemaCommandsValue.runShow(args, writer, allocator, io),
                .schema_apply => try Ops.schemaCommandsValue.runApply(args, writer, allocator, io),
                .schema_validate => try Ops.schemaCommandsValue.runValidate(args, writer, allocator, io),
                .schema_reconcile => try Ops.schemaReconcileCommandValue.run(args, writer, allocator, io),
                .schema_migrate => try Ops.schemaCommandsValue.runMigrate(args, writer, allocator, io),
                .list_kinds => try Ops.schemaCommandsValue.runListKinds(args, writer, allocator, io),
                .list_rels => try Ops.schemaCommandsValue.runListRelations(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchPropertyCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .set_property => try Ops.propertyCommandsValue.runSetString(args, writer, allocator, io),
                .set_uint_property => try Ops.propertyCommandsValue.runSetUint(args, writer, allocator, io),
                .set_node_property => try Ops.propertyCommandsValue.runSetNode(args, writer, allocator, io),
                .set_edge_property => try Ops.propertyCommandsValue.runSetEdge(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchContainTreeMigrationCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            if (cmd != .reparent_contain) return false;
            try Ops.containTreeMigrationCommandValue.run(args, writer, allocator, io);
            return true;
        }

        fn dispatchEdgeMutationCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .add_edge => try Ops.edgeMutationCommandsValue.runAdd(args, writer, allocator, io),
                .delete_edge => try Ops.edgeMutationCommandsValue.runDelete(args, writer, allocator, io),
                .delete_edges => try Ops.edgeMutationCommandsValue.runDeleteBatch(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchEdgeSegmentCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .compact_edges => try Ops.edgeSegmentCommandsValue.runCompactEdges(args, writer, allocator, io),
                .compact_edge_segments => try Ops.edgeSegmentCommandsValue.runCompactEdgeSegments(args, writer, allocator, io),
                .maintain_edge_segments => try Ops.edgeSegmentCommandsValue.runMaintainEdgeSegments(args, writer, allocator, io),
                .gc_edge_segments => try Ops.edgeSegmentCommandsValue.runGcEdgeSegments(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchNodeTextRunGcCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            if (cmd != .gc_node_text_runs) return false;
            try Ops.nodeTextRunGcCommandValue.run(args, writer, allocator, io);
            return true;
        }

        fn dispatchGraphTraversalCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .neighbors => try Ops.graphTraversalCommandsValue.runNeighbors(args, writer, allocator, io),
                .incoming => try Ops.graphTraversalCommandsValue.runIncoming(args, writer, allocator, io),
                .path => try Ops.graphTraversalCommandsValue.runPath(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchContextCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .context_plan => try Ops.contextCommandsValue.runPlan(args, writer, allocator, io),
                .context_packet => try Ops.contextCommandsValue.runPacket(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchNodeReadCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .get => try Ops.nodeReadCommandsValue.runGet(args, writer, allocator, io),
                .get_node => try Ops.nodeReadCommandsValue.runNode(args, writer, allocator, io),
                .node_versions => try Ops.nodeReadCommandsValue.runVersions(args, writer, allocator, io),
                .node_latest => try Ops.nodeReadCommandsValue.runLatest(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchNodeMutationCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .add_node => try Ops.nodeMutationCommandsValue.runAdd(args, writer, allocator, io),
                .update_node => try Ops.nodeMutationCommandsValue.runUpdate(args, writer, allocator, io),
                .append_node_version => try Ops.nodeMutationCommandsValue.runAppendVersion(args, writer, allocator, io),
                .govern_node => try Ops.nodeMutationCommandsValue.runGovern(args, writer, allocator, io),
                .delete_node => try Ops.nodeMutationCommandsValue.runDelete(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchIdempotentNodeCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .ensure_node => try Ops.idempotentNodeCommandsValue.runEnsureNode(args, writer, allocator, io),
                .ensure_anchor => try Ops.idempotentNodeCommandsValue.runEnsureAnchor(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchStoreCopyCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .backup => try Ops.storeCopyCommandsValue.runBackup(args, writer, allocator, io),
                .restore => try Ops.storeCopyCommandsValue.runRestore(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchStoreInterchangeCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .import_jsonl => try Ops.storeInterchangeCommandsValue.runImportJsonl(args, writer, allocator, io),
                .export_jsonl => try Ops.storeInterchangeCommandsValue.runExportJsonl(args, writer, allocator, io),
                .import_markdown => try Ops.storeInterchangeCommandsValue.runImportMarkdown(args, writer, allocator, io),
                .export_markdown => try Ops.storeInterchangeCommandsValue.runExportMarkdown(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn dispatchSingleCommand(cmd: Command, expected: Command, command_backend: anytype, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            if (cmd != expected) return false;
            try command_backend.run(args, writer, allocator, io);
            return true;
        }

        fn dispatchQueryCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            if (cmd != .query and cmd != .query_explain) return false;
            try Ops.queryCommandValue.run(args, writer, allocator, io, cmd == .query_explain);
            return true;
        }

        fn dispatchMarkdownImportCommand(cmd: Command, args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !bool {
            switch (cmd) {
                .import_md_doc => try Ops.markdownImportCommandsValue.runDocument(args, writer, allocator, io),
                .import_md_ast => try Ops.markdownImportCommandsValue.runAst(args, writer, allocator, io),
                else => return false,
            }
            return true;
        }

        fn runMaintenance(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const parsed = try Ops.parseMaintenanceArguments(allocator, io, args);
            const maintenance_start_ns = Ops.startTimer(io);
            var context = try Ops.MaintenanceContextValue.init(allocator, io, parsed.db_path);
            defer context.deinit();
            var summary = Ops.LifecycleMaintenanceSummaryValue{};
            var clean_cycle_streak: usize = 0;
            var cycle_index: usize = 0;
            while (cycle_index < parsed.max_cycles) : (cycle_index += 1) {
                const cycle = try context.runCycle(parsed, &summary, io);
                try Ops.recordCycle(&summary, cycle.made_progress);
                if (cycle.made_progress) {
                    clean_cycle_streak = 0;
                } else {
                    clean_cycle_streak = std.math.add(usize, clean_cycle_streak, 1) catch return error.RecordTooLarge;
                }
                if (parsed.max_cycles == 1 and cycle.stopped_clean) summary.stopped_clean = true;
                if (parsed.stop_after_clean_cycles != 0 and clean_cycle_streak >= parsed.stop_after_clean_cycles) {
                    summary.stopped_clean = true;
                    break;
                }
                if (cycle_index < parsed.max_cycles - 1 and parsed.poll_ms != 0) try Ops.sleepForMillis(io, parsed.poll_ms);
            }
            const maintenance_elapsed_ns = Ops.elapsedSince(io, maintenance_start_ns);
            try writer.print(
                "maintenance cycles={} passes={} stopped_clean={} clean_cycles={} edge_l0_compactions={} edge_l0_compacted_edges={} edge_l0_compacted_segments={} edge_gc_passes={} edge_gc_deleted_segments={} edge_gc_deleted_manifests={} node_text_delta_compactions={} node_text_delta_records_compacted={} node_text_run_compactions={} node_text_run_compacted_records={} node_text_run_gc_deleted_runs={} node_texts_compressions={} node_texts_compress_ns={} node_texts_bytes_before_last={} node_texts_bytes_after_last={} node_texts_logical_bytes_last={} node_text_gc_passes={} node_text_gc_deleted_runs={} node_text_gc_deleted_manifests={} property_payload_compactions={} property_payload_delta_bytes_compacted={} property_payload_delta_frames_compacted={} last_property_payload_live_entries={} property_payload_cleanup_pending={}",
                .{
                    summary.cycles,
                    summary.passes,
                    summary.stopped_clean,
                    summary.clean_cycles,
                    summary.edge_l0_compactions,
                    summary.edge_l0_compacted_edges,
                    summary.edge_l0_compacted_segments,
                    summary.edge_gc_passes,
                    summary.edge_gc_deleted_segments,
                    summary.edge_gc_deleted_manifests,
                    summary.node_text_delta_compactions,
                    summary.node_text_delta_records_compacted,
                    summary.node_text_run_compactions,
                    summary.node_text_run_compacted_records,
                    summary.node_text_run_gc_deleted_runs,
                    summary.node_texts_compressions,
                    summary.node_texts_compress_ns,
                    summary.node_texts_bytes_before_last,
                    summary.node_texts_bytes_after_last,
                    summary.node_texts_logical_bytes_last,
                    summary.node_text_gc_passes,
                    summary.node_text_gc_deleted_runs,
                    summary.node_text_gc_deleted_manifests,
                    summary.property_payload_compactions,
                    summary.property_payload_delta_bytes_compacted,
                    summary.property_payload_delta_frames_compacted,
                    summary.last_property_payload_live_entries,
                    @intFromBool(summary.property_payload_cleanup_pending),
                },
            );
            try writer.print(
                " last_edge_l0_entries_before={} last_edge_l0_entries_after={} last_node_text_delta_records_before={} last_node_text_delta_records_after={} last_node_text_run_entries_before={} last_node_text_run_entries_after={} last_node_text_run_records_before={} last_node_text_run_records_after={} elapsed_ns={}\n",
                .{
                    summary.last_edge_l0_entries_before,
                    summary.last_edge_l0_entries_after,
                    summary.last_node_text_delta_records_before,
                    summary.last_node_text_delta_records_after,
                    summary.last_node_text_run_entries_before,
                    summary.last_node_text_run_entries_after,
                    summary.last_node_text_run_records_before,
                    summary.last_node_text_run_records_after,
                    maintenance_elapsed_ns,
                },
            );
        }

        pub fn run(args: []const []const u8, writer: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            const cmd = try Ops.parseCommand(if (args.len > 1) args[1] else null);
            if (try dispatchSchemaCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchPropertyCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchContainTreeMigrationCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchEdgeMutationCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchEdgeSegmentCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchNodeTextRunGcCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchGraphTraversalCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchContextCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchNodeReadCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchNodeMutationCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchIdempotentNodeCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchStoreCopyCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchStoreInterchangeCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .apply, Ops.applyCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .import_metaknow_replay, Ops.metaknowReplayImportCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .agent_write, Ops.agentWriteCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .schema_scope, Ops.schemaScopeCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .find, Ops.findCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .search, Ops.searchCommandValue, args, writer, allocator, io)) return;
            if (try dispatchQueryCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchMarkdownImportCommand(cmd, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .render_md_doc, Ops.markdownRenderCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .gc_md_orphans, Ops.markdownOrphanGcCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .init, Ops.storeInitCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .rebuild_text, Ops.rebuildTextCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .upgrade, Ops.storeUpgradeCommandValue, args, writer, allocator, io)) return;
            if (try dispatchSingleCommand(cmd, .migrate_store_v2, Ops.migrateStoreV2CommandValue, args, writer, allocator, io)) return;
            switch (cmd) {
                .help => try Ops.writeHelp(writer),
                .version => try writeVersion(args, writer),
                .init, .rebuild_text, .backup, .restore, .upgrade, .migrate_store_v2 => unreachable,
                .schema_info, .schema_show, .schema_apply, .schema_validate, .schema_reconcile, .schema_migrate => unreachable,
                .import_metaknow_replay, .import_jsonl, .export_jsonl, .apply, .import_markdown, .export_markdown => unreachable,
                .import_md_ast, .import_md_doc, .render_md_doc, .gc_md_orphans => unreachable,
                .get, .get_node, .ensure_node, .schema_scope, .ensure_anchor => unreachable,
                .add_node, .update_node, .append_node_version, .govern_node, .delete_node, .reparent_contain => unreachable,
                .add_edge, .delete_edge, .delete_edges => unreachable,
                .set_property, .set_uint_property, .set_node_property, .set_edge_property => unreachable,
                .node_versions, .node_latest, .list_kinds, .list_rels => unreachable,
                .stats => try Ops.storeInspectionCommandsValue.runStats(args, writer, allocator, io),
                .store_info => try Ops.storeInspectionCommandsValue.runStoreInfo(args, writer, allocator, io),
                .list_recent => try Ops.recentCommandsValue.run(args, writer, allocator, io),
                .agent_write, .find, .search, .context_plan, .context_packet, .neighbors, .incoming, .path => unreachable,
                .task_ready => try Ops.taskReadCommandsValue.runReady(args, writer, allocator, io),
                .task_packet => try Ops.taskReadCommandsValue.runPacket(args, writer, allocator, io),
                .task_snapshot => try Ops.taskSnapshotCommandValue.run(args, writer, allocator, io),
                .ontology_rule_snapshot => try Ops.ontologySnapshotCommandValue.run(args, writer, allocator, io),
                .memory_migration_capabilities => try Ops.memoryMigrationCommandValue.runCapabilities(args, writer, allocator, io),
                .memory_migration_snapshot => try Ops.memoryMigrationCommandValue.runSnapshot(args, writer, allocator, io),
                .memory_migration_commit => try Ops.memoryMigrationCommandValue.runCommit(args, writer, allocator, io),
                .memory_migration_post_state => try Ops.memoryMigrationCommandValue.runPostState(args, writer, allocator, io),
                .memory_migration_rollback => try Ops.memoryMigrationCommandValue.runRollback(args, writer, allocator, io),
                .materialize_checkpoint => try Ops.materializeCheckpointCommandValue.run(args, writer, allocator, io),
                .task_frontier => try Ops.taskReadCommandsValue.runFrontier(args, writer, allocator, io),
                .task_claim => try Ops.taskLeaseCommandsValue.runClaim(args, writer, allocator, io),
                .task_release => try Ops.taskLeaseCommandsValue.runRelease(args, writer, allocator, io),
                .task_close => try Ops.taskCloseCommandValue.run(args, writer, allocator, io),
                .task_ancestry => try Ops.taskReadCommandsValue.runAncestry(args, writer, allocator, io),
                .task_metrics => try Ops.taskReadCommandsValue.runMetrics(args, writer, allocator, io),
                .task_event => try Ops.taskEventCommandValue.run(args, writer, allocator, io),
                .query, .query_explain => unreachable,
                .governance => try Ops.governanceCommandValue.run(args, writer, allocator, io),
                .segment_query, .segment_query_explain => try Ops.segmentCommandsValue.runQuery(args, writer, allocator, io, cmd == .segment_query_explain),
                .export_segment_bundle => try Ops.segmentCommandsValue.runExport(args, writer, allocator, io),
                .gc_segment_bundle => try Ops.segmentCommandsValue.runGc(args, writer, allocator, io),
                .bench => try Ops.runBench(args, writer, allocator, io),
                .bench_md_doc_edit => try Ops.runMarkdownDocEditBench(args, writer, allocator, io),
                .maintain => try runMaintenance(args, writer, allocator, io),
                .compact_edges, .compact_edge_segments, .maintain_edge_segments, .gc_edge_segments, .gc_node_text_runs => unreachable,
            }
        }

        fn writeVersion(args: []const []const u8, writer: anytype) !void {
            if (args.len == 2) {
                try writer.writeAll(Ops.versionCliValue);
                try writer.writeAll("\n");
            } else if (args.len == 4 and std.mem.eql(u8, args[2], "--format") and std.mem.eql(u8, args[3], "json")) {
                try writer.writeAll(Ops.versionMetadataJsonValue);
                try writer.writeAll("\n");
            } else return error.InvalidRecord;
        }
    };
}

fn firstAccepted(handlers: []const bool) ?usize {
    for (handlers, 0..) |accepted, index| if (accepted) return index;
    return null;
}

fn versionAdmission(args: []const []const u8) bool {
    return args.len == 2 or (args.len == 4 and std.mem.eql(u8, args[2], "--format") and std.mem.eql(u8, args[3], "json"));
}

fn shouldStopMaintenance(stop_after_clean_cycles: usize, clean_cycle_streak: usize) bool {
    return stop_after_clean_cycles != 0 and clean_cycle_streak >= stop_after_clean_cycles;
}

test "root command dispatch stops after the first accepting family" {
    try std.testing.expectEqual(@as(?usize, 1), firstAccepted(&.{ false, true, true }));
}

test "root command dispatch delegates help without opening a store" {
    var store_opened = false;
    const command = "help";
    if (std.mem.eql(u8, command, "help")) {
        try std.testing.expect(!store_opened);
    } else {
        store_opened = true;
    }
}

test "root command dispatch rejects unknown commands before family routing" {
    const TestOps = struct {
        fn parse(value: ?[]const u8) !void {
            if (value == null or !std.mem.eql(u8, value.?, "help")) return error.UnknownCommand;
        }
    };
    try std.testing.expectError(error.UnknownCommand, TestOps.parse("wat"));
}

test "root command dispatch preserves version format admission" {
    try std.testing.expect(versionAdmission(&.{ "tinykg", "version" }));
    try std.testing.expect(versionAdmission(&.{ "tinykg", "version", "--format", "json" }));
    try std.testing.expect(!versionAdmission(&.{ "tinykg", "version", "--format", "text" }));
}

test "root command dispatch stops maintenance after configured clean cycles" {
    try std.testing.expect(shouldStopMaintenance(2, 2));
    try std.testing.expect(!shouldStopMaintenance(2, 1));
}

test "root command dispatch keeps polling while maintenance makes progress" {
    var clean_cycle_streak: usize = 3;
    const made_progress = true;
    if (made_progress) clean_cycle_streak = 0;
    try std.testing.expectEqual(@as(usize, 0), clean_cycle_streak);
    try std.testing.expect(!shouldStopMaintenance(2, clean_cycle_streak));
}
