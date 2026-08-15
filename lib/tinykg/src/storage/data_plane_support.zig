const property_block_codec = @import("property_block_codec.zig");

/// Transitional storage support owner for rebuild state, index algorithms,
/// segment streams and capability adapters. It is deliberately below one
/// mebibyte and remains scheduled for responsibility-level refinement.
pub fn StorageDataPlaneSupport(comptime Ops: type) type {
    return struct {
        const std = Ops.dep_std;
        const builtin = Ops.dep_builtin;
        const core = Ops.dep_core;
        const graph_mod = Ops.dep_graph_mod;
        const schema = Ops.dep_schema;
        const segment_mod = Ops.dep_segment_mod;
        const segment_manifest = Ops.dep_segment_manifest;
        const segment_node_index = Ops.dep_segment_node_index;
        const process_liveness = Ops.dep_process_liveness;
        const edge_segment_gc_mod = Ops.dep_edge_segment_gc_mod;
        const edge_segment_maintenance_mod = Ops.dep_edge_segment_maintenance_mod;
        const edge_segment_merge_mod = Ops.dep_edge_segment_merge_mod;
        const edge_segment_publication_mod = Ops.dep_edge_segment_publication_mod;
        const edge_segment_query_opening_mod = Ops.dep_edge_segment_query_opening_mod;
        const edge_segment_window_compaction_mod = Ops.dep_edge_segment_window_compaction_mod;
        const edge_repair_index_publication_mod = Ops.dep_edge_repair_index_publication_mod;
        const edge_tombstone_repair_index_publication_mod = Ops.dep_edge_tombstone_repair_index_publication_mod;
        const manifest_process_lease_mod = Ops.dep_manifest_process_lease_mod;
        const node_text_catalog_transaction_mod = Ops.dep_node_text_catalog_transaction_mod;
        const node_text_lookup_view_data_plane_mod = Ops.dep_node_text_lookup_view_data_plane_mod;
        const node_text_maintenance_mod = Ops.dep_node_text_maintenance_mod;
        const node_text_repair_index_publication_mod = Ops.dep_node_text_repair_index_publication_mod;
        const persistent_rebuild_pipeline_mod = Ops.dep_persistent_rebuild_pipeline_mod;
        const primary_node_text_mod = Ops.dep_primary_node_text_mod;
        const node_text_run_gc_mod = Ops.dep_node_text_run_gc_mod;
        const binary_event_log_codec = Ops.dep_binary_event_log_codec;
        const edge_index_format = Ops.dep_edge_index_format;
        const edge_order_format = Ops.dep_edge_order_format;
        const edge_tombstone_format = Ops.dep_edge_tombstone_format;
        const external_key_format = Ops.dep_external_key_format;
        const index_meta_format = Ops.dep_index_meta_format;
        const edge_segment_manifest_format = Ops.dep_edge_segment_manifest_format;
        const node_text_run_manifest_format = Ops.dep_node_text_run_manifest_format;
        const property_format = Ops.dep_property_format;
        const property_payload_transaction_mod = Ops.dep_property_payload_transaction_mod;
        const repair_session_mod = Ops.dep_repair_session_mod;
        const store_bootstrap_mod = Ops.dep_store_bootstrap_mod;
        const store_cache_resources_mod = Ops.dep_store_cache_resources_mod;
        const store_opening_control = Ops.dep_store_opening_control;
        const EdgeIndexOrder = Ops.dep_EdgeIndexOrder;
        const EdgeIndexHeader = Ops.dep_EdgeIndexHeader;
        const EdgeIndexRecord = Ops.dep_EdgeIndexRecord;
        const EdgeOrderRecord = Ops.dep_EdgeOrderRecord;
        const IndexMeta = Ops.dep_IndexMeta;
        const NodeByIdHeader = Ops.dep_NodeByIdHeader;
        const NodeByIdRecord = Ops.dep_NodeByIdRecord;
        const NodeTextIndexHeader = Ops.dep_NodeTextIndexHeader;
        const NodeTextIndexRecord = Ops.dep_NodeTextIndexRecord;
        const DurabilityMode = Ops.dep_DurabilityMode;
        const StorageOptions = Ops.dep_StorageOptions;
        const EdgeSegmentMaintenanceBudget = Ops.dep_EdgeSegmentMaintenanceBudget;
        const EdgeSegmentMaintenanceResult = Ops.dep_EdgeSegmentMaintenanceResult;
        const EdgeSegmentGcResult = Ops.dep_EdgeSegmentGcResult;
        const ManifestProcessLease = Ops.dep_ManifestProcessLease;
        const EdgeSegmentRetentionRegistry = Ops.dep_EdgeSegmentRetentionRegistry;
        const EdgeSegmentRegisteredRetentionWindow = Ops.dep_EdgeSegmentRegisteredRetentionWindow;
        const NodeTextRunRetentionRegistry = Ops.dep_NodeTextRunRetentionRegistry;
        const NodeTextRunRegisteredRetentionWindow = Ops.dep_NodeTextRunRegisteredRetentionWindow;
        const PersistentRepairTimings = Ops.dep_PersistentRepairTimings;
        const NodeTextsCompressionResult = Ops.dep_NodeTextsCompressionResult;
        const NodeTextDeltaMaintenanceResult = Ops.dep_NodeTextDeltaMaintenanceResult;
        const NodeTextRunMaintenanceResult = Ops.dep_NodeTextRunMaintenanceResult;
        const NodeTextRunGcResult = Ops.dep_NodeTextRunGcResult;
        const SegmentKind = Ops.dep_SegmentKind;
        const SegmentHeader = Ops.dep_SegmentHeader;
        const Manifest = Ops.dep_Manifest;
        const StoreStats = Ops.dep_StoreStats;
        const StoredNode = Ops.dep_StoredNode;
        const PropertyOwner = Ops.dep_PropertyOwner;
        const PropertyPayloadWrite = Ops.dep_PropertyPayloadWrite;
        const SortedPropertyPayloadNext = Ops.dep_SortedPropertyPayloadNext;
        const PropertyPayloadCompactionResult = Ops.dep_PropertyPayloadCompactionResult;
        const PropertySnapshotEntry = Ops.dep_PropertySnapshotEntry;
        const PropertySnapshotLayerVisitor = Ops.dep_PropertySnapshotLayerVisitor;
        const Store = Ops.dep_Store;
        const PublishedEdgeSegments = Ops.dep_PublishedEdgeSegments;
        const PublishedEdgeSegmentsCoverage = Ops.dep_PublishedEdgeSegmentsCoverage;
        const PublishedEdgeSegmentsForQuery = Ops.dep_PublishedEdgeSegmentsForQuery;
        const store_plane = Ops.store_plane;
        const EdgeRepairRunHeapContext = Ops.store_type_EdgeRepairRunHeapContext;
        const EdgeRepairRunHeapEntry = Ops.store_type_EdgeRepairRunHeapEntry;
        const EdgeRepairRunReader = Ops.store_type_EdgeRepairRunReader;
        const EdgeTombstoneIndexView = Ops.store_type_EdgeTombstoneIndexView;
        const NodeByIdIndexView = Ops.store_type_NodeByIdIndexView;
        const NodeTextDeltaRunCache = Ops.store_type_NodeTextDeltaRunCache;
        const NodeTextLookupRun = Ops.store_type_NodeTextLookupRun;
        const NodeTextRepairPublishShape = Ops.store_type_NodeTextRepairPublishShape;
        const NodeTextsView = Ops.store_type_NodeTextsView;
        const compareEdgeRepairRunHeapEntry = Ops.store_type_compareEdgeRepairRunHeapEntry;

        pub const EdgeTombstoneHeader = edge_tombstone_format.Header;
        pub const EdgeTombstoneRecord = edge_tombstone_format.Record;
        pub const EdgeIndexRelDerivation = edge_index_format.EdgeIndexRelDerivation;
        pub const EdgeIndexDenseKeyRunSpan = edge_index_format.EdgeIndexDenseKeyRunSpan;
        pub const EdgeIndexKeyRunRecord = edge_index_format.EdgeIndexKeyRunRecord;
        pub const edgeIndexStoredEndpointLen = edge_index_format.storedEndpointLen;
        pub const edgeIndexStoredEdgeIdLen = edge_index_format.storedEdgeIdLen;
        pub const edgeIndexKeyRunRecordLen = edge_index_format.keyRunRecordLen;
        pub const edgeIndexKeyRunDirectorySizeForHeader = edge_index_format.keyRunDirectorySizeForHeader;
        pub const edgeIndexKeyRunOffsetForHeader = edge_index_format.keyRunOffsetForHeader;
        pub const edgeIndexRingOppositeForKey = edge_index_format.ringOppositeForKey;
        pub const EdgeOrderHeader = edge_order_format.EdgeOrderHeader;
        pub const ExternalKeyIndexHeader = external_key_format.NodeIndexHeader;
        pub const ExternalKeyIndexRecord = external_key_format.NodeIndexRecord;
        pub const EdgeExternalKeyIndexHeader = external_key_format.EdgeIndexHeader;
        pub const EdgeExternalKeyIndexRecord = external_key_format.EdgeIndexRecord;
        pub const EdgeSegmentIdRunSummary = index_meta_format.EdgeSegmentIdRunSummary;
        pub const NodePropertyIndexHeader = property_format.NodePropertyIndexHeader;
        pub const NodePropertyIndexRecord = property_format.NodePropertyIndexRecord;
        pub const PropertyPayloadIndexHeader = property_format.PropertyPayloadIndexHeader;
        pub const PropertyPayloadRedoJournalHeader = property_format.PropertyPayloadRedoJournalHeader;
        pub const PropertyPayloadIndexRecord = property_format.PropertyPayloadIndexRecord;
        pub const PropertyPayloadDeltaHeader = property_format.PropertyPayloadDeltaHeader;
        pub const PropertyBlockView = property_block_codec.View;
        pub const NodePropertyValueBlockHeader = property_format.NodePropertyValueBlockHeader;
        pub const NodePropertyValueRecord = property_format.NodePropertyValueRecord;

        pub const property_payload_delta_magic = property_format.property_payload_delta_magic;
        pub const property_payload_delta_version = property_format.property_payload_delta_version;
        pub const property_payload_delta_header_len = property_format.property_payload_delta_header_len;
        pub const property_payload_delta_entry_len = property_format.property_payload_delta_entry_len;
        pub const property_payload_delta_digest_seed = property_format.property_payload_delta_digest_seed;
        pub const property_payload_delta_max_frame_bytes = property_format.property_payload_delta_max_frame_bytes;
        pub const property_snapshot_legacy_version = property_format.property_snapshot_legacy_version;
        pub const property_snapshot_base_version = property_format.property_snapshot_base_version;
        pub const property_snapshot_delta_version_base = property_format.property_snapshot_delta_version_base;

        pub const ProcessId = u64;

        pub const NodeExternalKeyLookupEntry = struct {
            id: core.NodeId,
            kind: core.NodeKind,
        };

        pub fn currentProcessIdForTempPath() ProcessId {
            return process_liveness.currentId();
        }

        pub const StorageManifestProcessLeaseOps = struct {
            pub const Lease = ManifestProcessLease;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn leaseDirPath(store: Store, allocator_arg: std.mem.Allocator) ![]u8 {
                return store_plane.manifestProcessLeaseDirPath(store, allocator_arg);
            }

            pub fn currentManifestPath(
                store: Store,
                allocator_arg: std.mem.Allocator,
                kind: anytype,
            ) !?[]u8 {
                return store_plane.currentManifestPathForProcessLease(store, allocator_arg, kind);
            }

            pub fn tempPath(store: Store, path: []const u8) ![]u8 {
                return store_plane.tmpPathFor(store, path);
            }

            pub fn renameReplace(store: Store, tmp_path: []const u8, final_path: []const u8) !void {
                return store_plane.renameReplace(store, tmp_path, final_path);
            }

            pub fn currentProcessId(store: Store) ProcessId {
                _ = store;
                return currentProcessIdForTempPath();
            }

            pub fn processIdIsAlive(store: Store, pid: ProcessId) bool {
                _ = store;
                return process_liveness.isAlive(pid);
            }

            pub fn makeLease(store: Store, path: []u8) Lease {
                return .{ .allocator = store.allocator, .io = store.io, .path = path };
            }
        };

        pub const manifest_process_lease = manifest_process_lease_mod.ManifestProcessLeaseManager(StorageManifestProcessLeaseOps);
        pub const ManifestProcessLeaseKind = manifest_process_lease.Kind;

        pub const StorageEdgeSegmentGcOps = struct {
            pub const Manifest = EdgeSegmentManifest;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn storeDirPath(store: Store) []const u8 {
                return store.dir_path;
            }

            pub fn manifestPath(store: Store) []const u8 {
                return store.edge_segment_manifest_path;
            }

            pub fn currentManifestPath(store: Store, allocator_arg: std.mem.Allocator) !?[]u8 {
                return store_plane.readEdgeSegmentCurrentPath(store, allocator_arg);
            }

            pub fn readManifest(store: Store, path: []const u8) !StorageEdgeSegmentGcOps.Manifest {
                return store_plane.readEdgeSegmentManifestFile(store, store.allocator, path);
            }

            pub fn validateManifest(store: Store, path: []const u8, manifest: *const StorageEdgeSegmentGcOps.Manifest) !void {
                return store_plane.validateEdgeSegmentManifestPath(store, store.allocator, path, manifest.entries.items);
            }

            pub fn markLiveSegmentPaths(
                store: Store,
                manifest: *const StorageEdgeSegmentGcOps.Manifest,
                live_paths: *std.StringHashMap(void),
            ) !void {
                _ = store;
                return addEdgeSegmentManifestLivePaths(live_paths, manifest.entries.items);
            }

            pub fn deinitManifest(store: Store, manifest: *StorageEdgeSegmentGcOps.Manifest) void {
                manifest.deinit(store.allocator);
            }
        };

        pub const edge_segment_gc = edge_segment_gc_mod.EdgeSegmentGc(StorageEdgeSegmentGcOps);

        pub const StorageNodeTextRunGcOps = struct {
            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn storeDirPath(store: Store) []const u8 {
                return store.dir_path;
            }

            pub fn manifestPath(store: Store) []const u8 {
                return store.node_text_run_manifest_path;
            }

            pub fn currentManifestPath(store: Store, allocator_arg: std.mem.Allocator) !?[]u8 {
                return store_plane.readNodeTextRunCurrentPath(store, allocator_arg);
            }

            pub fn markManifestLiveRunPaths(
                store: Store,
                path: []const u8,
                live_paths: *std.StringHashMap([]u8),
            ) !void {
                return store_plane.addNodeTextRunManifestLivePaths(store, path, live_paths);
            }
        };

        pub const node_text_run_gc = node_text_run_gc_mod.NodeTextRunGc(StorageNodeTextRunGcOps);
        pub const PersistentRepairSessionOps = struct {
            pub fn monotonicNs(store: Store) u128 {
                return storageMonotonicNs(store.io);
            }

            pub fn elapsedNs(store: Store, start: u128) u128 {
                return storageElapsedNs(store.io, start);
            }

            pub fn recoverCommittedNodeTextJournal(store: Store) !bool {
                return (try store_plane.recoverNodeTextsAppendJournal(store)) == .committed;
            }

            pub fn truncateIncompleteBatchTail(store: Store) !void {
                _ = try store_plane.truncateIncompleteBatchTail(store);
            }

            pub fn rebuildPersistentIndexes(store: Store, reuse_node_texts: bool, timings: anytype) !void {
                try store_plane.rebuildPersistentIndexesFromLogStreamingReuseTexts(store, reuse_node_texts, timings);
            }

            pub fn dropRedundantEdgeOverlay(store: Store) void {
                _ = store_plane.dropRedundantEdgeSegmentOverlayAfterBaseIndexCatchup(store) catch {};
            }

            pub fn cleanupCommittedNodeTextJournal(store: Store) void {
                store_plane.cleanupCommittedNodeTextsAppendJournal(store);
            }
        };

        pub const repair_session = repair_session_mod.RepairSession(PersistentRepairSessionOps);
        pub const EdgeSegmentPublicationOps = struct {
            pub fn prepareEpoch(store: Store, entries: anytype) ![]u8 {
                if (entries.len == 0 or entries.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                const total_edges = try store_plane.edgeSegmentManifestTotalEdges(entries);
                const epoch_digest = try store_plane.edgeSegmentManifestDigest(store, entries);
                return store_plane.edgeSegmentManifestEpochPath(store, total_edges, epoch_digest);
            }

            pub fn releaseEpochPath(store: Store, epoch_path: []u8) void {
                store.allocator.free(epoch_path);
            }

            pub fn writeEpoch(store: Store, epoch_path: []const u8, entries: anytype) !void {
                try store_plane.writeEdgeSegmentManifestFile(store, epoch_path, entries);
            }

            pub fn commitCurrent(store: Store, epoch_path: []const u8) !void {
                try store_plane.writeEdgeSegmentCurrent(store, epoch_path);
            }
        };

        pub const edge_segment_publication = edge_segment_publication_mod.EdgeSegmentPublication(EdgeSegmentPublicationOps);

        pub fn edgeSegmentIdRunSummariesEqual(lhs: EdgeSegmentIdRunSummary, rhs: EdgeSegmentIdRunSummary) bool {
            return lhs.run_count == rhs.run_count and
                lhs.first_min == rhs.first_min and
                lhs.first_max == rhs.first_max and
                lhs.second_min == rhs.second_min and
                lhs.second_max == rhs.second_max;
        }

        pub const RepairIdBitSet = persistent_rebuild_pipeline_mod.ReplayState.IdBitSet;
        pub const RepairEdgeDigestIndex = persistent_rebuild_pipeline_mod.ReplayState.EdgeDigestIndex;
        pub const repair_dense_edge_digest_max_id = persistent_rebuild_pipeline_mod.ReplayState.dense_edge_digest_max_id;

        pub const EventCountState = struct {
            allocator: std.mem.Allocator,
            stats: StoreStats = .{},
            node_ids: RepairIdBitSet = .{},
            edge_digests: RepairEdgeDigestIndex,
            edge_records_seen: usize = 0,

            pub fn init(allocator: std.mem.Allocator) EventCountState {
                return .{
                    .allocator = allocator,
                    .edge_digests = RepairEdgeDigestIndex.init(allocator),
                };
            }

            pub fn deinit(self: *EventCountState) void {
                self.edge_digests.deinit(self.allocator);
                self.node_ids.deinit(self.allocator);
            }

            pub fn addNode(self: *EventCountState, id: u64, digest: u64) !void {
                if (try self.node_ids.put(self.allocator, id)) return error.InvalidRecord;
                self.stats.nodes = std.math.add(usize, self.stats.nodes, 1) catch return error.InvalidRecord;
                self.stats.node_digest ^= digest;
            }

            pub fn addEdge(self: *EventCountState, id: u64, src: u64, rel: u16, dst: u64) !void {
                if (id == 0 or src == 0 or dst == 0) return error.InvalidRecord;
                if (id == std.math.maxInt(u64) or src == std.math.maxInt(u64) or dst == std.math.maxInt(u64)) return error.InvalidRecord;
                if (relKindFromInt(rel) == null) return error.InvalidRecord;
                if (!try self.node_ids.contains(src) or !try self.node_ids.contains(dst)) return error.InvalidRecord;
                const record = EdgeIndexRecord{ .src = src, .dst = dst, .edge_id = id, .rel = rel };
                const digest = edgeRecordDigest(record);
                if (try self.edge_digests.put(self.allocator, id, digest, self.edge_records_seen)) return error.InvalidRecord;
                self.edge_records_seen = std.math.add(usize, self.edge_records_seen, 1) catch return error.InvalidRecord;
                self.stats.edges = std.math.add(usize, self.stats.edges, 1) catch return error.InvalidRecord;
                self.stats.edge_digest ^= digest;
            }

            pub fn deleteEdge(self: *EventCountState, id: u64) !void {
                if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                const digest = try self.edge_digests.delete(self.allocator, id) orelse return error.InvalidRecord;
                if (self.stats.edges == 0) return error.InvalidRecord;
                self.stats.edges -= 1;
                self.stats.edge_digest ^= digest;
            }
        };

        pub const storage_write_buffer_bytes: usize = 256 * 1024;
        pub const edge_batch_node_cache_slots: usize = 4096;
        pub const edge_segment_current_max_path_bytes: u64 = 64 * 1024;
        pub const implicit_edge_delta_segment_min_base_edges: u64 = 1024;
        pub const production_sort_chunk_records: usize = 128 * 1024;
        pub const test_sort_chunk_records: usize = 1024;
        pub const repair_sort_chunk_records: usize = if (builtin.is_test) test_sort_chunk_records else production_sort_chunk_records;
        pub const edge_repair_sort_chunk_records: usize = repair_sort_chunk_records;
        pub const edge_index_repair_key_run_memory_cap: usize = 1024 * 1024;
        pub const repair_spool_mmap_max_bytes: u64 = 64 * 1024 * 1024;
        pub const node_text_repair_sort_chunk_records: usize = repair_sort_chunk_records;
        pub const tombstone_repair_sort_chunk_records: usize = repair_sort_chunk_records;
        pub const edge_segment_id_sort_chunk_records: usize = repair_sort_chunk_records;
        pub const production_node_text_delta_max_records: u64 = 4096;
        pub const test_node_text_delta_max_records: u64 = 256;
        pub const node_text_delta_max_records: u64 = if (builtin.is_test) test_node_text_delta_max_records else production_node_text_delta_max_records;
        // Batch single out-of-order appends before publishing an L0 run, so appends
        // avoid one-run-per-node manifest churn without rewriting a large delta.
        pub const node_text_single_append_delta_flush_records: u64 = 64;
        // GB100 appends 182M nodes in 65,536-node chunks, which is about 2778 L0
        // node-text runs. Keep the append manifest above that so bulk ingest stays
        // append-only and leaves large run consolidation to explicit maintenance.
        pub const production_node_text_run_manifest_max_entries = node_text_run_manifest_format.production_max_entries;
        pub const test_node_text_run_manifest_max_entries = node_text_run_manifest_format.test_max_entries;
        pub const node_text_run_manifest_max_entries = node_text_run_manifest_format.max_entries;
        pub const node_text_run_max_records = node_text_run_manifest_format.max_records;
        pub const node_text_run_current_max_path_bytes = node_text_run_manifest_format.max_path_bytes;
        pub const node_text_run_hash_filter_min_records = node_text_run_manifest_format.hash_filter_min_records;
        pub const node_text_run_hash_filter_min_bytes = node_text_run_manifest_format.hash_filter_min_bytes;
        pub const node_text_run_hash_filter_max_bytes = node_text_run_manifest_format.hash_filter_max_bytes;
        // Run filters are lookup hints stored in the manifest. Writers pick a
        // record-count-derived power-of-two length; readers accept any valid length so
        // a non-canonical filter can only increase false positives, not hide records.
        pub const node_text_base_hash_filter_min_records: u64 = 32;
        pub const node_text_base_hash_filter_min_bytes: usize = 4 * 1024;
        pub const node_text_base_hash_filter_max_bytes: usize = 32 * 1024 * 1024;
        pub const node_text_base_hash_filter_target_bytes_per_record: u64 = 1;
        pub const segment_bundle_exact_sort_chunk_records: usize = 8192;
        pub const node_index_seen_dense_max_id: u64 = 64 * 1024 * 1024;
        pub const node_index_seen_dense_min_id: u64 = 64 * 1024;
        pub const node_index_seen_dense_ratio: u64 = 16;
        pub const active_node_set_dense_max_id: u64 = 64 * 1024 * 1024;
        pub const active_node_set_dense_min_id: u64 = 64 * 1024;
        pub const active_node_set_dense_ratio: u64 = 16;
        pub const graph_edge_id_set_dense_max_id: u64 = 512 * 1024 * 1024;
        pub const graph_edge_id_set_dense_min_id: u64 = 4096;
        pub const graph_edge_id_set_dense_ratio: u64 = 2;

        pub const NodeIndexSeenIds = union(enum) {
            dense: Dense,
            sparse: std.AutoHashMap(u64, void),

            const Dense = struct {
                bits: std.DynamicBitSetUnmanaged,
                seen: u64 = 0,
            };

            pub fn init(allocator: std.mem.Allocator, max_node_id: u64, expected_nodes: u64) !NodeIndexSeenIds {
                if (try shouldUseDense(max_node_id, expected_nodes)) {
                    const bit_count = std.math.cast(usize, max_node_id) orelse return error.RecordTooLarge;
                    return .{ .dense = .{
                        .bits = try std.DynamicBitSetUnmanaged.initEmpty(allocator, bit_count),
                    } };
                }

                var sparse = std.AutoHashMap(u64, void).init(allocator);
                errdefer sparse.deinit();
                try sparse.ensureTotalCapacity(@intCast(expected_nodes));
                return .{ .sparse = sparse };
            }

            pub fn deinit(self: *NodeIndexSeenIds, allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .dense => |*dense| dense.bits.deinit(allocator),
                    .sparse => |*sparse| sparse.deinit(),
                }
            }

            pub fn put(self: *NodeIndexSeenIds, id: u64) !bool {
                if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                switch (self.*) {
                    .dense => |*dense| {
                        const index = std.math.cast(usize, id - 1) orelse return error.RecordTooLarge;
                        if (index >= dense.bits.capacity()) return error.InvalidRecord;
                        const found = dense.bits.isSet(index);
                        if (!found) {
                            dense.bits.set(index);
                            dense.seen = std.math.add(u64, dense.seen, 1) catch return error.InvalidRecord;
                        }
                        return found;
                    },
                    .sparse => |*sparse| return (try sparse.getOrPut(id)).found_existing,
                }
            }

            pub fn count(self: NodeIndexSeenIds) u64 {
                return switch (self) {
                    .dense => |dense| dense.seen,
                    .sparse => |sparse| sparse.count(),
                };
            }

            pub fn shouldUseDense(max_node_id: u64, expected_nodes: u64) !bool {
                if (expected_nodes == 0 or max_node_id == 0 or max_node_id > node_index_seen_dense_max_id) return false;
                const scaled = std.math.mul(u64, expected_nodes, node_index_seen_dense_ratio) catch node_index_seen_dense_max_id;
                return max_node_id <= @max(node_index_seen_dense_min_id, scaled);
            }
        };

        pub const NodeTextValidationHash = struct {
            text_hash: u64,
            node_digest: u64,
        };

        pub const NodeTextValidationHashes = union(enum) {
            dense: Dense,
            sparse: std.AutoHashMap(u64, NodeTextValidationHash),

            const Dense = struct {
                values: []NodeTextValidationHash,
                present: std.DynamicBitSetUnmanaged,
            };

            pub fn init(allocator: std.mem.Allocator, max_node_id: u64, expected_nodes: u64) !NodeTextValidationHashes {
                if (try NodeIndexSeenIds.shouldUseDense(max_node_id, expected_nodes)) {
                    const count = std.math.cast(usize, max_node_id) orelse return error.RecordTooLarge;
                    const values = try allocator.alloc(NodeTextValidationHash, count);
                    errdefer allocator.free(values);
                    return .{ .dense = .{
                        .values = values,
                        .present = try std.DynamicBitSetUnmanaged.initEmpty(allocator, count),
                    } };
                }

                var sparse = std.AutoHashMap(u64, NodeTextValidationHash).init(allocator);
                errdefer sparse.deinit();
                try sparse.ensureTotalCapacity(@intCast(expected_nodes));
                return .{ .sparse = sparse };
            }

            pub fn deinit(self: *NodeTextValidationHashes, allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .dense => |*dense| {
                        dense.present.deinit(allocator);
                        allocator.free(dense.values);
                    },
                    .sparse => |*sparse| sparse.deinit(),
                }
            }

            pub fn estimatedBytes(self: *const NodeTextValidationHashes) u64 {
                return switch (self.*) {
                    .dense => |*dense| blk: {
                        const values_bytes: u64 = @intCast(dense.values.len * @sizeOf(NodeTextValidationHash));
                        const bit_bytes: u64 = @intCast((dense.present.capacity() + 7) / 8);
                        break :blk values_bytes + bit_bytes;
                    },
                    .sparse => |*sparse| @as(u64, @intCast(sparse.capacity())) * (@sizeOf(u64) + @sizeOf(NodeTextValidationHash)),
                };
            }

            pub fn put(self: *NodeTextValidationHashes, id: u64, value: NodeTextValidationHash) !void {
                if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                switch (self.*) {
                    .dense => |*dense| {
                        const index = std.math.cast(usize, id - 1) orelse return error.RecordTooLarge;
                        if (index >= dense.values.len) return error.InvalidRecord;
                        dense.values[index] = value;
                        dense.present.set(index);
                    },
                    .sparse => |*sparse| try sparse.put(id, value),
                }
            }

            pub fn get(self: *const NodeTextValidationHashes, id: u64) !NodeTextValidationHash {
                if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                return switch (self.*) {
                    .dense => |*dense| blk: {
                        const index = std.math.cast(usize, id - 1) orelse return error.RecordTooLarge;
                        if (index >= dense.values.len or !dense.present.isSet(index)) return error.InvalidRecord;
                        break :blk dense.values[index];
                    },
                    .sparse => |*sparse| sparse.get(id) orelse error.InvalidRecord,
                };
            }
        };

        pub const RepairEdgeReplayTracker = struct {
            allocator: std.mem.Allocator,
            ids: RepairIdBitSet = .{},
            digests: ?RepairEdgeDigestIndex = null,

            pub fn init(allocator: std.mem.Allocator) RepairEdgeReplayTracker {
                return .{ .allocator = allocator };
            }

            pub fn deinit(self: *RepairEdgeReplayTracker) void {
                if (self.digests) |*digests| digests.deinit(self.allocator);
                self.ids.deinit(self.allocator);
            }

            pub fn put(self: *RepairEdgeReplayTracker, edge_id: u64, digest: u64, record_count_so_far: usize) !bool {
                if (self.digests) |*digests| {
                    return digests.put(self.allocator, edge_id, digest, record_count_so_far);
                }
                return self.ids.put(self.allocator, edge_id);
            }

            pub fn delete(
                self: *RepairEdgeReplayTracker,
                store: Store,
                edge_file: std.Io.File,
                edge_writer: *StorageBufferedWriter,
                edge_id: u64,
                record_count: usize,
            ) !?u64 {
                try self.ensureDigestIndex(store, edge_file, edge_writer, record_count);
                if (self.digests) |*digests| return digests.delete(self.allocator, edge_id);
                return error.InvalidRecord;
            }

            pub fn ensureDigestIndex(
                self: *RepairEdgeReplayTracker,
                store: Store,
                edge_file: std.Io.File,
                edge_writer: *StorageBufferedWriter,
                record_count: usize,
            ) !void {
                if (self.digests != null) return;

                try edge_writer.flush();
                const expected_size = std.math.mul(u64, @intCast(record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                if (try edge_writer.position() != expected_size) return error.InvalidRecord;
                if (try store_plane.regularFileSize(store, edge_file) != expected_size) return error.InvalidRecord;

                var digests = RepairEdgeDigestIndex.init(self.allocator);
                errdefer digests.deinit(self.allocator);

                const chunk_records: usize = 8192;
                const chunk_bytes_len = std.math.mul(usize, chunk_records, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                const chunk_bytes = try self.allocator.alloc(u8, chunk_bytes_len);
                defer self.allocator.free(chunk_bytes);

                var read_pos: usize = 0;
                while (read_pos < record_count) {
                    const take = @min(chunk_records, record_count - read_pos);
                    const byte_count = std.math.mul(usize, take, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                    const offset = std.math.mul(u64, @intCast(read_pos), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                    const n = try edge_file.readPositionalAll(store.io, chunk_bytes[0..byte_count], offset);
                    if (n != byte_count) return error.InvalidRecord;

                    var cursor: usize = 0;
                    var index: usize = 0;
                    while (index < take) : (index += 1) {
                        const bytes = chunk_bytes[cursor .. cursor + EdgeIndexRecord.encoded_len];
                        const record = try EdgeIndexRecord.decodeSlice(bytes);
                        const record_ordinal = read_pos + index;
                        if (try digests.put(self.allocator, record.edge_id, edgeRecordDigest(record), record_ordinal)) return error.InvalidRecord;
                        cursor += EdgeIndexRecord.encoded_len;
                    }
                    read_pos += take;
                }

                self.ids.deinit(self.allocator);
                self.ids = .{};
                self.digests = digests;
            }
        };

        pub const StorageBufferedWriter = struct {
            io: std.Io,
            file: std.Io.File,
            allocator: std.mem.Allocator,
            buffer: []u8,
            len: usize = 0,
            offset: u64 = 0,

            pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !StorageBufferedWriter {
                std.debug.assert(capacity > 0);
                return .{
                    .io = io,
                    .file = file,
                    .allocator = allocator,
                    .buffer = try allocator.alloc(u8, capacity),
                };
            }

            pub fn initAtOffset(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize, offset: u64) !StorageBufferedWriter {
                var writer = try init(allocator, io, file, capacity);
                writer.offset = offset;
                return writer;
            }

            pub fn deinit(self: *StorageBufferedWriter) void {
                self.allocator.free(self.buffer);
            }

            pub fn append(self: *StorageBufferedWriter, bytes: []const u8) !void {
                if (bytes.len > self.buffer.len) {
                    try self.flush();
                    try self.file.writePositionalAll(self.io, bytes, self.offset);
                    self.offset = std.math.add(u64, self.offset, bytes.len) catch return error.InvalidRecord;
                    return;
                }
                if (self.len + bytes.len > self.buffer.len) try self.flush();
                @memcpy(self.buffer[self.len .. self.len + bytes.len], bytes);
                self.len += bytes.len;
            }

            pub fn flush(self: *StorageBufferedWriter) !void {
                if (self.len == 0) return;
                try self.file.writePositionalAll(self.io, self.buffer[0..self.len], self.offset);
                self.offset = std.math.add(u64, self.offset, self.len) catch return error.InvalidRecord;
                self.len = 0;
            }

            pub fn position(self: StorageBufferedWriter) !u64 {
                return std.math.add(u64, self.offset, self.len) catch return error.InvalidRecord;
            }
        };

        pub fn storageWriteBufferCapacity(file_size: u64) !usize {
            const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
            return @min(storage_write_buffer_bytes, size);
        }

        pub fn externalKeyIndexRecordLessThan(_: void, a: ExternalKeyIndexRecord, b: ExternalKeyIndexRecord) bool {
            if (a.hash != b.hash) return a.hash < b.hash;
            return a.node_id < b.node_id;
        }

        pub fn externalKeyHash(external_key: []const u8) u64 {
            return std.hash.Wyhash.hash(0x544B_4558, external_key);
        }

        pub fn externalKeyIndexFileSize(record_count: u64) !u64 {
            const records_bytes = std.math.mul(u64, record_count, ExternalKeyIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, ExternalKeyIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn externalKeyIndexRecordOffset(index: u64) !u64 {
            const records_bytes = std.math.mul(u64, index, ExternalKeyIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, ExternalKeyIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub const NodePropertyIndexEntry = struct {
            record: NodePropertyIndexRecord,
            value: ?[]u8 = null,

            pub fn deinit(self: *NodePropertyIndexEntry, allocator: std.mem.Allocator) void {
                if (self.value) |value| allocator.free(value);
                self.value = null;
            }
        };

        pub fn deinitNodePropertyIndexEntries(entries: []NodePropertyIndexEntry, allocator: std.mem.Allocator) void {
            for (entries) |*entry| entry.deinit(allocator);
        }

        pub const PropertyPayloadIndexEntry = struct {
            record: PropertyPayloadIndexRecord,
            value: ?[]u8 = null,

            pub fn deinit(self: *PropertyPayloadIndexEntry, allocator: std.mem.Allocator) void {
                if (self.value) |value| allocator.free(value);
                self.value = null;
            }
        };

        pub const PropertyPayloadDeltaScan = struct {
            valid_bytes: u64 = 0,
            last_sequence: u64 = 0,
            last_digest: u64 = 0,
            trailing_partial: bool = false,
        };

        pub const PropertyPayloadDeltaRecovery = enum {
            no_journal,
            committed,
        };

        pub fn deinitPropertyPayloadIndexEntries(entries: []PropertyPayloadIndexEntry, allocator: std.mem.Allocator) void {
            for (entries) |*entry| entry.deinit(allocator);
        }

        pub const NodePropertyPropsJson = struct {
            name: ?[]const u8 = null,
            status: ?[]const u8 = null,
            claimed_by: ?[]const u8 = null,
            schema_type: ?[]const u8 = null,
            external_key: ?[]const u8 = null,
            content_hash: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            retrieval_hints: ?[]const u8 = null,
            task_event_type: ?[]const u8 = null,
            dependency_relation: ?[]const u8 = null,
            task_recorded_ns: ?u64 = null,
            task_created_ns: ?u64 = null,
            task_completed_ns: ?u64 = null,
            claim_expires_ns: ?u64 = null,
            task_event_ns: ?u64 = null,
            task_root_id: ?u64 = null,
            task_id: ?u64 = null,
        };

        pub fn nodePropertyIndexRecordLessThan(_: void, a: NodePropertyIndexRecord, b: NodePropertyIndexRecord) bool {
            if (a.key_hash != b.key_hash) return a.key_hash < b.key_hash;
            if (a.value_type != b.value_type) return a.value_type < b.value_type;
            if (a.value_hash != b.value_hash) return a.value_hash < b.value_hash;
            return a.node_id < b.node_id;
        }

        pub fn nodePropertyIndexEntryLessThan(_: void, a: NodePropertyIndexEntry, b: NodePropertyIndexEntry) bool {
            return nodePropertyIndexRecordLessThan({}, a.record, b.record);
        }

        pub fn edgeExternalKeyIndexRecordLessThan(_: void, a: EdgeExternalKeyIndexRecord, b: EdgeExternalKeyIndexRecord) bool {
            if (a.hash != b.hash) return a.hash < b.hash;
            return a.edge_id < b.edge_id;
        }

        pub fn nodePropertyKeyHash(key: []const u8) u64 {
            return std.hash.Wyhash.hash(0x544B_504B, key);
        }

        pub fn nodePropertyValueHash(value: []const u8) u64 {
            return std.hash.Wyhash.hash(0x544B_5056, value);
        }

        pub fn edgeExternalKeyHash(external_key: []const u8) u64 {
            return std.hash.Wyhash.hash(0x544B_454B, external_key);
        }

        pub fn nodePropertyIndexFileSize(record_count: u64) !u64 {
            const records_bytes = std.math.mul(u64, record_count, NodePropertyIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, NodePropertyIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn nodePropertyIndexRecordOffset(index: u64) !u64 {
            const records_bytes = std.math.mul(u64, index, NodePropertyIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, NodePropertyIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn nodePropertyValueBlockHeaderAndRecordBytes(record_count: u64) !u64 {
            const records_bytes = std.math.mul(u64, record_count, NodePropertyValueRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, NodePropertyValueBlockHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn nodePropertyValueBlockFileSize(record_count: u64, payload_bytes: u64) !u64 {
            const prefix = try nodePropertyValueBlockHeaderAndRecordBytes(record_count);
            return std.math.add(u64, prefix, payload_bytes) catch error.RecordTooLarge;
        }

        pub fn nodePropertyValueRecordOffset(index: u64) !u64 {
            const records_bytes = std.math.mul(u64, index, NodePropertyValueRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, NodePropertyValueBlockHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn propertyPayloadIndexFileSize(record_count: u64) !u64 {
            const records_bytes = std.math.mul(u64, record_count, PropertyPayloadIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, PropertyPayloadIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn propertyPayloadIndexRecordOffset(index: u64) !u64 {
            const records_bytes = std.math.mul(u64, index, PropertyPayloadIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, PropertyPayloadIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn edgeExternalKeyIndexFileSize(record_count: u64) !u64 {
            const records_bytes = std.math.mul(u64, record_count, EdgeExternalKeyIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, EdgeExternalKeyIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn edgeExternalKeyIndexRecordOffset(index: u64) !u64 {
            const records_bytes = std.math.mul(u64, index, EdgeExternalKeyIndexRecord.encoded_len) catch return error.RecordTooLarge;
            return std.math.add(u64, EdgeExternalKeyIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
        }

        pub fn nodePropertyStringKeySupported(key: []const u8) bool {
            return propertyKeyNameValid(key) and !std.mem.eql(u8, key, "text");
        }

        pub fn nodePropertyUintKeySupported(key: []const u8) bool {
            return propertyKeyNameValid(key) and !std.mem.eql(u8, key, "text");
        }

        pub fn nodePropertyKeySupported(key: []const u8) bool {
            return nodePropertyStringKeySupported(key) or nodePropertyUintKeySupported(key);
        }

        pub fn nodePropertyOverlayStringKeySupported(key: []const u8) bool {
            return nodePropertyStringKeySupported(key);
        }

        pub fn edgePropertyOverlayStringKeySupported(key: []const u8) bool {
            return propertyKeyNameValid(key);
        }

        pub fn nodePropertyPayloadUintKeySupported(key: []const u8) bool {
            return nodePropertyUintKeySupported(key);
        }

        pub fn edgePropertyPayloadUintKeySupported(key: []const u8) bool {
            return propertyKeyNameValid(key);
        }

        pub fn propertyKeyNameValid(key: []const u8) bool {
            if (key.len == 0 or key.len > 128) return false;
            for (key) |byte| {
                const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == ':' or byte == '.';
                if (!ok) return false;
            }
            return true;
        }

        pub fn stringPropertyKeySupportedForOwner(owner: PropertyOwner, key: []const u8) bool {
            return switch (owner) {
                .node => nodePropertyOverlayStringKeySupported(key),
                .edge => edgePropertyOverlayStringKeySupported(key),
            };
        }

        pub fn uintPropertyKeySupportedForOwner(owner: PropertyOwner, key: []const u8) bool {
            return switch (owner) {
                .node => nodePropertyPayloadUintKeySupported(key),
                .edge => edgePropertyPayloadUintKeySupported(key),
            };
        }

        pub fn propertyPayloadOwnerKind(owner: PropertyOwner) u8 {
            return switch (owner) {
                .node => PropertyPayloadIndexRecord.owner_kind_node,
                .edge => PropertyPayloadIndexRecord.owner_kind_edge,
            };
        }

        pub fn propertyPayloadOwnerId(owner: PropertyOwner) u64 {
            return switch (owner) {
                .node => |node_id| node_id.toInt(),
                .edge => |edge_id| edge_id.toInt(),
            };
        }

        pub fn propertyPayloadOwnerFromParts(owner_kind: u8, owner_id: u64) !PropertyOwner {
            return switch (owner_kind) {
                PropertyPayloadIndexRecord.owner_kind_node => .{ .node = core.NodeId.fromInt(owner_id) },
                PropertyPayloadIndexRecord.owner_kind_edge => .{ .edge = core.EdgeId.fromInt(owner_id) },
                else => error.InvalidRecord,
            };
        }

        pub fn propertyPayloadRecordLessThan(_: void, a: PropertyPayloadIndexRecord, b: PropertyPayloadIndexRecord) bool {
            if (a.key_hash != b.key_hash) return a.key_hash < b.key_hash;
            if (a.owner_kind != b.owner_kind) return a.owner_kind < b.owner_kind;
            if (a.owner_id != b.owner_id) return a.owner_id < b.owner_id;
            if (a.value_type != b.value_type) return a.value_type < b.value_type;
            return a.value_hash < b.value_hash;
        }

        pub fn propertyPayloadEntryLessThan(_: void, a: PropertyPayloadIndexEntry, b: PropertyPayloadIndexEntry) bool {
            return propertyPayloadRecordLessThan({}, a.record, b.record);
        }

        pub fn propertyPayloadEntryMatchesOwnerKey(entry: PropertyPayloadIndexEntry, owner: PropertyOwner, key: []const u8) bool {
            return entry.record.owner_kind == propertyPayloadOwnerKind(owner) and
                entry.record.owner_id == propertyPayloadOwnerId(owner) and
                entry.record.key_hash == nodePropertyKeyHash(key);
        }

        pub const PropertyPayloadOwnerKey = struct {
            owner_kind: u8,
            owner_id: u64,
            key_hash: u64,
        };

        pub const PropertyPayloadOwnerKeySet = std.AutoHashMap(PropertyPayloadOwnerKey, void);
        pub const PropertyPayloadNodeIdSet = std.AutoHashMap(u64, void);

        pub const PropertyPayloadOwnerFilter = struct {
            owner_kind: u8,
            owner_ids: ?*const PropertyPayloadNodeIdSet = null,

            pub fn matches(self: PropertyPayloadOwnerFilter, owner_kind: u8, owner_id: u64) bool {
                if (owner_kind != self.owner_kind) return false;
                return if (self.owner_ids) |ids| ids.contains(owner_id) else true;
            }
        };

        pub const PropertyPayloadExistingKeyTarget = struct {
            wanted: *const PropertyPayloadOwnerKeySet,
            found: *PropertyPayloadOwnerKeySet,
        };

        pub const PropertyPayloadLookupTarget = struct {
            owner_key: PropertyPayloadOwnerKey,
            key_name: []const u8,
            value: ?PropertyPayloadIndexEntry = null,

            pub fn deinit(self: *PropertyPayloadLookupTarget, allocator: std.mem.Allocator) void {
                if (self.value) |*value| value.deinit(allocator);
                self.value = null;
            }
        };

        pub const PropertyPayloadKeyTarget = struct {
            key_hash: u64,
            key_name: []const u8,
            entries: *std.ArrayList(PropertyPayloadIndexEntry),
            positions: *std.AutoHashMap(PropertyPayloadOwnerKey, usize),
            owner_filter: ?PropertyPayloadOwnerFilter = null,
        };

        pub const SearchablePropertyByteBudget = struct {
            max_bytes: u64,
            used_bytes: u64 = 0,

            pub fn afterReplace(self: SearchablePropertyByteBudget, old_len: usize, new_len: usize) !u64 {
                const old_bytes: u64 = @intCast(old_len);
                const new_bytes: u64 = @intCast(new_len);
                if (old_bytes > self.used_bytes) return error.InvalidRecord;
                const without_old = self.used_bytes - old_bytes;
                const next = std.math.add(u64, without_old, new_bytes) catch return error.SearchableMetadataBudgetExceeded;
                if (next > self.max_bytes) return error.SearchableMetadataBudgetExceeded;
                return next;
            }
        };

        pub const PropertyPayloadIndexedTarget = struct {
            entries: *std.ArrayList(PropertyPayloadIndexEntry),
            positions: *std.AutoHashMap(PropertyPayloadOwnerKey, usize),
            searchable_byte_budget: ?*SearchablePropertyByteBudget = null,
        };

        pub const PropertyPayloadKeyNameMap = std.AutoHashMap(u64, []const u8);

        pub const PropertyPayloadSnapshotTarget = struct {
            key_names: *const PropertyPayloadKeyNameMap,
            entries: *std.ArrayList(PropertySnapshotEntry),
            positions: *std.AutoHashMap(PropertyPayloadOwnerKey, usize),
            owner_filter: PropertyPayloadOwnerFilter,
        };

        pub const PropertyPayloadLayerScanTarget = struct {
            context: *anyopaque,
            visit: PropertySnapshotLayerVisitor,
            next_version: *u64,
        };

        pub const PropertyPayloadDeltaTarget = union(enum) {
            none,
            all: PropertyPayloadIndexedTarget,
            searchable: PropertyPayloadIndexedTarget,
            key: PropertyPayloadKeyTarget,
            snapshot: PropertyPayloadSnapshotTarget,
            existing_keys: PropertyPayloadExistingKeyTarget,
            lookup: *PropertyPayloadLookupTarget,
            layer_scan: PropertyPayloadLayerScanTarget,
        };

        pub fn propertyPayloadOwnerKey(owner: PropertyOwner, key: []const u8) PropertyPayloadOwnerKey {
            return .{
                .owner_kind = propertyPayloadOwnerKind(owner),
                .owner_id = propertyPayloadOwnerId(owner),
                .key_hash = nodePropertyKeyHash(key),
            };
        }

        pub fn appendStringPropertyPayloadRecord(entries: *std.ArrayList(PropertyPayloadIndexEntry), allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8, value: []const u8) !void {
            if (value.len == 0) return;
            const owned = try allocator.dupe(u8, value);
            errdefer allocator.free(owned);
            try entries.append(allocator, .{
                .record = .{
                    .key_hash = nodePropertyKeyHash(key),
                    .value_hash = nodePropertyValueHash(value),
                    .owner_id = propertyPayloadOwnerId(owner),
                    .owner_kind = propertyPayloadOwnerKind(owner),
                    .value_type = PropertyPayloadIndexRecord.value_type_string,
                },
                .value = owned,
            });
        }

        pub fn appendUintPropertyPayloadRecord(entries: *std.ArrayList(PropertyPayloadIndexEntry), allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8, value: u64) !void {
            try entries.append(allocator, .{
                .record = .{
                    .key_hash = nodePropertyKeyHash(key),
                    .value_hash = value,
                    .owner_id = propertyPayloadOwnerId(owner),
                    .owner_kind = propertyPayloadOwnerKind(owner),
                    .value_type = PropertyPayloadIndexRecord.value_type_uint,
                },
            });
        }

        pub fn appendNodePropertyRecordForValue(entries: *std.ArrayList(NodePropertyIndexEntry), allocator: std.mem.Allocator, node_id: core.NodeId, key: []const u8, value: ?[]const u8) !void {
            const concrete = value orelse return;
            if (concrete.len == 0) return;
            const owned = try allocator.dupe(u8, concrete);
            errdefer allocator.free(owned);
            try entries.append(allocator, .{
                .record = .{
                    .key_hash = nodePropertyKeyHash(key),
                    .value_hash = nodePropertyValueHash(concrete),
                    .node_id = node_id.toInt(),
                    .value_type = NodePropertyIndexRecord.value_type_string,
                },
                .value = owned,
            });
        }

        pub fn appendEdgePropertyRecordForValue(entries: *std.ArrayList(NodePropertyIndexEntry), allocator: std.mem.Allocator, edge_id: core.EdgeId, key: []const u8, value: []const u8) !void {
            if (value.len == 0) return;
            const owned = try allocator.dupe(u8, value);
            errdefer allocator.free(owned);
            try entries.append(allocator, .{
                .record = .{
                    .key_hash = nodePropertyKeyHash(key),
                    .value_hash = nodePropertyValueHash(value),
                    .node_id = edge_id.toInt(),
                    .value_type = NodePropertyIndexRecord.value_type_string,
                },
                .value = owned,
            });
        }

        pub fn appendNodePropertyRecordForUint(entries: *std.ArrayList(NodePropertyIndexEntry), allocator: std.mem.Allocator, node_id: core.NodeId, key: []const u8, value: ?u64) !void {
            const concrete = value orelse return;
            try entries.append(allocator, .{
                .record = .{
                    .key_hash = nodePropertyKeyHash(key),
                    .value_hash = concrete,
                    .node_id = node_id.toInt(),
                    .value_type = NodePropertyIndexRecord.value_type_uint,
                },
            });
        }

        pub fn appendNodePropertyRecordsFromText(entries: *std.ArrayList(NodePropertyIndexEntry), allocator: std.mem.Allocator, node_id: core.NodeId, text: []const u8) !void {
            _ = entries;
            _ = allocator;
            _ = node_id;
            _ = text;
        }

        pub fn nodePropertyValueFromTextAlloc(allocator: std.mem.Allocator, text: []const u8, key: []const u8) !?[]u8 {
            _ = allocator;
            _ = text;
            _ = key;
            return null;
        }

        pub fn nodePropertyUintValueFromText(allocator: std.mem.Allocator, text: []const u8, key: []const u8) ?u64 {
            _ = allocator;
            _ = text;
            _ = key;
            return null;
        }

        pub const NodeTextRunManifestEntry = node_text_run_manifest_format.Entry;
        pub const OwnedNodeTextRunManifestEntry = node_text_run_manifest_format.OwnedEntry;
        pub const NodeTextRunManifest = node_text_run_manifest_format.Manifest;

        pub const NodeTextRunManifestCache = struct {
            path: []u8 = &.{},
            manifest: NodeTextRunManifest = .{},
            event_bytes: u64 = 0,
            valid: bool = false,

            pub fn clear(self: *NodeTextRunManifestCache, allocator: std.mem.Allocator) void {
                if (self.valid) self.manifest.deinit(allocator);
                allocator.free(self.path);
                self.* = .{};
            }
        };

        /// TODO(cache key):失效钥匙是 events.bin 字节数,而整店重写(记录对齐填充)可以
        /// 保字节数不变——rewriteNodeStore 已在换目录后手动 clear() 补这个洞,但病根是
        /// "文件大小 ≠ store 身份"。新增任何保字节数的突变路径前,先把 key 换成
        /// generation counter(rewrite 时 bump),否则同坑再踩。
        pub const IndexMetaCache = struct {
            meta: IndexMeta = .{},
            valid: bool = false,

            pub fn clear(self: *IndexMetaCache) void {
                self.* = .{};
            }
        };

        pub const NodeTextDeltaHeaderCache = struct {
            header: NodeTextIndexHeader = .{ .node_count = 0 },
            valid: bool = false,

            pub fn clear(self: *NodeTextDeltaHeaderCache) void {
                self.* = .{};
            }
        };

        pub const NodeTextBaseHashFilter = struct {
            header: NodeTextIndexHeader,
            filter: []u8 = &.{},

            pub fn deinit(self: *NodeTextBaseHashFilter, allocator: std.mem.Allocator) void {
                allocator.free(self.filter);
                self.* = .{ .header = .{ .node_count = 0 } };
            }
        };

        pub const NodeTextBaseHashFilterCache = struct {
            valid: bool = false,
            known_absent: bool = false,
            filter: NodeTextBaseHashFilter = .{ .header = .{ .node_count = 0 } },

            pub fn clear(self: *NodeTextBaseHashFilterCache, allocator: std.mem.Allocator) void {
                if (self.valid) self.filter.deinit(allocator);
                self.* = .{};
            }
        };

        pub const NodeTextBaseHashFilterHeader = struct {
            node_text_header: NodeTextIndexHeader,
            filter_len: u64,
            filter_digest: u64,

            const magic = [_]u8{ 'T', 'K', 'N', 'B' };
            const version: u16 = 1;
            pub const encoded_len: usize = 56;

            pub fn encode(self: NodeTextBaseHashFilterHeader, out: *[encoded_len]u8) !void {
                if (!nodeTextBaseHashFilterLenValid(self.filter_len)) return error.InvalidRecord;
                try self.node_text_header.validateShape();
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.filter_len, .little);
                std.mem.writeInt(u64, out[16..24], self.filter_digest, .little);
                std.mem.writeInt(u64, out[24..32], self.node_text_header.node_count, .little);
                std.mem.writeInt(u64, out[32..40], self.node_text_header.node_digest, .little);
                std.mem.writeInt(u64, out[40..48], self.node_text_header.order_digest, .little);
                std.mem.writeInt(u16, out[48..50], self.node_text_header.flags, .little);
                std.mem.writeInt(u16, out[50..52], self.node_text_header.record_len, .little);
                std.mem.writeInt(u16, out[52..54], self.node_text_header.uniform_kind, .little);
                std.mem.writeInt(u16, out[54..56], 0, .little);
            }

            pub fn decode(bytes: *const [encoded_len]u8) !NodeTextBaseHashFilterHeader {
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[54..56], .little) != 0) return error.InvalidRecord;
                const header = NodeTextBaseHashFilterHeader{
                    .filter_len = std.mem.readInt(u64, bytes[8..16], .little),
                    .filter_digest = std.mem.readInt(u64, bytes[16..24], .little),
                    .node_text_header = .{
                        .node_count = std.mem.readInt(u64, bytes[24..32], .little),
                        .node_digest = std.mem.readInt(u64, bytes[32..40], .little),
                        .order_digest = std.mem.readInt(u64, bytes[40..48], .little),
                        .flags = std.mem.readInt(u16, bytes[48..50], .little),
                        .record_len = std.mem.readInt(u16, bytes[50..52], .little),
                        .uniform_kind = std.mem.readInt(u16, bytes[52..54], .little),
                    },
                };
                try header.node_text_header.validateShape();
                if (!nodeTextBaseHashFilterLenValid(header.filter_len)) return error.InvalidRecord;
                return header;
            }
        };

        pub const TextSpan = struct {
            offset: u64,
            len: u32,
        };

        pub const StoreBootstrapNodeCatalogs = struct {
            missing_meta: bool,
            missing_node_by_id: bool,
            missing_node_texts: bool,
            missing_node_by_text: bool,
            missing_node_by_text_delta: bool,
            missing_external_key_index: bool,
            missing_node_props_index: bool,
            missing_node_props_values: bool,
            missing_edge_external_key_index: bool,
        };

        pub const StoreBootstrapEdgeCatalogs = struct {
            missing_id: bool,
            missing_src: bool,
            missing_dst: bool,
            missing_order: bool,
            missing_tombstones: bool,
        };

        pub const StoreBootstrapOps = struct {
            pub fn eventLogExists(store: Store) !bool {
                return store_plane.fileExists(store, store.events_bin_path);
            }

            pub fn anyDerivedGraphCatalogPathExists(store: Store) !bool {
                return store_plane.anyDerivedGraphCatalogPathExists(store);
            }

            pub fn createEventLog(store: Store) !void {
                try std.Io.Dir.cwd().writeFile(store.io, .{
                    .sub_path = store.events_bin_path,
                    .data = "",
                    .flags = .{ .truncate = false },
                });
            }

            pub fn validateIndexesOnRead(store: Store) bool {
                return store.options.validate_indexes_on_read;
            }

            pub fn fastPersistentIndexesCurrent(store: Store) !bool {
                return store_plane.fastPersistentIndexesCurrent(store);
            }

            pub fn stats(store: Store) !StoreStats {
                return store_plane.stats(store);
            }

            pub fn inspectNodeCatalogs(store: Store) !StoreBootstrapNodeCatalogs {
                return .{
                    .missing_meta = !try store_plane.fileExists(store, store.index_meta_path),
                    .missing_node_by_id = !try store_plane.fileExists(store, store.node_by_id_path),
                    .missing_node_texts = !try store_plane.fileExists(store, store.node_texts_path),
                    .missing_node_by_text = !try store_plane.fileExists(store, store.node_by_text_path),
                    .missing_node_by_text_delta = !try store_plane.fileExists(store, store.node_by_text_delta_path),
                    .missing_external_key_index = !try store_plane.fileExists(store, store.external_key_index_path),
                    .missing_node_props_index = !try store_plane.fileExists(store, store.node_props_index_path),
                    .missing_node_props_values = !try store_plane.fileExists(store, store.node_props_values_path),
                    .missing_edge_external_key_index = !try store_plane.fileExists(store, store.edge_external_key_index_path),
                };
            }

            pub fn writeEmptyNodeIndexes(store: Store) !void {
                try store_plane.writeEmptyNodeIndexes(store);
            }

            pub fn writeEmptyNodeTexts(store: Store) !void {
                try std.Io.Dir.cwd().writeFile(store.io, .{
                    .sub_path = store.node_texts_path,
                    .data = "",
                    .flags = .{ .truncate = false },
                });
            }

            pub fn writeEmptyNodeTextIndex(store: Store) !void {
                try store_plane.writeNodeTextIndex(store, &.{});
            }

            pub fn writeEmptyNodeTextDelta(store: Store) !void {
                try store_plane.writeEmptyNodeTextDelta(store);
            }

            pub fn writeEmptyExternalKeyIndex(store: Store) !void {
                try store_plane.writeExternalKeyIndex(store, &.{}, .{});
            }

            pub fn writeEmptyNodePropertyIndex(store: Store) !void {
                try store_plane.writeNodePropertyIndex(store, &.{}, .{});
            }

            pub fn writeEmptyEdgeExternalKeyIndex(store: Store) !void {
                try store_plane.writeEdgeExternalKeyIndex(store, &.{}, .{});
            }

            pub fn repairPersistentIndexes(store: Store) !void {
                try store_plane.repairPersistentIndexesFromLog(store);
            }

            pub fn inspectEdgeCatalogs(store: Store) !StoreBootstrapEdgeCatalogs {
                return .{
                    .missing_id = !try store_plane.fileExists(store, store.edge_by_id_path),
                    .missing_src = !try store_plane.fileExists(store, store.edge_by_src_path),
                    .missing_dst = !try store_plane.fileExists(store, store.edge_by_dst_path),
                    .missing_order = !try store_plane.fileExists(store, store.edge_order_path),
                    .missing_tombstones = !try store_plane.fileExists(store, store.edge_tombstones_path),
                };
            }

            pub fn writeEmptyEdgeIdIndex(store: Store) !void {
                try store_plane.writeEdgeIndex(store, store.edge_by_id_path, &.{});
            }

            pub fn writeEmptyEdgeSrcIndex(store: Store) !void {
                try store_plane.writeEdgeIndex(store, store.edge_by_src_path, &.{});
            }

            pub fn writeEmptyEdgeDstIndex(store: Store) !void {
                try store_plane.writeEdgeIndex(store, store.edge_by_dst_path, &.{});
            }

            pub fn writeEmptyEdgeOrderIndex(store: Store) !void {
                try store_plane.writeEdgeOrderIndex(store, &.{});
            }

            pub fn writeEmptyEdgeTombstoneIndex(store: Store) !void {
                try store_plane.writeEdgeTombstoneIndex(store, &.{});
            }

            pub fn writeIndexMetaFromStats(store: Store, stats_out: StoreStats) !void {
                try store_plane.writeIndexMetaFromStats(store, stats_out);
            }

            pub fn persistentIndexesCurrent(store: Store, stats_out: StoreStats) !bool {
                return store_plane.persistentIndexesCurrent(store, stats_out);
            }

            pub fn catalogExists(store: Store) !bool {
                return store_plane.fileExists(store, store.catalog_path);
            }

            pub fn writeKernelCatalog(store: Store) !void {
                try store_plane.writeKernelCatalog(store);
            }
        };

        pub const store_bootstrap = store_bootstrap_mod.StoreBootstrap(StoreBootstrapOps);

        pub const PersistentRebuildTextMaterial = struct {
            offset: u64,
            hash: u64,
            digest: u64,
        };

        pub const PersistentRebuildDirectNodeLayout =
            persistent_rebuild_pipeline_mod.ReplayState.DirectNodeLayout(core.NodeKind);

        pub const PersistentRebuildWorkspace = struct {
            events_file: std.Io.File,
            texts_tmp_path: ?[]u8,
            by_id_tmp_path: []u8,
            edge_repair_path: []u8,
            node_text_repair_path: []u8,
            tombstone_repair_path: []u8,
            file_size: u64,
            stats_out: StoreStats = .{},
            max_node_id: u64 = 0,
            max_edge_id_seen: u64 = 0,
            node_count: u64 = 0,
            node_digest: u64 = 0,
            first_node_kind: ?core.NodeKind = null,
            mixed_node_kind: bool = false,
            node_text_record_count: usize = 0,
            edge_record_count: usize = 0,
            tombstone_count: usize = 0,
            tombstone_digest: u64 = 0,
            direct_by_id: PersistentRebuildDirectNodeLayout = .{},

            pub fn deinit(self: *PersistentRebuildWorkspace, store: Store) void {
                self.direct_by_id.deinit(store.allocator);
                std.Io.Dir.cwd().deleteFile(store.io, self.tombstone_repair_path) catch {};
                store.allocator.free(self.tombstone_repair_path);
                std.Io.Dir.cwd().deleteFile(store.io, self.node_text_repair_path) catch {};
                store.allocator.free(self.node_text_repair_path);
                std.Io.Dir.cwd().deleteFile(store.io, self.edge_repair_path) catch {};
                store.allocator.free(self.edge_repair_path);
                std.Io.Dir.cwd().deleteFile(store.io, self.by_id_tmp_path) catch {};
                store.allocator.free(self.by_id_tmp_path);
                if (self.texts_tmp_path) |path| {
                    std.Io.Dir.cwd().deleteFile(store.io, path) catch {};
                    store.allocator.free(path);
                }
                self.events_file.close(store.io);
            }
        };

        pub fn repairReusedNodeTextOffset(
            reuse_cursor: *u64,
            source_texts_size: u64,
            parsed_offset: u64,
            parsed_len: u32,
        ) !u64 {
            const end = std.math.add(u64, parsed_offset, parsed_len) catch return error.CannotReuseNodeTexts;
            if (end > source_texts_size) return error.CannotReuseNodeTexts;
            reuse_cursor.* = @max(reuse_cursor.*, end);
            return parsed_offset;
        }

        pub const AppendedNodeTail = struct {
            ids: std.ArrayList(u64),
            /// XOR of the canonical per-node digests of every tail node, so a
            /// caller can prove catalog_digest ^ tail_digest == current index
            /// digest before trusting an incremental merge. The structural
            /// by-text-order digest is deliberately not part of this proof:
            /// it hashes run-manifest layout, and incremental consumers read
            /// node texts through live store reads, not through that layout.
            node_digest_xor: u64 = 0,

            pub fn deinit(self: *AppendedNodeTail, allocator: std.mem.Allocator) void {
                self.ids.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Node ids appended to the event log after `from_event_bytes` (a
        /// record-group boundary such as the text catalog watermark), with
        /// their combined canonical digest. Cost is O(tail); more than
        /// `max_nodes` tail nodes fails with error.RecordTooLarge so callers
        /// can fall back to full staleness handling. Whole-store rewrites
        /// replace the event log, which invalidates any older watermark and
        /// therefore never reaches this walk.
        pub fn collectNodeTailAppendedSince(
            store: Store,
            allocator: std.mem.Allocator,
            from_event_bytes: u64,
            max_nodes: u64,
        ) !AppendedNodeTail {
            var tail = AppendedNodeTail{ .ids = std.ArrayList(u64).empty };
            errdefer tail.deinit(allocator);
            var texts = try NodeTextsView.open(store);
            defer texts.deinit();
            var file = try std.Io.Dir.cwd().openFile(store.io, store.events_bin_path, .{});
            defer file.close(store.io);
            const file_size = try store_plane.regularFileSize(store, file);
            if (from_event_bytes > file_size) return error.InvalidRecord;
            var offset: u64 = from_event_bytes;
            var in_batch = false;
            while (offset < file_size) {
                const parsed = (try store_plane.readBinaryRecordHeader(store, file, &offset)) orelse return error.InvalidRecord;
                try ensureBinaryPayloadFits(file_size, offset, parsed.payload_len);
                const payload_len = std.math.cast(usize, parsed.payload_len) orelse return error.RecordTooLarge;
                switch (parsed.kind) {
                    .batch_begin => {
                        if (in_batch or payload_len != 0) return error.InvalidRecord;
                        in_batch = true;
                    },
                    .batch_commit => {
                        if (!in_batch or payload_len != 0) return error.InvalidRecord;
                        in_batch = false;
                    },
                    .node, .node_batch => {
                        const payload = try allocator.alloc(u8, payload_len);
                        defer allocator.free(payload);
                        const read_len = try file.readPositionalAll(store.io, payload, offset);
                        if (read_len != payload.len) return error.InvalidRecord;
                        if (parsed.payload_checksum) |checksum| {
                            if (binaryPayloadChecksum(payload) != checksum) return error.InvalidRecord;
                        }
                        if (parsed.kind == .node) {
                            const node = try validateBinaryNodePayload(payload);
                            try appendTailNode(&tail, allocator, &texts, node, max_nodes);
                        } else {
                            if (!in_batch) return error.InvalidRecord;
                            const batch = try validateBinaryNodeBatchHeader(payload);
                            // Derived-offset compact batches carry only text
                            // lengths per row; per-node offsets accumulate
                            // from the batch's base text offset, so the walk
                            // keeps the running cursor the stateless
                            // validator cannot.
                            var derived_text_cursor: u64 = batch.base_text_offset;
                            var index: u32 = 0;
                            while (index < batch.count) : (index += 1) {
                                const node = if (batch.derived_text_offset)
                                    try derivedBatchTailNode(payload, batch, index, &derived_text_cursor)
                                else
                                    try validateBinaryNodeBatchNode(payload, batch, index);
                                try appendTailNode(&tail, allocator, &texts, node, max_nodes);
                            }
                        }
                    },
                    .edge, .edge_batch, .edge_delete => {},
                }
                offset = std.math.add(u64, offset, parsed.payload_len) catch return error.InvalidRecord;
            }
            if (in_batch) return error.InvalidRecord;
            return tail;
        }

        fn derivedBatchTailNode(
            payload: []const u8,
            batch: anytype,
            index: u32,
            derived_text_cursor: *u64,
        ) !ParsedBinaryNode {
            const row_offset = std.math.add(
                usize,
                batch.header_len,
                std.math.mul(usize, @intCast(index), batch.row_len) catch return error.InvalidRecord,
            ) catch return error.InvalidRecord;
            if (row_offset + batch.row_len > payload.len) return error.InvalidRecord;
            const row = payload[row_offset..][0..batch.row_len];
            const text_len: u32 = if (batch.short_text_len)
                std.mem.readInt(u16, row[0..2], .little)
            else
                std.mem.readInt(u32, row[0..4], .little);
            const text_offset = derived_text_cursor.*;
            derived_text_cursor.* = std.math.add(u64, text_offset, text_len) catch return error.InvalidRecord;
            const id = std.math.add(u64, batch.dense_base_id, index) catch return error.InvalidRecord;
            return .{
                .id = id,
                .kind = batch.uniform_kind orelse return error.InvalidRecord,
                .text_offset = text_offset,
                .text_len = text_len,
            };
        }

        fn appendTailNode(
            tail: *AppendedNodeTail,
            allocator: std.mem.Allocator,
            texts: *const NodeTextsView,
            node: ParsedBinaryNode,
            max_nodes: u64,
        ) !void {
            if (tail.ids.items.len >= max_nodes) return error.RecordTooLarge;
            const digests = try texts.hashAndDigestStoredNode(node.id, node.kind, node.text_offset, node.text_len);
            tail.node_digest_xor ^= digests.node_digest;
            try tail.ids.append(allocator, node.id);
        }

        pub fn repairNodeTextMaterial(
            store: Store,
            source_texts: *const NodeTextsView,
            texts_writer: ?*StorageBufferedWriter,
            reuse_node_texts: bool,
            reuse_cursor: *u64,
            parsed_node: ParsedBinaryNode,
        ) !PersistentRebuildTextMaterial {
            if (reuse_node_texts) {
                const text_offset = try repairReusedNodeTextOffset(
                    reuse_cursor,
                    source_texts.size,
                    parsed_node.text_offset,
                    parsed_node.text_len,
                );
                const digests = try source_texts.hashAndDigestStoredNode(
                    parsed_node.id,
                    parsed_node.kind,
                    parsed_node.text_offset,
                    parsed_node.text_len,
                );
                return .{
                    .offset = text_offset,
                    .hash = digests.text_hash,
                    .digest = digests.node_digest,
                };
            }

            const text = try source_texts.readTextAlloc(store.allocator, parsed_node.text_offset, parsed_node.text_len);
            defer store.allocator.free(text);
            const writer = texts_writer orelse return error.InvalidRecord;
            const text_offset = try writer.position();
            try writer.append(text);
            return .{
                .offset = text_offset,
                .hash = nodeTextHash(text),
                .digest = try nodeRecordDigestFromParts(parsed_node.id, parsed_node.kind, text),
            };
        }

        pub const PersistentRebuildPipelineOps = struct {
            pub const WorkspaceType = PersistentRebuildWorkspace;
            pub const NodeKindType = core.NodeKind;

            pub fn prepareWorkspace(store: Store, reuse_node_texts: bool) !PersistentRebuildWorkspace {
                var events_file = try std.Io.Dir.cwd().openFile(store.io, store.events_bin_path, .{});
                errdefer events_file.close(store.io);
                const file_size = try store_plane.regularFileSize(store, events_file);

                const texts_tmp_path: ?[]u8 = if (reuse_node_texts) null else try store_plane.tmpPathFor(store, store.node_texts_path);
                errdefer if (texts_tmp_path) |path| store.allocator.free(path);
                const by_id_tmp_path = try store_plane.tmpPathFor(store, store.node_by_id_path);
                errdefer store.allocator.free(by_id_tmp_path);
                const edge_repair_path = try std.fmt.allocPrint(store.allocator, "{s}.repair_edges.tmp", .{store.edge_by_id_path});
                errdefer store.allocator.free(edge_repair_path);
                const node_text_repair_path = try std.fmt.allocPrint(store.allocator, "{s}.repair_texts.tmp", .{store.node_by_text_path});
                errdefer store.allocator.free(node_text_repair_path);
                const tombstone_repair_path = try std.fmt.allocPrint(store.allocator, "{s}.repair_tombstones.tmp", .{store.edge_tombstones_path});
                errdefer store.allocator.free(tombstone_repair_path);

                return .{
                    .events_file = events_file,
                    .texts_tmp_path = texts_tmp_path,
                    .by_id_tmp_path = by_id_tmp_path,
                    .edge_repair_path = edge_repair_path,
                    .node_text_repair_path = node_text_repair_path,
                    .tombstone_repair_path = tombstone_repair_path,
                    .file_size = file_size,
                };
            }

            pub fn deinitWorkspace(store: Store, workspace: *PersistentRebuildWorkspace) void {
                workspace.deinit(store);
            }

            pub fn replayAndFinalizeArtifacts(
                store: Store,
                workspace: *PersistentRebuildWorkspace,
                reuse_node_texts: bool,
                timings: ?*PersistentRepairTimings,
            ) !void {
                const file = workspace.events_file;
                const file_size = workspace.file_size;
                const texts_tmp_path = workspace.texts_tmp_path;
                const by_id_tmp_path = workspace.by_id_tmp_path;
                const edge_repair_path = workspace.edge_repair_path;
                const node_text_repair_path = workspace.node_text_repair_path;
                const tombstone_repair_path = workspace.tombstone_repair_path;
                var source_texts: ?NodeTextsView = null;
                defer if (source_texts) |*view| view.deinit();

                var stats_out = StoreStats{};
                var max_node_id: u64 = 0;
                var max_edge_id_seen: u64 = 0;
                var node_count: u64 = 0;
                var node_digest: u64 = 0;
                var first_node_kind: ?core.NodeKind = null;
                var mixed_node_kind = false;
                var node_text_record_count: usize = 0;
                var edge_record_count: usize = 0;
                var tombstone_count: usize = 0;
                var tombstone_digest: u64 = 0;
                var direct_by_id = &workspace.direct_by_id;
                var node_texts_logical_size: u64 = 0;
                var node_by_id_short_text_lens = true;

                {
                    var node_ids = RepairIdBitSet{};
                    defer node_ids.deinit(store.allocator);
                    var edge_tracker = RepairEdgeReplayTracker.init(store.allocator);
                    defer edge_tracker.deinit();

                    var texts_file: ?std.Io.File = null;
                    defer if (texts_file) |open_file| open_file.close(store.io);
                    var texts_writer: ?StorageBufferedWriter = null;
                    defer if (texts_writer) |*writer| writer.deinit();
                    var reuse_texts_cursor: u64 = 0;
                    if (!reuse_node_texts) {
                        const path = texts_tmp_path orelse return error.InvalidRecord;
                        texts_file = try std.Io.Dir.cwd().createFile(store.io, path, .{
                            .read = true,
                            .truncate = true,
                        });
                        texts_writer = try StorageBufferedWriter.init(store.allocator, store.io, texts_file.?, storage_write_buffer_bytes);
                    }
                    var text_repair_file = try std.Io.Dir.cwd().createFile(store.io, node_text_repair_path, .{
                        .read = true,
                        .truncate = true,
                    });
                    defer text_repair_file.close(store.io);
                    var text_repair_writer = try StorageBufferedWriter.init(store.allocator, store.io, text_repair_file, storage_write_buffer_bytes);
                    defer text_repair_writer.deinit();
                    var index_file = try std.Io.Dir.cwd().createFile(store.io, by_id_tmp_path, .{
                        .read = true,
                        .truncate = true,
                    });
                    defer index_file.close(store.io);
                    try store_plane.writeNodeByIdHeader(store, index_file, .{ .max_node_id = 0, .node_count = 0 });
                    var edge_file = try std.Io.Dir.cwd().createFile(store.io, edge_repair_path, .{
                        .read = true,
                        .truncate = true,
                    });
                    defer edge_file.close(store.io);
                    var edge_writer = try StorageBufferedWriter.init(store.allocator, store.io, edge_file, storage_write_buffer_bytes);
                    defer edge_writer.deinit();
                    var tombstone_file = try std.Io.Dir.cwd().createFile(store.io, tombstone_repair_path, .{
                        .read = true,
                        .truncate = true,
                    });
                    defer tombstone_file.close(store.io);
                    var tombstone_writer = try StorageBufferedWriter.init(store.allocator, store.io, tombstone_file, storage_write_buffer_bytes);
                    defer tombstone_writer.deinit();

                    var offset: u64 = 0;
                    var in_batch = false;
                    const replay_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                    while (true) {
                        const parsed = try store_plane.readBinaryRecordHeader(store, file, &offset) orelse break;
                        try ensureBinaryPayloadFits(file_size, offset, parsed.payload_len);
                        const payload = try store.allocator.alloc(u8, parsed.payload_len);
                        defer store.allocator.free(payload);
                        const payload_len = try file.readPositionalAll(store.io, payload, offset);
                        if (payload_len != payload.len) return error.InvalidRecord;
                        try store_plane.advanceBinaryOffset(&offset, payload.len);
                        try validateBinaryChecksum(parsed, payload);

                        switch (parsed.kind) {
                            .batch_begin => {
                                if (in_batch) return error.InvalidRecord;
                                if (payload.len != 0) return error.InvalidRecord;
                                in_batch = true;
                            },
                            .batch_commit => {
                                if (!in_batch) return error.InvalidRecord;
                                if (payload.len != 0) return error.InvalidRecord;
                                in_batch = false;
                            },
                            .node => {
                                const parsed_node = try validateBinaryNodePayload(payload);
                                if (try node_ids.put(store.allocator, parsed_node.id)) return error.InvalidRecord;
                                const texts = try store_plane.ensureNodeTextsView(store, &source_texts);
                                const text_material = try repairNodeTextMaterial(
                                    store,
                                    texts,
                                    if (texts_writer) |*writer| writer else null,
                                    reuse_node_texts,
                                    &reuse_texts_cursor,
                                    parsed_node,
                                );
                                try direct_by_id.observe(store.allocator, parsed_node.id, parsed_node.kind, text_material.offset, parsed_node.text_len);

                                max_node_id = @max(max_node_id, parsed_node.id);
                                const node_record = NodeByIdRecord{
                                    .id = parsed_node.id,
                                    .kind = @intFromEnum(parsed_node.kind),
                                    .text_offset = text_material.offset,
                                    .text_len = parsed_node.text_len,
                                };
                                if (!nodeRecordHasShortTextLen(node_record)) node_by_id_short_text_lens = false;
                                var node_record_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
                                try node_record.encode(&node_record_bytes);
                                const record_offset = try nodeByIdRecordOffset(parsed_node.id);
                                try index_file.writePositionalAll(store.io, &node_record_bytes, record_offset);

                                const text_record = NodeTextIndexRecord{
                                    .hash = text_material.hash,
                                    .id = parsed_node.id,
                                    .kind = @intFromEnum(parsed_node.kind),
                                    .text_offset = text_material.offset,
                                    .text_len = parsed_node.text_len,
                                };
                                var text_record_bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
                                try text_record.encode(&text_record_bytes);
                                try text_repair_writer.append(&text_record_bytes);
                                node_text_record_count = std.math.add(usize, node_text_record_count, 1) catch return error.InvalidRecord;
                                node_count = std.math.add(u64, node_count, 1) catch return error.InvalidRecord;
                                if (first_node_kind) |kind| {
                                    if (kind != parsed_node.kind) mixed_node_kind = true;
                                } else {
                                    first_node_kind = parsed_node.kind;
                                }
                                stats_out.nodes = std.math.add(usize, stats_out.nodes, 1) catch return error.InvalidRecord;
                                node_digest ^= text_material.digest;
                                stats_out.node_digest ^= text_material.digest;
                            },
                            .node_batch => {
                                if (!in_batch) return error.InvalidRecord;
                                var batch_reader = try BinaryNodeBatchReader.init(payload);
                                while (try batch_reader.next()) |parsed_node| {
                                    if (try node_ids.put(store.allocator, parsed_node.id)) return error.InvalidRecord;
                                    {
                                        const texts = try store_plane.ensureNodeTextsView(store, &source_texts);
                                        const text_material = try repairNodeTextMaterial(
                                            store,
                                            texts,
                                            if (texts_writer) |*writer| writer else null,
                                            reuse_node_texts,
                                            &reuse_texts_cursor,
                                            parsed_node,
                                        );
                                        try direct_by_id.observe(store.allocator, parsed_node.id, parsed_node.kind, text_material.offset, parsed_node.text_len);

                                        max_node_id = @max(max_node_id, parsed_node.id);
                                        const node_record = NodeByIdRecord{
                                            .id = parsed_node.id,
                                            .kind = @intFromEnum(parsed_node.kind),
                                            .text_offset = text_material.offset,
                                            .text_len = parsed_node.text_len,
                                        };
                                        if (!nodeRecordHasShortTextLen(node_record)) node_by_id_short_text_lens = false;
                                        var node_record_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
                                        try node_record.encode(&node_record_bytes);
                                        const record_offset = try nodeByIdRecordOffset(parsed_node.id);
                                        try index_file.writePositionalAll(store.io, &node_record_bytes, record_offset);

                                        const text_record = NodeTextIndexRecord{
                                            .hash = text_material.hash,
                                            .id = parsed_node.id,
                                            .kind = @intFromEnum(parsed_node.kind),
                                            .text_offset = text_material.offset,
                                            .text_len = parsed_node.text_len,
                                        };
                                        var text_record_bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
                                        try text_record.encode(&text_record_bytes);
                                        try text_repair_writer.append(&text_record_bytes);
                                        node_text_record_count = std.math.add(usize, node_text_record_count, 1) catch return error.InvalidRecord;
                                        node_count = std.math.add(u64, node_count, 1) catch return error.InvalidRecord;
                                        if (first_node_kind) |kind| {
                                            if (kind != parsed_node.kind) mixed_node_kind = true;
                                        } else {
                                            first_node_kind = parsed_node.kind;
                                        }
                                        stats_out.nodes = std.math.add(usize, stats_out.nodes, 1) catch return error.InvalidRecord;
                                        node_digest ^= text_material.digest;
                                        stats_out.node_digest ^= text_material.digest;
                                    }
                                }
                            },
                            .edge => {
                                const parsed_edge = try validateBinaryEdgePayload(payload);
                                if (!try node_ids.contains(parsed_edge.src)) return error.InvalidRecord;
                                if (!try node_ids.contains(parsed_edge.dst)) return error.InvalidRecord;
                                const record = EdgeIndexRecord{
                                    .src = parsed_edge.src,
                                    .dst = parsed_edge.dst,
                                    .edge_id = parsed_edge.id,
                                    .rel = @intFromEnum(parsed_edge.rel),
                                };
                                const record_digest = edgeRecordDigest(record);
                                if (try edge_tracker.put(parsed_edge.id, record_digest, edge_record_count)) return error.InvalidRecord;
                                max_edge_id_seen = @max(max_edge_id_seen, parsed_edge.id);
                                var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
                                record.encode(&record_bytes);
                                try edge_writer.append(&record_bytes);
                                edge_record_count = std.math.add(usize, edge_record_count, 1) catch return error.InvalidRecord;
                                stats_out.edges = std.math.add(usize, stats_out.edges, 1) catch return error.InvalidRecord;
                                stats_out.edge_digest ^= record_digest;
                            },
                            .edge_batch => {
                                if (!in_batch) return error.InvalidRecord;
                                const batch = try validateBinaryEdgeBatchHeader(payload);
                                var index: u32 = 0;
                                while (index < batch.count) : (index += 1) {
                                    const parsed_edge = try validateBinaryEdgeBatchEdge(payload, batch, index);
                                    if (!try node_ids.contains(parsed_edge.src)) return error.InvalidRecord;
                                    if (!try node_ids.contains(parsed_edge.dst)) return error.InvalidRecord;
                                    const record = EdgeIndexRecord{
                                        .src = parsed_edge.src,
                                        .dst = parsed_edge.dst,
                                        .edge_id = parsed_edge.id,
                                        .rel = @intFromEnum(parsed_edge.rel),
                                    };
                                    const record_digest = edgeRecordDigest(record);
                                    if (try edge_tracker.put(parsed_edge.id, record_digest, edge_record_count)) return error.InvalidRecord;
                                    max_edge_id_seen = @max(max_edge_id_seen, parsed_edge.id);
                                    var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
                                    record.encode(&record_bytes);
                                    try edge_writer.append(&record_bytes);
                                    edge_record_count = std.math.add(usize, edge_record_count, 1) catch return error.InvalidRecord;
                                    stats_out.edges = std.math.add(usize, stats_out.edges, 1) catch return error.InvalidRecord;
                                    stats_out.edge_digest ^= record_digest;
                                }
                            },
                            .edge_delete => {
                                const edge_id = (try validateBinaryEdgeDeletePayload(payload)).toInt();
                                max_edge_id_seen = @max(max_edge_id_seen, edge_id);
                                const edge_digest = try edge_tracker.delete(store, edge_file, &edge_writer, edge_id, edge_record_count) orelse return error.InvalidRecord;
                                if (stats_out.edges == 0) return error.InvalidRecord;
                                stats_out.edges -= 1;
                                stats_out.edge_digest ^= edge_digest;
                                const tombstone_record = EdgeTombstoneRecord{
                                    .edge_id = edge_id,
                                    .edge_digest = edge_digest,
                                };
                                var tombstone_bytes: [EdgeTombstoneRecord.encoded_len]u8 = undefined;
                                tombstone_record.encode(&tombstone_bytes);
                                try tombstone_writer.append(&tombstone_bytes);
                                tombstone_count = std.math.add(usize, tombstone_count, 1) catch return error.InvalidRecord;
                                tombstone_digest ^= edge_digest;
                            },
                        }
                    }
                    if (in_batch) return error.InvalidRecord;
                    if (timings) |t| t.replay_events_ns += storageElapsedNs(store.io, replay_start);

                    const node_material_flush_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                    if (texts_writer) |*writer| {
                        const open_file = texts_file orelse return error.InvalidRecord;
                        try writer.flush();
                        if (try store_plane.regularFileSize(store, open_file) != try writer.position()) return error.InvalidRecord;
                        node_texts_logical_size = try writer.position();
                        if (selfOptionsNeedSync(store)) try open_file.sync(store.io);
                    } else {
                        if (node_count == 0) return error.CannotReuseNodeTexts;
                        const view = source_texts orelse return error.CannotReuseNodeTexts;
                        if (reuse_texts_cursor != view.size) return error.CannotReuseNodeTexts;
                        node_texts_logical_size = view.size;
                    }
                    try text_repair_writer.flush();
                    const expected_text_repair_size = std.math.mul(u64, @intCast(node_text_record_count), NodeTextIndexRecord.encoded_len) catch return error.InvalidRecord;
                    if (try text_repair_writer.position() != expected_text_repair_size) return error.InvalidRecord;
                    if (try store_plane.regularFileSize(store, text_repair_file) != expected_text_repair_size) return error.InvalidRecord;
                    if (selfOptionsNeedSync(store)) try text_repair_file.sync(store.io);
                    if (timings) |t| t.spool_flush_ns += storageElapsedNs(store.io, node_material_flush_start);

                    const node_by_id_finalize_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                    var by_id_header = NodeByIdHeader{
                        .max_node_id = max_node_id,
                        .node_count = node_count,
                        .node_digest = node_digest,
                    };
                    try index_file.setLength(store.io, try store_plane.nodeByIdFileSizeForHeaderStore(store, by_id_header));
                    try store_plane.writeNodeByIdHeader(store, index_file, by_id_header);
                    if (!mixed_node_kind) {
                        if (first_node_kind) |kind| {
                            if (direct_by_id.canRewrite(kind, node_count, max_node_id, node_texts_logical_size)) {
                                try store_plane.rewriteNodeByIdIndexToDerivedDenseLengths(store, index_file, &by_id_header, kind, direct_by_id.lengths.items);
                            } else {
                                try store_plane.rewriteNodeByIdIndexToUniformRecordsFromTextRepair(store, index_file, &by_id_header, kind, text_repair_file, node_count, node_by_id_short_text_lens);
                                try store_plane.compactNodeByIdIndexToDerivedTextOffsets(store, index_file, &by_id_header);
                            }
                        }
                    }
                    if (selfOptionsNeedSync(store)) try index_file.sync(store.io);
                    if (timings) |t| t.node_by_id_finalize_ns += storageElapsedNs(store.io, node_by_id_finalize_start);

                    const edge_spool_flush_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                    try edge_writer.flush();
                    const expected_edge_repair_size = std.math.mul(u64, @intCast(edge_record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                    if (try edge_writer.position() != expected_edge_repair_size) return error.InvalidRecord;
                    if (try store_plane.regularFileSize(store, edge_file) != expected_edge_repair_size) return error.InvalidRecord;
                    if (selfOptionsNeedSync(store)) try edge_file.sync(store.io);
                    try tombstone_writer.flush();
                    const expected_tombstone_repair_size = std.math.mul(u64, @intCast(tombstone_count), EdgeTombstoneRecord.encoded_len) catch return error.InvalidRecord;
                    if (try tombstone_writer.position() != expected_tombstone_repair_size) return error.InvalidRecord;
                    if (try store_plane.regularFileSize(store, tombstone_file) != expected_tombstone_repair_size) return error.InvalidRecord;
                    if (selfOptionsNeedSync(store)) try tombstone_file.sync(store.io);
                    if (timings) |t| {
                        t.spool_flush_ns += storageElapsedNs(store.io, edge_spool_flush_start);
                        t.nodes = node_count;
                        t.edges = @intCast(stats_out.edges);
                        t.node_text_records = @intCast(node_text_record_count);
                        t.edge_records = @intCast(edge_record_count);
                        t.tombstone_records = @intCast(tombstone_count);
                    }
                }

                workspace.stats_out = stats_out;
                workspace.max_node_id = max_node_id;
                workspace.max_edge_id_seen = max_edge_id_seen;
                workspace.node_count = node_count;
                workspace.node_digest = node_digest;
                workspace.first_node_kind = first_node_kind;
                workspace.mixed_node_kind = mixed_node_kind;
                workspace.node_text_record_count = node_text_record_count;
                workspace.edge_record_count = edge_record_count;
                workspace.tombstone_count = tombstone_count;
                workspace.tombstone_digest = tombstone_digest;
            }

            pub fn publishPrimary(
                store: Store,
                workspace: *PersistentRebuildWorkspace,
                timings: ?*PersistentRepairTimings,
            ) !void {
                const primary_rename_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                if (workspace.texts_tmp_path) |path| {
                    try store_plane.renameReplace(store, path, store.node_texts_path);
                }
                try store_plane.renameReplace(store, workspace.by_id_tmp_path, store.node_by_id_path);
                if (timings) |t| t.primary_rename_ns += storageElapsedNs(store.io, primary_rename_start);
            }

            pub fn finalizePrimaryText(
                store: Store,
                timings: ?*PersistentRepairTimings,
            ) !void {
                const compress_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                try store_plane.finalizePrimaryTextStorage(store);
                if (timings) |t| t.node_texts_compress_ns += storageElapsedNs(store.io, compress_start);
            }

            pub fn publishNodeText(
                store: Store,
                workspace: *PersistentRebuildWorkspace,
                timings: ?*PersistentRepairTimings,
            ) !void {
                const node_text_index_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                const node_text_publish_shape = NodeTextRepairPublishShape{
                    .uniform_kind = if (!workspace.mixed_node_kind) blk: {
                        const kind = workspace.first_node_kind orelse break :blk null;
                        break :blk @intFromEnum(kind);
                    } else null,
                    .u32_id = workspace.max_node_id <= std.math.maxInt(u32),
                    .derived_hash = false,
                    .derived_text_span = true,
                };
                try store_plane.writeNodeTextIndexFromRepairSpool(store, workspace.node_text_repair_path, workspace.node_text_record_count, workspace.stats_out.node_digest, node_text_publish_shape);
                try store_plane.writeEmptyNodeTextDelta(store);
                try store_plane.deleteNodeTextRunManifest(store);
                std.Io.Dir.cwd().deleteFile(store.io, workspace.node_text_repair_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| return e,
                };
                if (timings) |t| t.node_text_index_ns += storageElapsedNs(store.io, node_text_index_start);
            }

            pub fn publishEdges(
                store: Store,
                workspace: *PersistentRebuildWorkspace,
                timings: ?*PersistentRepairTimings,
            ) !void {
                const edge_index_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                try store_plane.writeEdgeIndexesFromRepairSpool(store, workspace.edge_repair_path, workspace.edge_record_count, timings);
                std.Io.Dir.cwd().deleteFile(store.io, workspace.edge_repair_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| return e,
                };
                if (timings) |t| t.edge_index_ns += storageElapsedNs(store.io, edge_index_start);
            }

            pub fn publishTombstones(
                store: Store,
                workspace: *PersistentRebuildWorkspace,
                timings: ?*PersistentRepairTimings,
            ) !void {
                const tombstone_index_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                try store_plane.writeEdgeTombstoneIndexFromRepairSpool(store, workspace.tombstone_repair_path, workspace.tombstone_count, workspace.tombstone_digest);
                std.Io.Dir.cwd().deleteFile(store.io, workspace.tombstone_repair_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| return e,
                };
                if (timings) |t| t.tombstone_index_ns += storageElapsedNs(store.io, tombstone_index_start);
            }

            pub fn publishMetadataAndDerived(
                store: Store,
                workspace: *PersistentRebuildWorkspace,
                timings: ?*PersistentRepairTimings,
            ) !void {
                const meta_write_start = if (timings != null) storageMonotonicNs(store.io) else 0;
                var meta = IndexMeta{
                    .event_bytes = workspace.file_size,
                    .nodes = @intCast(workspace.stats_out.nodes),
                    .edges = @intCast(workspace.stats_out.edges),
                    .node_digest = workspace.stats_out.node_digest,
                    .edge_digest = workspace.stats_out.edge_digest,
                    .edge_indexed_edges = @intCast(workspace.edge_record_count),
                    .edge_index_digest = workspace.stats_out.edge_digest ^ workspace.tombstone_digest,
                    .max_edge_id_seen = workspace.max_edge_id_seen,
                };
                try store_plane.copyNodeTextOrderDigestFromHeader(store, &meta);
                try store_plane.copyEdgeOrderDigestsFromHeaders(store, &meta);
                try store_plane.writeIndexMeta(store, meta);
                try store_plane.rebuildExternalKeyIndex(store);
                try store_plane.rebuildNodePropertyIndex(store);
                try store_plane.rebuildEdgeExternalKeyIndex(store);
                _ = store_plane.dropRedundantEdgeSegmentOverlayAfterBaseIndexCatchup(store) catch {};
                if (timings) |t| t.meta_write_ns += storageElapsedNs(store.io, meta_write_start);
            }
        };

        pub const persistent_rebuild_pipeline =
            persistent_rebuild_pipeline_mod.PersistentRebuildPipeline(PersistentRebuildPipelineOps);

        pub const NodeTextRepairIndexPublicationOps = struct {
            pub const StoreType = Store;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn sortChunkRecords() usize {
                return node_text_repair_sort_chunk_records;
            }

            pub fn finalPath(store: Store) []const u8 {
                return store.node_by_text_path;
            }

            pub fn shouldSync(store: Store) bool {
                return selfOptionsNeedSync(store);
            }

            pub fn validatePrimaryTextsReadable(store: Store) !void {
                var texts = try NodeTextsView.open(store);
                defer texts.deinit();
            }

            pub fn compactDerivedRecords(store: Store, file: std.Io.File, header: *NodeTextIndexHeader) !void {
                return store_plane.compactNodeTextIndexToDerivedRecords(store, file, header);
            }

            pub fn renameReplace(store: Store, tmp_path: []const u8, final_path: []const u8) !void {
                return store_plane.renameReplace(store, tmp_path, final_path);
            }

            pub fn openReadOnlyMemoryMap(store: Store, file: std.Io.File, size: u64) !std.Io.File.MemoryMap {
                return store_plane.openReadOnlyMemoryMap(store.io, file, size);
            }
        };

        pub const node_text_repair_index_publication =
            node_text_repair_index_publication_mod.NodeTextRepairIndexPublication(
                core,
                schema.max_node_types,
                NodeTextRepairIndexPublicationOps,
            );

        pub const storageEdgeIndexLessThan = edgeIndexLessThan;

        pub const EdgeRepairIndexPublicationOps = struct {
            pub const StoreType = Store;
            pub const TimingsType = PersistentRepairTimings;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn sortChunkRecords() usize {
                return edge_repair_sort_chunk_records;
            }

            pub fn spoolMmapMaxBytes() u64 {
                return repair_spool_mmap_max_bytes;
            }

            pub fn keyRunMemoryCap() usize {
                return edge_index_repair_key_run_memory_cap;
            }

            pub fn edgeByIdPath(store: Store) []const u8 {
                return store.edge_by_id_path;
            }

            pub fn edgeBySrcPath(store: Store) []const u8 {
                return store.edge_by_src_path;
            }

            pub fn edgeByDstPath(store: Store) []const u8 {
                return store.edge_by_dst_path;
            }

            pub fn shouldSync(store: Store) bool {
                return selfOptionsNeedSync(store);
            }

            pub fn monotonicNs(store: Store) u128 {
                return storageMonotonicNs(store.io);
            }

            pub fn elapsedNs(store: Store, start: u128) u128 {
                return storageElapsedNs(store.io, start);
            }

            pub fn renameReplace(store: Store, tmp_path: []const u8, final_path: []const u8) !void {
                return store_plane.renameReplace(store, tmp_path, final_path);
            }

            pub fn openReadOnlyMemoryMap(store: Store, file: std.Io.File, size: u64) !std.Io.File.MemoryMap {
                return store_plane.openReadOnlyMemoryMap(store.io, file, size);
            }

            pub fn edgeIndexLessThan(order: EdgeIndexOrder, lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
                return storageEdgeIndexLessThan(order, lhs, rhs);
            }

            pub fn sortRecords(order: EdgeIndexOrder, records: []EdgeIndexRecord) void {
                return sortEdgeIndexRecords(order, records);
            }

            pub fn recordHasU32NodeIds(record: EdgeIndexRecord) bool {
                return edgeRecordHasU32NodeIds(record);
            }

            pub fn recordKey(record: EdgeIndexRecord, order: EdgeIndexOrder) u64 {
                return edgeIndexRecordKey(record, order);
            }

            pub fn recordOpposite(record: EdgeIndexRecord, order: EdgeIndexOrder) ?u64 {
                return edgeIndexRecordOpposite(record, order);
            }

            pub fn maybeBetterDenseKeyRunSpan(current: ?EdgeIndexDenseKeyRunSpan, best_score: *u64, run_start: u64, first: EdgeIndexKeyRunRecord, count: u64, start_step: u64, edge_id_base_step: u64) ?EdgeIndexDenseKeyRunSpan {
                return edgeIndexMaybeBetterDenseKeyRunSpan(current, best_score, run_start, first, count, start_step, edge_id_base_step);
            }

            pub fn denseKeyRunSpanRecordForIndex(header: EdgeIndexHeader, run_index: u64) !EdgeIndexKeyRunRecord {
                return edgeIndexDenseKeyRunSpanRecordForIndex(header, run_index);
            }

            pub fn keyRunRecordsEquivalent(header: EdgeIndexHeader, expected: EdgeIndexKeyRunRecord, actual: EdgeIndexKeyRunRecord) bool {
                return edgeIndexKeyRunRecordsEquivalent(header, expected, actual);
            }

            pub fn validateAdjacentKeyRuns(header: EdgeIndexHeader, current: EdgeIndexKeyRunRecord, next: EdgeIndexKeyRunRecord) !void {
                return validateAdjacentEdgeIndexKeyRuns(header, current, next);
            }

            pub fn writeCompleteSortedIndex(store: Store, path: []const u8, records: []const EdgeIndexRecord) !void {
                return store_plane.writeEdgeIndex(store, path, records);
            }

            pub fn compactDerivedRecords(store: Store, file: std.Io.File, header: *EdgeIndexHeader) !void {
                return store_plane.compactEdgeIndexToDerivedRecords(store, file, header);
            }
        };

        pub const edge_repair_index_publication =
            edge_repair_index_publication_mod.EdgeRepairIndexPublication(
                core,
                schema.max_relation_types,
                EdgeRepairIndexPublicationOps,
            );

        pub const EdgeTombstoneRepairIndexPublicationOps = struct {
            pub const StoreType = Store;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn sortChunkRecords() usize {
                return tombstone_repair_sort_chunk_records;
            }

            pub fn finalPath(store: Store) []const u8 {
                return store.edge_tombstones_path;
            }

            pub fn edgeByIdPath(store: Store) []const u8 {
                return store.edge_by_id_path;
            }

            pub fn shouldSync(store: Store) bool {
                return selfOptionsNeedSync(store);
            }

            pub fn renameReplace(store: Store, tmp_path: []const u8, final_path: []const u8) !void {
                return store_plane.renameReplace(store, tmp_path, final_path);
            }

            pub fn openReadOnlyMemoryMap(store: Store, file: std.Io.File, size: u64) !std.Io.File.MemoryMap {
                return store_plane.openReadOnlyMemoryMap(store.io, file, size);
            }

            pub fn readEdgeIndexRecordAt(store: Store, file: std.Io.File, header: anytype, index: u64) !EdgeIndexRecord {
                return store_plane.readEdgeIndexRecordAt(store, file, header, index);
            }
        };

        pub const edge_tombstone_repair_index_publication =
            edge_tombstone_repair_index_publication_mod.EdgeTombstoneRepairIndexPublication(
                core,
                schema.max_relation_types,
                EdgeTombstoneRepairIndexPublicationOps,
            );

        pub const PropertyPayloadTransactionOps = struct {
            pub const StoreType = Store;
            pub const EntryType = PropertyPayloadIndexEntry;
            pub const WriteType = PropertyPayloadWrite;
            pub const SortedNextType = SortedPropertyPayloadNext;
            pub const DeltaScanType = PropertyPayloadDeltaScan;
            pub const DeltaRecoveryType = PropertyPayloadDeltaRecovery;
            pub const CompactionResultType = PropertyPayloadCompactionResult;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn indexPath(store: Store) []const u8 {
                return store.property_payload_index_path;
            }

            pub fn valuesPath(store: Store) []const u8 {
                return store.property_payload_values_path;
            }

            pub fn deltaPath(store: Store) []const u8 {
                return store.property_payload_delta_path;
            }

            pub fn shouldSync(store: Store) bool {
                return selfOptionsNeedSync(store);
            }

            pub fn tmpPath(store: Store, path: []const u8) ![]u8 {
                return store_plane.tmpPathFor(store, path);
            }

            pub fn renameReplace(store: Store, tmp_path: []const u8, final_path: []const u8) !void {
                return store_plane.renameReplace(store, tmp_path, final_path);
            }

            pub fn syncParentDir(store: Store, path: []const u8) !void {
                return store_plane.syncParentDirForPath(store, path);
            }

            pub fn fileExists(store: Store, path: []const u8) !bool {
                return store_plane.fileExists(store, path);
            }

            pub fn deleteDeltaFile(store: Store) !void {
                return std.Io.Dir.cwd().deleteFile(store.io, store.property_payload_delta_path);
            }

            pub const CompactionMergeType = store_plane.PropertyPayloadCompactionMerge;

            pub fn openCompactionMerge(store: Store, merge_allocator: std.mem.Allocator) !CompactionMergeType {
                return CompactionMergeType.init(store, merge_allocator);
            }

            pub fn closeCompactionMerge(_: Store, merge: *CompactionMergeType) void {
                merge.deinit();
            }

            pub fn compactionMergeExpectedCount(merge: *CompactionMergeType) u64 {
                return merge.expected_count;
            }

            pub fn compactionMergeContext(merge: *CompactionMergeType) *anyopaque {
                return @ptrCast(merge);
            }

            pub const compactionMergeRestart = CompactionMergeType.restart;
            pub const compactionMergeNext = CompactionMergeType.next;

            pub fn keyNameValid(key: []const u8) bool {
                return propertyKeyNameValid(key);
            }

            pub fn keyHash(key: []const u8) u64 {
                return nodePropertyKeyHash(key);
            }

            pub fn valueHash(value: []const u8) u64 {
                return nodePropertyValueHash(value);
            }

            pub fn ownerKind(owner: PropertyOwner) u8 {
                return propertyPayloadOwnerKind(owner);
            }

            pub fn ownerId(owner: PropertyOwner) u64 {
                return propertyPayloadOwnerId(owner);
            }

            pub fn validateDeltaFrame(store: Store, header: PropertyPayloadDeltaHeader, payload: []const u8) !void {
                return store_plane.parsePropertyPayloadDeltaPayload(store.allocator, header, payload, .none);
            }

            pub fn scanDelta(store: Store, allocator_arg: std.mem.Allocator, allow_partial_tail: bool) !PropertyPayloadDeltaScan {
                return store_plane.scanPropertyPayloadDelta(store, allocator_arg, .none, allow_partial_tail);
            }

            pub fn validateRestoredBasePair(store: Store, index_path: []const u8, values_path: []const u8) !void {
                var validated = try store_plane.readPropertyPayloadEntriesFromFiles(store, store.allocator, index_path, values_path);
                defer {
                    deinitPropertyPayloadIndexEntries(validated.items, store.allocator);
                    validated.deinit(store.allocator);
                }
            }

            pub fn readEntriesOrEmpty(store: Store, allocator_arg: std.mem.Allocator) !std.ArrayList(PropertyPayloadIndexEntry) {
                return store_plane.readPropertyPayloadEntriesOrEmpty(store, allocator_arg);
            }

            pub fn deinitEntries(allocator_arg: std.mem.Allocator, entries: *std.ArrayList(PropertyPayloadIndexEntry)) void {
                deinitPropertyPayloadIndexEntries(entries.items, allocator_arg);
                entries.deinit(allocator_arg);
            }
        };

        pub const property_payload_transaction = property_payload_transaction_mod.PropertyPayloadTransaction(PropertyPayloadTransactionOps);

        pub const StoragePrimaryNodeTextOps = struct {
            pub const StoreType = Store;
            pub const SpanType = TextSpan;
            pub const StoredNodeType = StoredNode;
            pub const NodeKindType = core.NodeKind;
            pub const ValidationHashType = NodeTextValidationHash;
            pub const CompressionResultType = NodeTextsCompressionResult;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn io(store: Store) std.Io {
                return store.io;
            }

            pub fn nodeTextsPath(store: Store) []const u8 {
                return store.node_texts_path;
            }

            pub fn crashRecoveryAllowed(store: Store) bool {
                return store.options.crash_recovery;
            }

            pub fn shouldSync(store: Store) bool {
                return selfOptionsNeedSync(store);
            }

            pub fn normalWriteMode(store: Store) bool {
                return store.options.primary_text_write_mode == .normal;
            }

            /// Event-log watermark captured into v5 append journals so
            /// bounded recovery scans only the interrupted suffix (12003).
            /// Unknown on read failure: classification then falls back to
            /// the full scan, never to a wrong bound.
            pub fn journalEventWatermark(store: Store) u64 {
                // maxInt is the shared "unknown" sentinel: classification
                // must fall back to the full scan, never a wrong bound.
                return store_plane.eventBytes(store) catch std.math.maxInt(u64);
            }

            /// Raw-residue ceiling for bulk loading: once the raw node-texts
            /// file crosses this window the loader seals it into compressed
            /// blocks instead of deferring one whole-corpus finalize. Bounds
            /// the store-dir peak at compressed-so-far + one window.
            pub fn rawFinalizeWindowBytes() u64 {
                if (std.c.getenv("TINYKG_TEXT_RAW_FINALIZE_WINDOW_BYTES")) |raw| {
                    const parsed = std.fmt.parseInt(u64, std.mem.span(raw), 10) catch 0;
                    if (parsed != 0) return parsed;
                }
                return 256 * 1024 * 1024;
            }

            pub fn renameReplace(store: Store, tmp_path: []const u8, final_path: []const u8) !void {
                return store_plane.renameReplace(store, tmp_path, final_path);
            }

            pub fn syncParentDir(store: Store, path: []const u8) !void {
                return store_plane.syncParentDirForPath(store, path);
            }

            pub fn repairPersistentIndexesFromLog(store: Store) !void {
                return store_plane.repairPersistentIndexesFromLog(store);
            }

            pub fn openMap(store: Store, file: std.Io.File, physical_size: u64) !std.Io.File.MemoryMap {
                return store_plane.openReadOnlyMemoryMap(store.io, file, physical_size);
            }

            pub fn nodeKind(record: anytype) !core.NodeKind {
                return record.nodeKind();
            }

            pub fn makeStoredNode(record: anytype, kind: core.NodeKind, text: []u8) !StoredNode {
                return .{
                    .id = core.NodeId.fromInt(record.id),
                    .kind = kind,
                    .text = text,
                };
            }
        };

        pub const primary_node_text = primary_node_text_mod.PrimaryNodeText(StoragePrimaryNodeTextOps);

        pub const StoreCacheResourcesOps = struct {
            pub const IndexMetaCacheType = IndexMetaCache;
            pub const NodeTextDeltaHeaderCacheType = NodeTextDeltaHeaderCache;
            pub const NodeTextDeltaRunCacheType = NodeTextDeltaRunCache;
            pub const NodeTextRunManifestCacheType = NodeTextRunManifestCache;
            pub const NodeTextBaseHashFilterCacheType = NodeTextBaseHashFilterCache;

            pub fn createIndexMetaCache(allocator: std.mem.Allocator) !*IndexMetaCacheType {
                const cache = try allocator.create(IndexMetaCacheType);
                cache.* = .{};
                return cache;
            }

            pub fn destroyIndexMetaCache(allocator: std.mem.Allocator, cache: *IndexMetaCacheType) void {
                cache.clear();
                allocator.destroy(cache);
            }

            pub fn createNodeTextDeltaHeaderCache(allocator: std.mem.Allocator) !*NodeTextDeltaHeaderCacheType {
                const cache = try allocator.create(NodeTextDeltaHeaderCacheType);
                cache.* = .{};
                return cache;
            }

            pub fn destroyNodeTextDeltaHeaderCache(allocator: std.mem.Allocator, cache: *NodeTextDeltaHeaderCacheType) void {
                cache.clear();
                allocator.destroy(cache);
            }

            pub fn createNodeTextDeltaRunCache(allocator: std.mem.Allocator) !*NodeTextDeltaRunCacheType {
                const cache = try allocator.create(NodeTextDeltaRunCacheType);
                cache.* = .{};
                return cache;
            }

            pub fn destroyNodeTextDeltaRunCache(allocator: std.mem.Allocator, cache: *NodeTextDeltaRunCacheType) void {
                cache.clear();
                allocator.destroy(cache);
            }

            pub fn createNodeTextRunManifestCache(allocator: std.mem.Allocator) !*NodeTextRunManifestCacheType {
                const cache = try allocator.create(NodeTextRunManifestCacheType);
                cache.* = .{};
                return cache;
            }

            pub fn destroyNodeTextRunManifestCache(allocator: std.mem.Allocator, cache: *NodeTextRunManifestCacheType) void {
                cache.clear(allocator);
                allocator.destroy(cache);
            }

            pub fn createNodeTextBaseHashFilterCache(allocator: std.mem.Allocator) !*NodeTextBaseHashFilterCacheType {
                const cache = try allocator.create(NodeTextBaseHashFilterCacheType);
                cache.* = .{};
                return cache;
            }

            pub fn destroyNodeTextBaseHashFilterCache(allocator: std.mem.Allocator, cache: *NodeTextBaseHashFilterCacheType) void {
                cache.clear(allocator);
                allocator.destroy(cache);
            }
        };

        pub const store_cache_resources = store_cache_resources_mod.StoreCacheResources(StoreCacheResourcesOps);

        pub const StoreOpeningRequest = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            options: StorageOptions,
        };

        pub const StoreOpeningOps = struct {
            pub const Request = StoreOpeningRequest;
            pub const StoreType = Store;

            pub fn crashRecoveryAllowed(request: Request) bool {
                return request.options.crash_recovery;
            }

            pub fn createDirectory(request: Request) !void {
                try std.Io.Dir.cwd().createDirPath(request.io, request.dir_path);
            }

            pub fn requireDirectory(request: Request) !void {
                var dir = try std.Io.Dir.cwd().openDir(request.io, request.dir_path, .{});
                dir.close(request.io);
            }

            pub fn allocateOwned(request: Request) !StoreType {
                return store_plane.allocateOwned(request.allocator, request.io, request.dir_path, request.options);
            }

            pub fn deinitStore(store: *StoreType) void {
                store_plane.deinit(store);
            }

            pub fn storeMarkerExists(store: StoreType) !bool {
                return store_plane.fileExists(store, store.events_bin_path);
            }

            pub fn ensureStoreMarkerExists(store: StoreType) !void {
                try store_plane.ensureStoreMarkerExists(store);
            }

            pub fn recoverNodeTextsAppendJournal(store: StoreType) !bool {
                return (try store_plane.recoverNodeTextsAppendJournal(store)) == .committed;
            }

            pub fn admitStoreFormat(store: StoreType) !bool {
                return store_opening_control.admitStoreFormat(store);
            }

            pub fn repairPersistentIndexesFromLog(store: StoreType) !void {
                // The append journal only makes the node_texts.dat mutation durable.
                // It commits before the event record and derived indexes, so a crash
                // can leave a durable text tail that no event references. Bounded
                // recovery classifies that interrupted write from the journal, the
                // index watermark and the event tail, and only falls back to the
                // full O(event-log) rebuild for states it cannot prove.
                try store_plane.reconcileCommittedNodeTextsAppend(store);
            }

            pub fn recoverPropertyPayloadRedoJournal(store: StoreType) !void {
                try property_payload_transaction.recoverBaseRedoJournal(store);
            }

            pub fn recoverPropertyPayloadDeltaJournal(store: StoreType) !void {
                _ = try property_payload_transaction.recoverDeltaJournal(store);
            }
        };

        pub const store_opening = store_opening_control.module.StoreOpening(StoreOpeningOps);

        pub const EdgeSegmentQueryOpeningOps = struct {
            pub const DirectionType = segment_mod.Direction;
            pub const NodeIdType = core.NodeId;
            pub const CoverageType = PublishedEdgeSegmentsCoverage;
            pub const ManifestType = EdgeSegmentManifest;
            pub const RegistryType = EdgeSegmentRetentionRegistry;
            pub const ResultType = PublishedEdgeSegmentsForQuery;

            pub fn readCurrentManifest(store: Store, allocator: std.mem.Allocator) !EdgeSegmentManifest {
                return store_plane.readEdgeSegmentManifest(store, allocator);
            }

            pub fn readManifestAtPath(store: Store, allocator: std.mem.Allocator, manifest_path: []const u8) !EdgeSegmentManifest {
                return store_plane.readEdgeSegmentManifestAtPath(store, allocator, manifest_path);
            }

            pub fn deinitManifest(_: Store, allocator: std.mem.Allocator, manifest: *EdgeSegmentManifest) void {
                manifest.deinit(allocator);
            }

            pub fn acquireRetentionWindow(store: Store, registry: *EdgeSegmentRetentionRegistry) !EdgeSegmentRegisteredRetentionWindow {
                return store_plane.openRegisteredEdgeSegmentRetentionWindow(store, registry);
            }

            pub fn retentionManifestPath(window: *const EdgeSegmentRegisteredRetentionWindow) ?[]const u8 {
                return window.manifest_path;
            }

            pub fn deinitRetentionWindow(window: *EdgeSegmentRegisteredRetentionWindow) void {
                window.deinit();
            }

            pub fn attachRetentionWindow(result: *PublishedEdgeSegmentsForQuery, window: EdgeSegmentRegisteredRetentionWindow) void {
                result.retention_window = window;
            }

            pub fn readCurrentMeta(store: Store) !IndexMeta {
                return store_plane.readCurrentIndexMeta(store);
            }

            pub fn manifestTotalEdges(manifest: *const EdgeSegmentManifest) u64 {
                return manifest.totalEdgeCount();
            }

            pub fn visiblePlusTombstoneEdges(store: Store, meta: IndexMeta) !u64 {
                return store_plane.visiblePlusTombstoneEdgeCount(store, meta);
            }

            pub fn manifestCoversVisibleEdges(store: Store, meta: IndexMeta, manifest_edges: u64) !bool {
                return store_plane.edgeSegmentManifestCoversVisibleEdges(store, meta, manifest_edges);
            }

            pub fn metaSummaryCurrent(store: Store, meta: IndexMeta) !bool {
                return store_plane.edgeSegmentMetaSummaryCurrent(store, meta);
            }

            pub fn indexedEdgeCount(meta: IndexMeta) u64 {
                return meta.edge_indexed_edges;
            }

            pub fn baseHeadersMatchMeta(store: Store, meta: IndexMeta) !bool {
                return store_plane.edgeIndexBaseHeadersMatchMeta(store, meta);
            }

            pub fn manifestRangesTrusted(manifest: *const EdgeSegmentManifest) bool {
                return manifest.ranges_trusted;
            }

            pub fn openSegments(
                store: Store,
                allocator: std.mem.Allocator,
                manifest: *const EdgeSegmentManifest,
                coverage: PublishedEdgeSegmentsCoverage,
                filter_direction: ?segment_mod.Direction,
                filter_node_id: ?core.NodeId,
                filtered: bool,
            ) !?PublishedEdgeSegmentsForQuery {
                return store_plane.openPublishedEdgeSegmentDataForQuery(
                    store,
                    allocator,
                    manifest,
                    coverage,
                    filter_direction,
                    filter_node_id,
                    filtered,
                );
            }
        };

        pub const edge_segment_query_opening = edge_segment_query_opening_mod.EdgeSegmentQueryOpening(EdgeSegmentQueryOpeningOps);

        pub const EdgeSegmentWindowCompactionOps = struct {
            pub const OwnedEntryType = OwnedEdgeSegmentManifestEntry;
            pub const EntryType = EdgeSegmentManifestEntry;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn pathExists(store: Store, path: []const u8) !bool {
                return store_plane.pathExists(store, path);
            }

            pub fn openSources(store: Store, entries: []const OwnedEdgeSegmentManifestEntry) !PublishedEdgeSegments {
                return PublishedEdgeSegments.openFromManifest(store.allocator, store.io, entries);
            }

            pub fn deinitSources(_: Store, sources: *PublishedEdgeSegments) void {
                sources.deinit();
            }

            pub fn createTarget(store: Store, path: []const u8) !segment_mod.ImmutableAdjacencySegment {
                return segment_mod.ImmutableAdjacencySegment.initEmpty(store.allocator, store.io, path);
            }

            pub fn deinitTarget(_: Store, target: *segment_mod.ImmutableAdjacencySegment) void {
                target.deinit();
            }

            pub fn deleteUnpublishedTarget(store: Store, path: []const u8) void {
                std.Io.Dir.cwd().deleteTree(store.io, path) catch {};
            }

            pub fn writeDirection(
                store: Store,
                target: *segment_mod.ImmutableAdjacencySegment,
                sources: *PublishedEdgeSegments,
                direction: segment_mod.Direction,
                edge_count: u64,
            ) !segment_mod.ImmutableAdjacencySegment.WrittenEdgeStreamSummary {
                var stream = EdgeSegmentMergeStream.initWithVirtual(
                    store.allocator,
                    &sources.segments,
                    sources.virtual_edges.items,
                    direction,
                );
                defer stream.deinit();
                return target.writeTrustedOrderedEdgeStreamSummary(
                    direction,
                    edge_count,
                    &stream,
                    EdgeSegmentMergeStream.reset,
                    EdgeSegmentMergeStream.next,
                );
            }

            pub fn summarizeDirections(
                _: Store,
                forward: segment_mod.ImmutableAdjacencySegment.WrittenEdgeStreamSummary,
                reverse: segment_mod.ImmutableAdjacencySegment.WrittenEdgeStreamSummary,
            ) !segment_mod.ImmutableAdjacencySegment.WrittenSegmentSummary {
                return segment_mod.ImmutableAdjacencySegment.summarizeWrittenEdgeStreams(forward, reverse);
            }

            pub fn writeIdIndex(
                store: Store,
                target_path: []const u8,
                entries: []const OwnedEdgeSegmentManifestEntry,
                written: segment_mod.ImmutableAdjacencySegment.WrittenSegmentSummary,
            ) !EdgeSegmentIdSidecarSummary {
                return store_plane.writeEdgeSegmentIdIndexFromManifestEntries(
                    store,
                    target_path,
                    entries,
                    written.edge_id_summary,
                );
            }

            pub fn copyEntry(entry: OwnedEdgeSegmentManifestEntry) EdgeSegmentManifestEntry {
                return .{
                    .edge_count = entry.edge_count,
                    .edge_digest = entry.edge_digest,
                    .edge_id_range = entry.edge_id_range,
                    .edge_id_digest = entry.edge_id_digest,
                    .edge_id_order_digest = entry.edge_id_order_digest,
                    .edge_id_runs = entry.edge_id_runs,
                    .src_node_range = entry.src_node_range,
                    .dst_node_range = entry.dst_node_range,
                    .singleton_rel = entry.singleton_rel,
                    .path = entry.path,
                };
            }

            pub fn replacementEntry(
                target_path: []const u8,
                edge_count: u64,
                written: segment_mod.ImmutableAdjacencySegment.WrittenSegmentSummary,
                id_index: EdgeSegmentIdSidecarSummary,
            ) EdgeSegmentManifestEntry {
                return .{
                    .edge_count = edge_count,
                    .edge_digest = written.edge_digest,
                    .edge_id_range = written.edge_id_summary.range,
                    .edge_id_digest = written.edge_id_summary.digest,
                    .edge_id_order_digest = id_index.edge_id_order_digest,
                    .edge_id_runs = id_index.edge_id_runs,
                    .src_node_range = written.endpoint_summary.src_range,
                    .dst_node_range = written.endpoint_summary.dst_range,
                    .path = target_path,
                };
            }

            pub fn publishManifest(store: Store, entries: []const EdgeSegmentManifestEntry) !void {
                try store_plane.writeEdgeSegmentManifestEntries(store, entries);
            }

            pub fn updateMetadata(store: Store, entries: []const EdgeSegmentManifestEntry) !void {
                try store_plane.updateIndexMetaEdgeSegmentSummary(store, try store_plane.edgeSegmentManifestSummary(store, entries));
            }
        };

        pub const edge_segment_window_compaction = edge_segment_window_compaction_mod.EdgeSegmentWindowCompaction(EdgeSegmentWindowCompactionOps);

        pub const EdgeSegmentMaintenanceOps = struct {
            pub const BudgetType = EdgeSegmentMaintenanceBudget;
            pub const ResultType = EdgeSegmentMaintenanceResult;
            pub const GcResultType = EdgeSegmentGcResult;

            pub fn allocator(store: Store) std.mem.Allocator {
                return store.allocator;
            }

            pub fn autoCompactEntryThreshold(store: Store) usize {
                return @intCast(store.options.auto_compact_edge_segment_entries);
            }

            pub fn autoCompactBatchEntries(store: Store) usize {
                return @intCast(store.options.auto_compact_edge_segment_batch_entries);
            }

            pub fn autoGcEnabled(store: Store) bool {
                return store.options.auto_gc_edge_segments;
            }

            pub fn dropRedundantOverlay(store: Store) !bool {
                return store_plane.dropRedundantEdgeSegmentOverlayAfterBaseIndexCatchup(store);
            }

            pub fn readManifest(store: Store) !EdgeSegmentManifest {
                return store_plane.readEdgeSegmentManifest(store, store.allocator);
            }

            pub fn deinitManifest(store: Store, manifest: *EdgeSegmentManifest) void {
                manifest.deinit(store.allocator);
            }

            pub fn manifestEntries(manifest: *const EdgeSegmentManifest) []const OwnedEdgeSegmentManifestEntry {
                return manifest.entries.items;
            }

            pub fn totalEdgeCount(manifest: *const EdgeSegmentManifest) u64 {
                return manifest.totalEdgeCount();
            }

            pub fn readCurrentMeta(store: Store) !IndexMeta {
                return store_plane.readCurrentIndexMeta(store);
            }

            pub fn coveredPhysicalEdges(store: Store, meta: IndexMeta, manifest_edges: u64) !?u64 {
                return store_plane.edgeSegmentManifestCoveredPhysicalEdges(store, meta, manifest_edges);
            }

            pub fn manifestOwnedDigest(store: Store, entries: []const OwnedEdgeSegmentManifestEntry) !u64 {
                return store_plane.edgeSegmentManifestOwnedDigest(store, entries);
            }

            pub fn autoCompactedPath(store: Store, edge_count: u64, count: usize, digest: u64) ![]u8 {
                return store_plane.edgeAutoCompactedSegmentPath(store, edge_count, count, digest);
            }

            pub fn freePath(store: Store, path: []const u8) void {
                store.allocator.free(path);
            }

            pub fn pathExists(store: Store, path: []const u8) !bool {
                return store_plane.pathExists(store, path);
            }

            pub fn compactWindow(
                store: Store,
                target_path: []const u8,
                entries: []const OwnedEdgeSegmentManifestEntry,
                start: usize,
                count: usize,
                edge_count: u64,
            ) !void {
                _ = try store_plane.compactEdgeSegmentManifestRange(store, target_path, entries, start, count, edge_count);
            }

            pub fn gcAfterAutoCompaction(store: Store) !EdgeSegmentGcResult {
                return store_plane.gcUnreferencedEdgeSegmentsWithProcessLeases(store);
            }

            pub fn gcAfterBudgetedCompaction(store: Store, pinned_manifest_paths: []const []const u8) !EdgeSegmentGcResult {
                return store_plane.gcUnreferencedEdgeSegmentsExcept(store, pinned_manifest_paths);
            }
        };

        pub const edge_segment_maintenance = edge_segment_maintenance_mod.EdgeSegmentMaintenance(EdgeSegmentMaintenanceOps);

        pub const StorageNodeTextLookupContext = struct {
            pub const MetaType = IndexMeta;
            pub const HeaderType = NodeTextIndexHeader;
            pub const RecordType = NodeTextIndexRecord;
            pub const ManifestType = NodeTextRunManifest;
            pub const ManifestEntryType = OwnedNodeTextRunManifestEntry;
            pub const NodeIdType = core.NodeId;
            pub const NodeKindType = core.NodeKind;
            pub const NodeViewType = NodeByIdIndexView;
            pub const TextsViewType = NodeTextsView;
            pub const FileType = std.Io.File;
            pub const MemoryMapType = std.Io.File.MemoryMap;
            pub const RetentionRegistryType = NodeTextRunRetentionRegistry;
            pub const RetentionWindowType = NodeTextRunRegisteredRetentionWindow;
            pub const BaseFilterType = NodeTextBaseHashFilter;

            store: Store,

            pub fn init(store: Store) StorageNodeTextLookupContext {
                return .{ .store = store };
            }

            pub fn basePath(context: StorageNodeTextLookupContext) []const u8 {
                return context.store.node_by_text_path;
            }

            pub fn deltaPath(context: StorageNodeTextLookupContext) []const u8 {
                return context.store.node_by_text_delta_path;
            }

            pub fn validateIndexesOnRead(context: StorageNodeTextLookupContext) bool {
                return context.store.options.validate_indexes_on_read;
            }

            pub fn monotonicNs(context: StorageNodeTextLookupContext) u128 {
                return store_plane.monotonicNs(context.store);
            }

            pub fn elapsedNs(context: StorageNodeTextLookupContext, start: u128) u128 {
                return store_plane.elapsedNs(context.store, start);
            }

            pub fn openFile(context: StorageNodeTextLookupContext, path: []const u8) !std.Io.File {
                return std.Io.Dir.cwd().openFile(context.store.io, path, .{});
            }

            pub fn closeFile(context: StorageNodeTextLookupContext, file: std.Io.File) void {
                file.close(context.store.io);
            }

            pub fn readHeader(context: StorageNodeTextLookupContext, file: std.Io.File) !NodeTextIndexHeader {
                return store_plane.readNodeTextIndexHeaderFromFile(context.store, file);
            }

            pub fn headersIdentifySameRun(expected: NodeTextIndexHeader, actual: NodeTextIndexHeader) bool {
                return expected.node_count == actual.node_count and
                    expected.node_digest == actual.node_digest and
                    expected.order_digest == actual.order_digest;
            }

            pub fn headersMatchCache(expected: NodeTextIndexHeader, actual: NodeTextIndexHeader) bool {
                return store_plane.nodeTextHeaderMatchesBaseFilter(expected, actual);
            }

            pub fn fileSizeForHeader(header: NodeTextIndexHeader) !u64 {
                return nodeTextIndexFileSizeForHeader(header);
            }

            pub fn regularFileSize(context: StorageNodeTextLookupContext, file: std.Io.File) !u64 {
                return store_plane.regularFileSize(context.store, file);
            }

            pub fn openReadOnlyMemoryMap(context: StorageNodeTextLookupContext, file: std.Io.File, size: u64) !std.Io.File.MemoryMap {
                return store_plane.openReadOnlyMemoryMap(context.store.io, file, size);
            }

            pub fn destroyMemoryMap(context: StorageNodeTextLookupContext, map: *std.Io.File.MemoryMap) void {
                map.destroy(context.store.io);
            }

            pub fn dupeHashFilter(context: StorageNodeTextLookupContext, filter: []const u8) ![]u8 {
                return context.store.allocator.dupe(u8, filter);
            }

            pub fn freeHashFilter(context: StorageNodeTextLookupContext, filter: []u8) void {
                context.store.allocator.free(filter);
            }

            pub fn readCurrentMeta(context: StorageNodeTextLookupContext) !IndexMeta {
                return store_plane.readCurrentIndexMeta(context.store);
            }

            pub fn readDeltaHeader(context: StorageNodeTextLookupContext) !NodeTextIndexHeader {
                return store_plane.readNodeTextDeltaHeader(context.store);
            }

            pub fn baseHeaderCoversMeta(header: NodeTextIndexHeader, meta: IndexMeta) bool {
                return nodeTextBaseHeaderCoversMeta(header, meta);
            }

            pub fn nodeIndexValid(context: StorageNodeTextLookupContext, expected_nodes: u64) !bool {
                return store_plane.nodeIndexValid(context.store, expected_nodes);
            }

            pub fn openRetentionWindow(
                context: StorageNodeTextLookupContext,
                registry: *NodeTextRunRetentionRegistry,
            ) !NodeTextRunRegisteredRetentionWindow {
                return store_plane.openRegisteredNodeTextRunRetentionWindow(context.store, registry);
            }

            pub fn retentionManifestPath(window: *const NodeTextRunRegisteredRetentionWindow) ?[]const u8 {
                return window.manifest_path;
            }

            pub fn deinitRetentionWindow(window: *NodeTextRunRegisteredRetentionWindow) void {
                window.deinit();
            }

            pub fn readManifest(
                context: StorageNodeTextLookupContext,
                allocator: std.mem.Allocator,
            ) !NodeTextRunManifest {
                return store_plane.readNodeTextRunManifest(context.store, allocator);
            }

            pub fn readManifestFile(
                context: StorageNodeTextLookupContext,
                allocator: std.mem.Allocator,
                path: []const u8,
            ) !NodeTextRunManifest {
                return store_plane.readNodeTextRunManifestFile(context.store, allocator, path);
            }

            pub fn deinitManifest(
                _: StorageNodeTextLookupContext,
                allocator: std.mem.Allocator,
                manifest: *NodeTextRunManifest,
            ) void {
                manifest.deinit(allocator);
            }

            pub fn emptyManifest() NodeTextRunManifest {
                return .{};
            }

            pub fn manifestEntries(manifest: *const NodeTextRunManifest) []const OwnedNodeTextRunManifestEntry {
                return manifest.entries.items;
            }

            pub fn manifestTotalNodeCount(manifest: *const NodeTextRunManifest) u64 {
                return manifest.totalNodeCount();
            }

            pub fn manifestNodeDigest(manifest: *const NodeTextRunManifest) u64 {
                return manifest.nodeDigest();
            }

            pub fn manifestCombinedOrderDigest(
                manifest: *const NodeTextRunManifest,
                base: NodeTextIndexHeader,
                delta: NodeTextIndexHeader,
            ) u64 {
                return manifest.combinedOrderDigest(base, delta);
            }

            pub fn entryPath(entry: OwnedNodeTextRunManifestEntry) []const u8 {
                return entry.path;
            }

            pub fn entryHeader(entry: OwnedNodeTextRunManifestEntry) NodeTextIndexHeader {
                return entry.header();
            }

            pub fn entryMinNodeId(entry: OwnedNodeTextRunManifestEntry) u64 {
                return entry.min_node_id;
            }

            pub fn entryHashFilter(entry: OwnedNodeTextRunManifestEntry) []const u8 {
                return entry.hash_filter;
            }

            pub fn entryMayContainHash(entry: OwnedNodeTextRunManifestEntry, hash: u64) bool {
                return nodeTextRunManifestEntryMayContainHash(entry, hash);
            }

            pub fn cachedManifestForMeta(
                context: StorageNodeTextLookupContext,
                meta: IndexMeta,
            ) !?*const NodeTextRunManifest {
                return store_plane.cachedNodeTextRunManifestForMeta(context.store, meta);
            }

            pub fn cachedBaseHashFilter(
                context: StorageNodeTextLookupContext,
            ) !?*const NodeTextBaseHashFilter {
                return store_plane.cachedNodeTextBaseHashFilter(context.store, null);
            }

            pub fn baseFilterHeader(filter: *const NodeTextBaseHashFilter) NodeTextIndexHeader {
                return filter.header;
            }

            pub fn baseFilterBytes(filter: *const NodeTextBaseHashFilter) []const u8 {
                return filter.filter;
            }

            pub fn baseFilterMatchesCurrentBase(
                context: StorageNodeTextLookupContext,
                header: NodeTextIndexHeader,
            ) !bool {
                return store_plane.nodeTextBaseFilterMatchesCurrentBase(context.store, header);
            }

            pub fn hashFilterMayContain(filter: []const u8, hash: u64) bool {
                return nodeTextRunHashFilterMayContain(filter, hash);
            }

            pub fn hashText(text: []const u8) u64 {
                return nodeTextHash(text);
            }

            pub fn deltaRunCache(context: StorageNodeTextLookupContext) *node_text_lookup_view_data_plane.DeltaRunCache {
                return context.store.node_text_delta_run_cache;
            }

            pub fn runMayContainHash(run: node_text_lookup_view_data_plane.Run, hash: u64) bool {
                return nodeTextLookupRunMayContainHash(run, hash);
            }

            pub fn headerHasDerivedHash(header: NodeTextIndexHeader) bool {
                return header.hasDerivedHash();
            }

            pub fn headerHasDerivedTextSpan(header: NodeTextIndexHeader) bool {
                return header.hasDerivedTextSpan();
            }

            pub fn headerHasTextHashUnique(header: NodeTextIndexHeader) bool {
                return header.hasTextHashUnique();
            }

            pub fn ensureTextsView(
                context: StorageNodeTextLookupContext,
                view: *?NodeTextsView,
            ) !*NodeTextsView {
                return store_plane.ensureNodeTextsView(context.store, view);
            }

            pub fn ensureNodeView(
                context: StorageNodeTextLookupContext,
                meta: IndexMeta,
                view: *?NodeByIdIndexView,
            ) !*NodeByIdIndexView {
                return store_plane.ensureNodeByIdIndexView(context.store, meta, view);
            }

            pub fn deinitTextsView(_: StorageNodeTextLookupContext, view: *NodeTextsView) void {
                view.deinit();
            }

            pub fn deinitNodeView(_: StorageNodeTextLookupContext, view: *NodeByIdIndexView) void {
                view.deinit();
            }

            pub fn readRecord(
                context: StorageNodeTextLookupContext,
                run: node_text_lookup_view_data_plane.Run,
                index: u64,
                texts: ?*const NodeTextsView,
                nodes: ?*const NodeByIdIndexView,
            ) !NodeTextIndexRecord {
                return if (run.map) |mapped|
                    store_plane.readNodeTextIndexRecordFromMapForHeaderWithTextsAndNodes(run.header, mapped, index, texts, nodes)
                else
                    store_plane.readNodeTextIndexRecordAtForHeaderWithTextsAndNodes(context.store, run.file, run.header, index, texts, nodes);
            }

            pub fn readRecordHash(
                context: StorageNodeTextLookupContext,
                run: node_text_lookup_view_data_plane.Run,
                index: u64,
                texts: ?*const NodeTextsView,
                nodes: ?*const NodeByIdIndexView,
            ) !u64 {
                return if (run.map) |mapped|
                    store_plane.readNodeTextIndexRecordHashFromMapForHeader(context.store, run.header, mapped, index, texts, nodes)
                else
                    store_plane.readNodeTextIndexRecordHashAtForHeader(context.store, run.file, run.header, index, texts, nodes);
            }

            pub fn recordNodeKind(record: NodeTextIndexRecord) !core.NodeKind {
                return record.nodeKind();
            }

            pub fn textsMatch(
                texts: *const NodeTextsView,
                offset: u64,
                len: u32,
                expected: []const u8,
            ) !bool {
                return texts.matches(offset, len, expected);
            }

            pub fn nodeViewReadRecord(view: *const NodeByIdIndexView, id: u64) !NodeByIdRecord {
                return view.readRecord(id);
            }

            pub fn validateLookupRecord(
                record: NodeTextIndexRecord,
                by_id: NodeByIdRecord,
                kind: core.NodeKind,
                text_len: usize,
            ) !void {
                return validateNodeTextLookupRecord(record, by_id, kind, text_len);
            }

            pub fn nodeIdFromInt(id: u64) core.NodeId {
                return core.NodeId.fromInt(id);
            }

            pub fn nodeIdToInt(id: core.NodeId) u64 {
                return id.toInt();
            }

            pub fn sortNodeIds(ids: []core.NodeId) void {
                std.mem.sort(core.NodeId, ids, {}, nodeIdLessThan);
            }
        };

        pub const node_text_lookup_view_data_plane =
            node_text_lookup_view_data_plane_mod.NodeTextLookupViewDataPlane(StorageNodeTextLookupContext);

        pub const StorageNodeTextCatalogContext = struct {
            pub const MetaType = IndexMeta;
            pub const HeaderType = NodeTextIndexHeader;
            pub const RecordType = NodeTextIndexRecord;
            pub const ManifestType = NodeTextRunManifest;
            pub const OwnedEntryType = OwnedNodeTextRunManifestEntry;
            pub const EntryType = NodeTextRunManifestEntry;
            pub const DigestType = NodeTextIndexDigest;
            pub const TextsViewType = NodeTextsView;
            pub const RunResultType = NodeTextRunMaintenanceResult;
            pub const GcResultType = NodeTextRunGcResult;

            pub const run_max_records = node_text_run_max_records;
            pub const manifest_max_entries = node_text_run_manifest_max_entries;
            pub const delta_max_records = node_text_delta_max_records;

            store: Store,
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            node_by_text_path: []const u8,
            node_by_text_delta_path: []const u8,

            pub fn init(store: Store) StorageNodeTextCatalogContext {
                return .{
                    .store = store,
                    .allocator = store.allocator,
                    .io = store.io,
                    .dir_path = store.dir_path,
                    .node_by_text_path = store.node_by_text_path,
                    .node_by_text_delta_path = store.node_by_text_delta_path,
                };
            }

            pub fn shouldSync(context: StorageNodeTextCatalogContext) bool {
                return selfOptionsNeedSync(context.store);
            }

            pub fn readIndexMeta(context: StorageNodeTextCatalogContext) !IndexMeta {
                return store_plane.readIndexMeta(context.store);
            }

            pub fn writeIndexMeta(context: StorageNodeTextCatalogContext, meta: IndexMeta) !void {
                try store_plane.writeIndexMeta(context.store, meta);
            }

            pub fn readHeader(context: StorageNodeTextCatalogContext, file: std.Io.File) !NodeTextIndexHeader {
                return store_plane.readNodeTextIndexHeaderFromFile(context.store, file);
            }

            pub fn readDeltaHeader(context: StorageNodeTextCatalogContext) !NodeTextIndexHeader {
                return store_plane.readNodeTextDeltaHeader(context.store);
            }

            pub fn readRunManifest(context: StorageNodeTextCatalogContext) !NodeTextRunManifest {
                return store_plane.readNodeTextRunManifest(context.store, context.allocator);
            }

            pub fn openNodeTextsView(context: StorageNodeTextCatalogContext) !NodeTextsView {
                return NodeTextsView.open(context.store);
            }

            pub fn deinitNodeTextsView(_: StorageNodeTextCatalogContext, texts: *NodeTextsView) void {
                texts.deinit();
            }

            pub fn readRecordWithTexts(
                context: StorageNodeTextCatalogContext,
                file: std.Io.File,
                header: NodeTextIndexHeader,
                index: u64,
                texts: *const NodeTextsView,
            ) !NodeTextIndexRecord {
                return store_plane.readNodeTextIndexRecordAtForHeaderWithTexts(context.store, file, header, index, texts);
            }

            pub fn readRecordFromMap(
                _: StorageNodeTextCatalogContext,
                header: NodeTextIndexHeader,
                map: *const std.Io.File.MemoryMap,
                index: u64,
                texts: *const NodeTextsView,
            ) !NodeTextIndexRecord {
                return store_plane.readNodeTextIndexRecordFromMapForHeaderWithTexts(header, map, index, texts);
            }

            pub fn recordDigestWithTexts(
                context: StorageNodeTextCatalogContext,
                texts: *const NodeTextsView,
                record: NodeTextIndexRecord,
            ) !u64 {
                return store_plane.nodeTextIndexRecordDigestWithTexts(context.store, texts, record);
            }

            pub fn openReadOnlyMemoryMap(context: StorageNodeTextCatalogContext, file: std.Io.File, size: u64) !std.Io.File.MemoryMap {
                return store_plane.openReadOnlyMemoryMap(context.io, file, size);
            }

            pub fn tmpPathFor(context: StorageNodeTextCatalogContext, path: []const u8) ![]u8 {
                return store_plane.tmpPathFor(context.store, path);
            }

            pub fn renameReplace(context: StorageNodeTextCatalogContext, from: []const u8, to: []const u8) !void {
                try store_plane.renameReplace(context.store, from, to);
            }

            pub fn pathExists(context: StorageNodeTextCatalogContext, path: []const u8) !bool {
                return store_plane.pathExists(context.store, path);
            }

            pub fn writeRunManifestEntries(context: StorageNodeTextCatalogContext, entries: []const NodeTextRunManifestEntry) !void {
                try store_plane.writeNodeTextRunManifestEntries(context.store, entries);
            }

            pub fn writeRunManifestEntriesExcept(
                context: StorageNodeTextCatalogContext,
                entries: []const NodeTextRunManifestEntry,
                pinned_manifest_paths: []const []const u8,
            ) !void {
                try store_plane.writeNodeTextRunManifestEntriesExcept(context.store, entries, pinned_manifest_paths);
            }

            pub fn writeEmptyDelta(context: StorageNodeTextCatalogContext) !void {
                try store_plane.writeEmptyNodeTextDelta(context.store);
            }

            pub fn deleteRunManifest(context: StorageNodeTextCatalogContext) !void {
                try store_plane.deleteNodeTextRunManifest(context.store);
            }

            pub fn deleteRunManifestExcept(context: StorageNodeTextCatalogContext, pinned_manifest_paths: []const []const u8) !NodeTextRunGcResult {
                return store_plane.deleteNodeTextRunManifestExcept(context.store, pinned_manifest_paths);
            }

            pub fn runPathsForPinnedManifests(
                context: StorageNodeTextCatalogContext,
                pinned_manifest_paths: []const []const u8,
            ) !std.StringHashMap([]u8) {
                return store_plane.nodeTextRunPathsForPinnedManifests(context.store, pinned_manifest_paths);
            }

            pub fn freeOwnedPathSet(context: StorageNodeTextCatalogContext, paths: *std.StringHashMap([]u8)) void {
                store_plane.freeOwnedPathSet(context.store, paths);
            }

            pub fn ensureBaseHashFilter(context: StorageNodeTextCatalogContext, header: NodeTextIndexHeader) !void {
                try store_plane.ensureNodeTextBaseHashFilter(context.store, header);
            }

            pub fn ensureCurrentBaseHashFilter(context: StorageNodeTextCatalogContext) !void {
                try store_plane.ensureCurrentNodeTextBaseHashFilter(context.store);
            }

            pub fn buildRunHashFilterForRecords(context: StorageNodeTextCatalogContext, records: []const NodeTextIndexRecord) ![]u8 {
                return store_plane.buildNodeTextRunHashFilterForRecords(context.store, records);
            }

            pub fn buildRunHashFilterFromFile(context: StorageNodeTextCatalogContext, path: []const u8, expected_records: u64) ![]u8 {
                return store_plane.buildNodeTextRunHashFilterFromFile(context.store, path, expected_records);
            }

            pub fn compactDerivedRecords(context: StorageNodeTextCatalogContext, file: std.Io.File, header: *NodeTextIndexHeader) !void {
                try store_plane.compactNodeTextIndexToDerivedRecords(context.store, file, header);
            }

            pub fn recordsCanDeriveSpans(context: StorageNodeTextCatalogContext, records: []const NodeTextIndexRecord, mode: anytype) !bool {
                return switch (mode) {
                    .trusted_recent_by_id_append => records.len != 0,
                    .verify_by_id => store_plane.nodeTextRecordsCanDeriveSpansFromById(context.store, records),
                };
            }

            pub fn sortedRecordsHaveUniqueTextHashes(
                context: StorageNodeTextCatalogContext,
                texts: *const NodeTextsView,
                records: []const NodeTextIndexRecord,
            ) !bool {
                return store_plane.sortedNodeTextRecordsHaveUniqueTextHashes(context.store, texts, records);
            }

            pub fn recordFitsStoredHeader(context: StorageNodeTextCatalogContext, header: NodeTextIndexHeader, record: NodeTextIndexRecord) !bool {
                return store_plane.nodeTextRecordFitsStoredHeader(context.store, header, record);
            }

            pub fn publishDeltaHeaderCache(context: StorageNodeTextCatalogContext, header: NodeTextIndexHeader) void {
                context.store.node_text_delta_header_cache.header = header;
                context.store.node_text_delta_header_cache.valid = true;
                store_plane.refreshNodeTextDeltaRunCache(context.store, header);
            }

            pub fn recordLessThan(lhs: NodeTextIndexRecord, rhs: NodeTextIndexRecord) bool {
                return nodeTextIndexLessThan({}, lhs, rhs);
            }

            pub fn recordLessThanContext(_: void, lhs: NodeTextIndexRecord, rhs: NodeTextIndexRecord) bool {
                return recordLessThan(lhs, rhs);
            }

            pub fn manifestTotalNodesOwned(entries: []const OwnedNodeTextRunManifestEntry) ?u64 {
                return nodeTextRunManifestTotalNodesOwned(entries);
            }

            pub fn manifestDigestOwned(entries: []const OwnedNodeTextRunManifestEntry) u64 {
                return nodeTextRunManifestDigestOwned(entries);
            }

            pub fn combinedOrderDigestOwned(base: NodeTextIndexHeader, delta: NodeTextIndexHeader, entries: []const OwnedNodeTextRunManifestEntry) u64 {
                return combinedNodeTextOrderDigestWithRuns(base, delta, entries);
            }

            pub fn combinedOrderDigestEntries(base: NodeTextIndexHeader, delta: NodeTextIndexHeader, entries: []const NodeTextRunManifestEntry) u64 {
                return combinedNodeTextOrderDigestWithRunEntries(base, delta, entries);
            }

            pub fn headerForTail(
                old_header: NodeTextIndexHeader,
                next_count: u64,
                digest: u64,
                order_digest: u64,
                records: []const NodeTextIndexRecord,
            ) NodeTextIndexHeader {
                return nodeTextHeaderForTail(old_header, next_count, digest, order_digest, records);
            }

            pub fn headerForRecordsWithDerivedSpan(
                records: []const NodeTextIndexRecord,
                digest: u64,
                order_digest: u64,
                derived_text_span: bool,
            ) NodeTextIndexHeader {
                return nodeTextIndexHeaderForRecordsWithDerivedSpan(records, digest, order_digest, derived_text_span);
            }

            pub fn headerForSortedUniqueHashRecords(records: []const NodeTextIndexRecord, digest: u64, order_digest: u64) NodeTextIndexHeader {
                return nodeTextIndexHeaderForSortedUniqueHashRecords(records, digest, order_digest);
            }

            pub fn sortedBatchOrderDigest(records: []const NodeTextIndexRecord) !u64 {
                return sortedNodeTextBatchOrderDigest(records);
            }

            pub fn recordIdRange(records: []const NodeTextIndexRecord) !struct { min: u64, max: u64 } {
                const range = try nodeTextRecordIdRange(records);
                return .{ .min = range.min, .max = range.max };
            }

            pub fn recordHashRange(records: []const NodeTextIndexRecord) !struct { min: u64, max: u64 } {
                const range = try nodeTextRecordHashRange(records);
                return .{ .min = range.min, .max = range.max };
            }

            pub fn orderDigestStep(previous: u64, position: u64, record: NodeTextIndexRecord) u64 {
                return nodeTextIndexOrderDigestStep(previous, position, record);
            }

            pub fn currentProcessId() ProcessId {
                return currentProcessIdForTempPath();
            }
        };

        pub const node_text_catalog_transaction =
            node_text_catalog_transaction_mod.NodeTextCatalogTransaction(StorageNodeTextCatalogContext);

        pub const NodeTextMaintenanceOps = struct {
            pub const DeltaResultType = NodeTextDeltaMaintenanceResult;
            pub const RunResultType = NodeTextRunMaintenanceResult;

            pub fn readCurrentMeta(store: Store) !IndexMeta {
                return store_plane.readCurrentIndexMeta(store);
            }

            pub fn readDeltaHeader(store: Store) !NodeTextIndexHeader {
                return store_plane.readNodeTextDeltaHeader(store);
            }

            pub fn compactDeltaForMeta(store: Store, meta: IndexMeta) !void {
                _ = try store_plane.compactNodeTextDeltaForMeta(store, meta.nodes, meta.node_digest, meta.node_by_text_order_digest);
            }

            pub fn readRunManifest(store: Store) !NodeTextRunManifest {
                return store_plane.readNodeTextRunManifest(store, store.allocator);
            }

            pub fn deinitRunManifest(store: Store, manifest: *NodeTextRunManifest) void {
                manifest.deinit(store.allocator);
            }

            pub fn runEntries(manifest: *const NodeTextRunManifest) []const OwnedNodeTextRunManifestEntry {
                return manifest.entries.items;
            }

            pub fn totalRunCount(manifest: *const NodeTextRunManifest) u64 {
                return manifest.totalNodeCount();
            }

            pub fn compactRunWindow(
                store: Store,
                meta: IndexMeta,
                entries: []const OwnedNodeTextRunManifestEntry,
                delta_header: NodeTextIndexHeader,
                max_run_records: u64,
                pinned_manifest_paths: []const []const u8,
            ) !?NodeTextRunMaintenanceResult {
                return store_plane.compactNodeTextRunWindowForMeta(store, meta, entries, delta_header, max_run_records, pinned_manifest_paths);
            }

            pub fn compactOverlaysForMeta(
                store: Store,
                meta: IndexMeta,
                pinned_manifest_paths: []const []const u8,
            ) !node_text_catalog_transaction.OverlayCompactionResult {
                return store_plane.compactNodeTextOverlaysForMeta(store, meta.nodes, meta.node_digest, meta.node_by_text_order_digest, pinned_manifest_paths);
            }
        };

        pub const node_text_maintenance = node_text_maintenance_mod.NodeTextMaintenance(NodeTextMaintenanceOps);

        pub fn selfOptionsNeedSync(store: Store) bool {
            return switch (store.options.durability) {
                .fast => false,
                .safe => true,
            };
        }

        pub fn storageMonotonicNs(io: std.Io) u128 {
            const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
            return if (timestamp < 0) 0 else @intCast(timestamp);
        }

        pub fn storageElapsedNs(io: std.Io, start: u128) u128 {
            const now = storageMonotonicNs(io);
            return if (now >= start) now - start else 0;
        }

        pub fn indexMetaEquals(lhs: IndexMeta, rhs: IndexMeta) bool {
            return lhs.event_bytes == rhs.event_bytes and
                lhs.nodes == rhs.nodes and
                lhs.edges == rhs.edges and
                lhs.node_digest == rhs.node_digest and
                lhs.edge_digest == rhs.edge_digest and
                lhs.node_by_text_order_digest == rhs.node_by_text_order_digest and
                lhs.edge_indexed_edges == rhs.edge_indexed_edges and
                lhs.edge_index_digest == rhs.edge_index_digest and
                lhs.edge_by_id_order_digest == rhs.edge_by_id_order_digest and
                lhs.edge_by_src_order_digest == rhs.edge_by_src_order_digest and
                lhs.edge_by_dst_order_digest == rhs.edge_by_dst_order_digest and
                lhs.max_edge_id_seen == rhs.max_edge_id_seen and
                edgeSegmentIdRunSummariesEqual(lhs.edge_by_id_runs, rhs.edge_by_id_runs) and
                lhs.edge_segment_edges == rhs.edge_segment_edges and
                lhs.edge_segment_manifest_digest == rhs.edge_segment_manifest_digest and
                edgeSegmentIdRunSummariesEqual(lhs.edge_segment_id_runs, rhs.edge_segment_id_runs);
        }

        pub fn segmentManifestUniqueEntry(snapshot: segment_manifest.Snapshot, kind: segment_manifest.SegmentKind) !segment_manifest.Entry {
            var found: ?segment_manifest.Entry = null;
            for (snapshot.entries.items) |entry| {
                if (entry.kind != kind) continue;
                if (found != null) return error.InvalidRecord;
                found = entry.asEntry();
            }
            return found orelse error.InvalidRecord;
        }

        pub fn segmentManifestHasEdgeEntry(snapshot: segment_manifest.Snapshot) bool {
            for (snapshot.entries.items) |entry| {
                if (entry.kind == .edge) return true;
            }
            return false;
        }

        pub fn segmentManifestEdgeEntries(allocator: std.mem.Allocator, snapshot: segment_manifest.Snapshot) ![]segment_manifest.Entry {
            var count: usize = 0;
            for (snapshot.entries.items) |entry| {
                if (entry.kind == .edge) count += 1;
            }
            if (count == 0) return error.InvalidRecord;

            const entries = try allocator.alloc(segment_manifest.Entry, count);
            errdefer allocator.free(entries);
            var index: usize = 0;
            for (snapshot.entries.items) |entry| {
                if (entry.kind != .edge) continue;
                entries[index] = entry.asEntry();
                index += 1;
            }
            return entries;
        }

        pub fn segmentManifestEdgeCount(entries: []const segment_manifest.Entry) !u64 {
            var total: u64 = 0;
            for (entries) |entry| {
                if (entry.kind != .edge) return error.InvalidRecord;
                total = std.math.add(u64, total, entry.edge_count) catch return error.InvalidRecord;
            }
            return total;
        }

        pub fn segmentManifestEdgeDigest(entries: []const segment_manifest.Entry) u64 {
            var digest: u64 = 0;
            for (entries) |entry| digest ^= entry.segment_digest;
            return digest;
        }

        pub fn markEdgeIndexesCurrent(meta: *IndexMeta) void {
            meta.edge_indexed_edges = meta.edges;
            meta.edge_index_digest = meta.edge_digest;
            clearEdgeSegmentSummary(meta);
        }

        pub fn clearEdgeSegmentSummary(meta: *IndexMeta) void {
            meta.edge_segment_edges = 0;
            meta.edge_segment_manifest_digest = 0;
            meta.edge_segment_id_runs = .{};
        }

        pub fn edgeOrderDigestForMeta(meta: IndexMeta, order: EdgeIndexOrder) u64 {
            return switch (order) {
                .id => meta.edge_by_id_order_digest,
                .src => meta.edge_by_src_order_digest,
                .dst => meta.edge_by_dst_order_digest,
            };
        }

        pub fn edgeIndexBySrcLessThan(_: void, lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
            if (lhs.src != rhs.src) return lhs.src < rhs.src;
            if (lhs.rel != rhs.rel) return lhs.rel < rhs.rel;
            if (lhs.dst != rhs.dst) return lhs.dst < rhs.dst;
            return lhs.edge_id < rhs.edge_id;
        }

        pub fn edgeIndexByIdLessThan(_: void, lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
            if (lhs.edge_id != rhs.edge_id) return lhs.edge_id < rhs.edge_id;
            if (lhs.src != rhs.src) return lhs.src < rhs.src;
            if (lhs.dst != rhs.dst) return lhs.dst < rhs.dst;
            return lhs.rel < rhs.rel;
        }

        pub fn edgeIndexByDstLessThan(_: void, lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
            if (lhs.dst != rhs.dst) return lhs.dst < rhs.dst;
            if (lhs.rel != rhs.rel) return lhs.rel < rhs.rel;
            if (lhs.src != rhs.src) return lhs.src < rhs.src;
            return lhs.edge_id < rhs.edge_id;
        }

        pub fn edgeIndexLessThan(order: EdgeIndexOrder, lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
            return switch (order) {
                .id => edgeIndexByIdLessThan({}, lhs, rhs),
                .src => edgeIndexBySrcLessThan({}, lhs, rhs),
                .dst => edgeIndexByDstLessThan({}, lhs, rhs),
            };
        }

        pub fn edgeIndexBatchSorted(order: EdgeIndexOrder, records: []const EdgeIndexRecord) bool {
            var pos: usize = 1;
            while (pos < records.len) : (pos += 1) {
                if (!edgeIndexLessThan(order, records[pos - 1], records[pos])) return false;
            }
            return true;
        }

        pub fn edgeRecordsAreDenseIdTail(base_count: u64, records: []const EdgeIndexRecord) bool {
            for (records, 0..) |record, i| {
                const expected = std.math.add(u64, base_count, @intCast(i + 1)) catch return false;
                if (record.edge_id != expected) return false;
            }
            return true;
        }

        pub fn edgeRecordHasU32NodeIds(record: EdgeIndexRecord) bool {
            return record.src <= std.math.maxInt(u32) and record.dst <= std.math.maxInt(u32);
        }

        pub fn edgeRecordsHaveU32NodeIds(records: []const EdgeIndexRecord) bool {
            if (records.len == 0) return false;
            for (records) |record| {
                if (!edgeRecordHasU32NodeIds(record)) return false;
            }
            return true;
        }

        pub fn edgeRecordHasU32EdgeId(record: EdgeIndexRecord) bool {
            return record.edge_id <= std.math.maxInt(u32);
        }

        pub fn edgeRecordsHaveU32EdgeIds(records: []const EdgeIndexRecord) bool {
            if (records.len == 0) return false;
            for (records) |record| {
                if (!edgeRecordHasU32EdgeId(record)) return false;
            }
            return true;
        }

        pub fn edgeIndexHeaderWithBeneficialKeyRuns(order: EdgeIndexOrder, header: EdgeIndexHeader, records: []const EdgeIndexRecord) EdgeIndexHeader {
            if (records.len == 0) return header;
            if (order == .id) return edgeIndexHeaderWithBeneficialIdEndpointRuns(header, records);
            if (header.hasDenseId() or header.hasKeyRuns()) return header;
            const run_count = edgeIndexRunCountForSortedRecords(order, records) orelse return header;
            if (run_count == 0 or run_count > std.math.maxInt(u32)) return header;
            const opposite_lane_len: u64 = if (header.hasU32NodeIds()) 4 else 8;
            const constant_opposite = edgeIndexRunsHaveConstantOpposite(order, records) and constant_opposite: {
                const dir_bytes = std.math.mul(u64, run_count, opposite_lane_len) catch break :constant_opposite false;
                const row_bytes = std.math.mul(u64, @intCast(records.len), opposite_lane_len) catch break :constant_opposite false;
                break :constant_opposite dir_bytes < row_bytes;
            };
            const base_body_bytes = edgeIndexBodyBytes(header) orelse return header;
            var best_header = header;
            var best_body_bytes = base_body_bytes;

            const key_run_header = header.withKeyRuns(@intCast(run_count), constant_opposite, false);
            if (edgeIndexBodyBytes(key_run_header)) |bytes| {
                if (bytes < best_body_bytes) {
                    best_header = key_run_header;
                    best_body_bytes = bytes;
                }
            }
            if (constant_opposite) {
                if (edgeIndexRunsHaveRingOpposite(order, key_run_header, records)) |opposite_mod| {
                    const ring_header = key_run_header.withKeyRunRingOpposite(opposite_mod);
                    if (edgeIndexBodyBytes(ring_header)) |bytes| {
                        if (bytes < best_body_bytes) {
                            best_header = ring_header;
                            best_body_bytes = bytes;
                        }
                    }
                }
            }

            const linear_probe = header.withKeyRuns(1, constant_opposite, true);
            if (edgeIndexRunCountForHeaderShape(linear_probe, records)) |linear_run_count| {
                if (linear_run_count != 0 and linear_run_count <= std.math.maxInt(u32)) {
                    const linear_header = header.withKeyRuns(@intCast(linear_run_count), constant_opposite, true);
                    if (edgeIndexBodyBytes(linear_header)) |bytes| {
                        if (bytes < best_body_bytes) {
                            best_header = linear_header;
                            best_body_bytes = bytes;
                        }
                    }
                    if (constant_opposite) {
                        if (edgeIndexRunsHaveRingOpposite(order, linear_header, records)) |opposite_mod| {
                            const ring_linear_header = linear_header.withKeyRunRingOpposite(opposite_mod);
                            if (edgeIndexBodyBytes(ring_linear_header)) |bytes| {
                                if (bytes < best_body_bytes) {
                                    best_header = ring_linear_header;
                                    best_body_bytes = bytes;
                                }
                            }
                            if (edgeIndexRunsHaveUniformEdgeIdStep(ring_linear_header, records)) |edge_id_step| {
                                const uniform_step_header = ring_linear_header.withKeyRunUniformEdgeIdStep(edge_id_step);
                                if (edgeIndexBodyBytes(uniform_step_header)) |uniform_bytes| {
                                    if (uniform_bytes < best_body_bytes) {
                                        best_header = uniform_step_header;
                                        best_body_bytes = uniform_bytes;
                                    }
                                }
                                if (edgeIndexRunsHaveDenseSpan(uniform_step_header, records)) |dense_span| {
                                    const dense_span_header = uniform_step_header.withKeyRunDenseSpan(dense_span);
                                    if (edgeIndexBodyBytes(dense_span_header)) |dense_span_bytes| {
                                        if (dense_span_bytes < best_body_bytes) {
                                            best_header = dense_span_header;
                                            best_body_bytes = dense_span_bytes;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (edgeIndexRunsHaveUniformEdgeIdStep(linear_header, records)) |edge_id_step| {
                        const uniform_step_header = linear_header.withKeyRunUniformEdgeIdStep(edge_id_step);
                        if (edgeIndexBodyBytes(uniform_step_header)) |bytes| {
                            if (bytes < best_body_bytes) {
                                best_header = uniform_step_header;
                                best_body_bytes = bytes;
                            }
                        }
                    }
                }
            }

            return best_header;
        }

        pub fn edgeIndexHeaderWithBeneficialIdEndpointRuns(header: EdgeIndexHeader, records: []const EdgeIndexRecord) EdgeIndexHeader {
            if (header.order != .id or !header.hasDenseId() or !header.hasU32NodeIds() or header.hasKeyRuns()) return header;
            const run_count = edgeIndexIdEndpointRunCount(records) orelse return header;
            if (run_count == 0 or run_count > std.math.maxInt(u32)) return header;
            const run_bytes = std.math.mul(u64, run_count, @as(u64, 12)) catch return header;
            const row_endpoint_bytes = std.math.mul(u64, @intCast(records.len), @as(u64, 8)) catch return header;
            if (run_bytes >= row_endpoint_bytes) return header;
            return header.withKeyRuns(@intCast(run_count), true, false);
        }

        pub fn denseEdgeIdRunSummaryForHeader(header: EdgeIndexHeader) !?EdgeSegmentIdRunSummary {
            try header.validateShape();
            if (header.order != .id or !header.hasDenseId()) return null;
            if (header.edge_count == 0) return .{};
            if (header.edge_count == std.math.maxInt(u64)) return error.InvalidRecord;
            return .{
                .run_count = 1,
                .first_min = 1,
                .first_max = header.edge_count,
            };
        }

        pub fn edgeIndexIdEndpointRunCount(records: []const EdgeIndexRecord) ?u64 {
            if (records.len == 0) return 0;
            var run_count: u64 = 1;
            if (!edgeIndexIdEndpointCanStartRun(records[0])) return null;
            for (records[1..], 1..) |record, i| {
                if (!edgeIndexIdEndpointCanStartRun(record)) return null;
                const previous = records[i - 1];
                const expected_src = std.math.add(u64, previous.src, 1) catch std.math.maxInt(u64);
                const expected_dst = std.math.add(u64, previous.dst, 1) catch std.math.maxInt(u64);
                if (record.src == expected_src and record.dst == expected_dst) continue;
                run_count = std.math.add(u64, run_count, 1) catch return null;
            }
            return run_count;
        }

        pub fn edgeIndexIdEndpointCanStartRun(record: EdgeIndexRecord) bool {
            return edgeRecordHasU32NodeIds(record) and record.src != 0 and record.dst != 0;
        }

        pub fn edgeIndexRecordStartsNewRun(header: EdgeIndexHeader, records: []const EdgeIndexRecord, index: usize) !bool {
            if (!header.hasKeyRuns() or index >= records.len) return error.InvalidRecord;
            if (index == 0) return true;
            if (header.order == .id) {
                const previous = records[index - 1];
                const record = records[index];
                const expected_src = std.math.add(u64, previous.src, 1) catch return true;
                const expected_dst = std.math.add(u64, previous.dst, 1) catch return true;
                return record.src != expected_src or record.dst != expected_dst;
            }
            return edgeIndexRecordKey(records[index], header.order) != edgeIndexRecordKey(records[index - 1], header.order);
        }

        pub fn edgeIndexBodyBytes(header: EdgeIndexHeader) ?u64 {
            const directory_size = edgeIndexKeyRunDirectorySizeForHeader(header) catch return null;
            const row_bytes = std.math.mul(u64, header.edge_count, header.record_len) catch return null;
            return std.math.add(u64, directory_size, row_bytes) catch return null;
        }

        pub fn edgeIndexRunCountForHeaderShape(header: EdgeIndexHeader, records: []const EdgeIndexRecord) ?u64 {
            if (!header.hasKeyRuns() or records.len == 0) return null;
            var run_count: u64 = 0;
            var run_start: usize = 0;
            while (run_start < records.len) {
                run_count = std.math.add(u64, run_count, 1) catch return null;
                run_start = edgeIndexNextRunStartForHeaderShape(header, records, run_start) orelse return null;
            }
            return run_count;
        }

        pub fn edgeIndexRunsHaveRingOpposite(order: EdgeIndexOrder, header: EdgeIndexHeader, records: []const EdgeIndexRecord) ?u64 {
            if (order == .id or !header.hasKeyRuns() or !header.hasKeyRunConstantOpposite() or records.len == 0) return null;
            var max_key: u64 = 0;
            var run_start: usize = 0;
            while (run_start < records.len) {
                const key = edgeIndexRecordKey(records[run_start], order);
                if (key == 0 or key == std.math.maxInt(u64)) return null;
                if (key > max_key) max_key = key;
                run_start = edgeIndexNextRunStartForHeaderShape(header, records, run_start) orelse return null;
            }
            if (max_key < 2) return null;
            if (header.hasU32NodeIds() and max_key > std.math.maxInt(u32)) return null;

            const probe_header = header.withKeyRunRingOpposite(max_key);
            run_start = 0;
            while (run_start < records.len) {
                const run = edgeIndexRunRecordForStart(header, records, run_start) catch return null;
                const expected = edgeIndexRingOppositeForKey(probe_header, run.key) catch return null;
                if (run.opposite != expected) return null;
                run_start = edgeIndexNextRunStartForHeaderShape(header, records, run_start) orelse return null;
            }
            return max_key;
        }

        pub fn edgeIndexRunsHaveUniformEdgeIdStep(header: EdgeIndexHeader, records: []const EdgeIndexRecord) ?u64 {
            if (!header.hasKeyRuns() or !header.hasKeyRunLinearEdgeIds() or records.len == 0) return null;
            var uniform_step: u64 = 0;
            var run_start: usize = 0;
            while (run_start < records.len) {
                const step = edgeIndexRunEdgeIdStep(header, records, run_start) orelse return null;
                if (step != 0) {
                    if (step > std.math.maxInt(u32)) return null;
                    if (uniform_step == 0) {
                        uniform_step = step;
                    } else if (step != uniform_step) {
                        return null;
                    }
                }
                run_start = edgeIndexNextRunStartForHeaderShape(header, records, run_start) orelse return null;
            }
            if (uniform_step == 0) return null;
            return uniform_step;
        }

        pub fn edgeIndexDenseKeyRunSpanRecordForIndex(header: EdgeIndexHeader, run_index: u64) !EdgeIndexKeyRunRecord {
            try header.validateShape();
            if (!header.hasKeyRunDenseSpan() or run_index < header.key_run_dense_run_start) return error.InvalidRecord;
            const dense_index = run_index - header.key_run_dense_run_start;
            if (dense_index >= header.key_run_dense_count) return error.InvalidRecord;
            const key = std.math.add(u64, header.key_run_dense_key_base, dense_index) catch return error.InvalidRecord;
            const start_delta = std.math.mul(u64, dense_index, header.key_run_dense_start_step) catch return error.InvalidRecord;
            const start = std.math.add(u64, header.key_run_dense_start_base, start_delta) catch return error.InvalidRecord;
            const edge_id_delta = std.math.mul(u64, dense_index, header.key_run_dense_edge_id_base_step) catch return error.InvalidRecord;
            const edge_id_base = std.math.add(u64, header.key_run_dense_edge_id_base, edge_id_delta) catch return error.InvalidRecord;
            return .{
                .key = key,
                .start = start,
                .opposite = try edgeIndexRingOppositeForKey(header, key),
                .edge_id_base = edge_id_base,
                .edge_id_step = header.key_run_edge_id_step,
            };
        }

        pub fn edgeIndexKeyRunRecordsEquivalent(header: EdgeIndexHeader, expected: EdgeIndexKeyRunRecord, actual: EdgeIndexKeyRunRecord) bool {
            if (expected.key != actual.key or expected.start != actual.start or expected.opposite != actual.opposite) return false;
            if (header.hasKeyRunLinearEdgeIds()) {
                if (expected.edge_id_base != actual.edge_id_base) return false;
                if (actual.edge_id_step != 0 and expected.edge_id_step != actual.edge_id_step) return false;
            }
            return true;
        }

        pub fn edgeIndexRunsHaveDenseSpan(header: EdgeIndexHeader, records: []const EdgeIndexRecord) ?EdgeIndexDenseKeyRunSpan {
            if (!header.hasKeyRunRingOpposite() or !header.hasKeyRunUniformEdgeIdStep()) return null;
            if (!header.hasU32NodeIds() or !header.hasU32EdgeIds()) return null;
            if (records.len == 0) return null;

            var best: ?EdgeIndexDenseKeyRunSpan = null;
            var best_score: u64 = 0;
            var span_start_index: u64 = 0;
            var span_start = edgeIndexRunRecordForStart(header, records, 0) catch return null;
            var previous = span_start;
            var span_count: u64 = 1;
            var start_step: u64 = 0;
            var edge_id_base_step: u64 = 0;

            var run_start: usize = 0;
            var run_index: u64 = 0;
            while (true) {
                const next_start = edgeIndexNextRunStartForHeaderShape(header, records, run_start) orelse return null;
                if (next_start >= records.len) break;
                const next = edgeIndexRunRecordForStart(header, records, next_start) catch return null;
                const continues = next.key == previous.key + 1 and
                    next.start > previous.start and
                    next.edge_id_base > previous.edge_id_base and
                    (next.edge_id_step == 0 or next.edge_id_step == header.key_run_edge_id_step);
                if (continues) {
                    const next_start_step = next.start - previous.start;
                    const next_edge_base_step = next.edge_id_base - previous.edge_id_base;
                    if (span_count == 1) {
                        start_step = next_start_step;
                        edge_id_base_step = next_edge_base_step;
                        span_count = 2;
                    } else if (next_start_step == start_step and next_edge_base_step == edge_id_base_step) {
                        span_count += 1;
                    } else {
                        best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                        span_start_index = run_index;
                        span_start = previous;
                        start_step = next_start_step;
                        edge_id_base_step = next_edge_base_step;
                        span_count = 2;
                    }
                } else {
                    best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                    span_start_index = run_index + 1;
                    span_start = next;
                    start_step = 0;
                    edge_id_base_step = 0;
                    span_count = 1;
                }
                previous = next;
                run_start = next_start;
                run_index += 1;
            }
            best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
            return best;
        }

        pub fn edgeIndexMaybeBetterDenseKeyRunSpan(current: ?EdgeIndexDenseKeyRunSpan, best_score: *u64, run_start: u64, first: EdgeIndexKeyRunRecord, count: u64, start_step: u64, edge_id_base_step: u64) ?EdgeIndexDenseKeyRunSpan {
            if (count < 2 or count > std.math.maxInt(u32)) return current;
            if (run_start > std.math.maxInt(u32)) return current;
            if (first.key == 0 or first.key > std.math.maxInt(u32)) return current;
            if (first.start > std.math.maxInt(u32)) return current;
            if (first.edge_id_base == 0 or first.edge_id_base > std.math.maxInt(u32)) return current;
            if (start_step == 0 or start_step > std.math.maxInt(u32)) return current;
            if (edge_id_base_step == 0 or edge_id_base_step > std.math.maxInt(u32)) return current;
            const score = count;
            if (score <= best_score.*) return current;
            best_score.* = score;
            return .{
                .run_start = run_start,
                .count = count,
                .key_base = first.key,
                .start_base = first.start,
                .start_step = start_step,
                .edge_id_base = first.edge_id_base,
                .edge_id_base_step = edge_id_base_step,
            };
        }

        pub fn edgeIndexNextRunStartForHeaderShape(header: EdgeIndexHeader, records: []const EdgeIndexRecord, run_start: usize) ?usize {
            if (!header.hasKeyRuns() or run_start >= records.len) return null;
            var index = run_start + 1;
            while (index < records.len and edgeIndexRecordContinuesRunForHeaderShape(header, records, run_start, index)) : (index += 1) {}
            return index;
        }

        pub fn edgeIndexRecordContinuesRunForHeaderShape(header: EdgeIndexHeader, records: []const EdgeIndexRecord, run_start: usize, index: usize) bool {
            if (!header.hasKeyRuns() or run_start >= records.len or index <= run_start or index >= records.len) return false;
            if (header.order == .id) {
                const previous = records[index - 1];
                const record = records[index];
                const expected_src = std.math.add(u64, previous.src, 1) catch return false;
                const expected_dst = std.math.add(u64, previous.dst, 1) catch return false;
                return record.src == expected_src and record.dst == expected_dst;
            }

            const key = edgeIndexRecordKey(records[run_start], header.order);
            if (key == 0 or key == std.math.maxInt(u64)) return false;
            if (edgeIndexRecordKey(records[index], header.order) != key) return false;
            if (header.hasKeyRunConstantOpposite()) {
                const run_opposite = edgeIndexRecordOpposite(records[run_start], header.order) orelse return false;
                const current_opposite = edgeIndexRecordOpposite(records[index], header.order) orelse return false;
                if (run_opposite == 0 or run_opposite == std.math.maxInt(u64)) return false;
                if (current_opposite != run_opposite) return false;
            }
            if (!header.hasKeyRunLinearEdgeIds()) return true;

            const base = records[run_start].edge_id;
            const current = records[index].edge_id;
            if (base == 0 or base == std.math.maxInt(u64)) return false;
            if (current == 0 or current == std.math.maxInt(u64)) return false;
            if (index == run_start + 1) return current > base;
            const second = records[run_start + 1].edge_id;
            if (second <= base or second == std.math.maxInt(u64)) return false;
            const step = second - base;
            const delta: u64 = @intCast(index - run_start);
            const scaled_delta = std.math.mul(u64, delta, step) catch return false;
            const expected = std.math.add(u64, base, scaled_delta) catch return false;
            return current == expected;
        }

        pub fn edgeIndexRunRecordForStart(header: EdgeIndexHeader, records: []const EdgeIndexRecord, run_start: usize) !EdgeIndexKeyRunRecord {
            if (!header.hasKeyRuns() or run_start >= records.len) return error.InvalidRecord;
            const record = records[run_start];
            if (header.order == .id) {
                return .{
                    .key = record.src,
                    .start = @intCast(run_start),
                    .opposite = record.dst,
                };
            }
            return .{
                .key = edgeIndexRecordKey(record, header.order),
                .start = @intCast(run_start),
                .opposite = if (header.hasKeyRunConstantOpposite()) edgeIndexRunOpposite(header.order, records, run_start) orelse return error.InvalidRecord else 0,
                .edge_id_base = if (header.hasKeyRunLinearEdgeIds()) record.edge_id else 0,
                .edge_id_step = if (header.hasKeyRunLinearEdgeIds()) edgeIndexRunEdgeIdStep(header, records, run_start) orelse return error.InvalidRecord else 0,
            };
        }

        pub fn edgeIndexRunCountForSortedRecords(order: EdgeIndexOrder, records: []const EdgeIndexRecord) ?u64 {
            if (order == .id or records.len == 0) return 0;
            var run_count: u64 = 1;
            var previous_key = edgeIndexRecordKey(records[0], order);
            if (previous_key == 0 or previous_key == std.math.maxInt(u64)) return null;
            for (records[1..]) |record| {
                const key = edgeIndexRecordKey(record, order);
                if (key == 0 or key == std.math.maxInt(u64)) return null;
                if (key < previous_key) return null;
                if (key != previous_key) {
                    run_count = std.math.add(u64, run_count, 1) catch return null;
                    previous_key = key;
                }
            }
            return run_count;
        }

        pub fn edgeIndexRunsHaveConstantOpposite(order: EdgeIndexOrder, records: []const EdgeIndexRecord) bool {
            if (order == .id or records.len == 0) return false;
            var previous_key = edgeIndexRecordKey(records[0], order);
            if (previous_key == 0 or previous_key == std.math.maxInt(u64)) return false;
            var run_opposite = edgeIndexRecordOpposite(records[0], order) orelse return false;
            if (run_opposite == 0 or run_opposite == std.math.maxInt(u64)) return false;
            for (records[1..]) |record| {
                const key = edgeIndexRecordKey(record, order);
                if (key == 0 or key == std.math.maxInt(u64) or key < previous_key) return false;
                const opposite = edgeIndexRecordOpposite(record, order) orelse return false;
                if (opposite == 0 or opposite == std.math.maxInt(u64)) return false;
                if (key != previous_key) {
                    previous_key = key;
                    run_opposite = opposite;
                } else if (opposite != run_opposite) {
                    return false;
                }
            }
            return true;
        }

        pub fn edgeIndexRunOpposite(order: EdgeIndexOrder, records: []const EdgeIndexRecord, run_start: usize) ?u64 {
            if (order == .id or run_start >= records.len) return null;
            return edgeIndexRecordOpposite(records[run_start], order);
        }

        pub fn edgeIndexRunEdgeIdStep(header: EdgeIndexHeader, records: []const EdgeIndexRecord, run_start: usize) ?u64 {
            if (header.order == .id or run_start >= records.len) return null;
            const key = edgeIndexRecordKey(records[run_start], header.order);
            if (key == 0 or key == std.math.maxInt(u64)) return null;
            if (run_start + 1 >= records.len) return 0;
            if (!edgeIndexRecordContinuesRunForHeaderShape(header, records, run_start, run_start + 1)) return 0;
            if (records[run_start + 1].edge_id <= records[run_start].edge_id) return null;
            return records[run_start + 1].edge_id - records[run_start].edge_id;
        }

        pub fn edgeIndexRecordOpposite(record: EdgeIndexRecord, order: EdgeIndexOrder) ?u64 {
            return switch (order) {
                .id => null,
                .src => record.dst,
                .dst => record.src,
            };
        }

        pub fn validateAdjacentEdgeIndexKeyRuns(header: EdgeIndexHeader, current: EdgeIndexKeyRunRecord, next: EdgeIndexKeyRunRecord) !void {
            if (next.start <= current.start) return error.InvalidRecord;
            if (header.order == .id) return;
            if (next.key < current.key) return error.InvalidRecord;
            if (next.key == current.key and !header.hasKeyRunLinearEdgeIds()) return error.InvalidRecord;
            if (next.key == current.key and header.hasKeyRunConstantOpposite() and next.opposite != current.opposite) return error.InvalidRecord;
            if (next.key == current.key and header.hasKeyRunLinearEdgeIds()) {
                if (current.edge_id_step != 0) {
                    const last_delta = next.start - current.start - 1;
                    const last_scaled_delta = std.math.mul(u64, last_delta, current.edge_id_step) catch return error.InvalidRecord;
                    const last_edge_id = std.math.add(u64, current.edge_id_base, last_scaled_delta) catch return error.InvalidRecord;
                    if (next.edge_id_base >= current.edge_id_base and next.edge_id_base <= last_edge_id) {
                        const offset = next.edge_id_base - current.edge_id_base;
                        if (offset % current.edge_id_step == 0) return error.InvalidRecord;
                    }
                } else if (next.edge_id_base == current.edge_id_base) {
                    return error.InvalidRecord;
                }
            }
        }

        pub fn nodeTextLenFitsU16(text_len: usize) bool {
            return text_len != 0 and text_len <= std.math.maxInt(u16);
        }

        pub fn nodeRecordHasShortTextLen(record: NodeByIdRecord) bool {
            return record.id == 0 or record.text_len <= std.math.maxInt(u16);
        }

        pub const edge_index_rel_kind_count = schema.max_relation_types;

        pub fn edgeIndexDefaultRelFromCounts(counts: [edge_index_rel_kind_count]u64, total: u64) ?u16 {
            if (total == 0) return null;
            var best_index: usize = 0;
            var best_count: u64 = 0;
            for (counts, 0..) |count, index| {
                if (count > best_count) {
                    best_count = count;
                    best_index = index;
                }
            }
            if (best_count == 0 or total - best_count > 2) return null;
            const best_rel: u16 = @intCast(best_index);
            if (relKindFromInt(best_rel) == null) return null;
            return best_rel;
        }

        pub fn edgeIndexRelDerivationAddException(derivation: *EdgeIndexRelDerivation, edge_id: u64, rel: u16) bool {
            if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return false;
            if (relKindFromInt(rel) == null or rel == derivation.default_rel) return false;
            if (derivation.exception_count >= derivation.exception_edge_ids.len) return false;
            var insert_at: usize = derivation.exception_count;
            var pos: usize = 0;
            while (pos < derivation.exception_count) : (pos += 1) {
                const existing_id = derivation.exception_edge_ids[pos];
                if (edge_id == existing_id) return false;
                if (edge_id < existing_id) {
                    insert_at = pos;
                    break;
                }
            }
            var move_pos: usize = derivation.exception_count;
            while (move_pos > insert_at) : (move_pos -= 1) {
                derivation.exception_edge_ids[move_pos] = derivation.exception_edge_ids[move_pos - 1];
                derivation.exception_rels[move_pos] = derivation.exception_rels[move_pos - 1];
            }
            derivation.exception_edge_ids[insert_at] = edge_id;
            derivation.exception_rels[insert_at] = rel;
            derivation.exception_count += 1;
            return true;
        }

        pub fn edgeRecordsDerivedRel(records: []const EdgeIndexRecord) ?EdgeIndexRelDerivation {
            var counts: [edge_index_rel_kind_count]u64 = [_]u64{0} ** edge_index_rel_kind_count;
            for (records) |record| {
                const rel_kind = relKindFromInt(record.rel) orelse return null;
                counts[@intFromEnum(rel_kind)] += 1;
            }
            const default_rel = edgeIndexDefaultRelFromCounts(counts, @intCast(records.len)) orelse return null;
            var derivation = EdgeIndexRelDerivation{ .default_rel = default_rel };
            for (records) |record| {
                if (record.rel != default_rel and !edgeIndexRelDerivationAddException(&derivation, record.edge_id, record.rel)) return null;
            }
            return derivation;
        }

        pub fn edgeRecordsExtendDerivedRel(header: EdgeIndexHeader, records: []const EdgeIndexRecord) ?EdgeIndexRelDerivation {
            if (!header.hasDerivedRel()) return null;
            var derivation = EdgeIndexRelDerivation{
                .default_rel = header.default_rel,
                .exception_count = header.rel_exception_count,
                .exception_edge_ids = header.rel_exception_edge_ids,
                .exception_rels = header.rel_exception_rels,
            };
            for (records) |record| {
                if (record.rel == derivation.default_rel) continue;
                var existing = false;
                var pos: usize = 0;
                while (pos < derivation.exception_count) : (pos += 1) {
                    if (record.edge_id == derivation.exception_edge_ids[pos]) {
                        if (record.rel != derivation.exception_rels[pos]) return null;
                        existing = true;
                        break;
                    }
                }
                if (!existing and !edgeIndexRelDerivationAddException(&derivation, record.edge_id, record.rel)) return null;
            }
            return derivation;
        }

        pub fn edgeIndexRelDerivationWithoutRecord(header: EdgeIndexHeader, removed: EdgeIndexRecord, next_count: u64) ?EdgeIndexRelDerivation {
            if (!header.hasDerivedRel() or next_count == 0) return null;
            var derivation = EdgeIndexRelDerivation{
                .default_rel = header.default_rel,
                .exception_count = 0,
            };
            var pos: usize = 0;
            while (pos < header.rel_exception_count) : (pos += 1) {
                if (header.rel_exception_edge_ids[pos] == removed.edge_id) continue;
                if (!edgeIndexRelDerivationAddException(&derivation, header.rel_exception_edge_ids[pos], header.rel_exception_rels[pos])) return null;
            }
            return derivation;
        }

        pub fn edgeIndexRecordToSegmentEdge(record: EdgeIndexRecord) !segment_mod.EdgeRecord {
            return .{
                .src = core.NodeId.fromInt(record.src),
                .dst = core.NodeId.fromInt(record.dst),
                .edge_id = core.EdgeId.fromInt(record.edge_id),
                .rel = try record.relKind(),
            };
        }

        pub const EdgeIndexRecordReader = struct {
            store: Store,
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            header: EdgeIndexHeader,
            edge_count: u64,

            pub fn deinit(self: *EdgeIndexRecordReader) void {
                if (self.map) |*map| map.destroy(self.store.io);
                self.file.close(self.store.io);
            }

            pub fn read(self: *EdgeIndexRecordReader, index: u64) !EdgeIndexRecord {
                if (index >= self.edge_count) return error.InvalidRecord;
                if (self.map) |*map| return store_plane.readEdgeIndexRecordFromMap(self.header, map, index);
                return store_plane.readEdgeIndexRecordAt(self.store, self.file, self.header, index);
            }
        };

        pub fn edgeIndexReaderRecordToSegmentEdge(reader: *EdgeIndexRecordReader, index: u64) !segment_mod.EdgeRecord {
            return edgeIndexRecordToSegmentEdge(try reader.read(index));
        }

        pub const StoreTextsFileStream = struct {
            allocator: std.mem.Allocator,
            texts: NodeTextsView,
            buffer: []u8,
            size: u64,
            offset: u64 = 0,

            pub fn init(allocator: std.mem.Allocator, store: Store) !StoreTextsFileStream {
                var texts = try NodeTextsView.open(store);
                errdefer texts.deinit();
                if (texts.size == 0) return error.InvalidRecord;
                return .{
                    .allocator = allocator,
                    .texts = texts,
                    .buffer = try allocator.alloc(u8, try storageWriteBufferCapacity(texts.size)),
                    .size = texts.size,
                };
            }

            pub fn deinit(self: *StoreTextsFileStream) void {
                self.allocator.free(self.buffer);
                self.texts.deinit();
            }

            pub fn reset(self: *StoreTextsFileStream) !void {
                self.offset = 0;
            }

            pub fn next(self: *StoreTextsFileStream) !?[]const u8 {
                if (self.offset >= self.size) return null;
                const remaining = self.size - self.offset;
                const want = @min(self.buffer.len, std.math.cast(usize, remaining) orelse self.buffer.len);
                try self.texts.readInto(self.offset, self.buffer[0..want]);
                self.offset = std.math.add(u64, self.offset, want) catch return error.RecordTooLarge;
                return self.buffer[0..want];
            }
        };

        pub const StoreCatalogByIdStream = struct {
            view: NodeByIdIndexView,
            next_id: u64 = 1,
            seen_nodes: u64 = 0,

            pub fn init(store: Store, meta: IndexMeta) !StoreCatalogByIdStream {
                return .{ .view = try NodeByIdIndexView.open(store, meta) };
            }

            pub fn deinit(self: *StoreCatalogByIdStream) void {
                self.view.deinit();
            }

            pub fn reset(self: *StoreCatalogByIdStream) !void {
                self.next_id = 1;
                self.seen_nodes = 0;
            }

            pub fn next(self: *StoreCatalogByIdStream) !?segment_node_index.CatalogRecord {
                while (self.next_id <= self.view.max_node_id) : (self.next_id += 1) {
                    const id = self.next_id;
                    const record = try self.view.readRecord(id);
                    if (record.id == 0) continue;
                    if (record.id != id) return error.InvalidRecord;
                    if (self.seen_nodes >= self.view.node_count) return error.InvalidRecord;
                    self.seen_nodes += 1;
                    self.next_id += 1;
                    return try nodeByIdRecordToCatalogRecord(record);
                }
                if (self.seen_nodes != self.view.node_count) return error.InvalidRecord;
                return null;
            }
        };

        pub const StoreEdgeRecordStream = struct {
            reader: *EdgeIndexRecordReader,
            tombstones: ?*EdgeTombstoneIndexView = null,
            pos: u64 = 0,

            pub fn reset(self: *StoreEdgeRecordStream) !void {
                self.pos = 0;
            }

            pub fn next(self: *StoreEdgeRecordStream) !?segment_mod.EdgeRecord {
                while (self.pos < self.reader.edge_count) {
                    const edge = try edgeIndexReaderRecordToSegmentEdge(self.reader, self.pos);
                    self.pos += 1;
                    if (self.tombstones) |tombstones| {
                        if (try tombstones.contains(edge.edge_id.toInt())) continue;
                    }
                    return edge;
                }
                return null;
            }
        };

        pub const EdgeSortedRunStream = struct {
            allocator: std.mem.Allocator,
            store: Store,
            order: EdgeIndexOrder,
            run_paths: []const []u8,
            readers: std.ArrayList(EdgeRepairRunReader) = .empty,
            queue: std.PriorityQueue(EdgeRepairRunHeapEntry, EdgeRepairRunHeapContext, compareEdgeRepairRunHeapEntry),

            pub fn init(
                allocator: std.mem.Allocator,
                store: Store,
                order: EdgeIndexOrder,
                run_paths: []const []u8,
            ) EdgeSortedRunStream {
                return .{
                    .allocator = allocator,
                    .store = store,
                    .order = order,
                    .run_paths = run_paths,
                    .queue = std.PriorityQueue(EdgeRepairRunHeapEntry, EdgeRepairRunHeapContext, compareEdgeRepairRunHeapEntry).initContext(.{ .order = order }),
                };
            }

            pub fn deinit(self: *EdgeSortedRunStream) void {
                self.clearReaders();
                self.readers.deinit(self.allocator);
                self.queue.deinit(self.allocator);
            }

            pub fn clearReaders(self: *EdgeSortedRunStream) void {
                for (self.readers.items) |*reader| reader.deinit(self.allocator, self.store.io);
                self.readers.clearRetainingCapacity();
            }

            pub fn reset(self: *EdgeSortedRunStream) !void {
                self.clearReaders();
                self.queue.deinit(self.allocator);
                self.queue = std.PriorityQueue(EdgeRepairRunHeapEntry, EdgeRepairRunHeapContext, compareEdgeRepairRunHeapEntry).initContext(.{ .order = self.order });
                try self.readers.ensureTotalCapacityPrecise(self.allocator, self.run_paths.len);
                try self.queue.ensureTotalCapacityPrecise(self.allocator, self.run_paths.len);

                for (self.run_paths) |run_path| {
                    var run_file = try std.Io.Dir.cwd().openFile(self.store.io, run_path, .{});
                    var close_run_file = true;
                    errdefer if (close_run_file) run_file.close(self.store.io);
                    const run_size = try store_plane.regularFileSize(self.store, run_file);
                    if (run_size == 0 or run_size % EdgeIndexRecord.encoded_len != 0) return error.InvalidRecord;
                    const run_count = run_size / EdgeIndexRecord.encoded_len;
                    var map = store_plane.openReadOnlyMemoryMap(self.store.io, run_file, run_size) catch null;
                    errdefer if (map) |*mapped| mapped.destroy(self.store.io);
                    var buffer: []u8 = &.{};
                    errdefer self.allocator.free(buffer);
                    if (map == null) {
                        buffer = try self.allocator.alloc(u8, try storageWriteBufferCapacity(run_size));
                    }
                    const reader_index = self.readers.items.len;
                    self.readers.appendAssumeCapacity(.{
                        .file = run_file,
                        .map = map,
                        .next_index = 0,
                        .count = run_count,
                        .buffer = buffer,
                    });
                    close_run_file = false;
                    map = null;
                    buffer = &.{};
                    const record = (try self.readers.items[reader_index].next(self.store)) orelse return error.InvalidRecord;
                    try self.queue.push(self.allocator, .{ .run_index = reader_index, .record = record });
                }
            }

            pub fn next(self: *EdgeSortedRunStream) !?segment_mod.EdgeRecord {
                const entry = self.queue.pop() orelse return null;
                const reader = &self.readers.items[entry.run_index];
                if (try reader.next(self.store)) |record| {
                    try self.queue.push(self.allocator, .{ .run_index = entry.run_index, .record = record });
                }
                return try edgeIndexRecordToSegmentEdge(entry.record);
            }
        };

        pub const EdgeSortedRecordSliceStream = struct {
            records: []const EdgeIndexRecord,
            pos: usize = 0,

            pub fn init(records: []const EdgeIndexRecord) EdgeSortedRecordSliceStream {
                return .{ .records = records };
            }

            pub fn reset(self: *EdgeSortedRecordSliceStream) !void {
                self.pos = 0;
            }

            pub fn next(self: *EdgeSortedRecordSliceStream) !?segment_mod.EdgeRecord {
                if (self.pos >= self.records.len) return null;
                const record = self.records[self.pos];
                self.pos += 1;
                return try edgeIndexRecordToSegmentEdge(record);
            }
        };

        pub const EdgeSortedRecordOrderStream = struct {
            records: []const EdgeIndexRecord,
            order: []const u32,
            pos: usize = 0,

            pub fn init(records: []const EdgeIndexRecord, order: []const u32) EdgeSortedRecordOrderStream {
                return .{ .records = records, .order = order };
            }

            pub fn reset(self: *EdgeSortedRecordOrderStream) !void {
                self.pos = 0;
            }

            pub fn next(self: *EdgeSortedRecordOrderStream) !?segment_mod.EdgeRecord {
                if (self.pos >= self.order.len) return null;
                const index = self.order[self.pos];
                self.pos += 1;
                if (index >= self.records.len) return error.InvalidRecord;
                return try edgeIndexRecordToSegmentEdge(self.records[@intCast(index)]);
            }
        };

        pub const StoreSegmentBundleExactRuns = struct {
            allocator: std.mem.Allocator,
            store: Store,
            paths: std.ArrayList([]u8) = .empty,

            pub fn build(store: Store, root_dir: []const u8, meta: IndexMeta) !StoreSegmentBundleExactRuns {
                var runs = StoreSegmentBundleExactRuns{
                    .allocator = store.allocator,
                    .store = store,
                };
                errdefer runs.deinit();

                var texts = try NodeTextsView.open(store);
                defer texts.deinit();
                var by_id = try StoreCatalogByIdStream.init(store, meta);
                defer by_id.deinit();
                var chunk = SegmentBundleExactSortChunk{};
                defer chunk.deinit(store.allocator);
                try chunk.ensureTotalCapacityPrecise(store.allocator, segment_bundle_exact_sort_chunk_records);

                while (try by_id.next()) |record| {
                    try chunk.append(store.allocator, &texts, record);
                    if (chunk.entries.items.len == segment_bundle_exact_sort_chunk_records) try runs.flush(root_dir, &chunk);
                }
                try runs.flush(root_dir, &chunk);
                if (runs.paths.items.len == 0) return error.InvalidRecord;
                return runs;
            }

            pub fn deinit(self: *StoreSegmentBundleExactRuns) void {
                for (self.paths.items) |path| {
                    std.Io.Dir.cwd().deleteFile(self.store.io, path) catch {};
                    self.allocator.free(path);
                }
                self.paths.deinit(self.allocator);
            }

            pub fn flush(self: *StoreSegmentBundleExactRuns, root_dir: []const u8, chunk: *SegmentBundleExactSortChunk) !void {
                if (chunk.entries.items.len == 0) return;
                std.mem.sort(SegmentBundleExactSortEntry, chunk.entries.items, chunk.texts.items, segmentBundleExactSortEntryLessThan);
                for (chunk.entries.items[1..], chunk.entries.items[0 .. chunk.entries.items.len - 1]) |entry, previous| {
                    if (!segmentBundleExactSortEntryLessThan(chunk.texts.items, previous, entry)) return error.InvalidRecord;
                }

                const run_path = try std.fmt.allocPrint(self.allocator, "{s}/.segment-bundle-exact-{d}.tmp", .{ root_dir, self.paths.items.len });
                var run_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.store.io, run_path) catch {};
                    if (run_path_owned) self.allocator.free(run_path);
                }

                try writeSegmentBundleExactRunFile(self.allocator, self.store.io, run_path, chunk.entries.items);
                try self.paths.append(self.allocator, run_path);
                run_path_owned = false;

                chunk.clearRetainingCapacity();
                try chunk.ensureTotalCapacityPrecise(self.allocator, segment_bundle_exact_sort_chunk_records);
            }
        };

        pub const SegmentBundleExactSortChunk = struct {
            entries: std.ArrayList(SegmentBundleExactSortEntry) = .empty,
            texts: std.ArrayList(u8) = .empty,

            pub fn deinit(self: *SegmentBundleExactSortChunk, allocator: std.mem.Allocator) void {
                self.texts.deinit(allocator);
                self.entries.deinit(allocator);
            }

            pub fn ensureTotalCapacityPrecise(self: *SegmentBundleExactSortChunk, allocator: std.mem.Allocator, entry_count: usize) !void {
                try self.entries.ensureTotalCapacityPrecise(allocator, entry_count);
            }

            pub fn append(
                self: *SegmentBundleExactSortChunk,
                allocator: std.mem.Allocator,
                texts_view: *const NodeTextsView,
                record: segment_node_index.CatalogRecord,
            ) !void {
                const span = try appendSegmentBundleExactSortText(allocator, texts_view, record, &self.texts);
                errdefer self.texts.shrinkRetainingCapacity(span.offset);
                try self.entries.append(allocator, .{
                    .record = record,
                    .text_offset = span.offset,
                    .text_len = span.len,
                });
            }

            pub fn clearRetainingCapacity(self: *SegmentBundleExactSortChunk) void {
                self.entries.clearRetainingCapacity();
                self.texts.clearRetainingCapacity();
            }
        };

        pub const SegmentBundleExactSortEntry = struct {
            record: segment_node_index.CatalogRecord,
            text_offset: usize,
            text_len: usize,
        };

        pub fn segmentBundleExactSortEntryLessThan(texts: []const u8, left: SegmentBundleExactSortEntry, right: SegmentBundleExactSortEntry) bool {
            const kind_order = std.math.order(@intFromEnum(left.record.kind), @intFromEnum(right.record.kind));
            if (kind_order != .eq) return kind_order == .lt;
            const text_order = std.mem.order(u8, segmentBundleExactSortText(texts, left), segmentBundleExactSortText(texts, right));
            if (text_order != .eq) return text_order == .lt;
            return left.record.id.toInt() < right.record.id.toInt();
        }

        pub fn segmentBundleExactSortText(texts: []const u8, entry: SegmentBundleExactSortEntry) []const u8 {
            return texts[entry.text_offset .. entry.text_offset + entry.text_len];
        }

        pub const SegmentBundleExactTextSpan = struct {
            offset: usize,
            len: usize,
        };

        pub fn appendSegmentBundleExactSortText(
            allocator: std.mem.Allocator,
            texts: *const NodeTextsView,
            record: segment_node_index.CatalogRecord,
            out: *std.ArrayList(u8),
        ) !SegmentBundleExactTextSpan {
            const len = std.math.cast(usize, record.text_len) orelse return error.RecordTooLarge;
            const offset = out.items.len;
            const end = std.math.add(usize, offset, len) catch return error.RecordTooLarge;
            if (try texts.mappedBytes(record.text_offset, record.text_len)) |bytes| {
                try out.appendSlice(allocator, bytes);
            } else {
                try out.resize(allocator, end);
                errdefer out.shrinkRetainingCapacity(offset);
                const dst = out.items[offset..end];
                try texts.readInto(record.text_offset, dst);
            }
            const text = out.items[offset..end];
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidRecord;
            return .{ .offset = offset, .len = len };
        }

        pub fn nodeByIdRecordToCatalogRecord(record: NodeByIdRecord) !segment_node_index.CatalogRecord {
            return .{
                .id = core.NodeId.fromInt(record.id),
                .kind = try record.nodeKind(),
                .text_offset = record.text_offset,
                .text_len = record.text_len,
            };
        }

        pub fn readSegmentBundleExactTextIntoBuffer(
            allocator: std.mem.Allocator,
            texts: *const NodeTextsView,
            record: segment_node_index.CatalogRecord,
            out: *std.ArrayList(u8),
        ) !void {
            const len = std.math.cast(usize, record.text_len) orelse return error.RecordTooLarge;
            out.clearRetainingCapacity();
            try out.resize(allocator, len);
            errdefer out.clearRetainingCapacity();
            try readSegmentBundleExactTextIntoSlice(texts, record, out.items);
        }

        pub fn readSegmentBundleExactTextIntoSlice(
            texts: *const NodeTextsView,
            record: segment_node_index.CatalogRecord,
            text: []u8,
        ) !void {
            if (text.len != record.text_len) return error.InvalidRecord;
            if (try texts.mappedBytes(record.text_offset, record.text_len)) |bytes| {
                @memcpy(text, bytes);
            } else {
                try texts.readInto(record.text_offset, text);
            }
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidRecord;
        }

        pub fn writeSegmentBundleExactRunFile(
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []const u8,
            entries: []const SegmentBundleExactSortEntry,
        ) !void {
            const file_size = std.math.mul(u64, entries.len, SegmentBundleExactRunRecord.encoded_len) catch return error.RecordTooLarge;
            var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
            defer file.close(io);
            var writer = try StorageBufferedWriter.init(allocator, io, file, try storageWriteBufferCapacity(file_size));
            defer writer.deinit();
            var bytes: [SegmentBundleExactRunRecord.encoded_len]u8 = undefined;
            for (entries) |entry| {
                SegmentBundleExactRunRecord.encode(entry.record, &bytes);
                try writer.append(&bytes);
            }
            try writer.flush();
            try file.sync(io);
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != file_size) return error.InvalidRecord;
        }

        pub const SegmentBundleExactRunRecord = struct {
            const encoded_len: usize = 32;

            pub fn encode(record: segment_node_index.CatalogRecord, out: *[encoded_len]u8) void {
                std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
                std.mem.writeInt(u16, out[8..10], @intFromEnum(record.kind), .little);
                @memset(out[10..16], 0);
                std.mem.writeInt(u64, out[16..24], record.text_offset, .little);
                std.mem.writeInt(u32, out[24..28], record.text_len, .little);
                @memset(out[28..32], 0);
            }

            pub fn decode(bytes: []const u8) !segment_node_index.CatalogRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (!allZero(bytes[10..16]) or !allZero(bytes[28..32])) return error.InvalidRecord;
                const id = std.mem.readInt(u64, bytes[0..8], .little);
                const kind_int = std.mem.readInt(u16, bytes[8..10], .little);
                const text_offset = std.mem.readInt(u64, bytes[16..24], .little);
                const text_len = std.mem.readInt(u32, bytes[24..28], .little);
                if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                return .{
                    .id = core.NodeId.fromInt(id),
                    .kind = nodeKindFromInt(kind_int) orelse return error.InvalidRecord,
                    .text_offset = text_offset,
                    .text_len = text_len,
                };
            }
        };

        pub const SegmentBundleExactRunReader = struct {
            store: Store,
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            count: u64,
            pos: u64 = 0,

            pub fn open(store: Store, path: []const u8) !SegmentBundleExactRunReader {
                var file = try std.Io.Dir.cwd().openFile(store.io, path, .{});
                errdefer file.close(store.io);
                const stat = try file.stat(store.io);
                if (stat.kind != .file or stat.size == 0 or stat.size % SegmentBundleExactRunRecord.encoded_len != 0) return error.InvalidRecord;
                var map = store_plane.openReadOnlyMemoryMap(store.io, file, stat.size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(store.io);
                return .{
                    .store = store,
                    .file = file,
                    .map = map,
                    .count = stat.size / SegmentBundleExactRunRecord.encoded_len,
                };
            }

            pub fn deinit(self: *SegmentBundleExactRunReader) void {
                if (self.map) |*map| map.destroy(self.store.io);
                self.file.close(self.store.io);
            }

            pub fn next(self: *SegmentBundleExactRunReader) !?segment_node_index.CatalogRecord {
                if (self.pos >= self.count) return null;
                const offset = std.math.mul(u64, self.pos, SegmentBundleExactRunRecord.encoded_len) catch return error.RecordTooLarge;
                self.pos += 1;
                if (self.map) |*map| {
                    const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                    const end = std.math.add(usize, start, SegmentBundleExactRunRecord.encoded_len) catch return error.InvalidRecord;
                    if (end > map.memory.len) return error.InvalidRecord;
                    return try SegmentBundleExactRunRecord.decode(map.memory[start..end]);
                }
                var bytes: [SegmentBundleExactRunRecord.encoded_len]u8 = undefined;
                if (try self.file.readPositionalAll(self.store.io, &bytes, offset) != bytes.len) return error.InvalidRecord;
                return try SegmentBundleExactRunRecord.decode(&bytes);
            }
        };

        pub const StoreSegmentBundleExactStream = struct {
            allocator: std.mem.Allocator,
            store: Store,
            run_paths: []const []u8,
            merger: ?SegmentBundleExactRunMerger = null,

            pub fn init(allocator: std.mem.Allocator, store: Store, run_paths: []const []u8) StoreSegmentBundleExactStream {
                return .{ .allocator = allocator, .store = store, .run_paths = run_paths };
            }

            pub fn deinit(self: *StoreSegmentBundleExactStream) void {
                if (self.merger) |*merger| merger.deinit();
            }

            pub fn reset(self: *StoreSegmentBundleExactStream) !void {
                if (self.merger) |*merger| merger.deinit();
                self.merger = null;
                self.merger = try SegmentBundleExactRunMerger.init(self.allocator, self.store, self.run_paths);
            }

            pub fn next(self: *StoreSegmentBundleExactStream) !?segment_node_index.CatalogRecord {
                if (self.merger == null) try self.reset();
                return try self.merger.?.next();
            }
        };

        pub const SegmentBundleExactCurrent = struct {
            record: segment_node_index.CatalogRecord,
            text: std.ArrayList(u8) = .empty,
        };

        pub const SegmentBundleExactRunMerger = struct {
            allocator: std.mem.Allocator,
            store: Store,
            texts: NodeTextsView,
            readers: std.ArrayList(SegmentBundleExactRunReader),
            current: std.ArrayList(SegmentBundleExactCurrent),
            queue: std.PriorityQueue(usize, []const SegmentBundleExactCurrent, compareSegmentBundleExactRunIndex),

            pub fn init(allocator: std.mem.Allocator, store: Store, run_paths: []const []u8) !SegmentBundleExactRunMerger {
                var texts = try NodeTextsView.open(store);
                errdefer texts.deinit();
                var readers = std.ArrayList(SegmentBundleExactRunReader).empty;
                errdefer {
                    for (readers.items) |*reader| reader.deinit();
                    readers.deinit(allocator);
                }
                var current = std.ArrayList(SegmentBundleExactCurrent).empty;
                errdefer {
                    for (current.items) |*entry| entry.text.deinit(allocator);
                    current.deinit(allocator);
                }
                try readers.ensureTotalCapacityPrecise(allocator, run_paths.len);
                try current.ensureTotalCapacityPrecise(allocator, run_paths.len);

                for (run_paths) |path| {
                    var reader = try SegmentBundleExactRunReader.open(store, path);
                    errdefer reader.deinit();
                    const record = (try reader.next()) orelse return error.InvalidRecord;
                    var text = std.ArrayList(u8).empty;
                    errdefer text.deinit(allocator);
                    try readSegmentBundleExactTextIntoBuffer(allocator, &texts, record, &text);
                    readers.appendAssumeCapacity(reader);
                    current.appendAssumeCapacity(.{ .record = record, .text = text });
                    text = .empty;
                }

                var queue = std.PriorityQueue(usize, []const SegmentBundleExactCurrent, compareSegmentBundleExactRunIndex).initContext(current.items);
                errdefer queue.deinit(allocator);
                try queue.ensureTotalCapacityPrecise(allocator, current.items.len);
                for (current.items, 0..) |_, index| {
                    try queue.push(allocator, index);
                }

                return .{
                    .allocator = allocator,
                    .store = store,
                    .texts = texts,
                    .readers = readers,
                    .current = current,
                    .queue = queue,
                };
            }

            pub fn deinit(self: *SegmentBundleExactRunMerger) void {
                self.queue.deinit(self.allocator);
                for (self.current.items) |*entry| entry.text.deinit(self.allocator);
                self.current.deinit(self.allocator);
                for (self.readers.items) |*reader| reader.deinit();
                self.readers.deinit(self.allocator);
                self.texts.deinit();
            }

            pub fn next(self: *SegmentBundleExactRunMerger) !?segment_node_index.CatalogRecord {
                const reader_index = self.queue.pop() orelse return null;
                const out = self.current.items[reader_index].record;
                if (try self.readers.items[reader_index].next()) |record| {
                    self.current.items[reader_index].record = record;
                    try readSegmentBundleExactTextIntoBuffer(self.allocator, &self.texts, record, &self.current.items[reader_index].text);
                    try self.queue.push(self.allocator, reader_index);
                } else {
                    self.current.items[reader_index].text.clearRetainingCapacity();
                }
                return out;
            }
        };

        pub fn compareSegmentBundleExactRunIndex(records: []const SegmentBundleExactCurrent, lhs: usize, rhs: usize) std.math.Order {
            const left = records[lhs];
            const right = records[rhs];
            const kind_order = std.math.order(@intFromEnum(left.record.kind), @intFromEnum(right.record.kind));
            if (kind_order != .eq) return kind_order;
            const text_order = std.mem.order(u8, left.text.items, right.text.items);
            if (text_order != .eq) return text_order;
            return std.math.order(left.record.id.toInt(), right.record.id.toInt());
        }

        pub const EdgeSegmentManifestEntry = edge_segment_manifest_format.Entry;

        pub const EdgeSegmentIdSidecarSummary = struct {
            edge_id_order_digest: u64,
            edge_id_runs: EdgeSegmentIdRunSummary,
        };

        pub const EdgeSegmentManifestSummary = struct {
            total_edges: u64,
            manifest_digest: u64,
            edge_id_runs: EdgeSegmentIdRunSummary,
        };

        pub const EdgeSegmentIdRunRange = struct {
            min: u64,
            max: u64,
        };

        pub fn edgeSegmentIdRunRangeLessThan(_: void, lhs: EdgeSegmentIdRunRange, rhs: EdgeSegmentIdRunRange) bool {
            if (lhs.min != rhs.min) return lhs.min < rhs.min;
            return lhs.max < rhs.max;
        }

        pub fn appendEdgeSegmentManifestRunRangeSorted(
            builder: *EdgeSegmentIdRunBuilder,
            has_previous: *bool,
            previous_max: *u64,
            min: u64,
            max: u64,
        ) bool {
            if (has_previous.* and min <= previous_max.*) return false;
            builder.addRange(min, max);
            previous_max.* = max;
            has_previous.* = true;
            return true;
        }

        pub const EdgeSegmentIdRunBuilder = struct {
            summary: EdgeSegmentIdRunSummary = .{},
            previous: u64 = 0,
            overflow: bool = false,

            pub fn add(self: *EdgeSegmentIdRunBuilder, edge_id: u64) void {
                if (self.overflow) return;
                if (self.summary.run_count == 0) {
                    self.summary.run_count = 1;
                    self.summary.first_min = edge_id;
                    self.summary.first_max = edge_id;
                    self.previous = edge_id;
                    return;
                }
                if (self.previous != std.math.maxInt(u64) and edge_id == self.previous + 1) {
                    if (self.summary.run_count == 1) {
                        self.summary.first_max = edge_id;
                    } else {
                        self.summary.second_max = edge_id;
                    }
                    self.previous = edge_id;
                    return;
                }
                if (self.summary.run_count == 1) {
                    self.summary.run_count = 2;
                    self.summary.second_min = edge_id;
                    self.summary.second_max = edge_id;
                    self.previous = edge_id;
                    return;
                }
                self.overflow = true;
            }

            pub fn addRange(self: *EdgeSegmentIdRunBuilder, min: u64, max: u64) void {
                if (self.overflow) return;
                if (min > max) {
                    self.overflow = true;
                    return;
                }
                if (self.summary.run_count == 0) {
                    self.summary.run_count = 1;
                    self.summary.first_min = min;
                    self.summary.first_max = max;
                    self.previous = max;
                    return;
                }
                if (min <= self.previous) {
                    self.overflow = true;
                    return;
                }
                if (self.previous != std.math.maxInt(u64) and min == self.previous + 1) {
                    if (self.summary.run_count == 1) {
                        self.summary.first_max = max;
                    } else {
                        self.summary.second_max = max;
                    }
                    self.previous = max;
                    return;
                }
                if (self.summary.run_count == 1) {
                    self.summary.run_count = 2;
                    self.summary.second_min = min;
                    self.summary.second_max = max;
                    self.previous = max;
                    return;
                }
                self.overflow = true;
            }

            pub fn finish(self: EdgeSegmentIdRunBuilder) EdgeSegmentIdRunSummary {
                if (self.overflow) return .{};
                return self.summary;
            }
        };

        pub const OwnedEdgeSegmentManifestEntry = edge_segment_manifest_format.OwnedEntry;
        pub const EdgeSegmentManifest = edge_segment_manifest_format.Manifest;
        pub const edge_segment_manifest_run_from_range = edge_segment_manifest_format.run_from_range;
        pub const edge_segment_manifest_run_two_split = edge_segment_manifest_format.run_two_split;
        pub const edge_segment_manifest_src_single = edge_segment_manifest_format.src_single;
        pub const edge_segment_manifest_src_full = edge_segment_manifest_format.src_full;
        pub const edge_segment_manifest_dst_single = edge_segment_manifest_format.dst_single;
        pub const edge_segment_manifest_dst_full = edge_segment_manifest_format.dst_full;
        pub const edge_segment_manifest_edge_digest_explicit = edge_segment_manifest_format.edge_digest_explicit;
        pub const edge_segment_manifest_edge_count_explicit = edge_segment_manifest_format.edge_count_explicit;
        pub const edge_segment_manifest_order_digest_explicit = edge_segment_manifest_format.order_digest_explicit;
        pub const edge_segment_manifest_path_relative = edge_segment_manifest_format.path_relative;
        pub const edge_segment_manifest_virtual_singleton = edge_segment_manifest_format.virtual_singleton;
        pub const EdgeSegmentManifestRunEncoding = edge_segment_manifest_format.RunEncoding;
        pub const EdgeSegmentManifestEndpointEncoding = edge_segment_manifest_format.EndpointEncoding;
        pub const EdgeSegmentManifestPathEncoding = edge_segment_manifest_format.PathEncoding;
        pub const edgeSegmentManifestSafeRelativePath = edge_segment_manifest_format.safeRelativePath;

        pub fn processIdIsAlive(pid: ProcessId) bool {
            return process_liveness.isAlive(pid);
        }

        pub fn freeOwnedManifestPathList(allocator: std.mem.Allocator, paths: []const []const u8) void {
            for (paths) |path| allocator.free(path);
            allocator.free(paths);
        }

        pub const edgeSegmentManifestEntryMayContainNode = edge_segment_manifest_format.entryMayContainNode;
        pub const edgeSegmentManifestEntryIsVirtual = edge_segment_manifest_format.entryIsVirtual;

        pub fn edgeSegmentManifestVirtualRunEdgeAt(entry: anytype, index: u64) !segment_mod.EdgeRecord {
            const rel = entry.singleton_rel orelse return error.InvalidRecord;
            if (entry.path.len != 0) return error.InvalidRecord;
            if (index >= entry.edge_count) return error.InvalidRecord;
            if (entry.edge_id_range.min == 0 or entry.edge_id_range.max == std.math.maxInt(u64)) return error.InvalidRecord;
            if (entry.src_node_range.min == 0 or entry.src_node_range.max == std.math.maxInt(u64)) return error.InvalidRecord;
            if (entry.dst_node_range.min == 0 or entry.dst_node_range.max == std.math.maxInt(u64)) return error.InvalidRecord;
            if (entry.src_node_range.min != entry.src_node_range.max) return error.InvalidRecord;
            if (try edgeSegmentManifestRangeCount(entry.edge_id_range) != entry.edge_count) return error.InvalidRecord;
            if (try nodeIdRangeCount(entry.dst_node_range) != entry.edge_count) return error.InvalidRecord;
            const edge_id = std.math.add(u64, entry.edge_id_range.min, index) catch return error.InvalidRecord;
            const dst = std.math.add(u64, entry.dst_node_range.min, index) catch return error.InvalidRecord;
            return .{
                .src = .fromInt(entry.src_node_range.min),
                .rel = rel,
                .dst = .fromInt(dst),
                .edge_id = .fromInt(edge_id),
            };
        }

        pub fn edgeSegmentManifestVirtualRunDigest(entry: anytype) !u64 {
            var digest: u64 = 0;
            var index: u64 = 0;
            while (index < entry.edge_count) : (index += 1) {
                const edge = try edgeSegmentManifestVirtualRunEdgeAt(entry, index);
                digest ^= edgeRecordDigest(.{
                    .src = edge.src.toInt(),
                    .dst = edge.dst.toInt(),
                    .edge_id = edge.edge_id.toInt(),
                    .rel = @intFromEnum(edge.rel),
                });
            }
            return digest;
        }

        pub const edgeSegmentManifestValidateVirtualEntryShape = edge_segment_manifest_format.validateVirtualEntryShape;

        pub fn edgeSegmentManifestValidateVirtualEntry(entry: anytype) !void {
            try edgeSegmentManifestValidateVirtualEntryShape(entry);
            const expected_id_digest = try edgeSegmentIdDigestForRun(entry.edge_id_range.min, entry.edge_count);
            if (entry.edge_id_digest != 0 and entry.edge_id_digest != expected_id_digest) return error.InvalidRecord;
            if (entry.edge_digest != try edgeSegmentManifestVirtualRunDigest(entry)) return error.InvalidRecord;
        }

        pub fn appendEdgeSegmentManifestVirtualEdges(
            allocator: std.mem.Allocator,
            out: *std.ArrayList(segment_mod.EdgeRecord),
            entry: anytype,
        ) !void {
            try edgeSegmentManifestValidateVirtualEntry(entry);
            const additional = std.math.cast(usize, entry.edge_count) orelse return error.RecordTooLarge;
            try out.ensureUnusedCapacity(allocator, additional);
            var index: u64 = 0;
            while (index < entry.edge_count) : (index += 1) {
                out.appendAssumeCapacity(try edgeSegmentManifestVirtualRunEdgeAt(entry, index));
            }
        }

        pub fn edgeSegmentIdDigestForRun(first: u64, count: u64) !u64 {
            var digest: u64 = 0;
            var offset: u64 = 0;
            while (offset < count) : (offset += 1) {
                digest ^= edgeSegmentIdDigest(std.math.add(u64, first, offset) catch return error.InvalidRecord);
            }
            return digest;
        }

        pub const nodeIdRangeCount = edge_segment_manifest_format.nodeRangeCount;

        pub fn extendVirtualEdgeRun(existing: *EdgeSegmentManifestEntry, next: EdgeSegmentManifestEntry) !bool {
            if (!edgeSegmentManifestEntryIsVirtual(existing.*)) return false;
            if (!edgeSegmentManifestEntryIsVirtual(next)) return false;
            try edgeSegmentManifestValidateVirtualEntryShape(existing.*);
            try edgeSegmentManifestValidateVirtualEntryShape(next);
            if (existing.singleton_rel.? != next.singleton_rel.?) return false;
            if (existing.src_node_range.min != next.src_node_range.min or existing.src_node_range.max != next.src_node_range.max) return false;
            if (existing.edge_id_range.max == std.math.maxInt(u64) or existing.dst_node_range.max == std.math.maxInt(u64)) return false;
            if (next.edge_id_range.min != existing.edge_id_range.max + 1 or next.edge_id_range.max != next.edge_id_range.min) return false;
            if (next.dst_node_range.min != existing.dst_node_range.max + 1 or next.dst_node_range.max != next.dst_node_range.min) return false;
            const existing_id_digest = if (existing.edge_id_digest != 0)
                existing.edge_id_digest
            else
                try edgeSegmentIdDigestForRun(existing.edge_id_range.min, existing.edge_count);
            existing.edge_count = std.math.add(u64, existing.edge_count, 1) catch return error.RecordTooLarge;
            existing.edge_digest ^= next.edge_digest;
            existing.edge_id_range.max = next.edge_id_range.max;
            existing.edge_id_digest = existing_id_digest ^ next.edge_id_digest;
            existing.edge_id_order_digest = 0;
            existing.edge_id_runs = .{
                .run_count = 1,
                .first_min = existing.edge_id_range.min,
                .first_max = existing.edge_id_range.max,
            };
            existing.dst_node_range.max = next.dst_node_range.max;
            try edgeSegmentManifestValidateVirtualEntryShape(existing.*);
            return true;
        }

        pub fn addEdgeSegmentManifestLivePaths(
            live_paths: *std.StringHashMap(void),
            entries: []const OwnedEdgeSegmentManifestEntry,
        ) !void {
            try live_paths.ensureUnusedCapacity(@intCast(entries.len));
            for (entries) |entry| {
                if (edgeSegmentManifestEntryIsVirtual(entry)) continue;
                live_paths.putAssumeCapacity(entry.path, {});
            }
        }

        pub const EdgeSegmentIdIndex = struct {
            const magic = [_]u8{ 'T', 'K', 'E', 'I' };
            const version: u16 = 1;
            pub const header_len: usize = 48;
        };

        pub const edge_segment_id_index_stack_scan_max = 256;

        pub const EdgeSegmentIdIndexHeader = struct {
            edge_count: u64,
            edge_id_min: u64,
            edge_id_max: u64,
            edge_id_digest: u64,
            edge_id_order_digest: u64,
        };

        pub const EdgeSegmentIdIndexWriter = struct {
            file: std.Io.File,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
            edge_id_order_digest: u64,
            offset: u64 = EdgeSegmentIdIndex.header_len,
            previous: u64 = 0,
            digest: u64 = 0,
            order_digest: u64 = 0,

            pub fn write(self: *EdgeSegmentIdIndexWriter, store: Store, index: usize, edge_id: u64) !void {
                if (index != 0 and edge_id <= self.previous) return error.InvalidRecord;
                self.previous = edge_id;
                self.digest ^= edgeSegmentIdDigest(edge_id);
                self.order_digest ^= edgeSegmentIdIndexOrderDigestAt(index, edge_id);
                var id_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &id_bytes, edge_id, .little);
                try self.file.writePositionalAll(store.io, &id_bytes, self.offset);
                self.offset += id_bytes.len;
            }

            pub fn finish(self: *EdgeSegmentIdIndexWriter, store: Store) !void {
                if (self.digest != self.summary.digest) return error.InvalidRecord;
                if (self.order_digest != self.edge_id_order_digest) return error.InvalidRecord;
                if (self.offset != try edgeSegmentIdIndexFileSize(self.summary.count)) return error.InvalidRecord;
                if (selfOptionsNeedSync(store)) try self.file.sync(store.io);
            }
        };

        pub const StorageEdgeSegmentMergeOps = struct {
            pub const EdgeType = segment_mod.EdgeRecord;
            pub const DirectionType = segment_mod.Direction;
            pub const SegmentCollectionType = std.ArrayList(segment_mod.ImmutableAdjacencySegment);
            pub const SegmentIteratorType = segment_mod.ImmutableAdjacencySegment.EdgeIterator;
            pub const NeighborIteratorType = segment_mod.ImmutableAdjacencySegment.NeighborIterator;
            pub const BaseReaderType = EdgeIndexRecordReader;
            pub const TombstoneViewType = EdgeTombstoneIndexView;
            pub const NodeIdType = core.NodeId;
            pub const RelationType = core.RelKind;

            pub fn segmentCount(segments: *SegmentCollectionType) usize {
                return segments.items.len;
            }

            pub fn segmentIterator(segments: *SegmentCollectionType, index: usize, direction: DirectionType) !SegmentIteratorType {
                return segments.items[index].edgeIterator(direction);
            }

            pub fn nextSegmentEdge(iterator: *SegmentIteratorType) !?EdgeType {
                return iterator.next();
            }

            pub fn neighborIterator(
                segments: *SegmentCollectionType,
                index: usize,
                direction: DirectionType,
                node_id: NodeIdType,
                rel_filter: ?RelationType,
            ) !?NeighborIteratorType {
                return segments.items[index].neighborIterator(direction, node_id, rel_filter);
            }

            pub fn nextNeighborEdge(iterator: *NeighborIteratorType) !?EdgeType {
                return iterator.next();
            }

            pub fn virtualNeighborMatches(
                edge: EdgeType,
                direction: DirectionType,
                node_id: NodeIdType,
                rel_filter: ?RelationType,
            ) bool {
                const owner = switch (direction) {
                    .forward => edge.src,
                    .reverse => edge.dst,
                };
                if (owner != node_id) return false;
                if (rel_filter) |rel| return edge.rel == rel;
                return true;
            }

            pub fn baseEdgeCount(reader: *BaseReaderType) u64 {
                return reader.edge_count;
            }

            pub fn baseEdgeAt(reader: *BaseReaderType, index: u64) !EdgeType {
                return edgeIndexReaderRecordToSegmentEdge(reader, index);
            }

            pub fn isTombstoned(view: *TombstoneViewType, edge: EdgeType) !bool {
                return view.contains(edge.edge_id.toInt());
            }

            pub fn edgeLessThan(direction: DirectionType, lhs: EdgeType, rhs: EdgeType) bool {
                return segmentEdgeLessThan(direction, lhs, rhs);
            }
        };

        pub const edge_segment_merge = edge_segment_merge_mod.EdgeSegmentMerge(StorageEdgeSegmentMergeOps);
        pub const EdgeSegmentMergeStream = edge_segment_merge.SegmentMergeStream;
        pub const BaseAndSegmentMergeStream = edge_segment_merge.BaseAndSegmentMergeStream;

        pub fn segmentEdgeLessThan(direction: segment_mod.Direction, lhs: segment_mod.EdgeRecord, rhs: segment_mod.EdgeRecord) bool {
            return switch (direction) {
                .forward => segmentForwardEdgeLessThan(lhs, rhs),
                .reverse => segmentReverseEdgeLessThan(lhs, rhs),
            };
        }

        pub fn segmentForwardEdgeLessThan(lhs: segment_mod.EdgeRecord, rhs: segment_mod.EdgeRecord) bool {
            if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
            if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
            if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
            return lhs.edge_id.toInt() < rhs.edge_id.toInt();
        }

        pub fn segmentReverseEdgeLessThan(lhs: segment_mod.EdgeRecord, rhs: segment_mod.EdgeRecord) bool {
            if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
            if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
            if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
            return lhs.edge_id.toInt() < rhs.edge_id.toInt();
        }

        pub const encodeEdgeSegmentManifestHeader = edge_segment_manifest_format.encodeHeader;
        pub const edgeSegmentManifestRangeCount = edge_segment_manifest_format.rangeCount;
        pub const edgeSegmentManifestRunsCoverEntry = edge_segment_manifest_format.runsCoverEntry;
        pub const edgeSegmentManifestCanDeriveEdgeIdDigest = edge_segment_manifest_format.canDeriveEdgeIdDigest;
        pub const edgeSegmentManifestCanDeriveEdgeCount = edge_segment_manifest_format.canDeriveEdgeCount;
        pub const edgeSegmentManifestLogicalEdgeIdDigest = edge_segment_manifest_format.logicalEdgeIdDigest;
        pub const edgeSegmentManifestOrderDigestExtraLen = edge_segment_manifest_format.orderDigestExtraLen;

        pub fn writeEdgeSegmentManifestOrderDigestExtra(
            io: std.Io,
            file: std.Io.File,
            offset: u64,
            entry: EdgeSegmentManifestEntry,
            flags: u32,
        ) !u64 {
            if (try edgeSegmentManifestOrderDigestExtraLen(flags) == 0) return offset;
            var extra: [8]u8 = undefined;
            std.mem.writeInt(u64, &extra, entry.edge_id_order_digest, .little);
            try file.writePositionalAll(io, &extra, offset);
            return std.math.add(u64, offset, extra.len) catch return error.RecordTooLarge;
        }

        pub const encodeEdgeSegmentManifestRunEncoding = edge_segment_manifest_format.encodeRun;
        pub const decodeEdgeSegmentManifestRunEncoding = edge_segment_manifest_format.decodeRun;
        pub const deriveEdgeSegmentManifestEdgeCountFromRunEncoding = edge_segment_manifest_format.deriveEdgeCount;
        pub const edgeSegmentManifestRunExtraLen = edge_segment_manifest_format.runExtraLen;

        pub fn writeEdgeSegmentManifestRunExtra(
            io: std.Io,
            file: std.Io.File,
            offset: u64,
            run_encoding: EdgeSegmentManifestRunEncoding,
        ) !u64 {
            if ((run_encoding.flags & edge_segment_manifest_run_two_split) == 0) return offset;
            var extra: [16]u8 = undefined;
            std.mem.writeInt(u64, extra[0..8], run_encoding.first_max, .little);
            std.mem.writeInt(u64, extra[8..16], run_encoding.second_min, .little);
            try file.writePositionalAll(io, &extra, offset);
            return std.math.add(u64, offset, extra.len) catch return error.RecordTooLarge;
        }

        pub const edgeSegmentManifestEdgeCountExtraLen = edge_segment_manifest_format.edgeCountExtraLen;

        pub fn writeEdgeSegmentManifestEdgeCountExtra(
            io: std.Io,
            file: std.Io.File,
            offset: u64,
            entry: EdgeSegmentManifestEntry,
            flags: u32,
        ) !u64 {
            if (try edgeSegmentManifestEdgeCountExtraLen(flags) == 0) return offset;
            var extra: [8]u8 = undefined;
            std.mem.writeInt(u64, &extra, entry.edge_count, .little);
            try file.writePositionalAll(io, &extra, offset);
            return std.math.add(u64, offset, extra.len) catch return error.RecordTooLarge;
        }

        pub const edgeSegmentManifestDigestExtraLen = edge_segment_manifest_format.digestExtraLen;

        pub fn writeEdgeSegmentManifestDigestExtra(
            io: std.Io,
            file: std.Io.File,
            offset: u64,
            entry: EdgeSegmentManifestEntry,
            flags: u32,
        ) !u64 {
            if (try edgeSegmentManifestDigestExtraLen(flags) == 0) return offset;
            var extra: [8]u8 = undefined;
            std.mem.writeInt(u64, &extra, entry.edge_id_digest, .little);
            try file.writePositionalAll(io, &extra, offset);
            return std.math.add(u64, offset, extra.len) catch return error.RecordTooLarge;
        }

        pub const encodeEdgeSegmentManifestEndpointEncoding = edge_segment_manifest_format.encodeEndpoints;
        pub const edgeSegmentManifestEndpointExtraLen = edge_segment_manifest_format.endpointExtraLen;

        pub fn writeEdgeSegmentManifestEndpointExtra(
            io: std.Io,
            file: std.Io.File,
            offset: u64,
            encoding: EdgeSegmentManifestEndpointEncoding,
        ) !u64 {
            var extra: [32]u8 = undefined;
            var len: usize = 0;
            if ((encoding.flags & edge_segment_manifest_src_full) == 0) {
                std.mem.writeInt(u64, extra[len..][0..8], encoding.src_min, .little);
                len += 8;
            }
            if ((encoding.flags & (edge_segment_manifest_src_single | edge_segment_manifest_src_full)) == 0) {
                std.mem.writeInt(u64, extra[len..][0..8], encoding.src_max, .little);
                len += 8;
            }
            if ((encoding.flags & edge_segment_manifest_dst_full) == 0) {
                std.mem.writeInt(u64, extra[len..][0..8], encoding.dst_min, .little);
                len += 8;
            }
            if ((encoding.flags & (edge_segment_manifest_dst_single | edge_segment_manifest_dst_full)) == 0) {
                std.mem.writeInt(u64, extra[len..][0..8], encoding.dst_max, .little);
                len += 8;
            }
            if (len == 0) return offset;
            try file.writePositionalAll(io, extra[0..len], offset);
            return std.math.add(u64, offset, len) catch return error.RecordTooLarge;
        }

        pub const edgeSegmentManifestSingletonRelExtraLen = edge_segment_manifest_format.singletonRelExtraLen;

        pub fn writeEdgeSegmentManifestSingletonRelExtra(
            io: std.Io,
            file: std.Io.File,
            offset: u64,
            entry: EdgeSegmentManifestEntry,
            flags: u32,
        ) !u64 {
            if (try edgeSegmentManifestSingletonRelExtraLen(flags) == 0) return offset;
            const rel = entry.singleton_rel orelse return error.InvalidRecord;
            var extra: [2]u8 = undefined;
            std.mem.writeInt(u16, &extra, @intFromEnum(rel), .little);
            try file.writePositionalAll(io, &extra, offset);
            return std.math.add(u64, offset, extra.len) catch return error.RecordTooLarge;
        }

        pub const decodeEdgeSegmentManifestEndpointRanges = edge_segment_manifest_format.decodeEndpoints;
        pub const encodeEdgeSegmentManifestEntryHeader = edge_segment_manifest_format.encodeEntryHeader;
        pub const encodeEdgeSegmentManifestEntryHeaderForPath = edge_segment_manifest_format.encodeEntryHeaderForPath;
        pub const decodeEdgeSegmentManifestHeader = edge_segment_manifest_format.decodeHeader;
        pub const decodeEdgeSegmentManifestEntryHeader = edge_segment_manifest_format.decodeEntryHeader;

        pub fn encodeEdgeSegmentIdIndexHeader(
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
            edge_id_order_digest: u64,
            out: *[EdgeSegmentIdIndex.header_len]u8,
        ) void {
            @memcpy(out[0..4], &EdgeSegmentIdIndex.magic);
            std.mem.writeInt(u16, out[4..6], EdgeSegmentIdIndex.version, .little);
            std.mem.writeInt(u16, out[6..8], EdgeSegmentIdIndex.header_len, .little);
            std.mem.writeInt(u64, out[8..16], summary.count, .little);
            std.mem.writeInt(u64, out[16..24], summary.range.min, .little);
            std.mem.writeInt(u64, out[24..32], summary.range.max, .little);
            std.mem.writeInt(u64, out[32..40], summary.digest, .little);
            std.mem.writeInt(u64, out[40..48], edge_id_order_digest, .little);
        }

        pub fn decodeEdgeSegmentIdIndexHeader(bytes: *const [EdgeSegmentIdIndex.header_len]u8) !EdgeSegmentIdIndexHeader {
            if (!std.mem.eql(u8, bytes[0..4], &EdgeSegmentIdIndex.magic)) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[4..6], .little) != EdgeSegmentIdIndex.version) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[6..8], .little) != EdgeSegmentIdIndex.header_len) return error.InvalidRecord;
            const edge_count = std.mem.readInt(u64, bytes[8..16], .little);
            const edge_id_min = std.mem.readInt(u64, bytes[16..24], .little);
            const edge_id_max = std.mem.readInt(u64, bytes[24..32], .little);
            if (edge_count == 0 or edge_id_min > edge_id_max) return error.InvalidRecord;
            return .{
                .edge_count = edge_count,
                .edge_id_min = edge_id_min,
                .edge_id_max = edge_id_max,
                .edge_id_digest = std.mem.readInt(u64, bytes[32..40], .little),
                .edge_id_order_digest = std.mem.readInt(u64, bytes[40..48], .little),
            };
        }

        pub fn edgeSegmentIdIndexFileSize(edge_count: u64) !u64 {
            const records = std.math.mul(u64, edge_count, 8) catch return error.RecordTooLarge;
            return std.math.add(u64, EdgeSegmentIdIndex.header_len, records) catch return error.RecordTooLarge;
        }

        pub fn edgeSegmentIdDigest(edge_id: u64) u64 {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, edge_id, .little);
            return std.hash.Wyhash.hash(0x544B_4549, &bytes);
        }

        pub fn edgeSegmentIdIndexOrderDigest(records_by_id: []const EdgeIndexRecord) u64 {
            var digest: u64 = 0;
            for (records_by_id, 0..) |record, index| {
                digest ^= edgeSegmentIdIndexOrderDigestAt(index, record.edge_id);
            }
            return digest;
        }

        pub fn edgeSegmentIdRunSummaryFromRecords(records_by_id: []const EdgeIndexRecord) EdgeSegmentIdRunSummary {
            var builder = EdgeSegmentIdRunBuilder{};
            for (records_by_id) |record| builder.add(record.edge_id);
            return builder.finish();
        }

        pub fn edgeSegmentIdSidecarSummaryFromCompleteRuns(
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
            runs: EdgeSegmentIdRunSummary,
        ) !?EdgeSegmentIdSidecarSummary {
            if (runs.run_count == 0) return null;
            if (try runs.coveredCount() != summary.count) return null;
            if (runs.first_min != summary.range.min) return null;
            const max = if (runs.run_count == 2) runs.second_max else runs.first_max;
            if (max != summary.range.max) return null;
            if (try edgeSegmentIdRunSummaryDigest(runs) != summary.digest) return null;
            return .{
                .edge_id_order_digest = 0,
                .edge_id_runs = runs,
            };
        }

        pub fn edgeSegmentIdSidecarSummaryFromCompleteRange(
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
        ) !?EdgeSegmentIdSidecarSummary {
            if (summary.count == 0 or summary.range.min == 0 or summary.range.max == std.math.maxInt(u64)) return null;
            if (summary.range.min > summary.range.max) return null;
            const span = std.math.add(u64, summary.range.max - summary.range.min, 1) catch return error.RecordTooLarge;
            if (span != summary.count) return null;
            return try edgeSegmentIdSidecarSummaryFromCompleteRuns(summary, .{
                .run_count = 1,
                .first_min = summary.range.min,
                .first_max = summary.range.max,
            });
        }

        pub fn edgeSegmentIdRunSummaryDigest(runs: EdgeSegmentIdRunSummary) !u64 {
            try runs.validate();
            var digest: u64 = 0;
            digest ^= try edgeSegmentIdRangeDigest(runs.first_min, runs.first_max);
            if (runs.run_count == 2) digest ^= try edgeSegmentIdRangeDigest(runs.second_min, runs.second_max);
            return digest;
        }

        pub fn edgeSegmentIdRangeDigest(min: u64, max: u64) !u64 {
            if (min == 0 or max == std.math.maxInt(u64) or min > max) return error.InvalidRecord;
            var digest: u64 = 0;
            var edge_id = min;
            while (true) {
                digest ^= edgeSegmentIdDigest(edge_id);
                if (edge_id == max) break;
                edge_id += 1;
            }
            return digest;
        }

        pub fn edgeSegmentIdRunBuilderFromSummary(summary: EdgeSegmentIdRunSummary) !EdgeSegmentIdRunBuilder {
            try summary.validate();
            var builder = EdgeSegmentIdRunBuilder{};
            switch (summary.run_count) {
                0 => {},
                1 => builder.addRange(summary.first_min, summary.first_max),
                2 => {
                    builder.addRange(summary.first_min, summary.first_max);
                    builder.addRange(summary.second_min, summary.second_max);
                },
                else => return error.InvalidRecord,
            }
            return builder;
        }

        pub fn extendEdgeSegmentIdRunSummaryWithRecords(
            summary: EdgeSegmentIdRunSummary,
            old_count: u64,
            records_by_id: []const EdgeIndexRecord,
        ) ?EdgeSegmentIdRunSummary {
            const covered = summary.coveredCount() catch return null;
            if (covered != old_count) return null;
            var builder = edgeSegmentIdRunBuilderFromSummary(summary) catch return null;
            for (records_by_id) |record| builder.add(record.edge_id);
            const next = builder.finish();
            const expected_count = std.math.add(u64, old_count, @intCast(records_by_id.len)) catch return null;
            const next_covered = next.coveredCount() catch return null;
            if (next_covered != expected_count) return null;
            return next;
        }

        pub fn extendEdgeSegmentIdRunSummaryWithEdge(
            summary: EdgeSegmentIdRunSummary,
            old_count: u64,
            edge_id: u64,
        ) ?EdgeSegmentIdRunSummary {
            const covered = summary.coveredCount() catch return null;
            if (covered != old_count) return null;
            var builder = edgeSegmentIdRunBuilderFromSummary(summary) catch return null;
            builder.add(edge_id);
            const next = builder.finish();
            const expected_count = std.math.add(u64, old_count, 1) catch return null;
            const next_covered = next.coveredCount() catch return null;
            if (next_covered != expected_count) return null;
            return next;
        }

        pub fn edgeSegmentIdIndexOrderDigestAt(index: usize, edge_id: u64) u64 {
            var bytes: [16]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], @intCast(index), .little);
            std.mem.writeInt(u64, bytes[8..16], edge_id, .little);
            return std.hash.Wyhash.hash(0x544B_454F, &bytes);
        }

        pub fn u64LessThan(_: void, lhs: u64, rhs: u64) bool {
            return lhs < rhs;
        }

        pub fn lowerBoundU64(items: []const u64, needle: u64) usize {
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid] < needle) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn upperBoundU64(items: []const u64, needle: u64) usize {
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid] <= needle) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn sortedSetIntersectsRange(items: []const u64, min: u64, max: u64) bool {
            const index = lowerBoundU64(items, min);
            return index < items.len and items[index] <= max;
        }

        pub fn u64SortedContains(items: []const u64, needle: u64) bool {
            const index = lowerBoundU64(items, needle);
            return index < items.len and items[index] == needle;
        }

        pub fn sortEdgeIndexRecords(order: EdgeIndexOrder, records: []EdgeIndexRecord) void {
            switch (order) {
                .id => std.mem.sort(EdgeIndexRecord, records, {}, edgeIndexByIdLessThan),
                .src => std.mem.sort(EdgeIndexRecord, records, {}, edgeIndexBySrcLessThan),
                .dst => std.mem.sort(EdgeIndexRecord, records, {}, edgeIndexByDstLessThan),
            }
        }

        pub const EdgeIndexRecordOrderContext = struct {
            order: EdgeIndexOrder,
            records: []const EdgeIndexRecord,
        };

        pub fn edgeIndexRecordOrderLessThan(context: EdgeIndexRecordOrderContext, lhs: u32, rhs: u32) bool {
            return edgeIndexLessThan(context.order, context.records[@intCast(lhs)], context.records[@intCast(rhs)]);
        }

        pub fn edgeIndexRecordOptionalOrderLessThan(order_map: *std.AutoHashMap(u64, u64), lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
            const lhs_order = order_map.get(lhs.edge_id);
            const rhs_order = order_map.get(rhs.edge_id);
            if (lhs_order != null and rhs_order != null and lhs_order.? != rhs_order.?) return lhs_order.? < rhs_order.?;
            if (lhs_order != null and rhs_order == null) return true;
            if (lhs_order == null and rhs_order != null) return false;
            return lhs.edge_id < rhs.edge_id;
        }

        pub fn edgeOrderRecordLessThan(_: void, lhs: EdgeOrderRecord, rhs: EdgeOrderRecord) bool {
            if (lhs.src != rhs.src) return lhs.src < rhs.src;
            if (lhs.order_key != rhs.order_key) return lhs.order_key < rhs.order_key;
            if (lhs.edge_id != rhs.edge_id) return lhs.edge_id < rhs.edge_id;
            return lhs.rel < rhs.rel;
        }

        pub fn validateEdgeOrderRecord(record: EdgeOrderRecord) !void {
            return edge_order_format.validateRecord(record);
        }

        pub fn sortEdgeIndexRecordOrder(order: EdgeIndexOrder, records: []const EdgeIndexRecord, record_order: []u32) void {
            const context = EdgeIndexRecordOrderContext{ .order = order, .records = records };
            std.mem.sort(u32, record_order, context, edgeIndexRecordOrderLessThan);
        }

        pub fn edgeRecordDigest(record: EdgeIndexRecord) u64 {
            var bytes: [26]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], record.edge_id, .little);
            std.mem.writeInt(u64, bytes[8..16], record.src, .little);
            std.mem.writeInt(u16, bytes[16..18], record.rel, .little);
            std.mem.writeInt(u64, bytes[18..26], record.dst, .little);
            return std.hash.Wyhash.hash(0x544B_4745, &bytes);
        }

        pub fn edgeOrderRecordDigest(record: EdgeOrderRecord) u64 {
            var bytes: [edge_order_format.record_encoded_len]u8 = undefined;
            edge_order_format.encodeRecord(record, &bytes);
            return std.hash.Wyhash.hash(0x544B_4F52, &bytes);
        }

        pub fn edgeIndexRecordFromEdge(edge: graph_mod.Edge) EdgeIndexRecord {
            return .{
                .src = edge.src.toInt(),
                .dst = edge.dst.toInt(),
                .edge_id = edge.id.toInt(),
                .rel = @intFromEnum(edge.rel),
            };
        }

        pub fn edgeIndexRecordEquals(lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
            return lhs.src == rhs.src and
                lhs.dst == rhs.dst and
                lhs.edge_id == rhs.edge_id and
                lhs.rel == rhs.rel;
        }

        pub fn tombstoneDigest(records: []const EdgeTombstoneRecord) u64 {
            var digest: u64 = 0;
            for (records) |record| digest ^= record.edge_digest;
            return digest;
        }

        pub fn edgeTombstoneSliceContains(records: []const EdgeTombstoneRecord, edge_id: u64) bool {
            var lo: usize = 0;
            var hi: usize = records.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (records[mid].edge_id < edge_id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo < records.len and records[lo].edge_id == edge_id;
        }

        pub fn mergeEdgeTombstones(
            existing: []const EdgeTombstoneRecord,
            batch: []const EdgeTombstoneRecord,
            out: *std.ArrayList(EdgeTombstoneRecord),
        ) !void {
            var existing_index: usize = 0;
            var batch_index: usize = 0;
            while (existing_index < existing.len or batch_index < batch.len) {
                const take_existing = if (batch_index >= batch.len)
                    true
                else if (existing_index >= existing.len)
                    false
                else
                    existing[existing_index].edge_id < batch[batch_index].edge_id;
                const record = if (take_existing) record: {
                    const value = existing[existing_index];
                    existing_index += 1;
                    break :record value;
                } else record: {
                    const value = batch[batch_index];
                    batch_index += 1;
                    break :record value;
                };
                if (out.items.len != 0 and out.items[out.items.len - 1].edge_id >= record.edge_id) return core.Error.InvalidId;
                out.appendAssumeCapacity(record);
            }
        }

        pub fn nodeRecordDigestFromParts(id: u64, kind: core.NodeKind, text: []const u8) !u64 {
            if (text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
            var fixed: [node_record_digest_fixed_len]u8 = undefined;
            std.mem.writeInt(u64, fixed[0..8], id, .little);
            std.mem.writeInt(u16, fixed[8..10], @intFromEnum(kind), .little);
            std.mem.writeInt(u32, fixed[10..14], @intCast(text.len), .little);
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&fixed);
            hasher.update(text);
            return hasher.final();
        }

        pub fn nodeRecordDigestFromPayload(payload: []const u8) !u64 {
            _ = payload;
            return error.InvalidRecord;
        }

        pub const EdgeIndexDigest = struct {
            count: u64 = 0,
            digest: u64 = 0,
            order_digest: u64 = 0,

            pub fn add(self: *EdgeIndexDigest, record: EdgeIndexRecord) void {
                self.addWithDigest(record, edgeRecordDigest(record));
            }

            pub fn addWithDigest(self: *EdgeIndexDigest, record: EdgeIndexRecord, record_digest: u64) void {
                self.order_digest = edgeIndexOrderDigestStep(self.order_digest, self.count, record);
                self.digest ^= record_digest;
                self.count += 1;
            }

            pub fn eql(self: EdgeIndexDigest, other: EdgeIndexDigest) bool {
                return self.count == other.count and self.digest == other.digest;
            }
        };

        pub fn edgeIndexOrderDigestStep(previous: u64, position: u64, record: EdgeIndexRecord) u64 {
            var bytes: [34]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], previous, .little);
            std.mem.writeInt(u64, bytes[8..16], position, .little);
            std.mem.writeInt(u64, bytes[16..24], edgeRecordDigest(record), .little);
            std.mem.writeInt(u64, bytes[24..32], record.edge_id, .little);
            std.mem.writeInt(u16, bytes[32..34], record.rel, .little);
            return std.hash.Wyhash.hash(0x544B_4758, &bytes);
        }

        pub fn activeNodeCount(graph: *const graph_mod.Graph) u64 {
            var count: u64 = 0;
            for (graph.nodes.items) |node| {
                if (node.status == .active) count += 1;
            }
            return count;
        }

        pub const ActiveNodeSet = struct {
            allocator: std.mem.Allocator,
            ids: Ids,
            count: u64 = 0,

            const Dense = struct {
                bits: std.DynamicBitSetUnmanaged,
            };

            const Ids = union(enum) {
                dense: Dense,
                sparse: std.AutoHashMap(u64, void),
            };

            pub fn deinit(self: *ActiveNodeSet) void {
                switch (self.ids) {
                    .dense => |*dense| dense.bits.deinit(self.allocator),
                    .sparse => |*sparse| sparse.deinit(),
                }
            }

            pub fn contains(self: ActiveNodeSet, id: u64) bool {
                if (id == 0 or id == std.math.maxInt(u64)) return false;
                return switch (self.ids) {
                    .dense => |dense| blk: {
                        const index = std.math.cast(usize, id - 1) orelse break :blk false;
                        break :blk index < dense.bits.capacity() and dense.bits.isSet(index);
                    },
                    .sparse => |sparse| sparse.contains(id),
                };
            }
        };

        pub const GraphIndexStats = struct {
            active_nodes: u64 = 0,
            visible_edges: u64 = 0,
            physical_edges: u64 = 0,
            node_digest: u64 = 0,
            edge_digest: u64 = 0,
            physical_edge_digest: u64 = 0,
            node_by_text_order_digest: u64 = 0,
            edge_by_id_order_digest: u64 = 0,
            edge_by_src_order_digest: u64 = 0,
            edge_by_dst_order_digest: u64 = 0,
            max_edge_id_seen: u64 = 0,
        };

        pub const GraphCurrentMetaStats = struct {
            active_nodes: u64 = 0,
            visible_edges: u64 = 0,
            node_digest: u64 = 0,
            edge_digest: u64 = 0,
            max_edge_id_seen: u64 = 0,
        };

        pub const GraphEdgeIndexStats = struct {
            visible_edges: u64 = 0,
            physical_edges: u64 = 0,
            edge_digest: u64 = 0,
            physical_edge_digest: u64 = 0,
        };

        pub fn graphCurrentMetaStats(allocator: std.mem.Allocator, graph: *const graph_mod.Graph) !GraphCurrentMetaStats {
            var active_nodes = try buildActiveNodeSet(allocator, graph);
            defer active_nodes.deinit();
            var edge_ids = try GraphPhysicalEdgeIdSet.init(allocator, @intCast(graph.edges.items.len));
            defer edge_ids.deinit();

            var out = GraphCurrentMetaStats{ .active_nodes = active_nodes.count };
            for (graph.nodes.items) |node| {
                if (node.status != .active) continue;
                out.node_digest ^= try nodeRecordDigestFromParts(node.id.toInt(), node.kind, node.text);
            }

            for (graph.edges.items) |edge| {
                const record = (try physicalEdgeRecord(&active_nodes, edge)) orelse continue;
                if (try edge_ids.put(record.edge_id)) return core.Error.InvalidId;
                out.max_edge_id_seen = @max(out.max_edge_id_seen, record.edge_id);
                if (edge.status == .active) {
                    out.visible_edges += 1;
                    out.edge_digest ^= edgeRecordDigest(record);
                }
            }
            return out;
        }

        pub const GraphPhysicalEdgeIdSet = struct {
            allocator: std.mem.Allocator,
            dense_limit: u64,
            dense_bits: std.ArrayList(u8) = .empty,
            overflow: std.AutoHashMap(u64, void),
            count: u64 = 0,

            pub fn init(allocator: std.mem.Allocator, expected_edges: u64) !GraphPhysicalEdgeIdSet {
                return .{
                    .allocator = allocator,
                    .dense_limit = try denseLimit(expected_edges),
                    .overflow = std.AutoHashMap(u64, void).init(allocator),
                };
            }

            pub fn deinit(self: *GraphPhysicalEdgeIdSet) void {
                self.overflow.deinit();
                self.dense_bits.deinit(self.allocator);
            }

            pub fn put(self: *GraphPhysicalEdgeIdSet, edge_id: u64) !bool {
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const found = if (edge_id <= self.dense_limit)
                    try self.putDense(edge_id)
                else
                    try self.putOverflow(edge_id);
                if (!found) self.count = std.math.add(u64, self.count, 1) catch return error.InvalidRecord;
                return found;
            }

            pub fn putDense(self: *GraphPhysicalEdgeIdSet, edge_id: u64) !bool {
                const bit = edge_id - 1;
                const byte_index = std.math.cast(usize, bit / 8) orelse return error.RecordTooLarge;
                if (byte_index >= self.dense_bits.items.len) {
                    const old_len = self.dense_bits.items.len;
                    const min_len = byte_index + 1;
                    const doubled = std.math.mul(usize, @max(old_len, 4096), 2) catch return error.RecordTooLarge;
                    const next_len = @max(min_len, doubled);
                    try self.dense_bits.resize(self.allocator, next_len);
                    @memset(self.dense_bits.items[old_len..], 0);
                }
                const mask = @as(u8, 1) << @intCast(bit % 8);
                const found = (self.dense_bits.items[byte_index] & mask) != 0;
                self.dense_bits.items[byte_index] |= mask;
                return found;
            }

            pub fn putOverflow(self: *GraphPhysicalEdgeIdSet, edge_id: u64) !bool {
                return (try self.overflow.getOrPut(edge_id)).found_existing;
            }

            pub fn denseLimit(expected_edges: u64) !u64 {
                const scaled = std.math.mul(u64, expected_edges, graph_edge_id_set_dense_ratio) catch graph_edge_id_set_dense_max_id;
                return @min(@max(graph_edge_id_set_dense_min_id, scaled), graph_edge_id_set_dense_max_id);
            }
        };

        pub fn graphEdgeIndexStats(allocator: std.mem.Allocator, graph: *const graph_mod.Graph) !GraphEdgeIndexStats {
            var active_nodes = try buildActiveNodeSet(allocator, graph);
            defer active_nodes.deinit();

            var out = GraphEdgeIndexStats{};
            for (graph.edges.items) |edge| {
                const record = (try physicalEdgeRecord(&active_nodes, edge)) orelse continue;
                out.physical_edges += 1;
                const digest = edgeRecordDigest(record);
                out.physical_edge_digest ^= digest;
                if (edge.status == .active) {
                    out.visible_edges += 1;
                    out.edge_digest ^= digest;
                }
            }
            return out;
        }

        pub fn graphIndexStats(allocator: std.mem.Allocator, graph: *const graph_mod.Graph) !GraphIndexStats {
            var active_nodes = try buildActiveNodeSet(allocator, graph);
            defer active_nodes.deinit();
            var edge_order = std.ArrayList(u32).empty;
            defer edge_order.deinit(allocator);
            var text_order = std.ArrayList(u32).empty;
            defer text_order.deinit(allocator);
            try text_order.ensureTotalCapacity(allocator, @intCast(active_nodes.count));

            var out = GraphIndexStats{ .active_nodes = active_nodes.count };
            var text_bytes: u64 = 0;
            for (graph.nodes.items, 0..) |node, node_index| {
                if (node.status != .active) continue;
                if (node.text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                out.node_digest ^= try nodeRecordDigestFromParts(node.id.toInt(), node.kind, node.text);
                text_order.appendAssumeCapacity(std.math.cast(u32, node_index) orelse return error.RecordTooLarge);
                text_bytes = std.math.add(u64, text_bytes, node.text.len) catch return error.RecordTooLarge;
            }
            std.mem.sort(u32, text_order.items, GraphNodeTextOrderContext{ .graph = graph }, graphNodeTextOrderLessThan);
            out.node_by_text_order_digest = graphNodeTextOrderDigest(graph, text_order.items);

            for (graph.edges.items, 0..) |edge, edge_index| {
                const record = (try physicalEdgeRecord(&active_nodes, edge)) orelse continue;
                out.physical_edges += 1;
                const digest = edgeRecordDigest(record);
                out.physical_edge_digest ^= digest;
                out.max_edge_id_seen = @max(out.max_edge_id_seen, record.edge_id);
                if (edge.status == .active) {
                    out.visible_edges += 1;
                    out.edge_digest ^= digest;
                }
                try edge_order.append(allocator, std.math.cast(u32, edge_index) orelse return error.RecordTooLarge);
            }
            std.mem.sort(u32, edge_order.items, GraphEdgeOrderContext{ .graph = graph, .order = .id }, graphEdgeOrderLessThan);
            var previous_edge_id: u64 = 0;
            for (edge_order.items) |edge_index| {
                const record = edgeIndexRecordFromEdge(graph.edges.items[@intCast(edge_index)]);
                if (record.edge_id == previous_edge_id) return error.InvalidRecord;
                previous_edge_id = record.edge_id;
            }
            out.edge_by_id_order_digest = graphEdgeOrderDigest(graph, edge_order.items);
            std.mem.sort(u32, edge_order.items, GraphEdgeOrderContext{ .graph = graph, .order = .src }, graphEdgeOrderLessThan);
            out.edge_by_src_order_digest = graphEdgeOrderDigest(graph, edge_order.items);
            std.mem.sort(u32, edge_order.items, GraphEdgeOrderContext{ .graph = graph, .order = .dst }, graphEdgeOrderLessThan);
            out.edge_by_dst_order_digest = graphEdgeOrderDigest(graph, edge_order.items);
            return out;
        }

        pub fn nodeTextOrderDigestForRecords(records: []const NodeTextIndexRecord) u64 {
            var digest = NodeTextIndexDigest{};
            for (records) |record| digest.add(record, 0);
            return digest.order_digest;
        }

        pub fn sortedNodeTextBatchOrderDigest(records: []const NodeTextIndexRecord) !u64 {
            var order_digest: u64 = 0;
            var previous: ?NodeTextIndexRecord = null;
            for (records, 0..) |record, position| {
                if (previous) |prev| {
                    if (!nodeTextIndexLessThan({}, prev, record)) return error.InvalidRecord;
                    if (prev.id == record.id) return error.InvalidRecord;
                }
                order_digest = nodeTextIndexOrderDigestStep(order_digest, @intCast(position), record);
                previous = record;
            }
            return order_digest;
        }

        pub fn nodeTextRecordIdRange(records: []const NodeTextIndexRecord) !struct { min: u64, max: u64 } {
            if (records.len == 0) return error.InvalidRecord;
            var min_id = records[0].id;
            var max_id = records[0].id;
            for (records[1..]) |record| {
                if (record.id < min_id) min_id = record.id;
                if (record.id > max_id) max_id = record.id;
            }
            if (min_id == 0 or max_id < min_id) return error.InvalidRecord;
            return .{ .min = min_id, .max = max_id };
        }

        pub fn nodeTextRecordHashRange(records: []const NodeTextIndexRecord) !struct { min: u64, max: u64 } {
            if (records.len == 0) return error.InvalidRecord;
            var min_hash = records[0].hash;
            var max_hash = records[0].hash;
            for (records[1..]) |record| {
                if (record.hash < min_hash) min_hash = record.hash;
                if (record.hash > max_hash) max_hash = record.hash;
            }
            return .{ .min = min_hash, .max = max_hash };
        }

        pub const GraphNodeTextOrderContext = struct {
            graph: *const graph_mod.Graph,
        };

        pub fn graphNodeTextOrderLessThan(context: GraphNodeTextOrderContext, lhs: u32, rhs: u32) bool {
            const lhs_node = context.graph.nodes.items[@intCast(lhs)];
            const rhs_node = context.graph.nodes.items[@intCast(rhs)];
            const lhs_hash = nodeTextHash(lhs_node.text);
            const rhs_hash = nodeTextHash(rhs_node.text);
            if (lhs_hash != rhs_hash) return lhs_hash < rhs_hash;
            if (lhs_node.id != rhs_node.id) return nodeIdLessThan({}, lhs_node.id, rhs_node.id);
            return @intFromEnum(lhs_node.kind) < @intFromEnum(rhs_node.kind);
        }

        pub fn graphNodeTextOrderDigest(graph: *const graph_mod.Graph, order: []const u32) u64 {
            var order_digest: u64 = 0;
            for (order, 0..) |node_index, position| {
                const node = graph.nodes.items[@intCast(node_index)];
                order_digest = nodeTextIndexOrderDigestStepParts(
                    order_digest,
                    @intCast(position),
                    nodeTextHash(node.text),
                    node.id.toInt(),
                    @intFromEnum(node.kind),
                );
            }
            return order_digest;
        }

        pub fn edgeOrderDigestForRecords(records: []const EdgeIndexRecord) u64 {
            var digest = EdgeIndexDigest{};
            for (records) |record| digest.add(record);
            return digest.order_digest;
        }

        pub const GraphEdgeOrderContext = struct {
            graph: *const graph_mod.Graph,
            order: EdgeIndexOrder,
        };

        pub fn graphEdgeOrderLessThan(context: GraphEdgeOrderContext, lhs: u32, rhs: u32) bool {
            const lhs_record = edgeIndexRecordFromEdge(context.graph.edges.items[@intCast(lhs)]);
            const rhs_record = edgeIndexRecordFromEdge(context.graph.edges.items[@intCast(rhs)]);
            return edgeIndexLessThan(context.order, lhs_record, rhs_record);
        }

        pub fn graphEdgeOrderDigest(graph: *const graph_mod.Graph, order: []const u32) u64 {
            var digest = EdgeIndexDigest{};
            for (order) |edge_index| digest.add(edgeIndexRecordFromEdge(graph.edges.items[@intCast(edge_index)]));
            return digest.order_digest;
        }

        pub fn edgeTombstoneLessThan(_: void, lhs: EdgeTombstoneRecord, rhs: EdgeTombstoneRecord) bool {
            return lhs.edge_id < rhs.edge_id;
        }

        pub fn buildActiveNodeSet(allocator: std.mem.Allocator, graph: *const graph_mod.Graph) !ActiveNodeSet {
            var count: u64 = 0;
            var max_node_id: u64 = 0;
            for (graph.nodes.items) |node| {
                if (node.status != .active) continue;
                try graph_mod.validateNodeText(node.text);
                const id = node.id.toInt();
                if (id == 0 or id == std.math.maxInt(u64)) return core.Error.InvalidId;
                count = std.math.add(u64, count, 1) catch return error.InvalidRecord;
                max_node_id = @max(max_node_id, id);
            }

            if (try activeNodeSetShouldUseDense(max_node_id, count)) {
                const bit_count = std.math.cast(usize, max_node_id) orelse return error.RecordTooLarge;
                var out = ActiveNodeSet{
                    .allocator = allocator,
                    .ids = .{ .dense = .{ .bits = try std.DynamicBitSetUnmanaged.initEmpty(allocator, bit_count) } },
                    .count = count,
                };
                errdefer out.deinit();
                for (graph.nodes.items) |node| {
                    if (node.status != .active) continue;
                    const index = std.math.cast(usize, node.id.toInt() - 1) orelse return error.RecordTooLarge;
                    if (out.ids.dense.bits.isSet(index)) return core.Error.InvalidId;
                    out.ids.dense.bits.set(index);
                }
                return out;
            }

            var out = ActiveNodeSet{
                .allocator = allocator,
                .ids = .{ .sparse = std.AutoHashMap(u64, void).init(allocator) },
                .count = count,
            };
            errdefer out.deinit();
            try out.ids.sparse.ensureTotalCapacity(@intCast(count));
            for (graph.nodes.items) |node| {
                if (node.status != .active) continue;
                const entry = try out.ids.sparse.getOrPut(node.id.toInt());
                if (entry.found_existing) return core.Error.InvalidId;
            }
            return out;
        }

        pub fn activeNodeSetShouldUseDense(max_node_id: u64, count: u64) !bool {
            if (count == 0 or max_node_id == 0 or max_node_id > active_node_set_dense_max_id) return false;
            const scaled = std.math.mul(u64, count, active_node_set_dense_ratio) catch active_node_set_dense_max_id;
            return max_node_id <= @max(active_node_set_dense_min_id, scaled);
        }

        pub fn visibleEdgeRecord(active_nodes: *const ActiveNodeSet, edge: graph_mod.Edge) !?EdgeIndexRecord {
            if (edge.status != .active) return null;
            return physicalEdgeRecord(active_nodes, edge);
        }

        pub fn physicalEdgeRecord(active_nodes: *const ActiveNodeSet, edge: graph_mod.Edge) !?EdgeIndexRecord {
            if (edge.status != .active and edge.status != .deleted) return null;
            const edge_id = edge.id.toInt();
            const src = edge.src.toInt();
            const dst = edge.dst.toInt();
            if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return core.Error.InvalidId;
            if (src == 0 or dst == 0 or src == std.math.maxInt(u64) or dst == std.math.maxInt(u64)) return core.Error.InvalidId;
            if (!active_nodes.contains(src) or !active_nodes.contains(dst)) return null;
            return .{
                .src = src,
                .dst = dst,
                .edge_id = edge_id,
                .rel = @intFromEnum(edge.rel),
            };
        }

        pub fn edgeIndexRecordKey(record: EdgeIndexRecord, order: EdgeIndexOrder) u64 {
            return switch (order) {
                .id => record.edge_id,
                .src => record.src,
                .dst => record.dst,
            };
        }

        pub fn edgeIndexRecordNodeRelLessThan(record: EdgeIndexRecord, order: EdgeIndexOrder, key: u64, rel: u16) bool {
            const record_key = edgeIndexRecordKey(record, order);
            if (record_key != key) return record_key < key;
            return switch (order) {
                .src, .dst => record.rel < rel,
                .id => false,
            };
        }

        pub fn nodeTextHash(text: []const u8) u64 {
            return std.hash.Wyhash.hash(0, text);
        }

        pub fn nodeTextIndexLessThan(_: void, lhs: NodeTextIndexRecord, rhs: NodeTextIndexRecord) bool {
            if (lhs.hash != rhs.hash) return lhs.hash < rhs.hash;
            if (lhs.id != rhs.id) return lhs.id < rhs.id;
            return lhs.kind < rhs.kind;
        }

        pub fn nodeTextIndexOrderDigestStepParts(previous: u64, position: u64, hash: u64, id: u64, kind: u16) u64 {
            var bytes: [34]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], previous, .little);
            std.mem.writeInt(u64, bytes[8..16], position, .little);
            std.mem.writeInt(u64, bytes[16..24], hash, .little);
            std.mem.writeInt(u64, bytes[24..32], id, .little);
            std.mem.writeInt(u16, bytes[32..34], kind, .little);
            return std.hash.Wyhash.hash(0x544B_474D, &bytes);
        }

        pub fn nodeTextIndexOrderDigestStep(previous: u64, position: u64, record: NodeTextIndexRecord) u64 {
            return nodeTextIndexOrderDigestStepParts(previous, position, record.hash, record.id, record.kind);
        }

        pub const combinedNodeTextOrderDigest = node_text_run_manifest_format.combinedOrderDigestBaseDelta;
        pub const combinedNodeTextOrderDigestWithRuns = node_text_run_manifest_format.combinedOrderDigestWithOwnedEntries;
        pub const combinedNodeTextOrderDigestWithRunEntries = node_text_run_manifest_format.combinedOrderDigestWithEntries;

        pub fn nodeTextBaseHeaderCoversMeta(base: NodeTextIndexHeader, meta: IndexMeta) bool {
            return base.node_count == meta.nodes and
                base.node_digest == meta.node_digest and
                base.order_digest == meta.node_by_text_order_digest;
        }

        pub const nodeTextRunManifestTotalNodesOwned = node_text_run_manifest_format.totalNodesOwned;
        pub const nodeTextRunManifestDigestOwned = node_text_run_manifest_format.digestOwned;
        pub const nodeTextRunManifestEntryMayContainHash = node_text_run_manifest_format.entryMayContainHash;

        pub fn nodeTextLookupRunMayContainHash(run: NodeTextLookupRun, hash: u64) bool {
            return nodeTextRunHashFilterMayContain(run.hash_filter, hash);
        }

        pub const nodeTextRunHashFilterShouldBuild = node_text_run_manifest_format.hashFilterShouldBuild;
        pub const nodeTextRunHashFilterLenForRecords = node_text_run_manifest_format.hashFilterLenForRecords;
        pub const nodeTextRunHashFilterLenValid = node_text_run_manifest_format.hashFilterLenValid;

        pub fn nodeTextBaseHashFilterLenForRecords(record_count: u64) usize {
            if (record_count < node_text_base_hash_filter_min_records) return 0;
            const target_bytes = std.math.mul(u64, record_count, node_text_base_hash_filter_target_bytes_per_record) catch std.math.maxInt(u64);
            const clamped = @min(@max(target_bytes, node_text_base_hash_filter_min_bytes), node_text_base_hash_filter_max_bytes);
            const filter_len = std.math.ceilPowerOfTwoAssert(usize, @intCast(clamped));
            return @min(filter_len, node_text_base_hash_filter_max_bytes);
        }

        pub fn nodeTextBaseHashFilterLenValid(filter_len: u64) bool {
            if (filter_len == 0) return false;
            if (filter_len < node_text_base_hash_filter_min_bytes) return false;
            if (filter_len > node_text_base_hash_filter_max_bytes) return false;
            return std.math.isPowerOfTwo(filter_len);
        }

        pub fn nodeTextHashFilterDigest(filter: []const u8) u64 {
            return std.hash.Wyhash.hash(0x544B_4E42, filter);
        }

        pub const nodeTextRunHashFilterSet = node_text_run_manifest_format.hashFilterSet;
        pub const nodeTextRunHashFilterMayContain = node_text_run_manifest_format.hashFilterMayContain;
        pub const nodeTextRunManifestEpochDigestOwned = node_text_run_manifest_format.epochDigestOwned;
        pub const nodeTextRunManifestContentDigestOwned = node_text_run_manifest_format.contentDigestOwned;
        pub const nodeTextRunManifestContentDigest = node_text_run_manifest_format.contentDigest;
        pub const encodeNodeTextRunManifestHeader = node_text_run_manifest_format.encodeHeader;
        pub const decodeNodeTextRunManifestHeader = node_text_run_manifest_format.decodeHeader;
        pub const encodeNodeTextRunManifestEntryHeader = node_text_run_manifest_format.encodeEntryHeader;
        pub const decodeNodeTextRunManifestEntryHeader = node_text_run_manifest_format.decodeEntryHeader;

        pub fn storedNodeIdLessThan(_: void, lhs: StoredNode, rhs: StoredNode) bool {
            return lhs.id.toInt() < rhs.id.toInt();
        }

        pub fn nodeIdLessThan(_: void, lhs: core.NodeId, rhs: core.NodeId) bool {
            return lhs.toInt() < rhs.toInt();
        }

        pub fn validateNodeTextLookupRecord(record: NodeTextIndexRecord, by_id: NodeByIdRecord, kind: core.NodeKind, text_len: usize) !void {
            const expected_len = std.math.cast(u32, text_len) orelse return error.InvalidRecord;
            if (by_id.id != record.id) return error.InvalidRecord;
            if ((try by_id.nodeKind()) != kind) return error.InvalidRecord;
            if (by_id.text_offset != record.text_offset) return error.InvalidRecord;
            if (by_id.text_len != record.text_len) return error.InvalidRecord;
            if (record.text_len != expected_len) return error.InvalidRecord;
        }

        pub const NodeTextIndexDigest = struct {
            count: u64 = 0,
            digest: u64 = 0,
            order_digest: u64 = 0,
            min_node_id: u64 = 0,
            max_node_id: u64 = 0,
            min_hash: u64 = 0,
            max_hash: u64 = 0,

            pub fn add(self: *NodeTextIndexDigest, record: NodeTextIndexRecord, record_digest: u64) void {
                self.order_digest = nodeTextIndexOrderDigestStep(self.order_digest, self.count, record);
                self.digest ^= record_digest;
                if (self.count == 0 or record.id < self.min_node_id) self.min_node_id = record.id;
                if (record.id > self.max_node_id) self.max_node_id = record.id;
                if (self.count == 0 or record.hash < self.min_hash) self.min_hash = record.hash;
                if (self.count == 0 or record.hash > self.max_hash) self.max_hash = record.hash;
                self.count += 1;
            }
        };

        pub fn nameSpanLessThan(_: void, lhs: TextSpan, rhs: TextSpan) bool {
            if (lhs.offset != rhs.offset) return lhs.offset < rhs.offset;
            return lhs.len < rhs.len;
        }

        pub fn textSpansCoverTextsFile(spans: []TextSpan, texts_size: u64) bool {
            std.mem.sort(TextSpan, spans, {}, nameSpanLessThan);
            var cursor: u64 = 0;
            var previous: ?TextSpan = null;
            for (spans) |span| {
                if (previous) |prev| {
                    if (prev.offset == span.offset and prev.len == span.len) continue;
                }
                previous = span;
                if (span.offset != cursor) return false;
                cursor = std.math.add(u64, cursor, span.len) catch return false;
            }
            return cursor == texts_size;
        }

        pub fn isReservedNodeId(id: core.NodeId) bool {
            return id == .none or id.toInt() == std.math.maxInt(u64);
        }

        pub fn edgeIndexFileSize(edge_count: u64) !u64 {
            return edgeIndexFileSizeWithRecordLen(edge_count, EdgeIndexRecord.encoded_len);
        }

        pub fn edgeIndexFileSizeForHeader(header: EdgeIndexHeader) !u64 {
            try header.validateShape();
            const directory_size = try edgeIndexKeyRunDirectorySizeForHeader(header);
            const rows_size = std.math.mul(u64, header.edge_count, header.record_len) catch return error.InvalidRecord;
            const with_directory = std.math.add(u64, EdgeIndexHeader.encoded_len, directory_size) catch return error.InvalidRecord;
            return std.math.add(u64, with_directory, rows_size) catch return error.InvalidRecord;
        }

        pub fn edgeIndexFileSizeWithRecordLen(edge_count: u64, record_len: u16) !u64 {
            if (record_len == 0) return error.InvalidRecord;
            const max_records_size = std.math.maxInt(u64) - EdgeIndexHeader.encoded_len;
            if (edge_count > max_records_size / record_len) return error.InvalidRecord;
            return EdgeIndexHeader.encoded_len + edge_count * record_len;
        }

        pub fn edgeTombstoneFileSize(count: u64) !u64 {
            const max_records_size = std.math.maxInt(u64) - EdgeTombstoneHeader.encoded_len;
            if (count > max_records_size / EdgeTombstoneRecord.encoded_len) return error.InvalidRecord;
            return EdgeTombstoneHeader.encoded_len + count * EdgeTombstoneRecord.encoded_len;
        }

        pub fn edgeTombstoneRecordOffset(index: u64) !u64 {
            const bytes = std.math.mul(u64, index, EdgeTombstoneRecord.encoded_len) catch return error.InvalidRecord;
            return std.math.add(u64, EdgeTombstoneHeader.encoded_len, bytes) catch return error.InvalidRecord;
        }

        pub fn edgeIndexRecordOffset(index: u64) !u64 {
            return edgeIndexRecordOffsetWithLen(index, EdgeIndexRecord.encoded_len);
        }

        pub fn edgeIndexRecordOffsetForHeader(header: EdgeIndexHeader, index: u64) !u64 {
            try header.validateShape();
            const directory_size = try edgeIndexKeyRunDirectorySizeForHeader(header);
            const rows_base = std.math.add(u64, EdgeIndexHeader.encoded_len, directory_size) catch return error.InvalidRecord;
            const bytes = std.math.mul(u64, index, header.record_len) catch return error.InvalidRecord;
            return std.math.add(u64, rows_base, bytes) catch return error.InvalidRecord;
        }

        pub fn edgeIndexRecordOffsetWithLen(index: u64, record_len: u16) !u64 {
            const bytes = std.math.mul(u64, index, record_len) catch return error.InvalidRecord;
            return std.math.add(u64, EdgeIndexHeader.encoded_len, bytes) catch return error.InvalidRecord;
        }

        pub fn nodeByIdFileSize(max_node_id: u64) !u64 {
            return nodeByIdFileSizeWithRecordLen(max_node_id, NodeByIdRecord.encoded_len);
        }

        pub fn nodeByIdFileSizeForHeader(header: NodeByIdHeader) !u64 {
            try header.validateShape();
            const records_size = try nodeByIdRecordsByteLen(header.max_node_id, header.record_len);
            var size = try std.math.add(u64, NodeByIdHeader.encoded_len, records_size);
            if (header.hasDerivedTextOffset()) {
                const checkpoints = try nodeByIdTextOffsetCheckpointCount(header);
                const checkpoint_bytes = std.math.mul(u64, checkpoints, 8) catch return error.InvalidRecord;
                size = std.math.add(u64, size, checkpoint_bytes) catch return error.InvalidRecord;
            }
            return size;
        }

        pub fn nodeByIdFileSizeWithRecordLen(max_node_id: u64, record_len: u16) !u64 {
            if (record_len == 0) return error.InvalidRecord;
            const records_size = try nodeByIdRecordsByteLen(max_node_id, record_len);
            return std.math.add(u64, NodeByIdHeader.encoded_len, records_size) catch return error.InvalidRecord;
        }

        pub fn nodeByIdRecordsByteLen(max_node_id: u64, record_len: u16) !u64 {
            if (record_len == 0) return error.InvalidRecord;
            return std.math.mul(u64, max_node_id, record_len) catch return error.InvalidRecord;
        }

        pub fn nodeByIdRecordOffset(node_id: u64) !u64 {
            return nodeByIdRecordOffsetWithLen(node_id, NodeByIdRecord.encoded_len);
        }

        pub fn nodeByIdRecordOffsetForHeader(header: NodeByIdHeader, node_id: u64) !u64 {
            try header.validateShape();
            return nodeByIdRecordOffsetWithLen(node_id, header.record_len);
        }

        pub fn nodeByIdRecordOffsetWithLen(node_id: u64, record_len: u16) !u64 {
            if (node_id == 0) return error.InvalidRecord;
            const index = node_id - 1;
            const bytes = std.math.mul(u64, index, record_len) catch return error.InvalidRecord;
            return std.math.add(u64, NodeByIdHeader.encoded_len, bytes) catch return error.InvalidRecord;
        }

        pub const node_by_id_text_offset_checkpoint_stride: u64 = 128;

        pub fn nodeByIdTextOffsetCheckpointCount(header: NodeByIdHeader) !u64 {
            try header.validateShape();
            if (!header.hasDerivedTextOffset()) return 0;
            return header.max_node_id / node_by_id_text_offset_checkpoint_stride +
                @intFromBool((header.max_node_id % node_by_id_text_offset_checkpoint_stride) != 0);
        }

        pub fn nodeByIdTextOffsetCheckpointBlock(node_id: u64) !u64 {
            if (node_id == 0) return error.InvalidRecord;
            return (node_id - 1) / node_by_id_text_offset_checkpoint_stride;
        }

        pub fn nodeByIdTextOffsetCheckpointTableOffset(header: NodeByIdHeader) !u64 {
            try header.validateShape();
            const records_size = try nodeByIdRecordsByteLen(header.max_node_id, header.record_len);
            return std.math.add(u64, NodeByIdHeader.encoded_len, records_size) catch return error.InvalidRecord;
        }

        pub fn nodeByIdTextOffsetCheckpointOffset(header: NodeByIdHeader, block: u64) !u64 {
            const checkpoint_count = try nodeByIdTextOffsetCheckpointCount(header);
            if (block >= checkpoint_count) return error.InvalidRecord;
            const table_offset = try nodeByIdTextOffsetCheckpointTableOffset(header);
            const byte_offset = std.math.mul(u64, block, 8) catch return error.InvalidRecord;
            return std.math.add(u64, table_offset, byte_offset) catch return error.InvalidRecord;
        }

        pub fn readDerivedNodeByIdTextLenFromMap(header: NodeByIdHeader, map: *const std.Io.File.MemoryMap, node_id: u64) !u32 {
            const offset = try nodeByIdRecordOffsetForHeader(header, node_id);
            const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
            const end = std.math.add(usize, start, 2) catch return error.InvalidRecord;
            if (end > map.memory.len) return error.InvalidRecord;
            return readU16(map.memory[start..end]);
        }

        pub fn deriveNodeByIdTextOffsetFromMap(header: NodeByIdHeader, map: *const std.Io.File.MemoryMap, node_id: u64) !u64 {
            const block = try nodeByIdTextOffsetCheckpointBlock(node_id);
            const checkpoint_offset = try nodeByIdTextOffsetCheckpointOffset(header, block);
            const checkpoint_start = std.math.cast(usize, checkpoint_offset) orelse return error.RecordTooLarge;
            const checkpoint_end = std.math.add(usize, checkpoint_start, 8) catch return error.InvalidRecord;
            if (checkpoint_end > map.memory.len) return error.InvalidRecord;
            var text_offset = readU64(map.memory[checkpoint_start..checkpoint_end]);
            var id = block * node_by_id_text_offset_checkpoint_stride + 1;
            while (id < node_id) : (id += 1) {
                text_offset = std.math.add(u64, text_offset, try readDerivedNodeByIdTextLenFromMap(header, map, id)) catch return error.InvalidRecord;
            }
            return text_offset;
        }

        pub fn nodeTextIndexHeaderForRecords(records: []const NodeTextIndexRecord, node_digest: u64, order_digest: u64) NodeTextIndexHeader {
            return nodeTextIndexHeaderForRecordsWithDerivedSpan(records, node_digest, order_digest, false);
        }

        pub fn nodeTextIndexHeaderForSortedUniqueHashRecords(records: []const NodeTextIndexRecord, node_digest: u64, order_digest: u64) NodeTextIndexHeader {
            var header = nodeTextIndexHeaderForRecords(records, node_digest, order_digest);
            header.setTextHashUnique(sortedNodeTextRecordsHaveUniqueHashes(records));
            return header;
        }

        pub fn sortedNodeTextRecordsHaveUniqueHashes(records: []const NodeTextIndexRecord) bool {
            var previous_hash: ?u64 = null;
            for (records) |record| {
                if (previous_hash) |hash| {
                    if (hash >= record.hash) return false;
                }
                previous_hash = record.hash;
            }
            return records.len != 0;
        }

        pub fn nodeTextIndexHeaderForRecordsWithDerivedSpan(
            records: []const NodeTextIndexRecord,
            node_digest: u64,
            order_digest: u64,
            derived_text_span: bool,
        ) NodeTextIndexHeader {
            if (records.len == 0) {
                return .{ .node_count = 0, .node_digest = node_digest, .order_digest = order_digest };
            }
            const uniform_kind = records[0].kind;
            var has_uniform_kind = true;
            var short_text_len = true;
            var u32_id = true;
            for (records) |record| {
                if (record.kind != uniform_kind) has_uniform_kind = false;
                if (record.text_len > std.math.maxInt(u16)) short_text_len = false;
                if (record.id > std.math.maxInt(u32)) u32_id = false;
            }
            return NodeTextIndexHeader.withShape(
                @intCast(records.len),
                node_digest,
                order_digest,
                if (has_uniform_kind) uniform_kind else null,
                short_text_len,
                u32_id,
                false,
                derived_text_span,
            );
        }

        pub fn nodeTextRecordFitsHeader(header: NodeTextIndexHeader, record: NodeTextIndexRecord) bool {
            if (header.hasUniformKind() and record.kind != header.uniform_kind) return false;
            if (header.hasShortTextLen() and record.text_len > std.math.maxInt(u16)) return false;
            if (header.hasU32Id() and record.id > std.math.maxInt(u32)) return false;
            return true;
        }

        pub fn nodeTextHeaderForTail(old_header: NodeTextIndexHeader, next_count: u64, node_digest: u64, order_digest: u64, records: []const NodeTextIndexRecord) NodeTextIndexHeader {
            var uniform_kind: ?u16 = null;
            if (old_header.hasUniformKind()) {
                uniform_kind = old_header.uniform_kind;
                for (records) |record| {
                    if (record.kind != old_header.uniform_kind) {
                        uniform_kind = null;
                        break;
                    }
                }
            }
            var short_text_len = old_header.hasShortTextLen();
            if (short_text_len) {
                for (records) |record| {
                    if (record.text_len > std.math.maxInt(u16)) {
                        short_text_len = false;
                        break;
                    }
                }
            }
            var u32_id = old_header.hasU32Id();
            if (u32_id) {
                for (records) |record| {
                    if (record.id > std.math.maxInt(u32)) {
                        u32_id = false;
                        break;
                    }
                }
            }
            return NodeTextIndexHeader.withShape(next_count, node_digest, order_digest, uniform_kind, short_text_len, u32_id, false, old_header.hasDerivedTextSpan());
        }

        pub fn nodeTextIndexFileSize(node_count: u64) !u64 {
            const max_records_size = std.math.maxInt(u64) - NodeTextIndexHeader.encoded_len;
            if (node_count > max_records_size / NodeTextIndexRecord.encoded_len) return error.InvalidRecord;
            return NodeTextIndexHeader.encoded_len + node_count * NodeTextIndexRecord.encoded_len;
        }

        pub fn nodeTextIndexFileSizeForHeader(header: NodeTextIndexHeader) !u64 {
            try header.validateShape();
            const max_records_size = std.math.maxInt(u64) - NodeTextIndexHeader.encoded_len;
            if (header.node_count > max_records_size / header.record_len) return error.InvalidRecord;
            return NodeTextIndexHeader.encoded_len + header.node_count * header.record_len;
        }

        pub fn nodeTextIndexRecordOffset(index: u64) !u64 {
            const bytes = std.math.mul(u64, index, NodeTextIndexRecord.encoded_len) catch return error.InvalidRecord;
            return std.math.add(u64, NodeTextIndexHeader.encoded_len, bytes) catch return error.InvalidRecord;
        }

        pub fn nodeTextIndexRecordOffsetForHeader(header: NodeTextIndexHeader, index: u64) !u64 {
            try header.validateShape();
            const bytes = std.math.mul(u64, index, header.record_len) catch return error.InvalidRecord;
            return std.math.add(u64, NodeTextIndexHeader.encoded_len, bytes) catch return error.InvalidRecord;
        }

        pub fn allZero(bytes: []const u8) bool {
            for (bytes) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }

        pub const node_record_digest_fixed_len: usize = 14;
        pub const BinaryRecordKind = binary_event_log_codec.BinaryRecordKind;
        pub const BinaryRecordHeader = binary_event_log_codec.BinaryRecordHeader;
        pub const binaryPayloadChecksum = binary_event_log_codec.binaryPayloadChecksum;
        pub const validateBinaryChecksum = binary_event_log_codec.validateBinaryChecksum;
        pub const validateBinaryChecksumValue = binary_event_log_codec.validateBinaryChecksumValue;
        pub const ensureBinaryPayloadFits = binary_event_log_codec.ensureBinaryPayloadFits;
        pub const appendBinaryHeader = binary_event_log_codec.appendBinaryHeader;
        pub const appendBinaryRecord = binary_event_log_codec.appendBinaryRecord;
        pub const binary_edge_record_len = binary_event_log_codec.binary_edge_record_len;
        pub const binary_edge_delete_record_len = binary_event_log_codec.binary_edge_delete_record_len;
        pub const encodeBinaryRecordHeader = binary_event_log_codec.encodeBinaryRecordHeader;
        pub const encodeBinaryNodeFixedPayload = binary_event_log_codec.encodeBinaryNodeFixedPayload;
        pub const appendBinaryNodeRecordToWriter = binary_event_log_codec.appendBinaryNodeRecordToWriter;
        pub const appendBinaryNodeBatchRecordToWriter = binary_event_log_codec.appendBinaryNodeBatchRecordToWriter;
        pub const appendBinaryEdgeBatchRecordToWriter = binary_event_log_codec.appendBinaryEdgeBatchRecordToWriter;
        pub const encodeBinaryEdgeRecord = binary_event_log_codec.encodeBinaryEdgeRecord;
        pub const encodeBinaryEdgePayload = binary_event_log_codec.encodeBinaryEdgePayload;
        pub const encodeBinaryEdgeDeleteRecord = binary_event_log_codec.encodeBinaryEdgeDeleteRecord;
        pub const replayBinaryRecord = binary_event_log_codec.replayBinaryRecord;
        pub const validateBinaryRecordPayload = binary_event_log_codec.validateBinaryRecordPayload;
        pub const ParsedBinaryNode = binary_event_log_codec.ParsedBinaryNode;
        pub const binary_node_payload_len = binary_event_log_codec.binary_node_payload_len;
        pub const binary_node_batch_base_header_len = binary_event_log_codec.binary_node_batch_base_header_len;
        pub const binary_node_batch_compact_header_len = binary_event_log_codec.binary_node_batch_compact_header_len;
        pub const binary_node_batch_derived_text_offset_header_extra_len = binary_event_log_codec.binary_node_batch_derived_text_offset_header_extra_len;
        pub const binary_node_batch_compact_row_len = binary_event_log_codec.binary_node_batch_compact_row_len;
        pub const binary_node_batch_compact_short_text_len_row_len = binary_event_log_codec.binary_node_batch_compact_short_text_len_row_len;
        pub const binary_node_batch_compact_derived_text_offset_row_len = binary_event_log_codec.binary_node_batch_compact_derived_text_offset_row_len;
        pub const binary_node_batch_compact_short_derived_text_offset_row_len = binary_event_log_codec.binary_node_batch_compact_short_derived_text_offset_row_len;
        pub const binary_node_batch_flag_dense_id = binary_event_log_codec.binary_node_batch_flag_dense_id;
        pub const binary_node_batch_flag_uniform_kind = binary_event_log_codec.binary_node_batch_flag_uniform_kind;
        pub const binary_node_batch_flag_short_text_len = binary_event_log_codec.binary_node_batch_flag_short_text_len;
        pub const binary_node_batch_flag_derived_text_offset = binary_event_log_codec.binary_node_batch_flag_derived_text_offset;
        pub const binary_node_batch_compact_flags = binary_event_log_codec.binary_node_batch_compact_flags;
        pub const binary_node_batch_known_flags = binary_event_log_codec.binary_node_batch_known_flags;
        pub const binary_node_batch_max_count = binary_event_log_codec.binary_node_batch_max_count;
        pub const binary_edge_payload_len = binary_event_log_codec.binary_edge_payload_len;
        pub const binary_edge_batch_base_header_len = binary_event_log_codec.binary_edge_batch_base_header_len;
        pub const binary_edge_batch_compact_fixed_header_len = binary_event_log_codec.binary_edge_batch_compact_fixed_header_len;
        pub const binary_edge_batch_compact_exception_len = binary_event_log_codec.binary_edge_batch_compact_exception_len;
        pub const binary_edge_batch_endpoint_run_len = binary_event_log_codec.binary_edge_batch_endpoint_run_len;
        pub const binary_edge_batch_compact_row_len = binary_event_log_codec.binary_edge_batch_compact_row_len;
        pub const binary_edge_batch_compact_u32_row_len = binary_event_log_codec.binary_edge_batch_compact_u32_row_len;
        pub const binary_edge_batch_flag_dense_id = binary_event_log_codec.binary_edge_batch_flag_dense_id;
        pub const binary_edge_batch_flag_derived_rel = binary_event_log_codec.binary_edge_batch_flag_derived_rel;
        pub const binary_edge_batch_flag_u32_node_ids = binary_event_log_codec.binary_edge_batch_flag_u32_node_ids;
        pub const binary_edge_batch_flag_linear_endpoints = binary_event_log_codec.binary_edge_batch_flag_linear_endpoints;
        pub const binary_edge_batch_compact_flags = binary_event_log_codec.binary_edge_batch_compact_flags;
        pub const binary_edge_batch_known_flags = binary_event_log_codec.binary_edge_batch_known_flags;
        pub const binary_edge_batch_max_rel_exceptions = binary_event_log_codec.binary_edge_batch_max_rel_exceptions;
        pub const binary_edge_batch_max_count = binary_event_log_codec.binary_edge_batch_max_count;
        pub const binary_edge_delete_payload_len = binary_event_log_codec.binary_edge_delete_payload_len;
        pub const max_binary_count_payload_prefix_len = binary_event_log_codec.max_binary_count_payload_prefix_len;
        pub const binary_count_read_chunk_len = binary_event_log_codec.binary_count_read_chunk_len;
        pub const maxBinaryNodeTextLen = binary_event_log_codec.maxBinaryNodeTextLen;
        pub const validateBinaryNodePayload = binary_event_log_codec.validateBinaryNodePayload;
        pub const validateBinaryNodePayloadForCount = binary_event_log_codec.validateBinaryNodePayloadForCount;
        pub const ParsedBinaryNodeBatch = binary_event_log_codec.ParsedBinaryNodeBatch;
        pub const binaryNodeBatchCanUseDenseUniform = binary_event_log_codec.binaryNodeBatchCanUseDenseUniform;
        pub const binaryNodeBatchTextsFitU16 = binary_event_log_codec.binaryNodeBatchTextsFitU16;
        pub const binaryNodeBatchCanDeriveTextOffsets = binary_event_log_codec.binaryNodeBatchCanDeriveTextOffsets;
        pub const binaryNodeBatchCompactRowLen = binary_event_log_codec.binaryNodeBatchCompactRowLen;
        pub const binaryNodeBatchPayloadLen = binary_event_log_codec.binaryNodeBatchPayloadLen;
        pub const binaryNodeBatchCountFromPrefix = binary_event_log_codec.binaryNodeBatchCountFromPrefix;
        pub const validateBinaryNodeBatchHeader = binary_event_log_codec.validateBinaryNodeBatchHeader;
        pub const validateBinaryNodeBatchNode = binary_event_log_codec.validateBinaryNodeBatchNode;
        pub const validateBinaryNodeBatchPayload = binary_event_log_codec.validateBinaryNodeBatchPayload;
        pub const BinaryNodeBatchReader = binary_event_log_codec.BinaryNodeBatchReader;
        pub const ParsedBinaryEdge = binary_event_log_codec.ParsedBinaryEdge;
        pub const BinaryEdgeBatchCompactShape = binary_event_log_codec.BinaryEdgeBatchCompactShape;
        pub const ParsedBinaryEdgeBatch = binary_event_log_codec.ParsedBinaryEdgeBatch;
        pub const BinaryEdgeBatchEndpointRun = binary_event_log_codec.BinaryEdgeBatchEndpointRun;
        pub const validateBinaryEdgePayload = binary_event_log_codec.validateBinaryEdgePayload;
        pub const binaryEdgeBatchDenseDerivedRelShape = binary_event_log_codec.binaryEdgeBatchDenseDerivedRelShape;
        pub const binaryEdgeBatchEndpointRunCount = binary_event_log_codec.binaryEdgeBatchEndpointRunCount;
        pub const binaryEdgeBatchEndpointCanStartRun = binary_event_log_codec.binaryEdgeBatchEndpointCanStartRun;
        pub const binaryEdgeBatchEndpointContinuesRun = binary_event_log_codec.binaryEdgeBatchEndpointContinuesRun;
        pub const binaryEdgeBatchEndpointStartsNewRun = binary_event_log_codec.binaryEdgeBatchEndpointStartsNewRun;
        pub const binaryEdgeBatchPayloadLen = binary_event_log_codec.binaryEdgeBatchPayloadLen;
        pub const validateBinaryEdgeBatchHeader = binary_event_log_codec.validateBinaryEdgeBatchHeader;
        pub const binaryEdgeBatchRelAt = binary_event_log_codec.binaryEdgeBatchRelAt;
        pub const readBinaryEdgeBatchEndpointRun = binary_event_log_codec.readBinaryEdgeBatchEndpointRun;
        pub const binaryEdgeBatchEndpointRunForIndex = binary_event_log_codec.binaryEdgeBatchEndpointRunForIndex;
        pub const validateBinaryEdgeBatchEdge = binary_event_log_codec.validateBinaryEdgeBatchEdge;
        pub const validateBinaryEdgeBatchPayload = binary_event_log_codec.validateBinaryEdgeBatchPayload;
        pub const validateBinaryEdgeDeletePayload = binary_event_log_codec.validateBinaryEdgeDeletePayload;
        pub const nodeKindFromInt = binary_event_log_codec.nodeKindFromInt;
        pub const relKindFromInt = binary_event_log_codec.relKindFromInt;
        pub const appendU16 = binary_event_log_codec.appendU16;
        pub const appendU32 = binary_event_log_codec.appendU32;
        pub const appendU64 = binary_event_log_codec.appendU64;
        pub const writeU48 = binary_event_log_codec.writeU48;
        pub const writeU16 = binary_event_log_codec.writeU16;
        pub const writeU32 = binary_event_log_codec.writeU32;
        pub const writeU64 = binary_event_log_codec.writeU64;
        pub const readU16 = binary_event_log_codec.readU16;
        pub const readU32 = binary_event_log_codec.readU32;
        pub const readU48 = binary_event_log_codec.readU48;
        pub const readU64 = binary_event_log_codec.readU64;
        test "segment header carries format identity" {
            const header = SegmentHeader.init(.nodes, 7);
            try std.testing.expectEqual(SegmentHeader.expected_magic, header.magic);
            try std.testing.expectEqual(SegmentHeader.current_version, header.version);
            try std.testing.expectEqual(SegmentKind.nodes, header.kind);
            try std.testing.expectEqual(@as(u64, 7), header.epoch);
        }

        test "safe durability is the default" {
            const manifest = Manifest{};
            try std.testing.expectEqual(DurabilityMode.safe, manifest.options.durability);
        }

        test "manifest process leases recognize the current process" {
            try std.testing.expect(processIdIsAlive(currentProcessIdForTempPath()));
        }

        test "durability mode controls fsync policy" {
            var index_meta_cache = IndexMetaCache{};
            var node_text_delta_header_cache = NodeTextDeltaHeaderCache{};
            var node_text_delta_run_cache = NodeTextDeltaRunCache{};
            var node_text_run_manifest_cache = NodeTextRunManifestCache{};
            var node_text_base_filter_cache = NodeTextBaseHashFilterCache{};
            const safe_store = Store{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
                .dir_path = ".",
                .events_bin_path = "events.bin",
                .index_meta_path = "index.meta",
                .node_by_id_path = "node_by_id.idx",
                .node_texts_path = "node_texts.dat",
                .node_by_text_path = "node_by_text.idx",
                .node_by_text_base_filter_path = "node_by_text.idx.filter",
                .node_by_text_delta_path = "node_by_text.delta",
                .external_key_index_path = "external_keys.idx",
                .node_props_index_path = "node_props.idx",
                .node_props_values_path = "node_props.values",
                .node_props_overlay_index_path = "node_props_overlay.idx",
                .node_props_overlay_values_path = "node_props_overlay.values",
                .edge_props_overlay_index_path = "edge_props_overlay.idx",
                .edge_props_overlay_values_path = "edge_props_overlay.values",
                .property_payload_index_path = "property_payload.idx",
                .property_payload_values_path = "property_payload.values",
                .property_payload_delta_path = "property_payload.delta",
                .edge_external_key_index_path = "edge_external_keys.idx",
                .node_text_run_manifest_path = "node_text_runs.manifest",
                .node_text_run_current_path = "node_text_runs.current",
                .edge_by_id_path = "edge_by_id.idx",
                .edge_by_src_path = "edge_by_src.idx",
                .edge_by_dst_path = "edge_by_dst.idx",
                .edge_order_path = "edge_order.idx",
                .edge_tombstones_path = "edge_tombstones.idx",
                .edge_segment_manifest_path = "edge_segment.manifest",
                .edge_segment_current_path = "edge_segment_current",
                .catalog_path = "catalog.bin",
                .index_meta_cache = &index_meta_cache,
                .node_text_delta_header_cache = &node_text_delta_header_cache,
                .node_text_delta_run_cache = &node_text_delta_run_cache,
                .node_text_run_manifest_cache = &node_text_run_manifest_cache,
                .node_text_base_filter_cache = &node_text_base_filter_cache,
                .options = .{ .durability = .safe },
            };
            var fast_store = safe_store;
            fast_store.options.durability = .fast;
            try std.testing.expect(selfOptionsNeedSync(safe_store));
            try std.testing.expect(!selfOptionsNeedSync(fast_store));
        }
    };
}
