/// Persistent TinyQL, search, context-packet, node and neighbor read rendering.
const checkpoint = @import("../checkpoint.zig");

pub fn QueryContextReadDataPlane(comptime Ops: type) type {
    return struct {
        const CliOutputFormat = Ops.CliOutputFormatValue;
        const MarkdownImportContext = Ops.MarkdownImportContextValue;
        const NodeReadRenderOptions = Ops.NodeReadRenderOptionsValue;
        const ParsedContextArgs = Ops.ParsedContextArgsValue;
        const ParsedNeighborsArgs = Ops.ParsedNeighborsArgsValue;
        const ParsedTaskPacketArgs = Ops.ParsedTaskPacketArgsValue;
        const QueryOutputWriter = Ops.QueryOutputWriterValue;
        const TextBudgetProfile = Ops.TextBudgetProfileValue;
        const TextContextSize = Ops.TextContextSizeValue;
        const agent = Ops.agentValue;
        const agent_memory_text_postings_scanned = Ops.agent_memory_text_postings_scannedValue;
        const agent_memory_text_timeout_ms = Ops.agent_memory_text_timeout_msValue;
        const appendMarkdownProjectionEdge = Ops.appendMarkdownProjectionEdgeValue;
        const collectContainChildIds = Ops.collectContainChildIdsValue;
        const collectProjectDescendantNodeIds = Ops.collectProjectDescendantNodeIdsValue;
        const computeTextContextSize = Ops.computeTextContextSizeValue;
        const core = Ops.coreValue;
        const dag = Ops.dagValue;
        const elapsedNs = Ops.elapsedNsValue;
        const ensureTaskEvidenceEdge = Ops.ensureTaskEvidenceEdgeValue;
        const existingTinyKgStorePath = Ops.existingTinyKgStorePathValue;
        const forEachVisibleEdgeRecordByNode = Ops.forEachVisibleEdgeRecordByNodeValue;
        const graph = Ops.graphValue;
        const linkNodeToProjectParent = Ops.linkNodeToProjectParentValue;
        const lookupMarkdownProjectionEdgeByEndpoints = Ops.lookupMarkdownProjectionEdgeByEndpointsValue;
        const markdownIncomingHeadingRel = Ops.markdownIncomingHeadingRelValue;
        const markdownPreviewPrefixLen = Ops.markdownPreviewPrefixLenValue;
        const markdownProjectionChildren = Ops.markdownProjectionChildrenValue;
        const markdownProjectionVisibleText = Ops.markdownProjectionVisibleTextValue;
        const markdownSubtreeSectionStats = Ops.markdownSubtreeSectionStatsValue;
        const markdownUtf8PrefixEndByChars = Ops.markdownUtf8PrefixEndByCharsValue;
        const max_cli_text_postings_scanned = Ops.max_cli_text_postings_scannedValue;
        const max_cli_text_timeout_ms = Ops.max_cli_text_timeout_msValue;
        const md_rel_h1 = Ops.md_rel_h1Value;
        const monotonicNs = Ops.monotonicNsValue;
        const nodeDeprecatedBy = Ops.nodeDeprecatedByValue;
        const nodeHasTaskEventSchema = Ops.nodeHasTaskEventSchemaValue;
        const nodeKindNameAlloc = Ops.nodeKindNameAllocValue;
        const nodeKindNameWithSchemaAlloc = Ops.nodeKindNameWithSchemaAllocValue;
        const nodeLocalGraphStats = Ops.nodeLocalGraphStatsValue;
        const parseContextArgs = Ops.parseContextArgsValue;
        const parseDbArgs = Ops.parseDbArgsValue;
        const parseFreeTextDbArgs = Ops.parseFreeTextDbArgsValue;
        const parseNeighborsArgs = Ops.parseNeighborsArgsValue;
        const parseNodeIdArg = Ops.parseNodeIdArgValue;
        const parseOptionalDbPath = Ops.parseOptionalDbPathValue;
        const parseQueryArgs = Ops.parseQueryArgsValue;
        const parseSearchArgs = Ops.parseSearchArgsValue;
        const parseTaskAncestryArgs = Ops.parseTaskAncestryArgsValue;
        const parseTaskFrontierArgs = Ops.parseTaskFrontierArgsValue;
        const parseTaskMetricsArgs = Ops.parseTaskMetricsArgsValue;
        const parseTaskPacketArgs = Ops.parseTaskPacketArgsValue;
        const persistentNowNs = Ops.persistentNowNsValue;
        const persistentTextCatalogWarm = Ops.persistentTextCatalogWarmValue;
        const ql = Ops.qlValue;
        const query = Ops.queryValue;
        const query_index = Ops.query_indexValue;
        const readVisibleEdgeRecordsByNode = Ops.readVisibleEdgeRecordsByNodeValue;
        const readVisibleEdgeRecordsByNodeCompleteLimited = Ops.readVisibleEdgeRecordsByNodeCompleteLimitedValue;
        const readVisibleEdgeRecordsByNodeLimited = Ops.readVisibleEdgeRecordsByNodeLimitedValue;
        const readVisibleTaskHierarchyEdgeRecords = Ops.readVisibleTaskHierarchyEdgeRecordsValue;
        const readVisibleTaskPacketChildEdgeRecords = Ops.readVisibleTaskPacketChildEdgeRecordsValue;
        const relKindNameWithSchemaAlloc = Ops.relKindNameWithSchemaAllocValue;
        const renderMarkdownDocument = Ops.renderMarkdownDocumentValue;
        const renderTaskFrontierOutput = Ops.renderTaskFrontierOutputValue;
        const renderTextContextSizeJson = Ops.renderTextContextSizeJsonValue;
        const run = Ops.runValue;
        const schema = Ops.schemaValue;
        const segment_bundle = Ops.segment_bundleValue;
        const segment_node_index = Ops.segment_node_indexValue;
        const std = Ops.stdValue;
        const storage = Ops.storageValue;
        const task = Ops.taskValue;
        const taskHasNonCompletedChildren = Ops.taskHasNonCompletedChildrenValue;
        const taskPacketRoleIsGoalAnchor = Ops.taskPacketRoleIsGoalAnchorValue;
        const text_search = Ops.text_searchValue;
        const u128ToU64 = Ops.u128ToU64Value;
        const version = Ops.versionValue;
        const writeEscapedText = Ops.writeEscapedTextValue;
        const writeJsonBoolField = Ops.writeJsonBoolFieldValue;
        const writeJsonFieldPrefix = Ops.writeJsonFieldPrefixValue;
        const writeJsonNullableStringField = Ops.writeJsonNullableStringFieldValue;
        const writeJsonNumberField = Ops.writeJsonNumberFieldValue;
        const writeJsonObjectEnd = Ops.writeJsonObjectEndValue;
        const writeJsonObjectStart = Ops.writeJsonObjectStartValue;
        const writeJsonString = Ops.writeJsonStringValue;
        const writeJsonStringField = Ops.writeJsonStringFieldValue;
        const writeNodeKindName = Ops.writeNodeKindNameValue;
        const writeNodeKindNameWithSchema = Ops.writeNodeKindNameWithSchemaValue;
        const writeProjectionPersistent = Ops.writeProjectionPersistentValue;
        const writeRelKindName = Ops.writeRelKindNameValue;
        const writeRelKindNameWithSchema = Ops.writeRelKindNameWithSchemaValue;
        const writeTaskPacketEdgeRows = Ops.writeTaskPacketEdgeRowsValue;
        const writeTaskPacketHierarchyEdgeRows = Ops.writeTaskPacketHierarchyEdgeRowsValue;
        const writeTaskPacketNodeRow = Ops.writeTaskPacketNodeRowValue;
        const writeTaskPacketRecentEdgeRows = Ops.writeTaskPacketRecentEdgeRowsValue;
        const writeTaskPacketRecentHistoryEdgeRows = Ops.writeTaskPacketRecentHistoryEdgeRowsValue;

        fn renderPersistentQueryOutput(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            physical: ql.optimizer.PhysicalPlan,
            explain: bool,
            budget: core.QueryBudget,
        ) ![]u8 {
            return renderPersistentQueryOutputMaybeRetained(allocator, io, store, null, null, null, physical, explain, budget);
        }

        pub fn renderPersistentQueryOutputRetained(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
            physical: ql.optimizer.PhysicalPlan,
            explain: bool,
            budget: core.QueryBudget,
        ) ![]u8 {
            var node_text_retention_registry = storage.NodeTextRunRetentionRegistry.init(allocator);
            defer node_text_retention_registry.deinit();
            return renderPersistentQueryOutputMaybeRetained(allocator, io, store, edge_retention_registry, &node_text_retention_registry, null, physical, explain, budget);
        }

        /// Daemon hot path. The session owns retained edge/node-text readers
        /// across requests and is explicitly invalidated when Store generation
        /// advances. Explain output still uses the instrumented retained path.
        pub fn renderPersistentQueryOutputSession(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            session: *ql.executor.PersistentStoreQuerySession,
            physical: ql.optimizer.PhysicalPlan,
            explain: bool,
            budget: core.QueryBudget,
        ) ![]u8 {
            return renderPersistentQueryOutputMaybeRetained(
                allocator,
                io,
                store,
                session.edgeRetentionRegistry(),
                null,
                session,
                physical,
                explain,
                budget,
            );
        }

        /// Compact daemon presentation path. Execution and projection both
        /// borrow one generation-owned checkpoint Runtime, so no expanded
        /// legacy Store or persistent derived index is created on disk.
        pub fn renderCheckpointQueryOutput(
            allocator: std.mem.Allocator,
            io: std.Io,
            runtime: *checkpoint.Runtime,
            physical: ql.optimizer.PhysicalPlan,
            explain: bool,
            budget: core.QueryBudget,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            const explain_start_ns = if (explain) monotonicNs(io) else 0;
            var operator_timings = ql.executor.OperatorTimingRecorder.init(allocator, io);
            defer operator_timings.deinit();
            var table = if (explain)
                try runtime.executeExplain(io, physical, budget, &operator_timings)
            else
                try runtime.execute(io, physical, budget);
            defer table.deinit(allocator);
            if (!explain and table.stats.budget_exceeded) return core.Error.BudgetExceeded;

            if (explain) {
                if (try accumulateCheckpointProjectionExplainStats(
                    allocator,
                    io,
                    runtime,
                    physical,
                    table,
                    budget,
                    &table.stats,
                )) table.stats.budget_exceeded = true;
                const elapsed_ns = elapsedNs(io, explain_start_ns);
                try out.print(
                    "rows={} nodes_visited={} edges_visited={} budget_exceeded={} elapsed_ns={} text_warm_start=1 text_warm_end=1 max_results={} max_depth={} max_visited_nodes={} max_visited_edges={} max_text_postings_scanned={} timeout_ms={} plan=",
                    .{
                        table.rows.items.len,
                        table.stats.nodes_visited,
                        table.stats.edges_visited,
                        table.stats.budget_exceeded,
                        elapsed_ns,
                        budget.max_results,
                        budget.max_depth,
                        budget.max_visited_nodes,
                        budget.max_visited_edges,
                        budget.max_text_postings_scanned,
                        budget.timeout_ms,
                    },
                );
                try renderPhysicalPlanSummary(&out, physical);
                try out.writeAll(" op_timings=");
                try renderOperatorTimings(&out, operator_timings.entries.items);
                try out.writeAll("\n");
                return out.buffer.toOwnedSlice(allocator);
            }

            const projections = physicalProjections(physical) orelse return error.InvalidPlan;
            const read_timestamp_ns = table.read_timestamp_ns orelse try u128ToU64(persistentNowNs(io));
            for (table.rows.items) |row| {
                for (projections, 0..) |projection, index_pos| {
                    if (index_pos > 0) try out.writeAll("\t");
                    try writeProjectionCheckpoint(&out, allocator, io, runtime, read_timestamp_ns, row, projection, budget, null);
                }
                try out.writeAll("\n");
            }
            return out.buffer.toOwnedSlice(allocator);
        }

        fn writeProjectionCheckpoint(
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
            runtime: *checkpoint.Runtime,
            read_timestamp_ns: u64,
            row: ql.executor.Row,
            projection: ql.ast.Projection,
            budget: core.QueryBudget,
            projection_stats: ?*query_index.QueryStats,
        ) !void {
            switch (projection) {
                .variable => |var_name| {
                    const id = row.get(var_name) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    const node = runtime.graph_index.getNode(&runtime.graph, id) orelse return error.InvalidRecord;
                    try writer.print("{}:", .{id.toInt()});
                    try writeNodeKindName(writer, node.kind);
                    try writer.writeAll(":");
                    try writeEscapedText(writer, markdownProjectionVisibleText(node.text));
                },
                .property => |property_projection| {
                    const id = row.get(property_projection.var_name) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    const node = runtime.graph_index.getNode(&runtime.graph, id) orelse return error.InvalidRecord;
                    if (std.mem.eql(u8, property_projection.property, "text")) {
                        try writeEscapedText(writer, node.text);
                        return;
                    }
                    if (node.kind == .task and std.mem.eql(u8, property_projection.property, task.status_property)) {
                        const lifecycle = try checkpointTaskStatus(runtime.query_view, id, read_timestamp_ns);
                        try writer.writeAll(@tagName(lifecycle));
                        return;
                    }
                    const value = runtime.query_view.nodeProperty(id.toInt(), property_projection.property) orelse {
                        if (std.mem.eql(u8, property_projection.property, "name") or std.mem.eql(u8, property_projection.property, "summary")) {
                            try writer.writeAll("");
                        } else {
                            try writer.writeAll("null");
                        }
                        return;
                    };
                    switch (value.value_kind) {
                        .string => try writeEscapedText(writer, value.string_value),
                        .uint => try writer.print("{}", .{value.uint_value}),
                    }
                },
                .path => |path| {
                    const nodes = row.getPath(path.from_var, path.to_var) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    for (nodes, 0..) |node_id, index_pos| {
                        if (runtime.graph_index.getNode(&runtime.graph, node_id) == null) return error.InvalidRecord;
                        if (index_pos > 0) try writer.writeAll(" -> ");
                        try writer.print("{}", .{node_id.toInt()});
                    }
                },
                .reachable => |reachable| {
                    const from = row.get(reachable.from_var) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    const to = row.get(reachable.to_var) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    var local_stats: query_index.QueryStats = .{};
                    const stats = projection_stats orelse &local_stats;
                    const value = try dag.reachableWithCursorMeasured(
                        allocator,
                        &runtime.graph,
                        &runtime.graph_index,
                        .{ .memory = .{ .mem_index = &runtime.graph_index, .checkpoint_view = runtime.query_view } },
                        from,
                        to,
                        reachable.rel,
                        budget,
                        stats,
                    );
                    try writer.writeAll(if (value) "true" else "false");
                },
                .context => |context| {
                    const focus = row.get(context.var_name) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    var local_stats: query_index.QueryStats = .{};
                    const stats = projection_stats orelse &local_stats;
                    var packet = try agent.contextPacketWithCursorMeasured(
                        allocator,
                        io,
                        &runtime.graph,
                        &runtime.graph_index,
                        .{ .memory = .{ .mem_index = &runtime.graph_index, .checkpoint_view = runtime.query_view } },
                        focus,
                        8,
                        budget,
                        stats,
                    );
                    defer packet.deinit(allocator);
                    for (packet.facts.items, 0..) |fact, index_pos| {
                        const node = runtime.graph_index.getNode(&runtime.graph, fact.node_id) orelse return error.InvalidRecord;
                        if (index_pos > 0) try writer.writeAll(",");
                        try writeRelKindName(writer, fact.rel);
                        try writer.print(":{s}:{}:", .{ @tagName(fact.direction), fact.node_id.toInt() });
                        try writeEscapedText(writer, node.text);
                        try writer.print(":{}", .{fact.score});
                    }
                },
                .score => |score| {
                    if (row.getScore(score.var_name)) |value| {
                        try writer.print("{d:.6}", .{value});
                    } else {
                        try writer.writeAll("null");
                    }
                },
            }
        }

        fn accumulateCheckpointProjectionExplainStats(
            allocator: std.mem.Allocator,
            io: std.Io,
            runtime: *checkpoint.Runtime,
            physical: ql.optimizer.PhysicalPlan,
            table: ql.executor.ResultTable,
            budget: core.QueryBudget,
            stats: *query_index.QueryStats,
        ) !bool {
            const projections = physicalProjections(physical) orelse return error.InvalidPlan;
            var sink = ProjectionExplainSink{};
            const read_timestamp_ns = table.read_timestamp_ns orelse try u128ToU64(persistentNowNs(io));
            for (table.rows.items) |row| {
                for (projections) |projection| {
                    var projection_stats: query_index.QueryStats = .{};
                    writeProjectionCheckpoint(
                        &sink,
                        allocator,
                        io,
                        runtime,
                        read_timestamp_ns,
                        row,
                        projection,
                        budget,
                        &projection_stats,
                    ) catch |err| {
                        try mergeProjectionStats(stats, projection_stats);
                        switch (err) {
                            core.Error.BudgetExceeded => return true,
                            else => |other| return other,
                        }
                    };
                    try mergeProjectionStats(stats, projection_stats);
                }
            }
            return false;
        }

        fn checkpointTaskStatus(
            view: query.CheckpointView,
            node_id: core.NodeId,
            now_ns: u64,
        ) !task.Status {
            var fields: task.StatusSnapshot.LifecycleFields = .{};
            if (view.nodeProperty(node_id.toInt(), task.status_property)) |value| {
                if (value.value_kind == .string) fields.stored_status_raw = value.string_value else fields.invalid_value_type = true;
            }
            if (view.nodeProperty(node_id.toInt(), task.claimed_by_property)) |value| {
                if (value.value_kind == .string) fields.claimed_by = value.string_value else fields.invalid_value_type = true;
            }
            if (view.nodeProperty(node_id.toInt(), task.claim_expires_ns_property)) |value| {
                if (value.value_kind == .uint) fields.claim_expires_ns = value.uint_value else fields.invalid_value_type = true;
            }
            if (view.nodeProperty(node_id.toInt(), "task_recorded_ns")) |value| {
                if (value.value_kind == .uint) fields.task_recorded_ns = value.uint_value else fields.invalid_value_type = true;
            }
            if (view.nodeProperty(node_id.toInt(), "task_created_ns")) |value| {
                if (value.value_kind == .uint) fields.task_created_ns = value.uint_value else fields.invalid_value_type = true;
            }
            if (view.nodeProperty(node_id.toInt(), "task_completed_ns")) |value| {
                if (value.value_kind == .uint) fields.task_completed_ns = value.uint_value else fields.invalid_value_type = true;
            }
            return task.effectiveStatusForLifecycleFields(fields, now_ns, .strict);
        }

        fn renderPersistentQueryOutputMaybeRetained(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
            node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry,
            persistent_session: ?*ql.executor.PersistentStoreQuerySession,
            physical: ql.optimizer.PhysicalPlan,
            explain: bool,
            budget: core.QueryBudget,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            const explain_start_ns = if (explain) monotonicNs(io) else 0;
            const text_warm_start = if (explain) try persistentTextCatalogWarm(allocator, io, store, store.dir_path) else false;
            var operator_timings = ql.executor.OperatorTimingRecorder.init(allocator, io);
            defer operator_timings.deinit();
            var table = if (persistent_session != null and !explain)
                try persistent_session.?.execute(io, physical, budget)
            else if (explain)
                try ql.executor.executeWithPersistentStoreAndIoRetainedIndexesExplain(allocator, io, store, edge_retention_registry, node_text_retention_registry, physical, budget, &operator_timings)
            else if (edge_retention_registry) |edge_registry|
                if (node_text_retention_registry) |node_text_registry|
                    try ql.executor.executeWithPersistentStoreAndIoRetainedIndexes(allocator, io, store, edge_registry, node_text_registry, physical, budget)
                else
                    try ql.executor.executeWithPersistentStoreAndIoRetained(allocator, io, store, edge_registry, physical, budget)
            else
                try ql.executor.executeWithPersistentStoreAndIo(allocator, io, store, physical, budget);
            defer table.deinit(allocator);

            if (!explain and table.stats.budget_exceeded) return core.Error.BudgetExceeded;

            if (explain) {
                if (try accumulateProjectionExplainStats(allocator, store, edge_retention_registry, physical, table, budget, &table.stats)) {
                    table.stats.budget_exceeded = true;
                }
                const elapsed_ns = elapsedNs(io, explain_start_ns);
                const text_warm_end = try persistentTextCatalogWarm(allocator, io, store, store.dir_path);
                try out.print(
                    "rows={} nodes_visited={} edges_visited={} budget_exceeded={} elapsed_ns={} text_warm_start={} text_warm_end={} max_results={} max_depth={} max_visited_nodes={} max_visited_edges={} max_text_postings_scanned={} timeout_ms={} plan=",
                    .{
                        table.rows.items.len,
                        table.stats.nodes_visited,
                        table.stats.edges_visited,
                        table.stats.budget_exceeded,
                        elapsed_ns,
                        @intFromBool(text_warm_start),
                        @intFromBool(text_warm_end),
                        budget.max_results,
                        budget.max_depth,
                        budget.max_visited_nodes,
                        budget.max_visited_edges,
                        budget.max_text_postings_scanned,
                        budget.timeout_ms,
                    },
                );
                try renderPhysicalPlanSummary(&out, physical);
                try out.writeAll(" op_timings=");
                try renderOperatorTimings(&out, operator_timings.entries.items);
                try out.writeAll("\n");
            } else {
                const projections = physicalProjections(physical) orelse return error.InvalidPlan;
                var node_view: ?storage.Store.NodeRecordView = null;
                defer if (node_view) |*view| view.deinit();
                if (table.rows.items.len > 0 and projectionsNeedPersistentNodes(projections)) {
                    node_view = try store.openNodeRecordView();
                }
                var status_snapshot = try initTaskStatusProjectionSnapshot(
                    allocator,
                    store,
                    if (node_view) |*view| view else null,
                    table.rows.items,
                    projections,
                );
                defer if (status_snapshot) |*snapshot| snapshot.deinit();
                const read_timestamp_ns = table.read_timestamp_ns orelse try u128ToU64(persistentNowNs(io));
                for (table.rows.items) |row| {
                    for (projections, 0..) |projection, i| {
                        if (i > 0) try out.writeAll("\t");
                        try writeProjectionPersistent(&out, allocator, store, edge_retention_registry, if (node_view) |*view| view else null, if (status_snapshot) |*snapshot| snapshot else null, read_timestamp_ns, row, projection, budget, null);
                    }
                    try out.writeAll("\n");
                }
            }

            return out.buffer.toOwnedSlice(allocator);
        }

        pub fn renderSegmentBundleQueryOutput(
            allocator: std.mem.Allocator,
            io: std.Io,
            root_dir: []const u8,
            physical: ql.optimizer.PhysicalPlan,
            explain: bool,
            budget: core.QueryBudget,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            const explain_start_ns = if (explain) monotonicNs(io) else 0;
            var opened = try segment_bundle.openTrusted(allocator, io, root_dir);
            defer opened.deinit();
            var operator_timings = ql.executor.OperatorTimingRecorder.init(allocator, io);
            defer operator_timings.deinit();
            var table = if (explain)
                try opened.executeExactTextPathExplain(allocator, physical, budget, &operator_timings)
            else
                try opened.executeExactTextPath(allocator, physical, budget);
            defer table.deinit(allocator);

            if (!explain and table.stats.budget_exceeded) return core.Error.BudgetExceeded;

            if (explain) {
                const elapsed_ns = elapsedNs(io, explain_start_ns);
                try out.print(
                    "rows={} nodes_visited={} edges_visited={} budget_exceeded={} elapsed_ns={} text_warm_start=0 text_warm_end=0 max_results={} max_depth={} max_visited_nodes={} max_visited_edges={} max_text_postings_scanned={} timeout_ms={} plan=",
                    .{
                        table.rows.items.len,
                        table.stats.nodes_visited,
                        table.stats.edges_visited,
                        table.stats.budget_exceeded,
                        elapsed_ns,
                        budget.max_results,
                        budget.max_depth,
                        budget.max_visited_nodes,
                        budget.max_visited_edges,
                        budget.max_text_postings_scanned,
                        budget.timeout_ms,
                    },
                );
                try renderPhysicalPlanSummary(&out, physical);
                try out.writeAll(" op_timings=");
                try renderOperatorTimings(&out, operator_timings.entries.items);
                try out.writeAll("\n");
            } else {
                const projections = physicalProjections(physical) orelse return error.InvalidPlan;
                for (table.rows.items) |row| {
                    for (projections, 0..) |projection, i| {
                        if (i > 0) try out.writeAll("\t");
                        try writeProjectionSegment(&out, &opened.catalog, row, projection);
                    }
                    try out.writeAll("\n");
                }
            }

            return out.buffer.toOwnedSlice(allocator);
        }

        fn renderPhysicalPlanSummary(writer: anytype, physical: ql.optimizer.PhysicalPlan) !void {
            for (physical.ops.items, 0..) |op, i| {
                if (i > 0) try writer.writeAll("->");
                switch (op) {
                    .text_search => |text_op| {
                        try writer.writeAll("text_search(index=bm25,var=");
                        try writeEscapedText(writer, text_op.var_name);
                        try writer.writeAll(",kind=");
                        try writeOptionalNodeKindName(writer, text_op.kind);
                        if (text_op.text_eq != null) try writer.writeAll(",post_filter=text");
                        if (text_op.limit) |limit| try writer.print(",limit={}", .{limit});
                        try writer.writeAll(")");
                    },
                    .node_lookup_by_text => |lookup| {
                        try writer.writeAll("node_lookup_by_text(index=node_by_text,var=");
                        try writeEscapedText(writer, lookup.var_name);
                        try writer.writeAll(",kind=");
                        try writeOptionalNodeKindName(writer, lookup.kind);
                        if (lookup.property_eq != null) try writer.writeAll(",post_filter=property");
                        try writer.writeAll(")");
                    },
                    .node_lookup_by_property => |lookup| {
                        try writer.writeAll("node_lookup_by_property(index=node_props,var=");
                        try writeEscapedText(writer, lookup.var_name);
                        try writer.writeAll(",kind=");
                        try writeOptionalNodeKindName(writer, lookup.kind);
                        try writer.writeAll(",property=");
                        try writeEscapedText(writer, lookup.property_eq.key);
                        try writer.writeAll(")");
                    },
                    .node_scan => |scan| {
                        try writer.writeAll("node_scan(index=node_by_id,var=");
                        try writeEscapedText(writer, scan.var_name);
                        try writer.writeAll(",kind=");
                        try writeOptionalNodeKindName(writer, scan.kind);
                        try writer.writeAll(")");
                    },
                    .expand => |expand| {
                        try writer.writeAll("expand(index=");
                        try writeExpandIndexName(writer, expand.direction);
                        try writer.writeAll(",dir=");
                        try writer.writeAll(@tagName(expand.direction));
                        try writer.writeAll(",from=");
                        try writeEscapedText(writer, expand.left_var);
                        if (expand.edge_var) |edge_var| {
                            try writer.writeAll(",edge=");
                            try writeEscapedText(writer, edge_var);
                        }
                        try writer.writeAll(",to=");
                        try writeEscapedText(writer, expand.right_var);
                        try writer.writeAll(",rel=");
                        try writeOptionalRelKindName(writer, expand.rel);
                        try writer.print(",hops={}..{}", .{ expand.min_hops, expand.max_hops });
                        if (expand.right_text_eq != null) try writer.writeAll(",post_filter=right_name");
                        if (expand.edge_property_eq != null) try writer.writeAll(",post_filter=edge_property,index=property_payload");
                        try writer.writeAll(")");
                    },
                    .order_by => |order_by| {
                        try writer.writeAll("order_by(sort=rows,index_hint=node_props,var=");
                        try writeEscapedText(writer, order_by.var_name);
                        try writer.writeAll(",property=");
                        try writeEscapedText(writer, order_by.property);
                        try writer.writeAll(",dir=");
                        try writer.writeAll(@tagName(order_by.direction));
                        try writer.writeAll(")");
                    },
                    .project => |project| try writer.print("project(cols={})", .{project.len}),
                    .limit => |limit| try writer.print("limit(n={})", .{limit}),
                }
            }
        }

        fn renderOperatorTimings(writer: anytype, timings: []const ql.executor.OperatorTiming) !void {
            if (timings.len == 0) {
                try writer.writeAll("none");
                return;
            }
            for (timings, 0..) |timing, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print(
                    "{}:{s}:ns={}:in={}:out={}:nodes={}:edges={}:budget={}",
                    .{
                        timing.op_index,
                        timing.op_name,
                        timing.elapsed_ns,
                        timing.input_rows,
                        timing.output_rows,
                        timing.nodes_visited_delta,
                        timing.edges_visited_delta,
                        @intFromBool(timing.budget_exceeded),
                    },
                );
            }
        }

        fn writeExpandIndexName(writer: anytype, direction: ql.ast.EdgeDirection) !void {
            switch (direction) {
                .outgoing => try writer.writeAll("edge_by_src"),
                .incoming => try writer.writeAll("edge_by_dst"),
                .undirected => try writer.writeAll("edge_by_src+edge_by_dst"),
            }
        }

        fn writeOptionalNodeKindName(writer: anytype, kind: ?core.NodeKind) !void {
            if (kind) |value| {
                try writeNodeKindName(writer, value);
            } else {
                try writer.writeAll("any");
            }
        }

        fn writeOptionalRelKindName(writer: anytype, rel: ?core.RelKind) !void {
            if (rel) |value| {
                try writeRelKindName(writer, value);
            } else {
                try writer.writeAll("any");
            }
        }

        fn writeProjectionSegment(
            writer: anytype,
            catalog: *const segment_node_index.MappedCatalog,
            row: ql.executor.Row,
            projection: ql.ast.Projection,
        ) !void {
            switch (projection) {
                .variable => |var_name| {
                    const id = row.get(var_name) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    const node = (try catalog.nodeInfo(id)) orelse return error.InvalidRecord;
                    try writer.print("{}:", .{node.id.toInt()});
                    try writeNodeKindName(writer, node.kind);
                    try writer.writeAll(":");
                    try writeEscapedText(writer, markdownProjectionVisibleText(node.text));
                },
                .property => |property| {
                    const id = row.get(property.var_name) orelse {
                        try writer.writeAll("null");
                        return;
                    };
                    const node = (try catalog.nodeInfo(id)) orelse return error.InvalidRecord;
                    if (std.mem.eql(u8, property.property, "text")) {
                        try writeEscapedText(writer, markdownProjectionVisibleText(node.text));
                    } else if (std.mem.eql(u8, property.property, "name") or std.mem.eql(u8, property.property, "summary")) {
                        try writer.writeAll("");
                    } else {
                        try writer.writeAll("null");
                    }
                },
                .path, .reachable, .context, .score => return error.Unsupported,
            }
        }

        const ProjectionExplainSink = struct {
            pub fn writeAll(_: *ProjectionExplainSink, _: []const u8) !void {}

            pub fn print(_: *ProjectionExplainSink, comptime _: []const u8, _: anytype) !void {}
        };

        const CountingProjectionSink = struct {
            allocator: std.mem.Allocator,
            bytes: usize = 0,

            fn writeAll(self: *CountingProjectionSink, bytes: []const u8) !void {
                self.bytes = std.math.add(usize, self.bytes, bytes.len) catch return error.RecordTooLarge;
            }

            fn print(self: *CountingProjectionSink, comptime fmt: []const u8, args: anytype) !void {
                const text = try std.fmt.allocPrint(self.allocator, fmt, args);
                defer self.allocator.free(text);
                try self.writeAll(text);
            }
        };

        fn accumulateProjectionExplainStats(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
            physical: ql.optimizer.PhysicalPlan,
            table: ql.executor.ResultTable,
            budget: core.QueryBudget,
            stats: *query_index.QueryStats,
        ) !bool {
            const projections = physicalProjections(physical) orelse return error.InvalidPlan;
            var sink = ProjectionExplainSink{};
            var node_view: ?storage.Store.NodeRecordView = null;
            defer if (node_view) |*view| view.deinit();
            if (table.rows.items.len > 0 and projectionsNeedPersistentNodes(projections)) {
                node_view = try store.openNodeRecordView();
            }
            var status_snapshot = try initTaskStatusProjectionSnapshot(
                allocator,
                store,
                if (node_view) |*view| view else null,
                table.rows.items,
                projections,
            );
            defer if (status_snapshot) |*snapshot| snapshot.deinit();
            const read_timestamp_ns = table.read_timestamp_ns orelse try u128ToU64(persistentNowNs(store.io));
            for (table.rows.items) |row| {
                for (projections) |projection| {
                    var projection_stats: query_index.QueryStats = .{};
                    writeProjectionPersistent(&sink, allocator, store, edge_retention_registry, if (node_view) |*view| view else null, if (status_snapshot) |*snapshot| snapshot else null, read_timestamp_ns, row, projection, budget, &projection_stats) catch |err| {
                        try mergeProjectionStats(stats, projection_stats);
                        switch (err) {
                            core.Error.BudgetExceeded => return true,
                            else => |e| return e,
                        }
                    };
                    try mergeProjectionStats(stats, projection_stats);
                }
            }
            return false;
        }

        fn projectionsNeedPersistentNodes(projections: []const ql.ast.Projection) bool {
            for (projections) |projection| {
                switch (projection) {
                    .variable, .property, .path, .context => return true,
                    .reachable, .score => {},
                }
            }
            return false;
        }

        fn initTaskStatusProjectionSnapshot(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: ?*storage.Store.NodeRecordView,
            rows: []const ql.executor.Row,
            projections: []const ql.ast.Projection,
        ) !?task.StatusSnapshot {
            var status_vars = std.ArrayList([]const u8).empty;
            defer status_vars.deinit(allocator);
            for (projections) |projection| switch (projection) {
                .property => |property| {
                    if (std.mem.eql(u8, property.property, task.status_property)) {
                        try status_vars.append(allocator, property.var_name);
                    }
                },
                else => {},
            };
            if (status_vars.items.len == 0 or rows.len == 0) return null;

            const view = node_view orelse return error.InvalidPlan;
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();
            var task_ids = std.ArrayList(core.NodeId).empty;
            defer task_ids.deinit(allocator);
            for (rows) |row| {
                for (status_vars.items) |var_name| {
                    const node_id = row.get(var_name) orelse continue;
                    const entry = try seen.getOrPut(node_id.toInt());
                    if (entry.found_existing) continue;
                    const node_ref = (try view.readNodeRefById(node_id)) orelse return error.InvalidRecord;
                    if (node_ref.kind == .task) try task_ids.append(allocator, node_id);
                }
            }
            if (task_ids.items.len == 0) return null;
            return try task.StatusSnapshot.initForNodeIds(allocator, store, task_ids.items);
        }

        fn mergeProjectionStats(stats: *query_index.QueryStats, projection_stats: query_index.QueryStats) !void {
            const nodes_visited = std.math.add(usize, stats.nodes_visited, projection_stats.nodes_visited) catch return error.RecordTooLarge;
            const edges_visited = std.math.add(usize, stats.edges_visited, projection_stats.edges_visited) catch return error.RecordTooLarge;
            stats.nodes_visited = nodes_visited;
            stats.edges_visited = edges_visited;
        }

        fn physicalProjections(physical: ql.optimizer.PhysicalPlan) ?[]const ql.ast.Projection {
            for (physical.ops.items) |op| {
                switch (op) {
                    .project => |project| return project,
                    else => {},
                }
            }
            return null;
        }

        const list_recent_tombstone_prefix = "__tinykg_deleted_node__";
        // project 子树扫描取节点上限:足够覆盖任何现实项目(取全量再降序取尾 K 需覆盖全域,
        // 否则会漏掉最新节点——BFS 返回的是遍历序而非 id 序,截断取的是任意子集)。
        pub const list_recent_project_scan_cap: usize = 100_000;

        fn nodeIdDescLessThan(_: void, a: core.NodeId, b: core.NodeId) bool {
            return a.toInt() > b.toInt();
        }

        // 墓碑排除:删除把节点重写成 kind=.edit + text `__tinykg_deleted_node__ N`,by_id 记录仍在,
        // readNodeRefById 会把它当存活返回 → 必须显式过滤(search 层另有专门排除,list-recent 绕开它)。
        fn nodeRefIsTombstone(
            node_view: *const storage.Store.NodeRecordView,
            node_ref: storage.Store.NodeRecordView.NodeRef,
        ) !bool {
            if (node_ref.kind != .edit) return false;
            const text = (try node_view.readNodeRefTextBorrowed(node_ref)) orelse return false;
            return std.mem.startsWith(u8, text, list_recent_tombstone_prefix);
        }

        fn emitListRecentRow(
            out: *QueryOutputWriter,
            node_view: *const storage.Store.NodeRecordView,
            store: storage.Store,
            allocator: std.mem.Allocator,
            node_ref: storage.Store.NodeRecordView.NodeRef,
            with_type: bool,
        ) !void {
            const text = try node_view.readNodeRefTextAlloc(allocator, node_ref);
            defer allocator.free(text);
            try out.print("{}\t", .{node_ref.id.toInt()});
            try writeNodeKindName(out, node_ref.kind);
            try out.writeAll("\t");
            if (with_type) {
                // schema_type 作第 3 列(缺省空)。属性读一次/节点(list-recent 低频,可接受)。
                const st = (try store.getNodeStringProperty(allocator, node_ref.id, "schema_type")) orelse try allocator.dupe(u8, "");
                defer allocator.free(st);
                try writeEscapedText(out, st);
                try out.writeAll("\t");
            }
            try writeEscapedText(out, text);
            try out.writeAll("\n");
        }

        // list-recent:按 id 降序(= 创建序,id 单调递增;created_at 是可选 property 不可假设都有)列最近节点。
        // 绕开全文检索层 → 无召回门槛/排序污染(替换 KgClient 里用虚词 search 冒充枚举的 hack)。
        pub fn renderListRecentOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            project: ?[]const u8,
            kind_filter: ?core.NodeKind,
            limit: usize,
            with_type: bool,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            if (limit == 0) return out.buffer.toOwnedSlice(allocator);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();

            if (project) |proj| {
                // project 子树:取该项目全部后代节点 id,显式降序(BFS 返回遍历序非 id 序),取尾 limit,跳墓碑。
                var scan_truncated = false;
                // task_composition 下钻(contain + contains):锚下任务树可见——旧 contain-only 是
                // "任务节点全部直挂 project"这个拍平形状存在的真原因,挂根不直挂后不下钻就漏成员。
                // 刻意**不含 md:***:section 碎片会淹没最近清单,文档以根代表(e2e 有断言钉住)。
                var ids = try collectProjectDescendantNodeIds(allocator, store, try parseNodeIdArg(proj), kind_filter, list_recent_project_scan_cap, &scan_truncated, .task_composition);
                defer ids.deinit(allocator);
                std.mem.sort(core.NodeId, ids.items, {}, nodeIdDescLessThan);
                var emitted: usize = 0;
                for (ids.items) |id| {
                    if (emitted >= limit) break;
                    const node_ref = (try node_view.readNodeRefById(id)) orelse continue;
                    if (try nodeRefIsTombstone(&node_view, node_ref)) continue;
                    try emitListRecentRow(&out, &node_view, store, allocator, node_ref, with_type);
                    emitted += 1;
                }
                // cap 截断不静默(Linus):`#` 前缀诊断行,TSV 消费方按列解析会自然跳过。
                if (scan_truncated) try out.print("# project_scan_truncated=1 cap={d}\n", .{list_recent_project_scan_cap});
            } else {
                // 无 project:从 max id 反向直查,收满 limit 个存活节点即停(O(limit + 空洞/墓碑))。
                const next = try store.nextNodeId();
                var id = next.toInt();
                var emitted: usize = 0;
                while (id > 1 and emitted < limit) {
                    id -= 1;
                    const node_ref = (try node_view.readNodeRefById(core.NodeId.fromInt(id))) orelse continue;
                    if (kind_filter) |kf| {
                        if (node_ref.kind != kf) continue;
                    }
                    if (try nodeRefIsTombstone(&node_view, node_ref)) continue;
                    try emitListRecentRow(&out, &node_view, store, allocator, node_ref, with_type);
                    emitted += 1;
                }
            }
            return out.buffer.toOwnedSlice(allocator);
        }

        /// search 成员过滤诊断(输出端显式上报,截断绝不静默)。
        pub const MemberFilterDiag = struct {
            active: bool = false,
            project_scan_truncated: bool = false,
            schema_scan_truncated: bool = false,
        };

        /// schema_type 成员集扫描上限(property 索引 lookup;超出置 truncated 诊断)。
        const schema_type_scan_cap: usize = 100_000;

        /// search server-side 成员集:--project(contain 子树 BFS,含 composition 下钻)
        /// ∩ --schema-type(property 索引成员集)。两者都 null → null(不过滤)。
        /// 截断(cap)一律写进 diag,输出端上报——静默截断 = 三个月后有人对着空结果查一天。
        pub fn buildSearchMemberSet(
            allocator: std.mem.Allocator,
            store: storage.Store,
            project: ?[]const u8,
            schema_type: ?[]const u8,
            diag: *MemberFilterDiag,
        ) !?std.AutoHashMap(u64, void) {
            var member: ?std.AutoHashMap(u64, void) = null;
            errdefer if (member) |*m| m.deinit();

            if (project) |proj| {
                diag.active = true;
                const proj_id = try parseNodeIdArg(proj);
                // search membership:含 composition 后代(document→section;task 树同理)。
                var ids = try collectProjectDescendantNodeIds(allocator, store, proj_id, null, list_recent_project_scan_cap, &diag.project_scan_truncated, .full_composition);
                defer ids.deinit(allocator);
                var m = std.AutoHashMap(u64, void).init(allocator);
                errdefer m.deinit();
                for (ids.items) |id| try m.put(id.toInt(), {});
                member = m;
            }
            if (schema_type) |st| {
                diag.active = true;
                var ids = try store.lookupNodeIdsByStringProperty(allocator, "schema_type", st, null, schema_type_scan_cap);
                defer ids.deinit(allocator);
                if (ids.items.len >= schema_type_scan_cap) diag.schema_scan_truncated = true;
                if (member) |*m| {
                    // 交集:project 子树 ∩ schema_type。
                    var both = std.AutoHashMap(u64, void).init(allocator);
                    errdefer both.deinit();
                    for (ids.items) |id| {
                        if (m.contains(id.toInt())) try both.put(id.toInt(), {});
                    }
                    m.deinit();
                    member = both;
                } else {
                    var m = std.AutoHashMap(u64, void).init(allocator);
                    errdefer m.deinit();
                    for (ids.items) |id| try m.put(id.toInt(), {});
                    member = m;
                }
            }
            return member;
        }

        pub fn renderSearchOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            search_query: []const u8,
            options: text_search.TextSearchOptions,
            profile: TextBudgetProfile,
            output_limit: usize,
            include_history: bool,
            filter_diag: MemberFilterDiag,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            var embedded_catalog = try store.readCatalog();
            defer if (embedded_catalog) |*cat| cat.deinit();
            const registry: ?schema.Registry = if (embedded_catalog) |cat| cat.registry else null;

            var hits = try text_search.searchText(allocator, store, search_query, options);
            defer hits.deinit(allocator);
            if (hits.items.len == 0 or output_limit == 0) {
                try appendMemberFilterDiagText(&out, filter_diag);
                return out.buffer.toOwnedSlice(allocator);
            }

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();

            if (profile == .agent_memory and options.kind_filter == null) {
                std.mem.sort(text_search.TextSearchHit, hits.items, {}, textSearchHitAgentMemoryLessThan);
            }

            var emitted: usize = 0;
            for (hits.items) |hit| {
                if (emitted >= output_limit) break;
                if (!include_history and !try nodeIsCurrentGeneration(store, hit.node_id)) continue;
                const node_ref = (try node_view.readNodeRefById(hit.node_id)) orelse return error.InvalidRecord;
                if (node_ref.kind != hit.kind) return error.InvalidRecord;
                const text = try node_view.readNodeRefTextAlloc(allocator, node_ref);
                defer allocator.free(text);
                try out.print("{}\t", .{hit.node_id.toInt()});
                try writeNodeKindNameWithSchema(&out, registry, hit.kind);
                try out.writeAll("\t");
                try writeEscapedText(&out, text);
                try out.print("\t{d:.6}\n", .{hit.score});
                emitted += 1;
            }

            try appendMemberFilterDiagText(&out, filter_diag);

            return out.buffer.toOwnedSlice(allocator);
        }

        /// 成员过滤截断诊断(`#` 诊断行,TSV 按列解析自然跳过)。截断绝不静默(Linus)。
        /// 注:过滤已 server-side 下推(截断前生效),旧 candidate_window_saturated 语义不再成立,已删。
        fn appendMemberFilterDiagText(out: *QueryOutputWriter, diag: MemberFilterDiag) !void {
            if (!diag.active) return;
            if (diag.project_scan_truncated) try out.print("# project_scan_truncated=1 cap={d}\n", .{list_recent_project_scan_cap});
            if (diag.schema_scan_truncated) try out.print("# schema_type_scan_truncated=1 cap={d}\n", .{schema_type_scan_cap});
        }

        pub fn renderSearchJsonOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            search_query: []const u8,
            options: text_search.TextSearchOptions,
            profile: TextBudgetProfile,
            output_limit: usize,
            include_history: bool,
            include_text: bool,
            timeout_ms: u64,
            filter_diag: MemberFilterDiag,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            var embedded_catalog = try store.readCatalog();
            defer if (embedded_catalog) |*cat| cat.deinit();
            const registry: ?schema.Registry = if (embedded_catalog) |cat| cat.registry else null;

            const plan_stats = try text_search.textQueryPlanStats(allocator, store, search_query, options);
            var hits = try text_search.searchText(allocator, store, search_query, options);
            defer hits.deinit(allocator);

            if (profile == .agent_memory and options.kind_filter == null) {
                std.mem.sort(text_search.TextSearchHit, hits.items, {}, textSearchHitAgentMemoryLessThan);
            }

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();

            try writeJsonObjectStart(&out);
            var first = true;
            try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonStringField(&out, "query", search_query, &first);

            try writeJsonFieldPrefix(&out, "plan", &first);
            try out.writeAll("{");
            var plan_first = true;
            try writeJsonStringField(&out, "score_model", "bm25", &plan_first);
            try writeJsonStringField(&out, "profile", textBudgetProfileName(profile), &plan_first);
            try writeJsonFieldPrefix(&out, "kind_filter", &plan_first);
            if (options.kind_filter) |kind| {
                const kind_label = try nodeKindNameWithSchemaAlloc(allocator, registry, kind);
                defer allocator.free(kind_label);
                try writeJsonString(&out, kind_label);
            } else {
                try out.writeAll("null");
            }
            try writeJsonNumberField(&out, "query_terms", plan_stats.query_terms, &plan_first);
            try writeJsonNumberField(&out, "unique_query_terms", plan_stats.unique_query_terms, &plan_first);
            try writeJsonNumberField(&out, "matched_terms", plan_stats.matched_terms, &plan_first);
            try writeJsonNumberField(&out, "postings_planned", plan_stats.postings_count_total, &plan_first);
            try writeJsonNumberField(&out, "max_term_postings", plan_stats.max_postings_count, &plan_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "budget", &first);
            try out.writeAll("{");
            var budget_first = true;
            try writeJsonNumberField(&out, "max_nodes", output_limit, &budget_first);
            try writeJsonNumberField(&out, "candidate_limit", options.limit, &budget_first);
            try writeJsonNumberField(&out, "max_postings", options.max_postings_scanned, &budget_first);
            // 成员过滤截断诊断(server-side 下推后 candidate_saturated 语义不再成立,已删)。
            if (filter_diag.active) {
                try writeJsonBoolField(&out, "project_scan_truncated", filter_diag.project_scan_truncated, &budget_first);
                try writeJsonBoolField(&out, "schema_scan_truncated", filter_diag.schema_scan_truncated, &budget_first);
            }
            try writeJsonNumberField(&out, "timeout_ms", timeout_ms, &budget_first);
            try writeJsonNumberField(&out, "postings_planned", plan_stats.postings_count_total, &budget_first);
            try out.writeAll("}");

            var emitted: usize = 0;
            var omitted_history: usize = 0;
            var used_chars: usize = 0;
            var truncated = false;
            try writeJsonFieldPrefix(&out, "hits", &first);
            try out.writeAll("[");
            var first_hit = true;
            for (hits.items) |hit| {
                if (emitted >= output_limit) {
                    truncated = true;
                    break;
                }
                if (!include_history and !try nodeIsCurrentGeneration(store, hit.node_id)) {
                    omitted_history += 1;
                    continue;
                }
                var node = (try node_view.readNodeById(allocator, hit.node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                if (node.kind != hit.kind) return error.InvalidRecord;
                const size = try computeTextContextSize(node.text);
                used_chars = std.math.add(usize, used_chars, size.text_chars) catch return error.RecordTooLarge;
                if (!first_hit) try out.writeAll(",");
                first_hit = false;
                try out.writeAll("{");
                var hit_first = true;
                try writeJsonNumberField(&out, "rank", emitted + 1, &hit_first);
                try writeJsonFieldPrefix(&out, "score", &hit_first);
                try out.print("{d:.6}", .{hit.score});
                try writeJsonFieldPrefix(&out, "node", &hit_first);
                try renderNodeObjectJsonWithSchema(&out, allocator, store, registry, node, include_text);
                try writeJsonFieldPrefix(&out, "why", &hit_first);
                try out.writeAll("{");
                var why_first = true;
                try writeJsonStringField(&out, "score_model", "bm25", &why_first);
                try writeJsonStringField(&out, "matched_fields", "name", &why_first);
                try writeJsonNumberField(&out, "matched_query_terms", plan_stats.matched_terms, &why_first);
                try out.writeAll("}");
                try writeJsonFieldPrefix(&out, "continuations", &hit_first);
                try out.writeAll("[");
                try writeSearchContinuation(&out, "inspect_metadata", hit.node_id, "inspect node metadata before expanding text");
                try out.writeAll(",");
                try writeSearchContinuation(&out, "neighbors", hit.node_id, "estimate local graph expansion cost");
                try out.writeAll("]");
                try out.writeAll("}");
                emitted += 1;
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "summary", &first);
            try out.writeAll("{");
            var summary_first = true;
            try writeJsonNumberField(&out, "hit_count", emitted, &summary_first);
            try writeJsonNumberField(&out, "candidate_count", hits.items.len, &summary_first);
            try writeJsonNumberField(&out, "omitted_history", omitted_history, &summary_first);
            try writeJsonBoolField(&out, "truncated", truncated, &summary_first);
            try writeJsonNullableStringField(&out, "truncate_reason", if (truncated) "max_nodes" else null, &summary_first);
            try writeJsonNumberField(&out, "used_nodes", emitted, &summary_first);
            try writeJsonNumberField(&out, "used_chars", used_chars, &summary_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "diagnostics", &first);
            try out.writeAll("{");
            var diagnostics_first = true;
            const unmatched_terms = if (plan_stats.unique_query_terms >= plan_stats.matched_terms) plan_stats.unique_query_terms - plan_stats.matched_terms else 0;
            try writeJsonNumberField(&out, "unmatched_terms_count", unmatched_terms, &diagnostics_first);
            try writeJsonBoolField(&out, "include_history", include_history, &diagnostics_first);
            try writeJsonStringField(&out, "next_step", if (emitted == 0) "try another lexical query or inspect task frontier" else "inspect metadata, then expand selected neighbors or raw text", &diagnostics_first);
            try out.writeAll("}");

            try writeJsonObjectEnd(&out);
            return out.buffer.toOwnedSlice(allocator);
        }

        fn contextSearchOptions(io: std.Io, args: ParsedContextArgs) text_search.TextSearchOptions {
            return .{
                .limit = searchCandidateLimit(args.profile, null, args.limit, args.include_history),
                .max_postings_scanned = args.max_postings_scanned,
                .deadline = core.QueryDeadline.fromIo(io, args.timeout_ms),
            };
        }

        fn renderContextBudgetJson(out: *QueryOutputWriter, args: ParsedContextArgs) !void {
            try out.writeAll("{");
            var first = true;
            try writeJsonNumberField(out, "max_search_hits", args.limit, &first);
            try writeJsonNumberField(out, "max_nodes", args.max_nodes, &first);
            try writeJsonNumberField(out, "max_edges", args.max_edges, &first);
            try writeJsonNumberField(out, "max_chars", args.max_chars, &first);
            try writeJsonNumberField(out, "max_postings", args.max_postings_scanned, &first);
            try writeJsonNumberField(out, "timeout_ms", args.timeout_ms, &first);
            try writeJsonNumberField(out, "neighbor_depth", args.neighbor_depth, &first);
            try writeJsonNumberField(out, "markdown_preview_lines", args.markdown_preview_lines, &first);
            try out.writeAll("}");
        }

        fn writeJsonNullableNodeIdField(out: *QueryOutputWriter, field: []const u8, node_id: ?core.NodeId, first: *bool) !void {
            try writeJsonFieldPrefix(out, field, first);
            if (node_id) |id| {
                try out.print("{}", .{id.toInt()});
            } else {
                try out.writeAll("null");
            }
        }

        fn writeContextStep(out: *QueryOutputWriter, action: []const u8, args_text: []const u8, reason: []const u8) !void {
            try out.writeAll("{");
            var first = true;
            try writeJsonStringField(out, "action", action, &first);
            try writeJsonStringField(out, "args", args_text, &first);
            try writeJsonStringField(out, "reason", reason, &first);
            try out.writeAll("}");
        }

        fn writeJsonCommandArgPrefix(out: *QueryOutputWriter, first: *bool) !void {
            if (first.*) {
                first.* = false;
            } else {
                try out.writeAll(",");
            }
        }

        fn writeJsonCommandStringArg(out: *QueryOutputWriter, value: []const u8, first: *bool) !void {
            try writeJsonCommandArgPrefix(out, first);
            try writeJsonString(out, value);
        }

        fn writeJsonCommandNumberArg(out: *QueryOutputWriter, value: anytype, first: *bool) !void {
            try writeJsonCommandArgPrefix(out, first);
            try out.writeAll("\"");
            try out.print("{}", .{value});
            try out.writeAll("\"");
        }

        fn writeContextCommand(out: *QueryOutputWriter, subcommand: []const u8, args: ParsedContextArgs, limit: usize, max_postings: usize, max_chars: usize) !void {
            try out.writeAll("[");
            var first = true;
            try writeJsonCommandStringArg(out, "tinykg", &first);
            try writeJsonCommandStringArg(out, subcommand, &first);
            try writeJsonCommandStringArg(out, args.db_path, &first);
            try writeJsonCommandStringArg(out, args.query, &first);
            if (args.task_id) |task_id| {
                try writeJsonCommandStringArg(out, "--task", &first);
                try writeJsonCommandNumberArg(out, task_id.toInt(), &first);
            }
            if (args.root_node_id) |node_id| {
                try writeJsonCommandStringArg(out, "--node", &first);
                try writeJsonCommandNumberArg(out, node_id.toInt(), &first);
            }
            try writeJsonCommandStringArg(out, "--limit", &first);
            try writeJsonCommandNumberArg(out, limit, &first);
            try writeJsonCommandStringArg(out, "--profile", &first);
            try writeJsonCommandStringArg(out, textBudgetProfileName(args.profile), &first);
            try writeJsonCommandStringArg(out, "--max-postings", &first);
            try writeJsonCommandNumberArg(out, max_postings, &first);
            try writeJsonCommandStringArg(out, "--timeout-ms", &first);
            try writeJsonCommandNumberArg(out, args.timeout_ms, &first);
            if (args.include_history) try writeJsonCommandStringArg(out, "--include-history", &first);
            try writeJsonCommandStringArg(out, "--format", &first);
            try writeJsonCommandStringArg(out, "json", &first);
            try writeJsonCommandStringArg(out, "--meta", &first);
            try writeJsonCommandStringArg(out, "--neighbor-depth", &first);
            try writeJsonCommandNumberArg(out, args.neighbor_depth, &first);
            try writeJsonCommandStringArg(out, "--max-nodes", &first);
            try writeJsonCommandNumberArg(out, args.max_nodes, &first);
            try writeJsonCommandStringArg(out, "--max-edges", &first);
            try writeJsonCommandNumberArg(out, args.max_edges, &first);
            try writeJsonCommandStringArg(out, "--max-chars", &first);
            try writeJsonCommandNumberArg(out, max_chars, &first);
            try writeJsonCommandStringArg(out, "--markdown-preview-lines", &first);
            try writeJsonCommandNumberArg(out, args.markdown_preview_lines, &first);
            try out.writeAll("]");
        }

        fn writeContextPacketCommand(out: *QueryOutputWriter, args: ParsedContextArgs, limit: usize, max_postings: usize, max_chars: usize) !void {
            try writeContextCommand(out, "context-packet", args, limit, max_postings, max_chars);
        }

        fn writeContextPlanCommand(out: *QueryOutputWriter, args: ParsedContextArgs, limit: usize, max_postings: usize, max_chars: usize) !void {
            try writeContextCommand(out, "context-plan", args, limit, max_postings, max_chars);
        }

        fn writeNeighborsCommand(out: *QueryOutputWriter, args: ParsedContextArgs, node_id: core.NodeId) !void {
            try out.writeAll("[");
            var first = true;
            try writeJsonCommandStringArg(out, "tinykg", &first);
            try writeJsonCommandStringArg(out, "neighbors", &first);
            try writeJsonCommandStringArg(out, args.db_path, &first);
            try writeJsonCommandNumberArg(out, node_id.toInt(), &first);
            try writeJsonCommandStringArg(out, "--format", &first);
            try writeJsonCommandStringArg(out, "json", &first);
            try writeJsonCommandStringArg(out, "--meta", &first);
            try writeJsonCommandStringArg(out, "--depth", &first);
            try writeJsonCommandNumberArg(out, args.neighbor_depth, &first);
            try writeJsonCommandStringArg(out, "--max-nodes", &first);
            try writeJsonCommandNumberArg(out, args.max_nodes, &first);
            try writeJsonCommandStringArg(out, "--max-edges", &first);
            try writeJsonCommandNumberArg(out, args.max_edges, &first);
            try writeJsonCommandStringArg(out, "--max-chars", &first);
            try writeJsonCommandNumberArg(out, args.max_chars, &first);
            try out.writeAll("]");
        }

        fn writeRenderMarkdownCommand(out: *QueryOutputWriter, args: ParsedContextArgs, node_id: core.NodeId) !void {
            try out.writeAll("[");
            var first = true;
            try writeJsonCommandStringArg(out, "tinykg", &first);
            try writeJsonCommandStringArg(out, "render-md-doc", &first);
            try writeJsonCommandStringArg(out, args.db_path, &first);
            try writeJsonCommandNumberArg(out, node_id.toInt(), &first);
            try writeJsonCommandStringArg(out, "--format", &first);
            try writeJsonCommandStringArg(out, "json", &first);
            try writeJsonCommandStringArg(out, "--meta", &first);
            try writeJsonCommandStringArg(out, "--preview-lines", &first);
            try writeJsonCommandNumberArg(out, args.markdown_preview_lines, &first);
            try out.writeAll("]");
        }

        fn writeContextCommandContinuationPrefix(out: *QueryOutputWriter, action: []const u8, reason: []const u8) !bool {
            try out.writeAll("{");
            var first = true;
            try writeJsonStringField(out, "action", action, &first);
            try writeJsonStringField(out, "reason", reason, &first);
            return first;
        }

        pub fn renderContextPlanJsonOutput(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            args: ParsedContextArgs,
        ) ![]u8 {
            const options = contextSearchOptions(io, args);
            const plan_stats = try text_search.textQueryPlanStats(allocator, store, args.query, options);

            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try writeJsonObjectStart(&out);
            var first = true;
            try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonStringField(&out, "mode", "context-plan", &first);

            try writeJsonFieldPrefix(&out, "query", &first);
            try out.writeAll("{");
            var query_first = true;
            try writeJsonStringField(&out, "text", args.query, &query_first);
            try writeJsonNullableNodeIdField(&out, "task_id", args.task_id, &query_first);
            try writeJsonNullableNodeIdField(&out, "root_node_id", args.root_node_id, &query_first);
            try writeJsonBoolField(&out, "include_history", args.include_history, &query_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "budget", &first);
            try renderContextBudgetJson(&out, args);

            try writeJsonFieldPrefix(&out, "plan", &first);
            try out.writeAll("{");
            var plan_first = true;
            try writeJsonStringField(&out, "score_model", "bm25", &plan_first);
            try writeJsonStringField(&out, "profile", textBudgetProfileName(args.profile), &plan_first);
            try writeJsonNumberField(&out, "query_terms", plan_stats.query_terms, &plan_first);
            try writeJsonNumberField(&out, "unique_query_terms", plan_stats.unique_query_terms, &plan_first);
            try writeJsonNumberField(&out, "matched_terms", plan_stats.matched_terms, &plan_first);
            try writeJsonNumberField(&out, "postings_planned", plan_stats.postings_count_total, &plan_first);
            try writeJsonNumberField(&out, "max_term_postings", plan_stats.max_postings_count, &plan_first);
            try writeJsonStringField(&out, "retrieval_order", "search -> focus metadata -> task packet -> neighbors -> markdown previews", &plan_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "steps", &first);
            try out.writeAll("[");
            try writeContextStep(&out, "search", "bounded bm25 over node texts", "find lexical anchors with scores and matched-term diagnostics");
            try out.writeAll(",");
            try writeContextStep(&out, "inspect_metadata", "selected task/node/search hits", "read schema, context_size, generation status, and local graph fanout before raw text");
            if (args.task_id != null) {
                try out.writeAll(",");
                try writeContextStep(&out, "task-packet", "bounded task DAG packet", "recover parent, dependencies, blockers, recent child rounds, and verification evidence");
            }
            try out.writeAll(",");
            try writeContextStep(&out, "neighbors", "bounded local subgraphs for focus nodes", "estimate expansion cost and gather adjacent graph context");
            try out.writeAll(",");
            try writeContextStep(&out, "render-md-doc", "bounded markdown previews for document nodes", "preview markdown without dumping full rendered documents");
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "continuations", &first);
            try out.writeAll("[");
            try out.writeAll("{");
            var cont_first = true;
            try writeJsonStringField(&out, "action", "context-packet", &cont_first);
            try writeJsonStringField(&out, "reason", "execute this plan and return compact context sections", &cont_first);
            try writeJsonFieldPrefix(&out, "command", &cont_first);
            const suggested_max_postings = @max(args.max_postings_scanned, plan_stats.postings_count_total);
            try writeContextPacketCommand(&out, args, args.limit, suggested_max_postings, args.max_chars);
            try out.writeAll("}");
            try out.writeAll("]");

            try writeJsonObjectEnd(&out);
            return out.buffer.toOwnedSlice(allocator);
        }

        fn appendUniqueContextNodeId(allocator: std.mem.Allocator, node_ids: *std.ArrayList(core.NodeId), node_id: core.NodeId, max_len: usize) !bool {
            for (node_ids.items) |existing| {
                if (existing.toInt() == node_id.toInt()) return true;
            }
            if (node_ids.items.len >= max_len) return false;
            try node_ids.append(allocator, node_id);
            return true;
        }

        fn contextSubBudget(total: usize, roots: usize) usize {
            if (roots == 0) return total;
            return @max(@as(usize, 1), total / roots);
        }

        const ContextPacketTextBudget = struct {
            max_chars: usize,
            used_bytes: usize = 0,
            used_chars: usize = 0,
            used_lines: usize = 0,
            requested_bytes: usize = 0,
            requested_chars: usize = 0,
            requested_lines: usize = 0,
            truncated: bool = false,
            truncate_reason: ?[]const u8 = null,
            omitted_texts: usize = 0,

            fn take(self: *ContextPacketTextBudget, text: []const u8) !struct { text: []const u8, truncated: bool } {
                if (text.len == 0) return .{ .text = text, .truncated = false };
                const full_size = try computeTextContextSize(text);
                try self.addRequestedSize(full_size);
                if (self.used_chars <= self.max_chars and full_size.text_chars <= self.max_chars - self.used_chars) {
                    try self.addSize(full_size);
                    return .{ .text = text, .truncated = false };
                }
                self.markTruncated("max_chars");
                const remaining = self.max_chars -| self.used_chars;
                if (remaining == 0) {
                    self.omitted_texts = std.math.add(usize, self.omitted_texts, 1) catch return error.RecordTooLarge;
                    return .{ .text = "", .truncated = true };
                }
                const prefix_end = markdownUtf8PrefixEndByChars(text, 0, remaining);
                const prefix = text[0..prefix_end];
                try self.addSize(try computeTextContextSize(prefix));
                return .{ .text = prefix, .truncated = prefix.len < text.len };
            }

            fn addSize(self: *ContextPacketTextBudget, size: TextContextSize) !void {
                self.used_bytes = std.math.add(usize, self.used_bytes, size.text_bytes) catch return error.RecordTooLarge;
                self.used_chars = std.math.add(usize, self.used_chars, size.text_chars) catch return error.RecordTooLarge;
                self.used_lines = std.math.add(usize, self.used_lines, size.text_lines) catch return error.RecordTooLarge;
            }

            fn addRequestedSize(self: *ContextPacketTextBudget, size: TextContextSize) !void {
                self.requested_bytes = std.math.add(usize, self.requested_bytes, size.text_bytes) catch return error.RecordTooLarge;
                self.requested_chars = std.math.add(usize, self.requested_chars, size.text_chars) catch return error.RecordTooLarge;
                self.requested_lines = std.math.add(usize, self.requested_lines, size.text_lines) catch return error.RecordTooLarge;
            }

            fn markTruncated(self: *ContextPacketTextBudget, reason: []const u8) void {
                self.truncated = true;
                if (self.truncate_reason == null) self.truncate_reason = reason;
            }
        };

        fn renderContextPacketTextBudgetJson(out: *QueryOutputWriter, budget: ContextPacketTextBudget) !void {
            try out.writeAll("{");
            var first = true;
            try writeJsonFieldPrefix(out, "context_size", &first);
            try renderTextContextSizeAggregateJson(out, budget.used_bytes, budget.used_chars, budget.used_lines);
            try writeJsonFieldPrefix(out, "requested_context_size", &first);
            try renderTextContextSizeAggregateJson(out, budget.requested_bytes, budget.requested_chars, budget.requested_lines);
            try writeJsonNumberField(out, "max_chars", budget.max_chars, &first);
            try writeJsonBoolField(out, "truncated", budget.truncated, &first);
            try writeJsonNullableStringField(out, "truncate_reason", budget.truncate_reason, &first);
            try writeJsonNumberField(out, "omitted_texts", budget.omitted_texts, &first);
            try out.writeAll("}");
        }

        fn renderContextNodeObjectJson(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            node: storage.StoredNode,
            budget: *ContextPacketTextBudget,
        ) !void {
            const kind_label = try nodeKindNameAlloc(allocator, node.kind);
            defer allocator.free(kind_label);
            const text_value = markdownProjectionVisibleText(node.text);
            const context_size = try computeTextContextSize(text_value);
            const logical_name = try store.getNodeStringProperty(allocator, node.id, "name");
            defer if (logical_name) |value| allocator.free(value);
            const logical_summary = try store.getNodeStringProperty(allocator, node.id, "summary");
            defer if (logical_summary) |value| allocator.free(value);
            const name_budget = try budget.take(logical_name orelse text_value);
            const deprecated_by = try nodeDeprecatedBy(store, node.id);
            const local_graph = try nodeLocalGraphStats(store, node.id);

            const schema_type = try store.getNodeStringProperty(allocator, node.id, "schema_type");
            defer if (schema_type) |value| allocator.free(value);
            const source_label = try store.getNodeStringProperty(allocator, node.id, "source_label");
            defer if (source_label) |v| allocator.free(v);
            const external_key = try store.getNodeStringProperty(allocator, node.id, "external_key");
            defer if (external_key) |value| allocator.free(value);

            try out.writeAll("{");
            var node_first = true;
            try writeJsonNumberField(out, "id", node.id.toInt(), &node_first);
            try writeJsonStringField(out, "kind", kind_label, &node_first);
            try writeJsonStringField(out, "name", name_budget.text, &node_first);
            try writeJsonBoolField(out, "name_truncated", name_budget.truncated, &node_first);

            try writeJsonFieldPrefix(out, "summary", &node_first);
            try out.writeAll("{");
            var summary_first = true;
            try writeJsonNullableStringField(out, "text", logical_summary, &summary_first);
            try writeJsonStringField(out, "source", if (logical_summary != null) "node_property" else "none", &summary_first);
            try writeJsonNullableStringField(out, "node_id", null, &summary_first);
            try writeJsonBoolField(out, "stale", false, &summary_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "schema", &node_first);
            try out.writeAll("{");
            var schema_first = true;
            try writeJsonNullableStringField(out, "schema_type", schema_type, &schema_first);
            try writeJsonNullableStringField(out, "external_key", external_key, &schema_first);
            try writeJsonNullableStringField(out, "source_label", source_label, &schema_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "context_size", &node_first);
            try renderTextContextSizeJson(out, context_size);

            try writeJsonFieldPrefix(out, "status", &node_first);
            try out.writeAll("{");
            var status_first = true;
            try writeJsonBoolField(out, "current_generation", deprecated_by == null, &status_first);
            try writeJsonFieldPrefix(out, "deprecated_by", &status_first);
            if (deprecated_by) |id| {
                try out.print("{}", .{id.toInt()});
            } else {
                try out.writeAll("null");
            }
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "expand", &node_first);
            try out.writeAll("{");
            var expand_first = true;
            try writeJsonBoolField(out, "has_text", node.text.len != 0, &expand_first);
            try writeJsonBoolField(out, "has_summary", logical_summary != null and logical_summary.?.len != 0, &expand_first);
            try writeJsonBoolField(out, "has_children", local_graph.out_degree != 0, &expand_first);
            try writeJsonStringField(out, "recommended", if (local_graph.out_degree != 0) "children_first" else "raw_text", &expand_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "local_graph", &node_first);
            try out.writeAll("{");
            var graph_first = true;
            try writeJsonNumberField(out, "in_degree", local_graph.in_degree, &graph_first);
            try writeJsonNumberField(out, "out_degree", local_graph.out_degree, &graph_first);
            try out.writeAll("}");

            try out.writeAll("}");
        }

        fn renderContextSubgraphJson(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            root_id: core.NodeId,
            result: SubgraphBuildResult,
            budget: *ContextPacketTextBudget,
        ) !void {
            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();

            try out.writeAll("{");
            var first = true;
            try writeJsonNumberField(out, "root_id", root_id.toInt(), &first);
            try writeJsonFieldPrefix(out, "summary", &first);
            try out.writeAll("{");
            var summary_first = true;
            try writeJsonNumberField(out, "node_count", result.node_ids.items.len, &summary_first);
            try writeJsonNumberField(out, "edge_count", result.edges.items.len, &summary_first);
            try writeJsonNumberField(out, "backref_count", result.backrefs.items.len, &summary_first);
            try writeJsonBoolField(out, "truncated", result.truncated, &summary_first);
            try writeJsonNullableStringField(out, "truncate_reason", result.truncate_reason, &summary_first);
            try writeJsonNumberField(out, "used_nodes", result.node_ids.items.len, &summary_first);
            try writeJsonNumberField(out, "used_edges", subgraphUsedEdgeRefs(result), &summary_first);
            try writeJsonNumberField(out, "used_chars", result.used_chars, &summary_first);
            try writeJsonNumberField(out, "edges_scanned", result.scanned_edges, &summary_first);
            try writeJsonFieldPrefix(out, "context_size", &summary_first);
            try renderTextContextSizeAggregateJson(out, result.used_bytes, result.used_chars, result.used_lines);
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "nodes", &first);
            try out.writeAll("[");
            for (result.node_ids.items, 0..) |node_id, index| {
                if (index != 0) try out.writeAll(",");
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                try renderContextNodeObjectJson(out, allocator, store, node, budget);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(out, "edges", &first);
            try out.writeAll("[");
            for (result.edges.items, 0..) |edge, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphEdgeJson(out, allocator, store, edge);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(out, "backrefs", &first);
            try out.writeAll("[");
            for (result.backrefs.items, 0..) |edge, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphEdgeJson(out, allocator, store, edge);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(out, "omitted", &first);
            try out.writeAll("[");
            for (result.omitted.items, 0..) |item, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphOmittedJson(out, item);
            }
            try out.writeAll("]");
            try out.writeAll("}");
        }

        fn renderContextTaskPacketJson(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            task_id: core.NodeId,
            args: ParsedContextArgs,
            budget: *ContextPacketTextBudget,
        ) !void {
            var task_node = (try store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
            defer task_node.deinit(allocator);
            if (task_node.kind != .task) return core.Error.InvalidId;

            const now_ns = try u128ToU64(persistentNowNs(store.io));
            const lifecycle = try task.statusForStoredNode(allocator, store, task_node, now_ns);
            const state: ?task.ReadyState = if (lifecycle.isTerminal()) null else try task.readyStateWithPersistentStoreAt(allocator, store, task_id, now_ns);
            const packet_args = ParsedTaskPacketArgs{
                .task_id = "",
                .limit = args.limit,
                .format = .json,
                .meta = true,
                .max_nodes = args.max_nodes,
                .max_edges = args.max_edges,
                .max_chars = args.max_chars,
            };
            const task_budget = taskPacketJsonBudget(packet_args);
            var result = try buildTaskPacketSubgraph(allocator, store, task_id, packet_args, task_budget);
            defer result.deinit(allocator);

            try out.writeAll("{");
            var first = true;
            try writeJsonNumberField(out, "task_id", task_id.toInt(), &first);
            try writeJsonStringField(out, "status", @tagName(lifecycle), &first);
            try writeJsonNullableStringField(out, "readiness", if (state) |value| @tagName(value) else null, &first);
            try writeJsonFieldPrefix(out, "root", &first);
            try renderContextNodeObjectJson(out, allocator, store, task_node, budget);
            try writeJsonFieldPrefix(out, "subgraph", &first);
            try renderContextSubgraphJson(out, allocator, store, task_id, result, budget);
            try out.writeAll("}");
        }

        fn renderContextMarkdownPreviewJson(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            node: storage.StoredNode,
            preview_lines: usize,
            budget: *ContextPacketTextBudget,
        ) !void {
            const rendered = try renderMarkdownDocument(allocator, store, node.id);
            defer allocator.free(rendered);
            const rendered_size = try computeTextContextSize(rendered);
            const preview = markdownPreviewPrefixLen(rendered, preview_lines);
            const section_stats = try markdownSubtreeSectionStats(allocator, store, node.id);

            try out.writeAll("{");
            var first = true;
            try writeJsonNumberField(out, "node_id", node.id.toInt(), &first);
            try writeJsonFieldPrefix(out, "node", &first);
            try renderContextNodeObjectJson(out, allocator, store, node, budget);
            try writeJsonFieldPrefix(out, "rendered_markdown", &first);
            try out.writeAll("{");
            var rendered_first = true;
            try writeJsonFieldPrefix(out, "context_size", &rendered_first);
            try renderTextContextSizeJson(out, rendered_size);
            const preview_budget = try budget.take(rendered[0..preview.len]);
            const preview_size = try computeTextContextSize(preview_budget.text);
            const preview_truncated = preview.truncated or preview_budget.truncated;
            const preview_truncate_reason: ?[]const u8 = if (preview_budget.truncated) "max_chars" else if (preview.truncated) "preview_lines" else null;
            try writeJsonNumberField(out, "preview_lines", if (preview_budget.truncated) preview_size.text_lines else preview.lines, &rendered_first);
            try writeJsonBoolField(out, "truncated", preview_truncated, &rendered_first);
            try writeJsonNullableStringField(out, "truncate_reason", preview_truncate_reason, &rendered_first);
            try writeJsonStringField(out, "preview", preview_budget.text, &rendered_first);
            try out.writeAll("}");
            try writeJsonFieldPrefix(out, "sections", &first);
            try out.writeAll("{");
            var sections_first = true;
            try writeJsonNumberField(out, "section_count", section_stats.section_count, &sections_first);
            try writeJsonFieldPrefix(out, "context_size", &sections_first);
            try renderTextContextSizeJson(out, section_stats.context_size);
            try out.writeAll("}");
            try out.writeAll("}");
        }

        pub fn renderContextPacketJsonOutput(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
            args: ParsedContextArgs,
        ) ![]u8 {
            const options = contextSearchOptions(io, args);
            const plan_stats = try text_search.textQueryPlanStats(allocator, store, args.query, options);
            var maybe_hits = text_search.searchText(allocator, store, args.query, options) catch |err| switch (err) {
                core.Error.BudgetExceeded => null,
                else => |e| return e,
            };
            defer if (maybe_hits) |*hits| hits.deinit(allocator);
            const search_budget_exceeded = maybe_hits == null;
            if (maybe_hits) |*hits| {
                if (args.profile == .agent_memory) {
                    std.mem.sort(text_search.TextSearchHit, hits.items, {}, textSearchHitAgentMemoryLessThan);
                }
            }

            var selected_hits = std.ArrayList(text_search.TextSearchHit).empty;
            defer selected_hits.deinit(allocator);
            var focus_node_ids = std.ArrayList(core.NodeId).empty;
            defer focus_node_ids.deinit(allocator);
            if (args.task_id) |id| _ = try appendUniqueContextNodeId(allocator, &focus_node_ids, id, args.max_nodes);
            if (args.root_node_id) |id| _ = try appendUniqueContextNodeId(allocator, &focus_node_ids, id, args.max_nodes);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var omitted_history: usize = 0;
            if (maybe_hits) |hits| {
                for (hits.items) |hit| {
                    if (selected_hits.items.len >= args.limit) break;
                    if (!args.include_history and !try nodeIsCurrentGeneration(store, hit.node_id)) {
                        omitted_history += 1;
                        continue;
                    }
                    try selected_hits.append(allocator, hit);
                    _ = try appendUniqueContextNodeId(allocator, &focus_node_ids, hit.node_id, args.max_nodes);
                }
            }

            const roots = @max(@as(usize, 1), focus_node_ids.items.len);
            const per_root_nodes = contextSubBudget(args.max_nodes, roots);
            const per_root_edges = contextSubBudget(args.max_edges, roots);
            const per_root_chars = contextSubBudget(args.max_chars, roots);
            var packet_text_budget = ContextPacketTextBudget{ .max_chars = args.max_chars };

            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            try writeJsonObjectStart(&out);
            var first = true;
            try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonStringField(&out, "mode", "context-packet", &first);

            try writeJsonFieldPrefix(&out, "query", &first);
            try out.writeAll("{");
            var query_first = true;
            try writeJsonStringField(&out, "text", args.query, &query_first);
            try writeJsonNullableNodeIdField(&out, "task_id", args.task_id, &query_first);
            try writeJsonNullableNodeIdField(&out, "root_node_id", args.root_node_id, &query_first);
            try writeJsonBoolField(&out, "include_history", args.include_history, &query_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "budget", &first);
            try renderContextBudgetJson(&out, args);

            try writeJsonFieldPrefix(&out, "search", &first);
            try out.writeAll("{");
            var search_first = true;
            try writeJsonFieldPrefix(&out, "plan", &search_first);
            try out.writeAll("{");
            var plan_first = true;
            try writeJsonStringField(&out, "score_model", "bm25", &plan_first);
            try writeJsonStringField(&out, "profile", textBudgetProfileName(args.profile), &plan_first);
            try writeJsonNumberField(&out, "query_terms", plan_stats.query_terms, &plan_first);
            try writeJsonNumberField(&out, "unique_query_terms", plan_stats.unique_query_terms, &plan_first);
            try writeJsonNumberField(&out, "matched_terms", plan_stats.matched_terms, &plan_first);
            try writeJsonNumberField(&out, "postings_planned", plan_stats.postings_count_total, &plan_first);
            try writeJsonNumberField(&out, "max_term_postings", plan_stats.max_postings_count, &plan_first);
            try out.writeAll("}");
            try writeJsonFieldPrefix(&out, "hits", &search_first);
            try out.writeAll("[");
            var used_chars: usize = 0;
            for (selected_hits.items, 0..) |hit, index| {
                if (index != 0) try out.writeAll(",");
                var node = (try node_view.readNodeById(allocator, hit.node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                const size = try computeTextContextSize(node.text);
                used_chars = std.math.add(usize, used_chars, size.text_chars) catch return error.RecordTooLarge;
                try out.writeAll("{");
                var hit_first = true;
                try writeJsonNumberField(&out, "rank", index + 1, &hit_first);
                try writeJsonFieldPrefix(&out, "score", &hit_first);
                try out.print("{d:.6}", .{hit.score});
                try writeJsonFieldPrefix(&out, "node", &hit_first);
                try renderContextNodeObjectJson(&out, allocator, store, node, &packet_text_budget);
                try out.writeAll("}");
            }
            try out.writeAll("]");
            try writeJsonFieldPrefix(&out, "summary", &search_first);
            try out.writeAll("{");
            var search_summary_first = true;
            try writeJsonNumberField(&out, "hit_count", selected_hits.items.len, &search_summary_first);
            const candidate_count = if (maybe_hits) |hits| hits.items.len else @as(usize, 0);
            const search_truncated = search_budget_exceeded or selected_hits.items.len < candidate_count - omitted_history;
            try writeJsonNumberField(&out, "candidate_count", candidate_count, &search_summary_first);
            try writeJsonNumberField(&out, "omitted_history", omitted_history, &search_summary_first);
            try writeJsonBoolField(&out, "budget_exceeded", search_budget_exceeded, &search_summary_first);
            try writeJsonBoolField(&out, "truncated", search_truncated, &search_summary_first);
            try writeJsonNullableStringField(&out, "truncate_reason", if (search_budget_exceeded) "max_postings" else if (search_truncated) "max_search_hits" else null, &search_summary_first);
            try writeJsonNumberField(&out, "used_chars", used_chars, &search_summary_first);
            try out.writeAll("}");
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "focus_nodes", &first);
            try out.writeAll("[");
            for (focus_node_ids.items, 0..) |node_id, index| {
                if (index != 0) try out.writeAll(",");
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                try renderContextNodeObjectJson(&out, allocator, store, node, &packet_text_budget);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "task_packet", &first);
            if (args.task_id) |task_id| {
                try renderContextTaskPacketJson(&out, allocator, store, task_id, args, &packet_text_budget);
            } else {
                try out.writeAll("null");
            }

            try writeJsonFieldPrefix(&out, "neighbor_subgraphs", &first);
            try out.writeAll("[");
            for (focus_node_ids.items, 0..) |node_id, index| {
                if (index != 0) try out.writeAll(",");
                const neighbor_args = ParsedNeighborsArgs{
                    .node_id = "",
                    .include_history = args.include_history,
                    .format = .json,
                    .meta = true,
                    .depth = args.neighbor_depth,
                    .max_nodes = per_root_nodes,
                    .max_edges = per_root_edges,
                    .max_chars = per_root_chars,
                };
                const budget = neighborsJsonBudget(neighbor_args);
                var result = try buildNeighborsSubgraph(allocator, store, edge_retention_registry, node_id, null, neighbor_args, budget);
                defer result.deinit(allocator);
                try renderContextSubgraphJson(&out, allocator, store, node_id, result, &packet_text_budget);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "markdown_previews", &first);
            try out.writeAll("[");
            var preview_first = true;
            var first_markdown_node_id: ?core.NodeId = null;
            for (focus_node_ids.items) |node_id| {
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                if (node.kind != .document and node.kind != .document_section) continue;
                if (first_markdown_node_id == null) first_markdown_node_id = node_id;
                if (!preview_first) try out.writeAll(",");
                preview_first = false;
                try renderContextMarkdownPreviewJson(&out, allocator, store, node, args.markdown_preview_lines, &packet_text_budget);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "packet_summary", &first);
            try renderContextPacketTextBudgetJson(&out, packet_text_budget);

            try writeJsonFieldPrefix(&out, "continuations", &first);
            try out.writeAll("[");
            var continuation_first = true;
            const recommended_postings = @max(args.max_postings_scanned, plan_stats.postings_count_total);
            if (search_budget_exceeded) {
                if (!continuation_first) try out.writeAll(",");
                continuation_first = false;
                var cont_first = try writeContextCommandContinuationPrefix(&out, "context-packet", "search exceeded max_postings; rerun with planned postings budget or refine query");
                try writeJsonFieldPrefix(&out, "command", &cont_first);
                try writeContextPacketCommand(&out, args, args.limit, recommended_postings, args.max_chars);
                try writeJsonNumberField(&out, "postings_planned", plan_stats.postings_count_total, &cont_first);
                try writeJsonNumberField(&out, "current_max_postings", args.max_postings_scanned, &cont_first);
                try out.writeAll("}");
            } else if (search_truncated) {
                if (!continuation_first) try out.writeAll(",");
                continuation_first = false;
                const recommended_limit = @max(args.limit +| 1, candidate_count -| omitted_history);
                var cont_first = try writeContextCommandContinuationPrefix(&out, "context-packet", "search hits were truncated; raise --limit only if current anchors are insufficient");
                try writeJsonFieldPrefix(&out, "command", &cont_first);
                try writeContextPacketCommand(&out, args, recommended_limit, args.max_postings_scanned, args.max_chars);
                try writeJsonNumberField(&out, "current_limit", args.limit, &cont_first);
                try writeJsonNumberField(&out, "suggested_limit", recommended_limit, &cont_first);
                try out.writeAll("}");
            }
            if (packet_text_budget.truncated) {
                if (!continuation_first) try out.writeAll(",");
                continuation_first = false;
                const recommended_max_chars = @max(packet_text_budget.requested_chars, args.max_chars +| 1);
                var cont_first = try writeContextCommandContinuationPrefix(&out, "context-packet", "packet text payload reached max_chars; rerun with suggested_max_chars to fit the same packet shape, or reduce focus nodes");
                try writeJsonFieldPrefix(&out, "command", &cont_first);
                try writeContextPacketCommand(&out, args, args.limit, args.max_postings_scanned, recommended_max_chars);
                try writeJsonNumberField(&out, "current_max_chars", args.max_chars, &cont_first);
                try writeJsonNumberField(&out, "suggested_max_chars", recommended_max_chars, &cont_first);
                try out.writeAll("}");
            }
            if (focus_node_ids.items.len != 0) {
                if (!continuation_first) try out.writeAll(",");
                continuation_first = false;
                var cont_first = try writeContextCommandContinuationPrefix(&out, "neighbors", "expand graph around first focus node if local subgraph was insufficient");
                try writeJsonFieldPrefix(&out, "command", &cont_first);
                try writeNeighborsCommand(&out, args, focus_node_ids.items[0]);
                try out.writeAll("}");
            }
            if (first_markdown_node_id) |node_id| {
                if (!continuation_first) try out.writeAll(",");
                continuation_first = false;
                var cont_first = try writeContextCommandContinuationPrefix(&out, "render-md-doc", "retrieve markdown for the first document focus after preview confirms relevance");
                try writeJsonFieldPrefix(&out, "command", &cont_first);
                try writeRenderMarkdownCommand(&out, args, node_id);
                try out.writeAll("}");
            }
            if (continuation_first) {
                var cont_first = try writeContextCommandContinuationPrefix(&out, "context-plan", "refine the lexical query because no focus node was selected");
                try writeJsonFieldPrefix(&out, "command", &cont_first);
                try writeContextPlanCommand(&out, args, args.limit, args.max_postings_scanned, args.max_chars);
                try out.writeAll("}");
            }
            try out.writeAll("]");

            try writeJsonObjectEnd(&out);
            return out.buffer.toOwnedSlice(allocator);
        }

        fn textBudgetProfileName(profile: TextBudgetProfile) []const u8 {
            return switch (profile) {
                .interactive => "interactive",
                .agent_memory => "agent-memory",
            };
        }

        pub fn writeSearchContinuation(out: *QueryOutputWriter, action: []const u8, node_id: core.NodeId, reason: []const u8) !void {
            try out.writeAll("{");
            var first = true;
            try writeJsonStringField(out, "action", action, &first);
            try writeJsonNumberField(out, "node_id", node_id.toInt(), &first);
            try writeJsonStringField(out, "reason", reason, &first);
            try out.writeAll("}");
        }

        pub fn nodeIsCurrentGeneration(store: storage.Store, node_id: core.NodeId) !bool {
            return (try nodeDeprecatedBy(store, node_id)) == null;
        }

        pub fn currentGenerationLookupCandidateLimit(output_limit: usize) usize {
            if (output_limit == 0) return 0;
            const max_candidate_limit: usize = 4096;
            const expanded = std.math.add(usize, std.math.mul(usize, output_limit, 4) catch max_candidate_limit, 32) catch max_candidate_limit;
            return @min(max_candidate_limit, @max(output_limit, expanded));
        }

        pub fn searchCandidateLimit(profile: TextBudgetProfile, kind_filter: ?core.NodeKind, output_limit: usize, include_history: bool) usize {
            if (output_limit == 0) return 0;
            if (include_history) return output_limit;
            const agent_memory_candidate_limit: usize = 4096;
            if (profile != .agent_memory) {
                const expanded = std.math.add(usize, std.math.mul(usize, output_limit, 4) catch agent_memory_candidate_limit, 32) catch agent_memory_candidate_limit;
                return @min(agent_memory_candidate_limit, @max(output_limit, expanded));
            }
            if (kind_filter != null) {
                const expanded = std.math.add(usize, std.math.mul(usize, output_limit, 4) catch agent_memory_candidate_limit, 32) catch agent_memory_candidate_limit;
                return @min(agent_memory_candidate_limit, @max(output_limit, expanded));
            }
            const expanded = std.math.add(usize, std.math.mul(usize, output_limit, 8) catch agent_memory_candidate_limit, 32) catch agent_memory_candidate_limit;
            return @min(agent_memory_candidate_limit, @max(@as(usize, 256), @max(output_limit, expanded)));
        }

        fn textSearchHitAgentMemoryLessThan(_: void, lhs: text_search.TextSearchHit, rhs: text_search.TextSearchHit) bool {
            const lhs_rank = agentMemorySearchKindRank(lhs.kind);
            const rhs_rank = agentMemorySearchKindRank(rhs.kind);
            if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
            const lhs_finite = std.math.isFinite(lhs.score);
            const rhs_finite = std.math.isFinite(rhs.score);
            if (lhs_finite != rhs_finite) return lhs_finite;
            if (lhs_finite and lhs.score != rhs.score) return lhs.score > rhs.score;
            return lhs.node_id.toInt() < rhs.node_id.toInt();
        }

        fn agentMemorySearchKindRank(kind: core.NodeKind) u8 {
            return switch (kind) {
                .decision,
                .concept,
                .verification,
                .fix,
                .error_event,
                .task,
                .command,
                .user_preference,
                .observation,
                => 0,
                .repo,
                .directory,
                .file,
                .symbol,
                .function,
                .type_decl,
                .relation_kind,
                .relation_policy,
                .edit,
                => 1,
                .evidence,
                .image,
                .media,
                => 2,
                .document,
                .document_section,
                => 3,
                else => 1,
            };
        }

        fn renderNodeMetadataJson(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            registry: ?schema.Registry,
            node: storage.StoredNode,
            include_text: bool,
        ) !void {
            try writeJsonObjectStart(out);
            var first = true;
            try writeJsonStringField(out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonBoolField(out, "found", true, &first);
            try writeJsonFieldPrefix(out, "node", &first);
            try renderNodeObjectJsonWithSchema(out, allocator, store, registry, node, include_text);
            try writeJsonObjectEnd(out);
        }

        pub fn renderNodeObjectJson(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            node: storage.StoredNode,
            include_text: bool,
        ) !void {
            return renderNodeObjectJsonWithSchema(out, allocator, store, null, node, include_text);
        }

        fn renderNodeObjectJsonWithSchema(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            registry: ?schema.Registry,
            node: storage.StoredNode,
            include_text: bool,
        ) !void {
            const kind_label = try nodeKindNameWithSchemaAlloc(allocator, registry, node.kind);
            defer allocator.free(kind_label);
            const text_value = markdownProjectionVisibleText(node.text);
            const context_size = try computeTextContextSize(text_value);
            const deprecated_by = try nodeDeprecatedBy(store, node.id);
            const local_graph = try nodeLocalGraphStats(store, node.id);

            const logical_name = try store.getNodeStringProperty(allocator, node.id, "name");
            defer if (logical_name) |value| allocator.free(value);
            const logical_summary = try store.getNodeStringProperty(allocator, node.id, "summary");
            defer if (logical_summary) |value| allocator.free(value);
            const schema_type = try store.getNodeStringProperty(allocator, node.id, "schema_type");
            defer if (schema_type) |value| allocator.free(value);
            const source_label = try store.getNodeStringProperty(allocator, node.id, "source_label");
            defer if (source_label) |v| allocator.free(v);
            const external_key = try store.getNodeStringProperty(allocator, node.id, "external_key");
            defer if (external_key) |value| allocator.free(value);

            try out.writeAll("{");
            var node_first = true;
            try writeJsonNumberField(out, "id", node.id.toInt(), &node_first);
            try writeJsonStringField(out, "kind", kind_label, &node_first);
            try writeJsonStringField(out, "name", logical_name orelse "", &node_first);

            try writeJsonFieldPrefix(out, "summary", &node_first);
            try out.writeAll("{");
            var summary_first = true;
            try writeJsonNullableStringField(out, "text", logical_summary, &summary_first);
            try writeJsonStringField(out, "source", if (logical_summary != null) "node_property" else "none", &summary_first);
            try writeJsonNullableStringField(out, "node_id", null, &summary_first);
            try writeJsonBoolField(out, "stale", false, &summary_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "schema", &node_first);
            try out.writeAll("{");
            var schema_first = true;
            try writeJsonNullableStringField(out, "schema_type", schema_type, &schema_first);
            try writeJsonNullableStringField(out, "external_key", external_key, &schema_first);
            try writeJsonNullableStringField(out, "source_label", source_label, &schema_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "context_size", &node_first);
            try renderTextContextSizeJson(out, context_size);

            try writeJsonFieldPrefix(out, "status", &node_first);
            try out.writeAll("{");
            var status_first = true;
            try writeJsonBoolField(out, "current_generation", deprecated_by == null, &status_first);
            try writeJsonFieldPrefix(out, "deprecated_by", &status_first);
            if (deprecated_by) |next| {
                try out.print("{}", .{next.toInt()});
            } else {
                try out.writeAll("null");
            }
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "expand", &node_first);
            try out.writeAll("{");
            var expand_first = true;
            try writeJsonBoolField(out, "has_text", node.text.len != 0, &expand_first);
            try writeJsonBoolField(out, "has_summary", logical_summary != null and logical_summary.?.len != 0, &expand_first);
            try writeJsonBoolField(out, "has_children", local_graph.out_degree != 0, &expand_first);
            try writeJsonStringField(out, "recommended", if (local_graph.out_degree != 0) "children_first" else "raw_text", &expand_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(out, "local_graph", &node_first);
            try out.writeAll("{");
            var graph_first = true;
            try writeJsonNumberField(out, "in_degree", local_graph.in_degree, &graph_first);
            try writeJsonNumberField(out, "out_degree", local_graph.out_degree, &graph_first);
            try out.writeAll("}");

            if (include_text) try writeJsonStringField(out, "text", text_value, &node_first);
            try out.writeAll("}");
        }

        pub fn renderNodeByIdOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            args: NodeReadRenderOptions,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var node = (try store.readNodeById(allocator, node_id)) orelse {
                if (args.format == .json) {
                    try writeJsonObjectStart(&out);
                    var first = true;
                    try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
                    try writeJsonNumberField(&out, "id", node_id.toInt(), &first);
                    try writeJsonBoolField(&out, "found", false, &first);
                    try writeJsonObjectEnd(&out);
                    return out.buffer.toOwnedSlice(allocator);
                }
                try out.writeAll("not found\n");
                return out.buffer.toOwnedSlice(allocator);
            };
            defer node.deinit(allocator);

            var embedded_catalog = try store.readCatalog();
            defer if (embedded_catalog) |*cat| cat.deinit();
            const registry: ?schema.Registry = if (embedded_catalog) |cat| cat.registry else null;

            if (args.format == .json) {
                try renderNodeMetadataJson(&out, allocator, store, registry, node, args.include_text);
                return out.buffer.toOwnedSlice(allocator);
            }

            try out.print("{}\t", .{node.id.toInt()});
            try writeNodeKindNameWithSchema(&out, registry, node.kind);
            try out.writeAll("\t");
            try writeEscapedText(&out, node.text);
            try out.writeAll("\n");
            return out.buffer.toOwnedSlice(allocator);
        }

        const NeighborsJsonBudget = struct {
            max_depth: usize,
            max_nodes: usize,
            max_edges: usize,
            max_chars: usize,
            timeout_ms: u64 = (core.QueryBudget{}).timeout_ms,
        };

        const SubgraphEdgeRole = enum { tree, backref };

        const SubgraphEdgeRef = struct {
            edge_id: core.EdgeId,
            src: core.NodeId,
            rel: core.RelKind,
            dst: core.NodeId,
            depth: usize,
            role: SubgraphEdgeRole,
            direction: []const u8 = "outgoing",
            view_role: []const u8 = "",
        };

        const SubgraphOmittedItem = struct {
            reason: []const u8,
            edge_id: ?core.EdgeId = null,
            src: ?core.NodeId = null,
            dst: ?core.NodeId = null,
            depth: usize,
        };

        const SubgraphTraversalItem = struct {
            node_id: core.NodeId,
            depth: usize,
        };

        const SubgraphBuildResult = struct {
            node_ids: std.ArrayList(core.NodeId) = .empty,
            edges: std.ArrayList(SubgraphEdgeRef) = .empty,
            backrefs: std.ArrayList(SubgraphEdgeRef) = .empty,
            omitted: std.ArrayList(SubgraphOmittedItem) = .empty,
            used_bytes: usize = 0,
            used_chars: usize = 0,
            used_lines: usize = 0,
            scanned_edges: usize = 0,
            truncated: bool = false,
            truncate_reason: ?[]const u8 = null,

            pub fn deinit(self: *SubgraphBuildResult, allocator: std.mem.Allocator) void {
                self.node_ids.deinit(allocator);
                self.edges.deinit(allocator);
                self.backrefs.deinit(allocator);
                self.omitted.deinit(allocator);
            }
        };

        pub fn subgraphUsedEdgeRefs(result: SubgraphBuildResult) usize {
            return result.edges.items.len + result.backrefs.items.len;
        }

        fn neighborsJsonBudget(args: ParsedNeighborsArgs) NeighborsJsonBudget {
            const default_max_edges = args.max_edges orelse args.limit orelse (core.QueryBudget{}).max_results;
            const default_max_nodes = args.max_nodes orelse @min(default_max_edges + 1, (core.QueryBudget{}).max_results);
            return .{
                .max_depth = args.depth,
                .max_nodes = default_max_nodes,
                .max_edges = default_max_edges,
                .max_chars = args.max_chars orelse 200_000,
            };
        }

        fn markSubgraphTruncated(result: *SubgraphBuildResult, reason: []const u8) void {
            result.truncated = true;
            if (result.truncate_reason == null) result.truncate_reason = reason;
        }

        fn appendSubgraphOmitted(
            allocator: std.mem.Allocator,
            result: *SubgraphBuildResult,
            reason: []const u8,
            edge_id: ?core.EdgeId,
            src: ?core.NodeId,
            dst: ?core.NodeId,
            depth: usize,
        ) !void {
            try result.omitted.append(allocator, .{
                .reason = reason,
                .edge_id = edge_id,
                .src = src,
                .dst = dst,
                .depth = depth,
            });
            markSubgraphTruncated(result, reason);
        }

        fn tryAddSubgraphNode(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            result: *SubgraphBuildResult,
            visited_nodes: *std.AutoHashMap(u64, void),
            queue: ?*std.ArrayList(SubgraphTraversalItem),
            node_id: core.NodeId,
            depth: usize,
            budget: NeighborsJsonBudget,
            include_history: bool,
        ) !bool {
            if (visited_nodes.contains(node_id.toInt())) return true;
            if (!include_history and !try nodeIsCurrentGeneration(store, node_id)) {
                try appendSubgraphOmitted(allocator, result, "history", null, null, node_id, depth);
                return false;
            }
            if (result.node_ids.items.len >= budget.max_nodes) {
                try appendSubgraphOmitted(allocator, result, "max_nodes", null, null, node_id, depth);
                return false;
            }

            var node = (try node_view.readNodeById(allocator, node_id)) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            const size = try computeTextContextSize(node.text);
            if (result.used_chars > budget.max_chars or size.text_chars > budget.max_chars - result.used_chars) {
                try appendSubgraphOmitted(allocator, result, "max_chars", null, null, node_id, depth);
                return false;
            }

            try visited_nodes.put(node_id.toInt(), {});
            try result.node_ids.append(allocator, node_id);
            result.used_bytes = std.math.add(usize, result.used_bytes, size.text_bytes) catch return error.RecordTooLarge;
            result.used_chars = std.math.add(usize, result.used_chars, size.text_chars) catch return error.RecordTooLarge;
            result.used_lines = std.math.add(usize, result.used_lines, size.text_lines) catch return error.RecordTooLarge;
            if (queue) |pending| {
                if (depth < budget.max_depth) try pending.append(allocator, .{ .node_id = node_id, .depth = depth });
            }
            return true;
        }

        fn buildNeighborsSubgraph(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
            root_id: core.NodeId,
            rel_filter: ?core.RelKind,
            args: ParsedNeighborsArgs,
            budget: NeighborsJsonBudget,
        ) !SubgraphBuildResult {
            var result = SubgraphBuildResult{};
            errdefer result.deinit(allocator);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var visited_nodes = std.AutoHashMap(u64, void).init(allocator);
            defer visited_nodes.deinit();
            var visited_edges = std.AutoHashMap(u64, void).init(allocator);
            defer visited_edges.deinit();
            var queue = std.ArrayList(SubgraphTraversalItem).empty;
            defer queue.deinit(allocator);

            _ = try tryAddSubgraphNode(allocator, store, &node_view, &result, &visited_nodes, &queue, root_id, 0, budget, args.include_history);

            var cursor: usize = 0;
            while (cursor < queue.items.len) : (cursor += 1) {
                const current = queue.items[cursor];
                if (current.depth >= budget.max_depth) continue;
                if (subgraphUsedEdgeRefs(result) >= budget.max_edges) {
                    markSubgraphTruncated(&result, "max_edges");
                    break;
                }

                const remaining_edges = budget.max_edges - subgraphUsedEdgeRefs(result);
                var neighbor_result = try query.neighborsWithPersistentStoreRetained(allocator, store, edge_retention_registry, current.node_id, rel_filter, .{
                    .max_results = remaining_edges + 1,
                    .max_visited_edges = remaining_edges + 1,
                    .timeout_ms = budget.timeout_ms,
                });
                defer neighbor_result.deinit(allocator);
                result.scanned_edges = std.math.add(usize, result.scanned_edges, neighbor_result.stats.edges_visited) catch return error.RecordTooLarge;
                if (neighbor_result.stats.budget_exceeded) markSubgraphTruncated(&result, "max_edges");

                for (neighbor_result.neighbors.items) |neighbor| {
                    if (visited_edges.contains(neighbor.edge_id.toInt())) continue;
                    if (subgraphUsedEdgeRefs(result) >= budget.max_edges) {
                        try appendSubgraphOmitted(allocator, &result, "max_edges", neighbor.edge_id, current.node_id, neighbor.node_id, current.depth + 1);
                        break;
                    }
                    try visited_edges.put(neighbor.edge_id.toInt(), {});

                    if (visited_nodes.contains(neighbor.node_id.toInt())) {
                        try result.backrefs.append(allocator, .{
                            .edge_id = neighbor.edge_id,
                            .src = current.node_id,
                            .rel = neighbor.rel,
                            .dst = neighbor.node_id,
                            .depth = current.depth + 1,
                            .role = .backref,
                        });
                        continue;
                    }

                    const added = try tryAddSubgraphNode(allocator, store, &node_view, &result, &visited_nodes, &queue, neighbor.node_id, current.depth + 1, budget, args.include_history);
                    if (!added) continue;
                    try result.edges.append(allocator, .{
                        .edge_id = neighbor.edge_id,
                        .src = current.node_id,
                        .rel = neighbor.rel,
                        .dst = neighbor.node_id,
                        .depth = current.depth + 1,
                        .role = .tree,
                    });
                }
            }

            return result;
        }

        pub fn renderTextContextSizeAggregateJson(writer: *QueryOutputWriter, text_bytes: usize, text_chars: usize, text_lines: usize) !void {
            try writer.writeAll("{");
            var first = true;
            try writeJsonNumberField(writer, "text_bytes", text_bytes, &first);
            try writeJsonNumberField(writer, "text_chars", text_chars, &first);
            try writeJsonNumberField(writer, "text_lines", text_lines, &first);
            try writeJsonNumberField(writer, "size_version", 1, &first);
            try writer.writeAll("}");
        }

        fn writeNullableRelKindJson(out: *QueryOutputWriter, allocator: std.mem.Allocator, registry: ?schema.Registry, rel_filter: ?core.RelKind) !void {
            if (rel_filter) |rel| {
                const rel_label = try relKindNameWithSchemaAlloc(allocator, registry, rel);
                defer allocator.free(rel_label);
                try writeJsonString(out, rel_label);
            } else {
                try out.writeAll("null");
            }
        }

        pub fn renderSubgraphEdgeJson(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge: SubgraphEdgeRef,
        ) !void {
            return renderSubgraphEdgeJsonWithSchema(out, allocator, store, null, edge);
        }

        fn renderSubgraphEdgeJsonWithSchema(
            out: *QueryOutputWriter,
            allocator: std.mem.Allocator,
            store: storage.Store,
            registry: ?schema.Registry,
            edge: SubgraphEdgeRef,
        ) !void {
            const rel_label = try relKindNameWithSchemaAlloc(allocator, registry, edge.rel);
            defer allocator.free(rel_label);
            try out.writeAll("{");
            var first = true;
            try writeJsonNumberField(out, "id", edge.edge_id.toInt(), &first);
            try writeJsonNumberField(out, "src", edge.src.toInt(), &first);
            try writeJsonStringField(out, "rel", rel_label, &first);
            try writeJsonNumberField(out, "dst", edge.dst.toInt(), &first);
            try writeJsonFieldPrefix(out, "props", &first);
            // 边字符串属性:分类性引用边(acts_on/uses/produces/about)带 state=tentative|confirmed
            // (改动三两态位)。旧版硬编码 "{}" 让 state 写而不可读——补上使其可测/可用于展示。
            // **只对 ref 类关系查属性**:结构边(contains/depends_on/…)从不带 state,跳过 property
            // 索引查找,免掉每条边一次读盘的读热路径回归(subgraph 可达 200 边)。
            const is_ref_edge = switch (edge.rel) {
                .acts_on, .uses, .produces, .about => true,
                else => false,
            };
            const state_prop = if (is_ref_edge) (store.getEdgeStringProperty(allocator, edge.edge_id, "state") catch null) else null;
            defer if (state_prop) |sp| allocator.free(sp);
            if (state_prop) |sp| {
                try out.writeAll("{");
                var props_first = true;
                try writeJsonStringField(out, "state", sp, &props_first);
                try out.writeAll("}");
            } else {
                try out.writeAll("{}");
            }
            try writeJsonFieldPrefix(out, "summary", &first);
            try out.writeAll("{");
            var summary_first = true;
            try writeJsonNullableStringField(out, "text", null, &summary_first);
            try writeJsonStringField(out, "source", "none", &summary_first);
            try out.writeAll("}");
            try writeJsonStringField(out, "direction", edge.direction, &first);
            if (edge.view_role.len != 0) try writeJsonStringField(out, "view_role", edge.view_role, &first);
            try writeJsonStringField(out, "role", switch (edge.role) {
                .tree => "tree",
                .backref => "backref",
            }, &first);
            try writeJsonBoolField(out, "traversed", edge.role == .tree, &first);
            try writeJsonNumberField(out, "depth", edge.depth, &first);
            try out.writeAll("}");
        }

        pub fn renderSubgraphOmittedJson(out: *QueryOutputWriter, item: SubgraphOmittedItem) !void {
            try out.writeAll("{");
            var first = true;
            try writeJsonStringField(out, "reason", item.reason, &first);
            try writeJsonNumberField(out, "depth", item.depth, &first);
            try writeJsonFieldPrefix(out, "edge_id", &first);
            if (item.edge_id) |edge_id| try out.print("{}", .{edge_id.toInt()}) else try out.writeAll("null");
            try writeJsonFieldPrefix(out, "src", &first);
            if (item.src) |src| try out.print("{}", .{src.toInt()}) else try out.writeAll("null");
            try writeJsonFieldPrefix(out, "dst", &first);
            if (item.dst) |dst| try out.print("{}", .{dst.toInt()}) else try out.writeAll("null");
            try out.writeAll("}");
        }

        pub fn renderNeighborsJsonOutputRetained(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
            registry: ?schema.Registry,
            root_id: core.NodeId,
            rel_filter: ?core.RelKind,
            args: ParsedNeighborsArgs,
        ) ![]u8 {
            const budget = neighborsJsonBudget(args);
            var result = try buildNeighborsSubgraph(allocator, store, edge_retention_registry, root_id, rel_filter, args, budget);
            defer result.deinit(allocator);

            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();

            try writeJsonObjectStart(&out);
            var first = true;
            try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonStringField(&out, "mode", "neighbors", &first);
            try writeJsonFieldPrefix(&out, "query", &first);
            try out.writeAll("{");
            var query_first = true;
            try writeJsonNumberField(&out, "root_id", root_id.toInt(), &query_first);
            try writeJsonFieldPrefix(&out, "rel_filter", &query_first);
            try writeNullableRelKindJson(&out, allocator, registry, rel_filter);
            try writeJsonNumberField(&out, "depth", args.depth, &query_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "budget", &first);
            try out.writeAll("{");
            var budget_first = true;
            try writeJsonNumberField(&out, "max_nodes", budget.max_nodes, &budget_first);
            try writeJsonNumberField(&out, "max_edges", budget.max_edges, &budget_first);
            try writeJsonNumberField(&out, "max_chars", budget.max_chars, &budget_first);
            try writeJsonNumberField(&out, "max_depth", budget.max_depth, &budget_first);
            try writeJsonNumberField(&out, "timeout_ms", budget.timeout_ms, &budget_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "summary", &first);
            try out.writeAll("{");
            var summary_first = true;
            try writeJsonNumberField(&out, "node_count", result.node_ids.items.len, &summary_first);
            try writeJsonNumberField(&out, "edge_count", result.edges.items.len, &summary_first);
            try writeJsonNumberField(&out, "backref_count", result.backrefs.items.len, &summary_first);
            try writeJsonBoolField(&out, "truncated", result.truncated, &summary_first);
            try writeJsonNullableStringField(&out, "truncate_reason", result.truncate_reason, &summary_first);
            try writeJsonNumberField(&out, "used_nodes", result.node_ids.items.len, &summary_first);
            try writeJsonNumberField(&out, "used_edges", subgraphUsedEdgeRefs(result), &summary_first);
            try writeJsonNumberField(&out, "used_chars", result.used_chars, &summary_first);
            try writeJsonNumberField(&out, "postings_scanned", 0, &summary_first);
            try writeJsonNumberField(&out, "edges_scanned", result.scanned_edges, &summary_first);
            try writeJsonFieldPrefix(&out, "context_size", &summary_first);
            try renderTextContextSizeAggregateJson(&out, result.used_bytes, result.used_chars, result.used_lines);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "root", &first);
            if (result.node_ids.items.len == 0) {
                try out.writeAll("null");
            } else {
                var root_node = (try node_view.readNodeById(allocator, root_id)) orelse return error.InvalidRecord;
                defer root_node.deinit(allocator);
                try renderNodeObjectJsonWithSchema(&out, allocator, store, registry, root_node, false);
            }

            try writeJsonFieldPrefix(&out, "nodes", &first);
            try out.writeAll("[");
            for (result.node_ids.items, 0..) |node_id, index| {
                if (index != 0) try out.writeAll(",");
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                try renderNodeObjectJsonWithSchema(&out, allocator, store, registry, node, false);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "edges", &first);
            try out.writeAll("[");
            for (result.edges.items, 0..) |edge, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphEdgeJsonWithSchema(&out, allocator, store, registry, edge);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "backrefs", &first);
            try out.writeAll("[");
            for (result.backrefs.items, 0..) |edge, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphEdgeJsonWithSchema(&out, allocator, store, registry, edge);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "omitted", &first);
            try out.writeAll("[");
            for (result.omitted.items, 0..) |item, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphOmittedJson(&out, item);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "continuations", &first);
            try out.writeAll("[");
            var continuation_first = true;
            if (result.truncated) {
                try out.writeAll("{");
                var cont_first = true;
                try writeJsonStringField(&out, "action", "neighbors", &cont_first);
                try writeJsonNumberField(&out, "node_id", root_id.toInt(), &cont_first);
                try writeJsonStringField(&out, "args", "raise --max-nodes/--max-edges/--max-chars or lower --depth", &cont_first);
                try writeJsonStringField(&out, "reason", "subgraph traversal was truncated", &cont_first);
                try out.writeAll("}");
                continuation_first = false;
            }
            if (!continuation_first) try out.writeAll(",");
            try writeSearchContinuation(&out, "inspect_metadata", root_id, "inspect root node metadata before expanding raw text");
            try out.writeAll("]");

            try writeJsonObjectEnd(&out);
            return out.buffer.toOwnedSlice(allocator);
        }

        pub fn renderNodeVersionsOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            limit: usize,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var base_node = (try store.readNodeById(allocator, node_id)) orelse return core.Error.NotFound;
            defer base_node.deinit(allocator);
            try out.print("node_versions\t{}\tlimit={}\n", .{ node_id.toInt(), limit });
            try writeTaskPacketNodeRow(&out, "base", base_node.id, base_node.kind, base_node.text);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var queue = std.ArrayList(core.NodeId).empty;
            defer queue.deinit(allocator);
            try queue.append(allocator, node_id);

            var cursor: usize = 0;
            var rows: usize = 0;
            var truncated = false;
            while (cursor < queue.items.len) : (cursor += 1) {
                const current = queue.items[cursor];
                const remaining = limit - rows;
                var records = try readVisibleEdgeRecordsByNodeLimited(allocator, store, .src, current, .deprecated_by, remaining +| 1);
                defer records.deinit(allocator);
                for (records.items) |record| {
                    if (rows >= limit) {
                        truncated = true;
                        break;
                    }
                    const next_id = core.NodeId.fromInt(record.dst);
                    var node = (try node_view.readNodeById(allocator, next_id)) orelse return error.InvalidRecord;
                    defer node.deinit(allocator);
                    try out.print("version\t{}\tdeprecated_by\t{}\t{}\t", .{ record.edge_id, current.toInt(), next_id.toInt() });
                    try writeNodeKindName(&out, node.kind);
                    try out.writeAll("\t");
                    try writeEscapedText(&out, node.text);
                    try out.writeAll("\n");
                    try queue.append(allocator, next_id);
                    rows += 1;
                }
                if (truncated) break;
            }
            if (truncated) try out.print("version_truncated\tlimit={}\n", .{limit});

            return out.buffer.toOwnedSlice(allocator);
        }

        const NodeLatestVisit = struct {
            node_id: core.NodeId,
            parent_id: ?core.NodeId = null,
            edge_id: ?u64 = null,
            has_child: bool = false,
        };

        pub fn renderNodeLatestOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            limit: usize,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var base_node = (try store.readNodeById(allocator, node_id)) orelse return core.Error.NotFound;
            defer base_node.deinit(allocator);

            var visits = std.ArrayList(NodeLatestVisit).empty;
            defer visits.deinit(allocator);
            try visits.append(allocator, .{ .node_id = node_id });

            var cursor: usize = 0;
            var version_edges: usize = 0;
            var truncated = false;
            while (cursor < visits.items.len) : (cursor += 1) {
                const current_id = visits.items[cursor].node_id;
                const remaining = limit - version_edges;
                var records = try readVisibleEdgeRecordsByNodeLimited(allocator, store, .src, current_id, .deprecated_by, remaining +| 1);
                defer records.deinit(allocator);
                for (records.items) |record| {
                    if (version_edges >= limit) {
                        truncated = true;
                        break;
                    }
                    visits.items[cursor].has_child = true;
                    try visits.append(allocator, .{
                        .node_id = core.NodeId.fromInt(record.dst),
                        .parent_id = current_id,
                        .edge_id = record.edge_id,
                    });
                    version_edges += 1;
                }
                if (truncated) break;
            }

            var latest_count: usize = 0;
            if (!truncated) {
                for (visits.items) |visit| {
                    if (!visit.has_child) latest_count += 1;
                }
            }
            try out.print(
                "node_latest\t{}\tlimit={}\tscanned_versions={}\ttruncated={}\tlatest_count={}\n",
                .{ node_id.toInt(), limit, version_edges, @intFromBool(truncated), latest_count },
            );
            try writeTaskPacketNodeRow(&out, "base", base_node.id, base_node.kind, base_node.text);
            if (truncated) {
                try out.print("latest_truncated\tlimit={}\tscanned_versions={}\n", .{ limit, version_edges });
                return out.buffer.toOwnedSlice(allocator);
            }

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            for (visits.items) |visit| {
                if (visit.has_child) continue;
                var node = (try node_view.readNodeById(allocator, visit.node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                if (visit.parent_id) |parent_id| {
                    try out.print("latest\t{}\tdeprecated_by\t{}\t{}\t", .{ visit.edge_id.?, parent_id.toInt(), visit.node_id.toInt() });
                } else {
                    try out.print("latest\troot\t{}\t", .{visit.node_id.toInt()});
                }
                try writeNodeKindName(&out, node.kind);
                try out.writeAll("\t");
                try writeEscapedText(&out, node.text);
                try out.writeAll("\n");
            }

            return out.buffer.toOwnedSlice(allocator);
        }

        fn renderNeighborsOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
        ) ![]u8 {
            return renderNeighborsOutputMaybeRetained(allocator, store, null, null, node_id, rel_filter, budget, false, 0, false);
        }

        fn renderNeighborsOutputRetained(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
            include_history: bool,
        ) ![]u8 {
            return renderNeighborsOutputMaybeRetained(allocator, store, edge_retention_registry, null, node_id, rel_filter, budget, false, 0, include_history);
        }

        fn renderNeighborsOutputBounded(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            limit: usize,
            offset: usize,
        ) ![]u8 {
            return renderNeighborsOutputMaybeRetained(allocator, store, null, null, node_id, rel_filter, .{
                .max_results = limit + offset,
                .max_visited_edges = limit + offset,
            }, true, offset, false);
        }

        fn renderNeighborsOutputBoundedRetained(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            limit: usize,
            offset: usize,
            include_history: bool,
        ) ![]u8 {
            return renderNeighborsOutputMaybeRetained(allocator, store, edge_retention_registry, null, node_id, rel_filter, .{
                .max_results = limit + offset,
                .max_visited_edges = limit + offset,
            }, true, offset, include_history);
        }

        pub fn renderNeighborsOutputMaybeRetained(
            allocator: std.mem.Allocator,
            store: storage.Store,
            edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
            registry: ?schema.Registry,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
            allow_partial_results: bool,
            offset: usize,
            include_history: bool,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            if (!include_history and !try nodeIsCurrentGeneration(store, node_id)) return out.buffer.toOwnedSlice(allocator);

            var result = if (edge_retention_registry) |edge_registry|
                try query.neighborsWithPersistentStoreRetained(allocator, store, edge_registry, node_id, rel_filter, budget)
            else
                try query.neighborsWithPersistentStore(allocator, store, node_id, rel_filter, budget);
            defer result.deinit(allocator);
            if (!allow_partial_results and result.stats.budget_exceeded) return core.Error.BudgetExceeded;

            if (result.neighbors.items.len <= offset) return out.buffer.toOwnedSlice(allocator);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            for (result.neighbors.items[offset..]) |neighbor| {
                if (!include_history and !try nodeIsCurrentGeneration(store, neighbor.node_id)) continue;
                var node = (try node_view.readNodeById(allocator, neighbor.node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                try out.print("{}\t", .{neighbor.edge_id.toInt()});
                try writeRelKindNameWithSchema(&out, registry, neighbor.rel);
                try out.print("\t{}\t", .{node.id.toInt()});
                try writeEscapedText(&out, node.text);
                try out.writeAll("\n");
            }

            return out.buffer.toOwnedSlice(allocator);
        }

        pub fn renderIncomingOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            registry: ?schema.Registry,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
            include_history: bool,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var node_id_view = try store.openNodeByIdIndexView();
            defer node_id_view.deinit();
            if (!try node_id_view.nodeExists(node_id)) return core.Error.NotFound;
            if (!include_history and !try nodeIsCurrentGeneration(store, node_id)) return out.buffer.toOwnedSlice(allocator);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            const IncomingContext = struct {
                allocator: std.mem.Allocator,
                store: storage.Store,
                registry: ?schema.Registry,
                node_view: *storage.Store.NodeRecordView,
                out: *QueryOutputWriter,
                budget: core.QueryBudget,
                include_history: bool,
                rows: usize = 0,
                visited: usize = 0,

                fn visit(self: *@This(), record: storage.EdgeIndexRecord) !bool {
                    if (self.visited >= self.budget.max_visited_edges) return core.Error.BudgetExceeded;
                    self.visited += 1;
                    if (self.rows >= self.budget.max_results) return core.Error.BudgetExceeded;
                    const src_id = core.NodeId.fromInt(record.src);
                    if (!self.include_history and !try nodeIsCurrentGeneration(self.store, src_id)) return false;
                    var node = (try self.node_view.readNodeById(self.allocator, src_id)) orelse return error.InvalidRecord;
                    defer node.deinit(self.allocator);
                    try self.out.print("{}\t", .{record.edge_id});
                    try writeRelKindNameWithSchema(self.out, self.registry, @enumFromInt(record.rel));
                    try self.out.print("\t{}\t", .{node.id.toInt()});
                    try writeEscapedText(self.out, node.text);
                    try self.out.writeAll("\n");
                    self.rows += 1;
                    return false;
                }
            };
            var context = IncomingContext{
                .allocator = allocator,
                .store = store,
                .registry = registry,
                .node_view = &node_view,
                .out = &out,
                .budget = budget,
                .include_history = include_history,
            };
            _ = try forEachVisibleEdgeRecordByNode(allocator, store, .dst, node_id, rel_filter, &context, IncomingContext.visit);

            return out.buffer.toOwnedSlice(allocator);
        }

        pub fn renderTaskPacketOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            task_id: core.NodeId,
            limit: usize,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var task_node = (try store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
            defer task_node.deinit(allocator);
            if (task_node.kind != .task) return core.Error.InvalidId;

            const now_ns = try u128ToU64(persistentNowNs(store.io));
            const lifecycle = try task.statusForStoredNode(allocator, store, task_node, now_ns);
            const state: ?task.ReadyState = if (lifecycle.isTerminal()) null else try task.readyStateWithPersistentStoreAt(allocator, store, task_id, now_ns);
            try out.print("task_packet\t{}\tstatus={s}\treadiness=", .{ task_id.toInt(), @tagName(lifecycle) });
            if (state) |value| {
                try out.writeAll(@tagName(value));
            } else {
                try out.writeAll("-");
            }
            try out.print("\tlimit={}\n", .{limit});
            try writeTaskPacketNodeRow(&out, "task", task_node.id, task_node.kind, task_node.text);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            try writeTaskPacketHierarchyEdgeRows(allocator, store, &node_view, &out, "parent_in", .dst, task_id, limit);
            try writeTaskPacketEdgeRows(allocator, store, &node_view, &out, "goal_anchor_in", .dst, task_id, .related_to, limit);
            try writeTaskPacketEdgeRows(allocator, store, &node_view, &out, "goal_anchor_out", .src, task_id, .related_to, limit);
            try writeTaskPacketEdgeRows(allocator, store, &node_view, &out, "depends_on_out", .src, task_id, .depends_on, limit);
            try writeTaskPacketEdgeRows(allocator, store, &node_view, &out, "blocks_in", .dst, task_id, .blocks, limit);
            try writeTaskPacketRecentHistoryEdgeRows(allocator, store, &node_view, &out, "child_out", .src, task_id, limit);
            try writeTaskPacketRecentEdgeRows(allocator, store, &node_view, &out, "verified_by_out", .src, task_id, .verified_by, limit);

            return out.buffer.toOwnedSlice(allocator);
        }

        pub fn taskPacketJsonBudget(args: ParsedTaskPacketArgs) NeighborsJsonBudget {
            const default_max_edges = args.max_edges orelse @min((core.QueryBudget{}).max_visited_edges, args.limit * 7);
            const default_max_nodes = args.max_nodes orelse @min((core.QueryBudget{}).max_results, default_max_edges + 1);
            return .{
                .max_depth = 1,
                .max_nodes = default_max_nodes,
                .max_edges = default_max_edges,
                .max_chars = args.max_chars orelse 200_000,
            };
        }

        fn taskPacketEdgeDirection(order: storage.EdgeIndexOrder) []const u8 {
            return switch (order) {
                .src => "outgoing",
                .dst => "incoming",
                .id => "unknown",
            };
        }

        fn addTaskPacketEdgeToSubgraph(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            result: *SubgraphBuildResult,
            visited_nodes: *std.AutoHashMap(u64, void),
            visited_edges: *std.AutoHashMap(u64, void),
            record: storage.EdgeIndexRecord,
            order: storage.EdgeIndexOrder,
            view_role: []const u8,
            budget: NeighborsJsonBudget,
        ) !bool {
            result.scanned_edges = std.math.add(usize, result.scanned_edges, 1) catch return error.RecordTooLarge;
            const edge_id = core.EdgeId.fromInt(record.edge_id);
            if (visited_edges.contains(edge_id.toInt())) return false;

            const node_id = switch (order) {
                .src => core.NodeId.fromInt(record.dst),
                .dst => core.NodeId.fromInt(record.src),
                .id => return core.Error.Unsupported,
            };
            var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
            defer node.deinit(allocator);
            if (taskPacketRoleIsGoalAnchor(view_role) and try nodeHasTaskEventSchema(allocator, store, node.id)) return false;

            if (subgraphUsedEdgeRefs(result.*) >= budget.max_edges) {
                try appendSubgraphOmitted(allocator, result, "max_edges", edge_id, core.NodeId.fromInt(record.src), core.NodeId.fromInt(record.dst), 1);
                return false;
            }
            try visited_edges.put(edge_id.toInt(), {});

            const role: SubgraphEdgeRole = if (visited_nodes.contains(node_id.toInt())) .backref else .tree;
            if (role == .tree) {
                const added = try tryAddSubgraphNode(allocator, store, node_view, result, visited_nodes, null, node_id, 1, budget, true);
                if (!added) return false;
            }
            const edge = SubgraphEdgeRef{
                .edge_id = edge_id,
                .src = core.NodeId.fromInt(record.src),
                .rel = @enumFromInt(record.rel),
                .dst = core.NodeId.fromInt(record.dst),
                .depth = 1,
                .role = role,
                .direction = taskPacketEdgeDirection(order),
                .view_role = view_role,
            };
            if (role == .backref) {
                try result.backrefs.append(allocator, edge);
            } else {
                try result.edges.append(allocator, edge);
            }
            return true;
        }

        fn collectTaskPacketEdgeRowsJson(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            result: *SubgraphBuildResult,
            visited_nodes: *std.AutoHashMap(u64, void),
            visited_edges: *std.AutoHashMap(u64, void),
            view_role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            rel_filter: core.RelKind,
            limit: usize,
            budget: NeighborsJsonBudget,
        ) !void {
            var rows: usize = 0;
            var records = try readVisibleEdgeRecordsByNode(allocator, store, order, owner_id, rel_filter);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (rows >= limit) {
                    try appendSubgraphOmitted(allocator, result, "max_role_rows", core.EdgeId.fromInt(record.edge_id), core.NodeId.fromInt(record.src), core.NodeId.fromInt(record.dst), 1);
                    break;
                }
                if (try addTaskPacketEdgeToSubgraph(allocator, store, node_view, result, visited_nodes, visited_edges, record, order, view_role, budget)) rows += 1;
            }
        }

        fn collectTaskPacketRecentEdgeRowsJson(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            result: *SubgraphBuildResult,
            visited_nodes: *std.AutoHashMap(u64, void),
            visited_edges: *std.AutoHashMap(u64, void),
            view_role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            rel_filter: core.RelKind,
            limit: usize,
            budget: NeighborsJsonBudget,
        ) !void {
            if (limit == 0) return error.InvalidLimit;

            const recent = try allocator.alloc(storage.EdgeIndexRecord, limit);
            defer allocator.free(recent);

            var scanned: usize = 0;
            var first_omitted: ?storage.EdgeIndexRecord = null;
            var records = try readVisibleEdgeRecordsByNode(allocator, store, order, owner_id, rel_filter);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (scanned >= limit and first_omitted == null) first_omitted = recent[scanned % limit];
                recent[scanned % limit] = record;
                scanned += 1;
            }
            if (first_omitted) |omitted| {
                try appendSubgraphOmitted(allocator, result, "max_role_rows", core.EdgeId.fromInt(omitted.edge_id), core.NodeId.fromInt(omitted.src), core.NodeId.fromInt(omitted.dst), 1);
            }

            const emitted = @min(scanned, limit);
            var offset: usize = 0;
            while (offset < emitted) : (offset += 1) {
                const index = (scanned - 1 - offset) % limit;
                _ = try addTaskPacketEdgeToSubgraph(allocator, store, node_view, result, visited_nodes, visited_edges, recent[index], order, view_role, budget);
            }
        }

        pub fn edgeRecordIdLessThan(_: void, lhs: storage.EdgeIndexRecord, rhs: storage.EdgeIndexRecord) bool {
            return lhs.edge_id < rhs.edge_id;
        }

        fn collectTaskPacketHierarchyEdgeRowsJson(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            result: *SubgraphBuildResult,
            visited_nodes: *std.AutoHashMap(u64, void),
            visited_edges: *std.AutoHashMap(u64, void),
            view_role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            limit: usize,
            budget: NeighborsJsonBudget,
        ) !void {
            if (limit == 0) return error.InvalidLimit;
            var records = try readVisibleTaskHierarchyEdgeRecords(allocator, store, order, owner_id);
            defer records.deinit(allocator);
            std.mem.sort(storage.EdgeIndexRecord, records.items, {}, edgeRecordIdLessThan);

            const emitted = @min(records.items.len, limit);
            var offset: usize = 0;
            while (offset < emitted) : (offset += 1) {
                _ = try addTaskPacketEdgeToSubgraph(
                    allocator,
                    store,
                    node_view,
                    result,
                    visited_nodes,
                    visited_edges,
                    records.items[offset],
                    order,
                    view_role,
                    budget,
                );
            }
            if (records.items.len > limit) {
                const omitted = records.items[emitted];
                try appendSubgraphOmitted(
                    allocator,
                    result,
                    "max_role_rows",
                    core.EdgeId.fromInt(omitted.edge_id),
                    core.NodeId.fromInt(omitted.src),
                    core.NodeId.fromInt(omitted.dst),
                    1,
                );
            }
        }

        fn collectTaskPacketRecentHistoryEdgeRowsJson(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            result: *SubgraphBuildResult,
            visited_nodes: *std.AutoHashMap(u64, void),
            visited_edges: *std.AutoHashMap(u64, void),
            view_role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            limit: usize,
            budget: NeighborsJsonBudget,
        ) !void {
            if (limit == 0) return error.InvalidLimit;
            var records = try readVisibleTaskPacketChildEdgeRecords(allocator, store, order, owner_id);
            defer records.deinit(allocator);
            std.mem.sort(storage.EdgeIndexRecord, records.items, {}, edgeRecordIdLessThan);

            const emitted = @min(records.items.len, limit);
            var offset: usize = 0;
            while (offset < emitted) : (offset += 1) {
                const index = records.items.len - 1 - offset;
                _ = try addTaskPacketEdgeToSubgraph(
                    allocator,
                    store,
                    node_view,
                    result,
                    visited_nodes,
                    visited_edges,
                    records.items[index],
                    order,
                    view_role,
                    budget,
                );
            }
            if (records.items.len > limit) {
                const omitted = records.items[records.items.len - 1 - emitted];
                try appendSubgraphOmitted(
                    allocator,
                    result,
                    "max_role_rows",
                    core.EdgeId.fromInt(omitted.edge_id),
                    core.NodeId.fromInt(omitted.src),
                    core.NodeId.fromInt(omitted.dst),
                    1,
                );
            }
        }

        pub fn buildTaskPacketSubgraph(
            allocator: std.mem.Allocator,
            store: storage.Store,
            task_id: core.NodeId,
            args: ParsedTaskPacketArgs,
            budget: NeighborsJsonBudget,
        ) !SubgraphBuildResult {
            var result = SubgraphBuildResult{};
            errdefer result.deinit(allocator);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var visited_nodes = std.AutoHashMap(u64, void).init(allocator);
            defer visited_nodes.deinit();
            var visited_edges = std.AutoHashMap(u64, void).init(allocator);
            defer visited_edges.deinit();

            _ = try tryAddSubgraphNode(allocator, store, &node_view, &result, &visited_nodes, null, task_id, 0, budget, true);
            try collectTaskPacketHierarchyEdgeRowsJson(allocator, store, &node_view, &result, &visited_nodes, &visited_edges, "parent_in", .dst, task_id, args.limit, budget);
            try collectTaskPacketEdgeRowsJson(allocator, store, &node_view, &result, &visited_nodes, &visited_edges, "goal_anchor_in", .dst, task_id, .related_to, args.limit, budget);
            try collectTaskPacketEdgeRowsJson(allocator, store, &node_view, &result, &visited_nodes, &visited_edges, "goal_anchor_out", .src, task_id, .related_to, args.limit, budget);
            try collectTaskPacketEdgeRowsJson(allocator, store, &node_view, &result, &visited_nodes, &visited_edges, "depends_on_out", .src, task_id, .depends_on, args.limit, budget);
            try collectTaskPacketEdgeRowsJson(allocator, store, &node_view, &result, &visited_nodes, &visited_edges, "blocks_in", .dst, task_id, .blocks, args.limit, budget);
            try collectTaskPacketRecentHistoryEdgeRowsJson(allocator, store, &node_view, &result, &visited_nodes, &visited_edges, "child_out", .src, task_id, args.limit, budget);
            try collectTaskPacketRecentEdgeRowsJson(allocator, store, &node_view, &result, &visited_nodes, &visited_edges, "verified_by_out", .src, task_id, .verified_by, args.limit, budget);
            return result;
        }

        test "free-text commands do not treat first query token as db path" {
            var parsed_search = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "invalid", "record" });
            defer parsed_search.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(".tinykg", parsed_search.db_path);
            try std.testing.expectEqualStrings("invalid record", parsed_search.query);

            var parsed_query = try parseFreeTextDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH", "(n)", "RETURN", "n" }, 2, 1);
            defer parsed_query.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(".tinykg", parsed_query.db_path);
            try std.testing.expectEqualStrings("MATCH", parsed_query.rest[0]);
        }

        test "fixed-arity commands prefer default db for valid optional arguments" {
            const governance_default = try parseDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "governance" }, 2, 0, 0, true);
            try std.testing.expectEqualStrings(".tinykg", governance_default.db_path);
            try std.testing.expectEqual(@as(usize, 0), governance_default.rest.len);

            const neighbors_default = try parseDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "neighbors", "1", "defines" }, 2, 1, 2, true);
            try std.testing.expectEqualStrings(".tinykg", neighbors_default.db_path);
            try std.testing.expectEqualStrings("1", neighbors_default.rest[0]);
            try std.testing.expectEqualStrings("defines", neighbors_default.rest[1]);

            const path_default = try parseDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "path", "1", "2", "depends_on" }, 2, 2, 3, true);
            try std.testing.expectEqualStrings(".tinykg", path_default.db_path);
            try std.testing.expectEqualStrings("1", path_default.rest[0]);
            try std.testing.expectEqualStrings("2", path_default.rest[1]);
            try std.testing.expectEqualStrings("depends_on", path_default.rest[2]);
        }

        test "fixed-arity commands use existing store path to break db ambiguity" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();

            const parsed = try parseDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "neighbors", db_path, "1" }, 2, 1, 2, true);
            try std.testing.expectEqualStrings(db_path, parsed.db_path);
            try std.testing.expectEqualStrings("1", parsed.rest[0]);
        }

        test "neighbors parser accepts explicit bounded output limit" {
            const bounded = try parseNeighborsArgs(&.{ "1", "defines", "--limit", "16", "--offset", "32", "--schema", "schema.json" });
            try std.testing.expectEqualStrings("1", bounded.node_id);
            try std.testing.expectEqualStrings("defines", bounded.rel_label.?);
            try std.testing.expectEqualStrings("schema.json", bounded.schema_path.?);
            try std.testing.expectEqual(@as(usize, 16), bounded.limit.?);
            try std.testing.expectEqual(@as(usize, 32), bounded.offset);

            const bounded_without_rel = try parseNeighborsArgs(&.{ "1", "--limit", "8" });
            try std.testing.expectEqualStrings("1", bounded_without_rel.node_id);
            try std.testing.expectEqual(@as(?[]const u8, null), bounded_without_rel.rel_label);
            try std.testing.expectEqual(@as(usize, 8), bounded_without_rel.limit.?);

            const json_meta = try parseNeighborsArgs(&.{ "1", "contains", "--format", "json", "--meta", "--depth", "2", "--max-nodes", "4", "--max-edges", "5", "--max-chars", "128" });
            try std.testing.expectEqual(CliOutputFormat.json, json_meta.format);
            try std.testing.expect(json_meta.meta);
            try std.testing.expectEqual(@as(usize, 2), json_meta.depth);
            try std.testing.expectEqual(@as(?usize, 4), json_meta.max_nodes);
            try std.testing.expectEqual(@as(?usize, 5), json_meta.max_edges);
            try std.testing.expectEqual(@as(?usize, 128), json_meta.max_chars);

            try std.testing.expectError(error.InvalidLimit, parseNeighborsArgs(&.{ "1", "--limit", "0" }));
            try std.testing.expectError(error.MissingArgument, parseNeighborsArgs(&.{ "1", "--offset", "8" }));
            try std.testing.expectError(error.Unsupported, parseNeighborsArgs(&.{ "1", "--meta" }));
            try std.testing.expectError(error.Unsupported, parseNeighborsArgs(&.{ "1", "--depth", "2" }));
            try std.testing.expectError(error.InvalidLimit, parseNeighborsArgs(&.{ "1", "--depth", "0" }));
            try std.testing.expectError(error.UnknownOption, parseNeighborsArgs(&.{ "1", "--unknown" }));
        }

        test "task packet parser accepts bounded output limit" {
            const default_limit = try parseTaskPacketArgs(&.{"1"});
            try std.testing.expectEqualStrings("1", default_limit.task_id);
            try std.testing.expectEqual(@as(usize, 8), default_limit.limit);

            const bounded = try parseTaskPacketArgs(&.{ "1", "--limit", "16" });
            try std.testing.expectEqualStrings("1", bounded.task_id);
            try std.testing.expectEqual(@as(usize, 16), bounded.limit);

            const json_meta = try parseTaskPacketArgs(&.{ "1", "--format", "json", "--meta", "--limit", "4", "--max-nodes", "8", "--max-edges", "9", "--max-chars", "128" });
            try std.testing.expectEqual(CliOutputFormat.json, json_meta.format);
            try std.testing.expect(json_meta.meta);
            try std.testing.expectEqual(@as(usize, 4), json_meta.limit);
            try std.testing.expectEqual(@as(?usize, 8), json_meta.max_nodes);
            try std.testing.expectEqual(@as(?usize, 9), json_meta.max_edges);
            try std.testing.expectEqual(@as(?usize, 128), json_meta.max_chars);

            try std.testing.expectError(error.InvalidLimit, parseTaskPacketArgs(&.{ "1", "--limit", "0" }));
            try std.testing.expectError(error.MissingArgument, parseTaskPacketArgs(&.{ "1", "--limit" }));
            try std.testing.expectError(error.Unsupported, parseTaskPacketArgs(&.{ "1", "--meta" }));
            try std.testing.expectError(error.Unsupported, parseTaskPacketArgs(&.{ "1", "--max-nodes", "2" }));
            try std.testing.expectError(error.UnknownOption, parseTaskPacketArgs(&.{ "1", "--unknown" }));
            try std.testing.expectError(error.TooManyArguments, parseTaskPacketArgs(&.{ "1", "2" }));
        }

        test "task frontier parser accepts bounded output limit" {
            const default_limit = try parseTaskFrontierArgs(&.{"1"});
            try std.testing.expectEqualStrings("1", default_limit.root_id);
            try std.testing.expectEqual(@as(usize, 8), default_limit.limit);

            const bounded = try parseTaskFrontierArgs(&.{ "1", "--limit", "16" });
            try std.testing.expectEqualStrings("1", bounded.root_id);
            try std.testing.expectEqual(@as(usize, 16), bounded.limit);

            try std.testing.expectError(error.InvalidLimit, parseTaskFrontierArgs(&.{ "1", "--limit", "0" }));
            try std.testing.expectError(error.MissingArgument, parseTaskFrontierArgs(&.{ "1", "--limit" }));
            try std.testing.expectError(error.UnknownOption, parseTaskFrontierArgs(&.{ "1", "--unknown" }));
            try std.testing.expectError(error.TooManyArguments, parseTaskFrontierArgs(&.{ "1", "2" }));
        }

        test "task ancestry parser accepts bounded depth and output limit" {
            const defaults = try parseTaskAncestryArgs(&.{"1"});
            try std.testing.expectEqualStrings("1", defaults.task_id);
            try std.testing.expectEqual(@as(usize, 3), defaults.depth);
            try std.testing.expectEqual(@as(usize, 16), defaults.limit);

            const bounded = try parseTaskAncestryArgs(&.{ "1", "--depth", "2", "--limit", "8" });
            try std.testing.expectEqualStrings("1", bounded.task_id);
            try std.testing.expectEqual(@as(usize, 2), bounded.depth);
            try std.testing.expectEqual(@as(usize, 8), bounded.limit);

            try std.testing.expectError(error.InvalidLimit, parseTaskAncestryArgs(&.{ "1", "--depth", "0" }));
            try std.testing.expectError(error.InvalidLimit, parseTaskAncestryArgs(&.{ "1", "--depth", "9" }));
            try std.testing.expectError(error.InvalidLimit, parseTaskAncestryArgs(&.{ "1", "--limit", "0" }));
            try std.testing.expectError(error.MissingArgument, parseTaskAncestryArgs(&.{ "1", "--depth" }));
            try std.testing.expectError(error.UnknownOption, parseTaskAncestryArgs(&.{ "1", "--unknown" }));
            try std.testing.expectError(error.TooManyArguments, parseTaskAncestryArgs(&.{ "1", "2" }));
        }

        test "task metrics parser accepts bounded output limit" {
            const defaults = try parseTaskMetricsArgs(&.{"1"});
            try std.testing.expectEqualStrings("1", defaults.root_id);
            try std.testing.expectEqual(@as(usize, 64), defaults.limit);

            const bounded = try parseTaskMetricsArgs(&.{ "1", "--limit", "8" });
            try std.testing.expectEqualStrings("1", bounded.root_id);
            try std.testing.expectEqual(@as(usize, 8), bounded.limit);

            try std.testing.expectError(error.InvalidLimit, parseTaskMetricsArgs(&.{ "1", "--limit", "0" }));
            try std.testing.expectError(error.MissingArgument, parseTaskMetricsArgs(&.{ "1", "--limit" }));
            try std.testing.expectError(error.UnknownOption, parseTaskMetricsArgs(&.{ "1", "--unknown" }));
            try std.testing.expectError(error.TooManyArguments, parseTaskMetricsArgs(&.{ "1", "2" }));
        }

        test "fixed-arity commands reject extra arguments" {
            try std.testing.expectError(
                error.TooManyArguments,
                parseDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "task-ready", "1", "extra" }, 2, 1, 1, true),
            );
        }

        test "search parser keeps flag-like query tokens unless they are valid trailing options" {
            var literal_limit = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "--limit" });
            defer literal_limit.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(".tinykg", literal_limit.db_path);
            try std.testing.expectEqualStrings("--limit", literal_limit.query);
            try std.testing.expectEqual(@as(?core.NodeKind, null), literal_limit.kind_filter);
            try std.testing.expectEqual(@as(usize, 20), literal_limit.limit);

            var limit_buf: [32]u8 = undefined;
            const max_limit = try std.fmt.bufPrint(&limit_buf, "{}", .{(core.QueryBudget{}).max_results});
            var trailing_options = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "edge", "index", "--kind", "task", "--limit", max_limit });
            defer trailing_options.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("edge index", trailing_options.query);
            try std.testing.expectEqual(core.NodeKind.task, trailing_options.kind_filter.?);
            try std.testing.expectEqual((core.QueryBudget{}).max_results, trailing_options.limit);
            try std.testing.expectEqual((core.QueryBudget{}).max_text_postings_scanned, trailing_options.max_postings_scanned);
            try std.testing.expectEqual((core.QueryBudget{}).timeout_ms, trailing_options.timeout_ms);
            try std.testing.expectEqual(CliOutputFormat.text, trailing_options.format);

            var json_meta = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "edge", "index", "--format", "json", "--meta" });
            defer json_meta.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("edge index", json_meta.query);
            try std.testing.expectEqual(CliOutputFormat.json, json_meta.format);
            try std.testing.expect(json_meta.meta);

            var max_postings_buf: [32]u8 = undefined;
            const max_postings = try std.fmt.bufPrint(&max_postings_buf, "{}", .{max_cli_text_postings_scanned});
            var max_timeout_buf: [32]u8 = undefined;
            const max_timeout = try std.fmt.bufPrint(&max_timeout_buf, "{}", .{max_cli_text_timeout_ms});
            var postings_budget = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "edge", "index", "--max-postings", max_postings, "--timeout-ms", max_timeout });
            defer postings_budget.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("edge index", postings_budget.query);
            try std.testing.expectEqual(max_cli_text_postings_scanned, postings_budget.max_postings_scanned);
            try std.testing.expectEqual(max_cli_text_timeout_ms, postings_budget.timeout_ms);

            var query_budget = try parseQueryArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH", "TEXT", "\"edge index\"", "AS", "n", "RETURN", "n", "--max-postings", max_postings, "--timeout-ms", max_timeout });
            defer query_budget.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("MATCH TEXT \"edge index\" AS n RETURN n", query_budget.query);
            try std.testing.expectEqual(max_cli_text_postings_scanned, query_budget.max_postings_scanned);
            try std.testing.expectEqual(max_cli_text_timeout_ms, query_budget.timeout_ms);

            var labeled_query = try parseQueryArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH (n:Task) RETURN n LIMIT nope" });
            defer labeled_query.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(".tinykg", labeled_query.db_path);
            try std.testing.expectEqualStrings("MATCH (n:Task) RETURN n LIMIT nope", labeled_query.query);

            var agent_memory_search = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "edge", "index", "--profile", "agent-memory" });
            defer agent_memory_search.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("edge index", agent_memory_search.query);
            try std.testing.expectEqual(agent_memory_text_postings_scanned, agent_memory_search.max_postings_scanned);
            try std.testing.expectEqual(agent_memory_text_timeout_ms, agent_memory_search.timeout_ms);
            try std.testing.expect(!agent_memory_search.include_history);

            var history_search = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "edge", "index", "--include-history", "--profile", "agent-memory" });
            defer history_search.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("edge index", history_search.query);
            try std.testing.expect(history_search.include_history);
            try std.testing.expectEqual(agent_memory_text_postings_scanned, history_search.max_postings_scanned);

            var override_after_profile = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "edge", "index", "--profile", "agent-memory", "--max-postings", "42", "--timeout-ms", "100" });
            defer override_after_profile.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 42), override_after_profile.max_postings_scanned);
            try std.testing.expectEqual(@as(u64, 100), override_after_profile.timeout_ms);

            var override_before_profile = try parseQueryArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH", "TEXT", "\"edge index\"", "AS", "n", "RETURN", "n", "--max-postings", "43", "--timeout-ms", "101", "--profile", "agent-memory" });
            defer override_before_profile.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 43), override_before_profile.max_postings_scanned);
            try std.testing.expectEqual(@as(u64, 101), override_before_profile.timeout_ms);
        }

        test "optional-db commands reject extra arguments" {
            try std.testing.expectEqualStrings(".tinykg", try parseOptionalDbPath(&.{ "tinykg", "stats" }, 2));
            try std.testing.expectEqualStrings("kg", try parseOptionalDbPath(&.{ "tinykg", "stats", "kg" }, 2));
            try std.testing.expectError(
                error.TooManyArguments,
                parseOptionalDbPath(&.{ "tinykg", "stats", "kg", "extra" }, 2),
            );
            try std.testing.expectError(
                error.TooManyArguments,
                parseOptionalDbPath(&.{ "tinykg", "init", "kg", "extra" }, 2),
            );
        }

        test "context parser accepts budgeted agent retrieval options" {
            var parsed = try parseContextArgs(std.testing.allocator, std.testing.io, &.{
                "tinykg",                   "context-packet", "markdown",     "retrieval",
                "--task",                   "7",              "--node",       "9",
                "--limit",                  "3",              "--profile",    "interactive",
                "--max-postings",           "100",            "--timeout-ms", "50",
                "--include-history",        "--format",       "json",         "--meta",
                "--neighbor-depth",         "2",              "--max-nodes",  "5",
                "--max-edges",              "6",              "--max-chars",  "700",
                "--markdown-preview-lines", "4",
            });
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("markdown retrieval", parsed.query);
            try std.testing.expectEqual(@as(u64, 7), parsed.task_id.?.toInt());
            try std.testing.expectEqual(@as(u64, 9), parsed.root_node_id.?.toInt());
            try std.testing.expectEqual(TextBudgetProfile.interactive, parsed.profile);
            try std.testing.expectEqual(@as(usize, 3), parsed.limit);
            try std.testing.expect(parsed.include_history);
            try std.testing.expectEqual(CliOutputFormat.json, parsed.format);
            try std.testing.expect(parsed.meta);
            try std.testing.expectEqual(@as(usize, 100), parsed.max_postings_scanned);
            try std.testing.expectEqual(@as(u64, 50), parsed.timeout_ms);
            try std.testing.expectEqual(@as(usize, 2), parsed.neighbor_depth);
            try std.testing.expectEqual(@as(usize, 5), parsed.max_nodes);
            try std.testing.expectEqual(@as(usize, 6), parsed.max_edges);
            try std.testing.expectEqual(@as(usize, 700), parsed.max_chars);
            try std.testing.expectEqual(@as(usize, 4), parsed.markdown_preview_lines);

            try std.testing.expectError(error.Unsupported, parseContextArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "context-plan", "query", "--format", "text" }));
            try std.testing.expectError(error.InvalidLimit, parseContextArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "context-plan", "query", "--neighbor-depth", "0" }));
            try std.testing.expectError(error.UnknownOption, parseContextArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "context-plan", "query", "--unknown", "value" }));
        }

        test "search parser rejects malformed trailing options" {
            try std.testing.expectError(
                error.InvalidLimit,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--limit", "flag" }),
            );
            var excessive_limit_buf: [32]u8 = undefined;
            const excessive_limit = try std.fmt.bufPrint(&excessive_limit_buf, "{}", .{(core.QueryBudget{}).max_results + 1});
            try std.testing.expectError(
                error.InvalidLimit,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--limit", excessive_limit }),
            );
            try std.testing.expectError(
                error.InvalidNodeKind,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--kind", "not-a-kind" }),
            );
            var zero_postings = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--max-postings", "0" });
            defer zero_postings.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), zero_postings.max_postings_scanned);

            var excessive_postings_buf: [32]u8 = undefined;
            const excessive_postings = try std.fmt.bufPrint(&excessive_postings_buf, "{}", .{max_cli_text_postings_scanned + 1});
            try std.testing.expectError(
                error.InvalidLimit,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--max-postings", excessive_postings }),
            );
            try std.testing.expectError(
                error.InvalidLimit,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--timeout-ms", "0" }),
            );
            var excessive_timeout_buf: [32]u8 = undefined;
            const excessive_timeout = try std.fmt.bufPrint(&excessive_timeout_buf, "{}", .{max_cli_text_timeout_ms + 1});
            try std.testing.expectError(
                error.InvalidLimit,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--timeout-ms", excessive_timeout }),
            );
            try std.testing.expectError(
                error.UnknownOption,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--unknown", "value" }),
            );
            try std.testing.expectError(
                error.InvalidLimit,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", "document", "--profile", "batch" }),
            );
            try std.testing.expectError(
                error.InvalidLimit,
                parseQueryArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH", "TEXT", "\"document\"", "AS", "n", "RETURN", "n", "--max-postings", excessive_postings }),
            );
            try std.testing.expectError(
                error.InvalidLimit,
                parseQueryArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH", "TEXT", "\"document\"", "AS", "n", "RETURN", "n", "--timeout-ms", "0" }),
            );
            try std.testing.expectError(
                error.UnknownOption,
                parseQueryArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", "MATCH", "(n)", "RETURN", "n", "--unknown", "value" }),
            );
        }

        test "free-text commands accept existing TinyKG store path" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();

            var parsed_search = try parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", db_path, "invalid", "record" });
            defer parsed_search.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(db_path, parsed_search.db_path);
            try std.testing.expectEqualStrings("invalid record", parsed_search.query);

            var parsed_query = try parseFreeTextDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", db_path, "MATCH", "(n)", "RETURN", "n" }, 2, 1);
            defer parsed_query.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(db_path, parsed_query.db_path);
            try std.testing.expectEqualStrings("MATCH", parsed_query.rest[0]);
        }

        test "free-text commands reject explicit non-store paths instead of falling back to default db" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "not-a-store" });
            defer std.testing.allocator.free(dir_path);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, dir_path);

            try std.testing.expectError(
                error.FileNotFound,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", dir_path, "invalid", "record" }),
            );
            try std.testing.expectError(
                error.FileNotFound,
                parseFreeTextDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", dir_path, "MATCH", "(n)", "RETURN", "n" }, 2, 1),
            );
            try std.testing.expectError(
                error.FileNotFound,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", ".tinykg", "invalid", "record" }),
            );
        }

        test "free-text store path detection ignores directory markers and file candidates" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];

            const marker_dir_store = try std.fs.path.join(std.testing.allocator, &.{ root_path, "marker-dir-store" });
            defer std.testing.allocator.free(marker_dir_store);
            const marker_dir = try std.fs.path.join(std.testing.allocator, &.{ marker_dir_store, "events.bin" });
            defer std.testing.allocator.free(marker_dir);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, marker_dir);

            try std.testing.expect(!try existingTinyKgStorePath(std.testing.allocator, std.testing.io, marker_dir_store));

            const meta_only_store = try std.fs.path.join(std.testing.allocator, &.{ root_path, "meta-only-store" });
            defer std.testing.allocator.free(meta_only_store);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, meta_only_store);
            const meta_only_file = try std.fs.path.join(std.testing.allocator, &.{ meta_only_store, "index.meta" });
            defer std.testing.allocator.free(meta_only_file);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = meta_only_file,
                .data = "not a store marker",
                .flags = .{ .truncate = true },
            });

            try std.testing.expect(!try existingTinyKgStorePath(std.testing.allocator, std.testing.io, meta_only_store));

            const file_candidate = try std.fs.path.join(std.testing.allocator, &.{ root_path, "plain-file" });
            defer std.testing.allocator.free(file_candidate);
            var file = try std.Io.Dir.cwd().createFile(std.testing.io, file_candidate, .{});
            file.close(std.testing.io);

            try std.testing.expect(!try existingTinyKgStorePath(std.testing.allocator, std.testing.io, file_candidate));
        }

        test "free-text commands reject existing store path without query text" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();

            try std.testing.expectError(
                error.MissingArgument,
                parseSearchArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "search", db_path }),
            );
            try std.testing.expectError(
                error.MissingArgument,
                parseFreeTextDbArgs(std.testing.allocator, std.testing.io, &.{ "tinykg", "query", db_path }, 2, 1),
            );
        }

        test "reachable projection uses caller query budget" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "a" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "b" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .task, .text = "c" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(2), .rel = .depends_on, .dst = .fromInt(3) });

            var row = ql.executor.Row.init();
            defer row.deinit(std.testing.allocator);
            try std.testing.expect(try row.put(std.testing.allocator, "a", .fromInt(1)));
            try std.testing.expect(try row.put(std.testing.allocator, "c", .fromInt(3)));

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try std.testing.expectError(
                core.Error.BudgetExceeded,
                writeProjectionPersistent(
                    &out,
                    std.testing.allocator,
                    store,
                    null,
                    null,
                    null,
                    0,
                    row,
                    .{ .reachable = .{ .from_var = "a", .to_var = "c", .rel = .depends_on } },
                    .{ .max_depth = 1 },
                    null,
                ),
            );
        }

        test "persistent query explain includes projection budget failure" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "a" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "b" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .task, .text = "c" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(2), .rel = .depends_on, .dst = .fromInt(3) });
            try store.appendEdge(.{ .id = .fromInt(3), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) });

            const query_ast = try ql.parser.parse(std.testing.allocator, "MATCH (a:Task)-[:MENTIONS]->(c:Task) WHERE a.text = \"a\" AND c.text = \"c\" RETURN reachable(a,c,DEPENDS_ON)");
            defer ql.ast.freeQuery(std.testing.allocator, query_ast);
            var logical = try ql.planner.plan(std.testing.allocator, query_ast);
            defer logical.deinit(std.testing.allocator);
            var physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            defer physical.deinit(std.testing.allocator);

            try std.testing.expectError(
                core.Error.BudgetExceeded,
                renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, false, .{ .max_depth = 1 }),
            );

            const explain = try renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, true, .{ .max_depth = 1 });
            defer std.testing.allocator.free(explain);
            try std.testing.expect(std.mem.indexOf(u8, explain, "rows=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "nodes_visited=4") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "edges_visited=3") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "budget_exceeded=true") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "elapsed_ns=") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "text_warm_start=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "text_warm_end=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "max_depth=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "plan=node_lookup_by_text(index=node_by_text,var=a,kind=task)") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "expand(index=edge_by_src,dir=outgoing,from=a,to=c,rel=mentions,hops=1..1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "project(cols=1)") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "op_timings=0:node_lookup_by_text:ns=") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, ",1:expand:ns=") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, ",2:project:ns=") != null);
        }

        test "persistent query refuses partial execution results without explain" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "a" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "b" });

            const query_ast = try ql.parser.parse(std.testing.allocator, "MATCH (t:Task) RETURN t LIMIT 10");
            defer ql.ast.freeQuery(std.testing.allocator, query_ast);
            var logical = try ql.planner.plan(std.testing.allocator, query_ast);
            defer logical.deinit(std.testing.allocator);
            var physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            defer physical.deinit(std.testing.allocator);

            try std.testing.expectError(
                core.Error.BudgetExceeded,
                renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, false, .{ .max_visited_nodes = 1 }),
            );

            const explain = try renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, true, .{ .max_visited_nodes = 1 });
            defer std.testing.allocator.free(explain);
            try std.testing.expect(std.mem.indexOf(u8, explain, "rows=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "budget_exceeded=true") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "text_warm_start=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "text_warm_end=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "max_visited_nodes=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "plan=node_scan(index=node_by_id,var=t,kind=task)") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "op_timings=0:node_scan:ns=") != null);
        }

        test "projection explain stat merge rejects overflow" {
            var stats = query_index.QueryStats{
                .nodes_visited = std.math.maxInt(usize),
            };

            try std.testing.expectError(
                error.RecordTooLarge,
                mergeProjectionStats(&stats, .{ .nodes_visited = 1 }),
            );
            try std.testing.expectEqual(std.math.maxInt(usize), stats.nodes_visited);

            stats = .{
                .edges_visited = std.math.maxInt(usize),
            };
            try std.testing.expectError(
                error.RecordTooLarge,
                mergeProjectionStats(&stats, .{ .nodes_visited = 7, .edges_visited = 1 }),
            );
            try std.testing.expectEqual(@as(usize, 0), stats.nodes_visited);
            try std.testing.expectEqual(std.math.maxInt(usize), stats.edges_visited);
        }

        test "persistent query explain includes context projection budget failure" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "focus" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "a" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .task, .text = "b" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(3) });

            const query_ast = try ql.parser.parse(std.testing.allocator, "MATCH (n:Task) WHERE n.text = \"focus\" RETURN context(n)");
            defer ql.ast.freeQuery(std.testing.allocator, query_ast);
            var logical = try ql.planner.plan(std.testing.allocator, query_ast);
            defer logical.deinit(std.testing.allocator);
            var physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            defer physical.deinit(std.testing.allocator);

            try std.testing.expectError(
                core.Error.BudgetExceeded,
                renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, false, .{ .max_visited_edges = 1 }),
            );

            const explain = try renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, true, .{ .max_visited_edges = 1 });
            defer std.testing.allocator.free(explain);
            try std.testing.expect(std.mem.indexOf(u8, explain, "rows=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "nodes_visited=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "edges_visited=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain, "budget_exceeded=true") != null);
        }

        test "persistent projection rejects bound missing node ids" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();

            var row = ql.executor.Row.init();
            defer row.deinit(std.testing.allocator);
            try std.testing.expect(try row.put(std.testing.allocator, "n", .fromInt(99)));
            try row.putPath(std.testing.allocator, "a", "b", &.{ .fromInt(1), .fromInt(99) });

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try std.testing.expectError(
                error.InvalidRecord,
                writeProjectionPersistent(
                    &out,
                    std.testing.allocator,
                    store,
                    null,
                    null,
                    null,
                    0,
                    row,
                    .{ .variable = "n" },
                    .{},
                    null,
                ),
            );
            try std.testing.expectError(
                error.InvalidRecord,
                writeProjectionPersistent(
                    &out,
                    std.testing.allocator,
                    store,
                    null,
                    null,
                    null,
                    0,
                    row,
                    .{ .property = .{ .var_name = "n", .property = "name" } },
                    .{},
                    null,
                ),
            );
            try std.testing.expectError(
                error.InvalidRecord,
                writeProjectionPersistent(
                    &out,
                    std.testing.allocator,
                    store,
                    null,
                    null,
                    null,
                    0,
                    row,
                    .{ .path = .{ .from_var = "a", .to_var = "b" } },
                    .{},
                    null,
                ),
            );
        }

        test "persistent status projection uses executor read timestamp" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "lease boundary" });
            try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.status_property, "claimed");
            try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.claimed_by_property, "agent-a");
            try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, task.claim_expires_ns_property, 101);

            var row = ql.executor.Row.init();
            defer row.deinit(std.testing.allocator);
            try std.testing.expect(try row.put(std.testing.allocator, "n", .fromInt(1)));
            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try writeProjectionPersistent(&out, std.testing.allocator, store, null, null, null, 100, row, .{
                .property = .{ .var_name = "n", .property = task.status_property },
            }, .{}, null);
            try std.testing.expectEqualStrings("claimed", out.buffer.items);
            out.buffer.clearRetainingCapacity();
            try writeProjectionPersistent(&out, std.testing.allocator, store, null, null, null, 101, row, .{
                .property = .{ .var_name = "n", .property = task.status_property },
            }, .{}, null);
            try std.testing.expectEqualStrings("open", out.buffer.items);
        }

        test "persistent status projection snapshots task owners across mixed rows" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNodesBatch(&.{
                .{ .id = .fromInt(1), .kind = .task, .text = "leased task" },
                .{ .id = .fromInt(2), .kind = .verification, .text = "published evidence" },
                .{ .id = .fromInt(3), .kind = .task, .text = "open task" },
            });
            _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
                .{ .owner = .{ .node = .fromInt(1) }, .key = task.status_property, .value = .{ .string = "claimed" } },
                .{ .owner = .{ .node = .fromInt(1) }, .key = task.claimed_by_property, .value = .{ .string = "agent-a" } },
                .{ .owner = .{ .node = .fromInt(1) }, .key = task.claim_expires_ns_property, .value = .{ .uint = 101 } },
                .{ .owner = .{ .node = .fromInt(2) }, .key = task.status_property, .value = .{ .string = "published" } },
                .{ .owner = .{ .node = .fromInt(3) }, .key = task.status_property, .value = .{ .string = "open" } },
            });

            var rows = [_]ql.executor.Row{ ql.executor.Row.init(), ql.executor.Row.init(), ql.executor.Row.init() };
            defer for (&rows) |*row| row.deinit(std.testing.allocator);
            for (&rows, 1..) |*row, raw_id| {
                try std.testing.expect(try row.put(std.testing.allocator, "n", .fromInt(raw_id)));
            }
            const projections = [_]ql.ast.Projection{.{
                .property = .{ .var_name = "n", .property = task.status_property },
            }};
            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var status_snapshot = (try initTaskStatusProjectionSnapshot(
                std.testing.allocator,
                store,
                &node_view,
                &rows,
                &projections,
            )).?;
            defer status_snapshot.deinit();
            try std.testing.expect(status_snapshot.covers(.fromInt(1)));
            try std.testing.expect(!status_snapshot.covers(.fromInt(2)));
            try std.testing.expect(status_snapshot.covers(.fromInt(3)));

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            for (rows, 0..) |row, index| {
                if (index != 0) try out.writeAll("\n");
                try writeProjectionPersistent(
                    &out,
                    std.testing.allocator,
                    store,
                    null,
                    &node_view,
                    &status_snapshot,
                    100,
                    row,
                    projections[0],
                    .{},
                    null,
                );
            }
            try std.testing.expectEqualStrings("claimed\npublished\nopen", out.buffer.items);
        }

        test "persistent query output renders from physical projections after AST is freed" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);
            const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "edge-s000001" });
            defer std.testing.allocator.free(segment_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) });
            try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(segment_path));
            try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_src_path);

            var physical: ql.optimizer.PhysicalPlan = undefined;
            {
                const source = try std.testing.allocator.dupe(u8, "MATCH (f:file)-[:defines]->(s:function) WHERE f.text = \"src/main.zig\" RETURN s.text");
                defer std.testing.allocator.free(source);
                const query_ast = try ql.parser.parse(std.testing.allocator, source);
                defer ql.ast.freeQuery(std.testing.allocator, query_ast);
                var logical = try ql.planner.plan(std.testing.allocator, query_ast);
                defer logical.deinit(std.testing.allocator);
                physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            }
            defer physical.deinit(std.testing.allocator);

            const output = try renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, false, .{});
            defer std.testing.allocator.free(output);
            try std.testing.expectEqualStrings("main\n", output);

            var retention_registry = storage.EdgeSegmentRetentionRegistry.init(std.testing.allocator);
            defer retention_registry.deinit();
            const retained_output = try renderPersistentQueryOutputRetained(std.testing.allocator, std.testing.io, store, &retention_registry, physical, false, .{});
            defer std.testing.allocator.free(retained_output);
            try std.testing.expectEqualStrings("main\n", retained_output);
            {
                const active_paths = try retention_registry.activeManifestPaths(std.testing.allocator);
                defer std.testing.allocator.free(active_paths);
                try std.testing.expectEqual(@as(usize, 0), active_paths.len);
            }
        }

        test "persistent query output renders BM25 backed unreachable projection as false" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "benchdoc1 source" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "benchdoc2 target" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) });

            const query_ast = try ql.parser.parse(std.testing.allocator, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions]->(n:file) WHERE n.text = \"benchdoc2 target\" RETURN reachable(f,n,DEPENDS_ON)");
            defer ql.ast.freeQuery(std.testing.allocator, query_ast);
            var logical = try ql.planner.plan(std.testing.allocator, query_ast);
            defer logical.deinit(std.testing.allocator);
            var physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            defer physical.deinit(std.testing.allocator);

            const output = try renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, false, .{});
            defer std.testing.allocator.free(output);
            try std.testing.expectEqualStrings("false\n", output);
        }

        test "persistent query output renders BM25 backed path projection" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "benchdoc1 source" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "benchdoc2 target" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) });

            const query_ast = try ql.parser.parse(std.testing.allocator, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions]->(n:file) WHERE n.text = \"benchdoc2 target\" RETURN path(f,n)");
            defer ql.ast.freeQuery(std.testing.allocator, query_ast);
            var logical = try ql.planner.plan(std.testing.allocator, query_ast);
            defer logical.deinit(std.testing.allocator);
            var physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            defer physical.deinit(std.testing.allocator);

            const output = try renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, false, .{});
            defer std.testing.allocator.free(output);
            try std.testing.expectEqualStrings("1 -> 2\n", output);
        }

        test "persistent query output renders BM25 backed mixed projections" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "benchdoc1 source" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "benchdoc2 target" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(2) });

            const query_ast = try ql.parser.parse(std.testing.allocator, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions]->(n:file) WHERE n.text = \"benchdoc2 target\" RETURN context(f), path(f,n), reachable(f,n,DEPENDS_ON)");
            defer ql.ast.freeQuery(std.testing.allocator, query_ast);
            var logical = try ql.planner.plan(std.testing.allocator, query_ast);
            defer logical.deinit(std.testing.allocator);
            var physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            defer physical.deinit(std.testing.allocator);

            const output = try renderPersistentQueryOutput(std.testing.allocator, std.testing.io, store, physical, false, .{});
            defer std.testing.allocator.free(output);
            try std.testing.expect(std.mem.indexOf(u8, output, "\t1 -> 2\ttrue\n") != null);
        }

        test "CLI segment-query opens trusted bundle and renders catalog projections" {
            const segment = @import("../segment.zig");
            const segment_executor = @import("../ql/segment_executor.zig");

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_dir = path_buf[0..root_len];

            const nodes = [_]segment_executor.NodeInfoEntry{
                .{ .id = .fromInt(10), .kind = .file, .text = "src/main.zig" },
                .{ .id = .fromInt(20), .kind = .function, .text = "main" },
            };
            const edges = [_]segment.EdgeRecord{
                .{ .edge_id = .fromInt(7), .src = .fromInt(10), .rel = .defines, .dst = .fromInt(20) },
            };
            try segment_bundle.publish(std.testing.allocator, std.testing.io, root_dir, .{
                .nodes = &nodes,
                .edges = &edges,
                .wal_checkpoint_bytes = 512,
            });

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{
                "tinykg",
                "segment-query",
                root_dir,
                "MATCH (f:file)-[:defines]->(s:function) WHERE f.text = \"src/main.zig\" RETURN s.text, s",
            }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("main\t20:function:main\n", out.buffer.items);

            var explain = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer explain.buffer.deinit(std.testing.allocator);
            try run(&.{
                "tinykg",
                "segment-query-explain",
                root_dir,
                "MATCH (f:file)-[:defines]->(s:function) WHERE f.text = \"src/main.zig\" RETURN s",
            }, &explain, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, explain.buffer.items, "rows=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, explain.buffer.items, "edges_visited=1") != null);
        }

        fn renderSearchOutputAllocationFailure(allocator: std.mem.Allocator, store: storage.Store) !void {
            const output = try renderSearchOutput(allocator, store, "edge index", .{ .limit = 10 }, .interactive, 10, false, .{});
            defer allocator.free(output);
            try std.testing.expect(std.mem.indexOf(u8, output, "1\ttask\tedge index repair\t") != null);
        }

        test "search output render rolls back allocation failures" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "edge index repair" });
            var prebuilt = try text_search.searchText(std.testing.allocator, store, "edge index", .{ .limit = 10 });
            prebuilt.deinit(std.testing.allocator);

            try std.testing.checkAllAllocationFailures(std.testing.allocator, renderSearchOutputAllocationFailure, .{store});
        }

        test "search output honors caller deadline budget" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "edge index repair" });

            try std.testing.expectError(
                core.Error.BudgetExceeded,
                renderSearchOutput(std.testing.allocator, store, "edge index", .{ .limit = 10, .deadline = .immediate }, .interactive, 10, false, .{}),
            );
        }

        test "agent-memory search output prefers semantic nodes over evidence candidates" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .evidence, .text = "storage repair storage repair storage repair raw command log" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .decision, .text = "storage repair policy" });
            var prebuilt = try text_search.searchText(std.testing.allocator, store, "storage repair", .{ .limit = 10 });
            prebuilt.deinit(std.testing.allocator);

            const output = try renderSearchOutput(
                std.testing.allocator,
                store,
                "storage repair",
                .{ .limit = 2 },
                .agent_memory,
                1,
                false,
                .{},
            );
            defer std.testing.allocator.free(output);
            try std.testing.expect(std.mem.startsWith(u8, output, "2\tdecision\tstorage repair policy\t"));
        }

        test "project containment 在 >1024 边 store(edge delta segment)上仍可见" {
            // Linus BLOCKER 回归锁:>1024 base 边后 appendEdge 走 delta segment,只读 committed 索引的
            // iterator 看不见新 contain 边 → BFS 瞎(--project 静默空)+ link 去重失效(重复边)。
            // 本测试在 segmented store 上压 linkNodeToProjectParent / collectProjectDescendantNodeIds /
            // renderSearchOutput --project 三条路。修复前(segment-blind 读)此测试红(已验证:换回瞎读法 1 failed)。
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .project, .text = "proj root" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .concept, .text = "delta segment target" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .concept, .text = "filler a" });
            try store.appendNode(.{ .id = .fromInt(4), .kind = .concept, .text = "filler b" });

            // 1100 条 filler 边:超过 implicit_edge_delta_segment_min_base_edges(1024)→ 后续 append 落 delta。
            var i: usize = 0;
            while (i < 1100) : (i += 1) {
                const id = try store.nextEdgeId();
                try store.appendEdge(.{ .id = id, .src = .fromInt(3), .rel = .references, .dst = .fromInt(4) });
            }

            // 挂接:contain 边此时落 delta segment。
            try linkNodeToProjectParent(std.testing.allocator, store, core.NodeId.fromInt(2), core.NodeId.fromInt(1));

            // ① BFS 必须看见 delta 上的 contain 边。
            var truncated = false;
            var ids = try collectProjectDescendantNodeIds(std.testing.allocator, store, .fromInt(1), null, 1000, &truncated, .contain_only);
            defer ids.deinit(std.testing.allocator);
            var found = false;
            for (ids.items) |id| {
                if (id.toInt() == 2) found = true;
            }
            try std.testing.expect(found);
            try std.testing.expect(!truncated);

            // ② 去重必须看见 delta 上的已有边:再 link 一次不得累积重复 contain 边。
            try linkNodeToProjectParent(std.testing.allocator, store, core.NodeId.fromInt(2), core.NodeId.fromInt(1));
            var children = try collectContainChildIds(std.testing.allocator, store, .fromInt(1));
            defer children.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), children.items.len);
            try std.testing.expectEqual(@as(u64, 2), children.items[0]);

            // ③ 端到端:search --project(server-side member_filter 下推)在 segmented store 上召回子树内命中。
            var prebuilt = try text_search.searchText(std.testing.allocator, store, "delta segment target", .{ .limit = 10 });
            prebuilt.deinit(std.testing.allocator);
            var diag = MemberFilterDiag{};
            var mset = (try buildSearchMemberSet(std.testing.allocator, store, "1", null, &diag)).?;
            defer mset.deinit();
            const scoped = try renderSearchOutput(std.testing.allocator, store, "delta segment target", .{ .limit = 10, .member_filter = &mset }, .interactive, 10, false, diag);
            defer std.testing.allocator.free(scoped);
            try std.testing.expect(std.mem.indexOf(u8, scoped, "delta segment target") != null);
        }

        test "task control plane sees relation-filtered delta segment edges" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNodesBatch(&.{
                .{ .id = .fromInt(1), .kind = .task, .text = "delta task root" },
                .{ .id = .fromInt(2), .kind = .task, .text = "base task child" },
                .{ .id = .fromInt(3), .kind = .verification, .text = "delta task proof" },
                .{ .id = .fromInt(4), .kind = .concept, .text = "filler source" },
                .{ .id = .fromInt(5), .kind = .concept, .text = "filler target" },
                .{ .id = .fromInt(6), .kind = .task, .text = "delta task child" },
            });
            _ = try dag.addEdgeCheckedWithPersistentStore(std.testing.allocator, store, .fromInt(1), .contains, .fromInt(2), .{});
            for (0..1100) |_| {
                const edge_id = try store.nextEdgeId();
                try store.appendEdge(.{ .id = edge_id, .src = .fromInt(4), .rel = .references, .dst = .fromInt(5) });
            }

            _ = try dag.addEdgeCheckedWithPersistentStore(std.testing.allocator, store, .fromInt(1), .contains, .fromInt(6), .{});
            try ensureTaskEvidenceEdge(std.testing.allocator, store, .fromInt(1), .fromInt(3));
            try ensureTaskEvidenceEdge(std.testing.allocator, store, .fromInt(1), .fromInt(3));

            var limited = try readVisibleEdgeRecordsByNodeLimited(std.testing.allocator, store, .src, .fromInt(4), .references, 2);
            defer limited.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), limited.items.len);
            try std.testing.expectError(
                core.Error.BudgetExceeded,
                readVisibleEdgeRecordsByNodeCompleteLimited(std.testing.allocator, store, .src, .fromInt(4), .references, 2),
            );

            const now_ns = try u128ToU64(persistentNowNs(std.testing.io));
            try std.testing.expect(try taskHasNonCompletedChildren(std.testing.allocator, store, .fromInt(1), now_ns));

            const root_packet = try renderTaskPacketOutput(std.testing.allocator, store, .fromInt(1), 8);
            defer std.testing.allocator.free(root_packet);
            try std.testing.expect(std.mem.indexOf(u8, root_packet, "child_out") != null);
            try std.testing.expect(std.mem.indexOf(u8, root_packet, "base task child") != null);
            try std.testing.expect(std.mem.indexOf(u8, root_packet, "delta task child") != null);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, root_packet, "verified_by_out"));

            const child_packet = try renderTaskPacketOutput(std.testing.allocator, store, .fromInt(6), 8);
            defer std.testing.allocator.free(child_packet);
            try std.testing.expect(std.mem.indexOf(u8, child_packet, "parent_in") != null);
            try std.testing.expect(std.mem.indexOf(u8, child_packet, "delta task root") != null);

            const frontier = try renderTaskFrontierOutput(
                std.testing.allocator,
                store,
                .fromInt(1),
                .{ .root_id = "1", .limit = 8 },
                now_ns,
            );
            defer std.testing.allocator.free(frontier);
            try std.testing.expect(std.mem.indexOf(u8, frontier, "base task child") != null);
            try std.testing.expect(std.mem.indexOf(u8, frontier, "delta task child") != null);
        }

        test "user visible node and markdown reads include published edge overlay" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const base_segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-base" });
            defer std.testing.allocator.free(base_segment_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNodesBatch(&.{
                .{ .id = .fromInt(1), .kind = .observation, .text = "old generation" },
                .{ .id = .fromInt(2), .kind = .decision, .text = "current generation" },
                .{ .id = .fromInt(3), .kind = .evidence, .text = "incoming evidence" },
                .{ .id = .fromInt(4), .kind = .concept, .text = "base source" },
                .{ .id = .fromInt(5), .kind = .concept, .text = "base target" },
                .{ .id = .fromInt(6), .kind = .document, .text = "overlay markdown" },
                .{ .id = .fromInt(7), .kind = .document_section, .text = "overlay heading" },
            });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(4), .rel = .references, .dst = .fromInt(5) });
            try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(base_segment_path));

            // These edges live only in the newly published delta overlay. The base
            // node indexes intentionally remain blind to them until maintenance.
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = .deprecated_by, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(3), .src = .fromInt(3), .rel = .references, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(4), .src = .fromInt(6), .rel = md_rel_h1, .dst = .fromInt(7) });
            var indexed_only = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
            defer indexed_only.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), indexed_only.items.len);

            try std.testing.expect(!try nodeIsCurrentGeneration(store, .fromInt(1)));
            try std.testing.expect(try nodeIsCurrentGeneration(store, .fromInt(2)));
            try std.testing.expectEqual(@as(u64, 2), (try nodeDeprecatedBy(store, .fromInt(1))).?.toInt());

            const old_stats = try nodeLocalGraphStats(store, .fromInt(1));
            try std.testing.expectEqual(@as(usize, 1), old_stats.out_degree);
            const current_stats = try nodeLocalGraphStats(store, .fromInt(2));
            try std.testing.expectEqual(@as(usize, 2), current_stats.in_degree);

            const versions = try renderNodeVersionsOutput(std.testing.allocator, store, .fromInt(1), 8);
            defer std.testing.allocator.free(versions);
            try std.testing.expect(std.mem.indexOf(u8, versions, "version\t2\tdeprecated_by\t1\t2\tdecision\tcurrent generation") != null);
            const latest = try renderNodeLatestOutput(std.testing.allocator, store, .fromInt(1), 8);
            defer std.testing.allocator.free(latest);
            try std.testing.expect(std.mem.indexOf(u8, latest, "latest\t2\tdeprecated_by\t1\t2\tdecision\tcurrent generation") != null);

            const incoming_current = try renderIncomingOutput(std.testing.allocator, store, null, .fromInt(2), null, .{ .max_results = 8, .max_visited_edges = 8 }, false);
            defer std.testing.allocator.free(incoming_current);
            try std.testing.expect(std.mem.indexOf(u8, incoming_current, "3\treferences\t3\tincoming evidence") != null);
            try std.testing.expect(std.mem.indexOf(u8, incoming_current, "old generation") == null);
            const incoming_history = try renderIncomingOutput(std.testing.allocator, store, null, .fromInt(2), null, .{ .max_results = 8, .max_visited_edges = 8 }, true);
            defer std.testing.allocator.free(incoming_history);
            try std.testing.expect(std.mem.indexOf(u8, incoming_history, "2\tdeprecated_by\t1\told generation") != null);

            try std.testing.expectEqual(@as(u64, 4), (try lookupMarkdownProjectionEdgeByEndpoints(std.testing.allocator, store, .fromInt(6), md_rel_h1, .fromInt(7))).?.toInt());
            try std.testing.expectEqual(md_rel_h1, (try markdownIncomingHeadingRel(std.testing.allocator, store, .fromInt(7))).?);
            var children = try markdownProjectionChildren(std.testing.allocator, store, .fromInt(6), md_rel_h1);
            defer children.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), children.items.len);
            try std.testing.expectEqual(@as(u64, 7), children.items[0].dst);

            var context = MarkdownImportContext{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
                .store = store,
                .document_external_key = "md-doc:overlay-test",
                .lookup_view = try store.openNodeTextLookupView(std.testing.allocator),
                .session_node_ids = std.StringHashMap(core.NodeId).init(std.testing.allocator),
                .session_node_external_keys = std.AutoHashMap(u64, []u8).init(std.testing.allocator),
                .session_edge_counts = std.StringHashMap(usize).init(std.testing.allocator),
                .desired_projection_owners = std.AutoHashMap(u64, void).init(std.testing.allocator),
                .session_owner_order_counts = std.AutoHashMap(u64, usize).init(std.testing.allocator),
                .reuse_existing_projection_edges = false,
                .pending_position_keys = std.StringHashMap(std.ArrayList(u64)).init(std.testing.allocator),
            };
            defer context.deinit();
            try std.testing.expect(!try appendMarkdownProjectionEdge(&context, .fromInt(6), md_rel_h1, .fromInt(7)));
            try std.testing.expectEqual(@as(usize, 0), context.pending_edges.items.len);
        }

        fn renderNeighborsOutputAllocationFailure(allocator: std.mem.Allocator, store: storage.Store) !void {
            const output = try renderNeighborsOutput(allocator, store, .fromInt(1), .defines, .{});
            defer allocator.free(output);
            try std.testing.expectEqualStrings("1\tdefines\t2\tmain\n", output);
        }

        test "neighbors output render rolls back allocation failures" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) });

            try std.testing.checkAllAllocationFailures(std.testing.allocator, renderNeighborsOutputAllocationFailure, .{store});
        }

        test "neighbors output refuses partial budgeted results" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .function, .text = "helper" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) });

            try std.testing.expectError(
                core.Error.BudgetExceeded,
                renderNeighborsOutput(std.testing.allocator, store, .fromInt(1), .defines, .{ .max_results = 1 }),
            );
        }

        test "neighbors bounded output returns explicit partial rows" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .function, .text = "helper" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) });

            const output = try renderNeighborsOutputBounded(std.testing.allocator, store, .fromInt(1), .defines, 1, 0);
            defer std.testing.allocator.free(output);
            try std.testing.expectEqualStrings("1\tdefines\t2\tmain\n", output);
        }

        test "neighbors bounded output supports explicit offset pages" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
            try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
            try store.appendNode(.{ .id = .fromInt(3), .kind = .function, .text = "helper" });
            try store.appendNode(.{ .id = .fromInt(4), .kind = .function, .text = "testMain" });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) });
            try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) });
            try store.appendEdge(.{ .id = .fromInt(3), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(4) });

            const output = try renderNeighborsOutputBounded(std.testing.allocator, store, .fromInt(1), .defines, 1, 1);
            defer std.testing.allocator.free(output);
            try std.testing.expectEqualStrings("2\tdefines\t3\thelper\n", output);
        }

        test "neighbors json meta returns subgraph envelope with backrefs and budgets" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.createEmpty();
                try store.appendNodesBatch(&.{
                    .{ .id = .fromInt(1), .kind = .task, .text = "root" },
                    .{ .id = .fromInt(2), .kind = .evidence, .text = "left" },
                    .{ .id = .fromInt(3), .kind = .evidence, .text = "right" },
                    .{ .id = .fromInt(4), .kind = .evidence, .text = "shared" },
                });
                try store.appendEdgesBatch(&.{
                    .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(2) },
                    .{ .id = .fromInt(2), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(3) },
                    .{ .id = .fromInt(3), .src = .fromInt(2), .rel = .contains, .dst = .fromInt(4) },
                    .{ .id = .fromInt(4), .src = .fromInt(3), .rel = .contains, .dst = .fromInt(4) },
                    .{ .id = .fromInt(5), .src = .fromInt(4), .rel = .contains, .dst = .fromInt(1) },
                });
            }

            var text_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer text_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "neighbors", db_path, "1", "contains", "--limit", "1" }, &text_out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("1\tcontains\t2\tleft\n", text_out.buffer.items);

            var json_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer json_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "neighbors", db_path, "1", "contains", "--format", "json", "--meta", "--depth", "3", "--max-nodes", "4", "--max-edges", "8", "--max-chars", "64" }, &json_out, std.testing.allocator, std.testing.io);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.buffer.items, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("tinykg-agent-retrieval-v1", parsed.value.object.get("schema_version").?.string);
            try std.testing.expectEqualStrings("neighbors", parsed.value.object.get("mode").?.string);
            try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("query").?.object.get("root_id").?.integer);
            try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("budget").?.object.get("max_depth").?.integer);
            try std.testing.expectEqual(@as(i64, 4), parsed.value.object.get("summary").?.object.get("node_count").?.integer);
            try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("summary").?.object.get("edge_count").?.integer);
            try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("summary").?.object.get("backref_count").?.integer);
            try std.testing.expect(!parsed.value.object.get("summary").?.object.get("truncated").?.bool);
            try std.testing.expectEqual(@as(i64, 5), parsed.value.object.get("summary").?.object.get("used_edges").?.integer);
            try std.testing.expectEqual(@as(i64, 19), parsed.value.object.get("summary").?.object.get("used_chars").?.integer);
            try std.testing.expectEqual(@as(i64, 19), parsed.value.object.get("summary").?.object.get("context_size").?.object.get("text_bytes").?.integer);
            try std.testing.expectEqual(@as(i64, 4), parsed.value.object.get("summary").?.object.get("context_size").?.object.get("text_lines").?.integer);
            try std.testing.expectEqual(@as(usize, 4), parsed.value.object.get("nodes").?.array.items.len);
            try std.testing.expect(parsed.value.object.get("nodes").?.array.items[0].object.get("text") == null);
            try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("edges").?.array.items.len);
            try std.testing.expectEqualStrings("tree", parsed.value.object.get("edges").?.array.items[0].object.get("role").?.string);
            try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("backrefs").?.array.items.len);
            try std.testing.expectEqualStrings("backref", parsed.value.object.get("backrefs").?.array.items[0].object.get("role").?.string);

            json_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "neighbors", db_path, "1", "contains", "--format", "json", "--meta", "--depth", "2", "--max-nodes", "2", "--max-edges", "8", "--max-chars", "64" }, &json_out, std.testing.allocator, std.testing.io);
            var truncated = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.buffer.items, .{});
            defer truncated.deinit();
            try std.testing.expect(truncated.value.object.get("summary").?.object.get("truncated").?.bool);
            try std.testing.expectEqualStrings("max_nodes", truncated.value.object.get("summary").?.object.get("truncate_reason").?.string);
            try std.testing.expect(truncated.value.object.get("omitted").?.array.items.len >= 1);
            try std.testing.expectEqualStrings("max_nodes", truncated.value.object.get("omitted").?.array.items[0].object.get("reason").?.string);
        }

        fn renderPersistentQueryOutputAllocationFailure(allocator: std.mem.Allocator) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "render task status" });
            try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.status_property, "open");

            const query_ast = try ql.parser.parse(std.testing.allocator, "MATCH (t:Task) RETURN t.status LIMIT 1");
            defer ql.ast.freeQuery(std.testing.allocator, query_ast);
            var logical = try ql.planner.plan(std.testing.allocator, query_ast);
            defer logical.deinit(std.testing.allocator);
            var physical = try ql.optimizer.optimize(std.testing.allocator, logical);
            defer physical.deinit(std.testing.allocator);

            const output = try renderPersistentQueryOutput(allocator, std.testing.io, store, physical, false, .{});
            defer allocator.free(output);
            try std.testing.expectEqualStrings("open\n", output);
        }

        test "persistent query output render rolls back allocation failures" {
            try std.testing.checkAllAllocationFailures(std.testing.allocator, renderPersistentQueryOutputAllocationFailure, .{});
        }
    };
}
