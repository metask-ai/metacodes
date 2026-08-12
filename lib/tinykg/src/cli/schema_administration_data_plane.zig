/// Project-scoped schema policy, catalog validation/reconciliation and atomic schema migration.
pub fn SchemaAdministrationDataPlane(comptime Ops: type) type {
    return struct {
        const CliStoreLock = Ops.CliStoreLockValue;
        const ContentDigest = Ops.ContentDigestValue;
        const MigrationEdgeSpoolBuilder = Ops.MigrationEdgeSpoolBuilderValue;
        const MigrationEdgeStream = Ops.MigrationEdgeStreamValue;
        const MigrationPropertyBatch = Ops.MigrationPropertyBatchValue;
        const MigrationPropertyKeys = Ops.MigrationPropertyKeysValue;
        const MigrationPropertyLookup = Ops.MigrationPropertyLookupValue;
        const MigrationPropertySpool = Ops.MigrationPropertySpoolValue;
        const MigrationPropertyStream = Ops.MigrationPropertyStreamValue;
        const MigrationTargetPropertySpoolBuilder = Ops.MigrationTargetPropertySpoolBuilderValue;
        const NodeLocalGraphStats = Ops.NodeLocalGraphStatsValue;
        const QueryOutputWriter = Ops.QueryOutputWriterValue;
        const StoreManifestSummary = Ops.StoreManifestSummaryValue;
        const addBuiltinProfilesFromCsv = Ops.addBuiltinProfilesFromCsvValue;
        const agent = Ops.agentValue;
        const anyPathExists = Ops.anyPathExistsValue;
        const appendCatalogProfileLabel = Ops.appendCatalogProfileLabelValue;
        const appendSchemaDocumentProfilesToCatalog = Ops.appendSchemaDocumentProfilesToCatalogValue;
        const appendSchemaFileProfilesToCatalog = Ops.appendSchemaFileProfilesToCatalogValue;
        const builtin = Ops.builtinValue;
        const canonicalPathsEqual = Ops.canonicalPathsEqualValue;
        const canonicalProspectivePath = Ops.canonicalProspectivePathValue;
        const catalogProfilesCsvAlloc = Ops.catalogProfilesCsvAllocValue;
        const catalog_mod = Ops.catalog_modValue;
        const collectKnownEdgeProperties = Ops.collectKnownEdgePropertiesValue;
        const collectKnownNodeProperties = Ops.collectKnownNodePropertiesValue;
        const collectProjectDirectMemberIds = Ops.collectProjectDirectMemberIdsValue;
        const contentDigestForBytes = Ops.contentDigestForBytesValue;
        const copyMetaknowDeferredBasedOnSidecarForMigration = Ops.copyMetaknowDeferredBasedOnSidecarForMigrationValue;
        const core = Ops.coreValue;
        const createOwnedDirectory = Ops.createOwnedDirectoryValue;
        const currentGenerationLookupCandidateLimit = Ops.currentGenerationLookupCandidateLimitValue;
        const current_schema_version = Ops.current_schema_versionValue;
        const dag = Ops.dagValue;
        const ensureDeclaredEdgePropertiesRetained = Ops.ensureDeclaredEdgePropertiesRetainedValue;
        const ensureDeclaredNodePropertiesRetained = Ops.ensureDeclaredNodePropertiesRetainedValue;
        const existingTinyKgStorePath = Ops.existingTinyKgStorePathValue;
        const fileExists = Ops.fileExistsValue;
        const forEachVisibleEdgeRecordByNode = Ops.forEachVisibleEdgeRecordByNodeValue;
        const graph = Ops.graphValue;
        const isDeletedNodeTombstone = Ops.isDeletedNodeTombstoneValue;
        const loadSchemaRegistryBytes = Ops.loadSchemaRegistryBytesValue;
        const loadSchemaRegistryFile = Ops.loadSchemaRegistryFileValue;
        const metaknowDeferredBasedOnPath = Ops.metaknowDeferredBasedOnPathValue;
        const metaknowDeferredBasedOnPathForDb = Ops.metaknowDeferredBasedOnPathForDbValue;
        const metaknow_deferred_based_on_header_len = Ops.metaknow_deferred_based_on_header_lenValue;
        const nodeIsCurrentGeneration = Ops.nodeIsCurrentGenerationValue;
        const parseSchemaFileBytes = Ops.parseSchemaFileBytesValue;
        const query = Ops.queryValue;
        const readSchemaFileBytesAlloc = Ops.readSchemaFileBytesAllocValue;
        const readStoreManifestSummary = Ops.readStoreManifestSummaryValue;
        const renamePath = Ops.renamePathValue;
        const rewriteTransactionMarkerFormatForTest = Ops.rewriteTransactionMarkerFormatForTestValue;
        const run = Ops.runValue;
        const schema = Ops.schemaValue;
        const schemaEdgeEndpointCheck = Ops.schemaEdgeEndpointCheckValue;
        const schema_arguments = Ops.schema_argumentsValue;
        const schema_migration_publish_lock_suffix = Ops.schema_migration_publish_lock_suffixValue;
        const schema_migration_staging_suffix = Ops.schema_migration_staging_suffixValue;
        const schema_migration_transaction_marker_file = Ops.schema_migration_transaction_marker_fileValue;
        const schema_migration_transaction_marker_format = Ops.schema_migration_transaction_marker_formatValue;
        const schema_migration_transaction_marker_legacy_format = Ops.schema_migration_transaction_marker_legacy_formatValue;
        const schema_reconciliation = Ops.schema_reconciliationValue;
        const std = Ops.stdValue;
        const storage = Ops.storageValue;
        const storeContentIdentity = Ops.storeContentIdentityValue;
        const syncExportDirectoryTree = Ops.syncExportDirectoryTreeValue;
        const syncParentDirectory = Ops.syncParentDirectoryValue;
        const task = Ops.taskValue;
        const transactionMarkerHasFormatForTest = Ops.transactionMarkerHasFormatForTestValue;
        const validateSchemaMigratePathRelationship = Ops.validateSchemaMigratePathRelationshipValue;
        const validateSchemaMigratePaths = Ops.validateSchemaMigratePathsValue;
        const version = Ops.versionValue;
        const writeJsonString = Ops.writeJsonStringValue;
        const writeMetaknowDeferredBasedOnForwardPairsSidecar = Ops.writeMetaknowDeferredBasedOnForwardPairsSidecarValue;
        const writeNodeKindNameWithSchema = Ops.writeNodeKindNameWithSchemaValue;
        const writeRecoverableTransactionMarker = Ops.writeRecoverableTransactionMarkerValue;
        const writeRelKindNameWithSchema = Ops.writeRelKindNameWithSchemaValue;
        const writeStoreManifest = Ops.writeStoreManifestValue;

        const SchemaScopePolicy = struct {
            schema_type: []u8, // owned
            project_ids: std.ArrayList(u64), // scope 内 project node-id
            enforce_block: bool, // true=block(写时拒绝),false=report(仅审计)
            fn deinit(self: *SchemaScopePolicy, allocator: std.mem.Allocator) void {
                allocator.free(self.schema_type);
                self.project_ids.deinit(allocator);
            }
        };

        /// 扫全店 schema_scope 政策节点(concept + schema_type=schema_scope),解析成政策列表。
        /// name = 被治理的 schema_type;scope_projects = JSON 整数数组;enforce = "block"|"report"。
        /// 调用方 deinit 每条 + 外层 list。
        fn collectSchemaScopePolicies(
            allocator: std.mem.Allocator,
            store: storage.Store,
        ) !std.ArrayList(SchemaScopePolicy) {
            var out = std.ArrayList(SchemaScopePolicy).empty;
            errdefer {
                for (out.items) |*p| p.deinit(allocator);
                out.deinit(allocator);
            }
            var iter = try store.nodeRecordsIterator(.concept);
            defer iter.deinit();
            while (try iter.next(allocator)) |stored_node| {
                var node = stored_node;
                defer node.deinit(allocator);
                if (isDeletedNodeTombstone(node)) continue;
                const st = try store.getNodeStringProperty(allocator, node.id, "schema_type");
                defer if (st) |s| allocator.free(s);
                if (st == null or !std.mem.eql(u8, st.?, "schema_scope")) continue;
                const name = (try store.getNodeStringProperty(allocator, node.id, "name")) orelse continue;
                defer allocator.free(name);
                const projs_json = (try store.getNodeStringProperty(allocator, node.id, "scope_projects")) orelse continue;
                defer allocator.free(projs_json);
                const enforce_str = try store.getNodeStringProperty(allocator, node.id, "enforce");
                defer if (enforce_str) |e| allocator.free(e);

                var ids = std.ArrayList(u64).empty;
                errdefer ids.deinit(allocator);
                try parseJsonUintArray(allocator, projs_json, &ids);
                // dupe 在 ids move 之前:dupe 失败时 ids 的 errdefer 正确释放 ids(无泄漏)。
                const type_owned = try allocator.dupe(u8, name);
                // 所有权移交 policy;**置空 ids 句柄让其 errdefer 变 no-op**(policy 已接管 backing)。
                // type_owned 无独立 errdefer(dupe 后到 move 之间无可失败点)→ 只由 policy.deinit 释放,
                // 不存在二次释放。append 失败:policy.deinit 释放两者;成功:所有权在 out(外层 errdefer)。
                var policy = SchemaScopePolicy{
                    .schema_type = type_owned,
                    .project_ids = ids,
                    .enforce_block = enforce_str != null and std.mem.eql(u8, enforce_str.?, "block"),
                };
                ids = std.ArrayList(u64).empty;
                if (out.append(allocator, policy)) |_| {} else |e| {
                    policy.deinit(allocator);
                    return e;
                }
            }
            return out;
        }

        /// 极简 JSON 整数数组解析(`[12, 47]` → {12,47})。只认十进制无符号整数,忽略空白/方括号/逗号。
        /// scope_projects 由本程序写(schema-scope 命令),格式受控;不需要通用 JSON parser。
        fn parseJsonUintArray(allocator: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u64)) !void {
            var i: usize = 0;
            while (i < s.len) {
                const c = s[i];
                if (c >= '0' and c <= '9') {
                    const start = i;
                    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
                    // 用 parseInt 解析整段:溢出/超范围 → 跳过该数(不 panic、不 wrap),坏输入自食其果。
                    const v = std.fmt.parseInt(u64, s[start..i], 10) catch continue;
                    try out.append(allocator, v);
                } else {
                    i += 1;
                }
            }
        }

        const schema_scope_member_cap: usize = 100_000;

        /// 某政策的 **allowed 节点集** = scope 内每个 project 的"边界即停下行成员集"的并集。
        /// 一个受限 schema_type 的节点,只要落在这个 allowed 集里 = 合法(任一 scope project 内即可,
        /// 无继承);不在 = 违规。governance / block-at-write / schema-scope 回显**共用此单一真相源**。
        /// 悬挂 project id(不存在/tombstone)自然贡献空集,dangling_out 计数(不静默)。
        pub fn schemaScopeAllowedSet(
            allocator: std.mem.Allocator,
            store: storage.Store,
            project_ids: []const u64,
            dangling_out: ?*u64,
        ) !std.AutoHashMap(u64, void) {
            var allowed = std.AutoHashMap(u64, void).init(allocator);
            errdefer allowed.deinit();
            for (project_ids) |pid| {
                const maybe_node = store.readNodeById(allocator, core.NodeId.fromInt(pid)) catch {
                    if (dangling_out) |d| d.* += 1;
                    continue;
                };
                if (maybe_node) |stored| {
                    var n = stored;
                    const bad = n.kind != .project or isDeletedNodeTombstone(n);
                    n.deinit(allocator);
                    if (bad) {
                        if (dangling_out) |d| d.* += 1;
                        continue;
                    }
                } else {
                    if (dangling_out) |d| d.* += 1;
                    continue;
                }
                var members = try collectProjectDirectMemberIds(allocator, store, core.NodeId.fromInt(pid), schema_scope_member_cap, null);
                defer members.deinit();
                var it = members.keyIterator();
                while (it.next()) |k| try allowed.put(k.*, {});
            }
            return allowed;
        }

        /// block-at-write(enforce=block):把 node_id 挂到 parent_node_id 前,若 node 的 schema_type
        /// 被声明为 block 档且违反 scope → 返回 error.SchemaProjectScopeViolation,让 govern-node 原子失败。
        /// 判定:node 挂上后其最近 project = parent 的最近 project;等价于
        /// `parent ∈ scope.project_ids`(parent 本身是 scope project)或 `parent ∈ allowed_set`
        /// (parent 的最近 project 是 scope project)→ 合法,否则违规。
        /// 只对**声明为 block 的 schema_type** 付出写时代价(policy 全局少,allowed 集只算 scope 内 project)。
        pub fn enforceSchemaScopeAtWrite(
            allocator: std.mem.Allocator,
            store: storage.Store,
            node_id: core.NodeId,
            parent_node_id: core.NodeId,
        ) !void {
            const st = try store.getNodeStringProperty(allocator, node_id, "schema_type");
            defer if (st) |s| allocator.free(s);
            const schema_type = st orelse return; // 无 schema_type → 不治理
            // schema_scope 政策节点自身 / project 不受治理
            if (std.mem.eql(u8, schema_type, "schema_scope") or std.mem.eql(u8, schema_type, "project")) return;

            // Linus P1 perf 修:**定向索引查找**该 schema_type 的政策节点(text="schema_scope:<type>"),
            // O(1) 而非全店扫 concept。无政策 / 非 block 档 → 快速返回,写路径零额外成本(base 类型/未治理类型)。
            var policy = (try findSchemaScopePolicy(allocator, store, schema_type)) orelse return;
            defer policy.deinit(allocator);
            if (!policy.enforce_block) return; // report 档:写不拦(仅 governance 审计)

            for (policy.project_ids.items) |pid| {
                if (pid == parent_node_id.toInt()) return; // parent 本身是 scope project → 合法
            }
            var allowed = try schemaScopeAllowedSet(allocator, store, policy.project_ids.items, null);
            defer allowed.deinit();
            if (allowed.contains(parent_node_id.toInt())) return; // parent 最近 project 是 scope project
            return error.SchemaProjectScopeViolation; // parent 最近 project 不在 scope
        }

        /// 定向查找某 schema_type 的政策节点(concept + text="schema_scope:<type>")→ 解析成政策。
        /// 无 → null。走文本索引,O(1),写路径用(避免全 concept 扫描)。调用方 deinit。
        fn findSchemaScopePolicy(
            allocator: std.mem.Allocator,
            store: storage.Store,
            schema_type: []const u8,
        ) !?SchemaScopePolicy {
            const policy_text = try std.fmt.allocPrint(allocator, "schema_scope:{s}", .{schema_type});
            defer allocator.free(policy_text);
            var matches = try store.lookupNodesByTextLimited(allocator, .concept, policy_text, 4);
            defer {
                for (matches.items) |*n| n.deinit(allocator);
                matches.deinit(allocator);
            }
            for (matches.items) |*n| {
                if (!try nodeIsCurrentGeneration(store, n.id)) continue;
                const stv = try store.getNodeStringProperty(allocator, n.id, "schema_type");
                defer if (stv) |s| allocator.free(s);
                if (stv == null or !std.mem.eql(u8, stv.?, "schema_scope")) continue;
                const projs_json = (try store.getNodeStringProperty(allocator, n.id, "scope_projects")) orelse continue;
                defer allocator.free(projs_json);
                const enforce_str = try store.getNodeStringProperty(allocator, n.id, "enforce");
                defer if (enforce_str) |e| allocator.free(e);
                var ids = std.ArrayList(u64).empty;
                errdefer ids.deinit(allocator);
                try parseJsonUintArray(allocator, projs_json, &ids);
                const type_owned = try allocator.dupe(u8, schema_type);
                const policy = SchemaScopePolicy{
                    .schema_type = type_owned,
                    .project_ids = ids,
                    .enforce_block = enforce_str != null and std.mem.eql(u8, enforce_str.?, "block"),
                };
                ids = std.ArrayList(u64).empty; // move 完成:errdefer 变 no-op(防 double-free)
                return policy;
            }
            return null;
        }

        /// schema-scope 的 --project spec 解析:纯数字 → 当 node-id(校验是 project);否则当 project name
        /// (lookupNodesByTextLimited kind=.project)。返回 project node-id;找不到/非 project → 错误。
        pub fn resolveProjectSpec(allocator: std.mem.Allocator, store: storage.Store, spec: []const u8) !u64 {
            var all_digits = spec.len > 0;
            for (spec) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                const id = std.fmt.parseInt(u64, spec, 10) catch return error.InvalidRecord;
                const maybe = try store.readNodeById(allocator, core.NodeId.fromInt(id));
                if (maybe) |stored| {
                    var n = stored;
                    const ok = n.kind == .project and !isDeletedNodeTombstone(n);
                    n.deinit(allocator);
                    if (!ok) return error.InvalidRecord;
                    return id;
                }
                return error.NotFound;
            }
            const candidate_limit = currentGenerationLookupCandidateLimit(1);
            var matches = try store.lookupNodesByTextLimited(allocator, .project, spec, candidate_limit);
            defer {
                for (matches.items) |*n| n.deinit(allocator);
                matches.deinit(allocator);
            }
            for (matches.items) |*n| {
                if (!try nodeIsCurrentGeneration(store, n.id)) continue;
                return n.id.toInt();
            }
            return error.NotFound;
        }

        pub fn nodeLocalGraphStats(store: storage.Store, node_id: core.NodeId) !NodeLocalGraphStats {
            return .{
                .out_degree = try countNodeIncidentEdges(store, .src, node_id),
                .in_degree = try countNodeIncidentEdges(store, .dst, node_id),
            };
        }

        fn countNodeIncidentEdges(store: storage.Store, order: storage.EdgeIndexOrder, node_id: core.NodeId) !usize {
            const CountContext = struct {
                count: usize = 0,

                fn visit(self: *@This(), record: storage.EdgeIndexRecord) !bool {
                    _ = record;
                    self.count = std.math.add(usize, self.count, 1) catch return error.RecordTooLarge;
                    return false;
                }
            };
            var context = CountContext{};
            _ = try store.forEachVisibleEdgeIndexRecordByNode(
                store.allocator,
                order,
                node_id,
                null,
                std.math.maxInt(usize),
                &context,
                CountContext.visit,
            );

            // Node metadata reports the complete logical degree. Deferred based_on
            // edges are not physical storage records, so add their exact count from
            // the sidecar without allocating its targets.
            const deferred_path = try query.metaknowDeferredBasedOnPath(store.allocator, store);
            defer store.allocator.free(deferred_path);
            const direction: query.MetaknowDeferredBasedOnDirection = switch (order) {
                .src => .forward,
                .dst => .reverse,
                .id => return core.Error.Unsupported,
            };
            var deferred = try query.readMetaknowDeferredBasedOnTargets(store.allocator, store.io, deferred_path, node_id, 0, direction);
            defer deferred.deinit(store.allocator);
            if (deferred.targets.len != 0) return error.InvalidRecord;
            context.count = std.math.add(usize, context.count, deferred.total_count) catch return error.RecordTooLarge;
            return context.count;
        }

        pub fn nodeDeprecatedBy(store: storage.Store, node_id: core.NodeId) !?core.NodeId {
            const DeprecatedContext = struct {
                replacement: ?core.NodeId = null,

                fn visit(self: *@This(), record: storage.EdgeIndexRecord) !bool {
                    self.replacement = .fromInt(record.dst);
                    return true;
                }
            };
            var context = DeprecatedContext{};
            _ = try forEachVisibleEdgeRecordByNode(store.allocator, store, .src, node_id, .deprecated_by, &context, DeprecatedContext.visit);
            return context.replacement;
        }

        pub fn writeMarkdownInlineText(writer: *QueryOutputWriter, text: []const u8) !void {
            for (text) |byte| {
                switch (byte) {
                    '\n', '\r', '\t' => try writer.writeAll(" "),
                    '`' => try writer.writeAll("'"),
                    else => {
                        const single = [_]u8{byte};
                        try writer.writeAll(&single);
                    },
                }
            }
        }

        pub fn renderKindListWithSchema(writer: anytype, registry: schema.Registry) !void {
            var index: usize = 0;
            while (index < registry.nodeTypeCount()) : (index += 1) {
                const info = registry.nodeTypeInfo(index).?;
                try writer.print("type id={} name={s}", .{ info.id, info.name });
                try renderTypeParents(writer, registry, info.parents, .node);
                const descendants = try registry.nodeDescendants(info.id);
                try writer.print(" descendant_count={}\n", .{descendants.count()});
            }
        }

        pub fn renderRelListWithSchema(writer: anytype, registry: schema.Registry) !void {
            var index: usize = 0;
            while (index < registry.relationTypeCount()) : (index += 1) {
                const info = registry.relationTypeInfo(index).?;
                try writer.print("type id={} name={s}", .{ info.id, info.name });
                try renderTypeParents(writer, registry, info.parents, .relation);
                const descendants = try registry.relationDescendants(info.id);
                try writer.print(" descendant_count={} class={s}\n", .{ descendants.count(), info.class.label() });
            }
        }

        pub fn renderSchemaInfo(writer: anytype, registry: schema.Registry, schema_label: []const u8) !void {
            try writer.print(
                "schema={s}\nnode_types={}\nrelation_types={}\nnode_properties={}\nrelation_properties={}\nrelation_compositions={}\nmax_node_types={}\nmax_relation_types={}\nmax_inheritance_depth={}\nmax_direct_parents={}\nnode_descendant_fast_cap={}\nrelation_descendant_fast_cap={}\n",
                .{
                    schema_label,
                    registry.nodeTypeCount(),
                    registry.relationTypeCount(),
                    schemaNodePropertyCount(registry),
                    schemaRelationPropertyCount(registry),
                    registry.relationCompositionCount(),
                    schema.max_node_types,
                    schema.max_relation_types,
                    schema.max_inheritance_depth,
                    schema.max_direct_parents,
                    schema.node_descendant_fast_cap,
                    schema.relation_descendant_fast_cap,
                },
            );
            try renderSchemaRelationClassCounts(writer, registry);
        }

        fn schemaNodePropertyCount(registry: schema.Registry) usize {
            var total: usize = 0;
            var index: usize = 0;
            while (index < registry.nodeTypeCount()) : (index += 1) {
                const info = registry.nodeTypeInfo(index).?;
                total += registry.nodePropertyCount(info.id);
            }
            return total;
        }

        fn schemaRelationPropertyCount(registry: schema.Registry) usize {
            var total: usize = 0;
            var index: usize = 0;
            while (index < registry.relationTypeCount()) : (index += 1) {
                const info = registry.relationTypeInfo(index).?;
                total += registry.relationPropertyCount(info.id);
            }
            return total;
        }

        fn renderSchemaRelationClassCounts(writer: anytype, registry: schema.Registry) !void {
            var counts = [_]u64{0} ** @typeInfo(schema.RelationClass).@"enum".fields.len;
            var index: usize = 0;
            while (index < registry.relationTypeCount()) : (index += 1) {
                const info = registry.relationTypeInfo(index).?;
                counts[@intFromEnum(info.class)] += 1;
            }
            inline for (@typeInfo(schema.RelationClass).@"enum".fields) |field| {
                const relation_class: schema.RelationClass = @enumFromInt(field.value);
                try writer.print("relation_class_count {s}={}\n", .{ relation_class.label(), counts[field.value] });
            }
        }

        const TypeParentDomain = enum { node, relation };

        fn renderTypeParents(writer: anytype, registry: schema.Registry, parents: []const u16, domain: TypeParentDomain) !void {
            try writer.writeAll(" parents=");
            if (parents.len == 0) {
                try writer.writeAll("-");
                return;
            }
            for (parents, 0..) |parent_id, i| {
                if (i > 0) try writer.writeAll(",");
                const name = switch (domain) {
                    .node => registry.nodeTypeNameById(parent_id),
                    .relation => registry.relationTypeNameById(parent_id),
                };
                if (name) |parent_name| {
                    try writer.print("{s}", .{parent_name});
                } else {
                    try writer.print("#{}", .{parent_id});
                }
            }
        }

        fn parseFlag(args: []const []const u8, flag: []const u8) bool {
            for (args) |arg| {
                if (std.mem.eql(u8, arg, flag)) return true;
            }
            return false;
        }

        const ParsedSchemaCatalogArgs = schema_arguments.Catalog;
        pub const ParsedSchemaMigrateArgs = schema_arguments.Migration;
        const ParsedSchemaReconcileArgs = struct {
            db_path: []const u8,
            schema_path: []const u8,
            plan_path: []const u8,
            profiles: ?[]const u8,
        };

        pub fn renderSchemaShow(allocator: std.mem.Allocator, io: std.Io, writer: anytype, store: storage.Store, want_json: bool) !void {
            _ = allocator;
            _ = io;
            const maybe_cat = try store.readCatalog();
            if (maybe_cat == null) {
                if (want_json) {
                    try writer.writeAll("{\"catalog\":\"none\",\"format_version\":0}\n");
                } else {
                    try writer.writeAll("catalog=none\nformat_version=0\n");
                }
                return;
            }
            var cat = maybe_cat.?;
            defer cat.deinit();
            if (want_json) {
                try renderCatalogJson(writer, cat);
            } else {
                try renderCatalogText(writer, cat);
            }
        }

        fn renderCatalogText(writer: anytype, cat: catalog_mod.Catalog) !void {
            try writer.print(
                "catalog=embedded\nformat_version={}\nrevision={}\nnode_types={}\nrelation_types={}\nretired_types={}\nprofiles={}\n",
                .{
                    cat.format_version,
                    cat.revision,
                    cat.registry.nodeTypeCount(),
                    cat.registry.relationTypeCount(),
                    cat.retired.items.len,
                    cat.profiles.items.len,
                },
            );
            var ni: usize = 0;
            while (cat.registry.nodeTypeInfo(ni)) |info| : (ni += 1) {
                try writer.print("node_type id={} name={s} parents=", .{ info.id, info.name });
                try renderParentIds(writer, cat.registry, info.parents, .node);
                try writer.writeAll("\n");
                var pi: usize = 0;
                while (cat.registry.nodePropertyInfo(info.id, pi)) |prop| : (pi += 1) {
                    try renderCatalogPropertyText(writer, "node_property", prop);
                }
            }
            var ri: usize = 0;
            while (cat.registry.relationTypeInfo(ri)) |info| : (ri += 1) {
                try writer.print("relation_type id={} name={s} class={s} parents=", .{ info.id, info.name, info.class.label() });
                try renderParentIds(writer, cat.registry, info.parents, .relation);
                const endpoint = cat.registry.relationEndpointRuleById(info.id) orelse return error.InvalidRecord;
                try writer.writeAll(" endpoint_src=");
                try renderCatalogNodeTypeSetText(writer, cat.registry, endpoint.src);
                try writer.writeAll(" endpoint_dst=");
                try renderCatalogNodeTypeSetText(writer, cat.registry, endpoint.dst);
                try writer.writeAll(" composition=");
                try renderCatalogCompositionText(writer, cat.registry.relationCompositionById(info.id));
                try writer.writeAll("\n");
                var pi: usize = 0;
                while (cat.registry.relationPropertyInfo(info.id, pi)) |prop| : (pi += 1) {
                    try renderCatalogPropertyText(writer, "relation_property", prop);
                }
            }
            for (cat.retired.items) |r| {
                try writer.print("retired_type id={} domain={s} name={s} retired_at_revision={}\n", .{ r.id, @tagName(r.domain), r.name, r.retired_at_revision });
            }
            for (cat.profiles.items) |label| {
                try writer.print("profile {s}\n", .{label});
            }
        }

        fn renderCatalogPropertyText(writer: anytype, label: []const u8, prop: schema.PropertyMeta) !void {
            try writer.print(
                "  {s} name={s} type={s} required={} nullable={} indexed={} searchable={} returned_by_default={} enum_values=",
                .{
                    label,
                    prop.name,
                    @tagName(prop.value_type),
                    @intFromBool(prop.required),
                    @intFromBool(prop.nullable),
                    @intFromBool(prop.indexed),
                    @intFromBool(prop.searchable),
                    @intFromBool(prop.returned_by_default),
                },
            );
            if (prop.enum_values.len == 0) {
                try writer.writeAll("-");
            } else {
                for (prop.enum_values, 0..) |value, index_pos| {
                    if (index_pos != 0) try writer.writeAll(",");
                    try writer.writeAll(value);
                }
            }
            try writer.writeAll("\n");
        }

        fn writeJsonStringRaw(writer: anytype, s: []const u8) !void {
            try writer.writeAll("\"");
            for (s) |c| {
                switch (c) {
                    '"', '\\' => {
                        try writer.writeAll("\\");
                        try writer.writeAll(&[_]u8{c});
                    },
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0...8, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{c}),
                    else => try writer.writeAll(&[_]u8{c}),
                }
            }
            try writer.writeAll("\"");
        }

        fn renderCatalogNodeTypeSetText(
            writer: anytype,
            registry: schema.Registry,
            maybe_types: ?schema.NodeTypeSet,
        ) !void {
            const types = maybe_types orelse {
                try writer.writeAll("*");
                return;
            };
            var first = true;
            var id: u16 = 0;
            while (id < schema.max_node_types) : (id += 1) {
                if (!types.containsId(id)) continue;
                if (!first) try writer.writeAll(",");
                first = false;
                if (registry.nodeTypeNameById(id)) |name| {
                    try writer.print("{s}#{}", .{ name, id });
                } else {
                    try writer.print("#{}", .{id});
                }
            }
            if (first) try writer.writeAll("-");
        }

        fn renderCatalogCompositionText(writer: anytype, maybe_composition: ?schema.CompositionMeta) !void {
            const composition = maybe_composition orelse {
                try writer.writeAll("none");
                return;
            };
            try writer.print(
                "enabled:{},owner:{},cardinality:{s},ordered_by:",
                .{
                    @intFromBool(composition.enabled),
                    @intFromBool(composition.owner),
                    composition.cardinality.label(),
                },
            );
            if (composition.ordered_by) |ordered_by| {
                try writer.writeAll(ordered_by);
            } else {
                try writer.writeAll("-");
            }
        }

        fn renderCatalogJson(writer: anytype, cat: catalog_mod.Catalog) !void {
            try writer.print(
                "{{\"catalog\":\"embedded\",\"format_version\":{},\"revision\":{},\"node_types\":[",
                .{ cat.format_version, cat.revision },
            );
            var ni: usize = 0;
            var first = true;
            while (cat.registry.nodeTypeInfo(ni)) |info| : (ni += 1) {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.print("{{\"id\":{},\"name\":", .{info.id});
                try writeJsonStringRaw(writer, info.name);
                try writer.writeAll(",\"parents\":");
                try renderCatalogParentRefsJson(writer, cat.registry, info.parents, .node);
                try writer.writeAll(",\"properties\":[");
                var pi: usize = 0;
                var first_property = true;
                while (cat.registry.nodePropertyInfo(info.id, pi)) |prop| : (pi += 1) {
                    if (!first_property) try writer.writeAll(",");
                    first_property = false;
                    try renderCatalogPropertyJson(writer, prop);
                }
                try writer.writeAll("]}");
            }
            try writer.writeAll("],\"relation_types\":[");
            var ri: usize = 0;
            first = true;
            while (cat.registry.relationTypeInfo(ri)) |info| : (ri += 1) {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.print("{{\"id\":{},\"name\":", .{info.id});
                try writeJsonStringRaw(writer, info.name);
                try writer.print(",\"class\":\"{s}\",\"parents\":", .{info.class.label()});
                try renderCatalogParentRefsJson(writer, cat.registry, info.parents, .relation);
                const endpoint = cat.registry.relationEndpointRuleById(info.id) orelse return error.InvalidRecord;
                try writer.writeAll(",\"endpoint\":{\"src\":");
                try renderCatalogNodeTypeSetJson(writer, cat.registry, endpoint.src);
                try writer.writeAll(",\"dst\":");
                try renderCatalogNodeTypeSetJson(writer, cat.registry, endpoint.dst);
                try writer.writeAll("},\"composition\":");
                try renderCatalogCompositionJson(writer, cat.registry.relationCompositionById(info.id));
                try writer.writeAll(",\"properties\":[");
                var pi: usize = 0;
                var first_property = true;
                while (cat.registry.relationPropertyInfo(info.id, pi)) |prop| : (pi += 1) {
                    if (!first_property) try writer.writeAll(",");
                    first_property = false;
                    try renderCatalogPropertyJson(writer, prop);
                }
                try writer.writeAll("]}");
            }
            try writer.writeAll("],\"retired_types\":[");
            first = true;
            for (cat.retired.items) |r| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.print("{{\"id\":{},\"domain\":\"{s}\",\"name\":", .{ r.id, @tagName(r.domain) });
                try writeJsonStringRaw(writer, r.name);
                try writer.writeAll("}");
            }
            try writer.writeAll("],\"profiles\":[");
            first = true;
            for (cat.profiles.items) |profile| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writeJsonStringRaw(writer, profile);
            }
            try writer.writeAll("]}\n");
        }

        fn renderCatalogParentRefsJson(
            writer: anytype,
            registry: schema.Registry,
            parents: []const u16,
            domain: TypeParentDomain,
        ) !void {
            try writer.writeAll("[");
            for (parents, 0..) |id, index| {
                if (index != 0) try writer.writeAll(",");
                const name = switch (domain) {
                    .node => registry.nodeTypeNameById(id),
                    .relation => registry.relationTypeNameById(id),
                };
                try renderCatalogTypeRefJson(writer, id, name);
            }
            try writer.writeAll("]");
        }

        fn renderCatalogNodeTypeSetJson(
            writer: anytype,
            registry: schema.Registry,
            maybe_types: ?schema.NodeTypeSet,
        ) !void {
            const types = maybe_types orelse {
                try writer.writeAll("null");
                return;
            };
            try writer.writeAll("[");
            var first = true;
            var id: u16 = 0;
            while (id < schema.max_node_types) : (id += 1) {
                if (!types.containsId(id)) continue;
                if (!first) try writer.writeAll(",");
                first = false;
                try renderCatalogTypeRefJson(writer, id, registry.nodeTypeNameById(id));
            }
            try writer.writeAll("]");
        }

        fn renderCatalogTypeRefJson(writer: anytype, id: u16, maybe_name: ?[]const u8) !void {
            try writer.print("{{\"id\":{},\"name\":", .{id});
            if (maybe_name) |name| {
                try writeJsonStringRaw(writer, name);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        }

        fn renderCatalogCompositionJson(writer: anytype, maybe_composition: ?schema.CompositionMeta) !void {
            const composition = maybe_composition orelse {
                try writer.writeAll("null");
                return;
            };
            try writer.print(
                "{{\"enabled\":{},\"owner\":{},\"cardinality\":\"{s}\",\"ordered_by\":",
                .{ composition.enabled, composition.owner, composition.cardinality.label() },
            );
            if (composition.ordered_by) |ordered_by| {
                try writeJsonStringRaw(writer, ordered_by);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        }

        fn renderCatalogPropertyJson(writer: anytype, prop: schema.PropertyMeta) !void {
            try writer.writeAll("{\"name\":");
            try writeJsonStringRaw(writer, prop.name);
            try writer.print(
                ",\"type\":\"{s}\",\"required\":{},\"nullable\":{},\"agent_fillable\":{},\"human_fillable\":{},\"indexed\":{},\"searchable\":{},\"returned_by_default\":{},\"enum_values\":[",
                .{
                    @tagName(prop.value_type),
                    prop.required,
                    prop.nullable,
                    prop.agent_fillable,
                    prop.human_fillable,
                    prop.indexed,
                    prop.searchable,
                    prop.returned_by_default,
                },
            );
            for (prop.enum_values, 0..) |value, index_pos| {
                if (index_pos != 0) try writer.writeAll(",");
                try writeJsonStringRaw(writer, value);
            }
            try writer.writeAll("]}");
        }

        fn renderParentIds(writer: anytype, registry: schema.Registry, parents: []const u16, domain: TypeParentDomain) !void {
            if (parents.len == 0) {
                try writer.writeAll("-");
                return;
            }
            for (parents, 0..) |pid, i| {
                if (i > 0) try writer.writeAll(",");
                const name = switch (domain) {
                    .node => registry.nodeTypeNameById(pid),
                    .relation => registry.relationTypeNameById(pid),
                };
                if (name) |n| {
                    try writer.print("{s}", .{n});
                } else {
                    try writer.print("#{}", .{pid});
                }
            }
        }

        const CatalogConflict = struct {
            const Kind = enum {
                id_name_mismatch,
                name_id_mismatch,
                retired_id_reuse,
                type_removed,
                property_removed,
                property_type_changed,
                enum_value_removed,
                property_constraint_tightened,
                required_property_added,
                parent_set_changed,
                relation_class_changed,
                endpoint_rule_changed,
                composition_changed,
            };

            kind: Kind,
            domain: TypeParentDomain,
            id: u16,
            existing_name: []const u8,
            candidate_name: []const u8,
        };

        fn appendCatalogConflict(
            allocator: std.mem.Allocator,
            conflicts: *std.ArrayList(CatalogConflict),
            kind: CatalogConflict.Kind,
            domain: TypeParentDomain,
            id: u16,
            existing_name: []const u8,
            candidate_name: []const u8,
        ) !void {
            const owned_existing = try allocator.dupe(u8, existing_name);
            errdefer allocator.free(owned_existing);
            const owned_candidate = try allocator.dupe(u8, candidate_name);
            errdefer allocator.free(owned_candidate);
            try conflicts.append(allocator, .{
                .kind = kind,
                .domain = domain,
                .id = id,
                .existing_name = owned_existing,
                .candidate_name = owned_candidate,
            });
        }

        fn loadCandidateRegistry(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedSchemaCatalogArgs) !schema.Registry {
            var registry = try loadSchemaRegistryFile(allocator, io, parsed.schema_path.?);
            errdefer registry.deinit();
            if (parsed.profiles) |profiles| try addBuiltinProfilesFromCsv(&registry, profiles);
            return registry;
        }

        fn endpointAxisWidensOrMatches(existing: ?schema.NodeTypeSet, candidate: ?schema.NodeTypeSet) bool {
            if (existing == null) return candidate == null;
            if (candidate == null) return true;
            return existing.?.isSubsetOf(candidate.?);
        }

        fn certifiedSharedProvenanceEndpointWidening(
            relation_id: u16,
            existing: schema.RelationEndpointRule,
            candidate: schema.RelationEndpointRule,
        ) !bool {
            const certified = switch (relation_id) {
                @intFromEnum(core.RelKind.references) => try schema.sharedReferencesEndpointRule(),
                @intFromEnum(core.RelKind.based_on) => try schema.sharedBasedOnEndpointRule(),
                else => return false,
            };
            if (!std.meta.eql(candidate, certified)) return false;
            return endpointAxisWidensOrMatches(existing.src, candidate.src) and
                endpointAxisWidensOrMatches(existing.dst, candidate.dst);
        }

        fn checkCatalogConflicts(allocator: std.mem.Allocator, cat: catalog_mod.Catalog, candidate: *const schema.Registry) ![]CatalogConflict {
            var conflicts = std.ArrayList(CatalogConflict).empty;
            errdefer {
                for (conflicts.items) |conflict| {
                    allocator.free(conflict.existing_name);
                    allocator.free(conflict.candidate_name);
                }
                conflicts.deinit(allocator);
            }

            var existing_node_index: usize = 0;
            while (cat.registry.nodeTypeInfo(existing_node_index)) |info| : (existing_node_index += 1) {
                if (candidate.nodeTypeNameById(info.id) == null) {
                    try appendCatalogConflict(allocator, &conflicts, .type_removed, .node, info.id, info.name, "");
                }
            }
            var existing_relation_index: usize = 0;
            while (cat.registry.relationTypeInfo(existing_relation_index)) |info| : (existing_relation_index += 1) {
                if (candidate.relationTypeNameById(info.id) == null) {
                    try appendCatalogConflict(allocator, &conflicts, .type_removed, .relation, info.id, info.name, "");
                }
            }

            var ni: usize = 0;
            while (candidate.nodeTypeInfo(ni)) |info| : (ni += 1) {
                if (cat.registry.nodeTypeNameById(info.id)) |existing| {
                    if (!std.mem.eql(u8, existing, info.name)) {
                        try appendCatalogConflict(allocator, &conflicts, .id_name_mismatch, .node, info.id, existing, info.name);
                    }
                    const existing_info = findNodeTypeInfoById(cat.registry, info.id) orelse return error.InvalidRecord;
                    if (!sameParentSet(existing_info.parents, info.parents)) {
                        try appendCatalogConflict(allocator, &conflicts, .parent_set_changed, .node, info.id, existing, info.name);
                    }
                }
                if (cat.registry.findNodeType(info.name)) |existing_id| {
                    if (existing_id != info.id) {
                        try appendCatalogConflict(allocator, &conflicts, .name_id_mismatch, .node, info.id, "", info.name);
                    }
                }
                for (cat.retired.items) |r| {
                    if (r.domain == .node and r.id == info.id) {
                        try appendCatalogConflict(allocator, &conflicts, .retired_id_reuse, .node, info.id, r.name, info.name);
                    }
                }
                try checkPropertyCompatibilityConflicts(allocator, &conflicts, .node, info.id, cat.registry, candidate);
            }
            var ri: usize = 0;
            while (candidate.relationTypeInfo(ri)) |info| : (ri += 1) {
                if (cat.registry.relationTypeNameById(info.id)) |existing| {
                    if (!std.mem.eql(u8, existing, info.name)) {
                        try appendCatalogConflict(allocator, &conflicts, .id_name_mismatch, .relation, info.id, existing, info.name);
                    }
                    const existing_info = findRelationTypeInfoById(cat.registry, info.id) orelse return error.InvalidRecord;
                    if (!sameParentSet(existing_info.parents, info.parents)) {
                        try appendCatalogConflict(allocator, &conflicts, .parent_set_changed, .relation, info.id, existing, info.name);
                    }
                    if (existing_info.class != info.class) {
                        try appendCatalogConflict(allocator, &conflicts, .relation_class_changed, .relation, info.id, existing, info.name);
                    }
                    const existing_endpoint = cat.registry.relationEndpointRuleById(info.id) orelse return error.InvalidRecord;
                    const candidate_endpoint = candidate.relationEndpointRuleById(info.id) orelse return error.InvalidRecord;
                    if (!std.meta.eql(existing_endpoint, candidate_endpoint) and
                        !try certifiedSharedProvenanceEndpointWidening(info.id, existing_endpoint, candidate_endpoint))
                    {
                        try appendCatalogConflict(allocator, &conflicts, .endpoint_rule_changed, .relation, info.id, existing, info.name);
                    }
                    if (!sameComposition(cat.registry.relationCompositionById(info.id), candidate.relationCompositionById(info.id))) {
                        try appendCatalogConflict(allocator, &conflicts, .composition_changed, .relation, info.id, existing, info.name);
                    }
                }
                if (cat.registry.findRelationType(info.name)) |existing_id| {
                    if (existing_id != info.id) {
                        try appendCatalogConflict(allocator, &conflicts, .name_id_mismatch, .relation, info.id, "", info.name);
                    }
                }
                for (cat.retired.items) |r| {
                    if (r.domain == .relation and r.id == info.id) {
                        try appendCatalogConflict(allocator, &conflicts, .retired_id_reuse, .relation, info.id, r.name, info.name);
                    }
                }
                try checkPropertyCompatibilityConflicts(allocator, &conflicts, .relation, info.id, cat.registry, candidate);
            }
            return conflicts.toOwnedSlice(allocator);
        }

        fn checkPropertyCompatibilityConflicts(
            allocator: std.mem.Allocator,
            conflicts: *std.ArrayList(CatalogConflict),
            domain: TypeParentDomain,
            type_id: u16,
            store_registry: schema.Registry,
            candidate: *const schema.Registry,
        ) !void {
            var ei: usize = 0;
            while (true) {
                const existing_prop = switch (domain) {
                    .node => store_registry.nodePropertyInfo(type_id, ei),
                    .relation => store_registry.relationPropertyInfo(type_id, ei),
                } orelse break;
                ei += 1;
                const candidate_prop = switch (domain) {
                    .node => candidate.nodePropertyByTypeId(type_id, existing_prop.name),
                    .relation => candidate.relationPropertyByTypeId(type_id, existing_prop.name),
                };
                const replacement = candidate_prop orelse {
                    try appendCatalogConflict(allocator, conflicts, .property_removed, domain, type_id, existing_prop.name, "");
                    continue;
                };
                if (replacement.value_type != existing_prop.value_type) {
                    try appendCatalogConflict(allocator, conflicts, .property_type_changed, domain, type_id, existing_prop.name, replacement.name);
                    continue;
                }
                if ((!existing_prop.required and replacement.required) or
                    (existing_prop.nullable and !replacement.nullable))
                {
                    try appendCatalogConflict(allocator, conflicts, .property_constraint_tightened, domain, type_id, existing_prop.name, replacement.name);
                }
                if (existing_prop.value_type == .@"enum") {
                    var narrowed = existing_prop.enum_values.len == 0 and replacement.enum_values.len != 0;
                    for (existing_prop.enum_values) |existing_value| {
                        if (!replacement.enumAllows(existing_value)) {
                            narrowed = true;
                            break;
                        }
                    }
                    if (narrowed) {
                        try appendCatalogConflict(allocator, conflicts, .enum_value_removed, domain, type_id, existing_prop.name, replacement.name);
                    }
                }
            }

            const type_exists = switch (domain) {
                .node => store_registry.hasNodeTypeId(type_id),
                .relation => store_registry.hasRelationTypeId(type_id),
            };
            if (!type_exists) return;
            var candidate_index: usize = 0;
            while (true) {
                const candidate_prop = switch (domain) {
                    .node => candidate.nodePropertyInfo(type_id, candidate_index),
                    .relation => candidate.relationPropertyInfo(type_id, candidate_index),
                } orelse break;
                candidate_index += 1;
                const existing_prop = switch (domain) {
                    .node => store_registry.nodePropertyByTypeId(type_id, candidate_prop.name),
                    .relation => store_registry.relationPropertyByTypeId(type_id, candidate_prop.name),
                };
                if (existing_prop == null and candidate_prop.required) {
                    try appendCatalogConflict(allocator, conflicts, .required_property_added, domain, type_id, "", candidate_prop.name);
                }
            }
        }

        fn findNodeTypeInfoById(registry: schema.Registry, id: u16) ?schema.TypeInfo {
            var index: usize = 0;
            while (registry.nodeTypeInfo(index)) |info| : (index += 1) {
                if (info.id == id) return info;
            }
            return null;
        }

        fn findRelationTypeInfoById(registry: schema.Registry, id: u16) ?schema.RelationTypeInfo {
            var index: usize = 0;
            while (registry.relationTypeInfo(index)) |info| : (index += 1) {
                if (info.id == id) return info;
            }
            return null;
        }

        fn sameParentSet(a: []const u16, b: []const u16) bool {
            if (a.len != b.len) return false;
            for (a) |parent| {
                if (std.mem.indexOfScalar(u16, b, parent) == null) return false;
            }
            return true;
        }

        fn sameComposition(a: ?schema.CompositionMeta, b: ?schema.CompositionMeta) bool {
            if (a == null or b == null) return a == null and b == null;
            const left = a.?;
            const right = b.?;
            if (left.enabled != right.enabled or left.owner != right.owner or left.cardinality != right.cardinality) return false;
            if (left.ordered_by == null or right.ordered_by == null) return left.ordered_by == null and right.ordered_by == null;
            return std.mem.eql(u8, left.ordered_by.?, right.ordered_by.?);
        }

        fn freeCatalogConflicts(allocator: std.mem.Allocator, conflicts: []CatalogConflict) void {
            for (conflicts) |c| {
                allocator.free(c.existing_name);
                allocator.free(c.candidate_name);
            }
            allocator.free(conflicts);
        }

        pub fn runSchemaApply(allocator: std.mem.Allocator, io: std.Io, writer: anytype, store: storage.Store, parsed: ParsedSchemaCatalogArgs) !void {
            var candidate = try loadCandidateRegistry(allocator, io, parsed);
            var candidate_owned = true;
            defer if (candidate_owned) candidate.deinit();

            const maybe_existing = try store.readCatalog();
            var existing_cat: catalog_mod.Catalog = undefined;
            if (maybe_existing) |ec| {
                existing_cat = ec;
            } else {
                existing_cat = try catalog_mod.Catalog.kernelOnly(allocator);
            }
            defer existing_cat.deinit();

            if (maybe_existing != null) {
                const conflicts = try checkCatalogConflicts(allocator, existing_cat, &candidate);
                defer freeCatalogConflicts(allocator, conflicts);
                if (conflicts.len > 0) {
                    try writer.print("schema_apply result=rejected conflicts={}\n", .{conflicts.len});
                    for (conflicts) |c| {
                        try writer.print("conflict kind={s} domain={s} id={} existing={s} candidate={s}\n", .{
                            @tagName(c.kind),
                            @tagName(c.domain),
                            c.id,
                            c.existing_name,
                            c.candidate_name,
                        });
                    }
                    return;
                }
            }

            var merged = try catalog_mod.Catalog.fromRegistry(allocator, candidate);
            candidate_owned = false;
            defer merged.deinit();
            merged.revision = std.math.add(u32, existing_cat.revision, 1) catch return error.RecordTooLarge;
            for (existing_cat.profiles.items) |existing_label| {
                try appendCatalogProfileLabel(allocator, &merged, existing_label);
            }
            try appendSchemaFileProfilesToCatalog(allocator, io, parsed.schema_path.?, &merged);
            if (parsed.profiles) |profiles| {
                var it = std.mem.tokenizeScalar(u8, profiles, ',');
                while (it.next()) |label| {
                    const trimmed = std.mem.trim(u8, label, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    try appendCatalogProfileLabel(allocator, &merged, trimmed);
                }
            }
            try store.writeCatalog(merged);
            try writer.print("schema_apply result=applied revision={} node_types={} relation_types={}\n", .{
                merged.revision,
                merged.registry.nodeTypeCount(),
                merged.registry.relationTypeCount(),
            });
        }

        const ValidationResult = struct {
            endpoint_violations: u64 = 0,
            unknown_kinds_in_data: u64 = 0,
            orphaned_types: u64 = 0,
        };

        const schema_validate_sample_limit: usize = 8;

        const SchemaEndpointViolationSample = struct {
            edge_id: u64,
            rel_id: u16,
            src_id: u64,
            src_kind_id: u16,
            dst_id: u64,
            dst_kind_id: u16,
        };

        fn schemaEndpointViolationSampleLessThan(a: SchemaEndpointViolationSample, b: SchemaEndpointViolationSample) bool {
            if (a.edge_id != b.edge_id) return a.edge_id < b.edge_id;
            if (a.src_id != b.src_id) return a.src_id < b.src_id;
            if (a.rel_id != b.rel_id) return a.rel_id < b.rel_id;
            return a.dst_id < b.dst_id;
        }

        const SchemaEndpointViolationSamples = struct {
            items: [schema_validate_sample_limit]SchemaEndpointViolationSample = undefined,
            len: usize = 0,

            fn record(self: *SchemaEndpointViolationSamples, sample: SchemaEndpointViolationSample) void {
                var insert_at: usize = 0;
                while (insert_at < self.len and schemaEndpointViolationSampleLessThan(self.items[insert_at], sample)) : (insert_at += 1) {}
                if (self.len == schema_validate_sample_limit and insert_at == schema_validate_sample_limit) return;

                const new_len = @min(self.len + 1, schema_validate_sample_limit);
                var index = new_len;
                while (index > insert_at + 1) {
                    index -= 1;
                    self.items[index] = self.items[index - 1];
                }
                self.items[insert_at] = sample;
                self.len = new_len;
            }
        };

        fn storedEdgeRefFromIndexRecord(record: storage.EdgeIndexRecord) storage.StoredEdgeRef {
            return .{
                .src = core.NodeId.fromInt(record.src),
                .dst = core.NodeId.fromInt(record.dst),
                .edge_id = core.EdgeId.fromInt(record.edge_id),
                .rel = @enumFromInt(record.rel),
            };
        }

        const SchemaValidationEdgeScanContext = struct {
            counts: *std.AutoHashMap(u16, u64),
            node_view: *storage.Store.NodeRecordView,
            registry: schema.Registry,
            result: *ValidationResult,
            samples: *SchemaEndpointViolationSamples,
            scanned_edges: u64 = 0,

            fn visit(raw_context: *anyopaque, edge_record: storage.EdgeIndexRecord) anyerror!void {
                const context: *@This() = @ptrCast(@alignCast(raw_context));
                const gop = try context.counts.getOrPut(edge_record.rel);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = std.math.add(u64, gop.value_ptr.*, 1) catch return error.RecordTooLarge;
                context.scanned_edges = std.math.add(u64, context.scanned_edges, 1) catch return error.RecordTooLarge;

                const rule = context.registry.relationEndpointRuleById(edge_record.rel) orelse return;
                if (rule.isEmpty()) return;
                const edge = storedEdgeRefFromIndexRecord(edge_record);
                const check = schemaEdgeEndpointCheck(context.node_view, context.registry, edge.src, edge.rel, edge.dst) catch |err| switch (err) {
                    // The node-kind inventory below reports unregistered historical
                    // kinds.  They must not truncate the edge scan and hide a later,
                    // fully classifiable endpoint violation.
                    error.UnknownNodeKind => return,
                    else => |e| return e,
                };
                if (!check.violates) return;

                context.result.endpoint_violations = std.math.add(u64, context.result.endpoint_violations, 1) catch return error.RecordTooLarge;
                context.samples.record(.{
                    .edge_id = edge.edge_id.toInt(),
                    .rel_id = edge_record.rel,
                    .src_id = edge.src.toInt(),
                    .src_kind_id = @intFromEnum(check.src_kind),
                    .dst_id = edge.dst.toInt(),
                    .dst_kind_id = @intFromEnum(check.dst_kind),
                });
            }
        };

        fn writeSchemaEndpointViolationSample(
            writer: anytype,
            registry: schema.Registry,
            sample: SchemaEndpointViolationSample,
        ) !void {
            try writer.print("SchemaEndpointViolation edge={} rel=", .{sample.edge_id});
            try writeRelKindNameWithSchema(writer, registry, @enumFromInt(sample.rel_id));
            try writer.print(" rel_id={} src={} src_kind=", .{ sample.rel_id, sample.src_id });
            try writeNodeKindNameWithSchema(writer, registry, @enumFromInt(sample.src_kind_id));
            try writer.print(" src_kind_id={} dst={} dst_kind=", .{ sample.src_kind_id, sample.dst_id });
            try writeNodeKindNameWithSchema(writer, registry, @enumFromInt(sample.dst_kind_id));
            try writer.print(" dst_kind_id={}\n", .{sample.dst_kind_id});
        }

        pub fn runSchemaValidate(allocator: std.mem.Allocator, io: std.Io, writer: anytype, store: storage.Store, parsed: ParsedSchemaCatalogArgs) !void {
            var candidate = try loadCandidateRegistry(allocator, io, parsed);
            defer candidate.deinit();
            try runSchemaValidateWithCandidate(allocator, writer, store, candidate);
        }

        fn runSchemaValidateWithCandidate(
            allocator: std.mem.Allocator,
            writer: anytype,
            store: storage.Store,
            candidate: schema.Registry,
        ) !void {
            var existing_catalog = try store.readCatalog();
            defer if (existing_catalog) |*catalog| catalog.deinit();
            var result = ValidationResult{};
            var node_kind_counts = std.AutoHashMap(u16, u64).init(allocator);
            defer node_kind_counts.deinit();
            var node_iter = try store.nodeRecordsIterator(null);
            defer node_iter.deinit();
            while (try node_iter.next(allocator)) |stored_node| {
                var n = stored_node;
                defer n.deinit(allocator);
                const gop = try node_kind_counts.getOrPut(@intFromEnum(n.kind));
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = std.math.add(u64, gop.value_ptr.*, 1) catch return error.RecordTooLarge;
            }
            var edge_kind_counts = std.AutoHashMap(u16, u64).init(allocator);
            defer edge_kind_counts.deinit();
            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var endpoint_samples = SchemaEndpointViolationSamples{};
            var edge_scan_context = SchemaValidationEdgeScanContext{
                .counts = &edge_kind_counts,
                .node_view = &node_view,
                .registry = candidate,
                .result = &result,
                .samples = &endpoint_samples,
            };
            const scanned_visible_edges = try store.scanVisibleEdgeIndexRecords(allocator, &edge_scan_context, SchemaValidationEdgeScanContext.visit);
            if (scanned_visible_edges != edge_scan_context.scanned_edges) return error.InvalidRecord;

            // Render by numeric type id rather than hash-map iteration order so the
            // same store/schema pair produces byte-stable validation feedback.
            var raw_id: u32 = 0;
            while (raw_id <= std.math.maxInt(u16)) : (raw_id += 1) {
                const id: u16 = @intCast(raw_id);
                if (node_kind_counts.get(id)) |count| {
                    if (candidate.nodeTypeNameById(id)) |name| {
                        try writer.print("node_type id={} name={s} data_count={}\n", .{ id, name, count });
                    } else if (if (existing_catalog) |catalog| catalog.registry.nodeTypeNameById(id) else null) |name| {
                        result.orphaned_types = std.math.add(u64, result.orphaned_types, 1) catch return error.RecordTooLarge;
                        try writer.print("SchemaOrphanedTypeInUse domain=node kind={} name={s} count={}\n", .{ id, name, count });
                    } else {
                        result.unknown_kinds_in_data = std.math.add(u64, result.unknown_kinds_in_data, 1) catch return error.RecordTooLarge;
                        try writer.print("SchemaUnknownKindInData domain=node kind={} count={}\n", .{ id, count });
                    }
                }
            }

            raw_id = 0;
            while (raw_id <= std.math.maxInt(u16)) : (raw_id += 1) {
                const id: u16 = @intCast(raw_id);
                if (edge_kind_counts.get(id)) |count| {
                    if (candidate.relationTypeNameById(id)) |name| {
                        try writer.print("relation_type id={} name={s} data_count={}\n", .{ id, name, count });
                    } else if (if (existing_catalog) |catalog| catalog.registry.relationTypeNameById(id) else null) |name| {
                        result.orphaned_types = std.math.add(u64, result.orphaned_types, 1) catch return error.RecordTooLarge;
                        try writer.print("SchemaOrphanedTypeInUse domain=relation kind={} name={s} count={}\n", .{ id, name, count });
                    } else {
                        result.unknown_kinds_in_data = std.math.add(u64, result.unknown_kinds_in_data, 1) catch return error.RecordTooLarge;
                        try writer.print("SchemaUnknownKindInData domain=relation kind={} count={}\n", .{ id, count });
                    }
                }
            }

            for (endpoint_samples.items[0..endpoint_samples.len]) |sample| {
                try writeSchemaEndpointViolationSample(writer, candidate, sample);
            }

            const status = if (result.endpoint_violations == 0 and result.unknown_kinds_in_data == 0 and result.orphaned_types == 0)
                "ok"
            else
                "invalid";
            try writer.print("schema_validate result={s} endpoint_violations={} unknown_kinds_in_data={} orphaned_types={}\n", .{
                status,
                result.endpoint_violations,
                result.unknown_kinds_in_data,
                result.orphaned_types,
            });
        }

        fn readBoundedRegularFileAlloc(
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []const u8,
            max_bytes: u64,
        ) ![]u8 {
            var file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size == 0 or stat.size > max_bytes) return error.InvalidRecord;
            const bytes = try allocator.alloc(u8, @intCast(stat.size));
            errdefer allocator.free(bytes);
            if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidRecord;
            return bytes;
        }

        fn appendCatalogRetiredTypes(
            allocator: std.mem.Allocator,
            target: *catalog_mod.Catalog,
            retired_types: []const catalog_mod.RetiredType,
        ) !void {
            for (retired_types) |retired| {
                const owned_name = try allocator.dupe(u8, retired.name);
                errdefer allocator.free(owned_name);
                try target.retired.append(allocator, .{
                    .id = retired.id,
                    .domain = retired.domain,
                    .name = owned_name,
                    .retired_at_revision = retired.retired_at_revision,
                });
            }
        }

        fn appendCatalogCsvProfiles(
            allocator: std.mem.Allocator,
            target: *catalog_mod.Catalog,
            raw_profiles: ?[]const u8,
        ) !void {
            const profiles = raw_profiles orelse return;
            var it = std.mem.tokenizeScalar(u8, profiles, ',');
            while (it.next()) |label| {
                const trimmed = std.mem.trim(u8, label, " \t\r\n");
                if (trimmed.len == 0) continue;
                try appendCatalogProfileLabel(allocator, target, trimmed);
            }
        }

        fn buildSchemaReconciliationCandidate(
            allocator: std.mem.Allocator,
            schema_bytes: []const u8,
            profiles: ?[]const u8,
            existing: catalog_mod.Catalog,
        ) !catalog_mod.Catalog {
            var registry = try loadSchemaRegistryBytes(allocator, schema_bytes);
            var registry_owned = true;
            errdefer if (registry_owned) registry.deinit();
            if (profiles) |raw_profiles| try addBuiltinProfilesFromCsv(&registry, raw_profiles);
            var candidate = try catalog_mod.Catalog.fromRegistry(allocator, registry);
            registry_owned = false;
            errdefer candidate.deinit();
            candidate.revision = std.math.add(u32, existing.revision, 1) catch return error.RecordTooLarge;
            for (existing.profiles.items) |label| try appendCatalogProfileLabel(allocator, &candidate, label);
            var parsed_schema = try parseSchemaFileBytes(allocator, schema_bytes);
            defer parsed_schema.deinit();
            try appendSchemaDocumentProfilesToCatalog(allocator, parsed_schema.value, &candidate);
            try appendCatalogCsvProfiles(allocator, &candidate, profiles);
            try appendCatalogRetiredTypes(allocator, &candidate, existing.retired.items);
            return candidate;
        }

        fn renderCatalogJsonAlloc(allocator: std.mem.Allocator, cat: catalog_mod.Catalog) ![]u8 {
            var output = QueryOutputWriter{ .allocator = allocator };
            errdefer output.buffer.deinit(allocator);
            try renderCatalogJson(&output, cat);
            return output.buffer.toOwnedSlice(allocator);
        }

        fn renderSchemaValidationAlloc(
            allocator: std.mem.Allocator,
            store: storage.Store,
            candidate: schema.Registry,
        ) ![]u8 {
            var output = QueryOutputWriter{ .allocator = allocator };
            errdefer output.buffer.deinit(allocator);
            try runSchemaValidateWithCandidate(allocator, &output, store, candidate);
            return output.buffer.toOwnedSlice(allocator);
        }

        fn verifySchemaReconciliationPostWrite(
            allocator: std.mem.Allocator,
            store: storage.Store,
            plan: *const schema_reconciliation.Plan,
            existing: catalog_mod.Catalog,
            expected_catalog_bytes: []const u8,
            candidate_schema_bytes: []const u8,
        ) !void {
            const actual_bytes = (try store.readCatalogBytesAlloc(allocator)) orelse return error.InvalidRecord;
            defer allocator.free(actual_bytes);
            if (!std.mem.eql(u8, actual_bytes, expected_catalog_bytes)) return error.SchemaReconciliationPostWriteMismatch;
            var actual = try catalog_mod.decodeCatalog(allocator, actual_bytes);
            defer actual.deinit();
            const actual_json = try renderCatalogJsonAlloc(allocator, actual);
            defer allocator.free(actual_json);
            if (!schema_reconciliation.digestMatchesHex(actual_json, plan.document().inputs.candidate_catalog_sha256)) {
                return error.SchemaReconciliationPostWriteMismatch;
            }
            try schema_reconciliation.validateCatalogTransition(plan, existing, actual);
            const validation = try renderSchemaValidationAlloc(allocator, store, actual.registry);
            defer allocator.free(validation);
            try schema_reconciliation.verifyValidationOutput(plan, validation);
            if (!schema_reconciliation.digestMatchesHex(validation, plan.document().inputs.schema_validation_sha256) or
                !schema_reconciliation.digestMatchesHex(candidate_schema_bytes, plan.document().inputs.candidate_schema_sha256))
            {
                return error.SchemaReconciliationPostWriteMismatch;
            }
        }

        fn rollbackSchemaReconciliationCatalog(
            allocator: std.mem.Allocator,
            store: storage.Store,
            snapshot: []const u8,
        ) !void {
            try store.restoreCatalogBytes(snapshot);
            const restored = (try store.readCatalogBytesAlloc(allocator)) orelse return error.SchemaReconciliationRollbackFailed;
            defer allocator.free(restored);
            if (!std.mem.eql(u8, restored, snapshot)) return error.SchemaReconciliationRollbackFailed;
        }

        /// `writeAll` only moves bytes into a buffered `std.Io.Writer`.  When the
        /// caller exposes a flush operation, make that observable publication part of
        /// the guarded transaction.  Memory/test writers without a separate flush
        /// boundary publish when `writeAll` returns.
        fn publishSchemaReconciliationReceipt(writer: anytype, receipt: []const u8) !void {
            try writer.writeAll(receipt);
            if (comptime @hasDecl(@TypeOf(writer.*), "flush")) try writer.flush();
        }

        pub fn runSchemaReconcile(
            allocator: std.mem.Allocator,
            io: std.Io,
            writer: anytype,
            store: storage.Store,
            parsed: ParsedSchemaReconcileArgs,
        ) !void {
            // StoreContext already owns the exclusive CLI lock.  Read every external
            // authorization input only after that lock is held, and construct the
            // candidate from those exact bytes rather than reopening the schema.
            const plan_bytes = try readBoundedRegularFileAlloc(allocator, io, parsed.plan_path, schema_reconciliation.max_plan_bytes);
            defer allocator.free(plan_bytes);
            var plan = try schema_reconciliation.parsePlan(allocator, plan_bytes);
            defer plan.deinit();
            const schema_bytes = try readSchemaFileBytesAlloc(allocator, io, parsed.schema_path);
            defer allocator.free(schema_bytes);
            const existing_bytes = (try store.readCatalogBytesAlloc(allocator)) orelse return error.SchemaReconciliationCatalogMissing;
            defer allocator.free(existing_bytes);
            var existing = try catalog_mod.decodeCatalog(allocator, existing_bytes);
            defer existing.deinit();
            var candidate = try buildSchemaReconciliationCandidate(allocator, schema_bytes, parsed.profiles, existing);
            defer candidate.deinit();

            const existing_json = try renderCatalogJsonAlloc(allocator, existing);
            defer allocator.free(existing_json);
            const candidate_json = try renderCatalogJsonAlloc(allocator, candidate);
            defer allocator.free(candidate_json);
            const validation = try renderSchemaValidationAlloc(allocator, store, candidate.registry);
            defer allocator.free(validation);
            try schema_reconciliation.verifyValidationOutput(&plan, validation);
            try schema_reconciliation.verifyBoundInputs(&plan, existing_json, candidate_json, schema_bytes, validation);
            try schema_reconciliation.validateCatalogTransition(&plan, existing, candidate);

            const candidate_bytes = try catalog_mod.encodeCatalog(allocator, candidate);
            defer allocator.free(candidate_bytes);
            const plan_digest_hex = schema_reconciliation.digestHex(plan.digest);
            const receipt = try std.fmt.allocPrint(
                allocator,
                "schema_reconcile plan_sha256={s} previous_revision={} revision={} existing_catalog_sha256={s} candidate_catalog_sha256={s} schema_validation_sha256={s} rollback_ready=1 post_write_parity=1 receipt_published=1 result=applied\n",
                .{
                    &plan_digest_hex,
                    existing.revision,
                    candidate.revision,
                    plan.document().inputs.existing_catalog_sha256,
                    plan.document().inputs.candidate_catalog_sha256,
                    plan.document().inputs.schema_validation_sha256,
                },
            );
            defer allocator.free(receipt);

            store.writeCatalog(candidate) catch |write_error| {
                rollbackSchemaReconciliationCatalog(allocator, store, existing_bytes) catch return error.SchemaReconciliationRollbackFailed;
                return write_error;
            };
            var post_write_error: ?anyerror = null;
            verifySchemaReconciliationPostWrite(allocator, store, &plan, existing, candidate_bytes, schema_bytes) catch |err| {
                post_write_error = err;
            };
            if (post_write_error == null) {
                publishSchemaReconciliationReceipt(writer, receipt) catch |err| {
                    post_write_error = err;
                };
            }
            if (post_write_error) |err| {
                rollbackSchemaReconciliationCatalog(allocator, store, existing_bytes) catch return error.SchemaReconciliationRollbackFailed;
                return err;
            }
        }

        const darwin_statfs = if (builtin.os.tag == .macos) struct {
            extern "c" fn statfs(path: [*:0]const u8, buf: *DarwinStatfs) c_int;

            const DarwinStatfs = extern struct {
                f_bsize: u32,
                f_iosize: i32,
                f_blocks: u64,
                f_bfree: u64,
                f_bavail: u64,
                f_files: u64,
                f_ffree: u64,
                f_fsid: [2]u32,
                f_owner: u32,
                f_type: u32,
                f_flags: u32,
                f_fssubtype: u32,
                f_fstypename: [16]u8,
                f_mntonname: [1024]u8,
                f_mntfromname: [1024]u8,
                f_reserved: [8]u32,
            };
        } else void;

        const linux_statvfs = if (builtin.os.tag == .linux and @sizeOf(usize) == 8) struct {
            extern "c" fn statvfs(path: [*:0]const u8, buf: *LinuxStatvfs) c_int;

            // Linux glibc and musl use this layout on the supported 64-bit targets.
            // Keep the declaration local rather than depending on libc-private Zig
            // bindings; 32-bit targets deliberately fall back to a skipped check.
            const LinuxStatvfs = extern struct {
                f_bsize: c_ulong,
                f_frsize: c_ulong,
                f_blocks: u64,
                f_bfree: u64,
                f_bavail: u64,
                f_files: u64,
                f_ffree: u64,
                f_favail: u64,
                f_fsid: c_ulong,
                f_flag: c_ulong,
                f_namemax: c_ulong,
                f_type: c_uint,
                f_spare: [5]c_int,
            };
        } else void;

        const DiskSpaceCheck = enum { ok, insufficient, skipped };

        fn diskSpaceCheckFromBlocks(available_blocks: u64, block_bytes: u64, needed_bytes: u64) DiskSpaceCheck {
            const available_bytes = std.math.mul(u64, available_blocks, block_bytes) catch std.math.maxInt(u64);
            return if (available_bytes >= needed_bytes) .ok else .insufficient;
        }

        fn checkDiskSpaceForMigration(target_path: []const u8, needed_bytes: u64) !DiskSpaceCheck {
            const target_dir = std.fs.path.dirname(target_path) orelse ".";
            var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
            const cstr = std.fmt.bufPrintZ(&path_buf, "{s}", .{target_dir}) catch return .skipped;
            if (builtin.os.tag == .macos) {
                var buf: darwin_statfs.DarwinStatfs = undefined;
                if (darwin_statfs.statfs(cstr.ptr, &buf) != 0) return .skipped;
                return diskSpaceCheckFromBlocks(buf.f_bavail, buf.f_bsize, needed_bytes);
            }
            if (builtin.os.tag == .linux and @sizeOf(usize) == 8) {
                var buf: linux_statvfs.LinuxStatvfs = undefined;
                if (linux_statvfs.statvfs(cstr.ptr, &buf) != 0) return .skipped;
                const block_bytes: u64 = if (buf.f_frsize != 0) buf.f_frsize else buf.f_bsize;
                return diskSpaceCheckFromBlocks(buf.f_bavail, block_bytes, needed_bytes);
            }
            return .skipped;
        }

        fn schemaMigrationPeakFreeBytes(source_bytes: u64, logical_primary_text_bytes: u64) u64 {
            // The source remains in place while schema-migrate builds a complete
            // target plus source/target external-sort spools. Publishing the canonical
            // property pair also creates a redo copy before the stage files are
            // renamed. Four physical source copies cover the non-text data and
            // spools; two additional logical text copies cover the raw bulk-ingest
            // target and its block-deflate publication even when the source text is
            // highly compressed. Saturate so overflow can never turn a huge
            // migration into a tiny ask.
            const physical = std.math.mul(u64, source_bytes, 4) catch return std.math.maxInt(u64);
            const logical_text = std.math.mul(u64, logical_primary_text_bytes, 2) catch return std.math.maxInt(u64);
            return std.math.add(u64, physical, logical_text) catch std.math.maxInt(u64);
        }

        test "schema migration disk estimate includes compressed text expansion and transient spools" {
            try std.testing.expectEqual(@as(u64, 0), schemaMigrationPeakFreeBytes(0, 0));
            try std.testing.expectEqual(@as(u64, 500), schemaMigrationPeakFreeBytes(100, 50));
            try std.testing.expectEqual(@as(u64, 2400), schemaMigrationPeakFreeBytes(100, 1000));
            try std.testing.expectEqual(std.math.maxInt(u64), schemaMigrationPeakFreeBytes(std.math.maxInt(u64), 0));
            try std.testing.expectEqual(std.math.maxInt(u64), schemaMigrationPeakFreeBytes(0, std.math.maxInt(u64)));
            try std.testing.expectEqual(std.math.maxInt(u64), schemaMigrationPeakFreeBytes(std.math.maxInt(u64) / 4, 2));
        }

        test "schema migration disk check saturates available byte arithmetic" {
            try std.testing.expectEqual(DiskSpaceCheck.ok, diskSpaceCheckFromBlocks(25, 4, 100));
            try std.testing.expectEqual(DiskSpaceCheck.insufficient, diskSpaceCheckFromBlocks(24, 4, 100));
            try std.testing.expectEqual(DiskSpaceCheck.ok, diskSpaceCheckFromBlocks(std.math.maxInt(u64), 4096, std.math.maxInt(u64)));
        }

        fn schemaMigrationStagingPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, schema_migration_staging_suffix });
        }

        pub fn schemaMigrationTransactionMarkerPath(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
            return try std.fs.path.join(allocator, &.{ dir_path, schema_migration_transaction_marker_file });
        }

        pub const SchemaMigrationTransactionExpectation = struct {
            canonical_source_path: []const u8,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
            source_registry_digest: ContentDigest,
            target_catalog_digest: ContentDigest,
            target_profiles: []const u8,
            target_schema_version: u32,
            target_kind_remaps: u64,
        };

        const SchemaMigrationPublicationResult = struct {
            nodes_migrated: u64,
            edges_migrated: u64,
            kind_remaps: u64,
            published_store_bytes: u64,
            published_store_digest: ContentDigest,
            marker_cleanup_pending: bool = false,
        };

        const SchemaMigrationTransactionMarkerJson = struct {
            format: []const u8,
            canonical_source_path: []const u8,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
            source_registry_digest: ContentDigest,
            target_catalog_digest: ContentDigest,
            target_profiles: []const u8,
            target_schema_version: u32,
            target_kind_remaps: u64,
            complete: bool,
            result: ?SchemaMigrationPublicationResult = null,
        };

        const SchemaMigrationMarkerState = struct {
            complete: bool,
            result: ?SchemaMigrationPublicationResult,
            legacy_format: bool,
        };

        fn appendSchemaMigrationPublicationResultJson(out: *QueryOutputWriter, result: SchemaMigrationPublicationResult) !void {
            try out.print(
                "{{\"nodes_migrated\":{},\"edges_migrated\":{},\"kind_remaps\":{},\"published_store_bytes\":{},\"published_store_digest\":[{},{},{},{}],\"marker_cleanup_pending\":{}}}",
                .{
                    result.nodes_migrated,
                    result.edges_migrated,
                    result.kind_remaps,
                    result.published_store_bytes,
                    result.published_store_digest[0],
                    result.published_store_digest[1],
                    result.published_store_digest[2],
                    result.published_store_digest[3],
                    result.marker_cleanup_pending,
                },
            );
        }

        pub fn writeSchemaMigrationTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: SchemaMigrationTransactionExpectation,
            result: ?SchemaMigrationPublicationResult,
        ) !void {
            const marker_path = try schemaMigrationTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
            defer allocator.free(tmp_path);

            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);
            try out.writeAll("{\"format\":");
            try writeJsonString(&out, schema_migration_transaction_marker_format);
            try out.writeAll(",\"canonical_source_path\":");
            try writeJsonString(&out, expected.canonical_source_path);
            try out.print(
                ",\"source_store_bytes\":{},\"source_store_digest\":[{},{},{},{}],\"source_registry_digest\":[{},{},{},{}],\"target_catalog_digest\":[{},{},{},{}],\"target_profiles\":",
                .{
                    expected.source_store_bytes,
                    expected.source_store_digest[0],
                    expected.source_store_digest[1],
                    expected.source_store_digest[2],
                    expected.source_store_digest[3],
                    expected.source_registry_digest[0],
                    expected.source_registry_digest[1],
                    expected.source_registry_digest[2],
                    expected.source_registry_digest[3],
                    expected.target_catalog_digest[0],
                    expected.target_catalog_digest[1],
                    expected.target_catalog_digest[2],
                    expected.target_catalog_digest[3],
                },
            );
            try writeJsonString(&out, expected.target_profiles);
            try out.print(",\"target_schema_version\":{},\"target_kind_remaps\":{},\"complete\":{},\"result\":", .{
                expected.target_schema_version,
                expected.target_kind_remaps,
                result != null,
            });
            if (result) |value| {
                try appendSchemaMigrationPublicationResultJson(&out, value);
            } else {
                try out.writeAll("null");
            }
            try out.writeAll("}\n");
            writeRecoverableTransactionMarker(allocator, io, tmp_path, marker_path, out.buffer.items) catch |err| switch (err) {
                error.TransactionMarkerConflict => return error.MigrationRecoveryConflict,
                else => |e| return e,
            };
        }

        fn readSchemaMigrationTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: SchemaMigrationTransactionExpectation,
        ) !?SchemaMigrationMarkerState {
            const marker_path = try schemaMigrationTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            return try readSchemaMigrationTransactionMarkerAtPath(allocator, io, marker_path, expected);
        }

        fn readSchemaMigrationTransactionMarkerAtPath(
            allocator: std.mem.Allocator,
            io: std.Io,
            marker_path: []const u8,
            expected: SchemaMigrationTransactionExpectation,
        ) !?SchemaMigrationMarkerState {
            const content = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(32 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return null,
                error.StreamTooLong => return error.InvalidRecord,
                else => |e| return e,
            };
            defer allocator.free(content);
            var parsed = std.json.parseFromSlice(SchemaMigrationTransactionMarkerJson, allocator, content, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            }) catch return error.InvalidRecord;
            defer parsed.deinit();
            const marker = parsed.value;
            const legacy_format = std.mem.eql(u8, marker.format, schema_migration_transaction_marker_legacy_format);
            if ((!std.mem.eql(u8, marker.format, schema_migration_transaction_marker_format) and !legacy_format) or
                !std.mem.eql(u8, marker.canonical_source_path, expected.canonical_source_path) or
                marker.source_store_bytes != expected.source_store_bytes or
                !std.meta.eql(marker.source_store_digest, expected.source_store_digest) or
                !std.meta.eql(marker.source_registry_digest, expected.source_registry_digest) or
                !std.meta.eql(marker.target_catalog_digest, expected.target_catalog_digest) or
                !std.mem.eql(u8, marker.target_profiles, expected.target_profiles) or
                marker.target_schema_version != expected.target_schema_version or
                marker.target_kind_remaps != expected.target_kind_remaps)
            {
                return error.MigrationRecoveryConflict;
            }
            if (marker.complete != (marker.result != null)) return error.InvalidRecord;
            if (marker.result) |result| {
                if (result.marker_cleanup_pending or
                    result.kind_remaps != expected.target_kind_remaps or
                    result.published_store_bytes == 0 or
                    std.meta.eql(result.published_store_digest, ContentDigest{ 0, 0, 0, 0 }))
                {
                    return error.InvalidRecord;
                }
            }
            return .{ .complete = marker.complete, .result = marker.result, .legacy_format = legacy_format };
        }

        fn schemaMigrationTransactionMarkerPresent(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !bool {
            const marker_path = try schemaMigrationTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const content = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(32 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return false,
                error.StreamTooLong => return error.InvalidRecord,
                else => |e| return e,
            };
            defer allocator.free(content);
            var parsed = std.json.parseFromSlice(SchemaMigrationTransactionMarkerJson, allocator, content, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            }) catch return error.InvalidRecord;
            defer parsed.deinit();
            const supported_format = std.mem.eql(u8, parsed.value.format, schema_migration_transaction_marker_format) or
                std.mem.eql(u8, parsed.value.format, schema_migration_transaction_marker_legacy_format);
            if (!supported_format or
                parsed.value.complete != (parsed.value.result != null))
            {
                return error.InvalidRecord;
            }
            return true;
        }

        fn directoryIsEmpty(io: std.Io, dir_path: []const u8) !bool {
            var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            var iter = dir.iterate();
            return try iter.next(io) == null;
        }

        /// Under the stable adjacent publish lock, a marked staging directory can
        /// only belong to an interrupted schema migration for this exact target.
        /// Unmarked non-empty state is foreign and is never recursively removed.
        pub fn recoverSchemaMigrationStaging(
            allocator: std.mem.Allocator,
            io: std.Io,
            staging_path: []const u8,
            expected: SchemaMigrationTransactionExpectation,
        ) !void {
            if (!try anyPathExists(io, staging_path)) return;
            const stat = try std.Io.Dir.cwd().statFile(io, staging_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.MigrationRecoveryConflict;
            if (try directoryIsEmpty(io, staging_path)) {
                try std.Io.Dir.cwd().deleteTree(io, staging_path);
                try syncParentDirectory(io, staging_path);
                return;
            }
            var marker = try readSchemaMigrationTransactionMarker(allocator, io, staging_path, expected);
            if (marker == null) {
                const marker_path = try schemaMigrationTransactionMarkerPath(allocator, staging_path);
                defer allocator.free(marker_path);
                const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
                defer allocator.free(tmp_path);
                marker = try readSchemaMigrationTransactionMarkerAtPath(allocator, io, tmp_path, expected);
            }
            _ = marker orelse return error.MigrationRecoveryConflict;
            try std.Io.Dir.cwd().deleteTree(io, staging_path);
            try syncParentDirectory(io, staging_path);
        }

        const SchemaMigrationRecoveryExpectation = struct {
            catalog: catalog_mod.Catalog,
            transaction: SchemaMigrationTransactionExpectation,
        };

        /// A final path carrying the private marker was renamed from a fully synced
        /// staging tree. The v3 marker binds source/store/schema identity and the
        /// published target digest; revalidate all of it before acknowledging an
        /// interrupted publication.
        fn recoverCompletedSchemaMigration(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
            expected: SchemaMigrationRecoveryExpectation,
        ) !?SchemaMigrationPublicationResult {
            if (!try anyPathExists(io, target_path)) return null;
            const stat = try std.Io.Dir.cwd().statFile(io, target_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.AlreadyExists;
            const marker = (try readSchemaMigrationTransactionMarker(allocator, io, target_path, expected.transaction)) orelse
                return error.AlreadyExists;
            if (!marker.complete) return error.InvalidRecord;
            _ = marker.result orelse return error.InvalidRecord;
            const target_lock = try CliStoreLock.acquire(allocator, io, target_path);
            defer target_lock.deinit();
            const locked_marker = (try readSchemaMigrationTransactionMarker(allocator, io, target_path, expected.transaction)) orelse
                return error.MigrationRecoveryConflict;
            if (!locked_marker.complete) return error.InvalidRecord;
            var result = locked_marker.result orelse return error.InvalidRecord;
            const identity = try storeContentIdentity(allocator, io, target_path);
            if (identity.bytes != result.published_store_bytes or
                !std.meta.eql(identity.digest, result.published_store_digest))
            {
                return error.MigrationRecoveryConflict;
            }
            if (!try existingTinyKgStorePath(allocator, io, target_path)) return error.InvalidRecord;
            var store = try storage.Store.open(allocator, io, target_path);
            defer store.deinit();
            const stats_out = try store.stats();
            if (stats_out.nodes != result.nodes_migrated or stats_out.edges != result.edges_migrated) return error.InvalidRecord;
            var catalog = (try store.readCatalog()) orelse return error.InvalidRecord;
            defer catalog.deinit();
            const actual_catalog_bytes = try catalog_mod.encodeCatalog(allocator, catalog);
            defer allocator.free(actual_catalog_bytes);
            const expected_catalog_bytes = try catalog_mod.encodeCatalog(allocator, expected.catalog);
            defer allocator.free(expected_catalog_bytes);
            if (!std.mem.eql(u8, actual_catalog_bytes, expected_catalog_bytes)) return error.MigrationRecoveryConflict;
            const manifest = try readStoreManifestSummary(allocator, io, target_path);
            defer manifest.deinit(allocator);
            const expected_schema_version = try std.fmt.allocPrint(allocator, "{}", .{expected.transaction.target_schema_version});
            defer allocator.free(expected_schema_version);
            if (!std.mem.eql(u8, manifest.status, "present") or
                !std.mem.eql(u8, manifest.storage_format_version, "2") or
                !std.mem.eql(u8, manifest.schema_version, expected_schema_version) or
                !std.mem.eql(u8, manifest.enabled_profiles, expected.transaction.target_profiles) or
                !std.mem.eql(u8, manifest.migration_name, "schema-migrate") or
                manifest.migration_source.len == 0) return error.MigrationRecoveryConflict;
            const canonical_manifest_source = canonicalProspectivePath(allocator, io, manifest.migration_source) catch return error.MigrationRecoveryConflict;
            defer allocator.free(canonical_manifest_source);
            if (!canonicalPathsEqual(canonical_manifest_source, expected.transaction.canonical_source_path)) return error.MigrationRecoveryConflict;
            if (locked_marker.legacy_format) {
                try writeSchemaMigrationTransactionMarker(allocator, io, target_path, expected.transaction, result);
            }
            try syncParentDirectory(io, target_path);
            // The complete marker is the durable commit receipt.  Keep it so a retry
            // can authenticate this exact publication if the success response was
            // lost after the rename commit.
            result.marker_cleanup_pending = false;
            return result;
        }

        fn loadEmbeddedSchemaRegistryOrKernel(allocator: std.mem.Allocator, store: storage.Store) !schema.Registry {
            if (try store.readCatalog()) |catalog_value| {
                var source_catalog = catalog_value;
                defer source_catalog.deinit();
                const registry = source_catalog.registry;
                // Transfer registry ownership out of the decoded catalog while still
                // letting its profile/retired metadata follow the normal deinit path.
                source_catalog.registry = schema.Registry.init(allocator);
                return registry;
            }
            var registry = schema.Registry.init(allocator);
            errdefer registry.deinit();
            try registry.addKernelTypes();
            return registry;
        }

        fn schemaMigrationManifestVersion(summary: StoreManifestSummary) u32 {
            const source_version = std.fmt.parseInt(u32, summary.schema_version, 10) catch return 2;
            return if (source_version >= current_schema_version) current_schema_version else 2;
        }

        fn schemaRegistryContentDigest(allocator: std.mem.Allocator, registry: schema.Registry) !ContentDigest {
            const view = catalog_mod.Catalog{
                .allocator = allocator,
                .registry = registry,
            };
            const bytes = try catalog_mod.encodeCatalog(allocator, view);
            defer allocator.free(bytes);
            return contentDigestForBytes(bytes);
        }

        fn catalogContentDigest(allocator: std.mem.Allocator, catalog: catalog_mod.Catalog) !ContentDigest {
            const bytes = try catalog_mod.encodeCatalog(allocator, catalog);
            defer allocator.free(bytes);
            return contentDigestForBytes(bytes);
        }

        pub fn runSchemaMigrate(allocator: std.mem.Allocator, io: std.Io, writer: anytype, parsed: ParsedSchemaMigrateArgs) !void {
            try validateSchemaMigratePathRelationship(allocator, io, parsed);
            const canonical_target_lock_path = try canonicalProspectivePath(allocator, io, parsed.new_db_path);
            defer allocator.free(canonical_target_lock_path);
            const cli_lock = try CliStoreLock.acquire(allocator, io, parsed.old_db_path);
            defer cli_lock.deinit();
            // Resolve again after excluding source writers.  This rejects dotted and
            // symlink aliases before a second lock can accidentally recurse into the
            // source store, and catches a target created after initial preflight.
            try validateSchemaMigratePathRelationship(allocator, io, parsed);
            const new_lock = try CliStoreLock.acquireAdjacent(allocator, io, canonical_target_lock_path, schema_migration_publish_lock_suffix);
            defer new_lock.deinit();
            const staging_path = try schemaMigrationStagingPath(allocator, parsed.new_db_path);
            defer allocator.free(staging_path);
            const canonical_source_path = try canonicalProspectivePath(allocator, io, parsed.old_db_path);
            defer allocator.free(canonical_source_path);
            var old_store = try storage.Store.open(allocator, io, parsed.old_db_path);
            defer old_store.deinit();
            var source_catalog = if (try old_store.readCatalog()) |catalog_value|
                catalog_value
            else
                try catalog_mod.Catalog.kernelOnly(allocator);
            defer source_catalog.deinit();
            const source_manifest = try readStoreManifestSummary(allocator, io, parsed.old_db_path);
            defer source_manifest.deinit(allocator);

            var old_registry = if (parsed.from_schema_path) |path|
                try loadSchemaRegistryFile(allocator, io, path)
            else
                try loadEmbeddedSchemaRegistryOrKernel(allocator, old_store);
            defer old_registry.deinit();
            var new_registry = if (parsed.to_schema_path) |path|
                try loadSchemaRegistryFile(allocator, io, path)
            else if (parsed.from_schema_path) |path|
                try loadSchemaRegistryFile(allocator, io, path)
            else
                try loadEmbeddedSchemaRegistryOrKernel(allocator, old_store);
            var new_registry_owned = true;
            errdefer if (new_registry_owned) new_registry.deinit();
            if (parsed.profiles) |profiles| try addBuiltinProfilesFromCsv(&new_registry, profiles);
            var new_cat = try catalog_mod.Catalog.fromRegistry(allocator, new_registry);
            new_registry_owned = false;
            defer new_cat.deinit();
            new_cat.revision = std.math.add(u32, source_catalog.revision, 1) catch return error.RecordTooLarge;
            if (parsed.to_schema_path) |path| {
                try appendSchemaFileProfilesToCatalog(allocator, io, path, &new_cat);
            } else if (parsed.from_schema_path) |path| {
                try appendSchemaFileProfilesToCatalog(allocator, io, path, &new_cat);
            } else {
                for (source_catalog.profiles.items) |profile| try appendCatalogProfileLabel(allocator, &new_cat, profile);
            }
            if (parsed.profiles) |profiles| {
                var profile_it = std.mem.tokenizeScalar(u8, profiles, ',');
                while (profile_it.next()) |raw_profile| {
                    const profile = std.mem.trim(u8, raw_profile, " \t\r\n");
                    if (profile.len == 0) continue;
                    try appendCatalogProfileLabel(allocator, &new_cat, profile);
                }
            }
            const target_profiles = try catalogProfilesCsvAlloc(allocator, new_cat);
            defer allocator.free(target_profiles);
            const target_schema_version = schemaMigrationManifestVersion(source_manifest);
            var migrator = try SchemaMigrator.init(allocator, &old_registry, &new_cat.registry, staging_path);
            defer migrator.deinit();
            const source_identity = try storeContentIdentity(allocator, io, parsed.old_db_path);
            const transaction_expectation = SchemaMigrationTransactionExpectation{
                .canonical_source_path = canonical_source_path,
                .source_store_bytes = source_identity.bytes,
                .source_store_digest = source_identity.digest,
                .source_registry_digest = try schemaRegistryContentDigest(allocator, old_registry),
                .target_catalog_digest = try catalogContentDigest(allocator, new_cat),
                .target_profiles = target_profiles,
                .target_schema_version = target_schema_version,
                .target_kind_remaps = @intCast(migrator.kind_remap_count),
            };
            try recoverSchemaMigrationStaging(allocator, io, staging_path, transaction_expectation);
            if (try recoverCompletedSchemaMigration(allocator, io, parsed.new_db_path, .{
                .catalog = new_cat,
                .transaction = transaction_expectation,
            })) |recovery| {
                try writer.print(
                    "schema_migrate result=ok recovered=1 marker_cleanup_pending={} old_db={s} new_db={s}\n",
                    .{ @intFromBool(recovery.marker_cleanup_pending), parsed.old_db_path, parsed.new_db_path },
                );
                return;
            }
            try validateSchemaMigratePaths(allocator, io, parsed);
            const source_bytes = source_identity.bytes;
            const logical_primary_text_bytes = try old_store.primaryNodeTextLogicalBytes();
            const required_peak_free_bytes = schemaMigrationPeakFreeBytes(source_bytes, logical_primary_text_bytes);
            const space_check = try checkDiskSpaceForMigration(parsed.new_db_path, required_peak_free_bytes);
            switch (space_check) {
                .ok => {},
                .skipped => try writer.print(
                    "schema_migrate warning=disk_space_check_skipped source_bytes={} logical_primary_text_bytes={} required_peak_free_bytes={}\n",
                    .{ source_bytes, logical_primary_text_bytes, required_peak_free_bytes },
                ),
                .insufficient => {
                    try writer.print(
                        "schema_migrate result=error reason=insufficient_disk_space source_bytes={} logical_primary_text_bytes={} required_peak_free_bytes={}\n",
                        .{ source_bytes, logical_primary_text_bytes, required_peak_free_bytes },
                    );
                    return error.InsufficientDiskSpace;
                },
            }
            // The final path stays absent until a fully materialized and synced store
            // is ready for one atomic directory rename. The private marker makes an
            // interrupted staging tree safe to reclaim on the next locked attempt.
            try createOwnedDirectory(io, staging_path);
            var staging_owned = true;
            defer if (staging_owned) std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeSchemaMigrationTransactionMarker(allocator, io, staging_path, transaction_expectation, null);
            try syncExportDirectoryTree(allocator, io, staging_path);
            var new_store = try storage.Store.initWithOptions(allocator, io, staging_path, .{
                .primary_text_write_mode = .bulk_ingest,
            });
            var new_store_open = true;
            defer if (new_store_open) new_store.deinit();
            try new_store.createEmpty();
            const migrate_result = try migrator.migrateStore(io, old_store, new_store);
            _ = try copyMetaknowDeferredBasedOnSidecarForMigration(allocator, io, old_store.dir_path, new_store.dir_path);
            try new_store.writeCatalog(new_cat);
            try writeStoreManifest(allocator, io, staging_path, .{
                .profiles = target_profiles,
                .migration_name = "schema-migrate",
                .source_path = canonical_source_path,
                .schema_version = target_schema_version,
            });
            new_store.deinit();
            new_store_open = false;
            const current_source_identity = try storeContentIdentity(allocator, io, parsed.old_db_path);
            if (current_source_identity.bytes != source_identity.bytes or
                !std.meta.eql(current_source_identity.digest, source_identity.digest))
            {
                return error.MigrationSourceChanged;
            }
            const published_identity = try storeContentIdentity(allocator, io, staging_path);
            var publication_result = SchemaMigrationPublicationResult{
                .nodes_migrated = @intCast(migrate_result.nodes_migrated),
                .edges_migrated = @intCast(migrate_result.edges_migrated),
                .kind_remaps = @intCast(migrate_result.kind_remaps),
                .published_store_bytes = published_identity.bytes,
                .published_store_digest = published_identity.digest,
            };
            try writeSchemaMigrationTransactionMarker(allocator, io, staging_path, transaction_expectation, publication_result);
            try syncExportDirectoryTree(allocator, io, staging_path);
            // The adjacent publish lock is stable while the target changes from
            // absent to present. Recheck absence immediately before the atomic claim.
            try validateSchemaMigratePaths(allocator, io, parsed);
            try renamePath(io, staging_path, parsed.new_db_path);
            staging_owned = false;
            try syncParentDirectory(io, parsed.new_db_path);
            // Retain the request-bound complete marker across acknowledgment loss.
            publication_result.marker_cleanup_pending = false;
            try writer.print(
                "schema_migrate result=ok old_db={s} new_db={s} nodes_migrated={} edges_migrated={} kind_remaps={} catalog_revision={} marker_cleanup_pending={}\n",
                .{
                    parsed.old_db_path,
                    parsed.new_db_path,
                    migrate_result.nodes_migrated,
                    migrate_result.edges_migrated,
                    migrate_result.kind_remaps,
                    new_cat.revision,
                    @intFromBool(publication_result.marker_cleanup_pending),
                },
            );
        }

        const SchemaMigrator = struct {
            const invalid_type_id = std.math.maxInt(u16);

            allocator: std.mem.Allocator,
            old_registry: *const schema.Registry,
            new_registry: *const schema.Registry,
            scratch_dir: []const u8,
            node_remap: [schema.max_node_types]u16,
            rel_remap: [schema.max_relation_types]u16,
            kind_remap_count: usize = 0,

            fn init(allocator: std.mem.Allocator, old_reg: *const schema.Registry, new_reg: *const schema.Registry, scratch_dir: []const u8) !SchemaMigrator {
                var m = SchemaMigrator{
                    .allocator = allocator,
                    .old_registry = old_reg,
                    .new_registry = new_reg,
                    .scratch_dir = scratch_dir,
                    .node_remap = undefined,
                    .rel_remap = undefined,
                };
                var i: u16 = 0;
                while (i < schema.max_node_types) : (i += 1) {
                    m.node_remap[i] = i;
                }
                i = 0;
                while (i < schema.max_relation_types) : (i += 1) {
                    m.rel_remap[i] = i;
                }
                var oi: usize = 0;
                while (m.old_registry.nodeTypeInfo(oi)) |old_info| : (oi += 1) {
                    if (m.new_registry.findNodeType(old_info.name)) |new_id| {
                        if (new_id != old_info.id) {
                            m.node_remap[old_info.id] = new_id;
                            m.kind_remap_count += 1;
                        }
                    } else if (!m.new_registry.hasNodeTypeId(old_info.id)) {
                        // A missing target id is a real drop, not an identity remap.
                        // Keep the sentinel until the data scan proves the old type
                        // unused; otherwise the migration must fail closed.
                        m.node_remap[old_info.id] = invalid_type_id;
                    }
                }
                var ori: usize = 0;
                while (m.old_registry.relationTypeInfo(ori)) |old_info| : (ori += 1) {
                    if (m.new_registry.findRelationType(old_info.name)) |new_id| {
                        if (new_id != old_info.id) {
                            m.rel_remap[old_info.id] = new_id;
                            m.kind_remap_count += 1;
                        }
                    } else if (!m.new_registry.hasRelationTypeId(old_info.id)) {
                        m.rel_remap[old_info.id] = invalid_type_id;
                    }
                }
                return m;
            }

            fn deinit(self: *SchemaMigrator) void {
                _ = self;
            }

            const MigrateResult = struct {
                nodes_migrated: usize,
                edges_migrated: usize,
                kind_remaps: usize,
            };

            fn migrateStore(self: *SchemaMigrator, io: std.Io, old_store: storage.Store, new_store: storage.Store) !MigrateResult {
                const node_batch_limit: usize = 4096;
                const edge_batch_limit: usize = 8192;
                var nodes_migrated: usize = 0;
                var edges_migrated: usize = 0;
                var node_property_keys = try MigrationPropertyKeys.init(self.allocator, self.old_registry.*, self.new_registry.*, .node);
                defer node_property_keys.deinit();
                var edge_property_keys = try MigrationPropertyKeys.init(self.allocator, self.old_registry.*, self.new_registry.*, .edge);
                defer edge_property_keys.deinit();
                var property_spool = try MigrationPropertySpool.build(
                    self.allocator,
                    io,
                    self.scratch_dir,
                    old_store,
                    &node_property_keys,
                    &edge_property_keys,
                );
                defer property_spool.deinit();
                var property_stream = try MigrationPropertyStream.init(&property_spool);
                defer property_stream.deinit();
                var target_property_builder = try MigrationTargetPropertySpoolBuilder.init(
                    self.allocator,
                    io,
                    self.scratch_dir,
                    &node_property_keys,
                    &edge_property_keys,
                );
                defer target_property_builder.deinit();

                // Publish entity records first. Property validation/copy is a second,
                // bounded pass: target owner checks then see consolidated entities, and
                // no all-store property snapshot or property write array is retained.
                var node_iter = try old_store.nodeRecordsIterator(null);
                defer node_iter.deinit();
                var batch = std.ArrayList(graph.Node).empty;
                defer {
                    for (batch.items) |n| self.allocator.free(n.text);
                    batch.deinit(self.allocator);
                }
                while (try node_iter.next(self.allocator)) |stored_node| {
                    var n = stored_node;
                    defer n.deinit(self.allocator);
                    const old_kind: u16 = @intFromEnum(n.kind);
                    if (old_kind >= schema.max_node_types) return error.InvalidRecord;
                    const new_kind: u16 = self.node_remap[old_kind];
                    if (new_kind == invalid_type_id or !self.new_registry.hasNodeTypeId(new_kind)) return error.SchemaOrphanedTypeInUse;
                    {
                        const owned_text = try self.allocator.dupe(u8, n.text);
                        errdefer self.allocator.free(owned_text);
                        try batch.append(self.allocator, .{
                            .id = n.id,
                            .kind = @enumFromInt(new_kind),
                            .text = owned_text,
                        });
                    }
                    nodes_migrated += 1;
                    if (batch.items.len >= node_batch_limit) {
                        try new_store.appendNodesBatch(batch.items);
                        for (batch.items) |node| self.allocator.free(node.text);
                        batch.clearRetainingCapacity();
                    }
                }
                if (batch.items.len > 0) {
                    try new_store.appendNodesBatch(batch.items);
                    for (batch.items) |node| self.allocator.free(node.text);
                    batch.clearRetainingCapacity();
                }
                try new_store.finalizePrimaryTextStorage();

                var node_ids = std.ArrayList(core.NodeId).empty;
                defer node_ids.deinit(self.allocator);
                var node_old_kinds = std.ArrayList(u16).empty;
                defer node_old_kinds.deinit(self.allocator);
                var node_new_kinds = std.ArrayList(u16).empty;
                defer node_new_kinds.deinit(self.allocator);
                var node_property_iter = try old_store.nodeRecordsIterator(null);
                defer node_property_iter.deinit();
                while (try node_property_iter.nextRef()) |node| {
                    const old_kind: u16 = @intFromEnum(node.kind);
                    if (old_kind >= schema.max_node_types) return error.InvalidRecord;
                    const new_kind = self.node_remap[old_kind];
                    if (new_kind == invalid_type_id or !self.new_registry.hasNodeTypeId(new_kind)) return error.SchemaOrphanedTypeInUse;
                    try node_ids.append(self.allocator, node.id);
                    try node_old_kinds.append(self.allocator, old_kind);
                    try node_new_kinds.append(self.allocator, new_kind);
                    if (node_ids.items.len >= node_batch_limit) {
                        try self.migrateNodePropertyBatch(&property_stream, &target_property_builder, node_ids.items, node_old_kinds.items, node_new_kinds.items);
                        node_ids.clearRetainingCapacity();
                        node_old_kinds.clearRetainingCapacity();
                        node_new_kinds.clearRetainingCapacity();
                    }
                }
                if (node_ids.items.len != 0) {
                    try self.migrateNodePropertyBatch(&property_stream, &target_property_builder, node_ids.items, node_old_kinds.items, node_new_kinds.items);
                }

                var edge_spool_builder = try MigrationEdgeSpoolBuilder.init(self.allocator, io, self.scratch_dir);
                defer edge_spool_builder.deinit();
                {
                    var target_node_view = try new_store.openNodeRecordView();
                    defer target_node_view.deinit();
                    var edge_batch = std.ArrayList(graph.Edge).empty;
                    defer edge_batch.deinit(self.allocator);
                    const EdgeMigrationContext = struct {
                        migrator: *SchemaMigrator,
                        target_node_view: *storage.Store.NodeRecordView,
                        new_store: storage.Store,
                        edge_batch: *std.ArrayList(graph.Edge),
                        edge_batch_limit: usize,
                        edge_spool_builder: *MigrationEdgeSpoolBuilder,
                        edges_migrated: *usize,

                        fn flush(context: *@This()) !void {
                            if (context.edge_batch.items.len == 0) return;
                            try context.new_store.appendEdgesBatch(context.edge_batch.items);
                            context.edge_batch.clearRetainingCapacity();
                        }

                        fn visit(raw_context: *anyopaque, record: storage.EdgeIndexRecord) anyerror!void {
                            const context: *@This() = @ptrCast(@alignCast(raw_context));
                            if (record.rel >= schema.max_relation_types) return error.InvalidRecord;
                            const new_rel = context.migrator.rel_remap[record.rel];
                            if (new_rel == invalid_type_id or !context.migrator.new_registry.hasRelationTypeId(new_rel)) return error.SchemaOrphanedTypeInUse;
                            const endpoint_rule = context.migrator.new_registry.relationEndpointRuleById(new_rel) orelse return error.SchemaOrphanedTypeInUse;
                            if (!endpoint_rule.isEmpty()) {
                                const endpoint_check = try schemaEdgeEndpointCheck(
                                    context.target_node_view,
                                    context.migrator.new_registry.*,
                                    core.NodeId.fromInt(record.src),
                                    @enumFromInt(new_rel),
                                    core.NodeId.fromInt(record.dst),
                                );
                                if (endpoint_check.violates) return error.SchemaEndpointViolation;
                            }
                            try context.edge_spool_builder.append(record);
                            try context.edge_batch.append(context.migrator.allocator, .{
                                .id = core.EdgeId.fromInt(record.edge_id),
                                .src = core.NodeId.fromInt(record.src),
                                .dst = core.NodeId.fromInt(record.dst),
                                .rel = @enumFromInt(new_rel),
                            });
                            context.edges_migrated.* = std.math.add(usize, context.edges_migrated.*, 1) catch return error.RecordTooLarge;
                            if (context.edge_batch.items.len >= context.edge_batch_limit) try context.flush();
                        }
                    };
                    var edge_migration_context = EdgeMigrationContext{
                        .migrator = self,
                        .target_node_view = &target_node_view,
                        .new_store = new_store,
                        .edge_batch = &edge_batch,
                        .edge_batch_limit = edge_batch_limit,
                        .edge_spool_builder = &edge_spool_builder,
                        .edges_migrated = &edges_migrated,
                    };
                    const scanned_edges = try old_store.scanVisibleEdgeIndexRecords(self.allocator, &edge_migration_context, EdgeMigrationContext.visit);
                    try edge_migration_context.flush();
                    if (scanned_edges != edges_migrated) return error.InvalidRecord;
                }
                var edge_spool = try edge_spool_builder.finish();
                defer edge_spool.deinit();
                if (edge_spool.record_count != edges_migrated) return error.InvalidRecord;
                // Multiple bounded edge publications may leave only their append
                // overlays visible. Consolidate once after the full stream, never
                // once per batch, so point reads are current without O(N²) rebuilds.
                if (edges_migrated != 0) try new_store.repairPersistentIndexesFromLog();
                _ = try new_store.replaceEdgeOrderIndexRemappedFrom(old_store, &self.rel_remap, invalid_type_id);

                var edge_ids = std.ArrayList(core.EdgeId).empty;
                defer edge_ids.deinit(self.allocator);
                var edge_old_rels = std.ArrayList(u16).empty;
                defer edge_old_rels.deinit(self.allocator);
                var edge_new_rels = std.ArrayList(u16).empty;
                defer edge_new_rels.deinit(self.allocator);
                var edge_property_stream = try MigrationEdgeStream.init(&edge_spool);
                defer edge_property_stream.deinit();
                while (try edge_property_stream.next()) |record| {
                    if (record.rel >= schema.max_relation_types) return error.InvalidRecord;
                    const new_rel = self.rel_remap[record.rel];
                    if (new_rel == invalid_type_id or !self.new_registry.hasRelationTypeId(new_rel)) return error.SchemaOrphanedTypeInUse;
                    try edge_ids.append(self.allocator, core.EdgeId.fromInt(record.edge_id));
                    try edge_old_rels.append(self.allocator, record.rel);
                    try edge_new_rels.append(self.allocator, new_rel);
                    if (edge_ids.items.len >= edge_batch_limit) {
                        try self.migrateEdgePropertyBatch(&property_stream, &target_property_builder, edge_ids.items, edge_old_rels.items, edge_new_rels.items);
                        edge_ids.clearRetainingCapacity();
                        edge_old_rels.clearRetainingCapacity();
                        edge_new_rels.clearRetainingCapacity();
                    }
                }
                if (edge_ids.items.len != 0) {
                    try self.migrateEdgePropertyBatch(&property_stream, &target_property_builder, edge_ids.items, edge_old_rels.items, edge_new_rels.items);
                }
                try property_stream.finish();
                var target_property_spool = try target_property_builder.finish();
                defer target_property_spool.deinit();
                var target_property_stream = try MigrationPropertyStream.init(&target_property_spool);
                defer target_property_stream.deinit();
                try new_store.replaceEmptyPropertyPayloadFromSortedStream(
                    target_property_spool.record_count,
                    &target_property_stream,
                    MigrationPropertyStream.nextSortedPayload,
                );
                return .{
                    .nodes_migrated = nodes_migrated,
                    .edges_migrated = edges_migrated,
                    .kind_remaps = self.kind_remap_count,
                };
            }

            fn migrateNodePropertyBatch(
                self: *SchemaMigrator,
                property_stream: *MigrationPropertyStream,
                target_property_builder: *MigrationTargetPropertySpoolBuilder,
                node_ids: []const core.NodeId,
                old_kinds: []const u16,
                new_kinds: []const u16,
            ) !void {
                if (node_ids.len != old_kinds.len or node_ids.len != new_kinds.len) return error.InvalidRecord;
                var raw_ids = std.ArrayList(u64).empty;
                defer raw_ids.deinit(self.allocator);
                try raw_ids.ensureTotalCapacityPrecise(self.allocator, node_ids.len);
                for (node_ids) |node_id| raw_ids.appendAssumeCapacity(node_id.toInt());
                const snapshot = try property_stream.snapshotForOwners(1, raw_ids.items);
                var source_properties = try MigrationPropertyLookup.initFromSnapshot(self.allocator, snapshot);
                defer source_properties.deinit();
                var property_batch = MigrationPropertyBatch.init(self.allocator);
                defer property_batch.deinit();
                for (node_ids, old_kinds, new_kinds) |node_id, old_kind, new_kind| {
                    try ensureDeclaredNodePropertiesRetained(&source_properties, self.old_registry.*, old_kind, self.new_registry.*, new_kind, node_id);
                    _ = try collectKnownNodeProperties(&source_properties, self.new_registry.*, new_kind, node_id, &property_batch, false, false);
                }
                if (property_batch.writes.items.len != 0) {
                    try target_property_builder.appendBatch(property_batch.writes.items);
                }
            }

            fn migrateEdgePropertyBatch(
                self: *SchemaMigrator,
                property_stream: *MigrationPropertyStream,
                target_property_builder: *MigrationTargetPropertySpoolBuilder,
                edge_ids: []const core.EdgeId,
                old_rels: []const u16,
                new_rels: []const u16,
            ) !void {
                if (edge_ids.len != old_rels.len or edge_ids.len != new_rels.len) return error.InvalidRecord;
                var raw_ids = std.ArrayList(u64).empty;
                defer raw_ids.deinit(self.allocator);
                try raw_ids.ensureTotalCapacityPrecise(self.allocator, edge_ids.len);
                for (edge_ids) |edge_id| raw_ids.appendAssumeCapacity(edge_id.toInt());
                const snapshot = try property_stream.snapshotForOwners(2, raw_ids.items);
                var source_properties = try MigrationPropertyLookup.initFromSnapshot(self.allocator, snapshot);
                defer source_properties.deinit();
                var property_batch = MigrationPropertyBatch.init(self.allocator);
                defer property_batch.deinit();
                for (edge_ids, old_rels, new_rels) |edge_id, old_rel, new_rel| {
                    try ensureDeclaredEdgePropertiesRetained(&source_properties, self.old_registry.*, old_rel, self.new_registry.*, new_rel, edge_id);
                    _ = try collectKnownEdgeProperties(&source_properties, self.new_registry.*, new_rel, edge_id, null, &property_batch);
                }
                if (property_batch.writes.items.len != 0) {
                    try target_property_builder.appendBatch(property_batch.writes.items);
                }
            }
        };

        pub fn catalogTestSchemaJsonAlloc(allocator: std.mem.Allocator, name: []const u8, id: u16) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{{\"schema_version\":2,\"node_types\":[{{\"name\":\"{s}\",\"id\":{},\"parents\":[\"node\"]}}]}}", .{ name, id });
        }

        pub fn writeSchemaFile(io: std.Io, path: []const u8, content: []const u8) !void {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content, .flags = .{ .truncate = true } });
        }

        test "schema documents reject unknown policy fields at every level" {
            const invalid_documents = [_][]const u8{
                \\{"schema_version":3,"schema_versoin":3}
                ,
                \\{"schema_version":3,"profile_contracts":{"agent_dagg":2}}
                ,
                \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"src_type":["node"]}]}
                ,
                \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"composition":{"enabled":true,"ordred_by":"order_key"}}]}
                ,
                \\{"schema_version":3,"node_types":[{"name":"ticket","id":100,"properties":{"state":{"type":"string","requierd":true}}}]}
                ,
            };
            for (invalid_documents) |document| {
                try std.testing.expectError(
                    error.UnknownField,
                    loadSchemaRegistryBytes(std.testing.allocator, document),
                );
            }
        }

        test "schema apply rejects unknown policy before catalog mutation" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "unknown-field.json" });
            defer std.testing.allocator.free(schema_path);

            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);
            var before_store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            const catalog_before = (try before_store.readCatalogBytesAlloc(std.testing.allocator)).?;
            before_store.deinit();
            defer std.testing.allocator.free(catalog_before);
            try writeSchemaFile(
                std.testing.io,
                schema_path,
                \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"src_type":["node"]}]}
                ,
            );

            var apply_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer apply_out.buffer.deinit(std.testing.allocator);
            try std.testing.expectError(
                error.UnknownField,
                run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &apply_out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), apply_out.buffer.items.len);

            var after_store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer after_store.deinit();
            const catalog_after = (try after_store.readCatalogBytesAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(catalog_after);
            try std.testing.expectEqualSlices(u8, catalog_before, catalog_after);
        }

        const schema_reconciliation_test_schema =
            \\{"schema_version":3,"node_types":[{"name":"document","id":6,"parents":["node"]},{"name":"document_section","id":7,"parents":["node"]}],"relation_types":[{"name":"contains","id":0,"parents":["edge"],"class":"sys","properties":{"order_key":{"type":"uint","required":false,"nullable":true,"indexed":true}}}]}
        ;

        fn schemaReconciliationTestCatalog(allocator: std.mem.Allocator) !catalog_mod.Catalog {
            var existing = catalog_mod.Catalog.init(allocator);
            errdefer existing.deinit();
            try existing.registry.addKernelTypes();
            try existing.registry.addNodeType("document", 6, &.{schema.kernel_node_type_id});
            try existing.registry.addNodeType("document_section", 7, &.{schema.kernel_node_type_id});
            const src = try schema.NodeTypeSet.singleton(6);
            const dst = try schema.NodeTypeSet.singleton(7);
            try existing.registry.addRelationTypeWithMetadata(
                "contains",
                0,
                &.{schema.kernel_edge_type_id},
                .{ .src = src, .dst = dst },
                .sys,
            );
            try existing.registry.setRelationProperty(0, .{ .name = "order_key", .value_type = .uint, .indexed = true });
            try existing.registry.setRelationComposition(0, .{
                .enabled = true,
                .owner = true,
                .cardinality = .many,
                .ordered_by = "order_key",
            });
            existing.revision = 1;
            return existing;
        }

        fn writeSchemaReconciliationTestPlan(
            allocator: std.mem.Allocator,
            io: std.Io,
            store: storage.Store,
            schema_path: []const u8,
            plan_path: []const u8,
        ) !void {
            const schema_bytes = try readSchemaFileBytesAlloc(allocator, io, schema_path);
            defer allocator.free(schema_bytes);
            var existing = (try store.readCatalog()) orelse return error.TestUnexpectedResult;
            defer existing.deinit();
            var candidate = try buildSchemaReconciliationCandidate(allocator, schema_bytes, null, existing);
            defer candidate.deinit();
            const existing_json = try renderCatalogJsonAlloc(allocator, existing);
            defer allocator.free(existing_json);
            const candidate_json = try renderCatalogJsonAlloc(allocator, candidate);
            defer allocator.free(candidate_json);
            const validation = try renderSchemaValidationAlloc(allocator, store, candidate.registry);
            defer allocator.free(validation);
            const existing_hash = schema_reconciliation.digestHex(schema_reconciliation.sha256(existing_json));
            const candidate_hash = schema_reconciliation.digestHex(schema_reconciliation.sha256(candidate_json));
            const schema_hash = schema_reconciliation.digestHex(schema_reconciliation.sha256(schema_bytes));
            const validation_hash = schema_reconciliation.digestHex(schema_reconciliation.sha256(validation));
            const plan_json = try std.fmt.allocPrint(
                allocator,
                "{{\"schema_version\":1,\"contract_id\":\"repository.catalog.reconciliation.plan.v1\",\"status\":\"approved\",\"inputs\":{{\"existing_catalog_sha256\":\"{s}\",\"candidate_catalog_sha256\":\"{s}\",\"candidate_schema_sha256\":\"{s}\",\"schema_validation_sha256\":\"{s}\"}},\"existing_revision\":1,\"candidate_revision\":2,\"validation\":{{\"result\":\"ok\",\"endpoint_violations\":0,\"unknown_kinds_in_data\":0,\"orphaned_types\":0,\"unknown_kinds\":[]}},\"approved_changes\":[{{\"domain\":\"relation\",\"id\":0,\"name\":\"contains\",\"kind\":\"endpoint_rule_widened\"}},{{\"domain\":\"relation\",\"id\":0,\"name\":\"contains\",\"kind\":\"composition_removed\"}}],\"summary\":{{\"changes\":2,\"by_kind\":{{\"composition_removed\":1,\"endpoint_rule_widened\":1}}}}}}\n",
                .{ &existing_hash, &candidate_hash, &schema_hash, &validation_hash },
            );
            defer allocator.free(plan_json);
            try writeSchemaFile(io, plan_path, plan_json);
        }

        const SchemaReconciliationReceiptFailingWriter = struct {
            buffer: std.ArrayList(u8) = .empty,

            fn deinit(self: *@This()) void {
                self.buffer.deinit(std.testing.allocator);
            }

            pub fn writeAll(self: *@This(), bytes: []const u8) !void {
                if (std.mem.indexOf(u8, bytes, "result=applied") != null) return error.OutputClosed;
                try self.buffer.appendSlice(std.testing.allocator, bytes);
            }

            pub fn print(self: *@This(), comptime format: []const u8, args: anytype) !void {
                const rendered = try std.fmt.allocPrint(std.testing.allocator, format, args);
                defer std.testing.allocator.free(rendered);
                try self.writeAll(rendered);
            }
        };

        const SchemaReconciliationReceiptFlushFailingWriter = struct {
            pending: std.ArrayList(u8) = .empty,
            visible: std.ArrayList(u8) = .empty,

            fn deinit(self: *@This()) void {
                self.pending.deinit(std.testing.allocator);
                self.visible.deinit(std.testing.allocator);
            }

            pub fn writeAll(self: *@This(), bytes: []const u8) !void {
                try self.pending.appendSlice(std.testing.allocator, bytes);
            }

            pub fn flush(_: *@This()) !void {
                return error.OutputClosed;
            }

            pub fn print(self: *@This(), comptime format: []const u8, args: anytype) !void {
                const rendered = try std.fmt.allocPrint(std.testing.allocator, format, args);
                defer std.testing.allocator.free(rendered);
                try self.writeAll(rendered);
            }
        };

        test "schema-reconcile applies an exact locked plan and proves post-write parity" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.json" });
            defer std.testing.allocator.free(plan_path);
            try writeSchemaFile(std.testing.io, schema_path, schema_reconciliation_test_schema);
            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.createEmpty();
                var existing = try schemaReconciliationTestCatalog(std.testing.allocator);
                defer existing.deinit();
                try store.writeCatalog(existing);
                try writeSchemaReconciliationTestPlan(std.testing.allocator, std.testing.io, store, schema_path, plan_path);
            }
            var output = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer output.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-reconcile", db_path, "--schema", schema_path, "--plan", plan_path }, &output, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, output.buffer.items, "rollback_ready=1 post_write_parity=1 receipt_published=1 result=applied\n") != null);
            var applied = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer applied.deinit();
            var catalog_after = (try applied.readCatalog()).?;
            defer catalog_after.deinit();
            try std.testing.expectEqual(@as(u32, 2), catalog_after.revision);
            try std.testing.expect((catalog_after.registry.relationEndpointRuleById(0).?).isEmpty());
            try std.testing.expectEqual(@as(?schema.CompositionMeta, null), catalog_after.registry.relationCompositionById(0));
        }

        test "schema-reconcile rolls back when final receipt publication fails" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.json" });
            defer std.testing.allocator.free(plan_path);
            try writeSchemaFile(std.testing.io, schema_path, schema_reconciliation_test_schema);
            var before: []u8 = undefined;
            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.createEmpty();
                var existing = try schemaReconciliationTestCatalog(std.testing.allocator);
                defer existing.deinit();
                try store.writeCatalog(existing);
                try writeSchemaReconciliationTestPlan(std.testing.allocator, std.testing.io, store, schema_path, plan_path);
                before = (try store.readCatalogBytesAlloc(std.testing.allocator)).?;
            }
            defer std.testing.allocator.free(before);
            var output = SchemaReconciliationReceiptFailingWriter{};
            defer output.deinit();
            try std.testing.expectError(
                error.OutputClosed,
                run(&.{ "tinykg", "schema-reconcile", db_path, "--schema", schema_path, "--plan", plan_path }, &output, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), output.buffer.items.len);
            var restored = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer restored.deinit();
            const after = (try restored.readCatalogBytesAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
        }

        test "schema-reconcile rolls back when buffered receipt flush fails" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.json" });
            defer std.testing.allocator.free(plan_path);
            try writeSchemaFile(std.testing.io, schema_path, schema_reconciliation_test_schema);
            var before: []u8 = undefined;
            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.createEmpty();
                var existing = try schemaReconciliationTestCatalog(std.testing.allocator);
                defer existing.deinit();
                try store.writeCatalog(existing);
                try writeSchemaReconciliationTestPlan(std.testing.allocator, std.testing.io, store, schema_path, plan_path);
                before = (try store.readCatalogBytesAlloc(std.testing.allocator)).?;
            }
            defer std.testing.allocator.free(before);
            var output = SchemaReconciliationReceiptFlushFailingWriter{};
            defer output.deinit();
            try std.testing.expectError(
                error.OutputClosed,
                run(&.{ "tinykg", "schema-reconcile", db_path, "--schema", schema_path, "--plan", plan_path }, &output, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(output.pending.items.len > 0);
            try std.testing.expectEqual(@as(usize, 0), output.visible.items.len);
            var restored = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer restored.deinit();
            const after = (try restored.readCatalogBytesAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
        }

        test "schema-reconcile locked revalidation rejects data drift without mutation" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.json" });
            defer std.testing.allocator.free(plan_path);
            try writeSchemaFile(std.testing.io, schema_path, schema_reconciliation_test_schema);
            var before: []u8 = undefined;
            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.createEmpty();
                var existing = try schemaReconciliationTestCatalog(std.testing.allocator);
                defer existing.deinit();
                try store.writeCatalog(existing);
                try writeSchemaReconciliationTestPlan(std.testing.allocator, std.testing.io, store, schema_path, plan_path);
                try store.appendNode(.{ .id = .fromInt(1), .kind = .repo, .text = "new unknown debt" });
                before = (try store.readCatalogBytesAlloc(std.testing.allocator)).?;
            }
            defer std.testing.allocator.free(before);
            var output = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer output.buffer.deinit(std.testing.allocator);
            try std.testing.expectError(
                schema_reconciliation.Error.ReconciliationInputChanged,
                run(&.{ "tinykg", "schema-reconcile", db_path, "--schema", schema_path, "--plan", plan_path }, &output, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), output.buffer.items.len);
            var unchanged = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
            defer unchanged.deinit();
            const after = (try unchanged.readCatalogBytesAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
        }

        test "schema-show on new store prints kernel-only catalog" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);

            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

            var show_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer show_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-show", db_path }, &show_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, show_out.buffer.items, "catalog=embedded") != null);
            try std.testing.expect(std.mem.indexOf(u8, show_out.buffer.items, "node_types=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, show_out.buffer.items, "name=node") != null);
            try std.testing.expect(std.mem.indexOf(u8, show_out.buffer.items, "endpoint_src=* endpoint_dst=* composition=none") != null);

            show_out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-show", db_path, "--json" }, &show_out, std.testing.allocator, std.testing.io);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, show_out.buffer.items, .{});
            defer parsed.deinit();
            const relations = parsed.value.object.get("relation_types").?.array.items;
            try std.testing.expect(relations.len > 0);
            const endpoint = relations[0].object.get("endpoint").?.object;
            try std.testing.expect(endpoint.get("src").? == .null);
            try std.testing.expect(endpoint.get("dst").? == .null);
            try std.testing.expect(relations[0].object.get("composition").? == .null);
        }

        test "schema-show exposes persisted parents endpoints and composition in text and json" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);

            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"node_types":[{"name":"parent","id":100,"parents":["node"]},{"name":"child","id":101,"parents":["parent"]}],"relation_types":[{"name":"owns","id":100,"parents":["edge"],"class":"domain","src_types":["child"],"dst_types":["parent"],"properties":{"order_key":{"type":"uint","required":false,"nullable":true}},"composition":{"enabled":true,"owner":true,"cardinality":"one","ordered_by":"order_key"}}]}
            );

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=applied") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-show", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_type id=101 name=child parents=parent") != null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                out.buffer.items,
                "relation_type id=100 name=owns class=domain parents=edge endpoint_src=child#101 endpoint_dst=parent#100,child#101 composition=enabled:1,owner:1,cardinality:one,ordered_by:order_key",
            ) != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-show", db_path, "--json" }, &out, std.testing.allocator, std.testing.io);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffer.items, .{});
            defer parsed.deinit();

            var found_child = false;
            for (parsed.value.object.get("node_types").?.array.items) |value| {
                const object = value.object;
                if (!std.mem.eql(u8, object.get("name").?.string, "child")) continue;
                found_child = true;
                const parents = object.get("parents").?.array.items;
                try std.testing.expectEqual(@as(usize, 1), parents.len);
                try std.testing.expectEqual(@as(i64, 100), parents[0].object.get("id").?.integer);
                try std.testing.expectEqualStrings("parent", parents[0].object.get("name").?.string);
            }
            try std.testing.expect(found_child);

            var found_owns = false;
            for (parsed.value.object.get("relation_types").?.array.items) |value| {
                const object = value.object;
                if (!std.mem.eql(u8, object.get("name").?.string, "owns")) continue;
                found_owns = true;
                const parents = object.get("parents").?.array.items;
                try std.testing.expectEqual(@as(usize, 1), parents.len);
                try std.testing.expectEqualStrings("edge", parents[0].object.get("name").?.string);
                const endpoint = object.get("endpoint").?.object;
                const src = endpoint.get("src").?.array.items;
                const dst = endpoint.get("dst").?.array.items;
                try std.testing.expectEqual(@as(usize, 1), src.len);
                try std.testing.expectEqual(@as(i64, 101), src[0].object.get("id").?.integer);
                try std.testing.expectEqualStrings("child", src[0].object.get("name").?.string);
                try std.testing.expectEqual(@as(usize, 2), dst.len);
                try std.testing.expectEqual(@as(i64, 100), dst[0].object.get("id").?.integer);
                try std.testing.expectEqualStrings("parent", dst[0].object.get("name").?.string);
                try std.testing.expectEqual(@as(i64, 101), dst[1].object.get("id").?.integer);
                try std.testing.expectEqualStrings("child", dst[1].object.get("name").?.string);
                const composition = object.get("composition").?.object;
                try std.testing.expect(composition.get("enabled").?.bool);
                try std.testing.expect(composition.get("owner").?.bool);
                try std.testing.expectEqualStrings("one", composition.get("cardinality").?.string);
                try std.testing.expectEqualStrings("order_key", composition.get("ordered_by").?.string);
            }
            try std.testing.expect(found_owns);
        }

        test "schema-show distinguishes an absent catalog and rejects corrupt catalog bytes" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const catalog_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "catalog.bin" });
            defer std.testing.allocator.free(catalog_path);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            const catalog_bytes = try std.Io.Dir.cwd().readFileAlloc(
                std.testing.io,
                catalog_path,
                std.testing.allocator,
                .limited(64 * 1024 * 1024),
            );
            defer std.testing.allocator.free(catalog_bytes);

            try std.Io.Dir.cwd().deleteFile(std.testing.io, catalog_path);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-show", db_path, "--json" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("{\"catalog\":\"none\",\"format_version\":0}\n", out.buffer.items);

            catalog_bytes[catalog_bytes.len - 1] ^= 0xff;
            try writeSchemaFile(std.testing.io, catalog_path, catalog_bytes);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.InvalidChecksum,
                run(&.{ "tinykg", "schema-show", db_path, "--json" }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
        }

        test "schema file profile labels persist through apply and explicit target migration" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "source.kg" });
            defer std.testing.allocator.free(source_path);
            const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target.kg" });
            defer std.testing.allocator.free(target_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag","markdown-document"],"profile_contracts":{"agent_dag":2,"markdown_document":2}}
            );

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", source_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-apply", source_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=applied") != null);
            {
                var source = try storage.Store.open(std.testing.allocator, std.testing.io, source_path);
                defer source.deinit();
                var source_catalog = (try source.readCatalog()).?;
                defer source_catalog.deinit();
                try std.testing.expectEqual(@as(usize, 2), source_catalog.profiles.items.len);
                try std.testing.expectEqualStrings("agent-dag", source_catalog.profiles.items[0]);
                try std.testing.expectEqualStrings("markdown-document", source_catalog.profiles.items[1]);
            }

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-migrate", source_path, target_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok") != null);
            var target = try storage.Store.open(std.testing.allocator, std.testing.io, target_path);
            defer target.deinit();
            var target_catalog = (try target.readCatalog()).?;
            defer target_catalog.deinit();
            try std.testing.expectEqual(@as(usize, 2), target_catalog.profiles.items.len);
            try std.testing.expectEqualStrings("agent-dag", target_catalog.profiles.items[0]);
            try std.testing.expectEqualStrings("markdown-document", target_catalog.profiles.items[1]);
        }

        test "schema-apply accepts new types and rejects id reuse conflict" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const conflict_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "conflict.json" });
            defer std.testing.allocator.free(conflict_path);

            const schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "concept", 100);
            defer std.testing.allocator.free(schema_content);
            try writeSchemaFile(std.testing.io, schema_path, schema_content);
            const conflict_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "renamed_concept", 100);
            defer std.testing.allocator.free(conflict_content);
            try writeSchemaFile(std.testing.io, conflict_path, conflict_content);

            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

            var apply_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer apply_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &apply_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, apply_out.buffer.items, "result=applied") != null);

            var conflict_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer conflict_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", conflict_path }, &conflict_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, "result=rejected") != null);
            try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, "id_name_mismatch") != null);
        }

        test "kernel-only embedded catalog preserves legacy core writes" {
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
            try run(&.{ "tinykg", "add-node", db_path, "observation", "one" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "observation", "two" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "references", "2" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("edge 1\n", out.buffer.items);
        }

        test "embedded catalog drives CLI node and relation parsing without schema file" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const schema_json =
                \\{"schema_version":3,"node_types":[{"name":"ticket","id":100,"parents":["node"]}],"relation_types":[{"name":"links","id":100,"parents":["edge"],"class":"domain","src_types":["ticket"],"dst_types":["ticket"],"properties":{"confidence":{"type":"enum","values":["draft"]}}}]}
            ;
            try writeSchemaFile(std.testing.io, schema_path, schema_json);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();

            try std.testing.expectError(
                error.UnknownNodeKind,
                run(&.{ "tinykg", "add-node", db_path, "observation", "not declared" }, &out, std.testing.allocator, std.testing.io),
            );
            out.buffer.clearRetainingCapacity();

            try run(&.{ "tinykg", "add-node", db_path, "ticket", "ticket one" }, &out, std.testing.allocator, std.testing.io);
            const first_id = try testExtractNodeId(out.buffer.items);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "ticket", "ticket two" }, &out, std.testing.allocator, std.testing.io);
            const second_id = try testExtractNodeId(out.buffer.items);
            var first_buf: [24]u8 = undefined;
            const first_arg = try std.fmt.bufPrint(&first_buf, "{}", .{first_id});
            var second_buf: [24]u8 = undefined;
            const second_arg = try std.fmt.bufPrint(&second_buf, "{}", .{second_id});

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, first_arg, "links", second_arg }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge 1") != null);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.UnknownRelationKind,
                run(&.{ "tinykg", "add-edge", db_path, first_arg, "references", second_arg }, &out, std.testing.allocator, std.testing.io),
            );
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.UnknownProperty,
                run(&.{ "tinykg", "set-edge-property", db_path, "1", "created_by", "agent" }, &out, std.testing.allocator, std.testing.io),
            );
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.InvalidRecord,
                run(&.{ "tinykg", "set-edge-property", db_path, "1", "confidence", "archived" }, &out, std.testing.allocator, std.testing.io),
            );
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "set-edge-property", db_path, "1", "confidence", "draft" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "find", db_path, "ticket", "ticket one" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.startsWith(u8, out.buffer.items, "1\tticket\tticket one"));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "get", db_path, first_arg }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.startsWith(u8, out.buffer.items, "1\tticket\tticket one"));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "get", db_path, first_arg, "--format", "json", "--meta" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"kind\":\"ticket\"") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "search", db_path, "ticket", "--limit", "2" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\tticket\t") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "search", db_path, "ticket", "--format", "json", "--meta", "--limit", "2" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"kind\":\"ticket\"") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "neighbors", db_path, first_arg, "links" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "links") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "ticket two") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "neighbors", db_path, first_arg, "links", "--format", "json", "--meta", "--depth", "1" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"kind\":\"ticket\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "\"rel\":\"links\"") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "incoming", db_path, second_arg, "links" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "links") != null);
        }

        test "schema-apply rejects destructive type and property evolution" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);

            const initial =
                \\{"schema_version":3,"node_types":[{"name":"concept","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft","published"],"required":false,"nullable":true},"rank":{"type":"uint","required":false,"nullable":true}}}]}
            ;
            try writeSchemaFile(std.testing.io, schema_path, initial);
            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);
            var apply_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer apply_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &apply_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, apply_out.buffer.items, "result=applied") != null);

            const cases = [_]struct { schema_json: []const u8, expected_conflict: []const u8 }{
                .{
                    .schema_json =
                    \\{"schema_version":3}
                    ,
                    .expected_conflict = "type_removed",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"node_types":[{"name":"concept","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft"],"required":false,"nullable":true},"rank":{"type":"uint","required":false,"nullable":true}}}]}
                    ,
                    .expected_conflict = "enum_value_removed",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"node_types":[{"name":"concept","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft","published"],"required":false,"nullable":true},"rank":{"type":"string","required":false,"nullable":true}}}]}
                    ,
                    .expected_conflict = "property_type_changed",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"node_types":[{"name":"concept","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft","published"],"required":true,"nullable":false},"rank":{"type":"uint","required":false,"nullable":true}}}]}
                    ,
                    .expected_conflict = "property_constraint_tightened",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"node_types":[{"name":"concept","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft","published"],"required":false,"nullable":true},"rank":{"type":"uint","required":false,"nullable":true},"owner":{"type":"string","required":true,"nullable":false}}}]}
                    ,
                    .expected_conflict = "required_property_added",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"node_types":[{"name":"concept","id":100,"properties":{"state":{"type":"enum","values":["draft","published"],"required":false,"nullable":true},"rank":{"type":"uint","required":false,"nullable":true}}}]}
                    ,
                    .expected_conflict = "parent_set_changed",
                },
            };
            for (cases) |case| {
                try writeSchemaFile(std.testing.io, schema_path, case.schema_json);
                var conflict_out = QueryOutputWriter{ .allocator = std.testing.allocator };
                defer conflict_out.buffer.deinit(std.testing.allocator);
                try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &conflict_out, std.testing.allocator, std.testing.io);
                try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, "result=rejected") != null);
                try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, case.expected_conflict) != null);
            }
        }

        test "schema-apply cannot narrow canonical task status" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);

            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"]}
            );
            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);
            var apply_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer apply_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &apply_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, apply_out.buffer.items, "result=applied") != null);

            const narrowed = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"schema_version\":3,\"profiles\":[\"agent-dag\"],\"node_types\":[{{\"name\":\"task\",\"id\":{},\"properties\":{{\"status\":{{\"type\":\"enum\",\"values\":[\"open\"],\"required\":true,\"nullable\":false}}}}}}]}}",
                .{@intFromEnum(core.NodeKind.task)},
            );
            defer std.testing.allocator.free(narrowed);
            try writeSchemaFile(std.testing.io, schema_path, narrowed);
            var conflict_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer conflict_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &conflict_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, "result=rejected") != null);
            try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, "enum_value_removed") != null);
        }

        test "schema-apply rejects relation semantic rewrites" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);

            const initial =
                \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"parents":["edge"],"class":"domain","src_types":["project"],"dst_types":["project"],"composition":{"enabled":true,"owner":false,"cardinality":"many"}}]}
            ;
            try writeSchemaFile(std.testing.io, schema_path, initial);
            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);
            var apply_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer apply_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &apply_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, apply_out.buffer.items, "result=applied") != null);

            const cases = [_]struct { schema_json: []const u8, expected_conflict: []const u8 }{
                .{
                    .schema_json =
                    \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"parents":["edge"],"class":"sys","src_types":["project"],"dst_types":["project"],"composition":{"enabled":true,"owner":false,"cardinality":"many"}}]}
                    ,
                    .expected_conflict = "relation_class_changed",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"parents":["edge"],"class":"domain","src_types":["node"],"dst_types":["project"],"composition":{"enabled":true,"owner":false,"cardinality":"many"}}]}
                    ,
                    .expected_conflict = "endpoint_rule_changed",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"parents":["edge"],"class":"domain","src_types":["project"],"dst_types":["project"],"composition":{"enabled":true,"owner":true,"cardinality":"many"}}]}
                    ,
                    .expected_conflict = "composition_changed",
                },
                .{
                    .schema_json =
                    \\{"schema_version":3,"relation_types":[{"name":"links","id":100,"class":"domain","src_types":["project"],"dst_types":["project"],"composition":{"enabled":true,"owner":false,"cardinality":"many"}}]}
                    ,
                    .expected_conflict = "parent_set_changed",
                },
            };
            for (cases) |case| {
                try writeSchemaFile(std.testing.io, schema_path, case.schema_json);
                var conflict_out = QueryOutputWriter{ .allocator = std.testing.allocator };
                defer conflict_out.buffer.deinit(std.testing.allocator);
                try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &conflict_out, std.testing.allocator, std.testing.io);
                try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, "result=rejected") != null);
                try std.testing.expect(std.mem.indexOf(u8, conflict_out.buffer.items, case.expected_conflict) != null);
            }
        }

        test "schema constrained node version writes reject missing native relation before mutation" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"node_types":[{"name":"decision","id":11,"parents":["node"]}]}
            );

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "decision", "original", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();

            try std.testing.expectError(
                error.UnknownRelationKind,
                run(&.{ "tinykg", "update-node", db_path, "1", "decision", "updated", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
            try std.testing.expectError(
                error.UnknownRelationKind,
                run(&.{ "tinykg", "append-node-version", db_path, "1", "decision", "appended", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);

            try run(&.{ "tinykg", "stats", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("nodes=1 edges=0\n", out.buffer.items);
        }

        test "canonical agent profile native relations stay known after real writes" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag","markdown-document"]}
            );

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "task", "goal", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "document", "worklog", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "decision", "original", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "related_to", "2", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "append-node-version", db_path, "3", "decision", "current", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "governance", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);

            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_unknown_relation_type_edges=0\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "traversable_relation_count related_to=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "traversable_relation_count deprecated_by=1\n") != null);
        }

        test "canonical schema keeps unrelated unknown relation debt visible" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const batch_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "existing-unknown-edge.jsonl" });
            defer std.testing.allocator.free(batch_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"]}
            );

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "decision", "first", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "decision", "second", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", db_path, "1", "related_to", "2", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            // Deliberately bypass application-schema enforcement to model historical
            // or imported debt.  Canonical registration must not turn arbitrary ids
            // into accepted relations or suppress their governance evidence.
            try run(&.{ "tinykg", "add-edge", db_path, "1", "rel#100", "2" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_apply result=applied") != null);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = batch_path,
                .data =
                \\{"version":1}
                \\{"op":"edge","id":2,"src":1,"rel":"rel#100","dst":2}
                ,
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "apply", db_path, batch_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edges_created=0 edges_existing=1") != null);

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "governance", db_path }, &out, std.testing.allocator, std.testing.io);

            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_unknown_relation_type_edges=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_unknown_relation_edge_sample edge=2 rel#100 src=1 dst=2\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "traversable_relation_count related_to=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "traversable_relation_count rel#100=1\n") != null);
        }

        test "schema apply additively upgrades embedded catalog for native version relations" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const old_schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "old-schema.json" });
            defer std.testing.allocator.free(old_schema_path);
            const canonical_schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "canonical-schema.json" });
            defer std.testing.allocator.free(canonical_schema_path);
            const current_schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "current-schema.json" });
            defer std.testing.allocator.free(current_schema_path);
            try writeSchemaFile(std.testing.io, old_schema_path,
                \\{"schema_version":3,"node_types":[{"name":"decision","id":11,"parents":["node"]},{"name":"evidence","id":12,"parents":["node"]}],"relation_types":[{"name":"based_on","id":9,"parents":["edge"],"class":"prov"}]}
            );
            // Model a live catalog whose unrelated based_on endpoint policy predates
            // the distributed canonical JSON. The full document must remain
            // fail-closed instead of using native-relation registration to rewrite it.
            try writeSchemaFile(std.testing.io, canonical_schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"],"relation_types":[{"name":"based_on","id":9,"class":"prov","src_types":["decision"],"dst_types":["evidence"]}]}
            );
            try writeSchemaFile(std.testing.io, current_schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"]}
            );

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", old_schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_apply result=applied") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "decision", "original" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();

            try std.testing.expectError(
                error.UnknownRelationKind,
                run(&.{ "tinykg", "append-node-version", db_path, "1", "decision", "rejected before schema refresh" }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);
            try run(&.{ "tinykg", "stats", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("nodes=1 edges=0\n", out.buffer.items);
            out.buffer.clearRetainingCapacity();

            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", canonical_schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_apply result=rejected conflicts=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "conflict kind=endpoint_rule_changed domain=relation id=9") != null);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.UnknownRelationKind,
                run(&.{ "tinykg", "append-node-version", db_path, "1", "decision", "still rejected after incompatible schema" }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expectEqual(@as(usize, 0), out.buffer.items.len);

            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", current_schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_apply result=applied") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "append-node-version", db_path, "1", "decision", "accepted after schema refresh" }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "rel=deprecated_by") != null);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "governance", db_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_unknown_relation_type_edges=0\n") != null);

            const manifest = try readStoreManifestSummary(std.testing.allocator, std.testing.io, db_path);
            defer manifest.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("3", manifest.schema_version);
        }

        test "schema-validate detects unknown kind in real data" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);

            const schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "concept", 100);
            defer std.testing.allocator.free(schema_content);
            try writeSchemaFile(std.testing.io, schema_path, schema_content);

            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &init_out, std.testing.allocator, std.testing.io);

            var add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer add_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "add-node", db_path, "task", "a task node" }, &add_out, std.testing.allocator, std.testing.io);

            var validate_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer validate_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-validate", db_path, "--schema", schema_path }, &validate_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, validate_out.buffer.items, "SchemaUnknownKindInData") != null);
            try std.testing.expect(std.mem.indexOf(u8, validate_out.buffer.items, "unknown_kinds_in_data=1") != null);
        }

        test "schema-validate distinguishes catalog types orphaned by a candidate" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const existing_schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "existing.json" });
            defer std.testing.allocator.free(existing_schema_path);
            const candidate_schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "candidate.json" });
            defer std.testing.allocator.free(candidate_schema_path);
            try writeSchemaFile(std.testing.io, existing_schema_path,
                \\{"schema_version":3,"node_types":[{"name":"ticket","id":100,"parents":["node"]}]}
            );
            try writeSchemaFile(std.testing.io, candidate_schema_path,
                \\{"schema_version":3}
            );

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", db_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-apply", db_path, "--schema", existing_schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", db_path, "ticket", "catalog-owned data", "--schema", existing_schema_path }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-validate", db_path, "--schema", candidate_schema_path }, &out, std.testing.allocator, std.testing.io);

            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "SchemaOrphanedTypeInUse domain=node kind=100 name=ticket count=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "SchemaUnknownKindInData") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_validate result=invalid endpoint_violations=0 unknown_kinds_in_data=0 orphaned_types=1\n") != null);
        }

        test "schema-validate scans based_on endpoints before candidate narrowing" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"],"profile_contracts":{"agent_dag":2}}
            );

            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.createEmpty();
                try store.appendNodesBatch(&.{
                    .{ .id = .fromInt(1), .kind = .decision, .text = "valid source" },
                    .{ .id = .fromInt(2), .kind = .evidence, .text = "valid target" },
                });
                try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .based_on, .dst = .fromInt(2) });
            }

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-validate", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "relation_type id=9 name=based_on data_count=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "SchemaEndpointViolation") == null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_validate result=ok endpoint_violations=0 unknown_kinds_in_data=0 orphaned_types=0\n") != null);

            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.appendNodesBatch(&.{
                    .{ .id = .fromInt(3), .kind = .edit, .text = "near-miss source" },
                    .{ .id = .fromInt(4), .kind = .evidence, .text = "near-miss target" },
                });
                // Bypass the candidate schema intentionally: schema-validate must
                // classify historical/imported data that predates the narrowing.
                try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(3), .rel = .based_on, .dst = .fromInt(4) });
            }

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-validate", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "relation_type id=9 name=based_on data_count=2\n") != null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                out.buffer.items,
                "SchemaEndpointViolation edge=2 rel=based_on rel_id=9 src=3 src_kind=edit src_kind_id=17 dst=4 dst_kind=evidence dst_kind_id=12\n",
            ) != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_validate result=invalid endpoint_violations=1 unknown_kinds_in_data=0 orphaned_types=0\n") != null);
        }

        test "schema-validate unknown endpoint kinds do not truncate later violations" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"],"profile_contracts":{"agent_dag":2}}
            );

            {
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
                defer store.deinit();
                try store.createEmpty();
                try store.appendNodesBatch(&.{
                    .{ .id = .fromInt(1), .kind = .repo, .text = "unregistered historical kind" },
                    .{ .id = .fromInt(2), .kind = .evidence, .text = "first target" },
                    .{ .id = .fromInt(3), .kind = .edit, .text = "registered near miss" },
                    .{ .id = .fromInt(4), .kind = .evidence, .text = "second target" },
                });
                try store.appendEdgesBatch(&.{
                    .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .based_on, .dst = .fromInt(2) },
                    .{ .id = .fromInt(2), .src = .fromInt(3), .rel = .based_on, .dst = .fromInt(4) },
                });
            }

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-validate", db_path, "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "SchemaUnknownKindInData domain=node kind=0 count=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "relation_type id=9 name=based_on data_count=2\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "SchemaEndpointViolation edge=2 rel=based_on") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "endpoint_violations=1 unknown_kinds_in_data=1") != null);
        }

        test "schema-validate endpoint samples retain the stable lowest bounded ids" {
            var samples = SchemaEndpointViolationSamples{};
            for (0..10) |index| {
                const edge_id: u64 = @intCast(10 - index);
                samples.record(.{
                    .edge_id = edge_id,
                    .rel_id = @intFromEnum(core.RelKind.based_on),
                    .src_id = edge_id * 2,
                    .src_kind_id = @intFromEnum(core.NodeKind.edit),
                    .dst_id = edge_id * 2 + 1,
                    .dst_kind_id = @intFromEnum(core.NodeKind.evidence),
                });
            }
            try std.testing.expectEqual(schema_validate_sample_limit, samples.len);
            for (samples.items[0..samples.len], 1..) |sample, expected_id| {
                try std.testing.expectEqual(@as(u64, @intCast(expected_id)), sample.edge_id);
            }
        }

        test "schema-validate writer failure cannot publish a success verdict" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"],"profile_contracts":{"agent_dag":2}}
            );
            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNode(.{ .id = .fromInt(1), .kind = .decision, .text = "visible before verdict" });

            const VerdictFailingWriter = struct {
                allocator: std.mem.Allocator,
                buffer: std.ArrayList(u8) = .empty,

                fn deinit(self: *@This()) void {
                    self.buffer.deinit(self.allocator);
                }

                pub fn writeAll(self: *@This(), bytes: []const u8) !void {
                    try self.buffer.appendSlice(self.allocator, bytes);
                }

                pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
                    if (std.mem.startsWith(u8, fmt, "schema_validate result=")) return error.OutputClosed;
                    const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
                    defer self.allocator.free(rendered);
                    try self.writeAll(rendered);
                }
            };
            var writer = VerdictFailingWriter{ .allocator = std.testing.allocator };
            defer writer.deinit();
            try std.testing.expectError(error.OutputClosed, runSchemaValidate(
                std.testing.allocator,
                std.testing.io,
                &writer,
                store,
                .{ .db_path = db_path, .schema_path = schema_path, .profiles = null },
            ));
            try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "node_type id=11 name=decision data_count=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "schema_validate result=") == null);
        }

        const SchemaValidateAllocationFixture = struct {
            store: storage.Store,
            db_path: []const u8,
            schema_path: []const u8,
        };

        fn exerciseSchemaValidateAllocationFailure(allocator: std.mem.Allocator, fixture: SchemaValidateAllocationFixture) !void {
            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);
            runSchemaValidate(
                allocator,
                std.testing.io,
                &out,
                fixture.store,
                .{ .db_path = fixture.db_path, .schema_path = fixture.schema_path, .profiles = null },
            ) catch |err| {
                try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_validate result=") == null);
                return err;
            };
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_validate result=ok endpoint_violations=0") != null);
        }

        test "schema-validate allocation failures cannot publish a success verdict" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            try writeSchemaFile(std.testing.io, schema_path,
                \\{"schema_version":3,"profiles":["agent-dag"],"profile_contracts":{"agent_dag":2}}
            );
            var store = try storage.Store.init(std.testing.allocator, std.testing.io, db_path);
            defer store.deinit();
            try store.createEmpty();
            try store.appendNodesBatch(&.{
                .{ .id = .fromInt(1), .kind = .decision, .text = "allocation source" },
                .{ .id = .fromInt(2), .kind = .evidence, .text = "allocation target" },
            });
            try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .based_on, .dst = .fromInt(2) });

            try std.testing.checkAllAllocationFailures(
                std.testing.allocator,
                exerciseSchemaValidateAllocationFailure,
                .{SchemaValidateAllocationFixture{ .store = store, .db_path = db_path, .schema_path = schema_path }},
            );
        }

        // ── 项目级 schema(applies_to,严格精确无继承)测试 ─────────────────────────
        // 从 "node <id> created=..." / "governed node=<id> ..." 里抠第一个 node id。
        fn testExtractNodeId(buf: []const u8) !u64 {
            const key = "node ";
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, buf, i, key)) |at| {
                var p = at + key.len;
                // 跳过 "node=" 形式:上面 key 是 "node ",这里再兼容 "node=" 需另找
                if (p < buf.len and buf[p] >= '0' and buf[p] <= '9') {
                    var v: u64 = 0;
                    while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') : (p += 1) v = v * 10 + (buf[p] - '0');
                    return v;
                }
                i = at + 1;
            }
            return error.NotFound;
        }

        test "project-scoped schema: restricted type violates in unlisted project, ok in listed (strict)" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db);
            const a = std.testing.allocator;

            var out = QueryOutputWriter{ .allocator = a };
            defer out.buffer.deinit(a);
            const reset = struct {
                fn f(o: *QueryOutputWriter, alloc: std.mem.Allocator) void {
                    o.buffer.deinit(alloc);
                    o.* = .{ .allocator = alloc };
                }
            }.f;

            try run(&.{ "tinykg", "init", db }, &out, a, std.testing.io);
            reset(&out, a);
            // projA, projB
            try run(&.{ "tinykg", "ensure-node", db, "project", "projA", "--schema-type", "project" }, &out, a, std.testing.io);
            const pa = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            try run(&.{ "tinykg", "ensure-node", db, "project", "projB", "--schema-type", "project" }, &out, a, std.testing.io);
            const pb = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            // migration 节点各挂一个
            try run(&.{ "tinykg", "add-node", db, "observation", "mig in A", "--schema-type", "migration" }, &out, a, std.testing.io);
            const na = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            var pa_buf: [24]u8 = undefined;
            const pa_str = try std.fmt.bufPrint(&pa_buf, "{d}", .{pa});
            var na_buf: [24]u8 = undefined;
            const na_str = try std.fmt.bufPrint(&na_buf, "{d}", .{na});
            try run(&.{ "tinykg", "govern-node", db, na_str, "--parent", pa_str, "--schema-type", "migration" }, &out, a, std.testing.io);
            reset(&out, a);
            try run(&.{ "tinykg", "add-node", db, "observation", "mig in B", "--schema-type", "migration" }, &out, a, std.testing.io);
            const nb = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            var pb_buf: [24]u8 = undefined;
            const pb_str = try std.fmt.bufPrint(&pb_buf, "{d}", .{pb});
            var nb_buf: [24]u8 = undefined;
            const nb_str = try std.fmt.bufPrint(&nb_buf, "{d}", .{nb});
            try run(&.{ "tinykg", "govern-node", db, nb_str, "--parent", pb_str, "--schema-type", "migration" }, &out, a, std.testing.io);
            reset(&out, a);

            // 声明 migration 只属 projA → projB 里的 migration 违规,projA 里的合法。
            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projA" }, &out, a, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_scope_violations=1") != null);
            // 违规样本指向 projB 里的节点 nb,不是 projA 里的 na。
            var vexp: [40]u8 = undefined;
            const vline = try std.fmt.bufPrint(&vexp, "violation node={d} not in scope", .{nb});
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, vline) != null);
            reset(&out, a);

            // 把 projA,projB 都列入 → 无违规。
            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projA,projB" }, &out, a, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_scope_violations=0") != null);
        }

        test "project-scoped schema: if-absent preserves existing policy and deduplicates projects" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db);
            const allocator = std.testing.allocator;
            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);

            try run(&.{ "tinykg", "init", db }, &out, allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-node", db, "project", "projA", "--schema-type", "project" }, &out, allocator, std.testing.io);
            const project_a = try testExtractNodeId(out.buffer.items);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "ensure-node", db, "project", "projB", "--schema-type", "project" }, &out, allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();

            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projA,projA", "--enforce", "block" }, &out, allocator, std.testing.io);
            var expected_projects: [64]u8 = undefined;
            const expected_projects_text = try std.fmt.bufPrint(&expected_projects, "projects=[{d}] enforce=block", .{project_a});
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, expected_projects_text) != null);
            out.buffer.clearRetainingCapacity();

            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projB", "--enforce", "report", "--if-absent" }, &out, allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "created=0 type=migration unchanged=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_scope_violations=") == null);

            var store = try storage.Store.open(allocator, std.testing.io, db);
            defer store.deinit();
            var policy = (try findSchemaScopePolicy(allocator, store, "migration")) orelse return error.NotFound;
            defer policy.deinit(allocator);
            try std.testing.expect(policy.enforce_block);
            try std.testing.expectEqualSlices(u64, &.{project_a}, policy.project_ids.items);
        }

        test "project-scoped schema: strict no-inheritance across nested project boundary" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db);
            const a = std.testing.allocator;
            var out = QueryOutputWriter{ .allocator = a };
            defer out.buffer.deinit(a);
            const reset = struct {
                fn f(o: *QueryOutputWriter, alloc: std.mem.Allocator) void {
                    o.buffer.deinit(alloc);
                    o.* = .{ .allocator = alloc };
                }
            }.f;

            try run(&.{ "tinykg", "init", db }, &out, a, std.testing.io);
            reset(&out, a);
            try run(&.{ "tinykg", "ensure-node", db, "project", "projA", "--schema-type", "project" }, &out, a, std.testing.io);
            const pa = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            try run(&.{ "tinykg", "ensure-node", db, "project", "projSub", "--schema-type", "project" }, &out, a, std.testing.io);
            const ps = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            var pa_buf: [24]u8 = undefined;
            const pa_str = try std.fmt.bufPrint(&pa_buf, "{d}", .{pa});
            var ps_buf: [24]u8 = undefined;
            const ps_str = try std.fmt.bufPrint(&ps_buf, "{d}", .{ps});
            // projSub 嵌套在 projA 下
            try run(&.{ "tinykg", "govern-node", db, ps_str, "--parent", pa_str, "--schema-type", "project" }, &out, a, std.testing.io);
            reset(&out, a);
            // migration 节点挂 projSub 下
            try run(&.{ "tinykg", "add-node", db, "observation", "mig in Sub", "--schema-type", "migration" }, &out, a, std.testing.io);
            const ns = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            var ns_buf: [24]u8 = undefined;
            const ns_str = try std.fmt.bufPrint(&ns_buf, "{d}", .{ns});
            try run(&.{ "tinykg", "govern-node", db, ns_str, "--parent", ps_str, "--schema-type", "migration" }, &out, a, std.testing.io);
            reset(&out, a);

            // scope=projA(不含 projSub)→ projSub 里的 migration 违规(无继承)。
            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projA" }, &out, a, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_scope_violations=1") != null);
            reset(&out, a);
            // 显式加 projSub → 合法。
            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projA,projSub" }, &out, a, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_scope_violations=0") != null);
        }

        test "project-scoped schema: enforce=block rejects out-of-scope attach at write time" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db);
            const a = std.testing.allocator;
            var out = QueryOutputWriter{ .allocator = a };
            defer out.buffer.deinit(a);
            const reset = struct {
                fn f(o: *QueryOutputWriter, alloc: std.mem.Allocator) void {
                    o.buffer.deinit(alloc);
                    o.* = .{ .allocator = alloc };
                }
            }.f;

            try run(&.{ "tinykg", "init", db }, &out, a, std.testing.io);
            reset(&out, a);
            try run(&.{ "tinykg", "ensure-node", db, "project", "projA", "--schema-type", "project" }, &out, a, std.testing.io);
            const pa = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            try run(&.{ "tinykg", "ensure-node", db, "project", "projB", "--schema-type", "project" }, &out, a, std.testing.io);
            const pb = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            // 声明 migration block 档只允许 projA
            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projA", "--enforce", "block" }, &out, a, std.testing.io);
            reset(&out, a);
            var pa_buf: [24]u8 = undefined;
            const pa_str = try std.fmt.bufPrint(&pa_buf, "{d}", .{pa});
            var pb_buf: [24]u8 = undefined;
            const pb_str = try std.fmt.bufPrint(&pb_buf, "{d}", .{pb});
            // 挂 projA 下 → 成功
            try run(&.{ "tinykg", "add-node", db, "observation", "ok in A", "--schema-type", "migration" }, &out, a, std.testing.io);
            const n1 = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            var n1_buf: [24]u8 = undefined;
            const n1_str = try std.fmt.bufPrint(&n1_buf, "{d}", .{n1});
            try run(&.{ "tinykg", "govern-node", db, n1_str, "--parent", pa_str, "--schema-type", "migration" }, &out, a, std.testing.io);
            reset(&out, a);
            // 挂 projB 下 → block 档拒绝(govern-node 返回 error)
            try run(&.{ "tinykg", "add-node", db, "observation", "block in B", "--schema-type", "migration" }, &out, a, std.testing.io);
            const n2 = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            var n2_buf: [24]u8 = undefined;
            const n2_str = try std.fmt.bufPrint(&n2_buf, "{d}", .{n2});
            const res = run(&.{ "tinykg", "govern-node", db, n2_str, "--parent", pb_str, "--schema-type", "migration" }, &out, a, std.testing.io);
            try std.testing.expectError(error.SchemaProjectScopeViolation, res);
        }

        test "project-scoped schema: unscoped type is global (no violation anywhere)" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db);
            const a = std.testing.allocator;
            var out = QueryOutputWriter{ .allocator = a };
            defer out.buffer.deinit(a);
            const reset = struct {
                fn f(o: *QueryOutputWriter, alloc: std.mem.Allocator) void {
                    o.buffer.deinit(alloc);
                    o.* = .{ .allocator = alloc };
                }
            }.f;
            try run(&.{ "tinykg", "init", db }, &out, a, std.testing.io);
            reset(&out, a);
            try run(&.{ "tinykg", "ensure-node", db, "project", "projA", "--schema-type", "project" }, &out, a, std.testing.io);
            const pa = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            // observation(全局类型,无 scope 声明)挂 projA → 声明另一个类型 scope 不影响它。
            try run(&.{ "tinykg", "add-node", db, "observation", "global obs", "--schema-type", "observation" }, &out, a, std.testing.io);
            const no = try testExtractNodeId(out.buffer.items);
            reset(&out, a);
            var pa_buf: [24]u8 = undefined;
            const pa_str = try std.fmt.bufPrint(&pa_buf, "{d}", .{pa});
            var no_buf: [24]u8 = undefined;
            const no_str = try std.fmt.bufPrint(&no_buf, "{d}", .{no});
            try run(&.{ "tinykg", "govern-node", db, no_str, "--parent", pa_str, "--schema-type", "observation" }, &out, a, std.testing.io);
            reset(&out, a);
            // 声明 migration scope(与 observation 无关)→ observation 节点不违规。
            try run(&.{ "tinykg", "schema-scope", db, "migration", "--project", "projA" }, &out, a, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "schema_scope_violations=0") != null);
        }

        test "schema-migrate staging recovery never deletes unmarked foreign state" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const target = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "target.kg" });
            defer std.testing.allocator.free(target);
            const staging = try schemaMigrationStagingPath(std.testing.allocator, target);
            defer std.testing.allocator.free(staging);
            const expected = SchemaMigrationTransactionExpectation{
                .canonical_source_path = "test-source",
                .source_store_bytes = 1,
                .source_store_digest = .{ 1, 2, 3, 4 },
                .source_registry_digest = .{ 5, 6, 7, 8 },
                .target_catalog_digest = .{ 9, 10, 11, 12 },
                .target_profiles = "",
                .target_schema_version = 2,
                .target_kind_remaps = 0,
            };

            try std.Io.Dir.cwd().createDir(std.testing.io, staging, .default_dir);
            try recoverSchemaMigrationStaging(std.testing.allocator, std.testing.io, staging, expected);
            try std.testing.expect(!try anyPathExists(std.testing.io, staging));

            try std.Io.Dir.cwd().createDir(std.testing.io, staging, .default_dir);
            const foreign = try std.fs.path.join(std.testing.allocator, &.{ staging, "foreign" });
            defer std.testing.allocator.free(foreign);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = foreign,
                .data = "do not delete",
                .flags = .{ .truncate = true },
            });
            try std.testing.expectError(
                error.MigrationRecoveryConflict,
                recoverSchemaMigrationStaging(std.testing.allocator, std.testing.io, staging, expected),
            );
            try std.testing.expect(try fileExists(std.testing.io, foreign));
        }

        test "migration sidecar copy rejects asymmetric deferred edges" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sidecar-source.kg" });
            defer std.testing.allocator.free(source_path);
            const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sidecar-target.kg" });
            defer std.testing.allocator.free(target_path);

            var source = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
            defer source.deinit();
            try source.createEmpty();
            try source.appendNodesBatch(&.{
                .{ .id = .fromInt(1), .kind = .evidence, .text = "source" },
                .{ .id = .fromInt(2), .kind = .document, .text = "target" },
            });
            _ = try writeMetaknowDeferredBasedOnForwardPairsSidecar(
                std.testing.allocator,
                source,
                &.{.{ .src = 1, .dst = 2 }},
                2,
            );

            const sidecar_path = try metaknowDeferredBasedOnPath(std.testing.allocator, source);
            defer std.testing.allocator.free(sidecar_path);
            var sidecar = try std.Io.Dir.cwd().openFile(std.testing.io, sidecar_path, .{ .mode = .read_write });
            var header: [metaknow_deferred_based_on_header_len]u8 = undefined;
            try std.testing.expectEqual(header.len, try sidecar.readPositionalAll(std.testing.io, &header, 0));
            const reverse_target_offset = std.mem.readInt(u64, header[64..72], .little);
            var wrong_target: [4]u8 = undefined;
            std.mem.writeInt(u32, &wrong_target, 2, .little);
            try sidecar.writePositionalAll(std.testing.io, &wrong_target, reverse_target_offset);
            sidecar.close(std.testing.io);

            try createOwnedDirectory(std.testing.io, target_path);
            try std.testing.expectError(
                error.InvalidRecord,
                copyMetaknowDeferredBasedOnSidecarForMigration(std.testing.allocator, std.testing.io, source_path, target_path),
            );
            const target_sidecar_path = try metaknowDeferredBasedOnPathForDb(std.testing.allocator, target_path);
            defer std.testing.allocator.free(target_sidecar_path);
            try std.testing.expect(!try anyPathExists(std.testing.io, target_sidecar_path));
        }

        test "schema-migrate atomically replaces marked staging and acknowledges promoted target" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "old.kg" });
            defer std.testing.allocator.free(old_db);
            const other_old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "other-old.kg" });
            defer std.testing.allocator.free(other_old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "new.kg" });
            defer std.testing.allocator.free(new_db);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "schema.json" });
            defer std.testing.allocator.free(schema_path);
            const other_schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "other-schema.json" });
            defer std.testing.allocator.free(other_schema_path);
            const staging = try schemaMigrationStagingPath(std.testing.allocator, new_db);
            defer std.testing.allocator.free(staging);

            const schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "custom_concept", 100);
            defer std.testing.allocator.free(schema_content);
            try writeSchemaFile(std.testing.io, schema_path, schema_content);
            const other_schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "custom_concept", 200);
            defer std.testing.allocator.free(other_schema_content);
            try writeSchemaFile(std.testing.io, other_schema_path, other_schema_content);
            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", old_db }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", old_db, "custom_concept", "recoverable concept", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);
            const source_metadata_path = try std.fs.path.join(std.testing.allocator, &.{ old_db, "source-metadata" });
            defer std.testing.allocator.free(source_metadata_path);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = source_metadata_path,
                .data = "alpha",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "init", other_old_db }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", other_old_db, "custom_concept", "different source", "--schema", schema_path }, &out, std.testing.allocator, std.testing.io);

            const canonical_source = try canonicalProspectivePath(std.testing.allocator, std.testing.io, old_db);
            defer std.testing.allocator.free(canonical_source);
            var source_store = try storage.Store.open(std.testing.allocator, std.testing.io, old_db);
            defer source_store.deinit();
            var source_catalog = if (try source_store.readCatalog()) |catalog_value|
                catalog_value
            else
                try catalog_mod.Catalog.kernelOnly(std.testing.allocator);
            defer source_catalog.deinit();
            const source_manifest = try readStoreManifestSummary(std.testing.allocator, std.testing.io, old_db);
            defer source_manifest.deinit(std.testing.allocator);
            var old_registry = try loadSchemaRegistryFile(std.testing.allocator, std.testing.io, schema_path);
            defer old_registry.deinit();
            var target_registry = try loadSchemaRegistryFile(std.testing.allocator, std.testing.io, schema_path);
            var target_registry_owned = true;
            errdefer if (target_registry_owned) target_registry.deinit();
            var target_catalog = try catalog_mod.Catalog.fromRegistry(std.testing.allocator, target_registry);
            target_registry_owned = false;
            defer target_catalog.deinit();
            target_catalog.revision = std.math.add(u32, source_catalog.revision, 1) catch return error.RecordTooLarge;
            const target_profiles = try catalogProfilesCsvAlloc(std.testing.allocator, target_catalog);
            defer std.testing.allocator.free(target_profiles);
            const source_identity = try storeContentIdentity(std.testing.allocator, std.testing.io, old_db);
            const expected = SchemaMigrationTransactionExpectation{
                .canonical_source_path = canonical_source,
                .source_store_bytes = source_identity.bytes,
                .source_store_digest = source_identity.digest,
                .source_registry_digest = try schemaRegistryContentDigest(std.testing.allocator, old_registry),
                .target_catalog_digest = try catalogContentDigest(std.testing.allocator, target_catalog),
                .target_profiles = target_profiles,
                .target_schema_version = schemaMigrationManifestVersion(source_manifest),
                .target_kind_remaps = 0,
            };

            // Simulate a process death before publication. The final path is absent;
            // the next locked attempt may reclaim only its private marked stage.
            try createOwnedDirectory(std.testing.io, staging);
            try writeSchemaMigrationTransactionMarker(std.testing.allocator, std.testing.io, staging, expected, null);
            const partial = try std.fs.path.join(std.testing.allocator, &.{ staging, "partial" });
            defer std.testing.allocator.free(partial);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = partial,
                .data = "partial",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok") != null);
            try std.testing.expect(!try anyPathExists(std.testing.io, staging));
            try std.testing.expect(try schemaMigrationTransactionMarkerPresent(std.testing.allocator, std.testing.io, new_db));

            // The complete receipt binds the exact source, schemas, result, and target.
            var migrated_store = try storage.Store.open(std.testing.allocator, std.testing.io, new_db);
            const migrated_stats = try migrated_store.stats();
            migrated_store.deinit();
            const published_identity = try storeContentIdentity(std.testing.allocator, std.testing.io, new_db);
            var publication_result = SchemaMigrationPublicationResult{
                .nodes_migrated = migrated_stats.nodes,
                .edges_migrated = migrated_stats.edges,
                .kind_remaps = 0,
                .published_store_bytes = published_identity.bytes,
                .published_store_digest = published_identity.digest,
            };
            const schema_marker_path = try schemaMigrationTransactionMarkerPath(std.testing.allocator, new_db);
            defer std.testing.allocator.free(schema_marker_path);
            try rewriteTransactionMarkerFormatForTest(
                std.testing.io,
                schema_marker_path,
                schema_migration_transaction_marker_format,
                schema_migration_transaction_marker_legacy_format,
            );

            // Same-size source mutation changes the request identity.
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = source_metadata_path,
                .data = "bravo",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.MigrationRecoveryConflict,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = source_metadata_path,
                .data = "alpha",
                .flags = .{ .truncate = true },
            });

            // A different source registry is a different request even when the target
            // catalog is byte-identical.
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.MigrationRecoveryConflict,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", other_schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io),
            );

            // A different requested target catalog or source must never be acknowledged.
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.MigrationRecoveryConflict,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", schema_path, "--to", other_schema_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(try schemaMigrationTransactionMarkerPresent(std.testing.allocator, std.testing.io, new_db));
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.MigrationRecoveryConflict,
                run(&.{ "tinykg", "schema-migrate", other_old_db, new_db, "--from", schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(try schemaMigrationTransactionMarkerPresent(std.testing.allocator, std.testing.io, new_db));

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok recovered=1") != null);
            try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, schema_marker_path, schema_migration_transaction_marker_format));

            // An equal-length target mutation cannot pass recovery by preserving graph
            // counts, catalog, and manifest alone.
            const target_metadata_path = try std.fs.path.join(std.testing.allocator, &.{ new_db, "target-metadata" });
            defer std.testing.allocator.free(target_metadata_path);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = target_metadata_path,
                .data = "alpha",
                .flags = .{ .truncate = true },
            });
            const target_with_metadata = try storeContentIdentity(std.testing.allocator, std.testing.io, new_db);
            publication_result.published_store_bytes = target_with_metadata.bytes;
            publication_result.published_store_digest = target_with_metadata.digest;
            try writeSchemaMigrationTransactionMarker(std.testing.allocator, std.testing.io, new_db, expected, publication_result);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = target_metadata_path,
                .data = "bravo",
                .flags = .{ .truncate = true },
            });
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.MigrationRecoveryConflict,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io),
            );
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = target_metadata_path,
                .data = "alpha",
                .flags = .{ .truncate = true },
            });

            // The exact original invocation acknowledges the already committed
            // target instead of deleting or rebuilding it.
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok recovered=1") != null);
            try std.testing.expect(try schemaMigrationTransactionMarkerPresent(std.testing.allocator, std.testing.io, new_db));
            try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, schema_marker_path, schema_migration_transaction_marker_format));
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", schema_path, "--to", schema_path }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok recovered=1") != null);
            try std.testing.expect(try schemaMigrationTransactionMarkerPresent(std.testing.allocator, std.testing.io, new_db));
            var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_db);
            defer migrated.deinit();
            var node = (try migrated.readNodeById(std.testing.allocator, .fromInt(1))).?;
            defer node.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("recoverable concept", node.text);
        }

        test "schema-migrate remaps kind ids across full store scan" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "old.kg" });
            defer std.testing.allocator.free(old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "new.kg" });
            defer std.testing.allocator.free(new_db);
            const old_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "old.json" });
            defer std.testing.allocator.free(old_schema);
            const new_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "new.json" });
            defer std.testing.allocator.free(new_schema);

            const old_schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "custom_concept", 100);
            defer std.testing.allocator.free(old_schema_content);
            try writeSchemaFile(std.testing.io, old_schema, old_schema_content);
            const new_schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "custom_concept", 200);
            defer std.testing.allocator.free(new_schema_content);
            try writeSchemaFile(std.testing.io, new_schema, new_schema_content);

            var init_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer init_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", old_db }, &init_out, std.testing.allocator, std.testing.io);

            var add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer add_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "add-node", old_db, "custom_concept", "concept text", "--schema", old_schema }, &add_out, std.testing.allocator, std.testing.io);

            {
                var old_store = try storage.Store.open(std.testing.allocator, std.testing.io, old_db);
                defer old_store.deinit();
                try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "name", "preserved concept name");
                try old_store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "ordered target" });
                try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property, "claimed");
                try old_store.setNodeStringProperty(std.testing.allocator, .fromInt(2), task.claimed_by_property, "schema-migrate-agent");
                try old_store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, task.claim_expires_ns_property, std.math.maxInt(u64));
                const edge_id = try old_store.nextEdgeId();
                try old_store.appendEdgeOrderedIndexed(.{
                    .id = edge_id,
                    .src = .fromInt(1),
                    .rel = .verified_by,
                    .dst = .fromInt(2),
                }, 2048);
                try old_store.setEdgeStringProperty(std.testing.allocator, edge_id, "created_by", "schema-migrate-test");
                _ = try writeMetaknowDeferredBasedOnForwardPairsSidecar(
                    std.testing.allocator,
                    old_store,
                    &.{.{ .src = 1, .dst = 2 }},
                    2,
                );
            }

            var migrate_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer migrate_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", old_schema, "--to", new_schema, "--profile", "agent-dag" }, &migrate_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, migrate_out.buffer.items, "result=ok") != null);
            try std.testing.expect(std.mem.indexOf(u8, migrate_out.buffer.items, "kind_remaps=1") != null);

            var show_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer show_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-show", new_db }, &show_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, show_out.buffer.items, "id=200") != null);
            try std.testing.expect(std.mem.indexOf(u8, show_out.buffer.items, "name=custom_concept") != null);

            var new_store = try storage.Store.open(std.testing.allocator, std.testing.io, new_db);
            defer new_store.deinit();
            const new_stats = try new_store.stats();
            try std.testing.expectEqual(@as(u64, 2), new_stats.nodes);
            try std.testing.expectEqual(@as(u64, 1), new_stats.edges);
            const migrated_name = (try new_store.getNodeStringProperty(std.testing.allocator, .fromInt(1), "name")).?;
            defer std.testing.allocator.free(migrated_name);
            try std.testing.expectEqualStrings("preserved concept name", migrated_name);
            const migrated_created_by = (try new_store.getEdgeStringProperty(std.testing.allocator, .fromInt(1), "created_by")).?;
            defer std.testing.allocator.free(migrated_created_by);
            try std.testing.expectEqualStrings("schema-migrate-test", migrated_created_by);
            const migrated_status = (try new_store.getNodeStringProperty(std.testing.allocator, .fromInt(2), task.status_property)).?;
            defer std.testing.allocator.free(migrated_status);
            try std.testing.expectEqualStrings("claimed", migrated_status);
            const migrated_holder = (try new_store.getNodeStringProperty(std.testing.allocator, .fromInt(2), task.claimed_by_property)).?;
            defer std.testing.allocator.free(migrated_holder);
            try std.testing.expectEqualStrings("schema-migrate-agent", migrated_holder);
            try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), try new_store.getUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, task.claim_expires_ns_property));
            var migrated_task = (try new_store.readNodeById(std.testing.allocator, .fromInt(2))).?;
            defer migrated_task.deinit(std.testing.allocator);
            try std.testing.expectEqual(task.Status.claimed, try task.statusForStoredNode(std.testing.allocator, new_store, migrated_task, 1));
            var migrated_order = try new_store.readEdgeOrderMap(std.testing.allocator);
            defer migrated_order.deinit();
            try std.testing.expectEqual(@as(?u64, 2048), migrated_order.get(1));
            try std.testing.expectEqual(@as(?u64, 2048), try new_store.getUintProperty(std.testing.allocator, .{ .edge = .fromInt(1) }, "order_key"));
            const migrated_deferred_path = try metaknowDeferredBasedOnPath(std.testing.allocator, new_store);
            defer std.testing.allocator.free(migrated_deferred_path);
            var deferred_forward = try query.readMetaknowDeferredBasedOnTargets(
                std.testing.allocator,
                std.testing.io,
                migrated_deferred_path,
                .fromInt(1),
                8,
                .forward,
            );
            defer deferred_forward.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u64, &.{2}, deferred_forward.targets);
            var deferred_reverse = try query.readMetaknowDeferredBasedOnTargets(
                std.testing.allocator,
                std.testing.io,
                migrated_deferred_path,
                .fromInt(2),
                8,
                .reverse,
            );
            defer deferred_reverse.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u64, &.{1}, deferred_reverse.targets);
            const migrated_manifest = try readStoreManifestSummary(std.testing.allocator, std.testing.io, new_db);
            defer migrated_manifest.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("3", migrated_manifest.schema_version);
            try std.testing.expectEqualStrings("agent-dag", migrated_manifest.enabled_profiles);
        }

        test "schema-migrate inherits embedded catalog and profiles by default" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "embedded-old.kg" });
            defer std.testing.allocator.free(old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "embedded-new.kg" });
            defer std.testing.allocator.free(new_db);
            const schema_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "embedded.json" });
            defer std.testing.allocator.free(schema_path);

            const schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "custom_concept", 100);
            defer std.testing.allocator.free(schema_content);
            try writeSchemaFile(std.testing.io, schema_path, schema_content);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", old_db }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-apply", old_db, "--schema", schema_path, "--profile", "agent-dag" }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", old_db, "custom_concept", "embedded catalog survives" }, &out, std.testing.allocator, std.testing.io);

            var source = try storage.Store.open(std.testing.allocator, std.testing.io, old_db);
            var source_catalog = (try source.readCatalog()).?;
            const source_revision = source_catalog.revision;
            source_catalog.deinit();
            source.deinit();

            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok") != null);

            var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_db);
            defer migrated.deinit();
            var migrated_catalog = (try migrated.readCatalog()).?;
            defer migrated_catalog.deinit();
            try std.testing.expectEqualStrings("custom_concept", migrated_catalog.registry.nodeTypeNameById(100).?);
            try std.testing.expectEqual(source_revision + 1, migrated_catalog.revision);
            try std.testing.expectEqual(@as(usize, 1), migrated_catalog.profiles.items.len);
            try std.testing.expectEqualStrings("agent-dag", migrated_catalog.profiles.items[0]);
            var migrated_node = (try migrated.readNodeById(std.testing.allocator, .fromInt(1))).?;
            defer migrated_node.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u16, 100), @intFromEnum(migrated_node.kind));
            try std.testing.expectEqualStrings("embedded catalog survives", migrated_node.text);

            const migrated_manifest = try readStoreManifestSummary(std.testing.allocator, std.testing.io, new_db);
            defer migrated_manifest.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("3", migrated_manifest.schema_version);
            try std.testing.expectEqualStrings("agent-dag", migrated_manifest.enabled_profiles);
        }

        test "schema-migrate crosses bounded node and edge publication batches" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "batched-old.kg" });
            defer std.testing.allocator.free(old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "batched-new.kg" });
            defer std.testing.allocator.free(new_db);

            const node_count: usize = 4097; // one beyond SchemaMigrator's node batch
            const edge_count: usize = 8193; // one beyond SchemaMigrator's edge batch
            {
                var source = try storage.Store.init(std.testing.allocator, std.testing.io, old_db);
                defer source.deinit();
                try source.createEmpty();
                const nodes = try std.testing.allocator.alloc(graph.Node, node_count);
                defer std.testing.allocator.free(nodes);
                for (nodes, 0..) |*node, index| node.* = .{
                    .id = .fromInt(index + 1),
                    .kind = .project,
                    .text = "bounded schema migration node",
                };
                try source.appendNodesBatch(nodes);

                const edges = try std.testing.allocator.alloc(graph.Edge, edge_count);
                defer std.testing.allocator.free(edges);
                for (edges, 0..) |*edge, index| edge.* = .{
                    .id = .fromInt(index + 1),
                    .src = .fromInt(1),
                    .rel = .contain,
                    .dst = .fromInt(2 + index % (node_count - 1)),
                };
                const order_keys = try std.testing.allocator.alloc(u64, edge_count);
                defer std.testing.allocator.free(order_keys);
                for (order_keys, 0..) |*order_key, index| order_key.* = index * 2;
                try source.appendEdgesOrderedBatch(edges, order_keys);
                try source.setNodeStringProperty(std.testing.allocator, .fromInt(node_count), "name", "tail node property");
                try source.setEdgeStringProperty(std.testing.allocator, .fromInt(edge_count), "created_by", "tail edge property");
            }

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok") != null);
            var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_db);
            defer migrated.deinit();
            const stats = try migrated.stats();
            try std.testing.expectEqual(@as(u64, node_count), stats.nodes);
            try std.testing.expectEqual(@as(u64, edge_count), stats.edges);
            const last_edge = try migrated.readEdgeById(.fromInt(edge_count));
            try std.testing.expectEqual(@as(u64, edge_count), last_edge.id.toInt());
            const last_node_name = (try migrated.getNodeStringProperty(std.testing.allocator, .fromInt(node_count), "name")).?;
            defer std.testing.allocator.free(last_node_name);
            try std.testing.expectEqualStrings("tail node property", last_node_name);
            const last_edge_creator = (try migrated.getEdgeStringProperty(std.testing.allocator, .fromInt(edge_count), "created_by")).?;
            defer std.testing.allocator.free(last_edge_creator);
            try std.testing.expectEqualStrings("tail edge property", last_edge_creator);
            var migrated_order = try migrated.readEdgeOrderMap(std.testing.allocator);
            defer migrated_order.deinit();
            try std.testing.expectEqual(@as(?u64, (edge_count - 1) * 2), migrated_order.get(edge_count));
            try std.testing.expectEqual(@as(?u64, (edge_count - 1) * 2), try migrated.getUintProperty(std.testing.allocator, .{ .edge = .fromInt(edge_count) }, "order_key"));
        }

        test "schema-migrate preserves published edge overlay records and properties" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "overlay-old.kg" });
            defer std.testing.allocator.free(old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "overlay-new.kg" });
            defer std.testing.allocator.free(new_db);

            {
                var source = try storage.Store.init(std.testing.allocator, std.testing.io, old_db);
                defer source.deinit();
                try source.createEmpty();
                try source.appendNodesBatch(&.{
                    .{ .id = .fromInt(1), .kind = .project, .text = "root" },
                    .{ .id = .fromInt(2), .kind = .project, .text = "base" },
                    .{ .id = .fromInt(3), .kind = .project, .text = "overlay-a" },
                    .{ .id = .fromInt(4), .kind = .project, .text = "overlay-b" },
                });
                var base_edges = std.ArrayList(graph.Edge).empty;
                defer base_edges.deinit(std.testing.allocator);
                try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
                for (1..1025) |raw_id| {
                    base_edges.appendAssumeCapacity(.{
                        .id = .fromInt(raw_id),
                        .src = .fromInt(1),
                        .rel = .contain,
                        .dst = .fromInt(2),
                    });
                }
                try source.appendEdgesBatch(base_edges.items);
                try source.appendEdgesBatch(&.{
                    .{ .id = .fromInt(1025), .src = .fromInt(1), .rel = .contain, .dst = .fromInt(3) },
                    .{ .id = .fromInt(1026), .src = .fromInt(1), .rel = .contain, .dst = .fromInt(4) },
                });
                try source.setEdgeStringProperty(std.testing.allocator, .fromInt(1026), "created_by", "overlay-agent");
                var consolidated_only = try source.visibleEdgeIndexRecordsIterator(.id);
                defer consolidated_only.deinit();
                var consolidated_count: usize = 0;
                while (try consolidated_only.next() != null) consolidated_count += 1;
                try std.testing.expect(consolidated_count < 1026);
            }

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "schema-migrate", old_db, new_db }, &out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "result=ok") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edges_migrated=1026") != null);

            var migrated = try storage.Store.open(std.testing.allocator, std.testing.io, new_db);
            defer migrated.deinit();
            const stats = try migrated.stats();
            try std.testing.expectEqual(@as(u64, 1026), stats.edges);
            const overlay_edge = try migrated.readEdgeById(.fromInt(1026));
            try std.testing.expectEqual(@as(u64, 4), overlay_edge.dst.toInt());
            const created_by = (try migrated.getEdgeStringProperty(std.testing.allocator, .fromInt(1026), "created_by")).?;
            defer std.testing.allocator.free(created_by);
            try std.testing.expectEqualStrings("overlay-agent", created_by);
        }

        test "schema-migrate rejects a live type dropped from the target catalog" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "drop-old.kg" });
            defer std.testing.allocator.free(old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "drop-new.kg" });
            defer std.testing.allocator.free(new_db);
            const old_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "drop-old.json" });
            defer std.testing.allocator.free(old_schema);
            const new_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "drop-new.json" });
            defer std.testing.allocator.free(new_schema);

            const old_schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "concept", 100);
            defer std.testing.allocator.free(old_schema_content);
            try writeSchemaFile(std.testing.io, old_schema, old_schema_content);
            const new_schema_content = try catalogTestSchemaJsonAlloc(std.testing.allocator, "replacement", 200);
            defer std.testing.allocator.free(new_schema_content);
            try writeSchemaFile(std.testing.io, new_schema, new_schema_content);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", old_db }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", old_db, "concept", "must not be reinterpreted", "--schema", old_schema }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.SchemaOrphanedTypeInUse,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", old_schema, "--to", new_schema }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(!try anyPathExists(std.testing.io, new_db));
        }

        test "schema-migrate rejects target endpoint rules violated by live edges" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "endpoint-old.kg" });
            defer std.testing.allocator.free(old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "endpoint-new.kg" });
            defer std.testing.allocator.free(new_db);
            const old_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "endpoint-old.json" });
            defer std.testing.allocator.free(old_schema);
            const new_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "endpoint-new.json" });
            defer std.testing.allocator.free(new_schema);
            const old_schema_json =
                \\{"schema_version":3,"node_types":[{"name":"source_type","id":100,"parents":["node"]},{"name":"target_type","id":101,"parents":["node"]}],"relation_types":[{"name":"links","id":100,"parents":["edge"],"class":"domain","src_types":["source_type"],"dst_types":["target_type"]}]}
            ;
            const new_schema_json =
                \\{"schema_version":3,"node_types":[{"name":"source_type","id":100,"parents":["node"]},{"name":"target_type","id":101,"parents":["node"]}],"relation_types":[{"name":"links","id":100,"parents":["edge"],"class":"domain","src_types":["source_type"],"dst_types":["source_type"]}]}
            ;
            try writeSchemaFile(std.testing.io, old_schema, old_schema_json);
            try writeSchemaFile(std.testing.io, new_schema, new_schema_json);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", old_db }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", old_db, "source_type", "source", "--schema", old_schema }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", old_db, "target_type", "target", "--schema", old_schema }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-edge", old_db, "1", "links", "2", "--schema", old_schema }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();

            try std.testing.expectError(
                error.SchemaEndpointViolation,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", old_schema, "--to", new_schema }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(!try anyPathExists(std.testing.io, new_db));
        }

        test "schema-migrate rejects live property values outside target enum" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const old_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "enum-old.kg" });
            defer std.testing.allocator.free(old_db);
            const new_db = try std.fs.path.join(std.testing.allocator, &.{ root_path, "enum-new.kg" });
            defer std.testing.allocator.free(new_db);
            const old_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "enum-old.json" });
            defer std.testing.allocator.free(old_schema);
            const new_schema = try std.fs.path.join(std.testing.allocator, &.{ root_path, "enum-new.json" });
            defer std.testing.allocator.free(new_schema);
            const old_schema_json =
                \\{"schema_version":3,"node_types":[{"name":"workflow","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft","obsolete"]}}}]}
            ;
            const new_schema_json =
                \\{"schema_version":3,"node_types":[{"name":"workflow","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft"]}}}]}
            ;
            try writeSchemaFile(std.testing.io, old_schema, old_schema_json);
            try writeSchemaFile(std.testing.io, new_schema, new_schema_json);

            var out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "init", old_db }, &out, std.testing.allocator, std.testing.io);
            out.buffer.clearRetainingCapacity();
            try run(&.{ "tinykg", "add-node", old_db, "workflow", "legacy workflow", "--schema", old_schema }, &out, std.testing.allocator, std.testing.io);
            {
                var source = try storage.Store.open(std.testing.allocator, std.testing.io, old_db);
                defer source.deinit();
                try source.setNodeStringProperty(std.testing.allocator, .fromInt(1), "state", "obsolete");
            }

            try std.testing.expectError(
                error.SchemaPropertyValueMismatch,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", old_schema, "--to", new_schema }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(!try anyPathExists(std.testing.io, new_db));

            const removed_property_schema_json =
                \\{"schema_version":3,"node_types":[{"name":"workflow","id":100,"parents":["node"]}]}
            ;
            try writeSchemaFile(std.testing.io, new_schema, removed_property_schema_json);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.SchemaOrphanedPropertyInUse,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", old_schema, "--to", new_schema }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(!try anyPathExists(std.testing.io, new_db));

            const required_property_schema_json =
                \\{"schema_version":3,"node_types":[{"name":"workflow","id":100,"parents":["node"],"properties":{"state":{"type":"enum","values":["draft","obsolete"]},"must_have":{"type":"string","required":true,"nullable":false}}}]}
            ;
            try writeSchemaFile(std.testing.io, new_schema, required_property_schema_json);
            out.buffer.clearRetainingCapacity();
            try std.testing.expectError(
                error.SchemaRequiredPropertyMissing,
                run(&.{ "tinykg", "schema-migrate", old_db, new_db, "--from", old_schema, "--to", new_schema }, &out, std.testing.allocator, std.testing.io),
            );
            try std.testing.expect(!try anyPathExists(std.testing.io, new_db));
        }
    };
}
