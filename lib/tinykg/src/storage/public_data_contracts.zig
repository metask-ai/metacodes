/// Stable storage value contracts shared by the public Store façade and
/// implementation owners. This module owns data shape, not persistence.
pub fn StoragePublicDataContracts(comptime Ops: type) type {
    return struct {
        const std = Ops.dep_std;
        const core = Ops.dep_core;
        const retention = Ops.dep_retention;
        const storage_data_plane_support = Ops.dep_storage_data_plane_support;
        const EdgeIndexRecord = Ops.dep_EdgeIndexRecord;

        pub const DurabilityMode = enum {
            /// Buffered writes. The OS may flush later, so a crash can lose recent
            /// append/index work.
            fast,
            /// Syncs append and derived-index file contents before returning. This does
            /// not make multi-file operations fully transactional. On platforms that
            /// support opening and syncing directories, renamed index and metadata files
            /// also fsync their parent directory before returning.
            safe,
        };

        pub const PrimaryTextWriteMode = enum {
            /// Normal stores enter the append-friendly block-deflate representation on
            /// the first non-empty write. Existing non-empty raw stores are never
            /// compressed by a foreground append; maintenance/finalize owns migration.
            normal,
            /// Bulk loaders may keep node_texts.dat raw while ingesting, but must call
            /// finalizePrimaryTextStorage before publishing the finished store.
            bulk_ingest,
        };

        pub const StorageOptions = struct {
            durability: DurabilityMode = .safe,
            primary_text_write_mode: PrimaryTextWriteMode = .normal,
            max_node_by_id_index_bytes: u64 = 2 * 1024 * 1024 * 1024,
            validate_indexes_on_read: bool = false,
            auto_compact_edge_segment_entries: u32 = 128,
            auto_compact_edge_segment_batch_entries: u32 = 0,
            auto_gc_edge_segments: bool = false,
        };

        pub const NodeExternalKeyLookupCache = struct {
            allocator: std.mem.Allocator,
            entries: std.StringHashMap(std.ArrayList(storage_data_plane_support.NodeExternalKeyLookupEntry)),

            pub fn deinit(self: *NodeExternalKeyLookupCache) void {
                var iterator = self.entries.iterator();
                while (iterator.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(self.allocator);
                }
                self.entries.deinit();
            }
        };

        pub const EdgeExternalKeyLookupCache = struct {
            allocator: std.mem.Allocator,
            node_keys: std.AutoHashMap(u64, []u8),
            order_map: std.AutoHashMap(u64, u64),

            pub fn deinit(self: *EdgeExternalKeyLookupCache) void {
                var iterator = self.node_keys.iterator();
                while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
                self.node_keys.deinit();
                self.order_map.deinit();
            }
        };

        pub const EdgeSegmentMaintenanceBudget = struct {
            /// Zero means no segment-count cap.
            max_segments: usize = 0,
            /// Zero means no edge-count cap.
            max_edges: u64 = 0,
        };

        pub const EdgeSegmentMaintenanceResult = struct {
            compacted: bool,
            compacted_edges: u64 = 0,
            compacted_segments: usize = 0,
            gc_deleted_segments: u64 = 0,
            gc_deleted_manifests: u64 = 0,
            manifest_entries_before: usize = 0,
            manifest_entries_after: usize = 0,
        };

        pub const EdgeSegmentGcResult = struct {
            deleted_segments: u64 = 0,
            deleted_manifests: u64 = 0,
        };

        pub const EdgeSegmentRetentionWindow = retention.EdgeSegmentRetentionWindow;
        pub const ManifestProcessLease = retention.ManifestProcessLease;
        pub const EdgeSegmentRetentionRegistry = retention.EdgeSegmentRetentionRegistry;
        pub const EdgeSegmentRegisteredRetentionWindow = retention.EdgeSegmentRegisteredRetentionWindow;
        pub const NodeTextRunRetentionRegistry = retention.NodeTextRunRetentionRegistry;
        pub const NodeTextRunRegisteredRetentionWindow = retention.NodeTextRunRegisteredRetentionWindow;

        pub const EdgeBatchSegmentDeltaStats = struct {
            fast_path_batches: u64 = 0,
            slow_path_batches: u64 = 0,
            slow_path_sorted_batches: u64 = 0,
            slow_path_candidate_ids: u64 = 0,
            segment_publish_batches: u64 = 0,
            segment_publish_edges: u64 = 0,
            segment_publish_ns: u128 = 0,
            segment_publish_manifest_read_ns: u128 = 0,
            segment_publish_segment_write_ns: u128 = 0,
            segment_publish_manifest_write_ns: u128 = 0,
            segment_maintenance_calls: u64 = 0,
            segment_maintenance_ns: u128 = 0,
            base_id_checks: u64 = 0,
            base_id_check_ns: u128 = 0,
            overlay_checks: u64 = 0,
            overlay_check_ns: u128 = 0,
            overlay_entries_considered: u64 = 0,
            overlay_entries_range_skipped: u64 = 0,
            overlay_sidecar_checks: u64 = 0,
            overlay_csr_fallbacks: u64 = 0,
        };

        pub const NodeBatchAppendTimings = struct {
            batches: u64 = 0,
            nodes: u64 = 0,
            repair_retry_count: u64 = 0,
            repair_ns: u128 = 0,
            read_meta_ns: u128 = 0,
            validate_ns: u128 = 0,
            append_texts_ns: u128 = 0,
            append_event_records_ns: u128 = 0,
            by_id_index_ns: u128 = 0,
            node_text_index_ns: u128 = 0,
            meta_write_ns: u128 = 0,
        };

        pub const NodeAppendTimings = struct {
            nodes: u64 = 0,
            next_id_ns: u128 = 0,
            validate_ns: u128 = 0,
            event_bytes_ns: u128 = 0,
            append_texts_ns: u128 = 0,
            append_record_ns: u128 = 0,
            by_id_index_ns: u128 = 0,
            node_text_index_ns: u128 = 0,
            meta_write_ns: u128 = 0,
        };

        pub const PersistentRepairTimings = storage_data_plane_support.repair_session.PersistentRepairTimings;

        pub const NodeTextsCompressionResult = struct {
            compressed: bool = false,
            before_bytes: u64 = 0,
            after_bytes: u64 = 0,
            logical_bytes: u64 = 0,
        };

        pub const PersistentValidateTimings = struct {
            stats_ns: u128 = 0,
            index_files_ns: u128 = 0,
            node_index_ns: u128 = 0,
            node_by_id_scan_ns: u128 = 0,
            node_by_text_scan_ns: u128 = 0,
            node_text_delta_scan_ns: u128 = 0,
            node_text_run_scan_ns: u128 = 0,
            node_text_meta_ns: u128 = 0,
            node_text_hash_cache_enabled: bool = false,
            node_text_hash_cache_bytes: u64 = 0,
            edge_by_id_ns: u128 = 0,
            edge_by_src_ns: u128 = 0,
            edge_by_dst_ns: u128 = 0,
            edge_consistency_ns: u128 = 0,
            edge_tombstone_ns: u128 = 0,
            edge_meta_ns: u128 = 0,
            edge_segment_manifest_read_ns: u128 = 0,
            edge_segment_open_ns: u128 = 0,
            edge_segment_digest_ns: u128 = 0,
        };

        pub const NodeTextDeltaMaintenanceResult = struct {
            compacted: bool,
            delta_records_before: u64 = 0,
            delta_records_after: u64 = 0,
        };

        pub const NodeTextRunMaintenanceResult = struct {
            compacted: bool,
            run_entries_before: usize = 0,
            run_entries_after: usize = 0,
            run_records_before: u64 = 0,
            run_records_after: u64 = 0,
            compacted_run_records: u64 = 0,
            delta_records_before: u64 = 0,
            delta_records_after: u64 = 0,
            gc_deleted_runs: u64 = 0,
        };

        pub const NodeTextRunGcResult = struct {
            deleted_runs: u64 = 0,
            deleted_manifests: u64 = 0,
        };

        pub const SegmentKind = enum(u8) {
            nodes,
            edges,
            strings,
            props,
            tombstones,
            meta,
            index,
        };

        pub const SegmentHeader = extern struct {
            magic: u32,
            version: u16,
            kind: SegmentKind,
            header_len: u16,
            record_count: u64,
            epoch: u64,
            checksum: u64,

            pub const expected_magic: u32 = 0x544B_4731; // TKG1
            pub const current_version: u16 = 1;

            pub fn init(kind: SegmentKind, epoch: u64) SegmentHeader {
                return .{
                    .magic = expected_magic,
                    .version = current_version,
                    .kind = kind,
                    .header_len = @sizeOf(SegmentHeader),
                    .record_count = 0,
                    .epoch = epoch,
                    .checksum = 0,
                };
            }
        };

        pub const Manifest = struct {
            epoch: u64 = 0,
            options: StorageOptions = .{},
        };

        pub const StoreStats = struct {
            nodes: usize = 0,
            edges: usize = 0,
            node_digest: u64 = 0,
            edge_digest: u64 = 0,
        };

        pub const StoredNode = struct {
            id: core.NodeId,
            kind: core.NodeKind,
            text: []u8,

            pub fn deinit(self: *StoredNode, allocator: std.mem.Allocator) void {
                allocator.free(self.text);
            }
        };

        pub const StoredEdgeRef = struct {
            src: core.NodeId,
            dst: core.NodeId,
            edge_id: core.EdgeId,
            rel: core.RelKind,
        };

        pub const NodeRewriteResult = struct {
            nodes_rewritten: u64 = 0,
            edges_rewritten: u64 = 0,
            edges_removed: u64 = 0,
        };

        pub const PropertyOwner = union(enum) {
            node: core.NodeId,
            edge: core.EdgeId,
        };

        pub const PropertyPayloadValue = union(enum) {
            string: []const u8,
            uint: u64,
        };

        pub const PropertyPayloadWrite = struct {
            owner: PropertyOwner,
            key: []const u8,
            value: PropertyPayloadValue,
        };

        /// One entry in the exact on-disk canonical property order. The producer must
        /// yield a globally unique owner/key pair stream sorted by the same ordering
        /// as PropertyPayloadIndexRecord. `string` is borrowed until the next callback.
        pub const SortedPropertyPayloadEntry = struct {
            owner: PropertyOwner,
            key_hash: u64,
            value: PropertyPayloadValue,
        };

        pub const SortedPropertyPayloadNext = *const fn (context: *anyopaque) anyerror!?SortedPropertyPayloadEntry;

        pub const PropertyPayloadUpsertResult = struct {
            writes_applied: usize = 0,
            entries_replaced: usize = 0,
            /// One batch is committed as one delta frame. Exposing this keeps callers
            /// and regression tests honest about lifecycle atomicity without adding
            /// test-only state to Store.
            payload_publish_count: usize = 0,
        };

        pub const PropertyPayloadCompactionResult = struct {
            compacted: bool = false,
            cleanup_pending: bool = false,
            delta_bytes: u64 = 0,
            delta_frames: u64 = 0,
            live_entries: u64 = 0,
        };

        pub const PropertySnapshotValueKind = enum {
            string,
            uint,
        };

        pub const PropertySnapshotEntry = struct {
            owner: PropertyOwner,
            key_hash: u64,
            value_kind: PropertySnapshotValueKind,
            string_len: u32 = 0,
            string_value: []const u8 = &.{},
            uint_value: u64 = 0,
        };

        pub const PropertySnapshot = struct {
            entries: []PropertySnapshotEntry,

            pub fn deinit(self: *PropertySnapshot, allocator: std.mem.Allocator) void {
                for (self.entries) |entry| {
                    if (entry.value_kind == .string) allocator.free(entry.string_value);
                }
                allocator.free(self.entries);
                self.entries = &.{};
            }
        };

        /// One physical contribution to the effective property view. Callers that
        /// need a bounded all-store snapshot can external-sort by
        /// `(owner, key_hash, version)` and retain the greatest version. String
        /// slices are borrowed only for the duration of the visitor call.
        pub const PropertySnapshotLayerEntry = struct {
            owner: PropertyOwner,
            key_hash: u64,
            version: u64,
            value_kind: PropertySnapshotValueKind,
            string_value: []const u8 = &.{},
            uint_value: u64 = 0,
        };

        pub const PropertySnapshotLayerVisitor = *const fn (context: *anyopaque, entry: PropertySnapshotLayerEntry) anyerror!void;
        pub const EdgeIndexRecordVisitor = *const fn (context: *anyopaque, record: EdgeIndexRecord) anyerror!void;

        pub const NodeIndexLayoutHint = struct {
            node_count: u64,
            dense_node_id_base: u32 = 0,
            uniform_kind: ?core.NodeKind = null,
        };

        test "storage public contracts preserve segment header identity" {
            const header = SegmentHeader.init(.nodes, 7);
            try std.testing.expectEqual(SegmentHeader.expected_magic, header.magic);
            try std.testing.expectEqual(SegmentHeader.current_version, header.version);
            try std.testing.expectEqual(SegmentKind.nodes, header.kind);
            try std.testing.expectEqual(@as(u64, 7), header.epoch);
        }

        test "storage public contracts default to safe durability" {
            const manifest = Manifest{};
            try std.testing.expectEqual(DurabilityMode.safe, manifest.options.durability);
        }

        test "storage public contracts keep property owners tagged" {
            const node_owner = PropertyOwner{ .node = .fromInt(7) };
            const edge_owner = PropertyOwner{ .edge = .fromInt(9) };
            try std.testing.expectEqual(@as(u64, 7), node_owner.node.toInt());
            try std.testing.expectEqual(@as(u64, 9), edge_owner.edge.toInt());
        }

        test "storage public contracts maintenance results start empty" {
            const result = EdgeSegmentMaintenanceResult{ .compacted = false };
            try std.testing.expect(!result.compacted);
            try std.testing.expectEqual(@as(u64, 0), result.compacted_edges);
            try std.testing.expectEqual(@as(usize, 0), result.manifest_entries_after);
        }
    };
}
