/// Task packet/frontier/ancestry traversal, lifecycle snapshots and bounded task metrics.
pub fn TaskReadMetricsDataPlane(comptime Ops: type) type {
    return struct {
        const ParsedTaskFrontierArgs = Ops.ParsedTaskFrontierArgsValue;
        const ParsedTaskPacketArgs = Ops.ParsedTaskPacketArgsValue;
        const QueryOutputWriter = Ops.QueryOutputWriterValue;
        const TaskHierarchyEdgeCollection = Ops.TaskHierarchyEdgeCollectionValue;
        const TaskMutationArguments = Ops.TaskMutationArgumentsValue;
        const agent = Ops.agentValue;
        const buildTaskPacketSubgraph = Ops.buildTaskPacketSubgraphValue;
        const collectVisibleTaskHierarchyEdgeRecordsLimited = Ops.collectVisibleTaskHierarchyEdgeRecordsLimitedValue;
        const core = Ops.coreValue;
        const edgeRecordIdLessThan = Ops.edgeRecordIdLessThanValue;
        const exerciseTaskEventMetadataAllocationFailure = Ops.exerciseTaskEventMetadataAllocationFailureValue;
        const graph = Ops.graphValue;
        const query = Ops.queryValue;
        const readVisibleEdgeRecordsByNode = Ops.readVisibleEdgeRecordsByNodeValue;
        const readVisibleEdgeRecordsByNodeLimited = Ops.readVisibleEdgeRecordsByNodeLimitedValue;
        const readVisibleTaskHierarchyEdgeRecords = Ops.readVisibleTaskHierarchyEdgeRecordsValue;
        const readVisibleTaskPacketChildEdgeRecords = Ops.readVisibleTaskPacketChildEdgeRecordsValue;
        const renderNodeObjectJson = Ops.renderNodeObjectJsonValue;
        const renderSubgraphEdgeJson = Ops.renderSubgraphEdgeJsonValue;
        const renderSubgraphOmittedJson = Ops.renderSubgraphOmittedJsonValue;
        const renderTextContextSizeAggregateJson = Ops.renderTextContextSizeAggregateJsonValue;
        const run = Ops.runValue;
        const schema = Ops.schemaValue;
        const std = Ops.stdValue;
        const storage = Ops.storageValue;
        const subgraphUsedEdgeRefs = Ops.subgraphUsedEdgeRefsValue;
        const task = Ops.taskValue;
        const taskEdgeLookaheadLimit = Ops.taskEdgeLookaheadLimitValue;
        const taskPacketJsonBudget = Ops.taskPacketJsonBudgetValue;
        const task_hierarchy = Ops.task_hierarchyValue;
        const u128ToU64 = Ops.u128ToU64Value;
        const version = Ops.versionValue;
        const writeEscapedText = Ops.writeEscapedTextValue;
        const writeJsonBoolField = Ops.writeJsonBoolFieldValue;
        const writeJsonFieldPrefix = Ops.writeJsonFieldPrefixValue;
        const writeJsonNullableStringField = Ops.writeJsonNullableStringFieldValue;
        const writeJsonNumberField = Ops.writeJsonNumberFieldValue;
        const writeJsonObjectEnd = Ops.writeJsonObjectEndValue;
        const writeJsonObjectStart = Ops.writeJsonObjectStartValue;
        const writeJsonStringField = Ops.writeJsonStringFieldValue;
        const writeNodeKindName = Ops.writeNodeKindNameValue;
        const writeRelKindName = Ops.writeRelKindNameValue;
        const writeSearchContinuation = Ops.writeSearchContinuationValue;

        pub fn renderTaskPacketJsonOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            task_id: core.NodeId,
            args: ParsedTaskPacketArgs,
        ) ![]u8 {
            var task_node = (try store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
            defer task_node.deinit(allocator);
            if (task_node.kind != .task) return core.Error.InvalidId;

            const now_ns = try u128ToU64(persistentNowNs(store.io));
            const lifecycle = try task.statusForStoredNode(allocator, store, task_node, now_ns);
            const state: ?task.ReadyState = if (lifecycle.isTerminal()) null else try task.readyStateWithPersistentStoreAt(allocator, store, task_id, now_ns);
            const budget = taskPacketJsonBudget(args);
            var result = try buildTaskPacketSubgraph(allocator, store, task_id, args, budget);
            defer result.deinit(allocator);

            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);
            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();

            try writeJsonObjectStart(&out);
            var first = true;
            try writeJsonStringField(&out, "schema_version", "tinykg-agent-retrieval-v1", &first);
            try writeJsonStringField(&out, "mode", "task-packet", &first);
            try writeJsonFieldPrefix(&out, "query", &first);
            try out.writeAll("{");
            var query_first = true;
            try writeJsonNumberField(&out, "task_id", task_id.toInt(), &query_first);
            try writeJsonNumberField(&out, "limit", args.limit, &query_first);
            try writeJsonStringField(&out, "status", @tagName(lifecycle), &query_first);
            try writeJsonNullableStringField(&out, "readiness", if (state) |value| @tagName(value) else null, &query_first);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "budget", &first);
            try out.writeAll("{");
            var budget_first = true;
            try writeJsonNumberField(&out, "max_nodes", budget.max_nodes, &budget_first);
            try writeJsonNumberField(&out, "max_edges", budget.max_edges, &budget_first);
            try writeJsonNumberField(&out, "max_chars", budget.max_chars, &budget_first);
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
            try writeJsonNumberField(&out, "edges_scanned", result.scanned_edges, &summary_first);
            try writeJsonFieldPrefix(&out, "context_size", &summary_first);
            try renderTextContextSizeAggregateJson(&out, result.used_bytes, result.used_chars, result.used_lines);
            try out.writeAll("}");

            try writeJsonFieldPrefix(&out, "root", &first);
            try renderNodeObjectJson(&out, allocator, store, task_node, false);

            try writeJsonFieldPrefix(&out, "nodes", &first);
            try out.writeAll("[");
            for (result.node_ids.items, 0..) |node_id, index| {
                if (index != 0) try out.writeAll(",");
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                try renderNodeObjectJson(&out, allocator, store, node, false);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "edges", &first);
            try out.writeAll("[");
            for (result.edges.items, 0..) |edge, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphEdgeJson(&out, allocator, store, edge);
            }
            try out.writeAll("]");

            try writeJsonFieldPrefix(&out, "backrefs", &first);
            try out.writeAll("[");
            for (result.backrefs.items, 0..) |edge, index| {
                if (index != 0) try out.writeAll(",");
                try renderSubgraphEdgeJson(&out, allocator, store, edge);
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
                try writeJsonStringField(&out, "action", "task-packet", &cont_first);
                try writeJsonNumberField(&out, "node_id", task_id.toInt(), &cont_first);
                try writeJsonStringField(&out, "args", "raise --limit/--max-nodes/--max-edges/--max-chars", &cont_first);
                try writeJsonStringField(&out, "reason", "task packet was truncated", &cont_first);
                try out.writeAll("}");
                continuation_first = false;
            }
            if (!continuation_first) try out.writeAll(",");
            try writeSearchContinuation(&out, "neighbors", task_id, "walk local graph around this task if task packet is insufficient");
            try out.writeAll("]");

            try writeJsonObjectEnd(&out);
            return out.buffer.toOwnedSlice(allocator);
        }

        /// task-frontier 深遍历预算(遍历面防爆;readiness 单查另有 QueryBudget)。
        /// 生命周期 sidecar 在遍历前只做一次定向快照；每节点仍会建立 readiness
        /// cursor/view，因此 4096 上限依旧是明确的 CPU/IO 防线。
        const frontier_max_visited_nodes: usize = 4096;
        const frontier_max_status_snapshot_nodes: usize = frontier_max_visited_nodes * 4;
        const frontier_max_depth: usize = 64;
        const frontier_path_segment_max_bytes: usize = 32;
        /// task-claim 默认租约(读侧过期:frontier 判定时 expires<=now 即视为无人认领,无后台任务)。
        pub const task_claim_default_ttl_s: u64 = 7200;

        /// 行内 claim 状态(owned holder;active = 有 holder 且租约未过期)。
        const FrontierClaim = struct {
            holder: ?[]const u8 = null,
            active: bool = false,
            owned: bool = false,

            fn deinit(self: *const FrontierClaim, allocator: std.mem.Allocator) void {
                if (self.owned) {
                    if (self.holder) |h| allocator.free(h);
                }
            }
        };

        fn frontierReadClaim(
            allocator: std.mem.Allocator,
            store: storage.Store,
            status_snapshot: *const task.StatusSnapshot,
            node_id: core.NodeId,
            now_ns: u64,
        ) !FrontierClaim {
            if (status_snapshot.covers(node_id)) {
                const claim = status_snapshot.claim(node_id);
                return .{ .holder = claim.holder, .active = claim.active(now_ns) };
            }
            const holder = try store.getNodeStringProperty(allocator, node_id, task.claimed_by_property);
            if (holder == null or holder.?.len == 0) {
                if (holder) |value| allocator.free(value);
                return .{};
            }
            errdefer allocator.free(holder.?);
            const expires = (try store.getUintProperty(allocator, .{ .node = node_id }, task.claim_expires_ns_property)) orelse 0;
            return .{ .holder = holder.?, .active = expires > now_ns, .owned = true };
        }

        fn exerciseFrontierReadClaimAllocationFailure(
            allocator: std.mem.Allocator,
            store: storage.Store,
            snapshot: *const task.StatusSnapshot,
        ) !void {
            const claim = try frontierReadClaim(allocator, store, snapshot, .fromInt(1), 0);
            defer claim.deinit(allocator);
            try std.testing.expectEqualStrings("allocation-test-agent", claim.holder.?);
            try std.testing.expect(claim.active);
        }

        fn frontierStatusForNode(walk: *const FrontierWalk, node: storage.StoredNode) !task.Status {
            if (walk.status_snapshot.covers(node.id)) return try walk.status_snapshot.statusForStoredNode(node, walk.now_ns);
            return try task.statusForStoredNode(walk.allocator, walk.store, node, walk.now_ns);
        }

        /// child_task/related_task 行的 claim 过滤(branch 行不过滤,结构上下文恒发射)。
        const FrontierClaimFilter = struct {
            mine: ?[]const u8 = null,
            unclaimed: bool = false,

            fn keeps(self: FrontierClaimFilter, claim: FrontierClaim) bool {
                if (self.mine) |agent_name| {
                    return claim.active and std.mem.eql(u8, claim.holder.?, agent_name);
                }
                if (self.unclaimed) return !claim.active;
                return true;
            }
        };

        const FrontierChildRef = struct {
            edge_id: u64,
            rel: core.RelKind,
            node_id: core.NodeId,
            status: task.Status,
        };

        /// task-frontier 深遍历状态。语义(v2):frontier = 子树的**可执行叶子集**。
        /// - child_task = 开放叶子(无开放 task 子节点),唯一计入 --limit 的可执行行;
        /// - branch_task = 开放复合节点(有开放子节点,不可直接执行,靠子树闭合而闭合),
        ///   供看板重建结构("不在 frontier = 已完成"的推断因此对复合节点也成立);
        /// - readiness 为**有效就绪度**:自身与祖先链取第一个非 ready(父被阻,子不虚报 ready)。
        const FrontierWalk = struct {
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            status_snapshot: *const task.StatusSnapshot,
            out: *QueryOutputWriter,
            limit: usize,
            now_ns: u64,
            claim_filter: FrontierClaimFilter = .{},
            emitted: usize = 0,
            leaf_truncated: bool = false,
            budget_truncated: bool = false,
            depth_truncated: bool = false,
            visited: std.AutoHashMap(u64, void),
            aggregate_readiness: std.AutoHashMap(u64, task.ReadyState),
            path: std.ArrayList(u8) = .empty,

            fn stopped(self: *const FrontierWalk) bool {
                return self.leaf_truncated or self.budget_truncated;
            }

            fn deinit(self: *FrontierWalk) void {
                self.aggregate_readiness.deinit();
                self.visited.deinit();
                self.path.deinit(self.allocator);
            }
        };

        fn frontierReadinessRank(state: task.ReadyState) u8 {
            return switch (state) {
                .ready => 0,
                .missing_dependencies => 1,
                .blocked => 2,
            };
        }

        fn stricterFrontierReadiness(lhs: task.ReadyState, rhs: task.ReadyState) task.ReadyState {
            return if (frontierReadinessRank(lhs) >= frontierReadinessRank(rhs)) lhs else rhs;
        }

        /// Precompute effective readiness before emitting rows. A contains graph is a
        /// DAG, not necessarily a tree: a shared descendant must inherit the strictest
        /// state from every root-to-node path. Emitting during the first DFS would make
        /// the answer depend on edge order because a later, blocked parent could no
        /// longer revise an already-written row. Each node can escalate at most twice
        /// (ready -> missing -> blocked), so this fixed-point walk stays bounded.
        fn aggregateFrontierReadiness(
            walk: *FrontierWalk,
            node_id: core.NodeId,
            depth: usize,
            inherited: task.ReadyState,
        ) !void {
            if (depth > frontier_max_depth) return;

            var node = (try walk.node_view.readNodeById(walk.allocator, node_id)) orelse return error.InvalidRecord;
            defer node.deinit(walk.allocator);
            if (node.kind != .task) return;
            const lifecycle = try frontierStatusForNode(walk, node);
            if (lifecycle == .completed) return;

            const own: task.ReadyState = if (lifecycle == .failed)
                .blocked
            else
                try task.readyStateWithPersistentStoreSnapshotAt(walk.allocator, walk.store, node_id, walk.now_ns, walk.status_snapshot);

            var children: std.ArrayList(FrontierChildRef) = .empty;
            defer children.deinit(walk.allocator);
            try frontierCollectTaskChildren(walk, node_id, &children);
            var has_failed_child = false;
            for (children.items) |child| {
                if (child.status == .failed) {
                    has_failed_child = true;
                    break;
                }
            }
            var effective = stricterFrontierReadiness(inherited, own);
            if (lifecycle == .failed or has_failed_child) effective = .blocked;

            const existing = walk.aggregate_readiness.get(node_id.toInt());
            if (existing) |previous| {
                effective = stricterFrontierReadiness(previous, effective);
                if (effective == previous) return;
            } else if (walk.aggregate_readiness.count() >= frontier_max_visited_nodes - 1) {
                // The emitting walk has the same DFS order and includes the root in
                // its node budget. Nodes beyond this point are never emitted.
                return;
            }
            try walk.aggregate_readiness.put(node_id.toInt(), effective);
            for (children.items) |child| {
                try aggregateFrontierReadiness(walk, child.node_id, depth + 1, effective);
            }
        }

        fn frontierCollectTaskChildren(
            walk: *FrontierWalk,
            parent_id: core.NodeId,
            children: *std.ArrayList(FrontierChildRef),
        ) !void {
            var records = try readVisibleTaskHierarchyEdgeRecords(walk.allocator, walk.store, .src, parent_id);
            defer records.deinit(walk.allocator);
            for (records.items) |record| {
                const child_id = core.NodeId.fromInt(record.dst);
                var child = (try walk.node_view.readNodeById(walk.allocator, child_id)) orelse return error.InvalidRecord;
                defer child.deinit(walk.allocator);
                if (child.kind != .task) continue;
                const lifecycle = try frontierStatusForNode(walk, child);
                if (lifecycle == .completed) continue;
                try children.append(walk.allocator, .{
                    .edge_id = record.edge_id,
                    .rel = @enumFromInt(record.rel),
                    .node_id = child_id,
                    .status = lifecycle,
                });
            }
        }

        fn frontierWalkTask(
            walk: *FrontierWalk,
            edge_id: u64,
            rel: core.RelKind,
            node_id: core.NodeId,
            depth: usize,
            inherited: task.ReadyState,
        ) !void {
            if (walk.stopped()) return;
            if (depth > frontier_max_depth) {
                walk.depth_truncated = true;
                return;
            }
            // 菱形防重:同节点只发射一次；readiness 已在前置固定点遍历中聚合
            // 全部 root-to-node 路径，这里只让第一条路径决定展示用 breadcrumb。
            const gop = try walk.visited.getOrPut(node_id.toInt());
            if (gop.found_existing) return;
            if (walk.visited.count() > frontier_max_visited_nodes) {
                walk.budget_truncated = true;
                return;
            }
            var node = (try walk.node_view.readNodeById(walk.allocator, node_id)) orelse return error.InvalidRecord;
            defer node.deinit(walk.allocator);
            if (node.kind != .task) return;
            const lifecycle = try frontierStatusForNode(walk, node);
            if (lifecycle == .completed) return;

            var children: std.ArrayList(FrontierChildRef) = .empty;
            defer children.deinit(walk.allocator);
            try frontierCollectTaskChildren(walk, node_id, &children);
            const effective = walk.aggregate_readiness.get(node_id.toInt()) orelse fallback: {
                const own: task.ReadyState = if (lifecycle == .failed)
                    .blocked
                else
                    try task.readyStateWithPersistentStoreSnapshotAt(walk.allocator, walk.store, node_id, walk.now_ns, walk.status_snapshot);
                var path_effective = stricterFrontierReadiness(inherited, own);
                for (children.items) |child| {
                    if (child.status == .failed) {
                        path_effective = .blocked;
                        break;
                    }
                }
                break :fallback path_effective;
            };

            if (children.items.len == 0) {
                const claim = try frontierReadClaim(walk.allocator, walk.store, walk.status_snapshot, node_id, walk.now_ns);
                defer claim.deinit(walk.allocator);
                if (lifecycle == .failed) {
                    try writeTaskFrontierRow(walk.out, "failed_task", edge_id, rel, node_id.toInt(), lifecycle, effective, depth, claim, walk.path.items, node.text);
                    return;
                }
                if (!walk.claim_filter.keeps(claim)) return;
                if (walk.emitted >= walk.limit) {
                    walk.leaf_truncated = true;
                    return;
                }
                try writeTaskFrontierRow(walk.out, "child_task", edge_id, rel, node_id.toInt(), lifecycle, effective, depth, claim, walk.path.items, node.text);
                walk.emitted += 1;
                return;
            }

            const branch_claim = try frontierReadClaim(walk.allocator, walk.store, walk.status_snapshot, node_id, walk.now_ns);
            defer branch_claim.deinit(walk.allocator);
            try writeTaskFrontierRow(walk.out, if (lifecycle == .failed) "failed_task" else "branch_task", edge_id, rel, node_id.toInt(), lifecycle, effective, depth, branch_claim, walk.path.items, node.text);
            const path_len_before = walk.path.items.len;
            if (walk.path.items.len > 0) try walk.path.appendSlice(walk.allocator, " › ");
            try appendFirstLineTruncated(&walk.path, walk.allocator, node.text, frontier_path_segment_max_bytes);
            defer walk.path.shrinkRetainingCapacity(path_len_before);
            for (children.items) |child| {
                try frontierWalkTask(walk, child.edge_id, child.rel, child.node_id, depth + 1, effective);
                if (walk.stopped()) return;
            }
        }

        fn writeTaskFrontierRow(
            out: *QueryOutputWriter,
            role: []const u8,
            edge_id: u64,
            rel: core.RelKind,
            node_id: u64,
            status: task.Status,
            readiness: task.ReadyState,
            depth: usize,
            claim: FrontierClaim,
            path_raw: []const u8,
            text: []const u8,
        ) !void {
            try out.print("{s}\t{}\t", .{ role, edge_id });
            try writeRelKindName(out, rel);
            try out.print("\t{}\tstatus={s}\treadiness={s}\tdepth={}\tclaimed_by=", .{ node_id, @tagName(status), @tagName(readiness), depth });
            if (claim.active) {
                try writeEscapedText(out, claim.holder.?);
            } else {
                try out.writeAll("-");
            }
            try out.writeAll("\tpath=");
            if (path_raw.len == 0) {
                try out.writeAll("-");
            } else {
                try writeEscapedText(out, path_raw);
            }
            try out.writeAll("\t");
            try writeEscapedText(out, text);
            try out.writeAll("\n");
        }

        /// 取 text 首行,UTF-8 安全截断到 max_bytes(超出加 …)。面包屑段用。
        fn appendFirstLineTruncated(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) !void {
            const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
            const line = std.mem.trim(u8, text[0..line_end], " \t\r");
            if (line.len <= max_bytes) {
                try list.appendSlice(allocator, line);
                return;
            }
            var end: usize = 0;
            while (end < line.len) {
                const width = std.unicode.utf8ByteSequenceLength(line[end]) catch 1;
                if (end + width > max_bytes) break;
                end += width;
            }
            try list.appendSlice(allocator, line[0..end]);
            try list.appendSlice(allocator, "…");
        }

        fn collectFrontierStatusSnapshotNodeIds(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: *storage.Store.NodeRecordView,
            root_id: core.NodeId,
        ) !std.ArrayList(core.NodeId) {
            var ids = std.ArrayList(core.NodeId).empty;
            errdefer ids.deinit(allocator);
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();
            try seen.put(root_id.toInt(), {});
            try ids.append(allocator, root_id);

            var cursor: usize = 0;
            while (cursor < ids.items.len and ids.items.len < frontier_max_visited_nodes) : (cursor += 1) {
                var records = try readVisibleTaskHierarchyEdgeRecords(allocator, store, .src, ids.items[cursor]);
                defer records.deinit(allocator);
                for (records.items) |record| {
                    const child_id = core.NodeId.fromInt(record.dst);
                    const entry = try seen.getOrPut(child_id.toInt());
                    if (entry.found_existing) continue;
                    var child = (try node_view.readNodeById(allocator, child_id)) orelse return error.InvalidRecord;
                    defer child.deinit(allocator);
                    if (child.kind != .task) continue;
                    try ids.append(allocator, child_id);
                    if (ids.items.len >= frontier_max_visited_nodes) break;
                }
            }

            if (ids.items.len < frontier_max_visited_nodes) {
                var related = try readVisibleEdgeRecordsByNode(allocator, store, .dst, root_id, .related_to);
                defer related.deinit(allocator);
                for (related.items) |record| {
                    const related_id = core.NodeId.fromInt(record.src);
                    const entry = try seen.getOrPut(related_id.toInt());
                    if (entry.found_existing) continue;
                    var node = (try node_view.readNodeById(allocator, related_id)) orelse return error.InvalidRecord;
                    defer node.deinit(allocator);
                    if (node.kind != .task) continue;
                    try ids.append(allocator, related_id);
                    if (ids.items.len >= frontier_max_visited_nodes) break;
                }
            }
            // Readiness consults immediate scheduler endpoints that may live outside
            // the contains tree (shared prerequisites, blockers and predecessors).
            // Include those owners in the same lifecycle snapshot so a frontier walk
            // validates the property delta once instead of once per external task.
            // Do not recursively expand endpoints: readiness itself is one-hop.
            const readiness_owner_count = ids.items.len;
            var owner_index: usize = 0;
            while (owner_index < readiness_owner_count and ids.items.len < frontier_max_status_snapshot_nodes) : (owner_index += 1) {
                try appendFrontierReadinessEndpointIds(allocator, store, &ids, &seen, ids.items[owner_index], .src, .depends_on, false);
                try appendFrontierReadinessEndpointIds(allocator, store, &ids, &seen, ids.items[owner_index], .dst, .blocks, true);
                try appendFrontierReadinessEndpointIds(allocator, store, &ids, &seen, ids.items[owner_index], .dst, .precedes, true);
            }
            return ids;
        }

        fn appendFrontierReadinessEndpointIds(
            allocator: std.mem.Allocator,
            store: storage.Store,
            ids: *std.ArrayList(core.NodeId),
            seen: *std.AutoHashMap(u64, void),
            owner_id: core.NodeId,
            order: storage.EdgeIndexOrder,
            rel: core.RelKind,
            endpoint_is_src: bool,
        ) !void {
            if (ids.items.len >= frontier_max_status_snapshot_nodes) return;
            var records = try readVisibleEdgeRecordsByNode(allocator, store, order, owner_id, rel);
            defer records.deinit(allocator);
            for (records.items) |record| {
                const endpoint_id = core.NodeId.fromInt(if (endpoint_is_src) record.src else record.dst);
                const entry = try seen.getOrPut(endpoint_id.toInt());
                if (entry.found_existing) continue;
                try ids.append(allocator, endpoint_id);
                if (ids.items.len >= frontier_max_status_snapshot_nodes) return;
            }
        }

        pub fn renderTaskFrontierOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            root_id: core.NodeId,
            frontier_arg: ParsedTaskFrontierArgs,
            now_ns: u64,
        ) ![]u8 {
            const limit = frontier_arg.limit;
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var node_id_view = try store.openNodeByIdIndexView();
            defer node_id_view.deinit();
            if (!try node_id_view.nodeExists(root_id)) return core.Error.NotFound;

            try out.print("task_frontier\t{}\tlimit={}\tmode=deep\n", .{ root_id.toInt(), limit });

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var snapshot_node_ids = try collectFrontierStatusSnapshotNodeIds(allocator, store, &node_view, root_id);
            defer snapshot_node_ids.deinit(allocator);
            var status_snapshot = try task.StatusSnapshot.initForNodeIds(allocator, store, snapshot_node_ids.items);
            defer status_snapshot.deinit();

            var root = (try node_view.readNodeById(allocator, root_id)) orelse return error.InvalidRecord;
            defer root.deinit(allocator);
            if (root.kind != .task) return core.Error.InvalidId;
            const root_lifecycle = try status_snapshot.statusForStoredNode(root, now_ns);
            if (root_lifecycle == .completed) return out.buffer.toOwnedSlice(allocator);

            var walk = FrontierWalk{
                .allocator = allocator,
                .store = store,
                .node_view = &node_view,
                .status_snapshot = &status_snapshot,
                .out = &out,
                .limit = limit,
                .now_ns = now_ns,
                .claim_filter = .{ .mine = frontier_arg.mine, .unclaimed = frontier_arg.unclaimed },
                .visited = std.AutoHashMap(u64, void).init(allocator),
                .aggregate_readiness = std.AutoHashMap(u64, task.ReadyState).init(allocator),
            };
            defer walk.deinit();
            try walk.visited.put(root_id.toInt(), {});

            var root_children: std.ArrayList(FrontierChildRef) = .empty;
            defer root_children.deinit(allocator);
            try frontierCollectTaskChildren(&walk, root_id, &root_children);
            var root_has_failed_child = false;
            for (root_children.items) |child| {
                if (child.status == .failed) {
                    root_has_failed_child = true;
                    break;
                }
            }
            const root_effective: task.ReadyState = if (root_lifecycle == .failed or root_has_failed_child)
                .blocked
            else
                try task.readyStateWithPersistentStoreSnapshotAt(allocator, store, root_id, now_ns, &status_snapshot);
            for (root_children.items) |child| {
                try aggregateFrontierReadiness(&walk, child.node_id, 1, root_effective);
            }
            for (root_children.items) |child| {
                try frontierWalkTask(&walk, child.edge_id, child.rel, child.node_id, 1, root_effective);
                if (walk.stopped()) break;
            }

            if (walk.leaf_truncated) try out.print("child_task_truncated\tlimit={}\n", .{limit});
            if (walk.budget_truncated) try out.writeAll("frontier_truncated\tbudget=nodes\n");
            if (walk.depth_truncated) try out.writeAll("frontier_truncated\tbudget=depth\n");

            if (!walk.stopped() and walk.emitted < limit) {
                try writeTaskFrontierRelatedRows(&walk, root_id);
            }

            return out.buffer.toOwnedSlice(allocator);
        }

        fn writeTaskFrontierRelatedRows(walk: *FrontierWalk, owner_id: core.NodeId) !void {
            var truncated = false;
            var records = try readVisibleEdgeRecordsByNode(walk.allocator, walk.store, .dst, owner_id, .related_to);
            defer records.deinit(walk.allocator);
            for (records.items) |record| {
                const node_id = core.NodeId.fromInt(record.src);
                var node = (try walk.node_view.readNodeById(walk.allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(walk.allocator);
                if (node.kind != .task) continue;
                const lifecycle = try frontierStatusForNode(walk, node);
                if (lifecycle == .completed) continue;
                const claim = try frontierReadClaim(walk.allocator, walk.store, walk.status_snapshot, node_id, walk.now_ns);
                defer claim.deinit(walk.allocator);
                if (lifecycle != .failed and !walk.claim_filter.keeps(claim)) continue;
                if (walk.emitted >= walk.limit) {
                    truncated = true;
                    break;
                }
                const state: task.ReadyState = if (lifecycle == .failed)
                    .blocked
                else
                    try task.readyStateWithPersistentStoreSnapshotAt(walk.allocator, walk.store, node_id, walk.now_ns, walk.status_snapshot);
                try writeTaskFrontierRow(walk.out, if (lifecycle == .failed) "related_failed_task" else "related_task", record.edge_id, @enumFromInt(record.rel), node.id.toInt(), lifecycle, state, 1, claim, "", node.text);
                walk.emitted += 1;
            }
            if (truncated) try walk.out.print("related_task_truncated\tlimit={}\n", .{walk.limit});
        }

        pub fn renderTaskAncestryOutput(
            allocator: std.mem.Allocator,
            store: storage.Store,
            task_id: core.NodeId,
            depth: usize,
            limit: usize,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var task_node = (try store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
            defer task_node.deinit(allocator);
            if (task_node.kind != .task) return core.Error.InvalidId;

            const lifecycle = try task.statusForStoredNode(allocator, store, task_node, try u128ToU64(persistentNowNs(store.io)));
            try out.print("task_ancestry\t{}\tstatus={s}\tdepth={}\tlimit={}\n", .{ task_id.toInt(), @tagName(lifecycle), depth, limit });
            try writeTaskPacketNodeRow(&out, "focus", task_node.id, task_node.kind, task_node.text);

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var current = std.ArrayList(core.NodeId).empty;
            defer current.deinit(allocator);
            var next = std.ArrayList(core.NodeId).empty;
            defer next.deinit(allocator);
            try current.append(allocator, task_id);

            var emitted: usize = 0;
            var level: usize = 0;
            while (level < depth and current.items.len > 0) : (level += 1) {
                next.clearRetainingCapacity();
                for (current.items) |node_id| {
                    if (try writeTaskAncestryAnchorRows(allocator, store, &node_view, &out, "goal_anchor_out", .src, node_id, level, limit, &emitted)) return out.buffer.toOwnedSlice(allocator);
                    if (try writeTaskAncestryAnchorRows(allocator, store, &node_view, &out, "goal_anchor_in", .dst, node_id, level, limit, &emitted)) return out.buffer.toOwnedSlice(allocator);
                    if (try writeTaskAncestryParentRows(allocator, store, &node_view, &out, node_id, level, limit, &emitted, &next)) return out.buffer.toOwnedSlice(allocator);
                }
                current.clearRetainingCapacity();
                try current.appendSlice(allocator, next.items);
            }

            return out.buffer.toOwnedSlice(allocator);
        }

        fn writeTaskAncestryAnchorRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            out: *QueryOutputWriter,
            role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            level: usize,
            limit: usize,
            emitted: *usize,
        ) !bool {
            var records = try readVisibleEdgeRecordsByNode(allocator, store, order, owner_id, .related_to);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (emitted.* >= limit) {
                    try out.print("{s}_truncated\tlevel={}\tlimit={}\n", .{ role, level, limit });
                    return true;
                }
                const node_id = switch (order) {
                    .src => core.NodeId.fromInt(record.dst),
                    .dst => core.NodeId.fromInt(record.src),
                    .id => return core.Error.Unsupported,
                };
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                if (try nodeHasTaskEventSchema(allocator, store, node.id)) continue;
                try out.print("{s}\tlevel={}\t{}\t", .{ role, level, record.edge_id });
                try writeRelKindName(out, @enumFromInt(record.rel));
                try out.print("\t{}\t", .{node.id.toInt()});
                try writeNodeKindName(out, node.kind);
                try out.writeAll("\t");
                try writeEscapedText(out, node.text);
                try out.writeAll("\n");
                emitted.* += 1;
            }
            return false;
        }

        fn writeTaskAncestryParentRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            out: *QueryOutputWriter,
            owner_id: core.NodeId,
            level: usize,
            limit: usize,
            emitted: *usize,
            next: *std.ArrayList(core.NodeId),
        ) !bool {
            var records = try readVisibleTaskHierarchyEdgeRecords(allocator, store, .dst, owner_id);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (emitted.* >= limit) {
                    try out.print("parent_in_truncated\tlevel={}\tlimit={}\n", .{ level, limit });
                    return true;
                }
                const node_id = core.NodeId.fromInt(record.src);
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                try out.print("parent_in\tlevel={}\t{}\t", .{ level, record.edge_id });
                try writeRelKindName(out, @enumFromInt(record.rel));
                try out.print("\t{}\t", .{node.id.toInt()});
                try writeNodeKindName(out, node.kind);
                try out.writeAll("\t");
                try writeEscapedText(out, node.text);
                try out.writeAll("\n");
                emitted.* += 1;
                try next.append(allocator, node_id);
            }
            return false;
        }

        const TaskMetrics = struct {
            scanned_edges: usize = 0,
            nested_event_edges: usize = 0,
            truncated: bool = false,
            open_tasks: usize = 0,
            claimed_tasks: usize = 0,
            completed_tasks: usize = 0,
            failed_tasks: usize = 0,
            legacy_closed_verifications: usize = 0,
            legacy_closed_fixes: usize = 0,
            other_nodes: usize = 0,
            ready_tasks: usize = 0,
            blocked_tasks: usize = 0,
            missing_dependency_tasks: usize = 0,
            dependency_edges: usize = 0,
            blocker_edges: usize = 0,
            verification_edges: usize = 0,
            rework_error_events: usize = 0,
            task_write_attempt_events: usize = 0,
            task_write_error_events: usize = 0,
            dependency_edge_created_events: usize = 0,
            dependency_edge_correction_events: usize = 0,
            prompt_adherence_ok_events: usize = 0,
            prompt_adherence_miss_events: usize = 0,
            stale_open_task_age_samples: usize = 0,
            stale_open_task_age_min_ns: u128 = 0,
            stale_open_task_age_max_ns: u128 = 0,
            completion_latency_samples: usize = 0,
            completion_latency_min_ns: u128 = 0,
            completion_latency_max_ns: u128 = 0,

            fn recordStaleOpenTaskAge(self: *TaskMetrics, recorded_ns: u128, now_ns: u128) void {
                const age_ns = if (now_ns >= recorded_ns) now_ns - recorded_ns else 0;
                if (self.stale_open_task_age_samples == 0 or age_ns < self.stale_open_task_age_min_ns) {
                    self.stale_open_task_age_min_ns = age_ns;
                }
                if (age_ns > self.stale_open_task_age_max_ns) {
                    self.stale_open_task_age_max_ns = age_ns;
                }
                self.stale_open_task_age_samples += 1;
            }

            fn recordCompletionLatency(self: *TaskMetrics, created_ns: u128, completed_ns: u128) void {
                const latency_ns = if (completed_ns >= created_ns) completed_ns - created_ns else 0;
                if (self.completion_latency_samples == 0 or latency_ns < self.completion_latency_min_ns) {
                    self.completion_latency_min_ns = latency_ns;
                }
                if (latency_ns > self.completion_latency_max_ns) {
                    self.completion_latency_max_ns = latency_ns;
                }
                self.completion_latency_samples += 1;
            }
        };

        const task_metric_detail_budget_multiplier: usize = 16;

        const TaskMetricDetailBudget = struct {
            limit: usize,
            scanned_edges: usize = 0,
            truncated: bool = false,

            fn init(row_limit: usize) TaskMetricDetailBudget {
                return .{
                    .limit = std.math.mul(usize, row_limit, task_metric_detail_budget_multiplier) catch std.math.maxInt(usize),
                };
            }

            fn charge(self: *TaskMetricDetailBudget, metrics: *TaskMetrics) bool {
                if (self.scanned_edges >= self.limit) {
                    self.truncated = true;
                    metrics.truncated = true;
                    return false;
                }
                self.scanned_edges += 1;
                return true;
            }

            fn remaining(self: TaskMetricDetailBudget) usize {
                return self.limit - self.scanned_edges;
            }

            fn absorb(self: *TaskMetricDetailBudget, scanned_edges: usize) void {
                std.debug.assert(scanned_edges <= self.remaining());
                self.scanned_edges += scanned_edges;
            }

            fn markTruncated(self: *TaskMetricDetailBudget, metrics: *TaskMetrics) void {
                self.truncated = true;
                metrics.truncated = true;
            }
        };

        const PendingTaskMetricEvent = struct {
            node_id: core.NodeId,
            skip_root_id: ?core.NodeId,
            metrics: *TaskMetrics,
        };

        const TaskMetricEventSnapshot = struct {
            allocator: std.mem.Allocator,
            properties: storage.PropertySnapshot,
            by_node: std.AutoHashMap(u64, Fields),

            const Fields = struct {
                task_root_id: ?u64 = null,
                event_type: ?[]const u8 = null,
                dependency_relation: ?[]const u8 = null,
            };

            fn init(allocator: std.mem.Allocator, store: storage.Store, node_ids: []const core.NodeId) !TaskMetricEventSnapshot {
                var properties = try store.loadNodePropertySnapshotForNodeIds(allocator, node_ids, &.{
                    "task_root_id",
                    "task_event_type",
                    "dependency_relation",
                });
                errdefer properties.deinit(allocator);
                var by_node = std.AutoHashMap(u64, Fields).init(allocator);
                errdefer by_node.deinit();

                const root_hash = storage.propertyKeyHashForLookup("task_root_id");
                const event_hash = storage.propertyKeyHashForLookup("task_event_type");
                const relation_hash = storage.propertyKeyHashForLookup("dependency_relation");
                for (properties.entries) |entry| {
                    const node_id = switch (entry.owner) {
                        .node => |id| id.toInt(),
                        .edge => return error.InvalidTaskMetricEvent,
                    };
                    const slot = try by_node.getOrPut(node_id);
                    if (!slot.found_existing) slot.value_ptr.* = .{};
                    if (entry.key_hash == root_hash) {
                        if (entry.value_kind != .uint) return error.InvalidTaskMetricEvent;
                        slot.value_ptr.task_root_id = entry.uint_value;
                    } else if (entry.key_hash == event_hash) {
                        if (entry.value_kind != .string) return error.InvalidTaskMetricEvent;
                        slot.value_ptr.event_type = entry.string_value;
                    } else if (entry.key_hash == relation_hash) {
                        if (entry.value_kind != .string) return error.InvalidTaskMetricEvent;
                        slot.value_ptr.dependency_relation = entry.string_value;
                    }
                }
                return .{ .allocator = allocator, .properties = properties, .by_node = by_node };
            }

            fn deinit(self: *TaskMetricEventSnapshot) void {
                self.by_node.deinit();
                self.properties.deinit(self.allocator);
                self.* = undefined;
            }

            fn fields(self: *const TaskMetricEventSnapshot, node_id: core.NodeId) Fields {
                return self.by_node.get(node_id.toInt()) orelse .{};
            }
        };

        pub fn renderTaskMetricsOutput(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            root_id: core.NodeId,
            limit: usize,
        ) ![]u8 {
            var out = QueryOutputWriter{ .allocator = allocator };
            errdefer out.buffer.deinit(allocator);

            var node_id_view = try store.openNodeByIdIndexView();
            defer node_id_view.deinit();
            if (!try node_id_view.nodeExists(root_id)) return core.Error.NotFound;

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var pending_events = std.ArrayList(PendingTaskMetricEvent).empty;
            defer pending_events.deinit(allocator);
            var aggregate_seen_nodes = std.AutoHashMap(u64, void).init(allocator);
            defer aggregate_seen_nodes.deinit();
            var detail_budget = TaskMetricDetailBudget.init(limit);

            const now_ns = persistentNowNs(io);
            var aggregate = TaskMetrics{};
            var child = TaskMetrics{};
            try collectTaskMetricsRows(allocator, store, &node_view, .src, root_id, .task_hierarchy, limit, now_ns, &child, &aggregate, &aggregate_seen_nodes, &pending_events, &detail_budget);
            var related = TaskMetrics{};
            try collectTaskMetricsRows(allocator, store, &node_view, .dst, root_id, .{ .ordinary = .related_to }, limit, now_ns, &related, &aggregate, &aggregate_seen_nodes, &pending_events, &detail_budget);
            var event_links = TaskMetrics{};
            try collectTaskEventMetricsRows(allocator, store, &node_view, root_id, .task_event, limit, &event_links, &aggregate, &pending_events);
            try collectTaskEventMetricsRows(allocator, store, &node_view, root_id, .references, limit, &event_links, &aggregate, &pending_events);
            try recordPendingTaskMetricEvents(allocator, store, pending_events.items);

            const total_open = aggregate.open_tasks;
            const total_claimed = aggregate.claimed_tasks;
            const total_completed = aggregate.completed_tasks;
            const total_failed = aggregate.failed_tasks;
            const total_rework = aggregate.rework_error_events;
            const combined = aggregate;
            const metrics_truncated = child.truncated or related.truncated or event_links.truncated or detail_budget.truncated;
            try out.print("task_metrics\t{}\tlimit={}\ttruncated={}\topen_tasks={}\tclaimed_tasks={}\tcompleted_tasks={}\tfailed_tasks={}\trework_error_events={}\n", .{ root_id.toInt(), limit, @intFromBool(metrics_truncated), total_open, total_claimed, total_completed, total_failed, total_rework });
            try out.print("budget\tscope=detail_edges\tscanned_edges={}\tlimit={}\ttruncated={}\n", .{ detail_budget.scanned_edges, detail_budget.limit, @intFromBool(detail_budget.truncated) });
            try writeTaskMetricsScopeRow(&out, "child_contains", child);
            try writeTaskMetricsScopeRow(&out, "incoming_related_to", related);
            try writeTaskMetricsScopeRow(&out, "incoming_task_event", event_links);
            const task_write_attempt_samples = @max(combined.task_write_attempt_events, combined.task_write_error_events);
            if (task_write_attempt_samples > 0) {
                try out.print(
                    "measured\tmetric=task_write_error_rate\tattempts={}\terrors={}\trate_bps={}\n",
                    .{ task_write_attempt_samples, combined.task_write_error_events, rateBps(combined.task_write_error_events, task_write_attempt_samples) },
                );
            } else {
                try out.writeAll("unavailable\tmetric=task_write_error_rate\treason=no_write_attempt_event_log\n");
            }
            if (combined.dependency_edge_created_events > 0) {
                try out.print(
                    "measured\tmetric=dependency_correction_rate\tcreated={}\tcorrections={}\trate_bps={}\n",
                    .{ combined.dependency_edge_created_events, combined.dependency_edge_correction_events, rateBps(combined.dependency_edge_correction_events, combined.dependency_edge_created_events) },
                );
            } else {
                try out.writeAll("unavailable\tmetric=dependency_correction_rate\treason=no_edge_revision_event_log\n");
            }
            const prompt_samples = combined.prompt_adherence_ok_events + combined.prompt_adherence_miss_events;
            if (prompt_samples > 0) {
                try out.print(
                    "measured\tmetric=prompt_adherence_rate\tok={}\tmisses={}\trate_bps={}\n",
                    .{ combined.prompt_adherence_ok_events, combined.prompt_adherence_miss_events, rateBps(combined.prompt_adherence_ok_events, prompt_samples) },
                );
            } else {
                try out.writeAll("unavailable\tmetric=prompt_adherence_rate\treason=no_prompt_adherence_event_log\n");
            }
            const total_tasks = total_open + total_claimed + total_completed + total_failed;
            if (total_tasks > 0) {
                try out.print(
                    "measured\tmetric=rework_density\ttasks={}\trework_error_events={}\trate_bps={}\n",
                    .{ total_tasks, total_rework, rateBps(total_rework, total_tasks) },
                );
            } else {
                try out.writeAll("unavailable\tmetric=rework_density\treason=no_task_samples\n");
            }
            if (combined.completion_latency_samples > 0) {
                try out.print(
                    "measured\tmetric=completion_latency\tsamples={}\tmin_ns={}\tmax_ns={}\n",
                    .{ combined.completion_latency_samples, combined.completion_latency_min_ns, combined.completion_latency_max_ns },
                );
            } else {
                try out.writeAll("unavailable\tmetric=completion_latency\treason=no_task_timestamp_index\n");
            }
            if (combined.stale_open_task_age_samples > 0) {
                try out.print(
                    "measured\tmetric=stale_open_task_age\tsamples={}\tmin_ns={}\tmax_ns={}\n",
                    .{ combined.stale_open_task_age_samples, combined.stale_open_task_age_min_ns, combined.stale_open_task_age_max_ns },
                );
            } else {
                try out.writeAll("unavailable\tmetric=stale_open_task_age\treason=no_task_timestamp_index\n");
            }
            return out.buffer.toOwnedSlice(allocator);
        }

        fn writeTaskMetricsScopeRow(out: *QueryOutputWriter, scope: []const u8, metrics: TaskMetrics) !void {
            try out.print(
                "scope\t{s}\tscanned_edges={}\ttruncated={}\topen_tasks={}\tclaimed_tasks={}\tcompleted_tasks={}\tfailed_tasks={}\tlegacy_closed_verifications={}\tlegacy_closed_fixes={}\tother_nodes={}\tready={}\tblocked={}\tmissing_dependencies={}\tdepends_on_edges={}\tblocker_edges={}\tverified_by_edges={}\trework_error_events={}\tnested_event_edges={}\n",
                .{
                    scope,
                    metrics.scanned_edges,
                    @intFromBool(metrics.truncated),
                    metrics.open_tasks,
                    metrics.claimed_tasks,
                    metrics.completed_tasks,
                    metrics.failed_tasks,
                    metrics.legacy_closed_verifications,
                    metrics.legacy_closed_fixes,
                    metrics.other_nodes,
                    metrics.ready_tasks,
                    metrics.blocked_tasks,
                    metrics.missing_dependency_tasks,
                    metrics.dependency_edges,
                    metrics.blocker_edges,
                    metrics.verification_edges,
                    metrics.rework_error_events,
                    metrics.nested_event_edges,
                },
            );
        }

        fn recordTaskLifecycleMetric(
            metrics: *TaskMetrics,
            lifecycle: task.Status,
            fields: task.StatusSnapshot.LifecycleFields,
            now_ns: u128,
        ) void {
            switch (lifecycle) {
                .open => {
                    metrics.open_tasks += 1;
                    if (taskMetricRecordedNsFromFields(fields)) |recorded_ns| metrics.recordStaleOpenTaskAge(recorded_ns, now_ns);
                },
                .claimed => metrics.claimed_tasks += 1,
                .completed => {
                    metrics.completed_tasks += 1;
                    if (taskMetricCompletionLatencyFromFields(fields)) |latency| metrics.recordCompletionLatency(latency.created_ns, latency.completed_ns);
                },
                .failed => metrics.failed_tasks += 1,
            }
        }

        fn recordTaskReadinessMetric(metrics: *TaskMetrics, state: task.ReadyState) void {
            switch (state) {
                .ready => metrics.ready_tasks += 1,
                .blocked => metrics.blocked_tasks += 1,
                .missing_dependencies => metrics.missing_dependency_tasks += 1,
            }
        }

        fn recordLegacyClosedTaskMetric(metrics: *TaskMetrics, kind: core.NodeKind, fields: task.StatusSnapshot.LifecycleFields) void {
            metrics.completed_tasks += 1;
            switch (kind) {
                .verification => metrics.legacy_closed_verifications += 1,
                .fix => metrics.legacy_closed_fixes += 1,
                else => unreachable,
            }
            if (taskMetricCompletionLatencyFromFields(fields)) |latency| metrics.recordCompletionLatency(latency.created_ns, latency.completed_ns);
        }

        const TaskMetricRelation = union(enum) {
            task_hierarchy,
            ordinary: core.RelKind,
        };

        fn collectTaskMetricsRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            relation: TaskMetricRelation,
            limit: usize,
            now_ns: u128,
            metrics: *TaskMetrics,
            aggregate_metrics: *TaskMetrics,
            aggregate_seen_nodes: *std.AutoHashMap(u64, void),
            pending_events: *std.ArrayList(PendingTaskMetricEvent),
            detail_budget: *TaskMetricDetailBudget,
        ) !void {
            const MetricRow = struct {
                node_id: core.NodeId,
            };
            var rows = std.ArrayList(MetricRow).empty;
            defer rows.deinit(allocator);
            const remaining_rows = if (metrics.scanned_edges < limit) limit - metrics.scanned_edges else 0;
            var hierarchy_records: ?TaskHierarchyEdgeCollection = null;
            defer if (hierarchy_records) |*records| records.deinit(allocator);
            var ordinary_records: ?std.ArrayList(storage.EdgeIndexRecord) = null;
            defer if (ordinary_records) |*records| records.deinit(allocator);
            const record_items: []const storage.EdgeIndexRecord = switch (relation) {
                .task_hierarchy => hierarchy: {
                    hierarchy_records = try collectVisibleTaskHierarchyEdgeRecordsLimited(
                        allocator,
                        store,
                        order,
                        owner_id,
                        taskEdgeLookaheadLimit(remaining_rows),
                    );
                    if (hierarchy_records.?.truncated) metrics.truncated = true;
                    break :hierarchy hierarchy_records.?.records.items;
                },
                .ordinary => |rel_filter| ordinary: {
                    ordinary_records = try readVisibleEdgeRecordsByNodeLimited(
                        allocator,
                        store,
                        order,
                        owner_id,
                        rel_filter,
                        taskEdgeLookaheadLimit(remaining_rows),
                    );
                    break :ordinary ordinary_records.?.items;
                },
            };
            for (record_items) |record| {
                if (metrics.scanned_edges >= limit) {
                    metrics.truncated = true;
                    break;
                }
                metrics.scanned_edges += 1;
                const node_id = switch (order) {
                    .src => core.NodeId.fromInt(record.dst),
                    .dst => core.NodeId.fromInt(record.src),
                    .id => return core.Error.Unsupported,
                };
                try rows.append(allocator, .{ .node_id = node_id });
            }
            if (rows.items.len == 0) return;

            const snapshot_ids = try allocator.alloc(core.NodeId, rows.items.len);
            defer allocator.free(snapshot_ids);
            for (rows.items, snapshot_ids) |row, *node_id| node_id.* = row.node_id;
            var lifecycle_snapshot = try task.StatusSnapshot.initForNodeIds(allocator, store, snapshot_ids);
            defer lifecycle_snapshot.deinit();
            const now_u64 = try u128ToU64(now_ns);
            var scope_seen_nodes = std.AutoHashMap(u64, void).init(allocator);
            defer scope_seen_nodes.deinit();

            for (rows.items) |row| {
                const node_id = row.node_id;
                const scope_entry = try scope_seen_nodes.getOrPut(node_id.toInt());
                if (scope_entry.found_existing) continue;
                const aggregate_entry = try aggregate_seen_nodes.getOrPut(node_id.toInt());
                const aggregate_target: ?*TaskMetrics = if (aggregate_entry.found_existing) null else aggregate_metrics;
                var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                switch (node.kind) {
                    .task => {
                        const lifecycle = try lifecycle_snapshot.statusForStoredNode(node, now_u64);
                        const lifecycle_fields = lifecycle_snapshot.fields(node.id);
                        recordTaskLifecycleMetric(metrics, lifecycle, lifecycle_fields, now_ns);
                        if (aggregate_target) |target| recordTaskLifecycleMetric(target, lifecycle, lifecycle_fields, now_ns);
                        if (!lifecycle.isTerminal()) {
                            if (try taskMetricReadyState(allocator, store, node_id, now_u64, &lifecycle_snapshot, metrics, detail_budget)) |state| {
                                recordTaskReadinessMetric(metrics, state);
                                if (aggregate_target) |target| recordTaskReadinessMetric(target, state);
                            }
                        }
                        const dependency_edges = try countTaskMetricEdges(allocator, store, .src, node_id, .depends_on, limit, metrics, detail_budget);
                        const blocker_edges = try countTaskMetricEdges(allocator, store, .dst, node_id, .blocks, limit, metrics, detail_budget);
                        const verification_edges = try countTaskMetricEdges(allocator, store, .src, node_id, .verified_by, limit, metrics, detail_budget);
                        const rework_events = try countTaskMetricEventKind(allocator, store, node_view, node_id, .error_event, limit, metrics, detail_budget);
                        metrics.dependency_edges += dependency_edges;
                        metrics.blocker_edges += blocker_edges;
                        metrics.verification_edges += verification_edges;
                        metrics.rework_error_events += rework_events;
                        if (aggregate_target) |target| {
                            target.dependency_edges += dependency_edges;
                            target.blocker_edges += blocker_edges;
                            target.verification_edges += verification_edges;
                            target.rework_error_events += rework_events;
                        }
                        try collectTaskAnchorEventMetrics(allocator, store, node_view, node_id, owner_id, limit, metrics, aggregate_target, pending_events, detail_budget);
                    },
                    .verification => {
                        if (lifecycle_snapshot.isLegacyClosedTaskNode(node)) {
                            recordLegacyClosedTaskMetric(metrics, node.kind, lifecycle_snapshot.fields(node.id));
                            if (aggregate_target) |target| recordLegacyClosedTaskMetric(target, node.kind, lifecycle_snapshot.fields(node.id));
                        } else {
                            metrics.other_nodes += 1;
                            if (aggregate_target) |target| target.other_nodes += 1;
                        }
                        const rework_events = try countTaskMetricEventKind(allocator, store, node_view, node_id, .error_event, limit, metrics, detail_budget);
                        metrics.rework_error_events += rework_events;
                        if (aggregate_target) |target| target.rework_error_events += rework_events;
                        try collectTaskAnchorEventMetrics(allocator, store, node_view, node_id, owner_id, limit, metrics, aggregate_target, pending_events, detail_budget);
                    },
                    .fix => {
                        if (lifecycle_snapshot.isLegacyClosedTaskNode(node)) {
                            recordLegacyClosedTaskMetric(metrics, node.kind, lifecycle_snapshot.fields(node.id));
                            if (aggregate_target) |target| recordLegacyClosedTaskMetric(target, node.kind, lifecycle_snapshot.fields(node.id));
                        } else {
                            metrics.other_nodes += 1;
                            if (aggregate_target) |target| target.other_nodes += 1;
                        }
                        const rework_events = try countTaskMetricEventKind(allocator, store, node_view, node_id, .error_event, limit, metrics, detail_budget);
                        metrics.rework_error_events += rework_events;
                        if (aggregate_target) |target| target.rework_error_events += rework_events;
                        try collectTaskAnchorEventMetrics(allocator, store, node_view, node_id, owner_id, limit, metrics, aggregate_target, pending_events, detail_budget);
                    },
                    .command, .error_event, .observation => {
                        metrics.other_nodes += 1;
                        try pending_events.append(allocator, .{ .node_id = node.id, .skip_root_id = null, .metrics = metrics });
                        if (aggregate_target) |target| {
                            target.other_nodes += 1;
                            try pending_events.append(allocator, .{ .node_id = node.id, .skip_root_id = null, .metrics = target });
                        }
                    },
                    else => {
                        metrics.other_nodes += 1;
                        if (aggregate_target) |target| target.other_nodes += 1;
                    },
                }
            }
        }

        fn collectTaskEventMetricsRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            root_id: core.NodeId,
            rel_filter: core.RelKind,
            limit: usize,
            metrics: *TaskMetrics,
            aggregate_metrics: *TaskMetrics,
            pending_events: *std.ArrayList(PendingTaskMetricEvent),
        ) !void {
            const remaining_rows = if (metrics.scanned_edges < limit) limit - metrics.scanned_edges else 0;
            var records = try readVisibleEdgeRecordsByNodeLimited(
                allocator,
                store,
                .dst,
                root_id,
                rel_filter,
                taskEdgeLookaheadLimit(remaining_rows),
            );
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (metrics.scanned_edges >= limit) {
                    metrics.truncated = true;
                    break;
                }
                metrics.scanned_edges += 1;
                var node = (try node_view.readNodeById(allocator, core.NodeId.fromInt(record.src))) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                switch (node.kind) {
                    .command, .error_event, .observation => {
                        metrics.other_nodes += 1;
                        try pending_events.append(allocator, .{ .node_id = node.id, .skip_root_id = null, .metrics = metrics });
                        try pending_events.append(allocator, .{ .node_id = node.id, .skip_root_id = null, .metrics = aggregate_metrics });
                    },
                    else => metrics.other_nodes += 1,
                }
            }
        }

        fn collectTaskAnchorEventMetrics(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            anchor_id: core.NodeId,
            owner_id: core.NodeId,
            limit: usize,
            metrics: *TaskMetrics,
            aggregate_metrics: ?*TaskMetrics,
            pending_events: *std.ArrayList(PendingTaskMetricEvent),
            detail_budget: *TaskMetricDetailBudget,
        ) !void {
            try collectTaskAnchorEventMetricsForRelation(allocator, store, node_view, anchor_id, owner_id, .task_event, limit, metrics, aggregate_metrics, pending_events, detail_budget);
            try collectTaskAnchorEventMetricsForRelation(allocator, store, node_view, anchor_id, owner_id, .references, limit, metrics, aggregate_metrics, pending_events, detail_budget);
        }

        fn collectTaskAnchorEventMetricsForRelation(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            anchor_id: core.NodeId,
            owner_id: core.NodeId,
            rel_filter: core.RelKind,
            limit: usize,
            metrics: *TaskMetrics,
            aggregate_metrics: ?*TaskMetrics,
            pending_events: *std.ArrayList(PendingTaskMetricEvent),
            detail_budget: *TaskMetricDetailBudget,
        ) !void {
            var scanned: usize = 0;
            var records = try readVisibleEdgeRecordsByNodeLimited(
                allocator,
                store,
                .dst,
                anchor_id,
                rel_filter,
                taskEdgeLookaheadLimit(@min(limit, detail_budget.remaining())),
            );
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (!detail_budget.charge(metrics)) break;
                if (scanned >= limit) {
                    metrics.truncated = true;
                    break;
                }
                scanned += 1;
                metrics.nested_event_edges += 1;
                var node = (try node_view.readNodeById(allocator, core.NodeId.fromInt(record.src))) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                switch (node.kind) {
                    .command, .error_event, .observation => {
                        try pending_events.append(allocator, .{ .node_id = node.id, .skip_root_id = owner_id, .metrics = metrics });
                        if (aggregate_metrics) |target| try pending_events.append(allocator, .{ .node_id = node.id, .skip_root_id = owner_id, .metrics = target });
                    },
                    else => {},
                }
            }
        }

        fn rateBps(numerator: usize, denominator: usize) usize {
            if (denominator == 0) return 0;
            const scaled = @as(u128, numerator) * 10000 / @as(u128, denominator);
            return @intCast(@min(scaled, std.math.maxInt(usize)));
        }

        fn recordPendingTaskMetricEvents(
            allocator: std.mem.Allocator,
            store: storage.Store,
            pending_events: []const PendingTaskMetricEvent,
        ) !void {
            if (pending_events.len == 0) return;
            const node_ids = try allocator.alloc(core.NodeId, pending_events.len);
            defer allocator.free(node_ids);
            for (pending_events, node_ids) |pending, *node_id| node_id.* = pending.node_id;
            var snapshot = try TaskMetricEventSnapshot.init(allocator, store, node_ids);
            defer snapshot.deinit();
            const SeenEvent = struct {
                metrics_address: usize,
                node_id: u64,
            };
            var seen = std.AutoHashMap(SeenEvent, void).init(allocator);
            defer seen.deinit();
            for (pending_events) |pending| {
                const key = SeenEvent{
                    .metrics_address = @intFromPtr(pending.metrics),
                    .node_id = pending.node_id.toInt(),
                };
                if (seen.contains(key)) continue;
                // A task-root copy is intentionally skipped in favor of the direct
                // root event row. Do not mark that skipped path as seen, or the later
                // direct row would be suppressed as a duplicate.
                if (recordTaskMetricEventFromSnapshot(&snapshot, pending)) try seen.put(key, {});
            }
        }

        fn recordTaskMetricEventFromSnapshot(snapshot: *const TaskMetricEventSnapshot, pending: PendingTaskMetricEvent) bool {
            const fields = snapshot.fields(pending.node_id);
            if (pending.skip_root_id) |root_id| {
                if (fields.task_root_id == root_id.toInt()) return false;
            }
            const concrete_event_type = fields.event_type orelse return true;
            if (std.mem.eql(u8, concrete_event_type, "write_attempt")) {
                pending.metrics.task_write_attempt_events += 1;
            } else if (std.mem.eql(u8, concrete_event_type, "write_error")) {
                pending.metrics.task_write_error_events += 1;
            } else if (std.mem.eql(u8, concrete_event_type, "dependency_edge_created")) {
                if (taskMetricEventRelationIsDependency(fields.dependency_relation)) {
                    pending.metrics.dependency_edge_created_events += 1;
                }
            } else if (std.mem.eql(u8, concrete_event_type, "dependency_edge_deleted")) {
                if (taskMetricEventRelationIsDependency(fields.dependency_relation)) {
                    pending.metrics.dependency_edge_correction_events += 1;
                }
            } else if (std.mem.eql(u8, concrete_event_type, "prompt_adherence_ok")) {
                pending.metrics.prompt_adherence_ok_events += 1;
            } else if (std.mem.eql(u8, concrete_event_type, "prompt_adherence_miss")) {
                pending.metrics.prompt_adherence_miss_events += 1;
            }
            return true;
        }

        fn taskMetricEventRelationIsDependency(relation: ?[]const u8) bool {
            const value = relation orelse return false;
            return std.mem.eql(u8, value, "depends_on") or std.mem.eql(u8, value, "blocks");
        }

        const TaskMetricCompletionLatency = struct {
            created_ns: u128,
            completed_ns: u128,
        };

        const min_task_metric_epoch_ns: u128 = 1_500_000_000_000_000_000;

        pub fn taskMetricEpochNs(value: ?u128) ?u128 {
            const timestamp = value orelse return null;
            return if (timestamp >= min_task_metric_epoch_ns) timestamp else null;
        }

        pub fn optionalU64ToU128(value: ?u64) ?u128 {
            return if (value) |concrete| @as(u128, concrete) else null;
        }

        fn taskMetricRecordedNsFromFields(fields: task.StatusSnapshot.LifecycleFields) ?u128 {
            return taskMetricEpochNs(optionalU64ToU128(fields.task_created_ns)) orelse
                taskMetricEpochNs(optionalU64ToU128(fields.task_recorded_ns));
        }

        fn taskMetricCompletionLatencyFromFields(fields: task.StatusSnapshot.LifecycleFields) ?TaskMetricCompletionLatency {
            const created_ns = taskMetricEpochNs(optionalU64ToU128(fields.task_created_ns)) orelse return null;
            const completed_ns = taskMetricEpochNs(optionalU64ToU128(fields.task_completed_ns)) orelse return null;
            if (completed_ns < created_ns) return null;
            return .{ .created_ns = created_ns, .completed_ns = completed_ns };
        }

        fn taskMetricReadyState(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            now_ns: u64,
            lifecycle_snapshot: *const task.StatusSnapshot,
            metrics: *TaskMetrics,
            detail_budget: *TaskMetricDetailBudget,
        ) !?task.ReadyState {
            const remaining_edges = detail_budget.remaining();
            var stats = task.ReadyTraversalStats{};
            const state = task.readyStateWithPersistentStoreSnapshotBudgetAt(
                allocator,
                store,
                node_id,
                .{
                    .max_visited_nodes = std.math.add(usize, remaining_edges, 1) catch std.math.maxInt(usize),
                    .max_visited_edges = remaining_edges,
                    // The aggregate detail-edge budget, not a fresh per-row clock,
                    // is the authoritative bound for this local indexed traversal.
                    .timeout_ms = std.math.maxInt(u64),
                },
                now_ns,
                lifecycle_snapshot,
                &stats,
            ) catch |err| {
                detail_budget.absorb(stats.edges_visited);
                if (err == core.Error.BudgetExceeded) {
                    detail_budget.markTruncated(metrics);
                    return null;
                }
                return err;
            };
            detail_budget.absorb(stats.edges_visited);
            return state;
        }

        fn countTaskMetricEdges(
            allocator: std.mem.Allocator,
            store: storage.Store,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            rel_filter: core.RelKind,
            limit: usize,
            metrics: *TaskMetrics,
            detail_budget: *TaskMetricDetailBudget,
        ) !usize {
            var count: usize = 0;
            var records = try readVisibleEdgeRecordsByNodeLimited(
                allocator,
                store,
                order,
                owner_id,
                rel_filter,
                taskEdgeLookaheadLimit(@min(limit, detail_budget.remaining())),
            );
            defer records.deinit(allocator);
            for (records.items) |_| {
                if (!detail_budget.charge(metrics)) break;
                if (count >= limit) {
                    metrics.truncated = true;
                    break;
                }
                count += 1;
            }
            return count;
        }

        fn countTaskMetricRelatedKind(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            node_id: core.NodeId,
            rel_filter: core.RelKind,
            kind: core.NodeKind,
            limit: usize,
            seen: *std.AutoHashMap(u64, void),
            count: *usize,
            metrics: *TaskMetrics,
            detail_budget: *TaskMetricDetailBudget,
        ) !void {
            var outgoing = try readVisibleEdgeRecordsByNodeLimited(
                allocator,
                store,
                .src,
                node_id,
                rel_filter,
                taskEdgeLookaheadLimit(detail_budget.remaining()),
            );
            defer outgoing.deinit(allocator);
            for (outgoing.items) |record| {
                if (!detail_budget.charge(metrics)) return;
                if (count.* >= limit) {
                    metrics.truncated = true;
                    return;
                }
                const related_id = core.NodeId.fromInt(record.dst);
                var node = (try node_view.readNodeById(allocator, related_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                if (node.kind != kind) continue;
                const entry = try seen.getOrPut(related_id.toInt());
                if (!entry.found_existing) count.* += 1;
            }
            var incoming = try readVisibleEdgeRecordsByNodeLimited(
                allocator,
                store,
                .dst,
                node_id,
                rel_filter,
                taskEdgeLookaheadLimit(detail_budget.remaining()),
            );
            defer incoming.deinit(allocator);
            for (incoming.items) |record| {
                if (!detail_budget.charge(metrics)) return;
                if (count.* >= limit) {
                    metrics.truncated = true;
                    return;
                }
                const related_id = core.NodeId.fromInt(record.src);
                var node = (try node_view.readNodeById(allocator, related_id)) orelse return error.InvalidRecord;
                defer node.deinit(allocator);
                if (node.kind != kind) continue;
                const entry = try seen.getOrPut(related_id.toInt());
                if (!entry.found_existing) count.* += 1;
            }
        }

        fn countTaskMetricEventKind(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            node_id: core.NodeId,
            kind: core.NodeKind,
            limit: usize,
            metrics: *TaskMetrics,
            detail_budget: *TaskMetricDetailBudget,
        ) !usize {
            const event_relations = [_]core.RelKind{ .related_to, .task_event, .references };
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();
            var count: usize = 0;
            inline for (event_relations, 0..) |relation, relation_index| {
                try countTaskMetricRelatedKind(allocator, store, node_view, node_id, relation, kind, limit, &seen, &count, metrics, detail_budget);
                if (count >= limit) {
                    // An exact hit in the final relation is complete. Earlier exact
                    // hits leave relation classes uninspected and are bounded samples.
                    if (relation_index + 1 < event_relations.len) metrics.truncated = true;
                    break;
                }
            }
            return count;
        }

        pub fn writeTaskPacketNodeRow(
            out: *QueryOutputWriter,
            role: []const u8,
            node_id: core.NodeId,
            kind: core.NodeKind,
            text: []const u8,
        ) !void {
            try out.print("{s}\t{}\t", .{ role, node_id.toInt() });
            try writeNodeKindName(out, kind);
            try out.writeAll("\t");
            try writeEscapedText(out, text);
            try out.writeAll("\n");
        }

        pub fn writeTaskPacketEdgeRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            out: *QueryOutputWriter,
            role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            rel_filter: core.RelKind,
            limit: usize,
        ) !void {
            var rows: usize = 0;
            var truncated = false;
            var records = try readVisibleEdgeRecordsByNode(allocator, store, order, owner_id, rel_filter);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (rows >= limit) {
                    truncated = true;
                    break;
                }
                if (try writeTaskPacketEdgeRow(allocator, store, node_view, out, role, order, record)) rows += 1;
            }
            if (truncated) try out.print("{s}_truncated\tlimit={}\n", .{ role, limit });
        }

        pub fn writeTaskPacketRecentEdgeRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            out: *QueryOutputWriter,
            role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            rel_filter: core.RelKind,
            limit: usize,
        ) !void {
            if (limit == 0) return error.InvalidLimit;

            const recent = try allocator.alloc(storage.EdgeIndexRecord, limit);
            defer allocator.free(recent);

            var scanned: usize = 0;
            var records = try readVisibleEdgeRecordsByNode(allocator, store, order, owner_id, rel_filter);
            defer records.deinit(allocator);
            for (records.items) |record| {
                recent[scanned % limit] = record;
                scanned += 1;
            }

            const emitted = @min(scanned, limit);
            var offset: usize = 0;
            while (offset < emitted) : (offset += 1) {
                const index = (scanned - 1 - offset) % limit;
                _ = try writeTaskPacketEdgeRow(allocator, store, node_view, out, role, order, recent[index]);
            }
            if (scanned > limit) {
                try out.print("{s}_truncated\tlimit={}\tscanned={}\trecent=1\n", .{ role, limit, scanned });
            }
        }

        pub fn writeTaskPacketHierarchyEdgeRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            out: *QueryOutputWriter,
            role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            limit: usize,
        ) !void {
            var records = try readVisibleTaskHierarchyEdgeRecords(allocator, store, order, owner_id);
            defer records.deinit(allocator);
            std.mem.sort(storage.EdgeIndexRecord, records.items, {}, edgeRecordIdLessThan);
            const emitted = @min(records.items.len, limit);
            for (records.items[0..emitted]) |record| {
                _ = try writeTaskPacketEdgeRow(allocator, store, node_view, out, role, order, record);
            }
            if (records.items.len > limit) try out.print("{s}_truncated\tlimit={}\n", .{ role, limit });
        }

        pub fn writeTaskPacketRecentHistoryEdgeRows(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            out: *QueryOutputWriter,
            role: []const u8,
            order: storage.EdgeIndexOrder,
            owner_id: core.NodeId,
            limit: usize,
        ) !void {
            if (limit == 0) return error.InvalidLimit;
            var records = try readVisibleTaskPacketChildEdgeRecords(allocator, store, order, owner_id);
            defer records.deinit(allocator);
            std.mem.sort(storage.EdgeIndexRecord, records.items, {}, edgeRecordIdLessThan);
            const emitted = @min(records.items.len, limit);
            var offset: usize = 0;
            while (offset < emitted) : (offset += 1) {
                const index = records.items.len - 1 - offset;
                _ = try writeTaskPacketEdgeRow(allocator, store, node_view, out, role, order, records.items[index]);
            }
            if (records.items.len > limit) {
                try out.print("{s}_truncated\tlimit={}\tscanned={}\trecent=1\n", .{ role, limit, records.items.len });
            }
        }

        fn writeTaskPacketEdgeRow(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_view: anytype,
            out: *QueryOutputWriter,
            role: []const u8,
            order: storage.EdgeIndexOrder,
            record: storage.EdgeIndexRecord,
        ) !bool {
            const node_id = switch (order) {
                .src => core.NodeId.fromInt(record.dst),
                .dst => core.NodeId.fromInt(record.src),
                .id => return core.Error.Unsupported,
            };
            var node = (try node_view.readNodeById(allocator, node_id)) orelse return error.InvalidRecord;
            defer node.deinit(allocator);
            if (taskPacketRoleIsGoalAnchor(role) and try nodeHasTaskEventSchema(allocator, store, node.id)) return false;
            try out.print("{s}\t{}\t", .{ role, record.edge_id });
            try writeRelKindName(out, @enumFromInt(record.rel));
            try out.print("\t{}\t", .{node.id.toInt()});
            try writeNodeKindName(out, node.kind);
            try out.writeAll("\t");
            try writeEscapedText(out, node.text);
            try out.writeAll("\n");
            return true;
        }

        pub fn taskPacketRoleIsGoalAnchor(role: []const u8) bool {
            return std.mem.eql(u8, role, "goal_anchor_in") or std.mem.eql(u8, role, "goal_anchor_out");
        }

        pub fn nodeHasTaskEventSchema(allocator: std.mem.Allocator, store: storage.Store, node_id: core.NodeId) !bool {
            const schema_type = try store.getNodeStringProperty(allocator, node_id, "schema_type");
            defer if (schema_type) |value| allocator.free(value);
            const concrete = schema_type orelse return false;
            return std.mem.eql(u8, concrete, "task_event");
        }

        pub fn monotonicNs(io: std.Io) u128 {
            const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
            return if (timestamp < 0) 0 else @intCast(timestamp);
        }

        pub fn persistentNowNs(io: std.Io) u128 {
            const timestamp = std.Io.Clock.real.now(io).nanoseconds;
            return if (timestamp < 0) 0 else @intCast(timestamp);
        }

        pub fn elapsedNs(io: std.Io, start: u128) u128 {
            const now = monotonicNs(io);
            return if (now >= start) now - start else 0;
        }

        test "task governance timestamps persist as epoch nanoseconds" {
            const helper = struct {
                fn expectEpochNsField(output: []const u8, field: []const u8) !void {
                    const field_pos = std.mem.indexOf(u8, output, field) orelse 0;
                    var pos = if (field_pos == 0) 0 else field_pos + field.len;
                    while (pos < output.len and !std.ascii.isDigit(output[pos])) : (pos += 1) {}
                    const start = pos;
                    while (pos < output.len and std.ascii.isDigit(output[pos])) : (pos += 1) {}
                    try std.testing.expect(pos > start);
                    const value = try std.fmt.parseInt(u128, output[start..pos], 10);
                    try std.testing.expect(value >= 1_500_000_000_000_000_000);
                }
            };

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "timestamped task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.text = \"timestamped task\" RETURN n.task_recorded_ns, n.task_created_ns LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
            try helper.expectEpochNsField(out.buffer.items, "task_recorded_ns");
            try helper.expectEpochNsField(out.buffer.items, "task_created_ns");

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_attempt", "--task", "2", "--note", "start" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.text = \"task_event write_attempt note=start\" RETURN n.task_event_ns LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
            try helper.expectEpochNsField(out.buffer.items, "task_event_ns");

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "2", "verification", "accepted timestamped task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.text = \"accepted timestamped task\" RETURN n.task_recorded_ns, n.task_created_ns, n.task_completed_ns LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
            try helper.expectEpochNsField(out.buffer.items, "task_recorded_ns");
            try helper.expectEpochNsField(out.buffer.items, "task_created_ns");
            try helper.expectEpochNsField(out.buffer.items, "task_completed_ns");

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_attempt", "--task", "2", "--note", "second" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "3", "command", "updated legacy event" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:command) WHERE n.text = \"updated legacy event\" RETURN n.task_event_ns LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
            try helper.expectEpochNsField(out.buffer.items, "task_event_ns");
        }

        test "task governance normalizes legacy monotonic timestamps" {
            const helper = struct {
                fn expectEpochNsField(output: []const u8, field: []const u8) !void {
                    const field_pos = std.mem.indexOf(u8, output, field) orelse 0;
                    var pos = if (field_pos == 0) 0 else field_pos + field.len;
                    while (pos < output.len and !std.ascii.isDigit(output[pos])) : (pos += 1) {}
                    const start = pos;
                    while (pos < output.len and std.ascii.isDigit(output[pos])) : (pos += 1) {}
                    try std.testing.expect(pos > start);
                    const value = try std.fmt.parseInt(u128, output[start..pos], 10);
                    try std.testing.expect(value >= min_task_metric_epoch_ns);
                }
            };

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "literal props_text=\"{\"domain_id\":\"tinykg\",\"schema_type\":\"task\",\"task_recorded_ns\":1150731573925708,\"task_created_ns\":1150731573925708}\"" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=stale_open_task_age\tsamples=1\tmin_ns=") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unavailable\tmetric=stale_open_task_age") == null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "2", "verification", "accepted legacy task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.text = \"accepted legacy task\" RETURN n.task_recorded_ns, n.task_created_ns, n.task_completed_ns LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
            try helper.expectEpochNsField(out.buffer.items, "task_recorded_ns");
            try helper.expectEpochNsField(out.buffer.items, "task_created_ns");
            try helper.expectEpochNsField(out.buffer.items, "task_completed_ns");
        }

        test "task metrics measures completion latency for revised task anchors" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "latency task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "2", "verification", "accepted latency task" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t1\tlimit=8\ttruncated=0\topen_tasks=0\tclaimed_tasks=0\tcompleted_tasks=1\tfailed_tasks=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=completion_latency\tsamples=1\tmin_ns=") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unavailable\tmetric=completion_latency") == null);
        }

        test "task frontier walks deep tree emitting actionable leaves with aggregate readiness and path" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            // 1 root ─contains→ 2 step A(叶)/ 3 step B(复合,depends_on A)/ 6 doc(非任务)/ 7 step C(A precedes C)
            // 3 step B ─contains→ 4 B1(叶)/ 5 B2(叶,depends_on B1)
            try run(&.{ "tinykg", "add-node", db_path, "task", "PLAN root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "step A" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "step B" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "B1 leaf" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "B2 leaf" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "notes doc" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "step C" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "3" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "3", "contains", "4" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "3", "contains", "5" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "6" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "3", "depends_on", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "5", "depends_on", "4" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "2", "precedes", "7" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "7" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "20" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_frontier\t1\tlimit=20\tmode=deep") != null);
            // 叶 A ready;复合 B 自身 missing(依赖 A);孙 B1 继承 B 的 missing;B2 自身 missing(依赖 B1);C 被 precedes 门住。
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t1\tcontains\t2\tstatus=open\treadiness=ready\tdepth=1\tclaimed_by=-\tpath=-\tstep A") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "branch_task\t2\tcontains\t3\tstatus=open\treadiness=missing_dependencies\tdepth=1\tclaimed_by=-\tpath=-\tstep B") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t3\tcontains\t4\tstatus=open\treadiness=missing_dependencies\tdepth=2\tclaimed_by=-\tpath=step B\tB1 leaf") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t4\tcontains\t5\tstatus=open\treadiness=missing_dependencies\tdepth=2\tclaimed_by=-\tpath=step B\tB2 leaf") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t9\tcontains\t7\tstatus=open\treadiness=missing_dependencies\tdepth=1\tclaimed_by=-\tpath=-\tstep C") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "notes doc") == null);

            // 闭合 A:A 出 frontier;B 解锁(ready);B1 继承解除;B2 仍等 B1;C 前驱释放。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "2", "verification", "step A done" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "20" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "step A") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "branch_task\t2\tcontains\t3\tstatus=open\treadiness=ready\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t3\tcontains\t4\tstatus=open\treadiness=ready\tdepth=2\tclaimed_by=-\tpath=step B\tB1 leaf") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t4\tcontains\t5\tstatus=open\treadiness=missing_dependencies\tdepth=2\tclaimed_by=-\tpath=step B\tB2 leaf") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t9\tcontains\t7\tstatus=open\treadiness=ready\t") != null);

            // 闭合 B1:B2 解锁;B 仍是复合(B2 开放)。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "4", "verification", "B1 done" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "20" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "B1 leaf") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t4\tcontains\t5\tstatus=open\treadiness=ready\tdepth=2\tclaimed_by=-\tpath=step B\tB2 leaf") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "branch_task\t2\tcontains\t3\tstatus=open\treadiness=ready\t") != null);

            // 闭合 B2:B 子树全闭 → B 变叶且 ready(可闭合信号);frontier 只剩 B 与 C。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "5", "verification", "B2 done" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "20" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t2\tcontains\t3\tstatus=open\treadiness=ready\tdepth=1\tclaimed_by=-\tpath=-\tstep B") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "branch_task") == null);
        }

        test "task frontier aggregates readiness across every parent in a contains diamond" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            inline for (.{ "root", "ready parent", "blocked parent", "shared leaf", "blocker" }) |label| {
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-node", db_path, "task", label }, &out, std.testing.allocator, std.testing.io);
            }
            inline for (&.{
                .{ "1", "contains", "2" },
                .{ "1", "contains", "3" },
                // The ready path is deliberately inserted first. The old emitting
                // DFS wrote node 4 as ready before discovering the blocked path.
                .{ "2", "contains", "4" },
                .{ "3", "contains", "4" },
                .{ "5", "blocks", "3" },
            }) |edge| {
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-edge", db_path, edge[0], edge[1], edge[2] }, &out, std.testing.allocator, std.testing.io);
            }

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.buffer.items, "shared leaf"));
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t3\tcontains\t4\tstatus=open\treadiness=blocked") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "shared leaf") != null);
        }

        test "task frontier propagates root blockers to descendants" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            inline for (&.{ "root", "child", "blocker" }) |label| {
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-node", db_path, "task", label }, &out, std.testing.allocator, std.testing.io);
            }
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "3", "blocks", "1" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t1\tcontains\t2\tstatus=open\treadiness=blocked") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-close", db_path, "3", "completed" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task\t1\tcontains\t2\tstatus=open\treadiness=ready") != null);
        }

        test "consecutive task revisions survive store rewrite meta cache invalidation" {
            // 回归:rewriteNodeStore 换目录后不清 index_meta_cache,且 events.bin 对齐填充
            // 常使字节数不变 → 第二次 revise 的治理属性写读到旧 meta digest 撞 InvalidRecord。
            // 闭合循环(revise→revise→revise)是任务 DAG 的核心形状,必须常绿。
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "c1" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "c2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "3" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "2", "verification", "done" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "updated node=2") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "3", "verification", "done" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "updated node=3") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task") == null);
        }

        test "ensure-node preserves idempotent identity, task status repair, and option rejection" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-node", db_path, "project", "demo", "--schema-type", "project" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("node 1 created=1\n", out.buffer.items);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-node", db_path, "project", "demo", "--schema-type", "project" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("node 1 created=0\n", out.buffer.items);

            {
                var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                const legacy_task = try store.addNode(.task, "legacy task");
                try std.testing.expectEqual(@as(u64, 2), legacy_task.toInt());
            }
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-node", db_path, "task", "legacy task" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("node 2 created=0\n", out.buffer.items);
            {
                var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                const status = try store.getNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property);
                defer if (status) |value| std.testing.allocator.free(value);
                try std.testing.expectEqualStrings("open", status.?);
            }

            // Visible-text modifiers are rejected during preparation, before the
            // shared lock/Store mutation context is acquired.
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.Unsupported,
                run(&.{ "tinykg", "ensure-node", db_path, "project", "demo", "--name", "renamed" }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
        }

        test "ensure-anchor 三锚唯一 + project 树约束 + contain 防环 + list-recent 下钻(乙方案地基)" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-node", db_path, "project", "demo-proj", "--schema-type", "project" }, &out, std.testing.allocator, std.testing.io);

            // Preserve preparation error order: numeric project id is validated
            // before the anchor label, and both precede lock/Store acquisition.
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.InvalidNodeId,
                run(&.{ "tinykg", "ensure-anchor", db_path, "bad-id", "unsupported" }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectError(
                error.InvalidArgument,
                run(&.{ "tinykg", "ensure-anchor", db_path, "1", "unsupported" }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);

            // 三锚 find-or-create,每类唯一(第二次 created=0 且同 id)。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-anchor", db_path, "1", "task" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node 2 created=1") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-anchor", db_path, "1", "task" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node 2 created=0") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-anchor", db_path, "1", "docs" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node 3 created=1") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-anchor", db_path, "1", "memory" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node 4 created=1") != null);
            {
                var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                const status = try store.getNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property);
                defer if (status) |value| std.testing.allocator.free(value);
                try std.testing.expectEqualStrings("open", status.?);
            }
            // 非 project 节点上 ensure-anchor 拒绝。
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "ensure-anchor", db_path, "2", "task" }, &out, std.testing.allocator, std.testing.io));

            // project 树约束:task 锚(2)收养 project(5)拒;project 收养 project 过。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "project", "sub-proj" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.ProjectTreeViolation, run(&.{ "tinykg", "add-edge", db_path, "2", "contain", "5" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contain", "5" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge") != null);
            // govern-node --parent 同约束(attachToProject 底层)。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "project", "sub-proj-2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.ProjectTreeViolation, run(&.{ "tinykg", "govern-node", db_path, "6", "--parent", "2" }, &out, std.testing.allocator, std.testing.io));

            // contain 防环:子 project(5)收养祖先 project(1)拒。
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.CycleDetected, run(&.{ "tinykg", "add-edge", db_path, "5", "contain", "1" }, &out, std.testing.allocator, std.testing.io));

            // 树约束盖 contains(Linus B):task kind 的锚(2)把 project 挂进任务分解树 → 拒。
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.ProjectTreeViolation, run(&.{ "tinykg", "add-edge", db_path, "2", "contains", "5" }, &out, std.testing.allocator, std.testing.io));

            // reparent 到自己的锚 = to 在 from 的 contain 子树内 → 环拒绝(Linus 第三轮:
            // 锚排除若泄进治理面,这里会被绕过并造 to→to 自环——contain_only 必须看见锚)。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "reparent-contain", db_path, "1", "2" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "reason=would_create_contain_cycle") != null);

            // list-recent --project composition 下钻:锚(contain 1跳)→ 计划根(contains 2跳)→ 步骤(3跳)全可见。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "计划根甲", "--schema-type", "plan_step" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "2", "contains", "7" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "步骤乙", "--schema-type", "plan_step" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "7", "contains", "8" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "list-recent", db_path, "--project", "1", "--limit", "10" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "计划根甲") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "步骤乙") != null);
            // 锚是结构基础设施不是内容:穿透遍历但不进成员集(不浮出脚手架)。
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task anchor") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "docs anchor") == null);
        }

        test "ensure-anchor repairs status on an existing legacy task anchor" {
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
                    .{ .id = .fromInt(1), .kind = .project, .text = "project" },
                    .{ .id = .fromInt(2), .kind = .task, .text = "legacy task anchor" },
                });
                try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "schema_type", "task_anchor");
                try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .contain, .dst = .fromInt(2) });
            }

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "ensure-anchor", db_path, "1", "task" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("node 2 created=0\n", out.buffer.items);

            var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            const status = try store.getNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property);
            defer if (status) |value| std.testing.allocator.free(value);
            try std.testing.expectEqualStrings("open", status.?);
        }

        test "append-node-version materializes open status for task versions" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "old task version" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "append-node-version", db_path, "1", "task", "new task version" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "old=1 new=2") != null);

            var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            const status = try store.getNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property);
            defer if (status) |value| std.testing.allocator.free(value);
            try std.testing.expectEqualStrings("open", status.?);
        }

        test "task claim lease lifecycle with frontier filters" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "leaf one" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "leaf two" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "notes" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "3" }, &out, std.testing.allocator, std.testing.io);

            // 认领:frontier 行内可见 holder。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-claim", db_path, "2", "--by", "sessA" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_claimed\t2\tby=sessA\texpires_ns=") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "claimed_by=sessA\tpath=-\tleaf one") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "claimed_by=-\tpath=-\tleaf two") != null);

            // 冲突:未过期的他人租约拒绝(除非 --steal)。
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.ClaimHeld, run(&.{ "tinykg", "task-claim", db_path, "2", "--by", "sessB" }, &out, std.testing.allocator, std.testing.io));
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_claim_held\t2\tby=sessA") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-claim", db_path, "2", "--by", "sessB", "--steal" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_claimed\t2\tby=sessB") != null);

            // 同 agent 续约合法。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-claim", db_path, "2", "--by", "sessB", "--ttl-s", "60" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_claimed\t2\tby=sessB") != null);

            // 过滤:--mine 只见自己的;--unclaimed 只见无主的。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--mine", "sessB" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf one") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf two") == null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--unclaimed" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf one") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf two") != null);

            // 释放的身份对称性:他人活租约不带 --by 匹配 → 拒;错误身份 → 拒;--force 越权 → 放。
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.ClaimHeld, run(&.{ "tinykg", "task-release", db_path, "2" }, &out, std.testing.allocator, std.testing.io));
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_release_held\t2\tby=sessB") != null);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.ClaimHeld, run(&.{ "tinykg", "task-release", db_path, "2", "--by", "sessA" }, &out, std.testing.allocator, std.testing.io));
            // 正确身份释放 = 租约立即过期 → 回到无主。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-release", db_path, "2", "--by", "sessB" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_released\t2\tproperty_publishes=1") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--unclaimed" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf one") != null);
            // 无主任务再 release 幂等(不需要身份);--force 路径:sessA 重新认领后被越权释放。
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-release", db_path, "2" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_released\t2\tproperty_publishes=0") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-claim", db_path, "2", "--by", "sessA" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-release", db_path, "2", "--force" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_released\t2\tproperty_publishes=1") != null);

            // 零 TTL 不能建立 canonical claimed 状态，必须在写前拒绝。
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.InvalidLimit, run(&.{ "tinykg", "task-claim", db_path, "3", "--by", "sessC", "--ttl-s", "0" }, &out, std.testing.allocator, std.testing.io));
            try std.testing.expectError(error.TooManyArguments, TaskMutationArguments.parseClaim(&.{ "3", "--by", "sessC", "--by", "sessD" }, task_claim_default_ttl_s));
            try std.testing.expectError(error.TooManyArguments, TaskMutationArguments.parseClaim(&.{ "3", "--ttl-s", "1", "--ttl-s", "2" }, task_claim_default_ttl_s));
            // Simulate a crash that persisted the claimed commit marker but whose
            // lease has expired. QL filtering and projection must expose effective
            // open status, not the stale raw property.
            {
                var expired_store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
                defer expired_store.deinit();
                try expired_store.setNodeStringProperty(std.testing.allocator, .fromInt(3), task.status_property, @tagName(task.Status.claimed));
                try expired_store.setNodeStringProperty(std.testing.allocator, .fromInt(3), task.claimed_by_property, "sessC");
                try expired_store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(3) }, task.claim_expires_ns_property, 1);
            }
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "claimed_by=-\tpath=-\tleaf two") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.status = \"open\" RETURN n.text" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf two") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.status = \"claimed\" RETURN n.text" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf two") == null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.text = \"leaf two\" RETURN n.status" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("open\n", out.buffer.items);

            // 非任务节点不可认领。
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "task-claim", db_path, "4", "--by", "sessA" }, &out, std.testing.allocator, std.testing.io));
        }

        test "task agent identity validation is independent of lifecycle state" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);
            const oversized_identity = [_]u8{'x'} ** (task.max_claim_holder_len + 1);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "identity validation" }, &out, std.testing.allocator, std.testing.io);

            inline for (&.{
                &.{ "tinykg", "task-claim", db_path, "1", "--by", &oversized_identity },
                &.{ "tinykg", "task-release", db_path, "1", "--by", &oversized_identity },
                &.{ "tinykg", "task-close", db_path, "1", "failed", "--by", &oversized_identity },
                &.{ "tinykg", "task-frontier", db_path, "1", "--mine", &oversized_identity },
            }) |command| {
                out.buffer.clearRetainingCapacity();
                try std.testing.expectError(error.InvalidArgument, run(command, &out, std.testing.allocator, std.testing.io));
            }

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-close", db_path, "1", "failed" }, &out, std.testing.allocator, std.testing.io);
            inline for (&.{
                &.{ "tinykg", "task-release", db_path, "1", "--by", &oversized_identity },
                &.{ "tinykg", "task-close", db_path, "1", "failed", "--by", &oversized_identity },
            }) |command| {
                out.buffer.clearRetainingCapacity();
                try std.testing.expectError(error.InvalidArgument, run(command, &out, std.testing.allocator, std.testing.io));
            }
        }

        test "task frontier lifecycle snapshot includes external scheduler endpoints" {
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
                .{ .id = .fromInt(1), .kind = .task, .text = "root" },
                .{ .id = .fromInt(2), .kind = .task, .text = "child" },
                .{ .id = .fromInt(3), .kind = .task, .text = "dependency" },
                .{ .id = .fromInt(4), .kind = .task, .text = "blocker" },
                .{ .id = .fromInt(5), .kind = .task, .text = "predecessor" },
            });
            try store.appendEdgesBatch(&.{
                .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(2) },
                .{ .id = .fromInt(2), .src = .fromInt(2), .rel = .depends_on, .dst = .fromInt(3) },
                .{ .id = .fromInt(3), .src = .fromInt(4), .rel = .blocks, .dst = .fromInt(2) },
                .{ .id = .fromInt(4), .src = .fromInt(5), .rel = .precedes, .dst = .fromInt(2) },
            });

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var ids = try collectFrontierStatusSnapshotNodeIds(std.testing.allocator, store, &node_view, .fromInt(1));
            defer ids.deinit(std.testing.allocator);
            var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
            defer seen.deinit();
            for (ids.items) |id| try seen.put(id.toInt(), {});
            inline for (1..6) |id| try std.testing.expect(seen.contains(id));
        }

        test "task frontier fallback claim read rolls back every allocation failure" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "fallback claim" });
            try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task.claimed_by_property, "allocation-test-agent");
            try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, task.claim_expires_ns_property, 1);

            var uncovered = try task.StatusSnapshot.initForNodeIds(std.testing.allocator, store, &.{});
            defer uncovered.deinit();
            try std.testing.checkAllAllocationFailures(
                std.testing.allocator,
                exerciseFrontierReadClaimAllocationFailure,
                .{ store, &uncovered },
            );
        }

        test "task lifecycle keeps stable kind and enforces terminal DAG semantics" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            inline for (&.{
                .{ "task", "root" },
                .{ "task", "dependency" },
                .{ "task", "consumer" },
                .{ "task", "branch" },
                .{ "task", "branch child" },
                .{ "task", "failed dependency" },
                .{ "task", "failed consumer" },
                .{ "verification", "proof" },
                .{ "fix", "legacy-looking proof" },
            }) |node| {
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-node", db_path, node[0], node[1] }, &out, std.testing.allocator, std.testing.io);
            }
            inline for (&.{
                .{ "1", "contains", "2" },
                .{ "1", "contains", "3" },
                .{ "1", "contains", "4" },
                .{ "4", "contains", "5" },
                .{ "1", "contains", "6" },
                .{ "1", "contains", "7" },
                .{ "3", "depends_on", "2" },
                .{ "7", "depends_on", "6" },
            }) |edge| {
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-edge", db_path, edge[0], edge[1], edge[2] }, &out, std.testing.allocator, std.testing.io);
            }

            var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            var dependency = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
            try std.testing.expectEqual(core.NodeKind.task, dependency.kind);
            try std.testing.expectEqual(task.Status.open, try task.statusForStoredNode(std.testing.allocator, store, dependency, try u128ToU64(persistentNowNs(std.testing.io))));
            dependency.deinit(std.testing.allocator);
            try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(9) }, "task_created_ns", 1);
            try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(9) }, "task_completed_ns", 2);
            store.deinit();

            // Lifecycle commands key off the stable physical kind.  Legacy evidence
            // timestamps do not turn a verification/fix node into a releasable task.
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "task-release", db_path, "8" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "task-release", db_path, "9" }, &out, std.testing.allocator, std.testing.io));

            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.TaskHasOpenChildren, run(&.{ "tinykg", "task-claim", db_path, "4", "--by", "agent-a" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.TaskNotReady, run(&.{ "tinykg", "task-claim", db_path, "3", "--by", "agent-a" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.TaskNotReady, run(&.{ "tinykg", "task-close", db_path, "3", "completed", "--force" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.TaskNotReady, run(&.{ "tinykg", "revise", db_path, "3", "verification", "must remain blocked" }, &out, std.testing.allocator, std.testing.io));

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-claim", db_path, "2", "--by", "agent-a" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.ClaimHeld, run(&.{ "tinykg", "revise", db_path, "2", "verification", "legacy close cannot steal" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.text = \"dependency\" RETURN n.status LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("claimed\n", out.buffer.items);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-release", db_path, "2", "--by", "agent-a" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task) WHERE n.text = \"dependency\" RETURN n.status LIMIT 1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("open\n", out.buffer.items);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-close", db_path, "2", "completed", "--evidence", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "status=completed\tidempotent=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_publishes=1") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-close", db_path, "2", "completed", "--evidence", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "status=completed\tidempotent=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_publishes=0") != null);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.InvalidTaskTransition, run(&.{ "tinykg", "task-claim", db_path, "2", "--by", "agent-a" }, &out, std.testing.allocator, std.testing.io));

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-packet", db_path, "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.startsWith(u8, out.buffer.items, "task_packet\t2\tstatus=completed\treadiness=-"));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.buffer.items, "verified_by_out"));
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.InvalidTaskTransition, run(&.{ "tinykg", "task-ready", db_path, "2" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-ancestry", db_path, "2", "--depth", "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.startsWith(u8, out.buffer.items, "task_ancestry\t2\tstatus=completed"));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "context-packet", db_path, "dependency", "--task", "2", "--limit", "2", "--format", "json" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"task_packet\":{\"task_id\":2,\"status\":\"completed\",\"readiness\":null") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-ready", db_path, "3" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("ready\n", out.buffer.items);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-claim", db_path, "3", "--by", "agent-b" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            const rejected_evidence = "wrong holder must not create this verification";
            try std.testing.expectError(error.ClaimHeld, run(&.{ "tinykg", "task-close", db_path, "3", "completed", "--by", "agent-a", "--evidence-text", rejected_evidence }, &out, std.testing.allocator, std.testing.io));
            // Authorization happens before evidence creation under the same store lock.
            // A rejected holder must leave neither a verification node nor an edge.
            var rejected_store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            var rejected_matches = try rejected_store.lookupNodesByTextLimited(std.testing.allocator, .verification, rejected_evidence, 2);
            try std.testing.expectEqual(@as(usize, 0), rejected_matches.items.len);
            rejected_matches.deinit(std.testing.allocator);
            rejected_store.deinit();
            out.buffer.clearRetainingCapacity();
            const accepted_evidence = "authorized close evidence";
            try run(&.{ "tinykg", "task-close", db_path, "3", "completed", "--by", "agent-b", "--evidence-text", accepted_evidence }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-close", db_path, "3", "completed", "--by", "agent-b", "--evidence-text", "terminal retry must be ignored" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-packet", db_path, "3", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, accepted_evidence) != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "terminal retry must be ignored") == null);

            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.TaskHasOpenChildren, run(&.{ "tinykg", "task-close", db_path, "4", "completed" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-close", db_path, "5", "failed" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.TaskHasOpenChildren, run(&.{ "tinykg", "task-close", db_path, "4", "completed" }, &out, std.testing.allocator, std.testing.io));

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-close", db_path, "6", "failed" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-ready", db_path, "7" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("missing_dependencies\n", out.buffer.items);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(error.TaskNotReady, run(&.{ "tinykg", "task-claim", db_path, "7", "--by", "agent-c" }, &out, std.testing.allocator, std.testing.io));

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "16" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "failed_task\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "status=failed\treadiness=blocked") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "branch_task\t") != null);

            store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            var completed = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
            defer completed.deinit(std.testing.allocator);
            try std.testing.expectEqual(core.NodeKind.task, completed.kind);
            try std.testing.expectEqual(task.Status.completed, try task.statusForStoredNode(std.testing.allocator, store, completed, try u128ToU64(persistentNowNs(std.testing.io))));
        }

        test "legacy revise publishes completion status and lease expiry in one delta frame" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "legacy close target" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "1", "verification", "legacy close complete" }, &out, std.testing.allocator, std.testing.io);

            const delta_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "property_payload.delta" });
            defer std.testing.allocator.free(delta_path);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, delta_path, std.testing.allocator, .limited(1024 * 1024));
            defer std.testing.allocator.free(bytes);
            var offset: usize = 0;
            var last_payload: []const u8 = &.{};
            while (offset < bytes.len) {
                if (bytes.len - offset < 32 or !std.mem.eql(u8, bytes[offset..][0..4], "TKPD")) return error.InvalidRecord;
                const payload_len = std.mem.readInt(u32, bytes[offset + 20 ..][0..4], .little);
                const payload_start = std.math.add(usize, offset, 32) catch return error.InvalidRecord;
                const frame_end = std.math.add(usize, payload_start, payload_len) catch return error.InvalidRecord;
                if (frame_end > bytes.len) return error.InvalidRecord;
                last_payload = bytes[payload_start..frame_end];
                offset = frame_end;
            }
            try std.testing.expect(std.mem.indexOf(u8, last_payload, "task_completed_ns") != null);
            try std.testing.expect(std.mem.indexOf(u8, last_payload, task.status_property) != null);
            try std.testing.expect(std.mem.indexOf(u8, last_payload, task.claim_expires_ns_property) != null);
        }

        test "task frontier limit bounds actionable leaves with truncation marker" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "leaf one" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "leaf two" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "leaf three" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "3" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "4" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "2" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf one") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf two") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "leaf three") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_task_truncated\tlimit=2") != null);
        }

        test "task context commands do not report task events as goal anchors" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "ship maturity fix" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "related_to", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "2", "prompt_adherence_ok", "--task", "1", "--note", "packet smoke" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "incoming", db_path, "2", "task_event" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event\t3\ttask_event prompt_adherence_ok") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "incoming", db_path, "1", "task_event" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event\t3\ttask_event prompt_adherence_ok") != null);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "task-frontier", db_path, "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event") == null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "3", "related_to", "1" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-packet", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);

            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "goal_anchor_out\t1\trelated_to\t2\tdocument\tworklog") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "goal_anchor_in") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event") == null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-ancestry", db_path, "1", "--depth", "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "goal_anchor_out\tlevel=0\t1\trelated_to\t2\tdocument\tworklog") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "goal_anchor_in") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event") == null);
        }

        test "task packet keeps recent verification evidence when bounded" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "ship maturity fix" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "verification", "old evidence" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "verification", "middle evidence" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "verification", "new evidence" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "verified_by", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "verified_by", "3" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "verified_by", "4" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-packet", db_path, "1", "--limit", "2" }, &out, std.testing.allocator, std.testing.io);
            const newest = std.mem.indexOf(u8, out.buffer.items, "verified_by_out\t3\tverified_by\t4\tverification\tnew evidence") orelse return error.TestExpectedEqual;
            const middle = std.mem.indexOf(u8, out.buffer.items, "verified_by_out\t2\tverified_by\t3\tverification\tmiddle evidence") orelse return error.TestExpectedEqual;
            try std.testing.expect(newest < middle);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified_by_out\t1\tverified_by\t2\tverification\told evidence") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "verified_by_out_truncated\tlimit=2\tscanned=3\trecent=1") != null);
        }

        test "task packet keeps recent child rounds when bounded" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "parent round task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "verification", "old child round" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "verification", "middle child round" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "verification", "new child round" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "3" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "4" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-packet", db_path, "1", "--limit", "2" }, &out, std.testing.allocator, std.testing.io);
            const newest = std.mem.indexOf(u8, out.buffer.items, "child_out\t3\tcontains\t4\tverification\tnew child round") orelse return error.TestExpectedEqual;
            const middle = std.mem.indexOf(u8, out.buffer.items, "child_out\t2\tcontains\t3\tverification\tmiddle child round") orelse return error.TestExpectedEqual;
            try std.testing.expect(newest < middle);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_out\t1\tcontains\t2\tverification\told child round") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "child_out_truncated\tlimit=2\tscanned=3\trecent=1") != null);
        }

        test "task packet json meta returns task subgraph envelope without changing text output" {
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
                    .{ .id = .fromInt(1), .kind = .task, .text = "root task" },
                    .{ .id = .fromInt(2), .kind = .task, .text = "parent task" },
                    .{ .id = .fromInt(3), .kind = .task, .text = "dependency task" },
                    .{ .id = .fromInt(4), .kind = .task, .text = "blocker task" },
                    .{ .id = .fromInt(5), .kind = .verification, .text = "child round" },
                    .{ .id = .fromInt(6), .kind = .verification, .text = "verified evidence" },
                });
                try store.appendEdgesBatch(&.{
                    .{ .id = .fromInt(1), .src = .fromInt(2), .rel = .contains, .dst = .fromInt(1) },
                    .{ .id = .fromInt(2), .src = .fromInt(1), .rel = .related_to, .dst = .fromInt(3) },
                    .{ .id = .fromInt(3), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(3) },
                    .{ .id = .fromInt(4), .src = .fromInt(4), .rel = .blocks, .dst = .fromInt(1) },
                    .{ .id = .fromInt(5), .src = .fromInt(1), .rel = .contains, .dst = .fromInt(5) },
                    .{ .id = .fromInt(6), .src = .fromInt(1), .rel = .verified_by, .dst = .fromInt(6) },
                });
            }

            var text_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer text_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "task-packet", db_path, "1", "--limit", "1" }, &text_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, text_out.buffer.items, "task_packet\t1\tstatus=open\treadiness=blocked\tlimit=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, text_out.buffer.items, "task\t1\ttask\troot task") != null);

            var json_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer json_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "task-packet", db_path, "1", "--format", "json", "--meta", "--limit", "2", "--max-nodes", "6", "--max-edges", "8", "--max-chars", "128" }, &json_out, std.testing.allocator, std.testing.io);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.buffer.items, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("tinykg-agent-retrieval-v1", parsed.value.object.get("schema_version").?.string);
            try std.testing.expectEqualStrings("task-packet", parsed.value.object.get("mode").?.string);
            try std.testing.expectEqualStrings("blocked", parsed.value.object.get("query").?.object.get("readiness").?.string);
            try std.testing.expectEqualStrings("open", parsed.value.object.get("query").?.object.get("status").?.string);
            try std.testing.expectEqual(@as(i64, 6), parsed.value.object.get("summary").?.object.get("node_count").?.integer);
            try std.testing.expectEqual(@as(i64, 5), parsed.value.object.get("summary").?.object.get("edge_count").?.integer);
            try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("summary").?.object.get("backref_count").?.integer);
            try std.testing.expect(!parsed.value.object.get("summary").?.object.get("truncated").?.bool);
            try std.testing.expectEqual(@as(i64, 75), parsed.value.object.get("summary").?.object.get("used_chars").?.integer);
            try std.testing.expect(parsed.value.object.get("nodes").?.array.items[0].object.get("text") == null);
            const edges = parsed.value.object.get("edges").?.array;
            try std.testing.expectEqualStrings("parent_in", edges.items[0].object.get("view_role").?.string);
            try std.testing.expectEqualStrings("incoming", edges.items[0].object.get("direction").?.string);
            try std.testing.expectEqualStrings("goal_anchor_out", edges.items[1].object.get("view_role").?.string);
            const backrefs = parsed.value.object.get("backrefs").?.array;
            try std.testing.expectEqualStrings("depends_on_out", backrefs.items[0].object.get("view_role").?.string);

            json_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-packet", db_path, "1", "--format", "json", "--meta", "--limit", "2", "--max-nodes", "3", "--max-edges", "8", "--max-chars", "128" }, &json_out, std.testing.allocator, std.testing.io);
            var truncated = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.buffer.items, .{});
            defer truncated.deinit();
            try std.testing.expect(truncated.value.object.get("summary").?.object.get("truncated").?.bool);
            try std.testing.expectEqualStrings("max_nodes", truncated.value.object.get("summary").?.object.get("truncate_reason").?.string);
        }

        test "context plan and packet compose search task graph neighbors and markdown previews" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const markdown_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "context.md" });
            defer std.testing.allocator.free(markdown_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "context packet root task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "verification", "context packet verification evidence" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "verified_by", "2" }, &out, std.testing.allocator, std.testing.io);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = markdown_path,
                .data =
                \\# Context Packet Doc
                \\
                \\Markdown preview anchor text should stay outside a two-line preview.
                \\
                ,
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "import-md-doc", db_path, markdown_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "document=3") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "3" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{
                "tinykg",      "context-plan", db_path,                    "context",     "packet",
                "--task",      "1",            "--node",                   "3",           "--limit",
                "2",           "--max-nodes",  "6",                        "--max-edges", "8",
                "--max-chars", "5000",         "--markdown-preview-lines", "2",           "--timeout-ms",
                "60000",
            }, &out, std.testing.allocator, std.testing.io);
            var parsed_plan = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffer.items, .{});
            defer parsed_plan.deinit();
            try std.testing.expectEqualStrings("tinykg-agent-retrieval-v1", parsed_plan.value.object.get("schema_version").?.string);
            try std.testing.expectEqualStrings("context-plan", parsed_plan.value.object.get("mode").?.string);
            try std.testing.expectEqual(@as(i64, 2), parsed_plan.value.object.get("budget").?.object.get("max_search_hits").?.integer);
            try std.testing.expectEqualStrings("search -> focus metadata -> task packet -> neighbors -> markdown previews", parsed_plan.value.object.get("plan").?.object.get("retrieval_order").?.string);
            const plan_continuations = parsed_plan.value.object.get("continuations").?.array;
            try std.testing.expectEqual(@as(usize, 1), plan_continuations.items.len);
            const plan_command = plan_continuations.items[0].object.get("command").?.array;
            try std.testing.expectEqualStrings("tinykg", plan_command.items[0].string);
            try std.testing.expectEqualStrings("context-packet", plan_command.items[1].string);
            try std.testing.expectEqualStrings(db_path, plan_command.items[2].string);
            try std.testing.expectEqualStrings("context packet", plan_command.items[3].string);

            out.buffer.clearRetainingCapacity();
            try run(&.{
                "tinykg",      "context-packet", db_path,                    "context",     "packet",
                "--task",      "1",              "--node",                   "3",           "--limit",
                "2",           "--max-nodes",    "6",                        "--max-edges", "8",
                "--max-chars", "5000",           "--markdown-preview-lines", "2",           "--timeout-ms",
                "60000",
            }, &out, std.testing.allocator, std.testing.io);
            var parsed_packet = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffer.items, .{});
            defer parsed_packet.deinit();
            try std.testing.expectEqualStrings("context-packet", parsed_packet.value.object.get("mode").?.string);
            try std.testing.expect(parsed_packet.value.object.get("search").?.object.get("summary").?.object.get("hit_count").?.integer > 0);
            try std.testing.expect(parsed_packet.value.object.get("focus_nodes").?.array.items.len >= 2);
            try std.testing.expectEqualStrings("ready", parsed_packet.value.object.get("task_packet").?.object.get("readiness").?.string);
            try std.testing.expect(parsed_packet.value.object.get("neighbor_subgraphs").?.array.items.len >= 2);
            const previews = parsed_packet.value.object.get("markdown_previews").?.array;
            try std.testing.expect(previews.items.len >= 1);
            const rendered = previews.items[0].object.get("rendered_markdown").?.object;
            try std.testing.expectEqual(@as(i64, 2), rendered.get("preview_lines").?.integer);
            try std.testing.expect(rendered.get("truncated").?.bool);
            try std.testing.expect(std.mem.indexOf(u8, rendered.get("preview").?.string, "Context Packet Doc") != null);
            try std.testing.expect(std.mem.indexOf(u8, rendered.get("preview").?.string, "Markdown preview anchor text") == null);
            try std.testing.expect(previews.items[0].object.get("node").?.object.get("text") == null);
            const packet_summary = parsed_packet.value.object.get("packet_summary").?.object;
            try std.testing.expect(!packet_summary.get("truncated").?.bool);
            try std.testing.expect(packet_summary.get("context_size").?.object.get("text_chars").?.integer > 0);
            try std.testing.expect(packet_summary.get("requested_context_size").?.object.get("text_chars").?.integer >= packet_summary.get("context_size").?.object.get("text_chars").?.integer);
            const packet_continuations = parsed_packet.value.object.get("continuations").?.array;
            try std.testing.expect(packet_continuations.items.len >= 2);
            var saw_neighbors_continuation = false;
            var saw_limit_recovery = false;
            for (packet_continuations.items) |continuation| {
                if (std.mem.eql(u8, continuation.object.get("action").?.string, "neighbors")) {
                    saw_neighbors_continuation = true;
                    try std.testing.expectEqualStrings("tinykg", continuation.object.get("command").?.array.items[0].string);
                }
                if (continuation.object.get("suggested_limit")) |suggested| {
                    saw_limit_recovery = true;
                    try std.testing.expect(suggested.integer > continuation.object.get("current_limit").?.integer);
                    const command = continuation.object.get("command").?.array;
                    var saw_limit = false;
                    for (command.items, 0..) |arg, index| {
                        if (std.mem.eql(u8, arg.string, "--limit")) {
                            saw_limit = true;
                            try std.testing.expectEqual(suggested.integer, try std.fmt.parseInt(i64, command.items[index + 1].string, 10));
                        }
                    }
                    try std.testing.expect(saw_limit);
                }
            }
            try std.testing.expect(saw_neighbors_continuation);
            try std.testing.expect(saw_limit_recovery);

            out.buffer.clearRetainingCapacity();
            try run(&.{
                "tinykg",       "context-packet", db_path,          "context",     "packet",
                "--limit",      "2",              "--max-postings", "1",           "--max-nodes",
                "2",            "--max-edges",    "2",              "--max-chars", "5000",
                "--timeout-ms", "60000",
            }, &out, std.testing.allocator, std.testing.io);
            var budgeted_packet = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffer.items, .{});
            defer budgeted_packet.deinit();
            const budgeted_summary = budgeted_packet.value.object.get("search").?.object.get("summary").?.object;
            try std.testing.expect(budgeted_summary.get("budget_exceeded").?.bool);
            try std.testing.expectEqualStrings("max_postings", budgeted_summary.get("truncate_reason").?.string);
            const budgeted_continuation = budgeted_packet.value.object.get("continuations").?.array.items[0].object;
            try std.testing.expectEqualStrings("context-packet", budgeted_continuation.get("action").?.string);
            try std.testing.expectEqual(@as(i64, 1), budgeted_continuation.get("current_max_postings").?.integer);
            try std.testing.expect(budgeted_continuation.get("postings_planned").?.integer > budgeted_continuation.get("current_max_postings").?.integer);
            const budgeted_command = budgeted_continuation.get("command").?.array;
            var saw_max_postings = false;
            for (budgeted_command.items, 0..) |arg, index| {
                if (std.mem.eql(u8, arg.string, "--max-postings")) {
                    saw_max_postings = true;
                    try std.testing.expectEqual(budgeted_continuation.get("postings_planned").?.integer, try std.fmt.parseInt(i64, budgeted_command.items[index + 1].string, 10));
                }
            }
            try std.testing.expect(saw_max_postings);

            out.buffer.clearRetainingCapacity();
            try run(&.{
                "tinykg",      "context-packet", db_path,       "context",     "packet",
                "--task",      "1",              "--node",      "3",           "--limit",
                "1",           "--max-postings", "100",         "--max-nodes", "2",
                "--max-edges", "2",              "--max-chars", "1",           "--markdown-preview-lines",
                "2",           "--timeout-ms",   "60000",
            }, &out, std.testing.allocator, std.testing.io);
            var tiny_packet = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffer.items, .{});
            defer tiny_packet.deinit();
            const tiny_summary = tiny_packet.value.object.get("packet_summary").?.object;
            try std.testing.expect(tiny_summary.get("truncated").?.bool);
            try std.testing.expectEqualStrings("max_chars", tiny_summary.get("truncate_reason").?.string);
            try std.testing.expectEqual(@as(i64, 1), tiny_summary.get("context_size").?.object.get("text_chars").?.integer);
            try std.testing.expect(tiny_summary.get("requested_context_size").?.object.get("text_chars").?.integer > tiny_summary.get("context_size").?.object.get("text_chars").?.integer);
            try std.testing.expect(tiny_packet.value.object.get("search").?.object.get("hits").?.array.items[0].object.get("node").?.object.get("name_truncated").?.bool);
            var saw_max_chars_recovery = false;
            for (tiny_packet.value.object.get("continuations").?.array.items) |continuation| {
                const obj = continuation.object;
                if (obj.get("suggested_max_chars")) |suggested| {
                    saw_max_chars_recovery = true;
                    try std.testing.expect(suggested.integer > obj.get("current_max_chars").?.integer);
                    const command = obj.get("command").?.array;
                    var saw_max_chars = false;
                    for (command.items, 0..) |arg, index| {
                        if (std.mem.eql(u8, arg.string, "--max-chars")) {
                            saw_max_chars = true;
                            try std.testing.expectEqual(suggested.integer, try std.fmt.parseInt(i64, command.items[index + 1].string, 10));
                        }
                    }
                    try std.testing.expect(saw_max_chars);
                }
            }
            try std.testing.expect(saw_max_chars_recovery);

            out.buffer.clearRetainingCapacity();
            try run(&.{
                "tinykg", "context-packet", db_path, "zzzxxyqwertyuiopasdfghjkl", "--timeout-ms", "60000",
            }, &out, std.testing.allocator, std.testing.io);
            var empty_packet = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffer.items, .{});
            defer empty_packet.deinit();
            const empty_continuation = empty_packet.value.object.get("continuations").?.array.items[0].object;
            try std.testing.expectEqualStrings("context-plan", empty_continuation.get("action").?.string);
            try std.testing.expectEqualStrings("context-plan", empty_continuation.get("command").?.array.items[1].string);
        }

        test "task metrics count task events linked through task_event" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "event metric task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "2", "related_to", "1" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_attempt", "--task", "2", "--note", "start" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_error", "--task", "2", "--note", "failed once" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "prompt_adherence_ok", "--task", "2", "--note", "used frontier" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "prompt_adherence_miss", "--task", "2", "--note", "missed once" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "task-frontier", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-frontier", db_path, "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event") == null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tincoming_task_event\tscanned_edges=4\ttruncated=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=task_write_error_rate\tattempts=1\terrors=1\trate_bps=10000") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=prompt_adherence_rate\tok=1\tmisses=1\trate_bps=5000") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unavailable\tmetric=task_write_error_rate") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unavailable\tmetric=prompt_adherence_rate") == null);
        }

        test "malformed task metric metadata does not masquerade as index corruption" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "metric root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "prompt_adherence_ok", "--note", "valid before corruption" }, &out, std.testing.allocator, std.testing.io);

            var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, "task_event_type", 7);

            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.InvalidTaskMetricEvent,
                run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io),
            );
        }

        test "task metrics treats write error as an attempted write sample" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "write error only task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "2", "related_to", "1" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_error", "--task", "2", "--note", "failed without explicit attempt" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tincoming_task_event\tscanned_edges=1\ttruncated=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=task_write_error_rate\tattempts=1\terrors=1\trate_bps=10000") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unavailable\tmetric=task_write_error_rate") == null);
        }

        test "task metrics aggregate task events from child workflow anchors" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "project worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "parent maturity task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "child round task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "2", "contains", "3" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_error", "--task", "3", "--note", "child failed once" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "3", "verification", "completed child round" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t2\tlimit=8\ttruncated=0\topen_tasks=0\tclaimed_tasks=0\tcompleted_tasks=1\tfailed_tasks=0\trework_error_events=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=0\topen_tasks=0\tclaimed_tasks=0\tcompleted_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=0\topen_tasks=0\tclaimed_tasks=0\tcompleted_tasks=1\tfailed_tasks=0\tlegacy_closed_verifications=0\tlegacy_closed_fixes=0\tother_nodes=0\tready=0\tblocked=0\tmissing_dependencies=0\tdepends_on_edges=0\tblocker_edges=0\tverified_by_edges=0\trework_error_events=1\tnested_event_edges=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=task_write_error_rate\tattempts=1\terrors=1\trate_bps=10000") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "unavailable\tmetric=task_write_error_rate") == null);
        }

        test "task metrics do not double count child events rooted at the parent" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "parent event root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "child event target" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_error", "--task", "2", "--note", "same root and child target" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=0\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tincoming_task_event\tscanned_edges=1\ttruncated=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=task_write_error_rate\tattempts=1\terrors=1\trate_bps=10000") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "attempts=2\terrors=2") == null);
        }

        test "task metrics aggregate unique tasks and events across relation scopes" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "metrics root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "shared task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "2", "related_to", "1" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_error", "--task", "2", "--note", "one failure" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "3", "references", "2" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "16" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t1\tlimit=16\ttruncated=0\topen_tasks=1\tclaimed_tasks=0\tcompleted_tasks=0\tfailed_tasks=0\trework_error_events=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=0\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tincoming_related_to\tscanned_edges=1\ttruncated=0\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=task_write_error_rate\tattempts=1\terrors=1\trate_bps=10000") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=rework_density\ttasks=1\trework_error_events=1\trate_bps=10000") != null);
        }

        test "task metrics report truncation for bounded child anchor events" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "parent metrics task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "child event-heavy task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "project event root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "3", "prompt_adherence_ok", "--task", "2", "--note", "first child event" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "3", "prompt_adherence_ok", "--task", "2", "--note", "second child event" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t1\tlimit=1\ttruncated=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=1\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=1\topen_tasks=1\tclaimed_tasks=0\tcompleted_tasks=0\tfailed_tasks=0\tlegacy_closed_verifications=0\tlegacy_closed_fixes=0\tother_nodes=0\tready=1\tblocked=0\tmissing_dependencies=0\tdepends_on_edges=0\tblocker_edges=0\tverified_by_edges=0\trework_error_events=0\tnested_event_edges=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=prompt_adherence_rate\tok=1\tmisses=0\trate_bps=10000") != null);
        }

        test "task metrics bound non-matching per-task detail scans globally" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "metrics root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "detail-heavy child" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);

            for (0..task_metric_detail_budget_multiplier + 1) |index| {
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-node", db_path, "observation", "non-error detail" }, &out, std.testing.allocator, std.testing.io);
                var id_buffer: [32]u8 = undefined;
                const observation_id = try std.fmt.bufPrint(&id_buffer, "{}", .{index + 3});
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-edge", db_path, observation_id, "related_to", "2" }, &out, std.testing.allocator, std.testing.io);
            }

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t1\tlimit=1\ttruncated=1\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "budget\tscope=detail_edges\tscanned_edges=16\tlimit=16\ttruncated=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=1") != null);
        }

        test "task metrics charge readiness traversal to the shared detail budget" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "metrics root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "dependency-heavy child" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);

            for (0..task_metric_detail_budget_multiplier + 1) |index| {
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-node", db_path, "verification", "satisfied dependency" }, &out, std.testing.allocator, std.testing.io);
                var id_buffer: [32]u8 = undefined;
                const dependency_id = try std.fmt.bufPrint(&id_buffer, "{}", .{index + 3});
                out.buffer.clearRetainingCapacity();
                try run(&.{ "tinykg", "add-edge", db_path, "2", "depends_on", dependency_id }, &out, std.testing.allocator, std.testing.io);
            }

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t1\tlimit=1\ttruncated=1\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "budget\tscope=detail_edges\tscanned_edges=16\tlimit=16\ttruncated=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=1") != null);
        }

        test "task metrics exact event limit in final relation is not truncated" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "metrics root" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "child" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "error_event", "single rework" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "3", "references", "2" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t1\tlimit=1\ttruncated=0\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "rework_error_events=1") != null);
        }

        test "task metrics reports aggregate truncation in header" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "first task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "second task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "contains", "3" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_metrics\t1\tlimit=1\ttruncated=1\topen_tasks=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tchild_contains\tscanned_edges=1\ttruncated=1") != null);
        }

        test "task event metadata recovery rolls back every allocation failure" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .error_event, .text = "recoverable event" });
            _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
                .{ .owner = .{ .node = .fromInt(1) }, .key = "schema_type", .value = .{ .string = "task_event" } },
                .{ .owner = .{ .node = .fromInt(1) }, .key = "task_event_type", .value = .{ .string = "write_error" } },
                .{ .owner = .{ .node = .fromInt(1) }, .key = "task_root_id", .value = .{ .uint = 2 } },
                .{ .owner = .{ .node = .fromInt(1) }, .key = "task_id", .value = .{ .uint = 3 } },
                .{ .owner = .{ .node = .fromInt(1) }, .key = "dependency_relation", .value = .{ .string = "depends_on" } },
            });
            try std.testing.checkAllAllocationFailures(
                std.testing.allocator,
                exerciseTaskEventMetadataAllocationFailure,
                .{store},
            );
        }

        test "task event validates targets before mutating store" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.NotFound, run(&.{ "tinykg", "task-event", db_path, "99", "prompt_adherence_ok", "--note", "missing root" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "stats", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("nodes=0 edges=0\n", out.buffer.items);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.NotFound, run(&.{ "tinykg", "task-event", db_path, "1", "prompt_adherence_ok", "--task", "99", "--note", "missing task" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "stats", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("nodes=1 edges=0\n", out.buffer.items);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "not a task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(core.Error.InvalidId, run(&.{ "tinykg", "task-event", db_path, "1", "prompt_adherence_ok", "--task", "2", "--note", "wrong kind" }, &out, std.testing.allocator, std.testing.io));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "stats", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("nodes=2 edges=0\n", out.buffer.items);
        }

        test "task event accepts closed workflow anchors" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "closed task event target" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "revise", db_path, "2", "verification", "accepted task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "prompt_adherence_ok", "--task", "2", "--note", "closed anchor" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event node=3 type=prompt_adherence_ok") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "incoming", db_path, "2", "task_event" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "task_event\t3\ttask_event prompt_adherence_ok") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "2", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=prompt_adherence_rate\tok=1\tmisses=0\trate_bps=10000") != null);
        }

        test "task event avoids duplicate edge when root is task" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);

            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "same root task" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-event", db_path, "1", "write_attempt", "--task", "1", "--note", "same" }, &out, std.testing.allocator, std.testing.io);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "incoming", db_path, "1", "task_event" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "1\ttask_event\t2\ttask_event write_attempt") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\n2\ttask_event") == null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "task-metrics", db_path, "1", "--limit", "8" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "scope\tincoming_task_event\tscanned_edges=1\ttruncated=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "measured\tmetric=task_write_error_rate\tattempts=1\terrors=0\trate_bps=0") != null);
        }
    };
}
