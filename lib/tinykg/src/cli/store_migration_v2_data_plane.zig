const std = @import("std");
const catalog_mod = @import("../catalog.zig");
const core = @import("../core.zig");
const graph = @import("../graph.zig");
const schema = @import("../schema.zig");
const storage = @import("../storage.zig");
const task = @import("../task.zig");
const text_search = @import("../text.zig");

/// Complete Store-v2 source-to-target migration data plane. The CLI façade
/// retains command admission, exclusions, output, and shared migration ports;
/// this owner controls translation, copy-on-write staging, recovery, and
/// post-copy verification as one transaction-shaped responsibility.
pub fn StoreMigrationV2DataPlane(comptime Ops: type) type {
    return struct {
        const ParsedMigrateStoreV2Args = Ops.Arguments;
        const ContentDigest = Ops.Digest;
        const QueryOutputWriter = Ops.OutputWriter;
        const MigrationPropertyBatch = Ops.PropertyBatch;
        const MigrationPropertyLookup = Ops.PropertyLookup;
        const MigrationPropertyKeys = Ops.PropertyKeys;
        const MigrationPropertySpool = Ops.PropertySpool;
        const MigrationPropertyStream = Ops.PropertyStream;
        const MigrationTargetPropertySpoolBuilder = Ops.TargetPropertySpoolBuilder;
        const RecoveryTargetLock = Ops.RecoveryTargetLock;

        const current_schema_version = Ops.schema_version_current;
        const current_storage_format_version = Ops.storage_format_version_current;
        const store_migration_transaction_marker_file = Ops.transaction_marker_file_name;
        const store_migration_transaction_marker_format = Ops.transaction_marker_format_name;
        const store_migration_transaction_marker_legacy_format = Ops.transaction_marker_legacy_format_name;
        const store_migration_staging_suffix = Ops.staging_suffix;
        const deleted_node_tombstone_prefix = Ops.deleted_node_tombstone_prefix;

        const addBuiltinProfilesFromCsvForSchemaVersion = Ops.addBuiltinProfilesFn;
        const anyPathExists = Ops.anyPathExistsFn;
        const appendCatalogProfileLabel = Ops.appendCatalogProfileLabelFn;
        const appendSchemaDocumentProfilesToCatalog = Ops.appendSchemaDocumentProfilesToCatalogFn;
        const appendSchemaFileProfilesToCatalog = Ops.appendSchemaFileProfilesToCatalogFn;
        const backupStore = Ops.backupStoreFn;
        const canonicalPathsEqual = Ops.canonicalPathsEqualFn;
        const canonicalProspectivePath = Ops.canonicalProspectivePathFn;
        const catalogProfilesCsvAlloc = Ops.catalogProfilesCsvAllocFn;
        const catalogProfilesMatchCsv = Ops.catalogProfilesMatchCsvFn;
        const collectKnownEdgeProperties = Ops.collectKnownEdgePropertiesFn;
        const collectKnownNodeProperties = Ops.collectKnownNodePropertiesFn;
        const copyMetaknowDeferredBasedOnSidecarForMigration = Ops.copyDeferredSidecarFn;
        const createOwnedDirectory = Ops.createOwnedDirectoryFn;
        const existingTinyKgStorePath = Ops.existingTinyKgStorePathFn;
        const isDeletedNodeTombstone = Ops.isDeletedNodeTombstoneFn;
        const migrationPropertyKeyValid = Ops.migrationPropertyKeyValidFn;
        const migrationPropertySuppressedByTaskStatusV1 = Ops.migrationPropertySuppressedByTaskStatusV1Fn;
        const pathsOverlap = Ops.pathsOverlapFn;
        const pathsOverlapForCopyTarget = Ops.pathsOverlapForCopyTargetFn;
        const persistentNowNs = Ops.persistentNowNsFn;
        const readStoreManifestSummary = Ops.readStoreManifestSummaryFn;
        const renamePath = Ops.renamePathFn;
        const storeContentIdentity = Ops.storeContentIdentityFn;
        const syncExportDirectoryTree = Ops.syncExportDirectoryTreeFn;
        const syncParentDirectory = Ops.syncParentDirectoryFn;
        const u128ToU64 = Ops.u128ToU64Fn;
        const validateExistingBackupForSource = Ops.validateExistingBackupForSourceFn;
        const writeJsonString = Ops.writeJsonStringFn;
        const writeRecoverableTransactionMarker = Ops.writeRecoverableTransactionMarkerFn;
        const writeStoreManifest = Ops.writeStoreManifestFn;

        pub const Result = struct {
            nodes_scanned: u64 = 0,
            nodes_written: u64 = 0,
            edges_scanned: u64 = 0,
            edges_written: u64 = 0,
            tombstone_nodes_skipped: u64 = 0,
            legacy_props_extracted: u64 = 0,
            legacy_text_repaired: u64 = 0,
            empty_text_physical_placeholders: u64 = 0,
            node_properties_written: u64 = 0,
            edge_properties_written: u64 = 0,
            task_statuses_written: u64 = 0,
            legacy_closed_tasks_converted: u64 = 0,
            text_warmed: bool = false,
            verified: bool = false,
            published_store_bytes: u64 = 0,
            published_store_digest: ContentDigest = .{ 0, 0, 0, 0 },
            marker_cleanup_pending: bool = false,
        };

        const StoreMigrationV2Result = Result;

        fn migrationLifecycleFields(
            source_properties: *const MigrationPropertyLookup,
            node_id: core.NodeId,
        ) task.StatusSnapshot.LifecycleFields {
            var fields: task.StatusSnapshot.LifecycleFields = .{};
            const owner: storage.PropertyOwner = .{ .node = node_id };
            if (source_properties.get(owner, task.status_property)) |entry| {
                if (entry.value_kind == .string) fields.stored_status_raw = entry.string_value else fields.invalid_value_type = true;
            }
            if (source_properties.get(owner, task.claimed_by_property)) |entry| {
                if (entry.value_kind == .string) fields.claimed_by = entry.string_value else fields.invalid_value_type = true;
            }
            if (source_properties.get(owner, task.claim_expires_ns_property)) |entry| {
                if (entry.value_kind == .uint) fields.claim_expires_ns = entry.uint_value else fields.invalid_value_type = true;
            }
            if (source_properties.get(owner, "task_recorded_ns")) |entry| {
                if (entry.value_kind == .uint) fields.task_recorded_ns = entry.uint_value else fields.invalid_value_type = true;
            }
            if (source_properties.get(owner, "task_created_ns")) |entry| {
                if (entry.value_kind == .uint) fields.task_created_ns = entry.uint_value else fields.invalid_value_type = true;
            }
            if (source_properties.get(owner, "task_completed_ns")) |entry| {
                if (entry.value_kind == .uint) fields.task_completed_ns = entry.uint_value else fields.invalid_value_type = true;
            }
            return fields;
        }

        const MigrationLifecycleFields = struct {
            fields: task.StatusSnapshot.LifecycleFields,
            owned_status: ?[]u8 = null,
            owned_claimed_by: ?[]u8 = null,

            fn deinit(self: *MigrationLifecycleFields, allocator: std.mem.Allocator) void {
                if (self.owned_status) |value| allocator.free(value);
                if (self.owned_claimed_by) |value| allocator.free(value);
                self.* = undefined;
            }
        };

        fn migrationLifecycleFieldsWithLegacyProps(
            allocator: std.mem.Allocator,
            source_properties: *const MigrationPropertyLookup,
            node_id: core.NodeId,
            props_json: ?[]const u8,
            strict: bool,
        ) !MigrationLifecycleFields {
            var result = MigrationLifecycleFields{ .fields = migrationLifecycleFields(source_properties, node_id) };
            errdefer result.deinit(allocator);
            const json = props_json orelse return result;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch |err| {
                if (strict) return err;
                return result;
            };
            defer parsed.deinit();
            if (parsed.value != .object) return result;
            const object = parsed.value.object;
            const owner: storage.PropertyOwner = .{ .node = node_id };

            if (source_properties.get(owner, task.status_property) == null) {
                if (object.get(task.status_property)) |value| switch (value) {
                    .string => |text| {
                        result.owned_status = try allocator.dupe(u8, text);
                        result.fields.stored_status_raw = result.owned_status.?;
                    },
                    else => result.fields.invalid_value_type = true,
                };
            }
            if (source_properties.get(owner, task.claimed_by_property) == null) {
                if (object.get(task.claimed_by_property)) |value| switch (value) {
                    .string => |text| {
                        result.owned_claimed_by = try allocator.dupe(u8, text);
                        result.fields.claimed_by = result.owned_claimed_by.?;
                    },
                    else => result.fields.invalid_value_type = true,
                };
            }
            inline for (.{
                task.claim_expires_ns_property,
                "task_recorded_ns",
                "task_created_ns",
                "task_completed_ns",
            }) |key| {
                if (source_properties.get(owner, key) == null) {
                    if (object.get(key)) |value| {
                        const parsed_uint: ?u64 = switch (value) {
                            .integer => |integer| if (integer >= 0) @intCast(integer) else blk: {
                                result.fields.invalid_value_type = true;
                                break :blk null;
                            },
                            else => blk: {
                                result.fields.invalid_value_type = true;
                                break :blk null;
                            },
                        };
                        if (parsed_uint) |uint_value| {
                            if (comptime std.mem.eql(u8, key, "claim_expires_ns")) {
                                result.fields.claim_expires_ns = uint_value;
                            } else if (comptime std.mem.eql(u8, key, "task_recorded_ns")) {
                                result.fields.task_recorded_ns = uint_value;
                            } else if (comptime std.mem.eql(u8, key, "task_created_ns")) {
                                result.fields.task_created_ns = uint_value;
                            } else if (comptime std.mem.eql(u8, key, "task_completed_ns")) {
                                result.fields.task_completed_ns = uint_value;
                            } else comptime unreachable;
                        }
                    }
                }
            }
            return result;
        }

        fn taskStatusForMigration(
            node: storage.StoredNode,
            lifecycle: task.StatusSnapshot.LifecycleFields,
            now_ns: u64,
        ) !?task.Status {
            if (node.kind == .task) {
                // The explicit COW migration is also the repair boundary for the
                // pre-v3 crash window where completion time reached the legacy
                // property overlay but terminal status did not. Runtime reads remain
                // fail-closed; migration deliberately drops that non-authoritative
                // completion field and derives only the lease-backed effective state.
                return try task.effectiveStatusForLifecycleFields(lifecycle, now_ns, .migration_repair_nonterminal_completion);
            }
            if (node.kind == .verification or node.kind == .fix) {
                if (task.lifecycleFieldsRepresentLegacyClosedTask(lifecycle)) return .completed;
            }
            return null;
        }

        pub fn migrationCatalog(
            allocator: std.mem.Allocator,
            source: storage.Store,
            profiles: []const u8,
            profiles_explicit: bool,
            task_status_v1: bool,
        ) !catalog_mod.Catalog {
            var source_catalog = try source.readCatalog();
            const source_is_kernel_only = if (source_catalog) |existing|
                existing.profiles.items.len == 0 and existing.registry.nodeTypeCount() == 2 and existing.registry.relationTypeCount() == 2
            else
                false;
            var cat = if (source_catalog != null and !source_is_kernel_only)
                source_catalog.?
            else blk: {
                if (source_catalog) |*existing| existing.deinit();
                source_catalog = null;
                var registry = schema.Registry.init(allocator);
                errdefer registry.deinit();
                try registry.addKernelTypes();
                try addBuiltinProfilesFromCsvForSchemaVersion(&registry, profiles, if (task_status_v1) 3 else 2);
                var created = try catalog_mod.Catalog.fromRegistry(allocator, registry);
                var profile_it = std.mem.tokenizeScalar(u8, profiles, ',');
                while (profile_it.next()) |raw| {
                    const label = std.mem.trim(u8, raw, " \t\r\n");
                    const profile = schema.BuiltinProfile.fromLabel(label) orelse continue;
                    try appendCatalogProfileLabel(allocator, &created, profile.label());
                }
                break :blk created;
            };
            errdefer cat.deinit();

            if (!source_is_kernel_only and profiles_explicit and !catalogProfilesMatchCsv(cat, profiles)) return error.Unsupported;

            if (task_status_v1) {
                // Revision is a schema generation, not a count of migration command
                // invocations. Snapshot the catalog before the narrow lifecycle
                // upgrade so a second task-status-v1 COW migration is semantically
                // idempotent and does not manufacture a new revision.
                const before = try catalog_mod.encodeCatalog(allocator, cat);
                defer allocator.free(before);
                const task_type = @intFromEnum(core.NodeKind.task);
                if (cat.registry.nodeTypeNameById(task_type)) |name| {
                    if (!std.mem.eql(u8, name, "task")) return error.InvalidRecord;
                } else {
                    if (cat.registry.findNodeType("task") != null) return error.InvalidRecord;
                    try cat.registry.addNodeType("task", task_type, &.{schema.kernel_node_type_id});
                }
                try cat.registry.setTaskLifecycleProperties();
                const after = try catalog_mod.encodeCatalog(allocator, cat);
                defer allocator.free(after);
                if (!std.mem.eql(u8, before, after)) {
                    cat.revision = std.math.add(u32, cat.revision, 1) catch return error.RecordTooLarge;
                }
            }
            return cat;
        }

        fn validateMigrateStoreV2PathRelationships(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedMigrateStoreV2Args) !void {
            if (!try existingTinyKgStorePath(allocator, io, parsed.source_path)) return error.FileNotFound;
            if (try pathsOverlapForCopyTarget(allocator, io, parsed.source_path, parsed.target_path)) return error.InvalidFileName;
            if (parsed.backup_path) |backup_path| {
                if (try pathsOverlapForCopyTarget(allocator, io, parsed.source_path, backup_path) or
                    try pathsOverlap(allocator, io, parsed.target_path, backup_path))
                {
                    return error.InvalidFileName;
                }
            }
        }

        fn validateMigrateStoreV2Destinations(io: std.Io, parsed: ParsedMigrateStoreV2Args) !void {
            if (!parsed.dry_run and try anyPathExists(io, parsed.target_path)) return error.AlreadyExists;
        }

        fn validateMigrateStoreV2Paths(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedMigrateStoreV2Args) !void {
            try validateMigrateStoreV2PathRelationships(allocator, io, parsed);
            try validateMigrateStoreV2Destinations(io, parsed);
            if (parsed.backup_path) |backup_path| {
                if (try anyPathExists(io, backup_path)) return error.AlreadyExists;
            }
        }

        pub const node_batch_limit: usize = 4096;
        const store_migration_node_batch_limit = node_batch_limit;
        pub const edge_batch_limit: usize = 8192;
        const store_migration_edge_batch_limit = edge_batch_limit;

        fn migrationLegacyTaskNeedsSchemaOverride(
            source_properties: *const MigrationPropertyLookup,
            node_id: core.NodeId,
        ) !bool {
            const entry = source_properties.get(.{ .node = node_id }, "schema_type") orelse return true;
            if (entry.value_kind != .string) return error.InvalidRecord;
            return std.mem.eql(u8, entry.string_value, "verification") or std.mem.eql(u8, entry.string_value, "fix");
        }

        fn processStoreMigrationNodeBatch(
            allocator: std.mem.Allocator,
            source_nodes: []const storage.StoredNode,
            target: ?storage.Store,
            target_catalog: catalog_mod.Catalog,
            property_stream: *MigrationPropertyStream,
            target_property_builder: ?*MigrationTargetPropertySpoolBuilder,
            parsed: ParsedMigrateStoreV2Args,
            migration_now_ns: u64,
            result: *StoreMigrationV2Result,
        ) !void {
            if (source_nodes.len == 0) return;
            var raw_ids = std.ArrayList(u64).empty;
            defer raw_ids.deinit(allocator);
            try raw_ids.ensureTotalCapacityPrecise(allocator, source_nodes.len);
            for (source_nodes) |node| raw_ids.appendAssumeCapacity(node.id.toInt());
            const snapshot = try property_stream.snapshotForOwners(1, raw_ids.items);
            var source_properties = try MigrationPropertyLookup.initFromSnapshot(allocator, snapshot);
            defer source_properties.deinit();

            var migrated_nodes = std.ArrayList(graph.Node).empty;
            defer {
                for (migrated_nodes.items) |node| allocator.free(node.text);
                migrated_nodes.deinit(allocator);
            }
            try migrated_nodes.ensureTotalCapacityPrecise(allocator, source_nodes.len);
            var property_batch = MigrationPropertyBatch.init(allocator);
            defer property_batch.deinit();
            var property_suppressions = std.ArrayList(MigrationTargetPropertySpoolBuilder.Suppression).empty;
            defer property_suppressions.deinit(allocator);
            const property_result_start = result.node_properties_written;

            for (source_nodes) |source_node| {
                var repaired = try repairLegacyNodeTextForMigration(allocator, source_node.text, parsed.strict, result, true);
                var repaired_owned = true;
                defer if (repaired_owned) repaired.deinit(allocator);
                var migration_lifecycle = if (parsed.task_status_v1)
                    try migrationLifecycleFieldsWithLegacyProps(
                        allocator,
                        &source_properties,
                        source_node.id,
                        repaired.props_json,
                        parsed.strict,
                    )
                else
                    MigrationLifecycleFields{ .fields = .{} };
                defer migration_lifecycle.deinit(allocator);
                const materialized_status = if (parsed.task_status_v1)
                    try taskStatusForMigration(source_node, migration_lifecycle.fields, migration_now_ns)
                else
                    null;
                const force_task_schema = materialized_status != null and source_node.kind != .task and
                    try migrationLegacyTaskNeedsSchemaOverride(&source_properties, source_node.id);
                const migrated_kind: core.NodeKind = if (materialized_status != null) .task else source_node.kind;
                migrated_nodes.appendAssumeCapacity(.{
                    .id = source_node.id,
                    .kind = migrated_kind,
                    .text = repaired.text,
                });
                repaired_owned = false;

                if (materialized_status != null) {
                    inline for (.{
                        task.status_property,
                        task.claim_expires_ns_property,
                        "task_completed_ns",
                    }) |key| try property_suppressions.append(allocator, .{
                        .owner = .{ .node = source_node.id },
                        .key_hash = storage.propertyKeyHashForLookup(key),
                    });
                    result.task_statuses_written = std.math.add(u64, result.task_statuses_written, 1) catch return error.RecordTooLarge;
                    if (source_node.kind != .task) {
                        result.legacy_closed_tasks_converted = std.math.add(u64, result.legacy_closed_tasks_converted, 1) catch return error.RecordTooLarge;
                    }
                }
                if (parsed.dry_run) {
                    result.legacy_props_extracted += try countLegacyNodePropsTextProperties(
                        allocator,
                        &source_properties,
                        source_node.id,
                        repaired.props_json,
                        parsed.strict,
                        materialized_status != null,
                        force_task_schema,
                    );
                    continue;
                }

                result.node_properties_written += collectKnownNodeProperties(
                    &source_properties,
                    target_catalog.registry,
                    @intFromEnum(migrated_kind),
                    source_node.id,
                    &property_batch,
                    materialized_status != null,
                    force_task_schema,
                ) catch return error.MigrationNodePropertyFailed;
                result.node_properties_written += appendLegacyNodePropsTextProperties(
                    allocator,
                    &source_properties,
                    source_node.id,
                    repaired.props_json,
                    parsed.strict,
                    result,
                    &property_batch,
                    materialized_status != null,
                    force_task_schema,
                ) catch return error.MigrationLegacyNodePropsFailed;
                if (materialized_status) |status| {
                    property_batch.appendString(.{ .node = source_node.id }, task.status_property, @tagName(status)) catch return error.MigrationPropertyBatchFailed;
                    result.node_properties_written += 1;
                    const lifecycle_fields = migration_lifecycle.fields;
                    if (status.isTerminal()) {
                        const completed_ns = lifecycle_fields.task_completed_ns orelse return error.InvalidRecord;
                        if (completed_ns == 0) return error.InvalidRecord;
                        if (lifecycle_fields.task_created_ns) |created_ns| {
                            if (created_ns == 0 or completed_ns < created_ns) return error.InvalidRecord;
                        }
                        property_batch.appendUint(.{ .node = source_node.id }, "task_completed_ns", completed_ns) catch return error.MigrationPropertyBatchFailed;
                        result.node_properties_written += 1;
                    }
                    if (lifecycle_fields.claim_expires_ns) |source_expiry| {
                        const normalized_expiry = if (status == .claimed) source_expiry else 0;
                        property_batch.appendUint(.{ .node = source_node.id }, task.claim_expires_ns_property, normalized_expiry) catch return error.MigrationPropertyBatchFailed;
                        result.node_properties_written += 1;
                    }
                }
                if (force_task_schema) {
                    try property_suppressions.append(allocator, .{
                        .owner = .{ .node = source_node.id },
                        .key_hash = storage.propertyKeyHashForLookup("schema_type"),
                    });
                    property_batch.appendString(.{ .node = source_node.id }, "schema_type", "task") catch return error.MigrationPropertyBatchFailed;
                    result.node_properties_written += 1;
                }
            }

            if (target) |store| {
                store.appendNodesBatch(migrated_nodes.items) catch return error.MigrationAppendNodesFailed;
                const builder = target_property_builder orelse return error.InvalidRecord;
                const merged_count = builder.appendSnapshotMerged(source_properties.snapshotView(), property_batch.writes.items, property_suppressions.items) catch return error.MigrationPropertyBatchFailed;
                result.node_properties_written = std.math.add(u64, property_result_start, merged_count) catch return error.MigrationPropertyBatchFailed;
            } else if (target_property_builder != null or !parsed.dry_run) {
                return error.InvalidRecord;
            }
            result.nodes_written = std.math.add(u64, result.nodes_written, migrated_nodes.items.len) catch return error.RecordTooLarge;
        }

        fn migrateStoreV2Nodes(
            allocator: std.mem.Allocator,
            source: storage.Store,
            target: ?storage.Store,
            target_catalog: catalog_mod.Catalog,
            property_stream: *MigrationPropertyStream,
            target_property_builder: ?*MigrationTargetPropertySpoolBuilder,
            parsed: ParsedMigrateStoreV2Args,
            migration_now_ns: u64,
            result: *StoreMigrationV2Result,
        ) !void {
            var batch = std.ArrayList(storage.StoredNode).empty;
            defer {
                for (batch.items) |*node| node.deinit(allocator);
                batch.deinit(allocator);
            }
            try batch.ensureTotalCapacityPrecise(allocator, store_migration_node_batch_limit);
            var node_iter = try source.nodeRecordsIterator(null);
            defer node_iter.deinit();
            while (try node_iter.next(allocator)) |stored_node| {
                var node = stored_node;
                result.nodes_scanned = std.math.add(u64, result.nodes_scanned, 1) catch return error.RecordTooLarge;
                if (isDeletedNodeTombstone(node)) {
                    result.tombstone_nodes_skipped = std.math.add(u64, result.tombstone_nodes_skipped, 1) catch return error.RecordTooLarge;
                    node.deinit(allocator);
                    continue;
                }
                batch.appendAssumeCapacity(node);
                if (batch.items.len < store_migration_node_batch_limit) continue;
                try processStoreMigrationNodeBatch(
                    allocator,
                    batch.items,
                    target,
                    target_catalog,
                    property_stream,
                    target_property_builder,
                    parsed,
                    migration_now_ns,
                    result,
                );
                for (batch.items) |*owned| owned.deinit(allocator);
                batch.clearRetainingCapacity();
            }
            if (batch.items.len != 0) {
                try processStoreMigrationNodeBatch(
                    allocator,
                    batch.items,
                    target,
                    target_catalog,
                    property_stream,
                    target_property_builder,
                    parsed,
                    migration_now_ns,
                    result,
                );
                for (batch.items) |*owned| owned.deinit(allocator);
                batch.clearRetainingCapacity();
            }
        }

        fn sourceMigrationNodeIsLive(
            allocator: std.mem.Allocator,
            view: *const storage.Store.NodeRecordView,
            node_id: core.NodeId,
        ) !bool {
            const node_ref = (try view.readNodeRefById(node_id)) orelse return false;
            if (node_ref.kind != .edit) return true;
            if (try view.readNodeRefTextBorrowed(node_ref)) |text| {
                return !std.mem.startsWith(u8, text, deleted_node_tombstone_prefix);
            }
            const text = try view.readNodeRefTextAlloc(allocator, node_ref);
            defer allocator.free(text);
            return !std.mem.startsWith(u8, text, deleted_node_tombstone_prefix);
        }

        fn processStoreMigrationEdgePropertyBatch(
            allocator: std.mem.Allocator,
            edges: []const graph.Edge,
            target_catalog: catalog_mod.Catalog,
            property_stream: *MigrationPropertyStream,
            target_property_builder: *MigrationTargetPropertySpoolBuilder,
            result: *StoreMigrationV2Result,
        ) !void {
            if (edges.len == 0) return;
            var raw_ids = std.ArrayList(u64).empty;
            defer raw_ids.deinit(allocator);
            try raw_ids.ensureTotalCapacityPrecise(allocator, edges.len);
            for (edges) |edge| raw_ids.appendAssumeCapacity(edge.id.toInt());
            const snapshot = try property_stream.snapshotForOwners(2, raw_ids.items);
            var source_properties = try MigrationPropertyLookup.initFromSnapshot(allocator, snapshot);
            defer source_properties.deinit();

            var property_batch = MigrationPropertyBatch.init(allocator);
            defer property_batch.deinit();
            const property_result_start = result.edge_properties_written;
            for (edges) |edge| {
                result.edge_properties_written += collectKnownEdgeProperties(
                    &source_properties,
                    target_catalog.registry,
                    @intFromEnum(edge.rel),
                    edge.id,
                    null,
                    &property_batch,
                ) catch return error.MigrationEdgePropertyFailed;
            }
            const merged_count = target_property_builder.appendSnapshotMerged(source_properties.snapshotView(), property_batch.writes.items, &.{}) catch return error.MigrationPropertyBatchFailed;
            result.edge_properties_written = std.math.add(u64, property_result_start, merged_count) catch return error.MigrationPropertyBatchFailed;
        }

        fn migrateStoreV2Edges(
            allocator: std.mem.Allocator,
            source: storage.Store,
            target: ?storage.Store,
            target_catalog: catalog_mod.Catalog,
            property_stream: *MigrationPropertyStream,
            target_property_builder: ?*MigrationTargetPropertySpoolBuilder,
            result: *StoreMigrationV2Result,
        ) !void {
            var batch = std.ArrayList(graph.Edge).empty;
            defer batch.deinit(allocator);
            try batch.ensureTotalCapacityPrecise(allocator, store_migration_edge_batch_limit);
            var source_node_view = try source.openNodeRecordView();
            defer source_node_view.deinit();
            const ScanContext = struct {
                allocator: std.mem.Allocator,
                source_node_view: *const storage.Store.NodeRecordView,
                target: ?storage.Store,
                batch: *std.ArrayList(graph.Edge),
                result: *StoreMigrationV2Result,

                fn flush(self: *@This()) !void {
                    if (self.batch.items.len == 0) return;
                    if (self.target) |store| {
                        store.appendEdgesBatch(self.batch.items) catch return error.MigrationAppendUnorderedEdgesFailed;
                    }
                    self.result.edges_written = std.math.add(u64, self.result.edges_written, self.batch.items.len) catch return error.RecordTooLarge;
                    self.batch.clearRetainingCapacity();
                }

                fn visit(raw_context: *anyopaque, record: storage.EdgeIndexRecord) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(raw_context));
                    if (self.target == null and
                        (!try sourceMigrationNodeIsLive(self.allocator, self.source_node_view, .fromInt(record.src)) or
                            !try sourceMigrationNodeIsLive(self.allocator, self.source_node_view, .fromInt(record.dst)))) return error.InvalidRecord;
                    self.batch.appendAssumeCapacity(.{
                        .id = .fromInt(record.edge_id),
                        .src = .fromInt(record.src),
                        .rel = try record.relKind(),
                        .dst = .fromInt(record.dst),
                    });
                    self.result.edges_scanned = std.math.add(u64, self.result.edges_scanned, 1) catch return error.RecordTooLarge;
                    if (self.batch.items.len == store_migration_edge_batch_limit) try self.flush();
                }
            };
            var scan_context = ScanContext{
                .allocator = allocator,
                .source_node_view = &source_node_view,
                .target = target,
                .batch = &batch,
                .result = result,
            };
            const scanned = try source.scanVisibleEdgeIndexRecords(allocator, &scan_context, ScanContext.visit);
            try scan_context.flush();
            if (scanned != result.edges_scanned or result.edges_scanned != result.edges_written) return error.InvalidRecord;

            if (target) |store| {
                if (result.edges_written != 0) try store.repairPersistentIndexesFromLog();
                _ = try store.replaceEdgeOrderIndexFromPresentEdges(source);
                const builder = target_property_builder orelse return error.InvalidRecord;
                var edge_iter = try store.visibleEdgeIndexRecordsIterator(.id);
                defer edge_iter.deinit();
                while (try edge_iter.next()) |record| {
                    try batch.append(allocator, .{
                        .id = .fromInt(record.edge_id),
                        .src = .fromInt(record.src),
                        .rel = try record.relKind(),
                        .dst = .fromInt(record.dst),
                    });
                    if (batch.items.len < store_migration_edge_batch_limit) continue;
                    try processStoreMigrationEdgePropertyBatch(
                        allocator,
                        batch.items,
                        target_catalog,
                        property_stream,
                        builder,
                        result,
                    );
                    batch.clearRetainingCapacity();
                }
                if (batch.items.len != 0) {
                    try processStoreMigrationEdgePropertyBatch(
                        allocator,
                        batch.items,
                        target_catalog,
                        property_stream,
                        builder,
                        result,
                    );
                }
            }
        }

        pub const TransactionExpectation = struct {
            canonical_source_path: []const u8,
            canonical_backup_path: []const u8,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
            target_profiles: []const u8,
            target_catalog_revision: u32,
            target_schema_version: u32,
            strict: bool,
            warm_text: bool,
            verify: bool,
            task_status_v1: bool,
        };

        const StoreMigrationV2TransactionMarkerJson = struct {
            format: []const u8,
            canonical_source_path: []const u8,
            canonical_backup_path: []const u8,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
            target_profiles: []const u8,
            target_catalog_revision: u32,
            target_schema_version: u32,
            strict: bool,
            warm_text: bool,
            verify: bool,
            task_status_v1: bool,
            complete: bool,
            result: ?StoreMigrationV2Result = null,
        };

        const StoreMigrationV2MarkerState = struct {
            complete: bool,
            result: ?StoreMigrationV2Result,
            legacy_format: bool,
        };

        pub fn stagingPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, store_migration_staging_suffix });
        }

        pub fn transactionMarkerPath(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
            return try std.fs.path.join(allocator, &.{ dir_path, store_migration_transaction_marker_file });
        }

        fn appendStoreMigrationV2ResultJson(out: *QueryOutputWriter, result: StoreMigrationV2Result) !void {
            try out.print(
                "{{\"nodes_scanned\":{},\"nodes_written\":{},\"edges_scanned\":{},\"edges_written\":{},\"tombstone_nodes_skipped\":{},\"legacy_props_extracted\":{},\"legacy_text_repaired\":{},\"empty_text_physical_placeholders\":{},\"node_properties_written\":{},\"edge_properties_written\":{},\"task_statuses_written\":{},\"legacy_closed_tasks_converted\":{},\"text_warmed\":{},\"verified\":{},\"published_store_bytes\":{},\"published_store_digest\":[{},{},{},{}],\"marker_cleanup_pending\":{}}}",
                .{
                    result.nodes_scanned,
                    result.nodes_written,
                    result.edges_scanned,
                    result.edges_written,
                    result.tombstone_nodes_skipped,
                    result.legacy_props_extracted,
                    result.legacy_text_repaired,
                    result.empty_text_physical_placeholders,
                    result.node_properties_written,
                    result.edge_properties_written,
                    result.task_statuses_written,
                    result.legacy_closed_tasks_converted,
                    result.text_warmed,
                    result.verified,
                    result.published_store_bytes,
                    result.published_store_digest[0],
                    result.published_store_digest[1],
                    result.published_store_digest[2],
                    result.published_store_digest[3],
                    result.marker_cleanup_pending,
                },
            );
        }

        pub fn writeTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: TransactionExpectation,
            result: ?StoreMigrationV2Result,
        ) !void {
            const marker_path = try transactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
            defer allocator.free(tmp_path);

            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);
            try out.writeAll("{\"format\":");
            try writeJsonString(&out, store_migration_transaction_marker_format);
            try out.writeAll(",\"canonical_source_path\":");
            try writeJsonString(&out, expected.canonical_source_path);
            try out.writeAll(",\"canonical_backup_path\":");
            try writeJsonString(&out, expected.canonical_backup_path);
            try out.writeAll(",\"target_profiles\":");
            try writeJsonString(&out, expected.target_profiles);
            try out.print(
                ",\"source_store_bytes\":{},\"source_store_digest\":[{},{},{},{}],\"target_catalog_revision\":{},\"target_schema_version\":{},\"strict\":{},\"warm_text\":{},\"verify\":{},\"task_status_v1\":{},\"complete\":{},\"result\":",
                .{
                    expected.source_store_bytes,
                    expected.source_store_digest[0],
                    expected.source_store_digest[1],
                    expected.source_store_digest[2],
                    expected.source_store_digest[3],
                    expected.target_catalog_revision,
                    expected.target_schema_version,
                    expected.strict,
                    expected.warm_text,
                    expected.verify,
                    expected.task_status_v1,
                    result != null,
                },
            );
            if (result) |value| {
                try appendStoreMigrationV2ResultJson(&out, value);
            } else {
                try out.writeAll("null");
            }
            try out.writeAll("}\n");
            writeRecoverableTransactionMarker(allocator, io, tmp_path, marker_path, out.buffer.items) catch |err| switch (err) {
                error.TransactionMarkerConflict => return error.MigrationRecoveryConflict,
                else => |e| return e,
            };
        }

        fn readStoreMigrationV2TransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: TransactionExpectation,
        ) !?StoreMigrationV2MarkerState {
            const marker_path = try transactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            return try readStoreMigrationV2TransactionMarkerAtPath(allocator, io, marker_path, expected);
        }

        fn readStoreMigrationV2TransactionMarkerAtPath(
            allocator: std.mem.Allocator,
            io: std.Io,
            marker_path: []const u8,
            expected: TransactionExpectation,
        ) !?StoreMigrationV2MarkerState {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(32 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return null,
                error.StreamTooLong => return error.InvalidRecord,
                else => |e| return e,
            };
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(StoreMigrationV2TransactionMarkerJson, allocator, bytes, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            }) catch return error.InvalidRecord;
            defer parsed.deinit();
            const marker = parsed.value;
            const legacy_format = std.mem.eql(u8, marker.format, store_migration_transaction_marker_legacy_format);
            if ((!std.mem.eql(u8, marker.format, store_migration_transaction_marker_format) and !legacy_format) or
                !std.mem.eql(u8, marker.canonical_source_path, expected.canonical_source_path) or
                !std.mem.eql(u8, marker.canonical_backup_path, expected.canonical_backup_path) or
                marker.source_store_bytes != expected.source_store_bytes or
                !std.meta.eql(marker.source_store_digest, expected.source_store_digest) or
                !std.mem.eql(u8, marker.target_profiles, expected.target_profiles) or
                marker.target_catalog_revision != expected.target_catalog_revision or
                marker.target_schema_version != expected.target_schema_version or
                marker.strict != expected.strict or
                marker.warm_text != expected.warm_text or
                marker.verify != expected.verify or
                marker.task_status_v1 != expected.task_status_v1)
            {
                return error.MigrationRecoveryConflict;
            }
            if (marker.complete != (marker.result != null)) return error.InvalidRecord;
            if (marker.result) |result| {
                if (result.marker_cleanup_pending or
                    result.text_warmed != expected.warm_text or
                    result.verified != expected.verify or
                    result.published_store_bytes == 0 or
                    std.meta.eql(result.published_store_digest, ContentDigest{ 0, 0, 0, 0 }) or
                    result.nodes_written > result.nodes_scanned or
                    result.edges_written != result.edges_scanned)
                {
                    return error.InvalidRecord;
                }
            }
            return .{ .complete = marker.complete, .result = marker.result, .legacy_format = legacy_format };
        }

        pub fn recoverStaging(
            allocator: std.mem.Allocator,
            io: std.Io,
            staging_path: []const u8,
            expected: TransactionExpectation,
        ) !void {
            if (!try anyPathExists(io, staging_path)) return;
            const stat = try std.Io.Dir.cwd().statFile(io, staging_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.MigrationRecoveryConflict;
            var marker = try readStoreMigrationV2TransactionMarker(allocator, io, staging_path, expected);
            if (marker == null) {
                const marker_path = try transactionMarkerPath(allocator, staging_path);
                defer allocator.free(marker_path);
                const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
                defer allocator.free(tmp_path);
                marker = try readStoreMigrationV2TransactionMarkerAtPath(allocator, io, tmp_path, expected);
            }
            _ = marker orelse return error.MigrationRecoveryConflict;
            try std.Io.Dir.cwd().deleteTree(io, staging_path);
            try syncParentDirectory(io, staging_path);
        }

        fn recoverCompletedStoreMigrationV2(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
            expected: TransactionExpectation,
            expected_catalog: catalog_mod.Catalog,
        ) !?StoreMigrationV2Result {
            if (!try anyPathExists(io, target_path)) return null;
            const stat = try std.Io.Dir.cwd().statFile(io, target_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.AlreadyExists;
            const marker = (try readStoreMigrationV2TransactionMarker(allocator, io, target_path, expected)) orelse
                return error.AlreadyExists;
            if (!marker.complete) return error.InvalidRecord;
            _ = marker.result orelse return error.InvalidRecord;
            // The adjacent publication lock protects the path claim, not normal CLI
            // writers inside an already published store. Take that store's writer
            // lock and re-read the marker before hashing or validating its contents.
            const target_lock = try RecoveryTargetLock.acquire(allocator, io, target_path);
            defer target_lock.deinit();
            const locked_marker = (try readStoreMigrationV2TransactionMarker(allocator, io, target_path, expected)) orelse
                return error.MigrationRecoveryConflict;
            if (!locked_marker.complete) return error.InvalidRecord;
            var result = locked_marker.result orelse return error.InvalidRecord;
            const target_identity = try storeContentIdentity(allocator, io, target_path);
            if (target_identity.bytes != result.published_store_bytes or
                !std.meta.eql(target_identity.digest, result.published_store_digest))
            {
                return error.MigrationRecoveryConflict;
            }
            if (!try existingTinyKgStorePath(allocator, io, target_path)) return error.InvalidRecord;

            var target = try storage.Store.open(allocator, io, target_path);
            defer target.deinit();
            const stats_out = try target.stats();
            if (stats_out.nodes != result.nodes_written or stats_out.edges != result.edges_written) return error.InvalidRecord;
            var actual_catalog = (try target.readCatalog()) orelse return error.InvalidRecord;
            defer actual_catalog.deinit();
            const actual_catalog_bytes = try catalog_mod.encodeCatalog(allocator, actual_catalog);
            defer allocator.free(actual_catalog_bytes);
            const expected_catalog_bytes = try catalog_mod.encodeCatalog(allocator, expected_catalog);
            defer allocator.free(expected_catalog_bytes);
            if (!std.mem.eql(u8, actual_catalog_bytes, expected_catalog_bytes)) return error.MigrationRecoveryConflict;

            const manifest = try readStoreManifestSummary(allocator, io, target_path);
            defer manifest.deinit(allocator);
            const expected_schema_version = try std.fmt.allocPrint(allocator, "{}", .{expected.target_schema_version});
            defer allocator.free(expected_schema_version);
            const expected_storage_version = try std.fmt.allocPrint(allocator, "{}", .{current_storage_format_version});
            defer allocator.free(expected_storage_version);
            const expected_migration_name = if (expected.task_status_v1) "migrate-store-v2+task-status-v1" else "migrate-store-v2";
            if (!std.mem.eql(u8, manifest.status, "present") or
                !std.mem.eql(u8, manifest.storage_format_version, expected_storage_version) or
                !std.mem.eql(u8, manifest.schema_version, expected_schema_version) or
                !std.mem.eql(u8, manifest.enabled_profiles, expected.target_profiles) or
                !std.mem.eql(u8, manifest.migration_name, expected_migration_name) or
                manifest.migration_source.len == 0)
            {
                return error.MigrationRecoveryConflict;
            }
            const canonical_manifest_source = canonicalProspectivePath(allocator, io, manifest.migration_source) catch
                return error.MigrationRecoveryConflict;
            defer allocator.free(canonical_manifest_source);
            if (!canonicalPathsEqual(canonical_manifest_source, expected.canonical_source_path)) return error.MigrationRecoveryConflict;
            if (expected.warm_text and try text_search.persistentTextCatalogQuickStale(allocator, target)) return error.InvalidRecord;

            if (locked_marker.legacy_format) {
                try writeTransactionMarker(allocator, io, target_path, expected, result);
            }

            // A retry that can still observe the renamed directory makes the earlier
            // rename durable before it acknowledges the committed result.
            try syncParentDirectory(io, target_path);
            // Keep the complete marker as a durable commit receipt.  stdout may fail
            // after this function returns; deleting the only request-bound receipt
            // here would make that committed migration impossible to acknowledge on
            // retry without trusting an arbitrary pre-existing target.
            result.marker_cleanup_pending = false;
            return result;
        }

        fn migrateStoreV2(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedMigrateStoreV2Args) !StoreMigrationV2Result {
            // Keep the validation here as well: migrateStoreV2 is used directly by
            // tests/embedders and must not rely on the CLI dispatcher for safety.
            try validateMigrateStoreV2PathRelationships(allocator, io, parsed);
            if (parsed.dry_run) try validateMigrateStoreV2Destinations(io, parsed);

            var source = try storage.Store.openWithOptions(allocator, io, parsed.source_path, .{
                .allow_legacy_store_format_read = true,
            });
            defer source.deinit();
            var target_catalog = try migrationCatalog(allocator, source, parsed.profiles, parsed.profiles_explicit, parsed.task_status_v1);
            defer target_catalog.deinit();
            const target_profiles = try catalogProfilesCsvAlloc(allocator, target_catalog);
            defer allocator.free(target_profiles);
            const target_schema_version: u32 = if (parsed.task_status_v1) current_schema_version else 2;
            const canonical_source_path = try canonicalProspectivePath(allocator, io, parsed.source_path);
            defer allocator.free(canonical_source_path);
            const canonical_backup_path = if (parsed.backup_path) |backup_path|
                try canonicalProspectivePath(allocator, io, backup_path)
            else
                try allocator.dupe(u8, "");
            defer allocator.free(canonical_backup_path);
            const source_identity = try storeContentIdentity(allocator, io, parsed.source_path);
            const migration_expectation = TransactionExpectation{
                .canonical_source_path = canonical_source_path,
                .canonical_backup_path = canonical_backup_path,
                .source_store_bytes = source_identity.bytes,
                .source_store_digest = source_identity.digest,
                .target_profiles = target_profiles,
                .target_catalog_revision = target_catalog.revision,
                .target_schema_version = target_schema_version,
                .strict = parsed.strict,
                .warm_text = parsed.warm_text,
                .verify = parsed.verify,
                .task_status_v1 = parsed.task_status_v1,
            };
            const staging_path = try stagingPath(allocator, parsed.target_path);
            defer allocator.free(staging_path);
            // Dry runs use the same private scratch path and marker discipline. A
            // crash while external-sorting must be reclaimable by the next request,
            // not leave an unmarked directory that blocks every future migration.
            try recoverStaging(allocator, io, staging_path, migration_expectation);
            if (!parsed.dry_run) {
                if (try recoverCompletedStoreMigrationV2(allocator, io, parsed.target_path, migration_expectation, target_catalog)) |recovered| {
                    return recovered;
                }
                try validateMigrateStoreV2Destinations(io, parsed);
                if (parsed.backup_path) |backup_path| {
                    if (try anyPathExists(io, backup_path)) {
                        _ = try validateExistingBackupForSource(allocator, io, parsed.source_path, backup_path);
                    } else {
                        _ = try backupStore(allocator, io, parsed.source_path, backup_path);
                    }
                }
            }
            var result = StoreMigrationV2Result{};
            const migration_now_ns = try u128ToU64(persistentNowNs(io));
            try createOwnedDirectory(io, staging_path);
            var staging_owned = true;
            defer if (staging_owned) std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeTransactionMarker(allocator, io, staging_path, migration_expectation, null);
            try syncExportDirectoryTree(allocator, io, staging_path);

            {
                var node_property_keys = try MigrationPropertyKeys.init(allocator, target_catalog.registry, target_catalog.registry, .node);
                defer node_property_keys.deinit();
                var edge_property_keys = try MigrationPropertyKeys.init(allocator, target_catalog.registry, target_catalog.registry, .edge);
                defer edge_property_keys.deinit();
                var source_property_spool = try MigrationPropertySpool.buildAll(
                    allocator,
                    io,
                    staging_path,
                    source,
                    &node_property_keys,
                    &edge_property_keys,
                );
                defer source_property_spool.deinit();

                if (parsed.dry_run) {
                    var source_property_stream = try MigrationPropertyStream.init(&source_property_spool);
                    defer source_property_stream.deinit();
                    try migrateStoreV2Nodes(
                        allocator,
                        source,
                        null,
                        target_catalog,
                        &source_property_stream,
                        null,
                        parsed,
                        migration_now_ns,
                        &result,
                    );
                    try migrateStoreV2Edges(
                        allocator,
                        source,
                        null,
                        target_catalog,
                        &source_property_stream,
                        null,
                        &result,
                    );
                    try source_property_stream.finish();
                    result.verified = true;
                    return result;
                }

                // Materialize only in the private staging tree. The final target remains
                // absent until a complete, verified and synced store can claim it with a
                // single directory rename.
                var target = storage.Store.initWithOptions(allocator, io, staging_path, .{
                    .primary_text_write_mode = .bulk_ingest,
                    // Migration emits many bounded edge batches before one final
                    // consolidation. Avoid periodically compacting the growing
                    // segment overlay into the base indexes during that stream.
                    .auto_compact_edge_segment_entries = std.math.maxInt(u32),
                }) catch |err| return err;
                var target_open = true;
                defer if (target_open) target.deinit();
                try target.createEmpty();
                try target.writeCatalog(target_catalog);
                var source_property_stream = try MigrationPropertyStream.init(&source_property_spool);
                defer source_property_stream.deinit();
                var target_property_builder = try MigrationTargetPropertySpoolBuilder.init(
                    allocator,
                    io,
                    staging_path,
                    &node_property_keys,
                    &edge_property_keys,
                );
                defer target_property_builder.deinit();
                try migrateStoreV2Nodes(
                    allocator,
                    source,
                    target,
                    target_catalog,
                    &source_property_stream,
                    &target_property_builder,
                    parsed,
                    migration_now_ns,
                    &result,
                );
                target.finalizePrimaryTextStorage() catch return error.MigrationAppendNodesFailed;
                try migrateStoreV2Edges(
                    allocator,
                    source,
                    target,
                    target_catalog,
                    &source_property_stream,
                    &target_property_builder,
                    &result,
                );
                try source_property_stream.finish();
                var target_property_spool = try target_property_builder.finish();
                defer target_property_spool.deinit();
                const expected_property_writes = std.math.add(u64, result.node_properties_written, result.edge_properties_written) catch return error.MigrationPropertyBatchFailed;
                if (target_property_spool.record_count != expected_property_writes) return error.MigrationPropertyBatchFailed;
                var target_property_stream = try MigrationPropertyStream.init(&target_property_spool);
                defer target_property_stream.deinit();
                target.replaceEmptyPropertyPayloadFromSortedStream(
                    target_property_spool.record_count,
                    &target_property_stream,
                    MigrationPropertyStream.nextSortedPayload,
                ) catch return error.MigrationPropertyBatchFailed;

                _ = try copyMetaknowDeferredBasedOnSidecarForMigration(allocator, io, source.dir_path, target.dir_path);

                if (parsed.warm_text) {
                    _ = try text_search.rebuildPersistentTextCatalog(allocator, target);
                    result.text_warmed = true;
                }

                try writeStoreManifest(allocator, io, staging_path, .{
                    .profiles = target_profiles,
                    .migration_name = if (parsed.task_status_v1) "migrate-store-v2+task-status-v1" else "migrate-store-v2",
                    .source_path = canonical_source_path,
                    // Schema v3 is an on-disk promise that every task has a durable
                    // status marker. A compatibility migration without --task-status-v1
                    // must remain v2 or effective-status queries can silently omit tasks.
                    .schema_version = target_schema_version,
                });

                if (parsed.verify) {
                    try verifyMigratedStoreV2(
                        allocator,
                        source,
                        target,
                        &source_property_spool,
                        &target_property_spool,
                        parsed,
                        migration_now_ns,
                        target_catalog,
                        target_profiles,
                        target_schema_version,
                        result,
                    );
                    result.verified = true;
                }

                target.deinit();
                target_open = false;
            }
            const current_source_identity = try storeContentIdentity(allocator, io, parsed.source_path);
            if (current_source_identity.bytes != source_identity.bytes or
                !std.meta.eql(current_source_identity.digest, source_identity.digest))
            {
                return error.MigrationSourceChanged;
            }
            const published_identity = try storeContentIdentity(allocator, io, staging_path);
            result.published_store_bytes = published_identity.bytes;
            result.published_store_digest = published_identity.digest;
            try writeTransactionMarker(allocator, io, staging_path, migration_expectation, result);
            try syncExportDirectoryTree(allocator, io, staging_path);
            // A foreign path can still appear after preflight. Never overwrite it and
            // never reinterpret it as our staging tree.
            try validateMigrateStoreV2PathRelationships(allocator, io, parsed);
            if (try anyPathExists(io, parsed.target_path)) return error.AlreadyExists;
            try renamePath(io, staging_path, parsed.target_path);
            staging_owned = false;
            try syncParentDirectory(io, parsed.target_path);
            // The complete transaction marker is retained as the idempotency receipt
            // for a caller that loses the success response after the rename commit.
            result.marker_cleanup_pending = false;
            return result;
        }

        const LegacyNodeTextRepair = struct {
            text: []u8,
            props_json: ?[]const u8 = null,
            repaired: bool = false,

            fn deinit(self: *LegacyNodeTextRepair, allocator: std.mem.Allocator) void {
                allocator.free(self.text);
            }
        };

        fn repairLegacyNodeTextForMigration(allocator: std.mem.Allocator, text: []const u8, strict: bool, result: *StoreMigrationV2Result, count_repair: bool) !LegacyNodeTextRepair {
            const marker = " props_text=\"";
            const marker_index = std.mem.indexOf(u8, text, marker) orelse {
                return .{ .text = try allocator.dupe(u8, text) };
            };
            const json_start = marker_index + marker.len;
            const json_slice = legacyJsonObjectSlice(text[json_start..]) orelse {
                if (strict) return error.InvalidRecord;
                return .{ .text = try allocator.dupe(u8, text) };
            };
            const visible = std.mem.trim(u8, text[0..marker_index], " \t\r\n");
            if (count_repair) result.legacy_text_repaired += 1;
            return .{
                .text = try allocator.dupe(u8, visible),
                .props_json = json_slice,
                .repaired = true,
            };
        }

        fn legacyJsonObjectSlice(text: []const u8) ?[]const u8 {
            if (text.len == 0 or text[0] != '{') return null;
            var depth: usize = 0;
            var in_string = false;
            var escaped = false;
            for (text, 0..) |byte, index| {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (in_string and byte == '\\') {
                    escaped = true;
                    continue;
                }
                if (byte == '"') {
                    in_string = !in_string;
                    continue;
                }
                if (in_string) continue;
                if (byte == '{') {
                    depth += 1;
                } else if (byte == '}') {
                    if (depth == 0) return null;
                    depth -= 1;
                    if (depth == 0) return text[0 .. index + 1];
                }
            }
            return null;
        }

        pub fn legacyPropsObject(text: []const u8) ?[]const u8 {
            return legacyJsonObjectSlice(text);
        }

        fn appendLegacyNodePropsTextProperties(
            allocator: std.mem.Allocator,
            source_properties: *const MigrationPropertyLookup,
            node_id: core.NodeId,
            props_json_input: ?[]const u8,
            strict: bool,
            result: *StoreMigrationV2Result,
            batch: *MigrationPropertyBatch,
            materialize_status: bool,
            force_task_schema: bool,
        ) !u64 {
            const props_json = props_json_input orelse return 0;

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, props_json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch |err| {
                if (strict) return err;
                return 0;
            };
            defer parsed.deinit();
            if (parsed.value != .object) return 0;

            var count: u64 = 0;
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!migrationPropertyKeyValid(key) or std.mem.eql(u8, key, "text")) continue;
                if (migrationPropertySuppressedByTaskStatusV1(key, materialize_status, force_task_schema)) continue;
                const owner: storage.PropertyOwner = .{ .node = node_id };
                if (source_properties.get(owner, key) != null) continue;
                switch (entry.value_ptr.*) {
                    .string => |value| {
                        try batch.appendString(owner, key, value);
                        count += 1;
                        result.legacy_props_extracted += 1;
                    },
                    .integer => |value| {
                        if (value < 0) continue;
                        try batch.appendUint(owner, key, @intCast(value));
                        count += 1;
                        result.legacy_props_extracted += 1;
                    },
                    .bool => |value| {
                        try batch.appendString(owner, key, if (value) "true" else "false");
                        count += 1;
                        result.legacy_props_extracted += 1;
                    },
                    else => {},
                }
            }
            return count;
        }

        fn countLegacyNodePropsTextProperties(
            allocator: std.mem.Allocator,
            source_properties: *const MigrationPropertyLookup,
            node_id: core.NodeId,
            props_json: ?[]const u8,
            strict: bool,
            materialize_status: bool,
            force_task_schema: bool,
        ) !u64 {
            const json = props_json orelse return 0;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch |err| {
                if (strict) return err;
                return 0;
            };
            defer parsed.deinit();
            if (parsed.value != .object) return 0;
            var count: u64 = 0;
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!migrationPropertyKeyValid(key) or std.mem.eql(u8, key, "text")) continue;
                if (migrationPropertySuppressedByTaskStatusV1(key, materialize_status, force_task_schema)) continue;
                const owner: storage.PropertyOwner = .{ .node = node_id };
                if (source_properties.get(owner, key) != null) continue;
                switch (entry.value_ptr.*) {
                    .string, .integer, .bool => count += 1,
                    else => {},
                }
            }
            return count;
        }

        fn verifyStoreMigrationNodeBatch(
            allocator: std.mem.Allocator,
            source_nodes: []const storage.StoredNode,
            property_stream: *MigrationPropertyStream,
            target_nodes: *storage.Store.NodeRecordIterator,
            parsed: ParsedMigrateStoreV2Args,
            migration_now_ns: u64,
        ) !u64 {
            if (source_nodes.len == 0) return 0;
            var raw_ids = std.ArrayList(u64).empty;
            defer raw_ids.deinit(allocator);
            try raw_ids.ensureTotalCapacityPrecise(allocator, source_nodes.len);
            for (source_nodes) |node| raw_ids.appendAssumeCapacity(node.id.toInt());
            const snapshot = try property_stream.snapshotForOwners(1, raw_ids.items);
            var source_properties = try MigrationPropertyLookup.initFromSnapshot(allocator, snapshot);
            defer source_properties.deinit();
            var dummy_result = StoreMigrationV2Result{};
            for (source_nodes) |source_node| {
                var repaired = try repairLegacyNodeTextForMigration(allocator, source_node.text, parsed.strict, &dummy_result, false);
                defer repaired.deinit(allocator);
                var migration_lifecycle = if (parsed.task_status_v1)
                    try migrationLifecycleFieldsWithLegacyProps(
                        allocator,
                        &source_properties,
                        source_node.id,
                        repaired.props_json,
                        parsed.strict,
                    )
                else
                    MigrationLifecycleFields{ .fields = .{} };
                defer migration_lifecycle.deinit(allocator);
                const materialized_status = if (parsed.task_status_v1)
                    try taskStatusForMigration(source_node, migration_lifecycle.fields, migration_now_ns)
                else
                    null;
                const expected_kind: core.NodeKind = if (materialized_status != null) .task else source_node.kind;
                var actual = (try target_nodes.next(allocator)) orelse return error.InvalidRecord;
                defer actual.deinit(allocator);
                if (actual.id != source_node.id or actual.kind != expected_kind or !std.mem.eql(u8, actual.text, repaired.text)) return error.InvalidRecord;
            }
            return @intCast(source_nodes.len);
        }

        fn verifyMigratedStoreV2(
            allocator: std.mem.Allocator,
            source: storage.Store,
            target: storage.Store,
            source_property_spool: *const MigrationPropertySpool,
            expected_property_spool: *const MigrationPropertySpool,
            parsed: ParsedMigrateStoreV2Args,
            migration_now_ns: u64,
            expected_catalog: catalog_mod.Catalog,
            expected_profiles: []const u8,
            expected_schema_version: u32,
            result: StoreMigrationV2Result,
        ) !void {
            const source_stats = try source.stats();
            const target_stats = try target.stats();
            if (target_stats.nodes != result.nodes_written or target_stats.edges != result.edges_written) return error.InvalidRecord;
            if (source_stats.nodes < target_stats.nodes or source_stats.edges < target_stats.edges) return error.InvalidRecord;

            var actual_catalog = (try target.readCatalog()) orelse return error.InvalidRecord;
            defer actual_catalog.deinit();
            const expected_catalog_bytes = try catalog_mod.encodeCatalog(allocator, expected_catalog);
            defer allocator.free(expected_catalog_bytes);
            const actual_catalog_bytes = try catalog_mod.encodeCatalog(allocator, actual_catalog);
            defer allocator.free(actual_catalog_bytes);
            if (!std.mem.eql(u8, expected_catalog_bytes, actual_catalog_bytes)) return error.InvalidRecord;

            const manifest = try readStoreManifestSummary(allocator, target.io, target.dir_path);
            defer manifest.deinit(allocator);
            const expected_storage_text = try std.fmt.allocPrint(allocator, "{}", .{current_storage_format_version});
            defer allocator.free(expected_storage_text);
            if (!std.mem.eql(u8, manifest.status, "present") or
                !std.mem.eql(u8, manifest.storage_format_version, expected_storage_text) or
                !std.mem.eql(u8, manifest.enabled_profiles, expected_profiles)) return error.InvalidRecord;
            const expected_schema_text = try std.fmt.allocPrint(allocator, "{}", .{expected_schema_version});
            defer allocator.free(expected_schema_text);
            if (!std.mem.eql(u8, manifest.schema_version, expected_schema_text)) return error.InvalidRecord;

            var source_property_stream = try MigrationPropertyStream.init(source_property_spool);
            defer source_property_stream.deinit();
            var source_nodes = try source.nodeRecordsIterator(null);
            defer source_nodes.deinit();
            var target_nodes = try target.nodeRecordsIterator(null);
            defer target_nodes.deinit();
            var node_batch = std.ArrayList(storage.StoredNode).empty;
            defer {
                for (node_batch.items) |*node| node.deinit(allocator);
                node_batch.deinit(allocator);
            }
            try node_batch.ensureTotalCapacityPrecise(allocator, store_migration_node_batch_limit);
            var nodes_verified: u64 = 0;
            while (try source_nodes.next(allocator)) |stored_node| {
                var node = stored_node;
                if (isDeletedNodeTombstone(node)) {
                    node.deinit(allocator);
                    continue;
                }
                node_batch.appendAssumeCapacity(node);
                if (node_batch.items.len < store_migration_node_batch_limit) continue;
                nodes_verified += try verifyStoreMigrationNodeBatch(
                    allocator,
                    node_batch.items,
                    &source_property_stream,
                    &target_nodes,
                    parsed,
                    migration_now_ns,
                );
                for (node_batch.items) |*owned| owned.deinit(allocator);
                node_batch.clearRetainingCapacity();
            }
            if (node_batch.items.len != 0) {
                nodes_verified += try verifyStoreMigrationNodeBatch(
                    allocator,
                    node_batch.items,
                    &source_property_stream,
                    &target_nodes,
                    parsed,
                    migration_now_ns,
                );
                for (node_batch.items) |*owned| owned.deinit(allocator);
                node_batch.clearRetainingCapacity();
            }
            if (nodes_verified != result.nodes_written) return error.InvalidRecord;
            if (try target_nodes.next(allocator)) |extra_node| {
                var owned_extra = extra_node;
                owned_extra.deinit(allocator);
                return error.InvalidRecord;
            }
            try source_property_stream.finish();

            var target_edges = try target.visibleEdgeIndexRecordsIterator(.src);
            defer target_edges.deinit();
            const EdgeCompare = struct {
                target_edges: *storage.Store.VisibleEdgeIndexRecordIterator,
                count: u64 = 0,

                fn visit(raw_context: *anyopaque, expected: storage.EdgeIndexRecord) anyerror!void {
                    const context: *@This() = @ptrCast(@alignCast(raw_context));
                    const actual = (try context.target_edges.next()) orelse return error.InvalidRecord;
                    if (actual.edge_id != expected.edge_id or actual.src != expected.src or actual.dst != expected.dst or actual.rel != expected.rel) return error.InvalidRecord;
                    context.count = std.math.add(u64, context.count, 1) catch return error.RecordTooLarge;
                }
            };
            var edge_compare = EdgeCompare{ .target_edges = &target_edges };
            const edges_verified = try source.scanVisibleEdgeIndexRecords(allocator, &edge_compare, EdgeCompare.visit);
            if (edges_verified != edge_compare.count) return error.InvalidRecord;
            if (edges_verified != result.edges_written or try target_edges.next() != null) return error.InvalidRecord;

            var expected_property_stream = try MigrationPropertyStream.init(expected_property_spool);
            defer expected_property_stream.deinit();
            const PropertyCompare = struct {
                expected: *MigrationPropertyStream,
                count: u64 = 0,

                fn visit(raw_context: *anyopaque, actual: storage.PropertySnapshotLayerEntry) anyerror!void {
                    const context: *@This() = @ptrCast(@alignCast(raw_context));
                    const expected = (try MigrationPropertyStream.nextSortedPayload(context.expected)) orelse return error.InvalidRecord;
                    const same_owner = switch (expected.owner) {
                        .node => |expected_id| switch (actual.owner) {
                            .node => |actual_id| expected_id == actual_id,
                            .edge => false,
                        },
                        .edge => |expected_id| switch (actual.owner) {
                            .node => false,
                            .edge => |actual_id| expected_id == actual_id,
                        },
                    };
                    if (!same_owner or expected.key_hash != actual.key_hash) return error.InvalidRecord;
                    switch (expected.value) {
                        .string => |value| if (actual.value_kind != .string or !std.mem.eql(u8, value, actual.string_value)) return error.InvalidRecord,
                        .uint => |value| if (actual.value_kind != .uint or value != actual.uint_value) return error.InvalidRecord,
                    }
                    context.count = std.math.add(u64, context.count, 1) catch return error.RecordTooLarge;
                }
            };
            var property_compare = PropertyCompare{ .expected = &expected_property_stream };
            try target.scanPropertySnapshotLayers(allocator, &property_compare, PropertyCompare.visit);
            if (try MigrationPropertyStream.nextSortedPayload(&expected_property_stream) != null or
                property_compare.count != expected_property_spool.record_count) return error.InvalidRecord;
        }

        pub fn validateRelationships(
            allocator: std.mem.Allocator,
            io: std.Io,
            parsed: ParsedMigrateStoreV2Args,
        ) !void {
            try validateMigrateStoreV2PathRelationships(allocator, io, parsed);
        }

        pub fn validatePaths(
            allocator: std.mem.Allocator,
            io: std.Io,
            parsed: ParsedMigrateStoreV2Args,
        ) !void {
            try validateMigrateStoreV2Paths(allocator, io, parsed);
        }

        pub fn execute(
            allocator: std.mem.Allocator,
            io: std.Io,
            parsed: ParsedMigrateStoreV2Args,
        ) !Result {
            return migrateStoreV2(allocator, io, parsed);
        }
    };
}

const TestArguments = struct {
    source_path: []const u8,
    target_path: []const u8,
    backup_path: ?[]const u8 = null,
    dry_run: bool = false,
};

const TestOps = struct {
    pub const Arguments = TestArguments;
    pub const Digest = [4]u64;

    var relationship_checked = false;
    var destination_checked = false;

    fn reset() void {
        relationship_checked = false;
        destination_checked = false;
    }

    pub fn canonicalProspectivePathFn(
        allocator: std.mem.Allocator,
        _: std.Io,
        path: []const u8,
    ) ![]u8 {
        relationship_checked = true;
        return allocator.dupe(u8, path);
    }

    pub fn canonicalPathsEqualFn(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn pathsOverlapForCopyTargetFn(
        _: std.mem.Allocator,
        _: std.Io,
        source_path: []const u8,
        target_path: []const u8,
    ) !bool {
        try std.testing.expect(relationship_checked);
        try std.testing.expect(!destination_checked);
        return std.mem.eql(u8, source_path, target_path);
    }

    pub fn pathsOverlapFn(
        _: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
        _: []const u8,
    ) !bool {
        try std.testing.expect(relationship_checked);
        try std.testing.expect(!destination_checked);
        return false;
    }

    pub fn anyPathExistsFn(_: std.Io, _: []const u8) !bool {
        try std.testing.expect(relationship_checked);
        destination_checked = true;
        return false;
    }

    pub fn existingTinyKgStorePathFn(
        _: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
    ) !bool {
        relationship_checked = true;
        return true;
    }
};

const TestPlane = StoreMigrationV2DataPlane(TestOps);

test "store migration v2 result begins as an unpublished receipt" {
    const result = TestPlane.Result{};
    try std.testing.expectEqual(@as(u64, 0), result.nodes_written);
    try std.testing.expectEqual(@as(u64, 0), result.published_store_bytes);
    try std.testing.expectEqual([4]u64{ 0, 0, 0, 0 }, result.published_store_digest);
    try std.testing.expect(!result.verified);
    try std.testing.expect(!result.marker_cleanup_pending);
}

test "store migration v2 legacy props isolate one complete object" {
    try std.testing.expectEqualStrings(
        "{\"domain\":\"tinykg\"}",
        TestPlane.legacyPropsObject("{\"domain\":\"tinykg\"} ignored").?,
    );
}

test "store migration v2 legacy props preserve nested and quoted braces" {
    const input = "{\"nested\":{\"text\":\"quoted } and \\\"{\\\"\"}} tail";
    try std.testing.expectEqualStrings(
        "{\"nested\":{\"text\":\"quoted } and \\\"{\\\"\"}}",
        TestPlane.legacyPropsObject(input).?,
    );
}

test "store migration v2 legacy props reject incomplete objects" {
    try std.testing.expect(TestPlane.legacyPropsObject("not-an-object") == null);
    try std.testing.expect(TestPlane.legacyPropsObject("{\"nested\":{") == null);
}

test "store migration v2 path validation preserves relationship before destination order" {
    TestOps.reset();
    try TestPlane.validatePaths(std.testing.allocator, std.testing.io, .{
        .source_path = "source.kg",
        .target_path = "target.kg",
        .backup_path = "backup.kg",
    });
    try std.testing.expect(TestOps.relationship_checked);
    try std.testing.expect(TestOps.destination_checked);
}

test "store migration v2 path validation rejects source target aliases" {
    TestOps.reset();
    try std.testing.expectError(error.InvalidFileName, TestPlane.validatePaths(
        std.testing.allocator,
        std.testing.io,
        .{ .source_path = "same.kg", .target_path = "same.kg" },
    ));
    try std.testing.expect(TestOps.relationship_checked);
    try std.testing.expect(!TestOps.destination_checked);
}
