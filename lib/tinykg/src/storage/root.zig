const std = @import("std");
const store_data_plane_mod = @import("store_data_plane.zig");
const data_plane_support_mod = @import("data_plane_support.zig");
const edge_segment_id_index_mod = @import("edge_segment_id_index.zig");
const node_catalog_index_mod = @import("node_catalog_index.zig");
const public_data_contracts_mod = @import("public_data_contracts.zig");
const node_catalog_read_views_mod = @import("node_catalog_read_views.zig");
const edge_index_read_views_mod = @import("edge_index_read_views.zig");
const edge_segment_build_resources_mod = @import("edge_segment_build_resources.zig");
const published_edge_segments_mod = @import("published_edge_segments.zig");
const builtin = @import("builtin");
const core = @import("../core.zig");
const graph_mod = @import("../graph.zig");
const schema = @import("../schema.zig");
const catalog_mod = @import("../catalog.zig");
const catalog_max_bytes: u64 = 64 * 1024 * 1024;
const segment_mod = @import("../segment.zig");
const segment_bundle = @import("../segment_bundle/storage.zig");
const segment_manifest = @import("../segment_manifest.zig");
const segment_node_index = @import("../segment_node_index.zig");
const snapshot_mod = @import("../snapshot.zig");
const process_liveness = @import("../process_liveness.zig");
const read_only_memory_map = @import("../read_only_memory_map.zig");
const edge_segment_gc_mod = @import("edge_segment_gc.zig");
const edge_segment_maintenance_mod = @import("edge_segment_maintenance.zig");
const edge_segment_merge_mod = @import("edge_segment_merge.zig");
const edge_segment_publication_mod = @import("edge_segment_publication.zig");
const edge_segment_query_opening_mod = @import("edge_segment_query_opening.zig");
const edge_segment_window_compaction_mod = @import("edge_segment_window_compaction.zig");
const edge_repair_index_publication_mod = @import("edge_repair_index_publication.zig");
const edge_tombstone_repair_index_publication_mod = @import("edge_tombstone_repair_index_publication.zig");
const manifest_process_lease_mod = @import("manifest_process_lease.zig");
const node_text_catalog_transaction_mod = @import("node_text_catalog_transaction.zig");
const node_text_lookup_view_data_plane_mod = @import("node_text_lookup_view_data_plane.zig");
const node_text_maintenance_mod = @import("node_text_maintenance.zig");
const node_text_repair_index_publication_mod = @import("node_text_repair_index_publication.zig");
const persistent_rebuild_pipeline_mod = @import("persistent_rebuild_pipeline.zig");
const primary_node_text_mod = @import("primary_node_text.zig");
const node_text_run_gc_mod = @import("node_text_run_gc.zig");
const binary_event_log_codec_mod = @import("binary_event_log_codec.zig");
const binary_event_log_codec = binary_event_log_codec_mod.BinaryEventLogCodec(core, schema.max_node_types, schema.max_relation_types);
const edge_index_format = @import("edge_index_format.zig").EdgeIndexFormat(core, schema.max_relation_types);
const edge_order_format = @import("edge_order_format.zig").EdgeOrderFormat(schema.max_relation_types);
const edge_tombstone_format = @import("edge_tombstone_format.zig");
const external_key_format = @import("external_key_format.zig");
const index_meta_format = @import("index_meta_format.zig").IndexMetaFormat;
const edge_segment_manifest_format = @import("edge_segment_manifest_format.zig").EdgeSegmentManifestFormat(core, segment_mod);
const node_text_format = @import("node_text_format.zig").NodeTextFormat(core, schema.max_node_types);
const node_text_run_manifest_format = @import("node_text_run_manifest_format.zig").NodeTextRunManifestFormat(node_text_format.NodeTextIndexHeader);
const property_format = @import("property_format.zig");
const property_payload_transaction_mod = @import("property_payload_transaction.zig");
const repair_session_mod = @import("repair_session.zig");
const retention = @import("retention.zig");
const store_bootstrap_mod = @import("store_bootstrap.zig");
const store_cache_resources_mod = @import("store_cache_resources.zig");
const store_opening_mod = @import("store_opening.zig");
const store_paths_mod = @import("store_paths.zig");

pub const EdgeIndexOrder = edge_index_format.EdgeIndexOrder;
pub const EdgeIndexHeader = edge_index_format.EdgeIndexHeader;
pub const EdgeIndexRecord = edge_index_format.EdgeIndexRecord;
pub const EdgeOrderRecord = edge_order_format.EdgeOrderRecord;
pub const EdgeOrderRecordVisitor = *const fn (context: *anyopaque, record: EdgeOrderRecord) anyerror!void;
pub const edge_order_header_bytes: u64 = edge_order_format.header_encoded_len;
pub const IndexMeta = index_meta_format.IndexMeta;
pub const NodeByIdHeader = node_text_format.NodeByIdHeader;
pub const NodeByIdRecord = node_text_format.NodeByIdRecord;
pub const NodeTextIndexHeader = node_text_format.NodeTextIndexHeader;
pub const NodeTextIndexRecord = node_text_format.NodeTextIndexRecord;
const StoragePublicDataContractOps = struct {
    pub const dep_std = std;
    pub const dep_core = core;
    pub const dep_retention = retention;
    pub const dep_storage_data_plane_support = storage_data_plane_support;
    pub const dep_EdgeIndexRecord = EdgeIndexRecord;
};
const storage_public_data_contracts = public_data_contracts_mod.StoragePublicDataContracts(StoragePublicDataContractOps);
pub const DurabilityMode = storage_public_data_contracts.DurabilityMode;
pub const PrimaryTextWriteMode = storage_public_data_contracts.PrimaryTextWriteMode;
pub const StorageOptions = storage_public_data_contracts.StorageOptions;
pub const NodeExternalKeyLookupCache = storage_public_data_contracts.NodeExternalKeyLookupCache;
pub const EdgeExternalKeyLookupCache = storage_public_data_contracts.EdgeExternalKeyLookupCache;
pub const EdgeSegmentMaintenanceBudget = storage_public_data_contracts.EdgeSegmentMaintenanceBudget;
pub const EdgeSegmentMaintenanceResult = storage_public_data_contracts.EdgeSegmentMaintenanceResult;
pub const EdgeSegmentGcResult = storage_public_data_contracts.EdgeSegmentGcResult;
pub const EdgeSegmentRetentionWindow = storage_public_data_contracts.EdgeSegmentRetentionWindow;
pub const ManifestProcessLease = storage_public_data_contracts.ManifestProcessLease;
pub const EdgeSegmentRetentionRegistry = storage_public_data_contracts.EdgeSegmentRetentionRegistry;
pub const EdgeSegmentRegisteredRetentionWindow = storage_public_data_contracts.EdgeSegmentRegisteredRetentionWindow;
pub const NodeTextRunRetentionRegistry = storage_public_data_contracts.NodeTextRunRetentionRegistry;
pub const NodeTextRunRegisteredRetentionWindow = storage_public_data_contracts.NodeTextRunRegisteredRetentionWindow;
pub const EdgeBatchSegmentDeltaStats = storage_public_data_contracts.EdgeBatchSegmentDeltaStats;
pub const NodeBatchAppendTimings = storage_public_data_contracts.NodeBatchAppendTimings;
pub const NodeAppendTimings = storage_public_data_contracts.NodeAppendTimings;
pub const PersistentRepairTimings = storage_public_data_contracts.PersistentRepairTimings;
pub const NodeTextsCompressionResult = storage_public_data_contracts.NodeTextsCompressionResult;
pub const PersistentValidateTimings = storage_public_data_contracts.PersistentValidateTimings;
pub const NodeTextDeltaMaintenanceResult = storage_public_data_contracts.NodeTextDeltaMaintenanceResult;
pub const NodeTextRunMaintenanceResult = storage_public_data_contracts.NodeTextRunMaintenanceResult;
pub const NodeTextRunGcResult = storage_public_data_contracts.NodeTextRunGcResult;
pub const SegmentKind = storage_public_data_contracts.SegmentKind;
pub const SegmentHeader = storage_public_data_contracts.SegmentHeader;
pub const Manifest = storage_public_data_contracts.Manifest;
pub const StoreStats = storage_public_data_contracts.StoreStats;
pub const StoredNode = storage_public_data_contracts.StoredNode;
pub const StoredEdgeRef = storage_public_data_contracts.StoredEdgeRef;
pub const NodeRewriteResult = storage_public_data_contracts.NodeRewriteResult;
pub const PropertyOwner = storage_public_data_contracts.PropertyOwner;
pub const PropertyPayloadValue = storage_public_data_contracts.PropertyPayloadValue;
pub const PropertyPayloadWrite = storage_public_data_contracts.PropertyPayloadWrite;
pub const SortedPropertyPayloadEntry = storage_public_data_contracts.SortedPropertyPayloadEntry;
pub const SortedPropertyPayloadNext = storage_public_data_contracts.SortedPropertyPayloadNext;
pub const PropertyPayloadUpsertResult = storage_public_data_contracts.PropertyPayloadUpsertResult;
pub const PropertyPayloadCompactionResult = storage_public_data_contracts.PropertyPayloadCompactionResult;
pub const PropertySnapshotValueKind = storage_public_data_contracts.PropertySnapshotValueKind;
pub const PropertySnapshotEntry = storage_public_data_contracts.PropertySnapshotEntry;
pub const PropertySnapshot = storage_public_data_contracts.PropertySnapshot;
pub const PropertySnapshotLayerEntry = storage_public_data_contracts.PropertySnapshotLayerEntry;
pub const PropertySnapshotLayerVisitor = storage_public_data_contracts.PropertySnapshotLayerVisitor;
pub const EdgeIndexRecordVisitor = storage_public_data_contracts.EdgeIndexRecordVisitor;
pub const NodeIndexLayoutHint = storage_public_data_contracts.NodeIndexLayoutHint;

const PublishedEdgeSegmentResourceOps = struct {
    pub const dep_core = core;
    pub const dep_segment_mod = segment_mod;
    pub const dep_support = storage_data_plane_support;
    pub const dep_EdgeSegmentRegisteredRetentionWindow = EdgeSegmentRegisteredRetentionWindow;
};
const published_edge_segment_resources = published_edge_segments_mod.PublishedEdgeSegmentResources(PublishedEdgeSegmentResourceOps);
pub const PublishedEdgeSegments = published_edge_segment_resources.PublishedEdgeSegments;
pub const PublishedEdgeSegmentsCoverage = published_edge_segment_resources.PublishedEdgeSegmentsCoverage;
pub const PublishedEdgeSegmentsForQuery = published_edge_segment_resources.PublishedEdgeSegmentsForQuery;

var store_temp_nonce: std.atomic.Value(u64) = .init(0);

pub fn propertyKeyHashForLookup(key: []const u8) u64 {
    return storage_data_plane_support.nodePropertyKeyHash(key);
}

pub fn propertyValueHashForStorage(value: []const u8) u64 {
    return storage_data_plane_support.nodePropertyValueHash(value);
}

pub fn edgeFactExternalKeyAlloc(allocator: std.mem.Allocator, src_external_key: []const u8, rel: core.RelKind, dst_external_key: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "edge-fact\x1f{s}\x1f{}\x1f{s}", .{ src_external_key, @intFromEnum(rel), dst_external_key });
}

pub fn orderedEdgeExternalKeyAlloc(allocator: std.mem.Allocator, src_external_key: []const u8, rel: core.RelKind, order_key: u64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "edge-ordered\x1f{s}\x1f{}\x1f{}", .{ src_external_key, @intFromEnum(rel), order_key });
}

pub const Store = struct {
    const OpenNodeTextLookupRun = storage_data_plane_support.node_text_lookup_view_data_plane.OpenRun;
    const NodeTextDeltaRunCache = storage_data_plane_support.node_text_lookup_view_data_plane.DeltaRunCache;
    const NodeTextLookupRun = storage_data_plane_support.node_text_lookup_view_data_plane.Run;
    const LazyFirstNodeTextLookup = storage_data_plane_support.node_text_lookup_view_data_plane.LazyFirst;
    pub const NodeTextLookupView = storage_data_plane_support.node_text_lookup_view_data_plane.View;
    pub const NodeTextLookupTimings = storage_data_plane_support.node_text_lookup_view_data_plane.LookupTimings;
    pub const NodeTextLookupOpenTimings = storage_data_plane_support.node_text_lookup_view_data_plane.OpenTimings;

    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    events_bin_path: []const u8,
    index_meta_path: []const u8,
    node_by_id_path: []const u8,
    node_texts_path: []const u8,
    node_by_text_path: []const u8,
    node_by_text_base_filter_path: []const u8,
    node_by_text_delta_path: []const u8,
    external_key_index_path: []const u8,
    node_props_index_path: []const u8,
    node_props_values_path: []const u8,
    node_props_overlay_index_path: []const u8,
    node_props_overlay_values_path: []const u8,
    edge_props_overlay_index_path: []const u8,
    edge_props_overlay_values_path: []const u8,
    property_payload_index_path: []const u8,
    property_payload_values_path: []const u8,
    property_payload_delta_path: []const u8,
    edge_external_key_index_path: []const u8,
    node_text_run_manifest_path: []const u8,
    node_text_run_current_path: []const u8,
    edge_by_id_path: []const u8,
    edge_by_src_path: []const u8,
    edge_by_dst_path: []const u8,
    edge_order_path: []const u8,
    edge_tombstones_path: []const u8,
    edge_segment_manifest_path: []const u8,
    edge_segment_current_path: []const u8,
    catalog_path: []const u8,
    index_meta_cache: *storage_data_plane_support.IndexMetaCache,
    node_text_delta_header_cache: *storage_data_plane_support.NodeTextDeltaHeaderCache,
    node_text_delta_run_cache: *NodeTextDeltaRunCache,
    node_text_run_manifest_cache: *storage_data_plane_support.NodeTextRunManifestCache,
    node_text_base_filter_cache: *storage_data_plane_support.NodeTextBaseHashFilterCache,
    options: StorageOptions,
    edge_batch_segment_delta_stats: ?*EdgeBatchSegmentDeltaStats = null,
    node_batch_append_timings: ?*NodeBatchAppendTimings = null,
    node_append_timings: ?*NodeAppendTimings = null,

    const StoreDataPlaneSelf = @This();

    const NodeCatalogReadViewOps = struct {
        pub const dep_Store = StoreDataPlaneSelf;
        pub const dep_core = core;
        pub const dep_support = storage_data_plane_support;
        pub const dep_IndexMeta = IndexMeta;
        pub const dep_NodeByIdHeader = NodeByIdHeader;
        pub const dep_NodeByIdRecord = NodeByIdRecord;
        pub const dep_NodeTextsView = storage_data_plane_support.primary_node_text.View;
        pub const dep_StoredNode = StoredNode;
        pub const readNodeByIdRecordFromMap = StoreDataPlaneSelf.readNodeByIdRecordFromMap;
        pub const readNodeByIdRecordAt = StoreDataPlaneSelf.readNodeByIdRecordAt;
        pub const readNodeByIdHeaderFromFile = StoreDataPlaneSelf.readNodeByIdHeaderFromFile;
        pub const nodeByIdFileSizeForHeaderStore = StoreDataPlaneSelf.nodeByIdFileSizeForHeaderStore;
        pub const regularFileSize = StoreDataPlaneSelf.regularFileSize;
        pub const openReadOnlyMemoryMap = StoreDataPlaneSelf.openReadOnlyMemoryMap;
    };
    const node_catalog_read_views = node_catalog_read_views_mod.NodeCatalogReadViews(NodeCatalogReadViewOps);
    pub const NodeIdIterator = node_catalog_read_views.NodeIdIterator;
    pub const NodeByIdIndexView = node_catalog_read_views.NodeByIdIndexView;
    const EdgeBatchNodeExistenceCache = node_catalog_read_views.EdgeBatchNodeExistenceCache;
    pub const NodeRecordView = node_catalog_read_views.NodeRecordView;
    pub const NodeRecordIterator = node_catalog_read_views.NodeRecordIterator;

    const EdgeIndexReadViewOps = struct {
        pub const dep_Store = StoreDataPlaneSelf;
        pub const dep_core = core;
        pub const dep_support = storage_data_plane_support;
        pub const dep_EdgeIndexHeader = EdgeIndexHeader;
        pub const dep_EdgeIndexOrder = EdgeIndexOrder;
        pub const dep_EdgeIndexRecord = EdgeIndexRecord;
        pub const readEdgeTombstoneRecordFromMap = StoreDataPlaneSelf.readEdgeTombstoneRecordFromMap;
        pub const readEdgeIndexRecordFromMap = StoreDataPlaneSelf.readEdgeIndexRecordFromMap;
        pub const readEdgeTombstoneHeaderFromFile = StoreDataPlaneSelf.readEdgeTombstoneHeaderFromFile;
        pub const regularFileSize = StoreDataPlaneSelf.regularFileSize;
        pub const readEdgeTombstoneRecordAt = StoreDataPlaneSelf.readEdgeTombstoneRecordAt;
        pub const readEdgeIndexRecordAt = StoreDataPlaneSelf.readEdgeIndexRecordAt;
        pub const readEdgeIndexKeyRunAt = StoreDataPlaneSelf.readEdgeIndexKeyRunAt;
        pub const openReadOnlyMemoryMap = StoreDataPlaneSelf.openReadOnlyMemoryMap;
    };
    const edge_index_read_views = edge_index_read_views_mod.EdgeIndexReadViews(EdgeIndexReadViewOps);
    const EdgeTombstoneIndexView = edge_index_read_views.EdgeTombstoneIndexView;
    pub const EdgeIndexRecordIterator = edge_index_read_views.EdgeIndexRecordIterator;
    pub const VisibleEdgeIndexRecordIterator = edge_index_read_views.VisibleEdgeIndexRecordIterator;
    const EdgeIndexKeyRunBounds = edge_index_read_views.EdgeIndexKeyRunBounds;
    const EdgeIndexSequentialRecordReader = edge_index_read_views.EdgeIndexSequentialRecordReader;
    const ExplicitEdgeIndexSequentialReader = edge_index_read_views.ExplicitEdgeIndexSequentialReader;

    const EdgeSegmentBuildResourceOps = struct {
        pub const dep_Store = StoreDataPlaneSelf;
        pub const dep_support = storage_data_plane_support;
        pub const dep_segment_mod = segment_mod;
    };
    const edge_segment_build_resources = edge_segment_build_resources_mod.EdgeSegmentBuildResources(EdgeSegmentBuildResourceOps);
    const EdgeAppendTailSpool = edge_segment_build_resources.EdgeAppendTailSpool;
    const EdgeSortedRunSet = edge_segment_build_resources.EdgeSortedRunSet;
    const EdgeSegmentIdIndexSummary = edge_segment_build_resources.EdgeSegmentIdIndexSummary;
    const EdgeSegmentIdRunSet = edge_segment_build_resources.EdgeSegmentIdRunSet;
    const EdgeSegmentIdIndexRunReader = edge_segment_build_resources.EdgeSegmentIdIndexRunReader;
    const EdgeSegmentIdIndexRunHeapEntry = edge_segment_build_resources.EdgeSegmentIdIndexRunHeapEntry;

    const EdgeSegmentIdIndexOps = struct {
        pub const dep_std = std;
        pub const Store_dep = StoreDataPlaneSelf;
        pub const segment_mod_dep = segment_mod;
        pub const EdgeIndexRecord_dep = EdgeIndexRecord;
        pub const EdgeIndexRecordReader_dep = storage_data_plane_support.EdgeIndexRecordReader;
        pub const EdgeSegmentIdIndexHeader_dep = storage_data_plane_support.EdgeSegmentIdIndexHeader;
        pub const EdgeSegmentIdIndex_dep = storage_data_plane_support.EdgeSegmentIdIndex;
        pub const EdgeSegmentIdIndexRunHeapEntry_dep = EdgeSegmentIdIndexRunHeapEntry;
        pub const EdgeSegmentIdIndexRunReader_dep = EdgeSegmentIdIndexRunReader;
        pub const EdgeSegmentIdIndexWriter_dep = storage_data_plane_support.EdgeSegmentIdIndexWriter;
        pub const EdgeSegmentIdRunBuilder_dep = storage_data_plane_support.EdgeSegmentIdRunBuilder;
        pub const EdgeSegmentIdRunSet_dep = EdgeSegmentIdRunSet;
        pub const EdgeSegmentIdSidecarSummary_dep = storage_data_plane_support.EdgeSegmentIdSidecarSummary;
        pub const OwnedEdgeSegmentManifestEntry_dep = storage_data_plane_support.OwnedEdgeSegmentManifestEntry;
        pub const StorageBufferedWriter_dep = storage_data_plane_support.StorageBufferedWriter;
        pub const edgeSegmentIdSidecarSummaryFromCompleteRange_dep = storage_data_plane_support.edgeSegmentIdSidecarSummaryFromCompleteRange;
        pub const regularFileSize_dep = StoreDataPlaneSelf.regularFileSize;
        pub const edge_segment_id_sort_chunk_records_dep = storage_data_plane_support.edge_segment_id_sort_chunk_records;
        pub const edgeSegmentIdDigest_dep = storage_data_plane_support.edgeSegmentIdDigest;
        pub const storageWriteBufferCapacity_dep = storage_data_plane_support.storageWriteBufferCapacity;
        pub const edgeSegmentIdIndexPath_dep = StoreDataPlaneSelf.edgeSegmentIdIndexPath;
        pub const edgeSegmentIdRunSummaryFromRecords_dep = storage_data_plane_support.edgeSegmentIdRunSummaryFromRecords;
        pub const edgeSegmentManifestIdRunSummary_dep = StoreDataPlaneSelf.edgeSegmentManifestIdRunSummary;
        pub const encodeEdgeSegmentIdIndexHeader_dep = storage_data_plane_support.encodeEdgeSegmentIdIndexHeader;
        pub const edgeSegmentManifestCanDeriveEdgeIdDigest_dep = storage_data_plane_support.edgeSegmentManifestCanDeriveEdgeIdDigest;
        pub const sortedSetIntersectsRange_dep = storage_data_plane_support.sortedSetIntersectsRange;
        pub const edgeSegmentManifestRunsCoverEntry_dep = storage_data_plane_support.edgeSegmentManifestRunsCoverEntry;
        pub const lowerBoundU64_dep = storage_data_plane_support.lowerBoundU64;
        pub const edge_segment_id_index_stack_scan_max_dep = storage_data_plane_support.edge_segment_id_index_stack_scan_max;
        pub const currentProcessIdForTempPath_dep = storage_data_plane_support.currentProcessIdForTempPath;
        pub const u64LessThan_dep = storage_data_plane_support.u64LessThan;
        pub const edgeSegmentIdIndexOrderDigestAt_dep = storage_data_plane_support.edgeSegmentIdIndexOrderDigestAt;
        pub const selfOptionsNeedSync_dep = storage_data_plane_support.selfOptionsNeedSync;
        pub const tmpPathFor_dep = StoreDataPlaneSelf.tmpPathFor;
        pub const edgeSegmentIdSidecarSummaryFromCompleteRuns_dep = storage_data_plane_support.edgeSegmentIdSidecarSummaryFromCompleteRuns;
        pub const edgeSegmentIdIndexFileSize_dep = storage_data_plane_support.edgeSegmentIdIndexFileSize;
        pub const store_temp_nonce_dep = &store_temp_nonce;
        pub const renameReplace_dep = StoreDataPlaneSelf.renameReplace;
        pub const openReadOnlyMemoryMap_dep = StoreDataPlaneSelf.openReadOnlyMemoryMap;
        pub const decodeEdgeSegmentIdIndexHeader_dep = storage_data_plane_support.decodeEdgeSegmentIdIndexHeader;
    };
    const edge_segment_id_index = edge_segment_id_index_mod.EdgeSegmentIdIndexOwner(EdgeSegmentIdIndexOps);
    test {
        _ = edge_segment_id_index;
    }

    const NodeCatalogIndexOps = struct {
        pub const dep_std = std;
        pub const dep_core = core;
        pub const dep_graph_mod = graph_mod;
        pub const Store_dep = StoreDataPlaneSelf;
        pub const NodeByIdHeader_dep = NodeByIdHeader;
        pub const NodeByIdRecord_dep = NodeByIdRecord;
        pub const NodeTextIndexHeader_dep = NodeTextIndexHeader;
        pub const NodeTextIndexRecord_dep = NodeTextIndexRecord;
        pub const IndexMeta_dep = IndexMeta;
        pub const NodeTextIndexDigest_dep = storage_data_plane_support.NodeTextIndexDigest;
        pub const NodeTextRepairPublishShape_dep = storage_data_plane_support.node_text_repair_index_publication.PublishShape;
        pub const TextSpan_dep = storage_data_plane_support.TextSpan;
        pub const NodeTextsView_dep = storage_data_plane_support.primary_node_text.View;
        pub const StorageBufferedWriter_dep = storage_data_plane_support.StorageBufferedWriter;
        pub const nodeTextLenFitsU16_dep = storage_data_plane_support.nodeTextLenFitsU16;
        pub const nodeRecordHasShortTextLen_dep = storage_data_plane_support.nodeRecordHasShortTextLen;
        pub const nodeRecordDigestFromParts_dep = storage_data_plane_support.nodeRecordDigestFromParts;
        pub const nodeTextHash_dep = storage_data_plane_support.nodeTextHash;
        pub const nodeByIdFileSizeForHeaderStore_dep = StoreDataPlaneSelf.nodeByIdFileSizeForHeaderStore;
        pub const nodeByIdRecordOffsetForHeader_dep = storage_data_plane_support.nodeByIdRecordOffsetForHeader;
        pub const nodeByIdTextOffsetCheckpointCount_dep = storage_data_plane_support.nodeByIdTextOffsetCheckpointCount;
        pub const nodeByIdTextOffsetCheckpointTableOffset_dep = storage_data_plane_support.nodeByIdTextOffsetCheckpointTableOffset;
        pub const nodeByIdTextOffsetCheckpointOffset_dep = storage_data_plane_support.nodeByIdTextOffsetCheckpointOffset;
        pub const node_by_id_text_offset_checkpoint_stride_dep = storage_data_plane_support.node_by_id_text_offset_checkpoint_stride;
        pub const writeNodeByIdHeader_dep = StoreDataPlaneSelf.writeNodeByIdHeader;
        pub const writeNodeByIdRecordAt_dep = StoreDataPlaneSelf.writeNodeByIdRecordAt;
        pub const extendNodeByIdIndex_dep = StoreDataPlaneSelf.extendNodeByIdIndex;
        pub const readNodeByIdRecordAt_dep = StoreDataPlaneSelf.readNodeByIdRecordAt;
        pub const readNodeByIdRecordFromMap_dep = StoreDataPlaneSelf.readNodeByIdRecordFromMap;
        pub const readDerivedNodeByIdTextLenAt_dep = StoreDataPlaneSelf.readDerivedNodeByIdTextLenAt;
        pub const readNodeTextIndexRecordAtForHeaderWithTexts_dep = StoreDataPlaneSelf.readNodeTextIndexRecordAtForHeaderWithTexts;
        pub const readNodeByIdHeaderFromFile_dep = StoreDataPlaneSelf.readNodeByIdHeaderFromFile;
        pub const openReadOnlyMemoryMap_dep = StoreDataPlaneSelf.openReadOnlyMemoryMap;
        pub const regularFileSize_dep = StoreDataPlaneSelf.regularFileSize;
        pub const nodeTextIndexFileSizeForHeader_dep = storage_data_plane_support.nodeTextIndexFileSizeForHeader;
        pub const nodeTextIndexRecordOffsetForHeader_dep = storage_data_plane_support.nodeTextIndexRecordOffsetForHeader;
        pub const nodeTextIndexHeaderForRecords_dep = storage_data_plane_support.nodeTextIndexHeaderForRecords;
        pub const nodeTextIndexOrderDigestStep_dep = storage_data_plane_support.nodeTextIndexOrderDigestStep;
        pub const nodeTextIndexLessThan_dep = storage_data_plane_support.nodeTextIndexLessThan;
        pub const nodeTextRecordFitsHeader_dep = storage_data_plane_support.nodeTextRecordFitsHeader;
        pub const nodeTextRecordFitsStoredHeader_dep = StoreDataPlaneSelf.nodeTextRecordFitsStoredHeader;
        pub const nodeTextIndexRecordDigestWithTexts_dep = StoreDataPlaneSelf.nodeTextIndexRecordDigestWithTexts;
        pub const nodeTextsLogicalSize_dep = StoreDataPlaneSelf.nodeTextsLogicalSize;
        pub const storage_write_buffer_bytes_dep = storage_data_plane_support.storage_write_buffer_bytes;
        pub const storageWriteBufferCapacity_dep = storage_data_plane_support.storageWriteBufferCapacity;
        pub const renameReplace_dep = StoreDataPlaneSelf.renameReplace;
        pub const selfOptionsNeedSync_dep = storage_data_plane_support.selfOptionsNeedSync;
        pub const node_text_repair_index_publication_dep = storage_data_plane_support.node_text_repair_index_publication;
        pub const node_text_catalog_transaction_dep = storage_data_plane_support.node_text_catalog_transaction;
        pub const StorageNodeTextCatalogContext_dep = storage_data_plane_support.StorageNodeTextCatalogContext;
        pub const tmpPathFor_dep = StoreDataPlaneSelf.tmpPathFor;
        pub const buildActiveNodeSet_dep = storage_data_plane_support.buildActiveNodeSet;
        pub const finalizePrimaryTextStorage_dep = StoreDataPlaneSelf.finalizePrimaryTextStorage;
        pub const writeEmptyNodeTextDelta_dep = StoreDataPlaneSelf.writeEmptyNodeTextDelta;
        pub const deleteNodeTextRunManifest_dep = StoreDataPlaneSelf.deleteNodeTextRunManifest;
        pub const ensureCurrentNodeTextBaseHashFilter_dep = StoreDataPlaneSelf.ensureCurrentNodeTextBaseHashFilter;
    };
    const node_catalog_index = node_catalog_index_mod.NodeCatalogIndexOwner(NodeCatalogIndexOps);
    test {
        _ = node_catalog_index;
    }

    const StoreDataPlaneOwners = struct {
        pub const edge_segment_id_index_owner = edge_segment_id_index;
        pub const node_catalog_index_owner = node_catalog_index;
    };

    const StoreDataPlaneOps = struct {
        pub const dep_Store = StoreDataPlaneSelf;
        pub const dep_owners = StoreDataPlaneOwners;
        pub const dep_std = std;
        pub const dep_builtin = builtin;
        pub const dep_core = core;
        pub const dep_graph_mod = graph_mod;
        pub const dep_schema = schema;
        pub const dep_catalog_mod = catalog_mod;
        pub const dep_catalog_max_bytes = catalog_max_bytes;
        pub const dep_segment_mod = segment_mod;
        pub const dep_segment_bundle = segment_bundle;
        pub const dep_segment_manifest = segment_manifest;
        pub const dep_segment_node_index = segment_node_index;
        pub const dep_snapshot_mod = snapshot_mod;
        pub const dep_read_only_memory_map = read_only_memory_map;
        pub const dep_edge_order_format = edge_order_format;
        pub const dep_index_meta_format = index_meta_format;
        pub const dep_edge_segment_manifest_format = edge_segment_manifest_format;
        pub const dep_node_text_run_manifest_format = node_text_run_manifest_format;
        pub const dep_retention = retention;
        pub const dep_store_paths_mod = store_paths_mod;
        pub const dep_support = storage_data_plane_support;
        pub const dep_EdgeIndexOrder = EdgeIndexOrder;
        pub const dep_EdgeIndexHeader = EdgeIndexHeader;
        pub const dep_EdgeIndexRecord = EdgeIndexRecord;
        pub const dep_EdgeOrderRecord = EdgeOrderRecord;
        pub const dep_EdgeOrderRecordVisitor = EdgeOrderRecordVisitor;
        pub const dep_IndexMeta = IndexMeta;
        pub const dep_NodeByIdHeader = NodeByIdHeader;
        pub const dep_NodeByIdRecord = NodeByIdRecord;
        pub const dep_NodeTextIndexHeader = NodeTextIndexHeader;
        pub const dep_NodeTextIndexRecord = NodeTextIndexRecord;
        pub const dep_StorageOptions = StorageOptions;
        pub const dep_NodeExternalKeyLookupCache = NodeExternalKeyLookupCache;
        pub const dep_EdgeExternalKeyLookupCache = EdgeExternalKeyLookupCache;
        pub const dep_EdgeSegmentMaintenanceBudget = EdgeSegmentMaintenanceBudget;
        pub const dep_EdgeSegmentMaintenanceResult = EdgeSegmentMaintenanceResult;
        pub const dep_EdgeSegmentGcResult = EdgeSegmentGcResult;
        pub const dep_EdgeSegmentRetentionWindow = EdgeSegmentRetentionWindow;
        pub const dep_EdgeSegmentRetentionRegistry = EdgeSegmentRetentionRegistry;
        pub const dep_EdgeSegmentRegisteredRetentionWindow = EdgeSegmentRegisteredRetentionWindow;
        pub const dep_NodeTextRunRetentionRegistry = NodeTextRunRetentionRegistry;
        pub const dep_NodeTextRunRegisteredRetentionWindow = NodeTextRunRegisteredRetentionWindow;
        pub const dep_store_temp_nonce = &store_temp_nonce;
        pub const dep_PersistentRepairTimings = PersistentRepairTimings;
        pub const dep_NodeTextsCompressionResult = NodeTextsCompressionResult;
        pub const dep_PersistentValidateTimings = PersistentValidateTimings;
        pub const dep_NodeTextDeltaMaintenanceResult = NodeTextDeltaMaintenanceResult;
        pub const dep_NodeTextRunMaintenanceResult = NodeTextRunMaintenanceResult;
        pub const dep_NodeTextRunGcResult = NodeTextRunGcResult;
        pub const dep_StoreStats = StoreStats;
        pub const dep_edgeFactExternalKeyAlloc = edgeFactExternalKeyAlloc;
        pub const dep_orderedEdgeExternalKeyAlloc = orderedEdgeExternalKeyAlloc;
        pub const dep_StoredNode = StoredNode;
        pub const dep_StoredEdgeRef = StoredEdgeRef;
        pub const dep_NodeRewriteResult = NodeRewriteResult;
        pub const dep_PropertyOwner = PropertyOwner;
        pub const dep_PropertyPayloadWrite = PropertyPayloadWrite;
        pub const dep_SortedPropertyPayloadNext = SortedPropertyPayloadNext;
        pub const dep_PropertyPayloadUpsertResult = PropertyPayloadUpsertResult;
        pub const dep_PropertyPayloadCompactionResult = PropertyPayloadCompactionResult;
        pub const dep_PropertySnapshotValueKind = PropertySnapshotValueKind;
        pub const dep_PropertySnapshotEntry = PropertySnapshotEntry;
        pub const dep_PropertySnapshot = PropertySnapshot;
        pub const dep_PropertySnapshotLayerEntry = PropertySnapshotLayerEntry;
        pub const dep_PropertySnapshotLayerVisitor = PropertySnapshotLayerVisitor;
        pub const dep_EdgeIndexRecordVisitor = EdgeIndexRecordVisitor;
        pub const dep_NodeIndexLayoutHint = NodeIndexLayoutHint;
        pub const dep_PublishedEdgeSegments = PublishedEdgeSegments;
        pub const dep_PublishedEdgeSegmentsCoverage = PublishedEdgeSegmentsCoverage;
        pub const dep_PublishedEdgeSegmentsForQuery = PublishedEdgeSegmentsForQuery;
        pub const dep_NodeTextLookupRun = StoreDataPlaneSelf.NodeTextLookupRun;
        pub const dep_LazyFirstNodeTextLookup = StoreDataPlaneSelf.LazyFirstNodeTextLookup;
        pub const dep_NodeTextLookupView = StoreDataPlaneSelf.NodeTextLookupView;
        pub const dep_NodeTextLookupTimings = StoreDataPlaneSelf.NodeTextLookupTimings;
        pub const dep_NodeTextLookupOpenTimings = StoreDataPlaneSelf.NodeTextLookupOpenTimings;
        pub const dep_NodeRewriteAction = StoreDataPlaneSelf.NodeRewriteAction;
        pub const dep_NodeTextsAppendRecovery = StoreDataPlaneSelf.NodeTextsAppendRecovery;
        pub const dep_EdgeTombstoneIndexView = StoreDataPlaneSelf.EdgeTombstoneIndexView;
        pub const dep_EdgeIndexRecordIterator = StoreDataPlaneSelf.EdgeIndexRecordIterator;
        pub const dep_VisibleEdgeIndexRecordIterator = StoreDataPlaneSelf.VisibleEdgeIndexRecordIterator;
        pub const dep_UintPropertyRange = StoreDataPlaneSelf.UintPropertyRange;
        pub const dep_NodeIdIterator = StoreDataPlaneSelf.NodeIdIterator;
        pub const dep_NodeByIdIndexView = StoreDataPlaneSelf.NodeByIdIndexView;
        pub const dep_EdgeBatchNodeExistenceCache = StoreDataPlaneSelf.EdgeBatchNodeExistenceCache;
        pub const dep_NodeTextsView = StoreDataPlaneSelf.NodeTextsView;
        pub const dep_NodeRecordView = StoreDataPlaneSelf.NodeRecordView;
        pub const dep_NodeRecordIterator = StoreDataPlaneSelf.NodeRecordIterator;
        pub const dep_EdgeIndexKeyRunBounds = StoreDataPlaneSelf.EdgeIndexKeyRunBounds;
        pub const dep_EdgeIndexSequentialRecordReader = StoreDataPlaneSelf.EdgeIndexSequentialRecordReader;
        pub const dep_ExplicitEdgeIndexSequentialReader = StoreDataPlaneSelf.ExplicitEdgeIndexSequentialReader;
        pub const dep_EdgeAppendTailSpool = StoreDataPlaneSelf.EdgeAppendTailSpool;
        pub const dep_EdgeSortedRunSet = StoreDataPlaneSelf.EdgeSortedRunSet;
        pub const dep_EdgeSegmentIdIndexSummary = StoreDataPlaneSelf.EdgeSegmentIdIndexSummary;
        pub const dep_EdgeIndexBatchWriteResult = StoreDataPlaneSelf.EdgeIndexBatchWriteResult;
        pub const dep_SecondaryRepairKeyRun = StoreDataPlaneSelf.SecondaryRepairKeyRun;
        pub const dep_DenseRingRepairSpoolShape = StoreDataPlaneSelf.DenseRingRepairSpoolShape;
        pub const dep_validateSortedRepairEdgeRecords = StoreDataPlaneSelf.validateSortedRepairEdgeRecords;
        pub const dep_validateSortedRepairEdgeRecordOrder = StoreDataPlaneSelf.validateSortedRepairEdgeRecordOrder;
    };
    const store_data_plane = store_data_plane_mod.StoreDataPlane(StoreDataPlaneOps);

    pub const init = store_data_plane.init;

    pub const initWithOptions = store_data_plane.initWithOptions;

    pub const open = store_data_plane.open;

    pub const openWithOptions = store_data_plane.openWithOptions;

    const allocateOwned = store_data_plane.allocateOwned;

    pub const deinit = store_data_plane.deinit;

    pub const createEmpty = store_data_plane.createEmpty;

    pub const resetEmptyForTests = store_data_plane.resetEmptyForTests;

    pub const appendNode = store_data_plane.appendNode;

    pub const appendNodesBatch = store_data_plane.appendNodesBatch;

    const rollbackNodeAppendFailure = store_data_plane.rollbackNodeAppendFailure;

    const appendNodeRecord = store_data_plane.appendNodeRecord;

    pub const addNode = store_data_plane.addNode;

    pub const updateNode = store_data_plane.updateNode;

    pub const deleteNode = store_data_plane.deleteNode;

    const NodeRewriteAction = union(enum) {
        update: struct {
            node_id: core.NodeId,
            kind: core.NodeKind,
            text: []const u8,
        },
        delete: struct {
            node_id: core.NodeId,
        },

        pub fn nodeId(self: NodeRewriteAction) core.NodeId {
            return switch (self) {
                .update => |update| update.node_id,
                .delete => |delete| delete.node_id,
            };
        }
    };

    const rewriteNodeStore = store_data_plane.rewriteNodeStore;

    pub const appendEdge = store_data_plane.appendEdge;

    pub const appendEdgeIndexed = store_data_plane.appendEdgeIndexed;

    pub const appendEdgeOrderedIndexed = store_data_plane.appendEdgeOrderedIndexed;

    pub const appendEdgesOrderedBatch = store_data_plane.appendEdgesOrderedBatch;

    pub const deleteEdge = store_data_plane.deleteEdge;

    pub const deleteEdgesBatch = store_data_plane.deleteEdgesBatch;

    pub const appendEdgesBatch = store_data_plane.appendEdgesBatch;

    const appendEdgeRecord = store_data_plane.appendEdgeRecord;

    pub const ensureRawNodeTextsFile = store_data_plane.ensureRawNodeTextsFile;

    pub const compressNodeTextsFileIfSmaller = store_data_plane.compressNodeTextsFileIfSmaller;

    pub const compressNodeTextsFileIfSmallerWithResult = store_data_plane.compressNodeTextsFileIfSmallerWithResult;

    pub const finalizePrimaryTextStorage = store_data_plane.finalizePrimaryTextStorage;

    pub const finalizePrimaryTextStorageWithResult = store_data_plane.finalizePrimaryTextStorageWithResult;

    pub const primaryNodeTextLogicalBytes = store_data_plane.primaryNodeTextLogicalBytes;

    const nodeTextsLogicalSize = store_data_plane.nodeTextsLogicalSize;

    const appendNodeTextBytes = store_data_plane.appendNodeTextBytes;

    const appendNodeTextsBatch = store_data_plane.appendNodeTextsBatch;

    const nodeTextsAppendJournalPath = store_data_plane.nodeTextsAppendJournalPath;

    const writeNodeTextsAppendJournal = store_data_plane.writeNodeTextsAppendJournal;

    const cleanupCommittedNodeTextsAppendJournal = store_data_plane.cleanupCommittedNodeTextsAppendJournal;

    const NodeTextsAppendRecovery = storage_data_plane_support.primary_node_text.AppendRecovery;

    const markNodeTextsAppendJournalCommitted = store_data_plane.markNodeTextsAppendJournalCommitted;

    const recoverNodeTextsAppendJournal = store_data_plane.recoverNodeTextsAppendJournal;

    const mutateCompressedNodeTextSlicesInPlace = store_data_plane.mutateCompressedNodeTextSlicesInPlace;

    const deflateNodeTextsBlock = store_data_plane.deflateNodeTextsBlock;

    const appendNodeBatchRecords = store_data_plane.appendNodeBatchRecords;

    const appendBatchMarker = store_data_plane.appendBatchMarker;

    pub const nextNodeId = store_data_plane.nextNodeId;

    pub const nodeIndexLayoutHint = store_data_plane.nodeIndexLayoutHint;

    pub const searchableNodeIndexLayoutHint = store_data_plane.searchableNodeIndexLayoutHint;

    pub const nextEdgeId = store_data_plane.nextEdgeId;

    const readCurrentIndexMeta = store_data_plane.readCurrentIndexMeta;

    pub const loadGraph = store_data_plane.loadGraph;

    /// Replay the canonical event log without publishing derived indexes,
    /// while honoring a caller-owned query deadline. Read-only recovery paths
    /// must not silently shed their time budget when a derived index is bad.
    pub const loadGraphDeadline = store_data_plane.loadGraphDeadline;

    pub const loadSnapshot = store_data_plane.loadSnapshot;

    pub const repairPersistentIndexesFromLog = store_data_plane.repairPersistentIndexesFromLog;

    pub const repairPersistentIndexesFromLogWithTimings = store_data_plane.repairPersistentIndexesFromLogWithTimings;

    pub const validatePersistentIndexes = store_data_plane.validatePersistentIndexes;

    pub const validatePersistentIndexesWithTimings = store_data_plane.validatePersistentIndexesWithTimings;

    pub const validatePersistentIndexFiles = store_data_plane.validatePersistentIndexFiles;

    const refreshIndexesAfterCommittedAppend = store_data_plane.refreshIndexesAfterCommittedAppend;

    pub const hasCatalog = store_data_plane.hasCatalog;

    pub const readCatalog = store_data_plane.readCatalog;

    /// Return the exact canonical catalog bytes.  Reconciliation keeps this
    /// snapshot alive across its guarded replacement so a failed post-write
    /// check can restore the byte-identical prior control plane.
    pub const readCatalogBytesAlloc = store_data_plane.readCatalogBytesAlloc;

    pub const writeCatalog = store_data_plane.writeCatalog;

    /// Restore a previously captured canonical catalog snapshot.  Decode it
    /// first so rollback can never turn arbitrary caller bytes into the
    /// store's schema authority.
    pub const restoreCatalogBytes = store_data_plane.restoreCatalogBytes;

    pub const writeKernelCatalog = store_data_plane.writeKernelCatalog;

    pub const stats = store_data_plane.stats;

    /// Count canonical node records without materializing ids, edges, or
    /// node text. Returning `max_nodes + 1` is a deliberate saturation signal
    /// so admission paths can reject a large log immediately.
    pub const nodeEventCountUpTo = store_data_plane.nodeEventCountUpTo;

    const fileExists = store_data_plane.fileExists;

    const pathExists = store_data_plane.pathExists;

    const anyDerivedGraphCatalogPathExists = store_data_plane.anyDerivedGraphCatalogPathExists;

    const ensureStoreMarkerExists = store_data_plane.ensureStoreMarkerExists;

    const regularFileSize = store_data_plane.regularFileSize;

    const readBinaryRecordHeader = store_data_plane.readBinaryRecordHeader;

    const advanceBinaryOffset = store_data_plane.advanceBinaryOffset;

    const appendRecord = store_data_plane.appendRecord;

    const truncateIncompleteBatchTail = store_data_plane.truncateIncompleteBatchTail;

    const rebuildPersistentIndexesFromLogStreamingReuseTexts = store_data_plane.rebuildPersistentIndexesFromLogStreamingReuseTexts;

    pub const readIndexMeta = store_data_plane.readIndexMeta;

    pub const eventByteCount = store_data_plane.eventByteCount;

    pub const propertyPayloadDeltaByteCount = store_data_plane.propertyPayloadDeltaByteCount;

    const writeIndexMeta = store_data_plane.writeIndexMeta;

    const currentIndexMeta = store_data_plane.currentIndexMeta;

    const currentIndexMetaFromIndexes = store_data_plane.currentIndexMetaFromIndexes;

    const writeIndexMetaFromStats = store_data_plane.writeIndexMetaFromStats;

    const copyNodeTextOrderDigestFromHeader = store_data_plane.copyNodeTextOrderDigestFromHeader;

    const copyEdgeOrderDigestsFromHeaders = store_data_plane.copyEdgeOrderDigestsFromHeaders;

    const edgeIdRunSummaryForIndexFile = store_data_plane.edgeIdRunSummaryForIndexFile;

    const persistentIndexesCurrent = store_data_plane.persistentIndexesCurrent;

    const fastPersistentIndexesCurrent = store_data_plane.fastPersistentIndexesCurrent;

    pub const readEdgeIndexHeader = store_data_plane.readEdgeIndexHeader;

    const readEdgeTombstoneIndexHeader = store_data_plane.readEdgeTombstoneIndexHeader;

    pub const edgeTombstoneCount = store_data_plane.edgeTombstoneCount;

    const visiblePlusTombstoneEdgeCount = store_data_plane.visiblePlusTombstoneEdgeCount;

    pub const visibleEdgeIndexRecordsIterator = store_data_plane.visibleEdgeIndexRecordsIterator;

    /// Stream the complete visible edge set, including a published segment
    /// overlay that has not yet been consolidated into the three base edge
    /// indexes. Memory is bounded by the manifest fan-in; callers that need a
    /// different global order can external-sort the fixed-size records.
    pub const scanVisibleEdgeIndexRecords = store_data_plane.scanVisibleEdgeIndexRecords;

    pub const edgeIndexRecordsByNodeIterator = store_data_plane.edgeIndexRecordsByNodeIterator;

    pub const edgeIndexRecordsByNodeAndRelationIterator = store_data_plane.edgeIndexRecordsByNodeAndRelationIterator;

    pub const readEdgeIndexRecordsByNode = store_data_plane.readEdgeIndexRecordsByNode;

    pub const readEdgeIndexRecordsByNodeOrdered = store_data_plane.readEdgeIndexRecordsByNodeOrdered;

    pub const readEdgeIndexRecordsByNodeOrderedWithOrderMap = store_data_plane.readEdgeIndexRecordsByNodeOrderedWithOrderMap;

    /// Read the physical visible adjacency for one endpoint. This is the
    /// storage-level source of truth for base indexes plus published segment
    /// overlays; query-only virtual edges (for example deferred `based_on`)
    /// are intentionally outside this API.
    pub const readVisibleEdgeIndexRecordsByNode = store_data_plane.readVisibleEdgeIndexRecordsByNode;

    pub const readVisibleEdgeIndexRecordsByNodeLimited = store_data_plane.readVisibleEdgeIndexRecordsByNodeLimited;

    pub const forEachVisibleEdgeIndexRecordByNode = store_data_plane.forEachVisibleEdgeIndexRecordByNode;

    pub const forEachVisibleEdgeIndexRecordByNodeRetained = store_data_plane.forEachVisibleEdgeIndexRecordByNodeRetained;

    /// Ordered traversal sorts this physical adjacency with the edge-order
    /// sidecar after loading; keep the compatibility name for those callers.
    pub const readVisibleEdgeIndexRecordsByNodeForOrderedTraversal = store_data_plane.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal;

    pub const readEdgeIndexRecordsByNodeLimited = store_data_plane.readEdgeIndexRecordsByNodeLimited;

    pub const readEdgeOrderRecordsByNode = store_data_plane.readEdgeOrderRecordsByNode;

    pub const readEdgeOrderMap = store_data_plane.readEdgeOrderMap;

    /// Validate and stream the ordered-edge sidecar without materializing an
    /// O(ordered edges) map. Migration uses this both to publish the target
    /// sidecar once and to feed authoritative order_key values into its
    /// external property sort.
    pub const scanEdgeOrderRecords = store_data_plane.scanEdgeOrderRecords;

    /// Replace this store's order sidecar by streaming a source sidecar and
    /// remapping relation ids. The target file is published atomically after
    /// the complete source digest and target ordering have been validated.
    pub const replaceEdgeOrderIndexRemappedFrom = store_data_plane.replaceEdgeOrderIndexRemappedFrom;

    /// Copy the authoritative order sidecar for edges that survived a COW
    /// rewrite.  Deleted edges may still have stale sidecar records; they are
    /// omitted, while every surviving record must exactly match the target
    /// edge identity and endpoints.
    pub const replaceEdgeOrderIndexFromPresentEdges = store_data_plane.replaceEdgeOrderIndexFromPresentEdges;

    /// 批量 upsert order 记录(按 edge_id 替换旧值;一次读全表+写回)。
    /// markdown re-import 修复用:路径 2 复用的旧投影边保留陈旧 order_key → 与新边撞车
    /// (schema_duplicate_order_key)→ render 乱序;复用点已知该位置的新 key,批量改写。
    pub const upsertEdgeOrderRecordsBatch = store_data_plane.upsertEdgeOrderRecordsBatch;

    /// 测试用:读全 order 索引(order_key 撞车回归锁直接断言索引内容)。
    pub const readAllEdgeOrderRecordsForTest = store_data_plane.readAllEdgeOrderRecordsForTest;

    pub const readNodeById = store_data_plane.readNodeById;

    pub const lookupNodeByExternalKey = store_data_plane.lookupNodeByExternalKey;

    pub const buildNodeExternalKeyLookupCache = store_data_plane.buildNodeExternalKeyLookupCache;

    pub const lookupNodeByExternalKeyCached = store_data_plane.lookupNodeByExternalKeyCached;

    pub const rebuildExternalKeyIndex = store_data_plane.rebuildExternalKeyIndex;

    const writeExternalKeyIndex = store_data_plane.writeExternalKeyIndex;

    pub const lookupNodeIdsByStringProperty = store_data_plane.lookupNodeIdsByStringProperty;

    /// seen-set 去重(Linus 严重4:线性查重让 100K cap 的 property lookup 变 O(n²))。
    pub const lookupEdgeIdsByStringProperty = store_data_plane.lookupEdgeIdsByStringProperty;

    pub const lookupNodeIdsByUintProperty = store_data_plane.lookupNodeIdsByUintProperty;

    pub const UintPropertyRange = struct {
        min: ?u64 = null,
        min_inclusive: bool = true,
        max: ?u64 = null,
        max_inclusive: bool = true,

        pub fn contains(self: UintPropertyRange, value: u64) bool {
            if (self.min) |min| {
                if (self.min_inclusive) {
                    if (value < min) return false;
                } else if (value <= min) return false;
            }
            if (self.max) |max| {
                if (self.max_inclusive) {
                    if (value > max) return false;
                } else if (value >= max) return false;
            }
            return true;
        }
    };

    pub const lookupNodeIdsByUintPropertyRange = store_data_plane.lookupNodeIdsByUintPropertyRange;

    pub const rebuildNodePropertyIndex = store_data_plane.rebuildNodePropertyIndex;

    const readNodePropertyIndexHeaderFromFile = store_data_plane.readNodePropertyIndexHeaderFromFile;

    const readNodePropertyIndexRecordAt = store_data_plane.readNodePropertyIndexRecordAt;

    const readNodePropertyValueBlockHeaderFromFile = store_data_plane.readNodePropertyValueBlockHeaderFromFile;

    const readNodePropertyValueRecordAt = store_data_plane.readNodePropertyValueRecordAt;

    const readPropertyPayloadIndexHeaderFromFile = store_data_plane.readPropertyPayloadIndexHeaderFromFile;

    const readPropertyPayloadIndexRecordAt = store_data_plane.readPropertyPayloadIndexRecordAt;

    const propertyPayloadKeyHashLowerBound = store_data_plane.propertyPayloadKeyHashLowerBound;

    const writeNodePropertyIndex = store_data_plane.writeNodePropertyIndex;

    const parsePropertyPayloadDeltaPayload = store_data_plane.parsePropertyPayloadDeltaPayload;

    const scanPropertyPayloadDelta = store_data_plane.scanPropertyPayloadDelta;

    const readPropertyPayloadEntriesFromFiles = store_data_plane.readPropertyPayloadEntriesFromFiles;

    const writeNodePropertyOverlay = store_data_plane.writeNodePropertyOverlay;

    const readPropertyPayloadEntriesOrEmpty = store_data_plane.readPropertyPayloadEntriesOrEmpty;

    /// Read only one persisted property key. The immutable base is ordered by
    /// key hash, so unrelated values (which may be very large blobs) are never
    /// materialized. Delta frames still have to be validated sequentially,
    /// but only exact persisted key names are retained and latest-wins updates
    /// are applied in O(1) per matching owner instead of rescanning the list.
    /// Materialize only node `name`/`summary` values.  Full-text stale-index
    /// fallback must not allocate unrelated property blobs merely to compute
    /// its metadata digest or snapshot.
    const addSearchableNodeMetadataDigest = store_data_plane.addSearchableNodeMetadataDigest;

    pub const searchableNodeMetadataDigest = store_data_plane.searchableNodeMetadataDigest;

    /// Digest the searchable property view while bounding the append-only
    /// delta scan and honoring the caller's query deadline. Explicit
    /// maintenance and validation continue to use the unbounded variant.
    pub const searchableNodeMetadataDigestLimitedDeadline = store_data_plane.searchableNodeMetadataDigestLimitedDeadline;

    const writePropertyPayload = store_data_plane.writePropertyPayload;

    /// Snapshot only the node metadata consumed by full-text indexing.  The
    /// general property snapshot includes edge fields and arbitrary payloads;
    /// materializing those on a stale-search fallback can turn a bounded node
    /// scan into an unrelated O(all property bytes) allocation.
    pub const loadSearchableNodeMetadataSnapshot = store_data_plane.loadSearchableNodeMetadataSnapshot;

    /// Same snapshot with a hard cap on owned string bytes.  Stale full-text
    /// fallback uses this before building an ephemeral BM25 index so bounded
    /// node text cannot be paired with unbounded `name`/`summary` allocation.
    pub const loadSearchableNodeMetadataSnapshotLimited = store_data_plane.loadSearchableNodeMetadataSnapshotLimited;

    /// Bound both owned searchable strings and canonical property-delta scan
    /// bytes while honoring the caller's query deadline.
    pub const loadSearchableNodeMetadataSnapshotWithLimitsDeadline = store_data_plane.loadSearchableNodeMetadataSnapshotWithLimitsDeadline;

    /// Materialize only the requested node-sidecar keys. This is the bounded
    /// read primitive for callers (notably task DAG walks) that need the same
    /// small property family for many nodes: each key probes the immutable
    /// base and validates the append-only delta once, rather than every node
    /// independently rescanning all property history.
    pub const loadNodePropertySnapshotForKeys = store_data_plane.loadNodePropertySnapshotForKeys;

    pub const loadNodePropertySnapshotForNodeIds = store_data_plane.loadNodePropertySnapshotForNodeIds;

    /// Bounded edge-property snapshot for migration and batch validation.  It
    /// probes only requested key ranges and retains only requested owners while
    /// still validating every append-only delta frame once.
    pub const loadEdgePropertySnapshotForEdgeIds = store_data_plane.loadEdgePropertySnapshotForEdgeIds;

    /// Stream every physical property layer once with explicit precedence.
    /// This validates the legacy overlays, canonical base, and append-only
    /// delta without retaining an all-store owner map. The visitor may spool
    /// fixed-size metadata and values to disk, then external-sort to obtain a
    /// bounded effective snapshot.
    pub const scanPropertySnapshotLayers = store_data_plane.scanPropertySnapshotLayers;

    pub const loadPropertySnapshot = store_data_plane.loadPropertySnapshot;

    pub const appendPropertiesBatch = store_data_plane.appendPropertiesBatch;

    /// Publish a canonical property base from a bounded sorted stream. This is
    /// intentionally restricted to an empty COW target: replacing a live base
    /// would discard concurrent deltas and violate the Store writer contract.
    /// The two-file base is still committed through the normal redo journal.
    pub const replaceEmptyPropertyPayloadFromSortedStream = store_data_plane.replaceEmptyPropertyPayloadFromSortedStream;

    /// Replace or insert several property values with one crash-safe delta
    /// publication.  The immutable base pair is only probed by key and is not
    /// rewritten; write amplification is therefore proportional to this batch.
    /// Duplicate owner/key writes are rejected before any durable mutation.
    pub const upsertPropertiesBatch = store_data_plane.upsertPropertiesBatch;

    /// Merge the append-only property delta into the immutable base pair.
    /// Callers must provide the same external writer exclusion used by other
    /// Store maintenance operations (the CLI holds CliStoreLock).  Publishing
    /// the new base before unlinking the delta is deliberate: a crash in that
    /// window merely replays identical latest-wins values, while deleting the
    /// delta first could lose committed updates.
    pub const compactPropertyPayloadDelta = store_data_plane.compactPropertyPayloadDelta;

    const readPropertyPayloadEntryForKey = store_data_plane.readPropertyPayloadEntryForKey;

    pub const setNodeStringProperty = store_data_plane.setNodeStringProperty;

    pub const getNodeStringProperty = store_data_plane.getNodeStringProperty;

    pub const setEdgeStringProperty = store_data_plane.setEdgeStringProperty;

    pub const getEdgeStringProperty = store_data_plane.getEdgeStringProperty;

    pub const setUintProperty = store_data_plane.setUintProperty;

    pub const getUintProperty = store_data_plane.getUintProperty;

    pub const setStringProperty = store_data_plane.setStringProperty;

    pub const getStringProperty = store_data_plane.getStringProperty;

    pub const lookupEdgeByExternalKey = store_data_plane.lookupEdgeByExternalKey;

    pub const buildEdgeExternalKeyLookupCache = store_data_plane.buildEdgeExternalKeyLookupCache;

    pub const lookupEdgeByExternalKeyCached = store_data_plane.lookupEdgeByExternalKeyCached;

    pub const lookupEdgeRecordByExternalKeyCached = store_data_plane.lookupEdgeRecordByExternalKeyCached;

    pub const lookupFactEdgeByNodeExternalKeys = store_data_plane.lookupFactEdgeByNodeExternalKeys;

    pub const refreshFactEdgeExternalKeyIndexAfterAppend = store_data_plane.refreshFactEdgeExternalKeyIndexAfterAppend;

    pub const rebuildEdgeExternalKeyIndex = store_data_plane.rebuildEdgeExternalKeyIndex;

    const writeEdgeExternalKeyIndex = store_data_plane.writeEdgeExternalKeyIndex;

    pub const nodeExistsById = store_data_plane.nodeExistsById;

    pub const openNodeByIdIndexView = store_data_plane.openNodeByIdIndexView;

    pub const openNodeRecordView = store_data_plane.openNodeRecordView;

    pub const nodeRecordsIterator = store_data_plane.nodeRecordsIterator;

    pub const lookupNodesByText = store_data_plane.lookupNodesByText;

    pub const lookupNodesByTextLimited = store_data_plane.lookupNodesByTextLimited;

    pub const lookupNodesByTextLimitedWithTimings = store_data_plane.lookupNodesByTextLimitedWithTimings;

    pub const lookupNodeIdsByTextLimited = store_data_plane.lookupNodeIdsByTextLimited;

    pub const lookupNodeIdsByTextLimitedWithTimings = store_data_plane.lookupNodeIdsByTextLimitedWithTimings;

    pub const lookupFirstNodeIdByText = store_data_plane.lookupFirstNodeIdByText;

    pub const lookupFirstNodeIdByTextWithTimings = store_data_plane.lookupFirstNodeIdByTextWithTimings;

    pub const openNodeTextLookupView = store_data_plane.openNodeTextLookupView;

    pub const openNodeTextLookupViewWithTimings = store_data_plane.openNodeTextLookupViewWithTimings;

    pub const openNodeTextLookupViewRetained = store_data_plane.openNodeTextLookupViewRetained;

    const refreshNodeTextDeltaRunCache = store_data_plane.refreshNodeTextDeltaRunCache;

    const monotonicNs = store_data_plane.monotonicNs;

    const elapsedNs = store_data_plane.elapsedNs;

    pub const scanNodeIds = store_data_plane.scanNodeIds;

    const ensureNodeByIdIndexView = store_data_plane.ensureNodeByIdIndexView;

    const NodeTextsStorageFormat = storage_data_plane_support.primary_node_text.StorageFormat;
    pub const node_texts_block_deflate_version = storage_data_plane_support.primary_node_text.block_deflate_version;
    const node_texts_block_deflate_header_len = storage_data_plane_support.primary_node_text.block_deflate_header_len;
    const node_texts_block_deflate_entry_len = storage_data_plane_support.primary_node_text.block_deflate_entry_len;
    pub const node_texts_block_deflate_block_bytes = storage_data_plane_support.primary_node_text.block_deflate_block_bytes;
    pub const node_texts_raw_mmap_max_bytes = storage_data_plane_support.primary_node_text.raw_mmap_max_bytes;
    const node_texts_append_journal_checksummed_version = storage_data_plane_support.primary_node_text.append_journal_checksummed_version;
    const node_texts_append_journal_header_len = storage_data_plane_support.primary_node_text.append_journal_header_len;
    const node_texts_append_journal_header_hash_seed = storage_data_plane_support.primary_node_text.append_journal_header_hash_seed;
    const node_texts_deflate_progress_entry_len = storage_data_plane_support.primary_node_text.deflate_progress_entry_len;
    const node_texts_deflate_progress_hash_seed = storage_data_plane_support.primary_node_text.deflate_progress_hash_seed;
    pub const node_texts_block_deflate_level_number = storage_data_plane_support.primary_node_text.block_deflate_level_number;
    pub const node_texts_block_deflate_level = storage_data_plane_support.primary_node_text.block_deflate_level;
    const NodeTextsView = storage_data_plane_support.primary_node_text.View;

    const ensureNodeTextsView = store_data_plane.ensureNodeTextsView;

    pub const nodeIdsIterator = store_data_plane.nodeIdsIterator;

    const readNodeByIdHeaderFromFile = store_data_plane.readNodeByIdHeaderFromFile;

    const readNodeByIdRecordAt = store_data_plane.readNodeByIdRecordAt;

    const readNodeByIdRecordFromMap = store_data_plane.readNodeByIdRecordFromMap;

    const readDerivedNodeByIdTextLenAt = store_data_plane.readDerivedNodeByIdTextLenAt;

    const extendNodeByIdIndex = store_data_plane.extendNodeByIdIndex;

    const readNodeTextIndexHeaderFromFile = store_data_plane.readNodeTextIndexHeaderFromFile;

    const readNodeTextIndexRecordAt = store_data_plane.readNodeTextIndexRecordAt;

    const readNodeTextIndexRecordAtForHeaderWithTexts = store_data_plane.readNodeTextIndexRecordAtForHeaderWithTexts;

    const readNodeTextIndexRecordAtForHeaderWithTextsAndNodes = store_data_plane.readNodeTextIndexRecordAtForHeaderWithTextsAndNodes;

    const readNodeTextIndexRecordHashAtForHeader = store_data_plane.readNodeTextIndexRecordHashAtForHeader;

    const readNodeTextIndexRecordHashFromMapForHeader = store_data_plane.readNodeTextIndexRecordHashFromMapForHeader;

    const readNodeTextIndexRecordFromMapForHeaderWithTexts = store_data_plane.readNodeTextIndexRecordFromMapForHeaderWithTexts;

    const readNodeTextIndexRecordFromMapForHeaderWithTextsAndNodes = store_data_plane.readNodeTextIndexRecordFromMapForHeaderWithTextsAndNodes;

    const readNodeTextRunManifest = store_data_plane.readNodeTextRunManifest;

    const cachedNodeTextRunManifestForMeta = store_data_plane.cachedNodeTextRunManifestForMeta;

    const nodeTextHeaderMatchesBaseFilter = store_data_plane.nodeTextHeaderMatchesBaseFilter;

    const cachedNodeTextBaseHashFilter = store_data_plane.cachedNodeTextBaseHashFilter;

    const nodeTextBaseFilterMatchesCurrentBase = store_data_plane.nodeTextBaseFilterMatchesCurrentBase;

    const readCurrentNodeTextBaseHashFilter = store_data_plane.readCurrentNodeTextBaseHashFilter;

    const ensureNodeTextBaseHashFilter = store_data_plane.ensureNodeTextBaseHashFilter;

    const ensureCurrentNodeTextBaseHashFilter = store_data_plane.ensureCurrentNodeTextBaseHashFilter;

    const readNodeTextRunManifestFile = store_data_plane.readNodeTextRunManifestFile;

    const writeNodeTextRunManifestEntries = store_data_plane.writeNodeTextRunManifestEntries;

    const writeNodeTextRunManifestEntriesExcept = store_data_plane.writeNodeTextRunManifestEntriesExcept;

    const writeNodeTextRunCurrent = store_data_plane.writeNodeTextRunCurrent;

    const readNodeTextRunCurrentPath = store_data_plane.readNodeTextRunCurrentPath;

    pub const readEdgeById = store_data_plane.readEdgeById;

    pub const loadEdgeRefs = store_data_plane.loadEdgeRefs;

    const readAllEdgeTombstones = store_data_plane.readAllEdgeTombstones;

    const readEdgeIndexHeaderFromFile = store_data_plane.readEdgeIndexHeaderFromFile;

    const readEdgeTombstoneHeaderFromFile = store_data_plane.readEdgeTombstoneHeaderFromFile;

    const readEdgeIndexRecordAt = store_data_plane.readEdgeIndexRecordAt;

    const readEdgeTombstoneRecordAt = store_data_plane.readEdgeTombstoneRecordAt;

    const readEdgeIndexRecordFromMap = store_data_plane.readEdgeIndexRecordFromMap;

    const readEdgeIndexKeyRunAt = store_data_plane.readEdgeIndexKeyRunAt;

    const readEdgeTombstoneRecordFromMap = store_data_plane.readEdgeTombstoneRecordFromMap;

    const openReadOnlyMemoryMap = store_data_plane.openReadOnlyMemoryMap;

    const readAllEdgeIndexRecords = store_data_plane.readAllEdgeIndexRecords;

    pub const publishEdgeAdjacencySegment = store_data_plane.publishEdgeAdjacencySegment;

    pub const publishSegmentBundle = store_data_plane.publishSegmentBundle;

    const readEdgeAppendTailSpool = store_data_plane.readEdgeAppendTailSpool;

    const readEdgeTailSortedChunksFromSpool = store_data_plane.readEdgeTailSortedChunksFromSpool;

    pub const compactPublishedEdgeSegments = store_data_plane.compactPublishedEdgeSegments;

    pub const gcUnreferencedEdgeSegments = store_data_plane.gcUnreferencedEdgeSegments;

    pub const currentEdgeSegmentManifestPath = store_data_plane.currentEdgeSegmentManifestPath;

    pub const openEdgeSegmentRetentionWindow = store_data_plane.openEdgeSegmentRetentionWindow;

    pub const openRegisteredEdgeSegmentRetentionWindow = store_data_plane.openRegisteredEdgeSegmentRetentionWindow;

    pub const gcUnreferencedEdgeSegmentsRetainingRegistry = store_data_plane.gcUnreferencedEdgeSegmentsRetainingRegistry;

    pub const gcUnreferencedEdgeSegmentsWithProcessLeases = store_data_plane.gcUnreferencedEdgeSegmentsWithProcessLeases;

    const dropRedundantEdgeSegmentOverlayAfterBaseIndexCatchup = store_data_plane.dropRedundantEdgeSegmentOverlayAfterBaseIndexCatchup;

    pub const gcUnreferencedEdgeSegmentsExceptAndProcessLeases = store_data_plane.gcUnreferencedEdgeSegmentsExceptAndProcessLeases;

    pub const currentNodeTextRunManifestPath = store_data_plane.currentNodeTextRunManifestPath;

    pub const openRegisteredNodeTextRunRetentionWindow = store_data_plane.openRegisteredNodeTextRunRetentionWindow;

    pub const gcUnreferencedNodeTextRunsRetainingRegistry = store_data_plane.gcUnreferencedNodeTextRunsRetainingRegistry;

    pub const gcUnreferencedNodeTextRunsWithProcessLeases = store_data_plane.gcUnreferencedNodeTextRunsWithProcessLeases;

    pub const gcUnreferencedNodeTextRunsExceptAndProcessLeases = store_data_plane.gcUnreferencedNodeTextRunsExceptAndProcessLeases;

    const manifestProcessLeaseDirPath = store_data_plane.manifestProcessLeaseDirPath;

    const currentManifestPathForProcessLease = store_data_plane.currentManifestPathForProcessLease;

    pub const gcUnreferencedEdgeSegmentsExcept = store_data_plane.gcUnreferencedEdgeSegmentsExcept;

    pub const autoCompactEdgeSegmentsIfNeeded = store_data_plane.autoCompactEdgeSegmentsIfNeeded;

    pub const compactEdgeSegmentsBudgeted = store_data_plane.compactEdgeSegmentsBudgeted;

    pub const compactEdgeSegmentsBudgetedRetainingRegistry = store_data_plane.compactEdgeSegmentsBudgetedRetainingRegistry;

    pub const compactEdgeSegmentsBudgetedWithProcessLeases = store_data_plane.compactEdgeSegmentsBudgetedWithProcessLeases;

    pub const compactEdgeSegmentsBudgetedExceptAndProcessLeases = store_data_plane.compactEdgeSegmentsBudgetedExceptAndProcessLeases;

    pub const compactEdgeSegmentsBudgetedExcept = store_data_plane.compactEdgeSegmentsBudgetedExcept;

    const compactEdgeSegmentManifestRange = store_data_plane.compactEdgeSegmentManifestRange;

    const edgeAutoCompactedSegmentPath = store_data_plane.edgeAutoCompactedSegmentPath;

    const edgeSegmentManifestCoveredPhysicalEdges = store_data_plane.edgeSegmentManifestCoveredPhysicalEdges;

    const edgeSegmentManifestCoversVisibleEdges = store_data_plane.edgeSegmentManifestCoversVisibleEdges;

    pub const forEachPublishedEdgeSegmentNeighbor = store_data_plane.forEachPublishedEdgeSegmentNeighbor;

    pub const forEachOpenedPublishedEdgeSegmentNeighbor = store_data_plane.forEachOpenedPublishedEdgeSegmentNeighbor;

    pub const openPublishedEdgeSegment = store_data_plane.openPublishedEdgeSegment;

    pub const openPublishedEdgeSegments = store_data_plane.openPublishedEdgeSegments;

    pub const openPublishedEdgeSegmentsForQuery = store_data_plane.openPublishedEdgeSegmentsForQuery;

    pub const openPublishedEdgeSegmentsForQueryRetained = store_data_plane.openPublishedEdgeSegmentsForQueryRetained;

    pub const openPublishedEdgeSegmentsForQueryForNode = store_data_plane.openPublishedEdgeSegmentsForQueryForNode;

    pub const openPublishedEdgeSegmentsForQueryForNodeRetained = store_data_plane.openPublishedEdgeSegmentsForQueryForNodeRetained;

    const openPublishedEdgeSegmentDataForQuery = store_data_plane.openPublishedEdgeSegmentDataForQuery;

    const edgeSegmentManifestTotalEdges = store_data_plane.edgeSegmentManifestTotalEdges;

    const edgeSegmentManifestSummary = store_data_plane.edgeSegmentManifestSummary;

    const edgeSegmentManifestIdRunSummary = store_data_plane.edgeSegmentManifestIdRunSummary;

    const updateIndexMetaEdgeSegmentSummary = store_data_plane.updateIndexMetaEdgeSegmentSummary;

    const writeEdgeSegmentManifestEntries = store_data_plane.writeEdgeSegmentManifestEntries;

    const edgeSegmentManifestDigest = store_data_plane.edgeSegmentManifestDigest;

    const edgeSegmentManifestOwnedDigest = store_data_plane.edgeSegmentManifestOwnedDigest;

    const edgeSegmentManifestEpochPath = store_data_plane.edgeSegmentManifestEpochPath;

    const restoreEdgeSegmentManifestPath = store_data_plane.restoreEdgeSegmentManifestPath;

    const writeEdgeSegmentManifestFile = store_data_plane.writeEdgeSegmentManifestFile;

    const edgeSegmentIdIndexPath = store_data_plane.edgeSegmentIdIndexPath;

    const writeEdgeSegmentIdIndexFromSegment = store_data_plane.writeEdgeSegmentIdIndexFromSegment;

    const buildEdgeSegmentIdSortedRunsFromSpool = store_data_plane.buildEdgeSegmentIdSortedRunsFromSpool;

    const writeEdgeSegmentIdIndexFromSingleSpoolChunk = store_data_plane.writeEdgeSegmentIdIndexFromSingleSpoolChunk;

    const writeEdgeSegmentIdIndexFromRunFiles = store_data_plane.writeEdgeSegmentIdIndexFromRunFiles;

    const writeEdgeSegmentIdIndexFromManifestEntries = store_data_plane.writeEdgeSegmentIdIndexFromManifestEntries;

    const edgeSegmentIdIndexContains = store_data_plane.edgeSegmentIdIndexContains;

    const readEdgeSegmentIdIndexRecordAt = store_data_plane.readEdgeSegmentIdIndexRecordAt;

    const writeEdgeSegmentCurrent = store_data_plane.writeEdgeSegmentCurrent;

    const readEdgeSegmentManifest = store_data_plane.readEdgeSegmentManifest;

    const readEdgeSegmentManifestAtPath = store_data_plane.readEdgeSegmentManifestAtPath;

    const validateEdgeSegmentManifestPath = store_data_plane.validateEdgeSegmentManifestPath;

    const readEdgeSegmentCurrentPath = store_data_plane.readEdgeSegmentCurrentPath;

    const readEdgeSegmentManifestFile = store_data_plane.readEdgeSegmentManifestFile;

    pub const ensurePersistentEdgeIndexes = store_data_plane.ensurePersistentEdgeIndexes;

    pub const ensurePersistentNodeIndexes = store_data_plane.ensurePersistentNodeIndexes;

    const nodeIndexValid = store_data_plane.nodeIndexValid;

    const nodeTextIndexRecordDigest = store_data_plane.nodeTextIndexRecordDigest;

    const nodeTextIndexRecordDigestWithTexts = store_data_plane.nodeTextIndexRecordDigestWithTexts;

    const edgeIndexValid = store_data_plane.edgeIndexValid;

    const edgeIndexesConsistent = store_data_plane.edgeIndexesConsistent;

    const edgeIndexesMatchMeta = store_data_plane.edgeIndexesMatchMeta;

    const edgeStorageMatchesMeta = store_data_plane.edgeStorageMatchesMeta;

    const edgeIndexBaseHeadersMatchMeta = store_data_plane.edgeIndexBaseHeadersMatchMeta;

    const edgeIndexDigest = store_data_plane.edgeIndexDigest;

    const insertEdgeIndexRecord = store_data_plane.insertEdgeIndexRecord;

    const EdgeIndexBatchWriteResult = struct {
        order_digest: u64,
        edge_id_runs: ?storage_data_plane_support.EdgeSegmentIdRunSummary = null,
    };

    const writeEmptyNodeIndexes = store_data_plane.writeEmptyNodeIndexes;

    const appendNodeIndexRecord = store_data_plane.appendNodeIndexRecord;

    const rewriteNodeByIdIndexToUniformRecordsFromTextRepair = store_data_plane.rewriteNodeByIdIndexToUniformRecordsFromTextRepair;

    const compactNodeByIdIndexToDerivedTextOffsets = store_data_plane.compactNodeByIdIndexToDerivedTextOffsets;

    const rewriteNodeByIdIndexToDerivedDenseLengths = store_data_plane.rewriteNodeByIdIndexToDerivedDenseLengths;

    const appendNodeTextIndexRecord = store_data_plane.appendNodeTextIndexRecord;

    const nodeTextRecordFitsStoredHeader = store_data_plane.nodeTextRecordFitsStoredHeader;

    const readNodeTextDeltaHeader = store_data_plane.readNodeTextDeltaHeader;

    const appendNodeTextDeltaRecord = store_data_plane.appendNodeTextDeltaRecord;

    pub const compactNodeTextDeltaBudgeted = store_data_plane.compactNodeTextDeltaBudgeted;

    pub const compactNodeTextRunsBudgeted = store_data_plane.compactNodeTextRunsBudgeted;

    pub const compactNodeTextRunsBudgetedRetainingRegistry = store_data_plane.compactNodeTextRunsBudgetedRetainingRegistry;

    pub const compactNodeTextRunsBudgetedWithProcessLeases = store_data_plane.compactNodeTextRunsBudgetedWithProcessLeases;

    pub const compactNodeTextRunsBudgetedExceptAndProcessLeases = store_data_plane.compactNodeTextRunsBudgetedExceptAndProcessLeases;

    pub const compactNodeTextRunsBudgetedExcept = store_data_plane.compactNodeTextRunsBudgetedExcept;

    pub const gcUnreferencedNodeTextRuns = store_data_plane.gcUnreferencedNodeTextRuns;

    pub const gcUnreferencedNodeTextRunsExcept = store_data_plane.gcUnreferencedNodeTextRunsExcept;

    const addNodeTextRunManifestLivePaths = store_data_plane.addNodeTextRunManifestLivePaths;

    const nodeTextRunPathsForPinnedManifests = store_data_plane.nodeTextRunPathsForPinnedManifests;

    const freeOwnedPathSet = store_data_plane.freeOwnedPathSet;

    const compactNodeTextDeltaForMeta = store_data_plane.compactNodeTextDeltaForMeta;
    const writeEmptyNodeTextDelta = store_data_plane.writeEmptyNodeTextDelta;

    const deleteNodeTextRunManifest = store_data_plane.deleteNodeTextRunManifest;

    const deleteNodeTextRunManifestExcept = store_data_plane.deleteNodeTextRunManifestExcept;

    const compactNodeTextRunWindowForMeta = store_data_plane.compactNodeTextRunWindowForMeta;
    const compactNodeTextOverlaysForMeta = store_data_plane.compactNodeTextOverlaysForMeta;
    const writeMergedNodeTextIndexBatch = store_data_plane.writeMergedNodeTextIndexBatch;
    const nodeTextRecordsCanDeriveSpansFromById = store_data_plane.nodeTextRecordsCanDeriveSpansFromById;

    const buildNodeTextRunHashFilterForRecords = store_data_plane.buildNodeTextRunHashFilterForRecords;

    const buildNodeTextRunHashFilterFromFile = store_data_plane.buildNodeTextRunHashFilterFromFile;

    const readAllNodeTextIndexRecords = store_data_plane.readAllNodeTextIndexRecords;

    const writeNodeTextIndex = store_data_plane.writeNodeTextIndex;

    const writeNodeTextIndexWithDigest = store_data_plane.writeNodeTextIndexWithDigest;

    const sortedNodeTextRecordsHaveUniqueTextHashes = store_data_plane.sortedNodeTextRecordsHaveUniqueTextHashes;

    const NodeTextRepairRunReader = storage_data_plane_support.node_text_repair_index_publication.RunReader;
    const NodeTextRepairPublishShape = storage_data_plane_support.node_text_repair_index_publication.PublishShape;

    const writeNodeTextIndexFromRepairSpool = store_data_plane.writeNodeTextIndexFromRepairSpool;

    const edgeSegmentMetaSummaryCurrent = store_data_plane.edgeSegmentMetaSummaryCurrent;

    const edgeIdExistsInSegmentOverlay = store_data_plane.edgeIdExistsInSegmentOverlay;

    const edgeIdSetIntersectsSegmentOverlay = store_data_plane.edgeIdSetIntersectsSegmentOverlay;

    const edgeIndexTailExceedsHighWater = store_data_plane.edgeIndexTailExceedsHighWater;

    const edgeIdExistsInFile = store_data_plane.edgeIdExistsInFile;

    const edgeIdSortedSetIntersectsFile = store_data_plane.edgeIdSortedSetIntersectsFile;

    const edgeIdRunSummaryMatchesFile = store_data_plane.edgeIdRunSummaryMatchesFile;

    const writeNodeByIdHeader = store_data_plane.writeNodeByIdHeader;

    const writeNodeByIdRecordAt = store_data_plane.writeNodeByIdRecordAt;

    const compactEdgeIndexToDerivedRecords = store_data_plane.compactEdgeIndexToDerivedRecords;

    const SecondaryRepairKeyRun = struct {
        run: storage_data_plane_support.EdgeIndexKeyRunRecord,
        next_pos: u64,
    };

    const readSecondaryRepairKeyRunAt = store_data_plane.readSecondaryRepairKeyRunAt;

    const readSecondaryRepairKeyRunFromMap = store_data_plane.readSecondaryRepairKeyRunFromMap;

    const writeCompleteEdgeIndexFile = store_data_plane.writeCompleteEdgeIndexFile;

    const compactNodeTextIndexToDerivedRecords = store_data_plane.compactNodeTextIndexToDerivedRecords;

    const EdgeRepairRunReader = storage_data_plane_support.edge_repair_index_publication.EdgeRepairRunReader;
    const EdgeRepairRunHeapEntry = storage_data_plane_support.edge_repair_index_publication.EdgeRepairRunHeapEntry;
    const EdgeRepairRunHeapContext = storage_data_plane_support.edge_repair_index_publication.EdgeRepairRunHeapContext;
    const DenseRingRepairSpoolShape = storage_data_plane_support.edge_repair_index_publication.DenseRingRepairSpoolShape;
    const compareEdgeRepairRunHeapEntry = storage_data_plane_support.edge_repair_index_publication.compareEdgeRepairRunHeapEntry;
    const validateSortedRepairEdgeRecords = storage_data_plane_support.edge_repair_index_publication.validateSortedRepairEdgeRecords;
    const validateSortedRepairEdgeRecordOrder = storage_data_plane_support.edge_repair_index_publication.validateSortedRepairEdgeRecordOrder;

    const writeEdgeIndexesFromRepairSpool = store_data_plane.writeEdgeIndexesFromRepairSpool;

    const writeEdgeIndexFromRepairSpool = store_data_plane.writeEdgeIndexFromRepairSpool;

    const detectDenseRingRepairSpoolShape = store_data_plane.detectDenseRingRepairSpoolShape;

    const writeDenseRingIdEdgeIndex = store_data_plane.writeDenseRingIdEdgeIndex;

    const writeDenseRingSecondaryEdgeIndex = store_data_plane.writeDenseRingSecondaryEdgeIndex;
    const writeEdgeIndex = store_data_plane.writeEdgeIndex;

    const writeEdgeTombstoneIndex = store_data_plane.writeEdgeTombstoneIndex;

    const writeEdgeOrderIndex = store_data_plane.writeEdgeOrderIndex;

    const TombstoneRepairRunReader = storage_data_plane_support.edge_tombstone_repair_index_publication.RunReader;

    const writeEdgeTombstoneIndexFromRepairSpool = store_data_plane.writeEdgeTombstoneIndexFromRepairSpool;
    const eventBytes = store_data_plane.eventBytes;

    const fileSizeOrZero = store_data_plane.fileSizeOrZero;

    const nodeByIdFileSizeForHeaderStore = store_data_plane.nodeByIdFileSizeForHeaderStore;

    const tmpPathFor = store_data_plane.tmpPathFor;

    const renameReplace = store_data_plane.renameReplace;

    const syncParentDirForPath = store_data_plane.syncParentDirForPath;
};

const StorageDataPlaneSupportOps = struct {
    pub const dep_std = std;
    pub const dep_builtin = builtin;
    pub const dep_core = core;
    pub const dep_graph_mod = graph_mod;
    pub const dep_schema = schema;
    pub const dep_segment_mod = segment_mod;
    pub const dep_segment_manifest = segment_manifest;
    pub const dep_segment_node_index = segment_node_index;
    pub const dep_process_liveness = process_liveness;
    pub const dep_edge_segment_gc_mod = edge_segment_gc_mod;
    pub const dep_edge_segment_maintenance_mod = edge_segment_maintenance_mod;
    pub const dep_edge_segment_merge_mod = edge_segment_merge_mod;
    pub const dep_edge_segment_publication_mod = edge_segment_publication_mod;
    pub const dep_edge_segment_query_opening_mod = edge_segment_query_opening_mod;
    pub const dep_edge_segment_window_compaction_mod = edge_segment_window_compaction_mod;
    pub const dep_edge_repair_index_publication_mod = edge_repair_index_publication_mod;
    pub const dep_edge_tombstone_repair_index_publication_mod = edge_tombstone_repair_index_publication_mod;
    pub const dep_manifest_process_lease_mod = manifest_process_lease_mod;
    pub const dep_node_text_catalog_transaction_mod = node_text_catalog_transaction_mod;
    pub const dep_node_text_lookup_view_data_plane_mod = node_text_lookup_view_data_plane_mod;
    pub const dep_node_text_maintenance_mod = node_text_maintenance_mod;
    pub const dep_node_text_repair_index_publication_mod = node_text_repair_index_publication_mod;
    pub const dep_persistent_rebuild_pipeline_mod = persistent_rebuild_pipeline_mod;
    pub const dep_primary_node_text_mod = primary_node_text_mod;
    pub const dep_node_text_run_gc_mod = node_text_run_gc_mod;
    pub const dep_binary_event_log_codec = binary_event_log_codec;
    pub const dep_edge_index_format = edge_index_format;
    pub const dep_edge_order_format = edge_order_format;
    pub const dep_edge_tombstone_format = edge_tombstone_format;
    pub const dep_external_key_format = external_key_format;
    pub const dep_index_meta_format = index_meta_format;
    pub const dep_edge_segment_manifest_format = edge_segment_manifest_format;
    pub const dep_node_text_run_manifest_format = node_text_run_manifest_format;
    pub const dep_property_format = property_format;
    pub const dep_property_payload_transaction_mod = property_payload_transaction_mod;
    pub const dep_repair_session_mod = repair_session_mod;
    pub const dep_store_bootstrap_mod = store_bootstrap_mod;
    pub const dep_store_cache_resources_mod = store_cache_resources_mod;
    pub const dep_store_opening_mod = store_opening_mod;
    pub const dep_EdgeIndexOrder = EdgeIndexOrder;
    pub const dep_EdgeIndexHeader = EdgeIndexHeader;
    pub const dep_EdgeIndexRecord = EdgeIndexRecord;
    pub const dep_EdgeOrderRecord = EdgeOrderRecord;
    pub const dep_IndexMeta = IndexMeta;
    pub const dep_NodeByIdHeader = NodeByIdHeader;
    pub const dep_NodeByIdRecord = NodeByIdRecord;
    pub const dep_NodeTextIndexHeader = NodeTextIndexHeader;
    pub const dep_NodeTextIndexRecord = NodeTextIndexRecord;
    pub const dep_DurabilityMode = DurabilityMode;
    pub const dep_StorageOptions = StorageOptions;
    pub const dep_EdgeSegmentMaintenanceBudget = EdgeSegmentMaintenanceBudget;
    pub const dep_EdgeSegmentMaintenanceResult = EdgeSegmentMaintenanceResult;
    pub const dep_EdgeSegmentGcResult = EdgeSegmentGcResult;
    pub const dep_ManifestProcessLease = ManifestProcessLease;
    pub const dep_EdgeSegmentRetentionRegistry = EdgeSegmentRetentionRegistry;
    pub const dep_EdgeSegmentRegisteredRetentionWindow = EdgeSegmentRegisteredRetentionWindow;
    pub const dep_NodeTextRunRetentionRegistry = NodeTextRunRetentionRegistry;
    pub const dep_NodeTextRunRegisteredRetentionWindow = NodeTextRunRegisteredRetentionWindow;
    pub const dep_PersistentRepairTimings = PersistentRepairTimings;
    pub const dep_NodeTextsCompressionResult = NodeTextsCompressionResult;
    pub const dep_NodeTextDeltaMaintenanceResult = NodeTextDeltaMaintenanceResult;
    pub const dep_NodeTextRunMaintenanceResult = NodeTextRunMaintenanceResult;
    pub const dep_NodeTextRunGcResult = NodeTextRunGcResult;
    pub const dep_SegmentKind = SegmentKind;
    pub const dep_SegmentHeader = SegmentHeader;
    pub const dep_Manifest = Manifest;
    pub const dep_StoreStats = StoreStats;
    pub const dep_StoredNode = StoredNode;
    pub const dep_PropertyOwner = PropertyOwner;
    pub const dep_PropertyPayloadWrite = PropertyPayloadWrite;
    pub const dep_SortedPropertyPayloadNext = SortedPropertyPayloadNext;
    pub const dep_PropertyPayloadCompactionResult = PropertyPayloadCompactionResult;
    pub const dep_PropertySnapshotEntry = PropertySnapshotEntry;
    pub const dep_PropertySnapshotLayerVisitor = PropertySnapshotLayerVisitor;
    pub const dep_Store = Store;
    pub const dep_PublishedEdgeSegments = PublishedEdgeSegments;
    pub const dep_PublishedEdgeSegmentsCoverage = PublishedEdgeSegmentsCoverage;
    pub const dep_PublishedEdgeSegmentsForQuery = PublishedEdgeSegmentsForQuery;
    pub const store_plane = Store.store_data_plane;
    pub const store_type_EdgeRepairRunHeapContext = Store.EdgeRepairRunHeapContext;
    pub const store_type_EdgeRepairRunHeapEntry = Store.EdgeRepairRunHeapEntry;
    pub const store_type_EdgeRepairRunReader = Store.EdgeRepairRunReader;
    pub const store_type_EdgeTombstoneIndexView = Store.EdgeTombstoneIndexView;
    pub const store_type_NodeByIdIndexView = Store.NodeByIdIndexView;
    pub const store_type_NodeTextDeltaRunCache = Store.NodeTextDeltaRunCache;
    pub const store_type_NodeTextLookupRun = Store.NodeTextLookupRun;
    pub const store_type_NodeTextRepairPublishShape = Store.NodeTextRepairPublishShape;
    pub const store_type_NodeTextsView = Store.NodeTextsView;
    pub const store_type_compareEdgeRepairRunHeapEntry = Store.compareEdgeRepairRunHeapEntry;
};
const storage_data_plane_support = data_plane_support_mod.StorageDataPlaneSupport(StorageDataPlaneSupportOps);

/// Test-only dependency ports used by the repository-level Storage integration
/// root. Production builds expose an empty namespace and never depend on the
/// integration owners under `tests/`.
pub const integration_test_support = if (builtin.is_test) struct {
    pub const NodeTextOps = struct {
        pub const dep_core = core;
        pub const dep_graph_mod = graph_mod;
        pub const dep_NodeByIdHeader = NodeByIdHeader;
        pub const dep_NodeByIdRecord = NodeByIdRecord;
        pub const dep_NodeTextIndexHeader = NodeTextIndexHeader;
        pub const dep_NodeTextIndexRecord = NodeTextIndexRecord;
        pub const dep_NodeTextRunRetentionRegistry = NodeTextRunRetentionRegistry;
        pub const dep_PersistentValidateTimings = PersistentValidateTimings;
        pub const dep_StoredNode = StoredNode;
        pub const dep_Store = Store;
        pub const dep_store_plane = Store.store_data_plane;
        pub const dep_storage_data_plane_support = storage_data_plane_support;
        pub const dep_NodeTextsAppendRecovery = Store.NodeTextsAppendRecovery;
        pub const dep_NodeTextsStorageFormat = Store.NodeTextsStorageFormat;
        pub const dep_NodeTextsView = Store.NodeTextsView;
        pub const dep_deflateNodeTextsBlock = Store.deflateNodeTextsBlock;
        pub const dep_node_texts_append_journal_checksummed_version = Store.node_texts_append_journal_checksummed_version;
        pub const dep_node_texts_append_journal_header_hash_seed = Store.node_texts_append_journal_header_hash_seed;
        pub const dep_node_texts_append_journal_header_len = Store.node_texts_append_journal_header_len;
        pub const dep_node_texts_block_deflate_header_len = Store.node_texts_block_deflate_header_len;
        pub const dep_node_texts_deflate_progress_entry_len = Store.node_texts_deflate_progress_entry_len;
        pub const dep_node_texts_deflate_progress_hash_seed = Store.node_texts_deflate_progress_hash_seed;
        pub const dep_openReadOnlyMemoryMap = Store.openReadOnlyMemoryMap;
    };

    pub const EdgeSegmentOps = struct {
        pub const dep_core = core;
        pub const dep_graph_mod = graph_mod;
        pub const dep_segment_mod = segment_mod;
        pub const dep_segment_bundle = segment_bundle;
        pub const dep_segment_manifest = segment_manifest;
        pub const dep_EdgeIndexRecord = EdgeIndexRecord;
        pub const dep_EdgeSegmentRetentionRegistry = EdgeSegmentRetentionRegistry;
        pub const dep_EdgeBatchSegmentDeltaStats = EdgeBatchSegmentDeltaStats;
        pub const dep_PublishedEdgeSegmentsCoverage = PublishedEdgeSegmentsCoverage;
        pub const dep_Store = Store;
        pub const dep_store_plane = Store.store_data_plane;
        pub const dep_storage_data_plane_support = storage_data_plane_support;
        pub const dep_edgeSegmentManifestIdRunSummary = Store.edgeSegmentManifestIdRunSummary;
    };

    pub const PersistentIndexRepairOps = struct {
        pub const dep_core = core;
        pub const dep_graph_mod = graph_mod;
        pub const dep_segment_mod = segment_mod;
        pub const dep_edge_order_format = edge_order_format;
        pub const dep_EdgeIndexOrder = EdgeIndexOrder;
        pub const dep_EdgeIndexHeader = EdgeIndexHeader;
        pub const dep_EdgeIndexRecord = EdgeIndexRecord;
        pub const dep_IndexMeta = IndexMeta;
        pub const dep_NodeTextIndexRecord = NodeTextIndexRecord;
        pub const dep_Store = Store;
        pub const dep_store_plane = Store.store_data_plane;
        pub const dep_storage_data_plane_support = storage_data_plane_support;
        pub const dep_EdgeRepairRunReader = Store.EdgeRepairRunReader;
        pub const dep_EdgeSegmentIdIndexRunReader = Store.EdgeSegmentIdIndexRunReader;
        pub const dep_NodeTextRepairRunReader = Store.NodeTextRepairRunReader;
        pub const dep_TombstoneRepairRunReader = Store.TombstoneRepairRunReader;
        pub const dep_openReadOnlyMemoryMap = Store.openReadOnlyMemoryMap;
        pub const dep_readSecondaryRepairKeyRunFromMap = Store.readSecondaryRepairKeyRunFromMap;
    };
} else struct {};

test "safe durability syncs parent directory path after rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.syncParentDirForPath(store.index_meta_path);

    var fast_store = store;
    fast_store.options.durability = .fast;
    try fast_store.syncParentDirForPath("/definitely/missing/tinykg/index.meta");

    if (builtin.os.tag == .windows) {
        try store.syncParentDirForPath("Z:\\definitely\\missing\\tinykg\\index.meta");
    }
}

test "current index meta cache still enforces event byte boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const cached = try store.readCurrentIndexMeta();
    try std.testing.expect(store.index_meta_cache.valid);

    store.index_meta_cache.meta.event_bytes = cached.event_bytes + 1;
    const reread = try store.readCurrentIndexMeta();
    try std.testing.expectEqual(cached.event_bytes, reread.event_bytes);
    try std.testing.expectEqual(cached.event_bytes, store.index_meta_cache.meta.event_bytes);
}

test "node text delta header cache updates on publish and strict read bypasses it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_texts_path,
        .data = "alpha.zig",
        .flags = .{ .truncate = true },
    });

    const record = NodeTextIndexRecord{
        .hash = storage_data_plane_support.nodeTextHash("alpha.zig"),
        .id = 1,
        .kind = @intFromEnum(core.NodeKind.file),
        .text_offset = 0,
        .text_len = 9,
    };
    try store.appendNodeTextDeltaRecord(record, .{ .node_count = 0 });
    try std.testing.expect(store.node_text_delta_header_cache.valid);
    try std.testing.expectEqual(@as(u64, 1), store.node_text_delta_header_cache.header.node_count);

    store.node_text_delta_header_cache.header = .{ .node_count = 0 };
    store.node_text_delta_header_cache.valid = true;
    var strict_store = store;
    strict_store.options.validate_indexes_on_read = true;
    const strict_header = try strict_store.readNodeTextDeltaHeader();
    try std.testing.expectEqual(@as(u64, 1), strict_header.node_count);
}

test "node text delta run cache updates on publish and strict lookup bypasses it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(10), .kind = .repo, .text = "shared-delta-cache" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "shared-delta-cache" });
    try std.testing.expect(store.node_text_delta_run_cache.run != null);
    try std.testing.expectEqual(@as(u64, 1), store.node_text_delta_run_cache.run.?.header.node_count);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.node_by_text_delta_path);

    const cached = try store.lookupFirstNodeIdByText(std.testing.allocator, null, "shared-delta-cache");
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(u64, 2), cached.?.toInt());

    var strict_store = store;
    strict_store.options.validate_indexes_on_read = true;
    try std.testing.expectError(error.InvalidRecord, strict_store.lookupFirstNodeIdByText(std.testing.allocator, null, "shared-delta-cache"));
}

test "store owns directory path slice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const input_path = path_buf[0..root_len];

    var store = try Store.init(std.testing.allocator, std.testing.io, input_path);
    defer store.deinit();

    try std.testing.expectEqualStrings(input_path, store.dir_path);
    try std.testing.expect(store.dir_path.ptr != input_path.ptr);
}

fn storeInitAllocationFailure(allocator: std.mem.Allocator, io: std.Io, store_path: []const u8) !void {
    var store = try Store.init(allocator, io, store_path);
    defer store.deinit();
}

test "store init rolls back owned paths and caches at every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "allocation-failure" });
    defer std.testing.allocator.free(store_path);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        storeInitAllocationFailure,
        .{ std.testing.io, store_path },
    );
}

fn fileExistsAtPath(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    file.close(io);
    return true;
}

test "store open does not create or accept non-store directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "missing" });
    defer std.testing.allocator.free(missing_path);

    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.allocator, std.testing.io, missing_path));
    try std.testing.expect(!try fileExistsAtPath(std.testing.io, missing_path));

    const existing_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "existing" });
    defer std.testing.allocator.free(existing_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, existing_path);

    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.allocator, std.testing.io, existing_path));

    var created = try Store.init(std.testing.allocator, std.testing.io, existing_path);
    defer created.deinit();
    try created.createEmpty();
    var opened = try Store.open(std.testing.allocator, std.testing.io, existing_path);
    defer opened.deinit();
    try std.testing.expectEqualStrings(existing_path, opened.dir_path);
    try std.testing.expect(try fileExistsAtPath(std.testing.io, opened.index_meta_path));
}

test "store open requires regular marker files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "marker-dir" });
    defer std.testing.allocator.free(store_path);
    const marker_dir = try std.fs.path.join(std.testing.allocator, &.{ store_path, "events.bin" });
    defer std.testing.allocator.free(marker_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, marker_dir);

    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.allocator, std.testing.io, store_path));
}

test "store open rejects event-log-only directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text-log-only" });
    defer std.testing.allocator.free(store_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, store_path);

    const events_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "events.log" });
    defer std.testing.allocator.free(events_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = events_path,
        .data = "N\t1\tfile\tlegacy.zig\n",
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.allocator, std.testing.io, store_path));
}

test "store open rejects index-meta-only directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "meta-only" });
    defer std.testing.allocator.free(store_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, store_path);

    const meta_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "index.meta" });
    defer std.testing.allocator.free(meta_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = meta_path,
        .data = "not a source of truth",
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.FileNotFound, Store.open(std.testing.allocator, std.testing.io, store_path));
}

test "store createEmpty rejects marker directories instead of accepting them as files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "marker-dir-create" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, store.events_bin_path);

    try std.testing.expectError(error.IsDir, store.createEmpty());
}

test "store replay and stats reject binary event log directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "event-dir" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.events_bin_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, store.events_bin_path);

    try std.testing.expectError(error.IsDir, store.loadGraph());
    try std.testing.expectError(error.IsDir, store.stats());
    try std.testing.expectError(error.IsDir, store.eventByteCount());
    try std.testing.expectError(error.IsDir, store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" }));
}

test "store read and repair reject missing append log instead of inventing empty graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "missing-log" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.events_bin_path);

    try std.testing.expectError(error.FileNotFound, store.loadGraph());
    try std.testing.expectError(error.FileNotFound, store.stats());
    try std.testing.expectError(error.FileNotFound, store.repairPersistentIndexesFromLog());
}

test "store createEmpty rejects missing append log when derived catalogs exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "derived-without-log" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.events_bin_path);

    try std.testing.expectError(error.InvalidRecord, store.createEmpty());
    try std.testing.expectError(error.FileNotFound, store.eventByteCount());
    try std.testing.expectError(error.FileNotFound, store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "src/other.zig" }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.events_bin_path, .{}));
}

test "store metadata and edge header reads require regular complete files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];

    const meta_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "meta-dir" });
    defer std.testing.allocator.free(meta_store_path);
    var meta_store = try Store.init(std.testing.allocator, std.testing.io, meta_store_path);
    defer meta_store.deinit();
    try meta_store.createEmpty();
    try std.Io.Dir.cwd().deleteFile(std.testing.io, meta_store.index_meta_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, meta_store.index_meta_path);
    try std.testing.expectError(error.IsDir, meta_store.readIndexMeta());

    const edge_dir_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-dir" });
    defer std.testing.allocator.free(edge_dir_store_path);
    var edge_dir_store = try Store.init(std.testing.allocator, std.testing.io, edge_dir_store_path);
    defer edge_dir_store.deinit();
    try edge_dir_store.createEmpty();
    try std.Io.Dir.cwd().deleteFile(std.testing.io, edge_dir_store.edge_by_src_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, edge_dir_store.edge_by_src_path);
    try std.testing.expectError(error.IsDir, edge_dir_store.readEdgeIndexHeader(edge_dir_store.edge_by_src_path));

    const trailing_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-trailing" });
    defer std.testing.allocator.free(trailing_store_path);
    var trailing_store = try Store.init(std.testing.allocator, std.testing.io, trailing_store_path);
    defer trailing_store.deinit();
    try trailing_store.createEmpty();
    var edge_file = try std.Io.Dir.cwd().openFile(std.testing.io, trailing_store.edge_by_src_path, .{ .mode = .read_write });
    defer edge_file.close(std.testing.io);
    try edge_file.writePositionalAll(std.testing.io, &[_]u8{1}, (try edge_file.stat(std.testing.io)).size);
    try std.testing.expectError(error.InvalidRecord, trailing_store.readEdgeIndexHeader(trailing_store.edge_by_src_path));
}

test "store node index read paths require regular files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];

    const by_id_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "node-by-id-dir" });
    defer std.testing.allocator.free(by_id_store_path);
    var by_id_store = try Store.init(std.testing.allocator, std.testing.io, by_id_store_path);
    defer by_id_store.deinit();
    try by_id_store.createEmpty();
    try by_id_store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, by_id_store.node_by_id_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, by_id_store.node_by_id_path);
    try std.testing.expectError(error.IsDir, by_id_store.readNodeById(std.testing.allocator, .fromInt(1)));

    const by_text_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "node-by-text-dir" });
    defer std.testing.allocator.free(by_text_store_path);
    var by_text_store = try Store.init(std.testing.allocator, std.testing.io, by_text_store_path);
    defer by_text_store.deinit();
    try by_text_store.createEmpty();
    try by_text_store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, by_text_store.node_by_text_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, by_text_store.node_by_text_path);
    try std.testing.expectError(error.IsDir, by_text_store.lookupNodesByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));

    const texts_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "node-texts-dir" });
    defer std.testing.allocator.free(texts_store_path);
    var texts_store = try Store.init(std.testing.allocator, std.testing.io, texts_store_path);
    texts_store.options.validate_indexes_on_read = false;
    defer texts_store.deinit();
    try texts_store.createEmpty();
    try texts_store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, texts_store.node_texts_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, texts_store.node_texts_path);
    try std.testing.expectError(error.IsDir, texts_store.readNodeById(std.testing.allocator, .fromInt(1)));
}

test "store addNode allocates id and repairs stale indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const first = try store.addNode(.file, "src/main.zig");
    try std.testing.expectEqual(@as(u64, 1), first.toInt());
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_by_text_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });

    const second = try store.addNode(.function, "main");
    try std.testing.expectEqual(@as(u64, 2), second.toInt());
    var found = (try store.readNodeById(std.testing.allocator, second)).?;
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("main", found.text);
}

test "store addNode reallocates id after stale append validation repair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    _ = try store.addNode(.file, "one.zig");

    const stale_node: graph_mod.Node = .{ .id = .fromInt(2), .kind = .file, .text = "two.zig" };
    const stale_span = try store.appendNodeTextBytes(stale_node.text);
    try store.appendNodeRecord(stale_node, stale_span);

    const added = try store.addNode(.file, "three.zig");
    try std.testing.expectEqual(@as(u64, 3), added.toInt());
    var found = (try store.readNodeById(std.testing.allocator, added)).?;
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("three.zig", found.text);
}

test "record offset helpers reject arithmetic overflow" {
    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.nodeByIdRecordOffset(std.math.maxInt(u64)));
    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.nodeTextIndexRecordOffset(std.math.maxInt(u64)));
    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.edgeIndexRecordOffset(std.math.maxInt(u64)));
}

test "store node text index derives uniform kind and short text length lanes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_texts_path,
        .data = "alphabetagamma",
        .flags = .{ .truncate = true },
    });

    try store.writeNodeTextIndex(&.{
        .{
            .hash = storage_data_plane_support.nodeTextHash("alpha"),
            .id = 1,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 0,
            .text_len = 5,
        },
        .{
            .hash = storage_data_plane_support.nodeTextHash("beta"),
            .id = 2,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 5,
            .text_len = 4,
        },
    });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeTextIndexHeaderFromFile(file);
    try std.testing.expect(header.hasUniformKind());
    try std.testing.expect(header.hasShortTextLen());
    try std.testing.expect(header.hasU32Id());
    try std.testing.expect(!header.hasDerivedHash());
    try std.testing.expectEqual(@intFromEnum(core.NodeKind.file), header.uniform_kind);
    try std.testing.expectEqual(@as(u16, 20), header.record_len);
    try std.testing.expectEqual(
        @as(u64, NodeTextIndexHeader.encoded_len + 2 * 20),
        try store.regularFileSize(file),
    );
    try std.testing.expectEqual(@as(u16, @intFromEnum(core.NodeKind.file)), (try store.readNodeTextIndexRecordAt(file, 0)).kind);
    try std.testing.expectEqual(@as(u32, 4), (try store.readNodeTextIndexRecordAt(file, 1)).text_len);
}

test "store node text index derives text spans from node id catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_texts_path,
        .data = "alphabetagamma",
        .flags = .{ .truncate = true },
    });

    var by_id = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{ .mode = .read_write });
    defer by_id.close(std.testing.io);
    var by_id_header = NodeByIdHeader.uniform(.file, true);
    by_id_header.max_node_id = 2;
    by_id_header.node_count = 2;
    try store.writeNodeByIdHeader(by_id, by_id_header);
    try by_id.setLength(std.testing.io, try store.nodeByIdFileSizeForHeaderStore(by_id_header));
    try store.writeNodeByIdRecordAt(by_id, by_id_header, .{
        .id = 1,
        .kind = @intFromEnum(core.NodeKind.file),
        .text_offset = 0,
        .text_len = 5,
    });
    try store.writeNodeByIdRecordAt(by_id, by_id_header, .{
        .id = 2,
        .kind = @intFromEnum(core.NodeKind.file),
        .text_offset = 5,
        .text_len = 4,
    });

    try store.writeNodeTextIndex(&.{
        .{
            .hash = storage_data_plane_support.nodeTextHash("alpha"),
            .id = 1,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 0,
            .text_len = 5,
        },
        .{
            .hash = storage_data_plane_support.nodeTextHash("beta"),
            .id = 2,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 5,
            .text_len = 4,
        },
    });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeTextIndexHeaderFromFile(file);
    try std.testing.expect(header.hasUniformKind());
    try std.testing.expect(header.hasU32Id());
    try std.testing.expect(!header.hasDerivedHash());
    try std.testing.expect(header.hasDerivedTextSpan());
    try std.testing.expect(header.hasTextHashUnique());
    try std.testing.expect(!header.hasShortTextLen());
    try std.testing.expectEqual(@as(u16, 12), header.record_len);
    try std.testing.expectEqual(
        @as(u64, NodeTextIndexHeader.encoded_len + 2 * 12),
        try store.regularFileSize(file),
    );
    const second = try store.readNodeTextIndexRecordAt(file, 1);
    try std.testing.expectEqual(@as(u64, 5), second.text_offset);
    try std.testing.expectEqual(@as(u32, 4), second.text_len);
    try std.testing.expectEqual(storage_data_plane_support.nodeTextHash("beta"), second.hash);
}

test "store exact-text lookup trusts hash-unique node text run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/a.zig" },
        .{ .id = .fromInt(2), .kind = .function, .text = "target_fn" },
        .{ .id = .fromInt(3), .kind = .task, .text = "fix lookup" },
    });
    try store.repairPersistentIndexesFromLog();

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeTextIndexHeaderFromFile(file);
    try std.testing.expect(header.hasTextHashUnique());
    try std.testing.expect(header.hasDerivedTextSpan());

    var timings = Store.NodeTextLookupTimings{};
    var matches = try store.lookupNodesByTextLimitedWithTimings(std.testing.allocator, .function, "target_fn", 4, &timings);
    defer {
        for (matches.items) |*node| node.deinit(std.testing.allocator);
        matches.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(u64, 2), matches.items[0].id.toInt());
    try std.testing.expectEqual(core.NodeKind.function, matches.items[0].kind);
    try std.testing.expectEqualStrings("target_fn", matches.items[0].text);
    try std.testing.expectEqual(@as(u128, 0), timings.text_match_ns);
    try std.testing.expectEqual(@as(u128, 0), timings.text_compare_ns);
    try std.testing.expectEqual(@as(u128, 0), timings.by_id_validate_ns);
}

test "store node text index keeps wide ids for high sparse node ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_texts_path,
        .data = "alphabetagamma",
        .flags = .{ .truncate = true },
    });

    const high_id: u64 = @as(u64, std.math.maxInt(u32)) + 1;
    try store.writeNodeTextIndex(&.{
        .{
            .hash = storage_data_plane_support.nodeTextHash("alpha"),
            .id = 1,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 0,
            .text_len = 5,
        },
        .{
            .hash = storage_data_plane_support.nodeTextHash("beta"),
            .id = high_id,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 5,
            .text_len = 4,
        },
    });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeTextIndexHeaderFromFile(file);
    try std.testing.expect(header.hasUniformKind());
    try std.testing.expect(header.hasShortTextLen());
    try std.testing.expect(!header.hasU32Id());
    try std.testing.expect(!header.hasDerivedHash());
    try std.testing.expectEqual(@as(u16, 24), header.record_len);
    try std.testing.expectEqual(
        @as(u64, NodeTextIndexHeader.encoded_len + 2 * 24),
        try store.regularFileSize(file),
    );
    try std.testing.expectEqual(high_id, (try store.readNodeTextIndexRecordAt(file, 1)).id);
}

test "store node by id derives dense text offsets from checkpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer nodes.deinit(std.testing.allocator);
    try nodes.ensureTotalCapacityPrecise(std.testing.allocator, 130);
    var text_bytes: [130][4]u8 = undefined;
    var id: u64 = 1;
    while (id <= 130) : (id += 1) {
        const text = try std.fmt.bufPrint(&text_bytes[@intCast(id - 1)], "{d:0>4}", .{id});
        nodes.appendAssumeCapacity(.{
            .id = .fromInt(id),
            .kind = .file,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeByIdHeaderFromFile(file);
    try std.testing.expect(header.hasUniformKind());
    try std.testing.expect(header.hasShortTextLen());
    try std.testing.expect(header.hasDerivedTextOffset());
    try std.testing.expectEqual(@as(u16, NodeByIdRecord.uniform_short_derived_offset_encoded_len), header.record_len);
    try std.testing.expectEqual(
        @as(u64, NodeByIdHeader.encoded_len + 130 * 2 + 2 * 8),
        try store.regularFileSize(file),
    );

    const last = try store.readNodeByIdRecordAt(file, header, 130);
    try std.testing.expectEqual(@as(u64, 130), last.id);
    try std.testing.expectEqual(@as(u64, 129 * 4), last.text_offset);
    try std.testing.expectEqual(@as(u32, 4), last.text_len);

    var loaded = (try store.readNodeById(std.testing.allocator, .fromInt(130))).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0130", loaded.text);

    try store.repairPersistentIndexesFromLog();

    {
        var repaired_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
        defer repaired_file.close(std.testing.io);
        const repaired_header = try store.readNodeByIdHeaderFromFile(repaired_file);
        try std.testing.expect(repaired_header.hasDerivedTextOffset());
        try std.testing.expectEqual(
            @as(u64, NodeByIdHeader.encoded_len + 130 * 2 + 2 * 8),
            try store.regularFileSize(repaired_file),
        );
    }
    {
        var repaired_text_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{});
        defer repaired_text_file.close(std.testing.io);
        const repaired_text_header = try store.readNodeTextIndexHeaderFromFile(repaired_text_file);
        try std.testing.expect(repaired_text_header.hasUniformKind());
        try std.testing.expect(repaired_text_header.hasU32Id());
        try std.testing.expect(!repaired_text_header.hasDerivedHash());
        try std.testing.expect(repaired_text_header.hasDerivedTextSpan());
        try std.testing.expect(!repaired_text_header.hasShortTextLen());
        try std.testing.expectEqual(@as(u16, 12), repaired_text_header.record_len);
        try std.testing.expectEqual(
            @as(u64, NodeTextIndexHeader.encoded_len + 130 * 12),
            try store.regularFileSize(repaired_text_file),
        );
        var found_last_name = false;
        var text_pos: u64 = 0;
        while (text_pos < repaired_text_header.node_count) : (text_pos += 1) {
            const record = try store.readNodeTextIndexRecordAt(repaired_text_file, text_pos);
            if (record.id != 130) continue;
            found_last_name = true;
            try std.testing.expectEqual(@as(u64, 129 * 4), record.text_offset);
            try std.testing.expectEqual(@as(u32, 4), record.text_len);
            break;
        }
        try std.testing.expect(found_last_name);
    }

    _ = try store.addNode(.file, "wxyz");
    var appended_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
    defer appended_file.close(std.testing.io);
    const appended_header = try store.readNodeByIdHeaderFromFile(appended_file);
    try std.testing.expect(appended_header.hasDerivedTextOffset());
    try std.testing.expectEqual(
        @as(u64, NodeByIdHeader.encoded_len + 131 * 2 + 2 * 8),
        try store.regularFileSize(appended_file),
    );
}

test "store node by id appends derived dense batch without widening old records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var first: [128]graph_mod.Node = undefined;
    var first_text_bytes: [128][4]u8 = undefined;
    for (&first, 0..) |*node, index| {
        const id: u64 = @intCast(index + 1);
        const text = try std.fmt.bufPrint(&first_text_bytes[index], "{d:0>4}", .{id});
        node.* = .{
            .id = .fromInt(id),
            .kind = .file,
            .text = text,
        };
    }
    try store.appendNodesBatch(&first);

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
        defer file.close(std.testing.io);
        const header = try store.readNodeByIdHeaderFromFile(file);
        try std.testing.expect(header.hasDerivedTextOffset());
        try std.testing.expectEqual(
            @as(u64, NodeByIdHeader.encoded_len + 128 * NodeByIdRecord.uniform_short_derived_offset_encoded_len + 8),
            try store.regularFileSize(file),
        );
    }

    var second: [132]graph_mod.Node = undefined;
    var second_text_bytes: [132][4]u8 = undefined;
    for (&second, 0..) |*node, index| {
        const id: u64 = @intCast(129 + index);
        const text = try std.fmt.bufPrint(&second_text_bytes[index], "{d:0>4}", .{id});
        node.* = .{
            .id = .fromInt(id),
            .kind = .file,
            .text = text,
        };
    }
    try store.appendNodesBatch(&second);

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeByIdHeaderFromFile(file);
    try std.testing.expect(header.hasDerivedTextOffset());
    try std.testing.expectEqual(@as(u64, 260), header.node_count);
    try std.testing.expectEqual(@as(u64, 260), header.max_node_id);
    try std.testing.expectEqual(
        @as(u64, NodeByIdHeader.encoded_len + 260 * NodeByIdRecord.uniform_short_derived_offset_encoded_len + 3 * 8),
        try store.regularFileSize(file),
    );

    var expected_offset: u64 = 0;
    var id: u64 = 1;
    while (id <= 260) : (id += 1) {
        const record = try store.readNodeByIdRecordAt(file, header, id);
        try std.testing.expectEqual(id, record.id);
        try std.testing.expectEqual(expected_offset, record.text_offset);
        try std.testing.expectEqual(@as(u32, 4), record.text_len);
        expected_offset = std.math.add(u64, expected_offset, 4) catch return error.InvalidRecord;
    }

    var loaded = (try store.readNodeById(std.testing.allocator, .fromInt(260))).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0260", loaded.text);
}

test "store node by id appends single derived dense tail without rewriting wide records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var first: [128]graph_mod.Node = undefined;
    var expected_offset: u64 = 0;
    var first_text_bytes: [128][4]u8 = undefined;
    for (&first, 0..) |*node, index| {
        const id: u64 = @intCast(index + 1);
        const text = try std.fmt.bufPrint(&first_text_bytes[index], "{d:0>4}", .{id});
        node.* = .{
            .id = .fromInt(id),
            .kind = .file,
            .text = text,
        };
        expected_offset = std.math.add(u64, expected_offset, text.len) catch return error.InvalidRecord;
    }
    try store.appendNodesBatch(&first);

    const appended_id = try store.addNode(.file, "0129");
    try std.testing.expectEqual(@as(u64, 129), appended_id.toInt());

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeByIdHeaderFromFile(file);
    try std.testing.expect(header.hasDerivedTextOffset());
    try std.testing.expectEqual(@as(u64, 129), header.node_count);
    try std.testing.expectEqual(@as(u64, 129), header.max_node_id);
    try std.testing.expectEqual(
        @as(u64, NodeByIdHeader.encoded_len + 129 * NodeByIdRecord.uniform_short_derived_offset_encoded_len + 2 * 8),
        try store.regularFileSize(file),
    );

    const appended = try store.readNodeByIdRecordAt(file, header, 129);
    try std.testing.expectEqual(@as(u64, 129), appended.id);
    try std.testing.expectEqual(expected_offset, appended.text_offset);
    try std.testing.expectEqual(@as(u32, 4), appended.text_len);
}

test "store sorted node text tail widens compact id lane for high node ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_texts_path,
        .data = "alphabetagamma",
        .flags = .{ .truncate = true },
    });

    const high_id: u64 = @as(u64, std.math.maxInt(u32)) + 1;
    var records = [_]NodeTextIndexRecord{
        .{
            .hash = storage_data_plane_support.nodeTextHash("alpha"),
            .id = 0,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 0,
            .text_len = 5,
        },
        .{
            .hash = storage_data_plane_support.nodeTextHash("beta"),
            .id = 0,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_offset = 5,
            .text_len = 4,
        },
    };
    std.mem.sort(NodeTextIndexRecord, &records, {}, storage_data_plane_support.nodeTextIndexLessThan);
    records[0].id = 1;
    records[1].id = high_id;

    try store.writeNodeTextIndex(records[0..1]);

    try store.appendNodeTextIndexRecord(.{
        .hash = records[1].hash,
        .id = records[1].id,
        .kind = records[1].kind,
        .text_offset = records[1].text_offset,
        .text_len = records[1].text_len,
    });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeTextIndexHeaderFromFile(file);
    try std.testing.expect(header.hasUniformKind());
    try std.testing.expect(header.hasShortTextLen());
    try std.testing.expect(!header.hasU32Id());
    try std.testing.expect(!header.hasDerivedHash());
    try std.testing.expectEqual(@as(u16, 24), header.record_len);
    try std.testing.expectEqual(@as(u64, 1), (try store.readNodeTextIndexRecordAt(file, 0)).id);
    try std.testing.expectEqual(high_id, (try store.readNodeTextIndexRecordAt(file, 1)).id);
}

test "store appends and replays graph events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.edges.items.len);
    try std.testing.expectError(core.Error.BudgetExceeded, store.loadGraphDeadline(.immediate));

    const stats_out = try store.stats();
    try std.testing.expectEqual(@as(usize, 2), stats_out.nodes);
    try std.testing.expectEqual(@as(usize, 1), stats_out.edges);

    var bin_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.events_bin_path, .{});
    defer bin_file.close(std.testing.io);
    try std.testing.expect((try bin_file.stat(std.testing.io)).size > 0);
}

fn appendTestNodeRefEvent(store: *Store, out: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u64, kind: core.NodeKind, text: []const u8) !void {
    const span = try store.appendNodeTextBytes(text);
    const node: graph_mod.Node = .{
        .id = core.NodeId.fromInt(id),
        .kind = kind,
        .text = text,
    };
    var payload: [storage_data_plane_support.binary_node_payload_len]u8 = undefined;
    _ = try storage_data_plane_support.encodeBinaryNodeFixedPayload(&payload, node, span);
    try storage_data_plane_support.appendBinaryRecord(out, allocator, .node, &payload);
}

test "store createEmpty is non destructive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "src/main.zig");
    try store.appendNode(graph.nodes.items[0]);

    const before = try store.stats();
    try std.testing.expectEqual(@as(usize, 1), before.nodes);
    try store.createEmpty();
    const after = try store.stats();
    try std.testing.expectEqual(@as(usize, 1), after.nodes);
}

test "store createEmpty repairs stale metadata even when index files exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    var stale = try store.readIndexMeta();
    stale.event_bytes -= 1;
    try store.writeIndexMeta(stale);

    try store.createEmpty();

    var node = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/main.zig", node.text);
    const repaired = try store.readIndexMeta();
    try std.testing.expectEqual(try store.eventBytes(), repaired.event_bytes);
}

test "store createEmpty fast path skips append log checksum audit when indexes are current" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const long_text = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(long_text);
    @memset(long_text, 'x');
    try store.appendNode(.{ .id = .fromInt(1), .kind = .document, .text = long_text });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.events_bin_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const corrupt_offset = storage_data_plane_support.BinaryRecordHeader.encoded_len + 10;
    try file.writePositionalAll(std.testing.io, "z", corrupt_offset);

    try store.createEmpty();
    try store.validatePersistentIndexFiles();
    try std.testing.expectError(error.InvalidRecord, store.validatePersistentIndexes());

    var strict_store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{ .validate_indexes_on_read = true });
    defer strict_store.deinit();
    try std.testing.expectError(error.InvalidRecord, strict_store.createEmpty());
}

test "store repair rebuilds sparse node catalog in one pass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    inline for (&[_]struct { id: u64, text: []const u8 }{
        .{ .id = 1, .text = "one.zig" },
        .{ .id = 4, .text = "four.zig" },
    }) |node| {
        try appendTestNodeRefEvent(&store, &bytes, std.testing.allocator, node.id, .file, node.text);
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try store.repairPersistentIndexesFromLog();

    var one = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one.zig", one.text);
    try std.testing.expect((try store.readNodeById(std.testing.allocator, .fromInt(2))) == null);
    var four = (try store.readNodeById(std.testing.allocator, .fromInt(4))).?;
    defer four.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("four.zig", four.text);
    try std.testing.expectEqual(@as(u64, 5), (try store.nextNodeId()).toInt());
}

test "store repair extends high sparse node id catalog without zero-fill writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const high_id: u64 = 1_000_000;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    inline for (&[_]struct { id: u64, text: []const u8 }{
        .{ .id = 1, .text = "one.zig" },
        .{ .id = high_id, .text = "high.zig" },
    }) |node| {
        try appendTestNodeRefEvent(&store, &bytes, std.testing.allocator, node.id, .file, node.text);
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try store.repairPersistentIndexesFromLog();

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
        defer file.close(std.testing.io);
        const header = try store.readNodeByIdHeaderFromFile(file);
        try std.testing.expect(header.hasUniformKind());
        try std.testing.expect(header.hasShortTextLen());
        try std.testing.expectEqual(@as(u16, NodeByIdRecord.uniform_short_text_len_encoded_len), header.record_len);
        try std.testing.expectEqual(try store.nodeByIdFileSizeForHeaderStore(header), try store.fileSizeOrZero(store.node_by_id_path));
    }
    try std.testing.expect((try store.readNodeById(std.testing.allocator, .fromInt(2))) == null);
    var high = (try store.readNodeById(std.testing.allocator, .fromInt(high_id))).?;
    defer high.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("high.zig", high.text);
    try std.testing.expectEqual(high_id + 1, (try store.nextNodeId()).toInt());
}

test "store node by id uniform records keep u32 text length for long outliers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const long_text = try std.testing.allocator.alloc(u8, @as(usize, std.math.maxInt(u16)) + 1);
    defer std.testing.allocator.free(long_text);
    @memset(long_text, 'x');

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "short.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = long_text });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeByIdHeaderFromFile(file);
    try std.testing.expect(header.hasUniformKind());
    try std.testing.expect(!header.hasShortTextLen());
    try std.testing.expectEqual(@as(u16, NodeByIdRecord.uniform_encoded_len), header.record_len);
    try std.testing.expectEqual(NodeByIdHeader.encoded_len + 2 * NodeByIdRecord.uniform_encoded_len, try store.fileSizeOrZero(store.node_by_id_path));

    var node = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, long_text.len), node.text.len);
}

test "store node by id records derive ids from ordinal slots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .repo, .text = "repo" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .file, .text = "src/main.zig" });

    try std.testing.expectEqual(@as(usize, 12), NodeByIdRecord.encoded_len);
    try std.testing.expectEqual(
        NodeByIdHeader.encoded_len + 4 * NodeByIdRecord.encoded_len,
        try store.fileSizeOrZero(store.node_by_id_path),
    );

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeByIdHeaderFromFile(file);

    var repo_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
    try std.testing.expectEqual(
        NodeByIdRecord.encoded_len,
        try file.readPositionalAll(std.testing.io, &repo_bytes, NodeByIdHeader.encoded_len),
    );
    try std.testing.expectEqual(@as(u16, @intFromEnum(core.NodeKind.repo) + 1), std.mem.readInt(u16, repo_bytes[0..2], .little));

    const repo_record = try store.readNodeByIdRecordAt(file, header, 1);
    try std.testing.expectEqual(@as(u64, 1), repo_record.id);
    try std.testing.expectEqual(@as(u16, @intFromEnum(core.NodeKind.repo)), repo_record.kind);

    var repo_node = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer repo_node.deinit(std.testing.allocator);
    try std.testing.expectEqual(core.NodeKind.repo, repo_node.kind);
    try std.testing.expectEqualStrings("repo", repo_node.text);

    var file_node = (try store.readNodeById(std.testing.allocator, .fromInt(4))).?;
    defer file_node.deinit(std.testing.allocator);
    try std.testing.expectEqual(core.NodeKind.file, file_node.kind);
    try std.testing.expectEqualStrings("src/main.zig", file_node.text);
}

test "store node primary index records pack u48 text offsets" {
    const max_u48: u64 = @intCast(std.math.maxInt(u48));

    var by_id = NodeByIdRecord{
        .id = 7,
        .kind = @intFromEnum(core.NodeKind.file),
        .text_offset = max_u48,
        .text_len = 8 * 1024,
    };
    var by_id_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
    try by_id.encode(&by_id_bytes);
    const decoded_by_id = try NodeByIdRecord.decodeAt(7, &by_id_bytes);
    try std.testing.expectEqual(@as(u64, 7), decoded_by_id.id);
    try std.testing.expectEqual(max_u48, decoded_by_id.text_offset);
    try std.testing.expectEqual(@as(u32, 8 * 1024), decoded_by_id.text_len);

    by_id.text_offset = max_u48 + 1;
    try std.testing.expectError(error.RecordTooLarge, by_id.encode(&by_id_bytes));

    var by_text = NodeTextIndexRecord{
        .hash = 0x1234_5678,
        .id = 7,
        .kind = @intFromEnum(core.NodeKind.file),
        .text_offset = max_u48,
        .text_len = 8 * 1024,
    };
    var by_text_bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
    try by_text.encode(&by_text_bytes);
    const decoded_by_text = try NodeTextIndexRecord.decode(&by_text_bytes);
    try std.testing.expectEqual(@as(u64, 7), decoded_by_text.id);
    try std.testing.expectEqual(max_u48, decoded_by_text.text_offset);
    try std.testing.expectEqual(@as(u32, 8 * 1024), decoded_by_text.text_len);

    by_text.text_offset = max_u48 + 1;
    try std.testing.expectError(error.RecordTooLarge, by_text.encode(&by_text_bytes));
}

test "store batch appends nodes with stream-merged text index maintenance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    const before_nodes = try store.eventByteCount();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(10), .kind = .file, .text = "z.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(7), .kind = .task, .text = "a.zig" },
    });
    const expected_batch_bytes =
        3 * storage_data_plane_support.BinaryRecordHeader.encoded_len +
        storage_data_plane_support.binary_node_batch_base_header_len +
        3 * storage_data_plane_support.binary_node_payload_len;
    try std.testing.expectEqual(before_nodes + expected_batch_bytes, try store.eventByteCount());

    const stats_out = try store.stats();
    try std.testing.expectEqual(@as(usize, 3), stats_out.nodes);
    try std.testing.expectEqual(@as(usize, 0), stats_out.edges);
    const meta = try store.readIndexMeta();
    try std.testing.expectEqual(@as(u64, 3), meta.nodes);
    try std.testing.expectEqual(try store.eventByteCount(), meta.event_bytes);
    try std.testing.expect(try store.nodeIndexValid(3));

    var matches = try store.lookupNodesByTextLimited(std.testing.allocator, .file, "a.zig", 4);
    defer {
        for (matches.items) |*node| node.deinit(std.testing.allocator);
        matches.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(u64, 2), matches.items[0].id.toInt());
    try std.testing.expectEqual(@as(u64, 11), (try store.nextNodeId()).toInt());
}

test "store batch appends dense uniform nodes with compact node batch payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    const before_nodes = try store.eventByteCount();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "b.zig" },
        .{ .id = .fromInt(3), .kind = .file, .text = "c.zig" },
    });
    const expected_batch_bytes =
        3 * storage_data_plane_support.BinaryRecordHeader.encoded_len +
        storage_data_plane_support.binary_node_batch_compact_header_len +
        storage_data_plane_support.binary_node_batch_derived_text_offset_header_extra_len +
        3 * storage_data_plane_support.binary_node_batch_compact_short_derived_text_offset_row_len;
    try std.testing.expectEqual(before_nodes + expected_batch_bytes, try store.eventByteCount());

    const stats_out = try store.stats();
    try std.testing.expectEqual(@as(usize, 3), stats_out.nodes);
    try std.testing.expectEqual(@as(usize, 0), stats_out.edges);
    try std.testing.expect(try store.nodeIndexValid(3));

    var text_index_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{});
    defer text_index_file.close(std.testing.io);
    const text_header = try store.readNodeTextIndexHeaderFromFile(text_index_file);
    try std.testing.expect(text_header.hasDerivedTextSpan());
    try std.testing.expect(!text_header.hasDerivedHash());
    try std.testing.expect(text_header.hasU32Id());
    try std.testing.expect(text_header.hasUniformKind());
    try std.testing.expectEqual(@as(u16, 12), text_header.record_len);

    try std.testing.expectEqual(@as(u64, 4), (try store.nextNodeId()).toInt());
}

test "node index layout hint exposes dense uniform facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "b.zig" },
        .{ .id = .fromInt(3), .kind = .file, .text = "c.zig" },
    });

    const hint = (try store.nodeIndexLayoutHint()) orelse return error.InvalidRecord;
    try std.testing.expectEqual(@as(u64, 3), hint.node_count);
    try std.testing.expectEqual(@as(u32, 1), hint.dense_node_id_base);
    try std.testing.expectEqual(core.NodeKind.file, hint.uniform_kind.?);
}

test "searchable node index layout hint is conservative around edit tombstones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const file_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "files.kg" });
    defer std.testing.allocator.free(file_store_path);
    const edit_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edits.kg" });
    defer std.testing.allocator.free(edit_store_path);
    const mixed_store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "mixed.kg" });
    defer std.testing.allocator.free(mixed_store_path);

    var file_store = try Store.initWithOptions(std.testing.allocator, std.testing.io, file_store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer file_store.deinit();
    try file_store.createEmpty();
    try file_store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "b.zig" },
    });
    const file_hint = (try file_store.searchableNodeIndexLayoutHint()) orelse return error.InvalidRecord;
    try std.testing.expectEqual(@as(u64, 2), file_hint.node_count);
    try std.testing.expectEqual(core.NodeKind.file, file_hint.uniform_kind.?);

    var edit_store = try Store.initWithOptions(std.testing.allocator, std.testing.io, edit_store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer edit_store.deinit();
    try edit_store.createEmpty();
    try edit_store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .edit, .text = "__tinykg_deleted_node__ 1" },
        .{ .id = .fromInt(2), .kind = .edit, .text = "ordinary edit memory" },
    });
    try std.testing.expectEqual(@as(?NodeIndexLayoutHint, null), try edit_store.searchableNodeIndexLayoutHint());

    var mixed_store = try Store.initWithOptions(std.testing.allocator, std.testing.io, mixed_store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer mixed_store.deinit();
    try mixed_store.createEmpty();
    try mixed_store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(2), .kind = .edit, .text = "__tinykg_deleted_node__ 2" },
    });
    try std.testing.expectEqual(@as(?NodeIndexLayoutHint, null), try mixed_store.searchableNodeIndexLayoutHint());
}

test "store compact node batch keeps u32 text length for long outliers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = true,
    });
    defer store.deinit();
    try store.createEmpty();

    const long_text = try std.testing.allocator.alloc(u8, @as(usize, std.math.maxInt(u16)) + 1);
    defer std.testing.allocator.free(long_text);
    @memset(long_text, 'x');

    const before_nodes = try store.eventByteCount();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "short.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = long_text },
    });
    const expected_batch_bytes =
        3 * storage_data_plane_support.BinaryRecordHeader.encoded_len +
        storage_data_plane_support.binary_node_batch_compact_header_len +
        storage_data_plane_support.binary_node_batch_derived_text_offset_header_extra_len +
        2 * storage_data_plane_support.binary_node_batch_compact_derived_text_offset_row_len;
    try std.testing.expectEqual(before_nodes + expected_batch_bytes, try store.eventByteCount());
    try std.testing.expect(try store.nodeIndexValid(2));

    var node = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, long_text.len), node.text.len);
}

test "node batch short text length flag requires compact dense uniform shape" {
    var payload = [_]u8{0} ** (storage_data_plane_support.binary_node_batch_compact_header_len + storage_data_plane_support.binary_node_batch_compact_short_text_len_row_len);
    std.mem.writeInt(u32, payload[0..4], 1, .little);
    std.mem.writeInt(u16, payload[4..6], storage_data_plane_support.binary_node_batch_flag_short_text_len, .little);
    std.mem.writeInt(u16, payload[6..8], @intFromEnum(core.NodeKind.file), .little);
    std.mem.writeInt(u64, payload[8..16], 1, .little);
    try storage_data_plane_support.writeU48(payload[16..22], 0);
    std.mem.writeInt(u16, payload[22..24], 3, .little);
    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.validateBinaryNodeBatchPayload(&payload));

    std.mem.writeInt(u16, payload[4..6], storage_data_plane_support.binary_node_batch_flag_derived_text_offset, .little);
    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.validateBinaryNodeBatchPayload(&payload));

    std.mem.writeInt(u16, payload[4..6], storage_data_plane_support.binary_node_batch_compact_flags | storage_data_plane_support.binary_node_batch_flag_short_text_len | (1 << 15), .little);
    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.validateBinaryNodeBatchPayload(&payload));
}

test "node batch derived text offsets synthesize contiguous spans" {
    var payload = [_]u8{0} ** (storage_data_plane_support.binary_node_batch_compact_header_len + storage_data_plane_support.binary_node_batch_derived_text_offset_header_extra_len + 2 * storage_data_plane_support.binary_node_batch_compact_short_derived_text_offset_row_len);
    std.mem.writeInt(u32, payload[0..4], 2, .little);
    std.mem.writeInt(u16, payload[4..6], storage_data_plane_support.binary_node_batch_compact_flags | storage_data_plane_support.binary_node_batch_flag_short_text_len | storage_data_plane_support.binary_node_batch_flag_derived_text_offset, .little);
    std.mem.writeInt(u16, payload[6..8], @intFromEnum(core.NodeKind.file), .little);
    std.mem.writeInt(u64, payload[8..16], 7, .little);
    try storage_data_plane_support.writeU48(payload[16..22], 100);
    std.mem.writeInt(u16, payload[22..24], 3, .little);
    std.mem.writeInt(u16, payload[24..26], 5, .little);

    const batch = try storage_data_plane_support.validateBinaryNodeBatchHeader(&payload);
    try std.testing.expect(batch.derived_text_offset);
    try std.testing.expect(batch.short_text_len);
    try std.testing.expectEqual(@as(usize, storage_data_plane_support.binary_node_batch_compact_short_derived_text_offset_row_len), batch.row_len);

    var reader = try storage_data_plane_support.BinaryNodeBatchReader.init(&payload);
    const first = (try reader.next()).?;
    const second = (try reader.next()).?;
    try std.testing.expect((try reader.next()) == null);
    try std.testing.expectEqual(@as(u64, 7), first.id);
    try std.testing.expectEqual(@as(u64, 100), first.text_offset);
    try std.testing.expectEqual(@as(u32, 3), first.text_len);
    try std.testing.expectEqual(@as(u64, 8), second.id);
    try std.testing.expectEqual(@as(u64, 103), second.text_offset);
    try std.testing.expectEqual(@as(u32, 5), second.text_len);
}

test "repair rebuilds node indexes from derived-offset node batch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "alpha.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "beta.zig" },
        .{ .id = .fromInt(3), .kind = .file, .text = "gamma.zig" },
    });
    const before_repair_events = try store.eventByteCount();

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.node_by_id_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.node_by_text_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.node_by_text_delta_path);
    try store.repairPersistentIndexesFromLog();

    try std.testing.expectEqual(before_repair_events, try store.eventByteCount());
    try std.testing.expect(try store.nodeIndexValid(3));
    var node = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("beta.zig", node.text);
}

test "store allocates next edge id from max persisted edge id not edge count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(10), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });

    try std.testing.expectEqual(@as(u64, 11), (try store.nextEdgeId()).toInt());
}

test "store fast edge id allocation skips secondary edge index validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "a" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .file, .text = "b.zig" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .function, .text = "b" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });

    try store.writeEdgeIndex(store.edge_by_dst_path, &.{
        .{ .src = 3, .dst = 4, .edge_id = 1, .rel = @intFromEnum(core.RelKind.defines) },
    });

    store.options.validate_indexes_on_read = true;
    try std.testing.expectError(error.InvalidRecord, store.nextEdgeId());

    store.options.validate_indexes_on_read = false;
    try std.testing.expectEqual(@as(u64, 2), (try store.nextEdgeId()).toInt());
}

test "store rejects edge append with missing endpoints before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.NotFound, store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines }));
    try std.testing.expectError(core.Error.NotFound, store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(2), .dst = .fromInt(1), .rel = .defines }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store rejects edge append with reserved zero endpoints before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(1),
        .src = .none,
        .dst = .fromInt(1),
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .dst = .none,
        .rel = .defines,
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store rejects max edge ids and endpoints before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(std.math.maxInt(u64)),
        .src = .fromInt(1),
        .dst = .fromInt(1),
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(1),
        .src = .fromInt(std.math.maxInt(u64)),
        .dst = .fromInt(1),
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .dst = .fromInt(std.math.maxInt(u64)),
        .rel = .defines,
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store rejects duplicate edge append before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store validates edge indexes on append even when read validation is disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = false;
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try store.writeEdgeIndex(store.edge_by_id_path, &.{});

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .dst = .fromInt(2),
        .rel = .mentions,
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store fast edge append rejects duplicate id when primary edge digest is stale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = false;
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try store.writeEdgeIndex(store.edge_by_id_path, &.{
        .{ .src = 1, .dst = 2, .edge_id = 2, .rel = @intFromEnum(core.RelKind.defines) },
    });

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .dst = .fromInt(2),
        .rel = .mentions,
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store ensures node indexes using only active graph nodes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const active = try graph.addNode(.file, "active.zig");
    const deleted = try graph.addNode(.file, "deleted.zig");
    const stale = try graph.addNode(.file, "stale.zig");
    for (graph.nodes.items) |*node| {
        if (node.id == deleted) node.status = .deleted;
        if (node.id == stale) node.status = .stale;
    }

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.writeIndexMeta(try store.currentIndexMeta(&graph));
    try store.ensurePersistentNodeIndexes(&graph);

    const repair_tmp_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.repair_texts.tmp", .{store.node_by_text_path});
    defer std.testing.allocator.free(repair_tmp_path);
    try std.testing.expect(!try store.fileExists(repair_tmp_path));
    try std.testing.expect(try store.nodeIndexValid(1));
    var active_node = (try store.readNodeById(std.testing.allocator, active)).?;
    defer active_node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("active.zig", active_node.text);
    try std.testing.expect((try store.readNodeById(std.testing.allocator, deleted)) == null);
    try std.testing.expect((try store.readNodeById(std.testing.allocator, stale)) == null);
}

test "store rejects duplicate active graph node ids during node index rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "first.zig");
    const duplicate_text = try std.testing.allocator.dupe(u8, "duplicate.zig");
    var duplicate_text_owned = true;
    errdefer if (duplicate_text_owned) std.testing.allocator.free(duplicate_text);
    try graph.nodes.append(std.testing.allocator, .{
        .id = .fromInt(1),
        .kind = .file,
        .text = duplicate_text,
    });
    duplicate_text_owned = false;

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.testing.expectError(core.Error.InvalidId, store.ensurePersistentNodeIndexes(&graph));
}

test "active node set uses dense bitset for normal ids and sparse fallback for high ids" {
    var dense_graph = graph_mod.Graph.init(std.testing.allocator);
    defer dense_graph.deinit();
    const first = try dense_graph.addNode(.file, "first.zig");
    const second = try dense_graph.addNode(.function, "second");

    var dense = try storage_data_plane_support.buildActiveNodeSet(std.testing.allocator, &dense_graph);
    defer dense.deinit();
    try std.testing.expectEqual(@as(u64, 2), dense.count);
    switch (dense.ids) {
        .dense => {},
        .sparse => return error.TestUnexpectedResult,
    }
    try std.testing.expect(dense.contains(first.toInt()));
    try std.testing.expect(dense.contains(second.toInt()));
    try std.testing.expect(!dense.contains(3));

    var sparse_graph = graph_mod.Graph.init(std.testing.allocator);
    defer sparse_graph.deinit();
    try sparse_graph.addNodeWithId(.fromInt(storage_data_plane_support.active_node_set_dense_max_id + 17), .file, "sparse.zig");

    var sparse = try storage_data_plane_support.buildActiveNodeSet(std.testing.allocator, &sparse_graph);
    defer sparse.deinit();
    switch (sparse.ids) {
        .dense => return error.TestUnexpectedResult,
        .sparse => {},
    }
    try std.testing.expect(sparse.contains(storage_data_plane_support.active_node_set_dense_max_id + 17));
    try std.testing.expect(!sparse.contains(1));
}

test "graph physical edge id set uses dense bitset and sparse fallback" {
    var ids = try storage_data_plane_support.GraphPhysicalEdgeIdSet.init(std.testing.allocator, 17);
    defer ids.deinit();
    try std.testing.expectEqual(@max(storage_data_plane_support.graph_edge_id_set_dense_min_id, @as(u64, 34)), ids.dense_limit);
    try std.testing.expect(!try ids.put(1));
    try std.testing.expect(!try ids.put(17));
    try std.testing.expect(try ids.put(1));
    try std.testing.expect(ids.dense_bits.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), ids.overflow.count());
    try std.testing.expectEqual(@as(u64, 2), ids.count);

    const high_id = ids.dense_limit + 17;
    try std.testing.expect(!try ids.put(high_id));
    try std.testing.expect(try ids.put(high_id));
    try std.testing.expectEqual(@as(usize, 1), ids.overflow.count());
    try std.testing.expectEqual(@as(u64, 3), ids.count);
}

test "graph current meta stats rejects duplicate physical edge ids" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const src = try graph.addNode(.file, "src.zig");
    const dst = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(src, .defines, dst);
    try graph.edges.append(std.testing.allocator, .{
        .id = .fromInt(1),
        .src = src,
        .dst = dst,
        .rel = .mentions,
    });

    try std.testing.expectError(core.Error.InvalidId, storage_data_plane_support.graphCurrentMetaStats(std.testing.allocator, &graph));
}

test "graph node-text order digest matches materialized records" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addNodeWithId(.fromInt(42), .function, "shared");
    try graph.addNodeWithId(.fromInt(7), .file, "alpha.zig");
    try graph.addNodeWithId(.fromInt(12), .repo, "shared");
    try graph.addNodeWithId(.fromInt(99), .task, "inactive");
    graph.nodes.items[3].status = .stale;

    var records = std.ArrayList(NodeTextIndexRecord).empty;
    defer records.deinit(std.testing.allocator);
    var order = std.ArrayList(u32).empty;
    defer order.deinit(std.testing.allocator);
    var text_offset: u64 = 0;
    for (graph.nodes.items, 0..) |node, node_index| {
        if (node.status != .active) continue;
        try records.append(std.testing.allocator, .{
            .hash = storage_data_plane_support.nodeTextHash(node.text),
            .id = node.id.toInt(),
            .kind = @intFromEnum(node.kind),
            .text_offset = text_offset,
            .text_len = @intCast(node.text.len),
        });
        try order.append(std.testing.allocator, @intCast(node_index));
        text_offset += @intCast(node.text.len);
    }

    std.mem.sort(NodeTextIndexRecord, records.items, {}, storage_data_plane_support.nodeTextIndexLessThan);
    std.mem.sort(u32, order.items, storage_data_plane_support.GraphNodeTextOrderContext{ .graph = &graph }, storage_data_plane_support.graphNodeTextOrderLessThan);
    try std.testing.expectEqual(storage_data_plane_support.nodeTextOrderDigestForRecords(records.items), storage_data_plane_support.graphNodeTextOrderDigest(&graph, order.items));
    for (records.items, order.items) |record, node_index| {
        const node = graph.nodes.items[@intCast(node_index)];
        try std.testing.expectEqual(record.hash, storage_data_plane_support.nodeTextHash(node.text));
        try std.testing.expectEqual(record.id, node.id.toInt());
        try std.testing.expectEqual(record.kind, @intFromEnum(node.kind));
    }
}

test "graph edge order digests match materialized records" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addNodeWithId(.fromInt(10), .file, "src.zig");
    try graph.addNodeWithId(.fromInt(3), .function, "alpha");
    try graph.addNodeWithId(.fromInt(8), .function, "beta");
    try graph.addNodeWithId(.fromInt(12), .task, "stale");
    try graph.addEdgeWithIdUnchecked(.fromInt(30), .fromInt(10), .defines, .fromInt(8));
    try graph.addEdgeWithIdUnchecked(.fromInt(5), .fromInt(10), .mentions, .fromInt(3));
    try graph.addEdgeWithIdUnchecked(.fromInt(17), .fromInt(3), .blocks, .fromInt(8));
    try graph.addEdgeWithIdUnchecked(.fromInt(44), .fromInt(8), .depends_on, .fromInt(10));
    try graph.addEdgeWithIdUnchecked(.fromInt(55), .fromInt(10), .depends_on, .fromInt(12));
    graph.nodes.items[3].status = .stale;
    graph.edges.items[3].status = .deleted;

    var active_nodes = try storage_data_plane_support.buildActiveNodeSet(std.testing.allocator, &graph);
    defer active_nodes.deinit();
    var records = std.ArrayList(EdgeIndexRecord).empty;
    defer records.deinit(std.testing.allocator);
    var order = std.ArrayList(u32).empty;
    defer order.deinit(std.testing.allocator);
    for (graph.edges.items, 0..) |edge, edge_index| {
        const record = (try storage_data_plane_support.physicalEdgeRecord(&active_nodes, edge)) orelse continue;
        try records.append(std.testing.allocator, record);
        try order.append(std.testing.allocator, @intCast(edge_index));
    }
    try std.testing.expectEqual(@as(usize, 4), records.items.len);

    for ([_]EdgeIndexOrder{ .id, .src, .dst }) |edge_order| {
        storage_data_plane_support.sortEdgeIndexRecords(edge_order, records.items);
        std.mem.sort(u32, order.items, storage_data_plane_support.GraphEdgeOrderContext{ .graph = &graph, .order = edge_order }, storage_data_plane_support.graphEdgeOrderLessThan);
        try std.testing.expectEqual(storage_data_plane_support.edgeOrderDigestForRecords(records.items), storage_data_plane_support.graphEdgeOrderDigest(&graph, order.items));
        for (records.items, order.items) |record, edge_index| {
            const graph_record = storage_data_plane_support.edgeIndexRecordFromEdge(graph.edges.items[@intCast(edge_index)]);
            try std.testing.expect(storage_data_plane_support.edgeIndexRecordEquals(record, graph_record));
        }
    }
}

test "store rebuilds node indexes with zero-length node text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const empty_text = try std.testing.allocator.dupe(u8, "");
    var empty_text_owned = true;
    errdefer if (empty_text_owned) std.testing.allocator.free(empty_text);
    try graph.nodes.append(std.testing.allocator, .{
        .id = .fromInt(1),
        .kind = .file,
        .text = empty_text,
    });
    empty_text_owned = false;

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.ensurePersistentNodeIndexes(&graph);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{});
    defer file.close(std.testing.io);
    const header = try store.readNodeByIdHeaderFromFile(file);
    const record = try store.readNodeByIdRecordAt(file, header, 1);
    try std.testing.expectEqual(@as(u64, 1), record.id);
    try std.testing.expectEqual(@as(u32, 0), record.text_len);
}

test "store ensures edge indexes using only active graph edges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const src = try graph.addNode(.file, "src.zig");
    const active_dst = try graph.addNode(.function, "active");
    const deleted_dst = try graph.addNode(.function, "deleted");
    const stale_dst = try graph.addNode(.function, "stale");
    const stale_node_dst = try graph.addNode(.function, "stale-node");
    const active_edge = try graph.addEdgeUnchecked(src, .defines, active_dst);
    const deleted_edge = try graph.addEdgeUnchecked(src, .mentions, deleted_dst);
    const stale_edge = try graph.addEdgeUnchecked(src, .blocks, stale_dst);
    _ = try graph.addEdgeUnchecked(src, .depends_on, stale_node_dst);
    for (graph.nodes.items) |*node| {
        if (node.id == stale_node_dst) node.status = .stale;
    }
    for (graph.edges.items) |*edge| {
        if (edge.id == deleted_edge) edge.status = .deleted;
        if (edge.id == stale_edge) edge.status = .stale;
    }

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const meta = try store.currentIndexMeta(&graph);
    try std.testing.expectEqual(@as(u64, 1), meta.edges);
    try store.writeIndexMeta(meta);
    try store.ensurePersistentNodeIndexes(&graph);
    try store.ensurePersistentEdgeIndexes(&graph);

    try std.testing.expectEqual(@as(u64, 2), (try store.readIndexMeta()).edge_indexed_edges);
    const tombstone_header = try store.readEdgeTombstoneIndexHeader();
    try std.testing.expectEqual(@as(u64, 1), tombstone_header.count);
    const edge_repair_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.repair_edges.tmp", .{store.edge_by_id_path});
    defer std.testing.allocator.free(edge_repair_path);
    const tombstone_repair_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.repair_tombstones.tmp", .{store.edge_tombstones_path});
    defer std.testing.allocator.free(tombstone_repair_path);
    try std.testing.expectEqual(@as(u64, 0), try store.fileSizeOrZero(edge_repair_path));
    try std.testing.expectEqual(@as(u64, 0), try store.fileSizeOrZero(tombstone_repair_path));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_id_path, .id, 2));
    var records = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, src);
    defer records.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqual(active_edge.toInt(), records.items[0].edge_id);
    try std.testing.expectEqual(active_dst.toInt(), records.items[0].dst);
}

test "store rejects duplicate active graph edge ids during edge index rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const src = try graph.addNode(.file, "src.zig");
    const first = try graph.addNode(.function, "first");
    const second = try graph.addNode(.function, "second");
    _ = try graph.addEdgeUnchecked(src, .defines, first);
    try graph.edges.append(std.testing.allocator, .{
        .id = .fromInt(1),
        .src = src,
        .dst = second,
        .rel = .mentions,
    });

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try std.testing.expectError(error.InvalidRecord, store.currentIndexMeta(&graph));
    try store.writeIndexMeta(.{
        .event_bytes = try store.eventBytes(),
        .nodes = 3,
        .edges = 2,
        .edge_digest = 0,
    });
    try std.testing.expectError(error.InvalidRecord, store.ensurePersistentEdgeIndexes(&graph));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_id_path, .id, 0));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_src_path, .src, 0));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_dst_path, .dst, 0));
}

test "storage write buffer capacity is bounded by file size and cap" {
    try std.testing.expectEqual(@as(usize, EdgeIndexHeader.encoded_len), try storage_data_plane_support.storageWriteBufferCapacity(try storage_data_plane_support.edgeIndexFileSize(0)));
    try std.testing.expectEqual(@as(usize, NodeTextIndexHeader.encoded_len), try storage_data_plane_support.storageWriteBufferCapacity(try storage_data_plane_support.nodeTextIndexFileSize(0)));
    try std.testing.expectEqual(storage_data_plane_support.storage_write_buffer_bytes, try storage_data_plane_support.storageWriteBufferCapacity(storage_data_plane_support.storage_write_buffer_bytes + 1));
}

test "repair edge digest index catches fallback then dense duplicate" {
    var index = storage_data_plane_support.RepairEdgeDigestIndex.init(std.testing.allocator);
    defer index.deinit(std.testing.allocator);

    const sparse_under_cap = @as(u64, 100_000);
    try std.testing.expect(!try index.put(std.testing.allocator, sparse_under_cap, 0x1234, 0));
    try std.testing.expect(try index.put(std.testing.allocator, sparse_under_cap, 0x5678, 100_000));
    try std.testing.expectEqual(@as(?u64, 0x1234), try index.delete(std.testing.allocator, sparse_under_cap));
    try std.testing.expectError(error.InvalidRecord, index.delete(std.testing.allocator, sparse_under_cap));
}

test "repair edge replay tracker avoids digest table until delete" {
    var tracker = storage_data_plane_support.RepairEdgeReplayTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(!try tracker.put(1, 0x1111, 0));
    try std.testing.expect(!try tracker.put(2, 0x2222, 1));
    try std.testing.expect(try tracker.put(1, 0x3333, 2));
    try std.testing.expect(tracker.digests == null);
}

test "store rejects edge append when edge id index count disagrees with metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });

    try store.writeEdgeIndex(store.edge_by_id_path, &.{});

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(
        core.Error.InvalidId,
        store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions }),
    );
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store rejects non-active edge append before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.Unsupported, store.appendEdge(.{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .dst = .fromInt(2),
        .rel = .defines,
        .status = .deleted,
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store updates persistent edge indexes during append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    const id_header = try store.readEdgeIndexHeader(store.edge_by_id_path);
    const src_header = try store.readEdgeIndexHeader(store.edge_by_src_path);
    const dst_header = try store.readEdgeIndexHeader(store.edge_by_dst_path);
    try std.testing.expectEqual(EdgeIndexOrder.id, id_header.order);
    try std.testing.expectEqual(EdgeIndexOrder.src, src_header.order);
    try std.testing.expectEqual(EdgeIndexOrder.dst, dst_header.order);
    try std.testing.expectEqual(@as(u64, 1), id_header.edge_count);
    try std.testing.expectEqual(@as(u64, 1), src_header.edge_count);
    try std.testing.expectEqual(@as(u64, 1), dst_header.edge_count);
    try std.testing.expect(id_header.hasU32NodeIds());
    try std.testing.expect(src_header.hasU32NodeIds());
    try std.testing.expect(dst_header.hasU32NodeIds());
    try std.testing.expect(!id_header.hasU32EdgeIds());
    try std.testing.expect(src_header.hasU32EdgeIds());
    try std.testing.expect(dst_header.hasU32EdgeIds());

    const expected_dense_uniform_size = EdgeIndexHeader.encoded_len + EdgeIndexRecord.u32_nodes_dense_id_derived_rel_encoded_len;
    try std.testing.expectEqual(@as(u64, expected_dense_uniform_size), try store.fileSizeOrZero(store.edge_by_id_path));
    try std.testing.expectEqual(try storage_data_plane_support.edgeIndexFileSizeForHeader(src_header), try store.fileSizeOrZero(store.edge_by_src_path));
    try std.testing.expectEqual(try storage_data_plane_support.edgeIndexFileSizeForHeader(dst_header), try store.fileSizeOrZero(store.edge_by_dst_path));
    var by_id = try store.readAllEdgeIndexRecords(std.testing.allocator, store.edge_by_id_path, .id);
    defer by_id.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), by_id.items.len);
    try std.testing.expectEqual(edge.toInt(), by_id.items[0].edge_id);
    var records = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, file);
    defer records.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqual(func.toInt(), records.items[0].dst);
}

test "store derives edge index relations with bounded exceptions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "n1" },
        .{ .id = .fromInt(2), .kind = .file, .text = "n2" },
        .{ .id = .fromInt(3), .kind = .file, .text = "n3" },
        .{ .id = .fromInt(4), .kind = .file, .text = "n4" },
        .{ .id = .fromInt(5), .kind = .file, .text = "n5" },
        .{ .id = .fromInt(6), .kind = .file, .text = "n6" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(2), .dst = .fromInt(3), .rel = .depends_on },
        .{ .id = .fromInt(3), .src = .fromInt(3), .dst = .fromInt(4), .rel = .mentions },
        .{ .id = .fromInt(4), .src = .fromInt(4), .dst = .fromInt(5), .rel = .depends_on },
        .{ .id = .fromInt(5), .src = .fromInt(5), .dst = .fromInt(6), .rel = .mentions },
    });
    try store.repairPersistentIndexesFromLog();

    const id_header = try store.readEdgeIndexHeader(store.edge_by_id_path);
    const src_header = try store.readEdgeIndexHeader(store.edge_by_src_path);
    const dst_header = try store.readEdgeIndexHeader(store.edge_by_dst_path);
    try std.testing.expect(id_header.hasDenseId());
    try std.testing.expect(id_header.hasDerivedRel());
    try std.testing.expect(src_header.hasDerivedRel());
    try std.testing.expect(dst_header.hasDerivedRel());
    try std.testing.expect(id_header.hasKeyRuns());
    try std.testing.expect(id_header.hasKeyRunConstantOpposite());
    try std.testing.expectEqual(@as(u32, 1), id_header.key_run_count);
    try std.testing.expectEqual(@as(u16, 0), id_header.record_len);
    try std.testing.expect(id_header.hasU32NodeIds());
    try std.testing.expect(src_header.hasU32NodeIds());
    try std.testing.expect(dst_header.hasU32NodeIds());
    try std.testing.expect(!id_header.hasU32EdgeIds());
    try std.testing.expect(src_header.hasU32EdgeIds());
    try std.testing.expect(dst_header.hasU32EdgeIds());
    try std.testing.expectEqual(@intFromEnum(core.RelKind.mentions), id_header.default_rel);
    try std.testing.expectEqual(@as(u8, 2), id_header.rel_exception_count);
    try std.testing.expectEqual(@as(u64, 2), id_header.rel_exception_edge_ids[0]);
    try std.testing.expectEqual(@as(u64, 4), id_header.rel_exception_edge_ids[1]);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.depends_on), id_header.rel_exception_rels[0]);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.depends_on), id_header.rel_exception_rels[1]);

    const expected_dense_derived_size = EdgeIndexHeader.encoded_len + storage_data_plane_support.edgeIndexKeyRunRecordLen(id_header);
    try std.testing.expectEqual(@as(u64, expected_dense_derived_size), try store.fileSizeOrZero(store.edge_by_id_path));
    try std.testing.expectEqual(try storage_data_plane_support.edgeIndexFileSizeForHeader(src_header), try store.fileSizeOrZero(store.edge_by_src_path));
    try std.testing.expectEqual(try storage_data_plane_support.edgeIndexFileSizeForHeader(dst_header), try store.fileSizeOrZero(store.edge_by_dst_path));

    var by_id = try store.readAllEdgeIndexRecords(std.testing.allocator, store.edge_by_id_path, .id);
    defer by_id.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), by_id.items.len);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.mentions), by_id.items[0].rel);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.depends_on), by_id.items[1].rel);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.mentions), by_id.items[2].rel);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.depends_on), by_id.items[3].rel);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.mentions), by_id.items[4].rel);
}

test "edge id index derives endpoint runs with non-monotonic run keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "n1" },
        .{ .id = .fromInt(2), .kind = .file, .text = "n2" },
        .{ .id = .fromInt(3), .kind = .file, .text = "n3" },
        .{ .id = .fromInt(4), .kind = .file, .text = "n4" },
        .{ .id = .fromInt(5), .kind = .file, .text = "n5" },
        .{ .id = .fromInt(6), .kind = .file, .text = "n6" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(2), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(3), .src = .fromInt(3), .dst = .fromInt(1), .rel = .mentions },
        .{ .id = .fromInt(4), .src = .fromInt(4), .dst = .fromInt(5), .rel = .mentions },
        .{ .id = .fromInt(5), .src = .fromInt(5), .dst = .fromInt(6), .rel = .mentions },
    });

    const header = try store.readEdgeIndexHeader(store.edge_by_id_path);
    try std.testing.expect(header.hasDenseId());
    try std.testing.expect(header.hasDerivedRel());
    try std.testing.expect(header.hasKeyRuns());
    try std.testing.expect(header.hasKeyRunConstantOpposite());
    try std.testing.expectEqual(@as(u32, 3), header.key_run_count);
    try std.testing.expectEqual(@as(u16, 0), header.record_len);
    try std.testing.expectEqual(@as(u64, EdgeIndexHeader.encoded_len + 3 * storage_data_plane_support.edgeIndexKeyRunRecordLen(header)), try store.fileSizeOrZero(store.edge_by_id_path));

    var by_id = try store.readAllEdgeIndexRecords(std.testing.allocator, store.edge_by_id_path, .id);
    defer by_id.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), by_id.items.len);
    try std.testing.expectEqual(@as(u64, 3), by_id.items[2].src);
    try std.testing.expectEqual(@as(u64, 1), by_id.items[2].dst);
    try std.testing.expectEqual(@as(u64, 5), by_id.items[4].src);
    try std.testing.expectEqual(@as(u64, 6), by_id.items[4].dst);
}

test "edge id run summary derives dense id range without scanning key-run body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var header = EdgeIndexHeader.withShape(.id, 3, 0, 0, true, true, false, null);
    header = header.withKeyRuns(2, true, false);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, store.edge_by_id_path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(std.testing.io);
    var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
    header.encode(&header_bytes);
    try file.writePositionalAll(std.testing.io, &header_bytes, 0);
    try file.setLength(std.testing.io, try storage_data_plane_support.edgeIndexFileSizeForHeader(header));

    const summary = try store.edgeIdRunSummaryForIndexFile(file, header);
    try std.testing.expectEqual(@as(u64, 1), summary.run_count);
    try std.testing.expectEqual(@as(u64, 1), summary.first_min);
    try std.testing.expectEqual(@as(u64, 3), summary.first_max);
}

test "dense edge id metadata paths avoid record-body reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const header = EdgeIndexHeader.withShape(.id, 3, 11, 22, true, false, false, null);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, store.edge_by_id_path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(std.testing.io);
    var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
    header.encode(&header_bytes);
    try file.writePositionalAll(std.testing.io, &header_bytes, 0);
    try file.setLength(std.testing.io, try storage_data_plane_support.edgeIndexFileSizeForHeader(header));

    try std.testing.expect(try store.edgeIdExistsInFile(file, header, 2));
    try std.testing.expect(!try store.edgeIdExistsInFile(file, header, 4));
    try std.testing.expect(try store.edgeIdSortedSetIntersectsFile(file, header, &.{ 0, 3, 5 }));
    try std.testing.expect(!try store.edgeIdSortedSetIntersectsFile(file, header, &.{ 0, 4, 5 }));
    try std.testing.expect(try store.edgeIdRunSummaryMatchesFile(file, header, .{
        .run_count = 1,
        .first_min = 1,
        .first_max = 3,
    }));

    var meta = IndexMeta{
        .edge_indexed_edges = 3,
        .edge_index_digest = 11,
        .edge_by_id_order_digest = 22,
        .max_edge_id_seen = 2,
    };
    try std.testing.expect(try store.edgeIndexTailExceedsHighWater(meta));
    meta.max_edge_id_seen = 3;
    try std.testing.expect(!try store.edgeIndexTailExceedsHighWater(meta));
}

test "edge id endpoint runs reject synthesized u32 endpoint overflow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var header = EdgeIndexHeader.withShape(.id, 2, 0, 0, true, true, false, .{
        .default_rel = @intFromEnum(core.RelKind.mentions),
    });
    header = header.withKeyRuns(1, true, false);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, store.edge_by_id_path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(std.testing.io);
    var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
    header.encode(&header_bytes);
    try file.writePositionalAll(std.testing.io, &header_bytes, 0);
    const run = storage_data_plane_support.EdgeIndexKeyRunRecord{
        .key = std.math.maxInt(u32),
        .start = 0,
        .opposite = 1,
    };
    var run_bytes: [40]u8 = undefined;
    const encoded_run = run_bytes[0..storage_data_plane_support.edgeIndexKeyRunRecordLen(header)];
    try run.encodeForHeader(header, encoded_run);
    try file.writePositionalAll(std.testing.io, encoded_run, EdgeIndexHeader.encoded_len);
    try file.setLength(std.testing.io, try storage_data_plane_support.edgeIndexFileSizeForHeader(header));

    try std.testing.expectError(error.InvalidRecord, store.readEdgeIndexRecordAt(file, header, 1));
}

test "edge secondary indexes derive sorted endpoint key runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "n1" },
        .{ .id = .fromInt(2), .kind = .file, .text = "n2" },
        .{ .id = .fromInt(3), .kind = .file, .text = "n3" },
        .{ .id = .fromInt(4), .kind = .file, .text = "n4" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(3), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(4), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(5), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
        .{ .id = .fromInt(6), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
        .{ .id = .fromInt(7), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
        .{ .id = .fromInt(8), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
    });

    const id_header = try store.readEdgeIndexHeader(store.edge_by_id_path);
    const src_header = try store.readEdgeIndexHeader(store.edge_by_src_path);
    const dst_header = try store.readEdgeIndexHeader(store.edge_by_dst_path);
    try std.testing.expect(!id_header.hasKeyRuns());
    try std.testing.expect(src_header.hasKeyRuns());
    try std.testing.expect(dst_header.hasKeyRuns());
    try std.testing.expect(src_header.hasKeyRunConstantOpposite());
    try std.testing.expect(dst_header.hasKeyRunConstantOpposite());
    try std.testing.expect(!src_header.hasKeyRunRingOpposite());
    try std.testing.expect(!dst_header.hasKeyRunRingOpposite());
    try std.testing.expect(src_header.hasKeyRunLinearEdgeIds());
    try std.testing.expect(dst_header.hasKeyRunLinearEdgeIds());
    try std.testing.expect(src_header.hasKeyRunUniformEdgeIdStep());
    try std.testing.expect(dst_header.hasKeyRunUniformEdgeIdStep());
    try std.testing.expectEqual(@as(u64, 1), src_header.key_run_edge_id_step);
    try std.testing.expectEqual(@as(u64, 1), dst_header.key_run_edge_id_step);
    try std.testing.expectEqual(@as(u32, 2), src_header.key_run_count);
    try std.testing.expectEqual(@as(u32, 2), dst_header.key_run_count);
    try std.testing.expectEqual(@as(u16, 0), src_header.record_len);
    try std.testing.expectEqual(@as(u16, 0), dst_header.record_len);

    const expected_secondary_size = EdgeIndexHeader.encoded_len + 2 * storage_data_plane_support.edgeIndexKeyRunRecordLen(src_header) + 8 * src_header.record_len;
    try std.testing.expectEqual(@as(u64, expected_secondary_size), try store.fileSizeOrZero(store.edge_by_src_path));
    try std.testing.expectEqual(@as(u64, expected_secondary_size), try store.fileSizeOrZero(store.edge_by_dst_path));

    var by_src = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer by_src.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), by_src.items.len);
    try std.testing.expectEqual(@as(u64, 3), by_src.items[0].dst);
    try std.testing.expectEqual(@as(u64, 4), by_src.items[3].edge_id);

    var by_dst = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .dst, .fromInt(4));
    defer by_dst.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), by_dst.items.len);
    try std.testing.expectEqual(@as(u64, 2), by_dst.items[0].src);
    try std.testing.expectEqual(@as(u64, 8), by_dst.items[3].edge_id);
}

test "edge secondary key runs encode u32 edge ids with u64 node ids" {
    const base = @as(u64, std.math.maxInt(u32)) + 100;
    const header = EdgeIndexHeader
        .withShape(.src, 8, 0x11, 0x22, false, false, true, null)
        .withKeyRuns(2, true, true)
        .withKeyRunUniformEdgeIdStep(1);
    try header.validateShape();
    try std.testing.expect(!header.hasU32NodeIds());
    try std.testing.expect(header.hasU32EdgeIds());
    try std.testing.expectEqual(@as(usize, 28), storage_data_plane_support.edgeIndexKeyRunRecordLen(header));

    const record = storage_data_plane_support.EdgeIndexKeyRunRecord{
        .key = base + 1,
        .start = 0,
        .opposite = base + 3,
        .edge_id_base = 1,
        .edge_id_step = 1,
    };
    var bytes: [28]u8 = undefined;
    try record.encodeForHeader(header, &bytes);
    const decoded = try storage_data_plane_support.EdgeIndexKeyRunRecord.decodeSliceForHeader(header, &bytes);
    try std.testing.expectEqual(record.key, decoded.key);
    try std.testing.expectEqual(record.start, decoded.start);
    try std.testing.expectEqual(record.opposite, decoded.opposite);
    try std.testing.expectEqual(record.edge_id_base, decoded.edge_id_base);
    try std.testing.expectEqual(record.edge_id_step, decoded.edge_id_step);
}

test "edge secondary key runs keep explicit non-linear edge ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "n1" },
        .{ .id = .fromInt(2), .kind = .file, .text = "n2" },
        .{ .id = .fromInt(3), .kind = .file, .text = "n3" },
        .{ .id = .fromInt(4), .kind = .file, .text = "n4" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
        .{ .id = .fromInt(3), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(4), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(5), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
        .{ .id = .fromInt(6), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
        .{ .id = .fromInt(7), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(8), .src = .fromInt(2), .dst = .fromInt(4), .rel = .mentions },
    });

    const src_header = try store.readEdgeIndexHeader(store.edge_by_src_path);
    try std.testing.expect(src_header.hasKeyRuns());
    try std.testing.expect(src_header.hasKeyRunConstantOpposite());
    try std.testing.expect(!src_header.hasKeyRunRingOpposite());
    try std.testing.expect(!src_header.hasKeyRunLinearEdgeIds());
    try std.testing.expect(!src_header.hasKeyRunUniformEdgeIdStep());
    try std.testing.expectEqual(@as(u32, 2), src_header.key_run_count);
    try std.testing.expectEqual(@as(u16, 4), src_header.record_len);

    const expected_size = EdgeIndexHeader.encoded_len + 2 * storage_data_plane_support.edgeIndexKeyRunRecordLen(src_header) + 8 * src_header.record_len;
    try std.testing.expectEqual(@as(u64, expected_size), try store.fileSizeOrZero(store.edge_by_src_path));

    var by_src = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer by_src.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), by_src.items.len);
    try std.testing.expectEqual(@as(u64, 1), by_src.items[0].edge_id);
    try std.testing.expectEqual(@as(u64, 7), by_src.items[3].edge_id);
}

test "edge secondary key runs split same-key linear edge id subruns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "n1" },
        .{ .id = .fromInt(2), .kind = .file, .text = "n2" },
        .{ .id = .fromInt(3), .kind = .file, .text = "n3" },
        .{ .id = .fromInt(4), .kind = .file, .text = "n4" },
    });

    var edges = std.ArrayList(graph_mod.Edge).empty;
    defer edges.deinit(std.testing.allocator);
    try edges.ensureTotalCapacityPrecise(std.testing.allocator, 100);
    var id: u64 = 1;
    while (id <= 100) : (id += 1) {
        if (id == 99) {
            try edges.append(std.testing.allocator, .{ .id = .fromInt(id), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions });
            continue;
        }
        if (id == 100) {
            try edges.append(std.testing.allocator, .{ .id = .fromInt(id), .src = .fromInt(2), .dst = .fromInt(3), .rel = .mentions });
            continue;
        }
        const src = ((id - 1) % 4) + 1;
        const dst = (id % 4) + 1;
        try edges.append(std.testing.allocator, .{ .id = .fromInt(id), .src = .fromInt(src), .dst = .fromInt(dst), .rel = .mentions });
    }
    try store.appendEdgesBatch(edges.items);

    const src_header = try store.readEdgeIndexHeader(store.edge_by_src_path);
    const dst_header = try store.readEdgeIndexHeader(store.edge_by_dst_path);
    try std.testing.expect(src_header.hasKeyRuns());
    try std.testing.expect(dst_header.hasKeyRuns());
    try std.testing.expect(src_header.hasKeyRunConstantOpposite());
    try std.testing.expect(dst_header.hasKeyRunConstantOpposite());
    try std.testing.expect(src_header.hasKeyRunRingOpposite());
    try std.testing.expect(dst_header.hasKeyRunRingOpposite());
    try std.testing.expectEqual(@as(u64, 4), src_header.key_run_opposite_mod);
    try std.testing.expectEqual(@as(u64, 4), dst_header.key_run_opposite_mod);
    try std.testing.expect(src_header.hasKeyRunLinearEdgeIds());
    try std.testing.expect(dst_header.hasKeyRunLinearEdgeIds());
    try std.testing.expect(src_header.hasKeyRunUniformEdgeIdStep());
    try std.testing.expect(dst_header.hasKeyRunUniformEdgeIdStep());
    try std.testing.expectEqual(@as(u64, 4), src_header.key_run_edge_id_step);
    try std.testing.expectEqual(@as(u64, 4), dst_header.key_run_edge_id_step);
    try std.testing.expect(src_header.hasKeyRunDenseSpan());
    try std.testing.expectEqual(@as(u32, 6), src_header.key_run_count);
    try std.testing.expectEqual(@as(u32, 6), dst_header.key_run_count);
    try std.testing.expectEqual(@as(u16, 0), src_header.record_len);
    try std.testing.expectEqual(@as(u16, 0), dst_header.record_len);

    try std.testing.expectEqual(try storage_data_plane_support.edgeIndexFileSizeForHeader(src_header), try store.fileSizeOrZero(store.edge_by_src_path));
    try std.testing.expectEqual(try storage_data_plane_support.edgeIndexFileSizeForHeader(dst_header), try store.fileSizeOrZero(store.edge_by_dst_path));

    var by_src = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer by_src.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 26), by_src.items.len);
    try std.testing.expectEqual(@as(u64, 1), by_src.items[0].edge_id);
    try std.testing.expectEqual(@as(u64, 97), by_src.items[24].edge_id);
    try std.testing.expectEqual(@as(u64, 99), by_src.items[25].edge_id);

    var by_dst = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .dst, .fromInt(3));
    defer by_dst.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 26), by_dst.items.len);
    try std.testing.expectEqual(@as(u64, 2), by_dst.items[0].edge_id);
    try std.testing.expectEqual(@as(u64, 98), by_dst.items[24].edge_id);
    try std.testing.expectEqual(@as(u64, 100), by_dst.items[25].edge_id);
}

test "edge secondary key runs reject overlapping same-key linear subruns" {
    const header = EdgeIndexHeader
        .withShape(.src, 4, 0, 0, false, true, true, null)
        .withKeyRuns(2, true, true);
    const current = storage_data_plane_support.EdgeIndexKeyRunRecord{
        .key = 1,
        .start = 0,
        .opposite = 2,
        .edge_id_base = 10,
        .edge_id_step = 5,
    };
    try storage_data_plane_support.validateAdjacentEdgeIndexKeyRuns(header, current, .{
        .key = 1,
        .start = 3,
        .opposite = 2,
        .edge_id_base = 21,
        .edge_id_step = 0,
    });
    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.validateAdjacentEdgeIndexKeyRuns(header, current, .{
        .key = 1,
        .start = 3,
        .opposite = 2,
        .edge_id_base = 20,
        .edge_id_step = 0,
    }));
}

test "edge batch append handles realistic fixture tail with compact key runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer nodes.deinit(std.testing.allocator);
    var node_id: u64 = 1;
    while (node_id <= 10) : (node_id += 1) {
        var text_buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "n{}", .{node_id});
        try nodes.append(std.testing.allocator, .{ .id = .fromInt(node_id), .kind = .file, .text = text });
    }
    try store.appendNodesBatch(nodes.items);

    var edges = std.ArrayList(graph_mod.Edge).empty;
    defer edges.deinit(std.testing.allocator);
    var edge_id: u64 = 1;
    while (edge_id <= 50) : (edge_id += 1) {
        if (edge_id == 49) {
            try edges.append(std.testing.allocator, .{ .id = .fromInt(edge_id), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(2) });
            continue;
        }
        if (edge_id == 50) {
            try edges.append(std.testing.allocator, .{ .id = .fromInt(edge_id), .src = .fromInt(2), .rel = .depends_on, .dst = .fromInt(3) });
            continue;
        }
        const src = ((edge_id - 1) % 10) + 1;
        const dst = (edge_id % 10) + 1;
        try edges.append(std.testing.allocator, .{ .id = .fromInt(edge_id), .src = .fromInt(src), .rel = .mentions, .dst = .fromInt(dst) });
    }
    try store.appendEdgesBatch(edges.items);

    const src_header = try store.readEdgeIndexHeader(store.edge_by_src_path);
    try std.testing.expect(src_header.hasKeyRuns());
    try std.testing.expectEqual(@as(u64, 50), src_header.edge_count);
    var outgoing = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer outgoing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), outgoing.items.len);
}

test "edge indexes keep u64 endpoints when node ids exceed u32" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const high_node_id: u64 = @as(u64, std.math.maxInt(u32)) + 1;
    const record = EdgeIndexRecord{
        .src = high_node_id,
        .dst = 2,
        .edge_id = 1,
        .rel = @intFromEnum(core.RelKind.mentions),
    };
    try store.writeEdgeIndex(store.edge_by_id_path, &.{record});

    const header = try store.readEdgeIndexHeader(store.edge_by_id_path);
    try std.testing.expect(header.hasDenseId());
    try std.testing.expect(header.hasDerivedRel());
    try std.testing.expect(!header.hasU32NodeIds());
    try std.testing.expectEqual(@as(u16, EdgeIndexRecord.dense_id_derived_rel_encoded_len), header.record_len);
    try std.testing.expectEqual(@as(u64, EdgeIndexHeader.encoded_len + EdgeIndexRecord.dense_id_derived_rel_encoded_len), try store.fileSizeOrZero(store.edge_by_id_path));

    var by_id = try store.readAllEdgeIndexRecords(std.testing.allocator, store.edge_by_id_path, .id);
    defer by_id.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), by_id.items.len);
    try std.testing.expectEqual(high_node_id, by_id.items[0].src);
}

test "edge indexes keep u64 edge ids when edge ids exceed u32" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const high_edge_id: u64 = @as(u64, std.math.maxInt(u32)) + 1;
    const record = EdgeIndexRecord{
        .src = 1,
        .dst = 2,
        .edge_id = high_edge_id,
        .rel = @intFromEnum(core.RelKind.mentions),
    };
    try store.writeEdgeIndex(store.edge_by_src_path, &.{record});

    const header = try store.readEdgeIndexHeader(store.edge_by_src_path);
    try std.testing.expect(!header.hasDenseId());
    try std.testing.expect(header.hasDerivedRel());
    try std.testing.expect(header.hasU32NodeIds());
    try std.testing.expect(!header.hasU32EdgeIds());
    try std.testing.expect(!header.hasKeyRuns());
    try std.testing.expect(!header.hasKeyRunConstantOpposite());
    try std.testing.expect(!header.hasKeyRunLinearEdgeIds());
    try std.testing.expectEqual(@as(u16, 16), header.record_len);
    try std.testing.expectEqual(try storage_data_plane_support.edgeIndexFileSizeForHeader(header), try store.fileSizeOrZero(store.edge_by_src_path));

    var by_src = try store.readAllEdgeIndexRecords(std.testing.allocator, store.edge_by_src_path, .src);
    defer by_src.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), by_src.items.len);
    try std.testing.expectEqual(high_edge_id, by_src.items[0].edge_id);
}

test "store batch appends edges with stream-merged sorted index maintenance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "b.zig" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .file, .text = "c.zig" });

    const before_edges = try store.eventByteCount();
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(2), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(3), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
    });
    const expected_batch_bytes =
        3 * storage_data_plane_support.BinaryRecordHeader.encoded_len +
        storage_data_plane_support.binary_edge_batch_compact_fixed_header_len +
        3 * storage_data_plane_support.binary_edge_batch_compact_u32_row_len;
    try std.testing.expectEqual(before_edges + expected_batch_bytes, try store.eventByteCount());

    const stats_out = try store.stats();
    try std.testing.expectEqual(@as(usize, 3), stats_out.nodes);
    try std.testing.expectEqual(@as(usize, 3), stats_out.edges);
    const meta = try store.readIndexMeta();
    try std.testing.expectEqual(@as(u64, 3), meta.edges);
    try std.testing.expectEqual(try store.eventByteCount(), meta.event_bytes);
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_id_path, .id, 3));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_src_path, .src, 3));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_dst_path, .dst, 3));
    try std.testing.expect(try store.edgeIndexesConsistent(3));
    try std.testing.expect(try store.edgeIndexesMatchMeta(meta));

    var outgoing = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer outgoing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), outgoing.items.len);
    try std.testing.expectEqual(@as(u64, 1), outgoing.items[0].edge_id);
    try std.testing.expectEqual(@as(u64, 3), outgoing.items[1].edge_id);
}

test "edge batch compact endpoint lanes fall back to u64 for high node ids" {
    const high_node_id = @as(u64, std.math.maxInt(u32)) + 1;
    const edges = [_]graph_mod.Edge{
        .{ .id = .fromInt(1), .src = .fromInt(high_node_id), .dst = .fromInt(2), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(high_node_id), .dst = .fromInt(3), .rel = .mentions },
    };
    const shape = storage_data_plane_support.binaryEdgeBatchDenseDerivedRelShape(&edges) orelse return error.InvalidRecord;
    try std.testing.expect(!shape.compact_node_ids);
    try std.testing.expectEqual(
        @as(u32, storage_data_plane_support.binary_edge_batch_compact_fixed_header_len + 2 * storage_data_plane_support.binary_edge_batch_compact_row_len),
        try storage_data_plane_support.binaryEdgeBatchPayloadLen(edges.len, shape),
    );

    var payload: [storage_data_plane_support.binary_edge_batch_compact_fixed_header_len + 2 * storage_data_plane_support.binary_edge_batch_compact_row_len]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 2, .little);
    std.mem.writeInt(u16, payload[4..6], storage_data_plane_support.binary_edge_batch_compact_flags, .little);
    std.mem.writeInt(u16, payload[6..8], @intFromEnum(core.RelKind.mentions), .little);
    std.mem.writeInt(u64, payload[8..16], 1, .little);
    payload[16] = 0;
    std.mem.writeInt(u64, payload[17..][0..8], high_node_id, .little);
    std.mem.writeInt(u64, payload[25..][0..8], 2, .little);
    std.mem.writeInt(u64, payload[33..][0..8], high_node_id, .little);
    std.mem.writeInt(u64, payload[41..][0..8], 3, .little);

    const batch = try storage_data_plane_support.validateBinaryEdgeBatchHeader(&payload);
    try std.testing.expect(!batch.compact_node_ids);
    const first = try storage_data_plane_support.validateBinaryEdgeBatchEdge(&payload, batch, 0);
    try std.testing.expectEqual(high_node_id, first.src);
    try std.testing.expectEqual(@as(u64, 2), first.dst);
}

test "edge batch compact derives linear endpoint runs" {
    const edges = [_]graph_mod.Edge{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(2), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(3), .src = .fromInt(3), .dst = .fromInt(1), .rel = .mentions },
        .{ .id = .fromInt(4), .src = .fromInt(4), .dst = .fromInt(5), .rel = .mentions },
        .{ .id = .fromInt(5), .src = .fromInt(5), .dst = .fromInt(6), .rel = .mentions },
        .{ .id = .fromInt(6), .src = .fromInt(6), .dst = .fromInt(7), .rel = .mentions },
        .{ .id = .fromInt(7), .src = .fromInt(7), .dst = .fromInt(8), .rel = .mentions },
        .{ .id = .fromInt(8), .src = .fromInt(8), .dst = .fromInt(9), .rel = .mentions },
    };
    const shape = storage_data_plane_support.binaryEdgeBatchDenseDerivedRelShape(&edges) orelse return error.InvalidRecord;
    try std.testing.expect(shape.compact_node_ids);
    try std.testing.expect(shape.linear_endpoint_runs);
    try std.testing.expectEqual(@as(u32, 3), shape.endpoint_run_count);
    const expected_payload_len = storage_data_plane_support.binary_edge_batch_compact_fixed_header_len + 4 + 3 * storage_data_plane_support.binary_edge_batch_endpoint_run_len;
    try std.testing.expectEqual(@as(u32, expected_payload_len), try storage_data_plane_support.binaryEdgeBatchPayloadLen(edges.len, shape));

    var payload: [expected_payload_len]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 8, .little);
    std.mem.writeInt(u16, payload[4..6], storage_data_plane_support.binary_edge_batch_compact_flags | storage_data_plane_support.binary_edge_batch_flag_u32_node_ids | storage_data_plane_support.binary_edge_batch_flag_linear_endpoints, .little);
    std.mem.writeInt(u16, payload[6..8], @intFromEnum(core.RelKind.mentions), .little);
    std.mem.writeInt(u64, payload[8..16], 1, .little);
    payload[16] = 0;
    std.mem.writeInt(u32, payload[17..][0..4], 3, .little);
    std.mem.writeInt(u32, payload[21..][0..4], 1, .little);
    std.mem.writeInt(u32, payload[25..][0..4], 0, .little);
    std.mem.writeInt(u32, payload[29..][0..4], 2, .little);
    std.mem.writeInt(u32, payload[33..][0..4], 3, .little);
    std.mem.writeInt(u32, payload[37..][0..4], 2, .little);
    std.mem.writeInt(u32, payload[41..][0..4], 1, .little);
    std.mem.writeInt(u32, payload[45..][0..4], 4, .little);
    std.mem.writeInt(u32, payload[49..][0..4], 3, .little);
    std.mem.writeInt(u32, payload[53..][0..4], 5, .little);

    const batch = try storage_data_plane_support.validateBinaryEdgeBatchHeader(&payload);
    try std.testing.expect(batch.compact_node_ids);
    try std.testing.expect(batch.linear_endpoint_runs);
    try std.testing.expectEqual(@as(u32, 3), batch.endpoint_run_count);
    try std.testing.expectEqual(@as(usize, 0), batch.row_len);
    try std.testing.expectEqual(@as(usize, payload.len), batch.header_len);
    try storage_data_plane_support.validateBinaryEdgeBatchPayload(&payload);

    const first = try storage_data_plane_support.validateBinaryEdgeBatchEdge(&payload, batch, 0);
    try std.testing.expectEqual(@as(u64, 1), first.id);
    try std.testing.expectEqual(@as(u64, 1), first.src);
    try std.testing.expectEqual(@as(u64, 2), first.dst);
    try std.testing.expectEqual(core.RelKind.mentions, first.rel);
    const wrapped = try storage_data_plane_support.validateBinaryEdgeBatchEdge(&payload, batch, 2);
    try std.testing.expectEqual(@as(u64, 3), wrapped.id);
    try std.testing.expectEqual(@as(u64, 3), wrapped.src);
    try std.testing.expectEqual(@as(u64, 1), wrapped.dst);
    const last = try storage_data_plane_support.validateBinaryEdgeBatchEdge(&payload, batch, 7);
    try std.testing.expectEqual(@as(u64, 8), last.id);
    try std.testing.expectEqual(@as(u64, 8), last.src);
    try std.testing.expectEqual(@as(u64, 9), last.dst);
}

test "edge batch compact linear endpoint runs reject synthesized u32 overflow" {
    var payload: [storage_data_plane_support.binary_edge_batch_compact_fixed_header_len + 4 + storage_data_plane_support.binary_edge_batch_endpoint_run_len]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 2, .little);
    std.mem.writeInt(u16, payload[4..6], storage_data_plane_support.binary_edge_batch_compact_flags | storage_data_plane_support.binary_edge_batch_flag_u32_node_ids | storage_data_plane_support.binary_edge_batch_flag_linear_endpoints, .little);
    std.mem.writeInt(u16, payload[6..8], @intFromEnum(core.RelKind.mentions), .little);
    std.mem.writeInt(u64, payload[8..16], 1, .little);
    payload[16] = 0;
    std.mem.writeInt(u32, payload[17..][0..4], 1, .little);
    std.mem.writeInt(u32, payload[21..][0..4], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, payload[25..][0..4], 0, .little);
    std.mem.writeInt(u32, payload[29..][0..4], 1, .little);

    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.validateBinaryEdgeBatchHeader(&payload));
}

test "store edge batch event log derives linear endpoint runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "n1" },
        .{ .id = .fromInt(2), .kind = .file, .text = "n2" },
        .{ .id = .fromInt(3), .kind = .file, .text = "n3" },
        .{ .id = .fromInt(4), .kind = .file, .text = "n4" },
        .{ .id = .fromInt(5), .kind = .file, .text = "n5" },
        .{ .id = .fromInt(6), .kind = .file, .text = "n6" },
        .{ .id = .fromInt(7), .kind = .file, .text = "n7" },
        .{ .id = .fromInt(8), .kind = .file, .text = "n8" },
        .{ .id = .fromInt(9), .kind = .file, .text = "n9" },
    });

    const before_edges = try store.eventByteCount();
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions },
        .{ .id = .fromInt(2), .src = .fromInt(2), .dst = .fromInt(3), .rel = .mentions },
        .{ .id = .fromInt(3), .src = .fromInt(3), .dst = .fromInt(1), .rel = .mentions },
        .{ .id = .fromInt(4), .src = .fromInt(4), .dst = .fromInt(5), .rel = .mentions },
        .{ .id = .fromInt(5), .src = .fromInt(5), .dst = .fromInt(6), .rel = .mentions },
        .{ .id = .fromInt(6), .src = .fromInt(6), .dst = .fromInt(7), .rel = .mentions },
        .{ .id = .fromInt(7), .src = .fromInt(7), .dst = .fromInt(8), .rel = .mentions },
        .{ .id = .fromInt(8), .src = .fromInt(8), .dst = .fromInt(9), .rel = .mentions },
    });

    const endpoint_run_batch_bytes =
        3 * storage_data_plane_support.BinaryRecordHeader.encoded_len +
        storage_data_plane_support.binary_edge_batch_compact_fixed_header_len +
        4 +
        3 * storage_data_plane_support.binary_edge_batch_endpoint_run_len;
    try std.testing.expectEqual(before_edges + endpoint_run_batch_bytes, try store.eventByteCount());
    const rowful_batch_bytes =
        3 * storage_data_plane_support.BinaryRecordHeader.encoded_len +
        storage_data_plane_support.binary_edge_batch_compact_fixed_header_len +
        8 * storage_data_plane_support.binary_edge_batch_compact_u32_row_len;
    try std.testing.expect(endpoint_run_batch_bytes < rowful_batch_bytes);

    const stats_out = try store.stats();
    try std.testing.expectEqual(@as(usize, 9), stats_out.nodes);
    try std.testing.expectEqual(@as(usize, 8), stats_out.edges);
    const meta = try store.readIndexMeta();
    try std.testing.expectEqual(@as(u64, 8), meta.edges);
    try std.testing.expectEqual(try store.eventByteCount(), meta.event_bytes);
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_id_path, .id, 8));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_src_path, .src, 8));
    try std.testing.expect(try store.edgeIndexValid(store.edge_by_dst_path, .dst, 8));
}

test "store rejects truncated binary event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bad = std.ArrayList(u8).empty;
    defer bad.deinit(std.testing.allocator);
    try storage_data_plane_support.appendBinaryHeader(&bad, std.testing.allocator, .node, 14, storage_data_plane_support.binaryPayloadChecksum("too short"));
    try bad.appendSlice(std.testing.allocator, "too short");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bad.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store rejects binary event log with trailing garbage after valid record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&payload, std.testing.allocator, "src/main.zig".len);
    try payload.appendSlice(std.testing.allocator, "src/main.zig");
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, payload.items);
    try bytes.append(std.testing.allocator, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store rejects binary node records with empty node texts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&payload, std.testing.allocator, 0);
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, payload.items);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store rejects binary node records with overflowing declared text length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&payload, std.testing.allocator, std.math.maxInt(u32));
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, payload.items);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store rejects invalid binary enum and oversized payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bad_enum = std.ArrayList(u8).empty;
    defer bad_enum.deinit(std.testing.allocator);
    var bad_payload = std.ArrayList(u8).empty;
    defer bad_payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&bad_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&bad_payload, std.testing.allocator, std.math.maxInt(u16));
    try storage_data_plane_support.appendU32(&bad_payload, std.testing.allocator, 0);
    try storage_data_plane_support.appendBinaryRecord(&bad_enum, std.testing.allocator, .node, bad_payload.items);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bad_enum.items,
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());

    var oversized = std.ArrayList(u8).empty;
    defer oversized.deinit(std.testing.allocator);
    try oversized.appendSlice(std.testing.allocator, &storage_data_plane_support.BinaryRecordHeader.magic);
    try oversized.append(std.testing.allocator, storage_data_plane_support.BinaryRecordHeader.current_version);
    try oversized.append(std.testing.allocator, @intFromEnum(storage_data_plane_support.BinaryRecordKind.node));
    try storage_data_plane_support.appendU32(&oversized, std.testing.allocator, storage_data_plane_support.BinaryRecordHeader.max_payload_len + 1);
    try storage_data_plane_support.appendU64(&oversized, std.testing.allocator, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = oversized.items,
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store rejects truncated max-size binary payload before allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var truncated = std.ArrayList(u8).empty;
    defer truncated.deinit(std.testing.allocator);
    try storage_data_plane_support.appendBinaryHeader(&truncated, std.testing.allocator, .node, storage_data_plane_support.BinaryRecordHeader.max_payload_len, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = truncated.items,
        .flags = .{ .truncate = true },
    });

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failing_store = store;
    failing_store.allocator = failing.allocator();
    try std.testing.expectError(error.InvalidRecord, failing_store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, failing_store.stats());
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "store rejects binary payload checksum mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&payload, std.testing.allocator, "src/main.zig".len);
    try payload.appendSlice(std.testing.allocator, "src/main.zig");
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, payload.items);
    bytes.items[storage_data_plane_support.BinaryRecordHeader.encoded_len + 14] ^= 1;

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store rejects old binary record headers without checksum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&payload, std.testing.allocator, "legacy.zig".len);
    try payload.appendSlice(std.testing.allocator, "legacy.zig");

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, &storage_data_plane_support.BinaryRecordHeader.magic);
    try bytes.append(std.testing.allocator, 1);
    try bytes.append(std.testing.allocator, @intFromEnum(storage_data_plane_support.BinaryRecordKind.node));
    try storage_data_plane_support.appendU32(&bytes, std.testing.allocator, @intCast(payload.items.len));
    try bytes.appendSlice(std.testing.allocator, payload.items);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store refuses to write oversized binary record headers" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.RecordTooLarge,
        storage_data_plane_support.appendBinaryHeader(&bytes, std.testing.allocator, .node, storage_data_plane_support.BinaryRecordHeader.max_payload_len + 1, 0),
    );
}

test "store binary log offset advance rejects arithmetic overflow" {
    var offset: u64 = std.math.maxInt(u64) - storage_data_plane_support.BinaryRecordHeader.encoded_len + 1;
    try std.testing.expectError(error.InvalidRecord, Store.advanceBinaryOffset(&offset, storage_data_plane_support.BinaryRecordHeader.encoded_len));
    offset = 10;
    try Store.advanceBinaryOffset(&offset, storage_data_plane_support.BinaryRecordHeader.encoded_len);
    try std.testing.expectEqual(@as(u64, 10 + storage_data_plane_support.BinaryRecordHeader.encoded_len), offset);
}

test "store rejects duplicate persisted ids during replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var first_payload = std.ArrayList(u8).empty;
    defer first_payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&first_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&first_payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&first_payload, std.testing.allocator, "src/main.zig".len);
    try first_payload.appendSlice(std.testing.allocator, "src/main.zig");
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, first_payload.items);

    var duplicate_payload = std.ArrayList(u8).empty;
    defer duplicate_payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&duplicate_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&duplicate_payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&duplicate_payload, std.testing.allocator, "duplicate".len);
    try duplicate_payload.appendSlice(std.testing.allocator, "duplicate");
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, duplicate_payload.items);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store repair rejects duplicate node ids through compressed node id set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var first_payload = std.ArrayList(u8).empty;
    defer first_payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&first_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&first_payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&first_payload, std.testing.allocator, "src/main.zig".len);
    try first_payload.appendSlice(std.testing.allocator, "src/main.zig");
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, first_payload.items);

    var duplicate_payload = std.ArrayList(u8).empty;
    defer duplicate_payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&duplicate_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&duplicate_payload, std.testing.allocator, @intFromEnum(core.NodeKind.symbol));
    try storage_data_plane_support.appendU32(&duplicate_payload, std.testing.allocator, "duplicate".len);
    try duplicate_payload.appendSlice(std.testing.allocator, "duplicate");
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, duplicate_payload.items);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.repairPersistentIndexesFromLog());
}

test "store repair keeps sparse high edge id deletes through digest fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });

    const high_edge_id = storage_data_plane_support.repair_dense_edge_digest_max_id + 17;
    try store.appendEdge(.{ .id = .fromInt(high_edge_id), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try store.deleteEdge(.fromInt(high_edge_id));
    try store.repairPersistentIndexesFromLog();

    const stats_out = try store.stats();
    try std.testing.expectEqual(@as(usize, 2), stats_out.nodes);
    try std.testing.expectEqual(@as(usize, 0), stats_out.edges);
    const meta = try store.readIndexMeta();
    try std.testing.expectEqual(high_edge_id, meta.max_edge_id_seen);
    const tombstone_header = try store.readEdgeTombstoneIndexHeader();
    try std.testing.expectEqual(@as(u64, 1), tombstone_header.count);
}

test "store rejects binary edges with missing endpoints as invalid records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var node_payload = std.ArrayList(u8).empty;
    defer node_payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&node_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&node_payload, std.testing.allocator, @intFromEnum(core.NodeKind.file));
    try storage_data_plane_support.appendU32(&node_payload, std.testing.allocator, "src/main.zig".len);
    try node_payload.appendSlice(std.testing.allocator, "src/main.zig");
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .node, node_payload.items);

    var edge_payload = std.ArrayList(u8).empty;
    defer edge_payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&edge_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU64(&edge_payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&edge_payload, std.testing.allocator, @intFromEnum(core.RelKind.defines));
    try storage_data_plane_support.appendU64(&edge_payload, std.testing.allocator, 2);
    try storage_data_plane_support.appendBinaryRecord(&bytes, std.testing.allocator, .edge, edge_payload.items);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.events_bin_path,
        .data = bytes.items,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidRecord, store.loadGraph());
    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "fixed edge binary encoder matches generic event encoder" {
    const edge: graph_mod.Edge = .{ .id = .fromInt(7), .src = .fromInt(3), .dst = .fromInt(9), .rel = .mentions };

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, edge.id.toInt());
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, edge.src.toInt());
    try storage_data_plane_support.appendU16(&payload, std.testing.allocator, @intFromEnum(edge.rel));
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, edge.dst.toInt());
    var generic = std.ArrayList(u8).empty;
    defer generic.deinit(std.testing.allocator);
    try storage_data_plane_support.appendBinaryRecord(&generic, std.testing.allocator, .edge, payload.items);

    var fixed: [storage_data_plane_support.binary_edge_record_len]u8 = undefined;
    storage_data_plane_support.encodeBinaryEdgeRecord(&fixed, edge);
    try std.testing.expectEqualSlices(u8, generic.items, &fixed);

    const header = try storage_data_plane_support.BinaryRecordHeader.decode(fixed[0..storage_data_plane_support.BinaryRecordHeader.encoded_len]);
    try storage_data_plane_support.validateBinaryChecksum(header, fixed[storage_data_plane_support.BinaryRecordHeader.encoded_len..]);
    const parsed = try storage_data_plane_support.validateBinaryEdgePayload(fixed[storage_data_plane_support.BinaryRecordHeader.encoded_len..]);
    try std.testing.expectEqual(edge.id.toInt(), parsed.id);
    try std.testing.expectEqual(edge.src.toInt(), parsed.src);
    try std.testing.expectEqual(edge.dst.toInt(), parsed.dst);
    try std.testing.expectEqual(edge.rel, parsed.rel);
}

test "fixed node binary helpers match generic event encoder" {
    const node: graph_mod.Node = .{ .id = .fromInt(11), .kind = .task, .text = "src/node-batch.zig" };

    const span: storage_data_plane_support.TextSpan = .{ .offset = 123, .len = @intCast(node.text.len) };
    var payload: [storage_data_plane_support.binary_node_payload_len]u8 = undefined;
    _ = try storage_data_plane_support.encodeBinaryNodeFixedPayload(&payload, node, span);
    var generic = std.ArrayList(u8).empty;
    defer generic.deinit(std.testing.allocator);
    try storage_data_plane_support.appendBinaryRecord(&generic, std.testing.allocator, .node, &payload);

    var fixed_payload: [storage_data_plane_support.binary_node_payload_len]u8 = undefined;
    const payload_len = try storage_data_plane_support.encodeBinaryNodeFixedPayload(&fixed_payload, node, span);
    var fixed_header: [storage_data_plane_support.BinaryRecordHeader.encoded_len]u8 = undefined;
    storage_data_plane_support.encodeBinaryRecordHeader(&fixed_header, .node, payload_len, storage_data_plane_support.binaryPayloadChecksum(&fixed_payload));
    var fixed = std.ArrayList(u8).empty;
    defer fixed.deinit(std.testing.allocator);
    try fixed.appendSlice(std.testing.allocator, &fixed_header);
    try fixed.appendSlice(std.testing.allocator, &fixed_payload);

    try std.testing.expectEqualSlices(u8, generic.items, fixed.items);

    const header = try storage_data_plane_support.BinaryRecordHeader.decode(fixed.items[0..storage_data_plane_support.BinaryRecordHeader.encoded_len]);
    try storage_data_plane_support.validateBinaryChecksum(header, fixed.items[storage_data_plane_support.BinaryRecordHeader.encoded_len..]);
    const parsed = try storage_data_plane_support.validateBinaryNodePayload(fixed.items[storage_data_plane_support.BinaryRecordHeader.encoded_len..]);
    try std.testing.expectEqual(node.id.toInt(), parsed.id);
    try std.testing.expectEqual(node.kind, parsed.kind);
    try std.testing.expectEqual(span.offset, parsed.text_offset);
    try std.testing.expectEqual(span.len, parsed.text_len);
}

test "store rejects duplicate node append before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addNodeWithId(core.NodeId.fromInt(1), .file, "src/main.zig");
    try store.appendNode(graph.nodes.items[0]);
    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendNode(graph.nodes.items[0]));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store validates node indexes on append even when read validation is disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = false;
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });

    {
        var index_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{ .mode = .read_write });
        defer index_file.close(std.testing.io);
        var empty_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
        try NodeByIdRecord.empty().encode(&empty_bytes);
        try index_file.writePositionalAll(std.testing.io, &empty_bytes, try storage_data_plane_support.nodeByIdRecordOffset(1));
    }

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendNode(.{
        .id = .fromInt(1),
        .kind = .file,
        .text = "duplicate.zig",
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store rejects non-active node append before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.Unsupported, store.appendNode(.{
        .id = .fromInt(1),
        .kind = .file,
        .text = "deleted.zig",
        .status = .deleted,
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store allows zero-length node text and keeps indexes current" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try store.appendNode(.{
        .id = .fromInt(1),
        .kind = .file,
        .text = "",
    });
    try std.testing.expect((try store.fileSizeOrZero(store.events_bin_path)) > before);
    var loaded = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", loaded.text);
    try std.testing.expect(try store.persistentIndexesCurrent(try store.stats()));

    var graph = try store.loadGraph();
    defer graph.deinit();
    try std.testing.expectEqualStrings("", graph.getNode(.fromInt(1)).?.text);
}

test "store external key index supports append lookup and repair rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const first = try store.addNode(.document, "doc");
    try store.setNodeStringProperty(std.testing.allocator, first, "external_key", "md-doc:test");
    try std.testing.expectEqual(first, (try store.lookupNodeByExternalKey(std.testing.allocator, "md-doc:test", null)).?);
    try std.testing.expectEqual(first, (try store.lookupNodeByExternalKey(std.testing.allocator, "md-doc:test", .document)).?);
    try std.testing.expectEqual(@as(?core.NodeId, null), try store.lookupNodeByExternalKey(std.testing.allocator, "md-doc:test", .observation));
    try std.testing.expectEqual(@as(?core.NodeId, null), try store.lookupNodeByExternalKey(std.testing.allocator, "missing", null));

    std.Io.Dir.cwd().deleteFile(std.testing.io, store.external_key_index_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try std.testing.expectEqual(first, (try store.lookupNodeByExternalKey(std.testing.allocator, "md-doc:test", null)).?);

    const second = try store.addNode(.observation, "chunk");
    try store.setNodeStringProperty(std.testing.allocator, second, "external_key", "content:test");
    try std.testing.expectEqual(second, (try store.lookupNodeByExternalKey(std.testing.allocator, "content:test", .observation)).?);
}

test "property payload batch upsert replaces lifecycle fields with one publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const task_id = try store.addNode(.task, "batch lifecycle task");
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "open" } },
        .{ .owner = .{ .node = task_id }, .key = "claim_expires_ns", .value = .{ .uint = 0 } },
    });

    const result = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = task_id }, .key = "claimed_by", .value = .{ .string = "agent-one" } },
        .{ .owner = .{ .node = task_id }, .key = "claim_expires_ns", .value = .{ .uint = 99 } },
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "claimed" } },
    });
    try std.testing.expectEqual(@as(usize, 3), result.writes_applied);
    try std.testing.expectEqual(@as(usize, 2), result.entries_replaced);
    try std.testing.expectEqual(@as(usize, 1), result.payload_publish_count);

    const status = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("claimed", status);
    const holder = (try store.getNodeStringProperty(std.testing.allocator, task_id, "claimed_by")).?;
    defer std.testing.allocator.free(holder);
    try std.testing.expectEqualStrings("agent-one", holder);
    try std.testing.expectEqual(@as(?u64, 99), try store.getUintProperty(std.testing.allocator, .{ .node = task_id }, "claim_expires_ns"));

    try std.testing.expectError(error.InvalidRecord, store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "open" } },
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "failed" } },
    }));
    var delta_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{});
    const delta_size_after_rejected_batch = try store.regularFileSize(delta_file);
    delta_file.close(std.testing.io);
    const status_after_rejected_batch = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(status_after_rejected_batch);
    try std.testing.expectEqualStrings("claimed", status_after_rejected_batch);
    var delta_file_again = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{});
    defer delta_file_again.close(std.testing.io);
    try std.testing.expectEqual(delta_size_after_rejected_batch, try store.regularFileSize(delta_file_again));
}

test "empty property payload can be replaced from a bounded sorted stream once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "sorted property target");
    const Context = struct {
        node_id: core.NodeId,
        emitted: bool = false,

        fn next(raw_context: *anyopaque) anyerror!?SortedPropertyPayloadEntry {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            if (context.emitted) return null;
            context.emitted = true;
            return .{
                .owner = .{ .node = context.node_id },
                .key_hash = propertyKeyHashForLookup("status"),
                .value = .{ .string = "open" },
            };
        }
    };
    var context = Context{ .node_id = node_id };
    try std.testing.expectError(
        error.InvalidRecord,
        store.replaceEmptyPropertyPayloadFromSortedStream(0, &context, Context.next),
    );
    context.emitted = false;
    try store.replaceEmptyPropertyPayloadFromSortedStream(1, &context, Context.next);
    const status = (try store.getNodeStringProperty(std.testing.allocator, node_id, "status")).?;
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("open", status);

    context.emitted = false;
    try std.testing.expectError(
        error.InvalidRecord,
        store.replaceEmptyPropertyPayloadFromSortedStream(1, &context, Context.next),
    );
}

test "streamed property payload redo recovers between pair renames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const donor_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "donor" });
    defer std.testing.allocator.free(donor_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "target" });
    defer std.testing.allocator.free(target_path);

    const Context = struct {
        node_id: core.NodeId,
        emitted: bool = false,

        fn next(raw_context: *anyopaque) anyerror!?SortedPropertyPayloadEntry {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            if (context.emitted) return null;
            context.emitted = true;
            return .{
                .owner = .{ .node = context.node_id },
                .key_hash = propertyKeyHashForLookup("status"),
                .value = .{ .string = "claimed" },
            };
        }
    };

    var donor = try Store.init(std.testing.allocator, std.testing.io, donor_path);
    defer donor.deinit();
    try donor.createEmpty();
    const donor_node = try donor.addNode(.task, "streamed redo donor");
    var context = Context{ .node_id = donor_node };
    try donor.replaceEmptyPropertyPayloadFromSortedStream(1, &context, Context.next);

    var target = try Store.init(std.testing.allocator, std.testing.io, target_path);
    var target_open = true;
    defer if (target_open) target.deinit();
    try target.createEmpty();
    const target_node = try target.addNode(.task, "streamed redo target");
    try std.testing.expectEqual(donor_node, target_node);

    const index_stage = try target.tmpPathFor(target.property_payload_index_path);
    defer std.testing.allocator.free(index_stage);
    const values_stage = try target.tmpPathFor(target.property_payload_values_path);
    defer std.testing.allocator.free(values_stage);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), donor.property_payload_index_path, std.Io.Dir.cwd(), index_stage, std.testing.io, .{});
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), donor.property_payload_values_path, std.Io.Dir.cwd(), values_stage, std.testing.io, .{});
    try storage_data_plane_support.property_payload_transaction.Testing.writeBaseRedo(target, index_stage, values_stage);

    // Simulate power loss after the streamed values file was published but
    // before the matching index rename and redo cleanup.
    try target.renameReplace(values_stage, target.property_payload_values_path);
    target.deinit();
    target_open = false;

    var reopened = try Store.open(std.testing.allocator, std.testing.io, target_path);
    defer reopened.deinit();
    const status = (try reopened.getNodeStringProperty(std.testing.allocator, target_node, "status")).?;
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("claimed", status);
    const journal_path = try storage_data_plane_support.property_payload_transaction.Testing.baseRedoPath(reopened);
    defer std.testing.allocator.free(journal_path);
    try std.testing.expect(!try reopened.pathExists(journal_path));
}

test "property payload delta is append only latest wins and survives reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    var store_open = true;
    defer if (store_open) store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "delta task");
    const other_id = try store.addNode(.observation, "delta other");
    const edge_id = try store.nextEdgeId();
    try store.appendEdgeIndexed(.{ .id = edge_id, .src = task_id, .rel = .references, .dst = other_id });
    try store.appendPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "open" } },
        .{ .owner = .{ .node = task_id }, .key = "name", .value = .{ .string = "base name" } },
    });

    var base_index_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_index_path, .{});
    const base_index_bytes = try store.regularFileSize(base_index_file);
    base_index_file.close(std.testing.io);
    var base_values_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_values_path, .{});
    const base_values_bytes = try store.regularFileSize(base_values_file);
    base_values_file.close(std.testing.io);

    const first = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "claimed" } },
        .{ .owner = .{ .node = task_id }, .key = "name", .value = .{ .string = "delta name" } },
        .{ .owner = .{ .node = task_id }, .key = "claim_expires_ns", .value = .{ .uint = 99 } },
        .{ .owner = .{ .edge = edge_id }, .key = "created_by", .value = .{ .string = "agent" } },
    });
    try std.testing.expectEqual(@as(usize, 2), first.entries_replaced);
    var delta_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{});
    const first_delta_bytes = try store.regularFileSize(delta_file);
    delta_file.close(std.testing.io);

    const second = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = task_id },
        .key = "name",
        .value = .{ .string = "latest name" },
    }});
    try std.testing.expectEqual(@as(usize, 1), second.entries_replaced);
    var delta_file_after = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{});
    const second_delta_bytes = try store.regularFileSize(delta_file_after);
    delta_file_after.close(std.testing.io);
    try std.testing.expect(second_delta_bytes > first_delta_bytes);
    try std.testing.expect(second_delta_bytes - first_delta_bytes < 256);

    var current_index_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_index_path, .{});
    try std.testing.expectEqual(base_index_bytes, try store.regularFileSize(current_index_file));
    var current_values_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_values_path, .{});
    try std.testing.expectEqual(base_values_bytes, try store.regularFileSize(current_values_file));

    const status = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("claimed", status);
    const name = (try store.getNodeStringProperty(std.testing.allocator, task_id, "name")).?;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("latest name", name);
    try std.testing.expectEqual(@as(?u64, 99), try store.getUintProperty(std.testing.allocator, .{ .node = task_id }, "claim_expires_ns"));
    const created_by = (try store.getEdgeStringProperty(std.testing.allocator, edge_id, "created_by")).?;
    defer std.testing.allocator.free(created_by);
    try std.testing.expectEqualStrings("agent", created_by);

    var snapshot = try store.loadSearchableNodeMetadataSnapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    var name_matches: usize = 0;
    for (snapshot.entries) |entry| {
        const owner_matches = switch (entry.owner) {
            .node => |node_id| node_id == task_id,
            .edge => false,
        };
        if (!owner_matches or entry.key_hash != storage_data_plane_support.nodePropertyKeyHash("name")) continue;
        name_matches += 1;
        try std.testing.expectEqualStrings("latest name", entry.string_value);
    }
    try std.testing.expectEqual(@as(usize, 1), name_matches);

    var bounded_snapshot = try store.loadSearchableNodeMetadataSnapshotLimited(std.testing.allocator, "latest name".len);
    bounded_snapshot.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.SearchableMetadataBudgetExceeded,
        store.loadSearchableNodeMetadataSnapshotLimited(std.testing.allocator, "latest name".len - 1),
    );

    var edge_snapshot = try store.loadEdgePropertySnapshotForEdgeIds(
        std.testing.allocator,
        &.{edge_id},
        &.{"created_by"},
    );
    defer edge_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), edge_snapshot.entries.len);
    try std.testing.expectEqual(edge_id, edge_snapshot.entries[0].owner.edge);
    try std.testing.expectEqualStrings("agent", edge_snapshot.entries[0].string_value);

    current_values_file.close(std.testing.io);
    current_index_file.close(std.testing.io);
    store.deinit();
    store_open = false;
    var reopened = try Store.open(std.testing.allocator, std.testing.io, store_path);
    defer reopened.deinit();
    const reopened_name = (try reopened.getNodeStringProperty(std.testing.allocator, task_id, "name")).?;
    defer std.testing.allocator.free(reopened_name);
    try std.testing.expectEqualStrings("latest name", reopened_name);
    try std.testing.expectEqual(@as(?u64, 99), try reopened.getUintProperty(std.testing.allocator, .{ .node = task_id }, "claim_expires_ns"));
}

test "property payload delta frames reject duplicate owner keys and impossible counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "duplicate delta owner key");

    try std.testing.expectError(error.InvalidRecord, storage_data_plane_support.property_payload_transaction.Testing.encodeDelta(std.testing.allocator, 1, &.{
        .{ .owner = .{ .node = task_id }, .key = "created_at", .value = .{ .uint = 1 } },
        .{ .owner = .{ .node = task_id }, .key = "created_at", .value = .{ .uint = 2 } },
    }));

    const frame = try storage_data_plane_support.property_payload_transaction.Testing.encodeDelta(std.testing.allocator, 1, &.{
        .{ .owner = .{ .node = task_id }, .key = "created_at", .value = .{ .uint = 1 } },
        .{ .owner = .{ .node = task_id }, .key = "updated_at", .value = .{ .uint = 2 } },
    });
    defer std.testing.allocator.free(frame);
    const payload = frame[storage_data_plane_support.property_payload_delta_header_len..];
    const first_key = "created_at";
    const second_entry_offset = storage_data_plane_support.property_payload_delta_entry_len + first_key.len;
    const second_raw = payload[second_entry_offset..][0..storage_data_plane_support.property_payload_delta_entry_len];
    storage_data_plane_support.writeU64(second_raw[16..24], storage_data_plane_support.nodePropertyKeyHash(first_key));
    @memcpy(payload[second_entry_offset + storage_data_plane_support.property_payload_delta_entry_len ..], first_key);
    var header_bytes: [storage_data_plane_support.property_payload_delta_header_len]u8 = undefined;
    @memcpy(&header_bytes, frame[0..storage_data_plane_support.property_payload_delta_header_len]);
    var header = try storage_data_plane_support.PropertyPayloadDeltaHeader.decode(&header_bytes);
    header.payload_digest = std.hash.Wyhash.hash(storage_data_plane_support.property_payload_delta_digest_seed, payload);
    try header.encode(&header_bytes);
    @memcpy(frame[0..storage_data_plane_support.property_payload_delta_header_len], &header_bytes);
    try std.testing.expectError(
        error.InvalidRecord,
        Store.parsePropertyPayloadDeltaPayload(std.testing.allocator, header, payload, .none),
    );

    var impossible = header;
    impossible.write_count = std.math.maxInt(u32);
    var no_alloc_scratch: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&no_alloc_scratch);
    try std.testing.expectError(
        error.InvalidRecord,
        Store.parsePropertyPayloadDeltaPayload(fixed.allocator(), impossible, payload, .none),
    );
}

test "property layer scan preserves legacy base and delta precedence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "layered properties");

    var legacy = std.ArrayList(storage_data_plane_support.NodePropertyIndexEntry).empty;
    defer {
        storage_data_plane_support.deinitNodePropertyIndexEntries(legacy.items, std.testing.allocator);
        legacy.deinit(std.testing.allocator);
    }
    try storage_data_plane_support.appendNodePropertyRecordForValue(&legacy, std.testing.allocator, task_id, "summary", "legacy");
    try store.writeNodePropertyOverlay(legacy.items);
    try store.appendPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = task_id },
        .key = "summary",
        .value = .{ .string = "base" },
    }});
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = task_id },
        .key = "summary",
        .value = .{ .string = "delta-one" },
    }});
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = task_id },
        .key = "summary",
        .value = .{ .string = "delta-two" },
    }});

    const Capture = struct {
        const Seen = struct { version: u64, value: []u8 };
        allocator: std.mem.Allocator,
        owner: core.NodeId,
        entries: std.ArrayList(Seen) = .empty,

        fn deinit(self: *@This()) void {
            for (self.entries.items) |entry| self.allocator.free(entry.value);
            self.entries.deinit(self.allocator);
        }

        fn visit(context: *anyopaque, entry: PropertySnapshotLayerEntry) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const node_id = switch (entry.owner) {
                .node => |id| id,
                .edge => return,
            };
            if (node_id != self.owner or entry.key_hash != storage_data_plane_support.nodePropertyKeyHash("summary")) return;
            if (entry.value_kind != .string) return error.InvalidRecord;
            try self.entries.append(self.allocator, .{
                .version = entry.version,
                .value = try self.allocator.dupe(u8, entry.string_value),
            });
        }
    };
    var capture = Capture{ .allocator = std.testing.allocator, .owner = task_id };
    defer capture.deinit();
    try store.scanPropertySnapshotLayers(std.testing.allocator, &capture, Capture.visit);

    try std.testing.expectEqual(@as(usize, 4), capture.entries.items.len);
    try std.testing.expectEqual(storage_data_plane_support.property_snapshot_legacy_version, capture.entries.items[0].version);
    try std.testing.expectEqual(storage_data_plane_support.property_snapshot_base_version, capture.entries.items[1].version);
    try std.testing.expectEqual(storage_data_plane_support.property_snapshot_delta_version_base, capture.entries.items[2].version);
    try std.testing.expectEqual(storage_data_plane_support.property_snapshot_delta_version_base + 1, capture.entries.items[3].version);
    try std.testing.expectEqualStrings("legacy", capture.entries.items[0].value);
    try std.testing.expectEqualStrings("base", capture.entries.items[1].value);
    try std.testing.expectEqualStrings("delta-one", capture.entries.items[2].value);
    try std.testing.expectEqualStrings("delta-two", capture.entries.items[3].value);
}

test "property payload delta compaction is idempotent and crash-window replay safe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    var store_open = true;
    defer if (store_open) store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "compact task properties");
    try store.appendPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = task_id },
        .key = "status",
        .value = .{ .string = "open" },
    }});
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "claimed" } },
        .{ .owner = .{ .node = task_id }, .key = "claimed_by", .value = .{ .string = "agent-a" } },
        .{ .owner = .{ .node = task_id }, .key = "claim_expires_ns", .value = .{ .uint = 99 } },
    });
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = task_id },
        .key = "status",
        .value = .{ .string = "completed" },
    }});

    // Simulate the safe half of the compaction publication: the new base has
    // landed, but the old delta was not yet unlinked when the process died.
    var merged = try store.readPropertyPayloadEntriesOrEmpty(std.testing.allocator);
    defer {
        storage_data_plane_support.deinitPropertyPayloadIndexEntries(merged.items, std.testing.allocator);
        merged.deinit(std.testing.allocator);
    }
    try store.writePropertyPayload(merged.items);
    store.deinit();
    store_open = false;

    store = try Store.open(std.testing.allocator, std.testing.io, store_path);
    store_open = true;
    const replayed_status = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(replayed_status);
    try std.testing.expectEqualStrings("completed", replayed_status);
    const compacted = try store.compactPropertyPayloadDelta(std.testing.allocator);
    try std.testing.expect(compacted.compacted);
    try std.testing.expectEqual(@as(u64, 2), compacted.delta_frames);
    try std.testing.expect(compacted.delta_bytes > 0);
    try std.testing.expectEqual(@as(u64, 3), compacted.live_entries);
    try std.testing.expect(!try store.fileExists(store.property_payload_delta_path));

    const no_op = try store.compactPropertyPayloadDelta(std.testing.allocator);
    try std.testing.expect(!no_op.compacted);
    const status_after = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(status_after);
    try std.testing.expectEqualStrings("completed", status_after);
    const holder_after = (try store.getNodeStringProperty(std.testing.allocator, task_id, "claimed_by")).?;
    defer std.testing.allocator.free(holder_after);
    try std.testing.expectEqualStrings("agent-a", holder_after);
    try std.testing.expectEqual(@as(?u64, 99), try store.getUintProperty(std.testing.allocator, .{ .node = task_id }, "claim_expires_ns"));
}

test "property payload compaction cleanup failure remains retryable state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    // A same-name directory deterministically makes file unlink fail without
    // relying on platform-specific permission behavior. Post-commit cleanup
    // reports pending and preserves the foreign path for retry/inspection.
    try std.Io.Dir.cwd().createDir(std.testing.io, store.property_payload_delta_path, .default_dir);
    try std.testing.expect(!storage_data_plane_support.property_payload_transaction.Testing.cleanupCompactedDelta(store));
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, store.property_payload_delta_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(.directory, stat.kind);
}

test "property payload delta redo recovers absent committed and partial appends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    var store_open = true;
    defer if (store_open) store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "delta redo task");

    const frame_one = try storage_data_plane_support.property_payload_transaction.Testing.encodeDelta(std.testing.allocator, 1, &.{.{
        .owner = .{ .node = task_id },
        .key = "status",
        .value = .{ .string = "open" },
    }});
    defer std.testing.allocator.free(frame_one);
    try storage_data_plane_support.property_payload_transaction.Testing.writeDeltaRedo(store, frame_one);
    store.deinit();
    store_open = false;

    store = try Store.open(std.testing.allocator, std.testing.io, store_path);
    store_open = true;
    const open_status = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(open_status);
    try std.testing.expectEqualStrings("open", open_status);

    const scan_one = try store.scanPropertyPayloadDelta(std.testing.allocator, .none, false);
    const frame_two = try storage_data_plane_support.property_payload_transaction.Testing.encodeDelta(std.testing.allocator, 2, &.{.{
        .owner = .{ .node = task_id },
        .key = "status",
        .value = .{ .string = "claimed" },
    }});
    defer std.testing.allocator.free(frame_two);
    try storage_data_plane_support.property_payload_transaction.Testing.writeDeltaRedo(store, frame_two);
    try storage_data_plane_support.property_payload_transaction.Testing.appendDelta(store, frame_two, scan_one.valid_bytes);
    store.deinit();
    store_open = false;

    store = try Store.open(std.testing.allocator, std.testing.io, store_path);
    store_open = true;
    const claimed_status = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(claimed_status);
    try std.testing.expectEqualStrings("claimed", claimed_status);

    const scan_two = try store.scanPropertyPayloadDelta(std.testing.allocator, .none, false);
    const frame_three = try storage_data_plane_support.property_payload_transaction.Testing.encodeDelta(std.testing.allocator, 3, &.{.{
        .owner = .{ .node = task_id },
        .key = "status",
        .value = .{ .string = "completed" },
    }});
    defer std.testing.allocator.free(frame_three);
    try storage_data_plane_support.property_payload_transaction.Testing.writeDeltaRedo(store, frame_three);
    {
        var delta = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{ .mode = .read_write });
        defer delta.close(std.testing.io);
        try delta.writePositionalAll(std.testing.io, frame_three[0 .. frame_three.len / 2], scan_two.valid_bytes);
    }
    store.deinit();
    store_open = false;

    store = try Store.open(std.testing.allocator, std.testing.io, store_path);
    store_open = true;
    const completed_status = (try store.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(completed_status);
    try std.testing.expectEqualStrings("completed", completed_status);
    const journal_path = try storage_data_plane_support.property_payload_transaction.Testing.deltaRedoPath(store);
    defer std.testing.allocator.free(journal_path);
    try std.testing.expect(!try store.pathExists(journal_path));
}

test "property payload delta corruption without matching redo fails closed on first property use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    try store.createEmpty();
    const task_id = try store.addNode(.task, "delta corrupt task");
    try store.setNodeStringProperty(std.testing.allocator, task_id, "status", "open");
    var delta = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{ .mode = .read_write });
    const delta_len = try store.regularFileSize(delta);
    try delta.writePositionalAll(std.testing.io, "broken", delta_len);
    delta.close(std.testing.io);
    store.deinit();

    var reopened = try Store.open(std.testing.allocator, std.testing.io, store_path);
    defer reopened.deinit();
    try std.testing.expectError(
        error.InvalidRecord,
        reopened.getNodeStringProperty(std.testing.allocator, task_id, "status"),
    );
}

test "property payload delta redo refuses a nonmatching corrupt tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    try store.createEmpty();
    const task_id = try store.addNode(.task, "delta mismatched redo task");
    try store.setNodeStringProperty(std.testing.allocator, task_id, "status", "open");
    const scan = try store.scanPropertyPayloadDelta(std.testing.allocator, .none, false);
    const frame = try storage_data_plane_support.property_payload_transaction.Testing.encodeDelta(std.testing.allocator, 2, &.{.{
        .owner = .{ .node = task_id },
        .key = "status",
        .value = .{ .string = "claimed" },
    }});
    defer std.testing.allocator.free(frame);
    try storage_data_plane_support.property_payload_transaction.Testing.writeDeltaRedo(store, frame);
    var delta = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{ .mode = .read_write });
    try delta.writePositionalAll(std.testing.io, "wrong-tail", scan.valid_bytes);
    delta.close(std.testing.io);
    store.deinit();

    try std.testing.expectError(error.InvalidRecord, Store.open(std.testing.allocator, std.testing.io, store_path));
}

test "property payload redo journal recovers between pair renames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    var store_open = true;
    defer if (store_open) store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "redo lifecycle task");
    try store.appendPropertiesBatch(std.testing.allocator, &.{.{
        .owner = .{ .node = task_id },
        .key = "status",
        .value = .{ .string = "open" },
    }});

    var entries = try store.readPropertyPayloadEntriesOrEmpty(std.testing.allocator);
    defer {
        storage_data_plane_support.deinitPropertyPayloadIndexEntries(entries.items, std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }
    var index: usize = 0;
    while (index < entries.items.len) {
        if (storage_data_plane_support.propertyPayloadEntryMatchesOwnerKey(entries.items[index], .{ .node = task_id }, "status")) {
            var removed = entries.orderedRemove(index);
            removed.deinit(std.testing.allocator);
        } else {
            index += 1;
        }
    }
    try storage_data_plane_support.appendStringPropertyPayloadRecord(&entries, std.testing.allocator, .{ .node = task_id }, "status", "claimed");
    try storage_data_plane_support.appendUintPropertyPayloadRecord(&entries, std.testing.allocator, .{ .node = task_id }, "claim_expires_ns", 99);
    std.mem.sort(storage_data_plane_support.PropertyPayloadIndexEntry, entries.items, {}, storage_data_plane_support.propertyPayloadEntryLessThan);

    const index_stage = try store.tmpPathFor(store.property_payload_index_path);
    defer std.testing.allocator.free(index_stage);
    const values_stage = try store.tmpPathFor(store.property_payload_values_path);
    defer std.testing.allocator.free(values_stage);
    try storage_data_plane_support.property_payload_transaction.Testing.writeIndexStage(store, index_stage, entries.items);
    try storage_data_plane_support.property_payload_transaction.Testing.writeValueStage(store, values_stage, entries.items);
    try storage_data_plane_support.property_payload_transaction.Testing.writeBaseRedo(store, index_stage, values_stage);

    // Simulate power loss after values became visible but before the matching
    // index rename and journal deletion.
    try store.renameReplace(values_stage, store.property_payload_values_path);
    store.deinit();
    store_open = false;

    var reopened = try Store.open(std.testing.allocator, std.testing.io, store_path);
    defer reopened.deinit();
    const status = (try reopened.getNodeStringProperty(std.testing.allocator, task_id, "status")).?;
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("claimed", status);
    try std.testing.expectEqual(@as(?u64, 99), try reopened.getUintProperty(std.testing.allocator, .{ .node = task_id }, "claim_expires_ns"));
    const journal_path = try storage_data_plane_support.property_payload_transaction.Testing.baseRedoPath(reopened);
    defer std.testing.allocator.free(journal_path);
    try std.testing.expect(!try reopened.pathExists(journal_path));
}

test "property payload redo journal corruption fails closed on open and init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    var store_open = true;
    defer if (store_open) store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "fail-closed redo");
    try store.setNodeStringProperty(std.testing.allocator, node_id, "status", "open");
    const journal_path = try storage_data_plane_support.property_payload_transaction.Testing.baseRedoPath(store);
    defer std.testing.allocator.free(journal_path);
    store.deinit();
    store_open = false;

    // A zero-length or garbage journal is not safe to discard: either may be
    // the only durable copy of a pair publication interrupted mid-rename.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = journal_path, .data = "", .flags = .{ .truncate = true } });
    try std.testing.expectError(error.InvalidRecord, Store.open(std.testing.allocator, std.testing.io, store_path));
    try std.testing.expectError(error.InvalidRecord, Store.init(std.testing.allocator, std.testing.io, store_path));

    const garbage = [_]u8{0xa5} ** storage_data_plane_support.PropertyPayloadRedoJournalHeader.encoded_len;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = journal_path, .data = &garbage, .flags = .{ .truncate = true } });
    try std.testing.expectError(error.InvalidRecord, Store.open(std.testing.allocator, std.testing.io, store_path));
    try std.testing.expectEqual(.file, (try std.Io.Dir.cwd().statFile(std.testing.io, journal_path, .{})).kind);
}

test "strict property payload key readers reject globally unsorted immutable base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "strict property order");
    try store.appendPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = node_id }, .key = "name", .value = .{ .string = "searchable name" } },
        .{ .owner = .{ .node = node_id }, .key = "summary", .value = .{ .string = "searchable summary" } },
        .{ .owner = .{ .node = node_id }, .key = "unrelated_a", .value = .{ .string = "alpha" } },
        .{ .owner = .{ .node = node_id }, .key = "unrelated_b", .value = .{ .string = "beta" } },
    });

    var index_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_index_path, .{ .mode = .read_write });
    const header = try store.readPropertyPayloadIndexHeaderFromFile(index_file);
    var unrelated_indexes: [2]u64 = undefined;
    var unrelated_count: usize = 0;
    var index: u64 = 0;
    while (index < header.record_count and unrelated_count < unrelated_indexes.len) : (index += 1) {
        const record = try store.readPropertyPayloadIndexRecordAt(index_file, index);
        if (record.key_hash == storage_data_plane_support.nodePropertyKeyHash("name") or record.key_hash == storage_data_plane_support.nodePropertyKeyHash("summary")) continue;
        unrelated_indexes[unrelated_count] = index;
        unrelated_count += 1;
    }
    try std.testing.expectEqual(unrelated_indexes.len, unrelated_count);
    const first = try store.readPropertyPayloadIndexRecordAt(index_file, unrelated_indexes[0]);
    const second = try store.readPropertyPayloadIndexRecordAt(index_file, unrelated_indexes[1]);
    var first_bytes: [storage_data_plane_support.PropertyPayloadIndexRecord.encoded_len]u8 = undefined;
    var second_bytes: [storage_data_plane_support.PropertyPayloadIndexRecord.encoded_len]u8 = undefined;
    try first.encode(&first_bytes);
    try second.encode(&second_bytes);
    try index_file.writePositionalAll(std.testing.io, &second_bytes, try storage_data_plane_support.propertyPayloadIndexRecordOffset(unrelated_indexes[0]));
    try index_file.writePositionalAll(std.testing.io, &first_bytes, try storage_data_plane_support.propertyPayloadIndexRecordOffset(unrelated_indexes[1]));
    index_file.close(std.testing.io);

    store.options.validate_indexes_on_read = true;
    try std.testing.expectError(error.InvalidRecord, store.searchableNodeMetadataDigest(std.testing.allocator));
    try std.testing.expectError(error.InvalidRecord, store.getNodeStringProperty(std.testing.allocator, node_id, "name"));
}

test "searchable metadata digest allocates only selected property values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "metadata digest task");
    const unrelated = [_]u8{'x'} ** (64 * 1024);
    try store.appendPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = node_id }, .key = "name", .value = .{ .string = "short searchable name" } },
        .{ .owner = .{ .node = node_id }, .key = "unrelated_blob", .value = .{ .string = &unrelated } },
    });

    var digest_scratch: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&digest_scratch);
    try std.testing.expect((try store.searchableNodeMetadataDigest(fixed.allocator())) != 0);

    var snapshot_scratch: [512]u8 = undefined;
    var snapshot_fixed = std.heap.FixedBufferAllocator.init(&snapshot_scratch);
    var snapshot = try store.loadSearchableNodeMetadataSnapshot(snapshot_fixed.allocator());
    defer snapshot.deinit(snapshot_fixed.allocator());
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.len);
    try std.testing.expectEqualStrings("short searchable name", snapshot.entries[0].string_value);
}

test "compacted searchable metadata digest streams immutable values with fixed memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const long_name = [_]u8{'n'} ** (20 * 1024);
    for (0..8) |index| {
        const node_id = try store.addNode(.task, "streamed metadata");
        try std.testing.expectEqual(@as(u64, index + 1), node_id.toInt());
        try store.setNodeStringProperty(std.testing.allocator, node_id, "name", &long_name);
    }
    const expected = try store.searchableNodeMetadataDigest(std.testing.allocator);
    const compacted = try store.compactPropertyPayloadDelta(std.testing.allocator);
    try std.testing.expect(compacted.compacted);
    try std.testing.expect(!try store.pathExists(store.property_payload_delta_path));

    // The pre-streaming path owned every selected value at once and could not
    // compute this 160 KiB digest with a one-byte caller allocator. Each
    // individual value also crosses the streaming scratch-buffer boundary.
    // The immutable steady-state path now reads values through a fixed stack
    // buffer while retaining the exact same semantic digest.
    var scratch: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    try std.testing.expectEqual(expected, try store.searchableNodeMetadataDigest(fixed.allocator()));
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        store.searchableNodeMetadataDigestLimitedDeadline(fixed.allocator(), 0, .immediate),
    );

    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "name", "delta override");
    const expected_with_delta = try store.searchableNodeMetadataDigest(std.testing.allocator);
    var manually_overridden = expected;
    Store.addSearchableNodeMetadataDigest(
        &manually_overridden,
        0x544B_534D,
        1,
        storage_data_plane_support.nodePropertyKeyHash("name"),
        storage_data_plane_support.nodePropertyValueHash(&long_name),
        &long_name,
    );
    Store.addSearchableNodeMetadataDigest(
        &manually_overridden,
        0x544B_534D,
        1,
        storage_data_plane_support.nodePropertyKeyHash("name"),
        storage_data_plane_support.nodePropertyValueHash("delta override"),
        "delta override",
    );
    try std.testing.expectEqual(manually_overridden, expected_with_delta);
    var delta_scratch: [16 * 1024]u8 = undefined;
    var delta_fixed = std.heap.FixedBufferAllocator.init(&delta_scratch);
    try std.testing.expectEqual(
        expected_with_delta,
        try store.searchableNodeMetadataDigestLimitedDeadline(
            delta_fixed.allocator(),
            try store.propertyPayloadDeltaByteCount(),
            .none,
        ),
    );

    var index_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_index_path, .{});
    const index_header = try store.readPropertyPayloadIndexHeaderFromFile(index_file);
    const name_index = try store.propertyPayloadKeyHashLowerBound(index_file, index_header.record_count, storage_data_plane_support.nodePropertyKeyHash("name"));
    index_file.close(std.testing.io);
    var values_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_values_path, .{ .mode = .read_write });
    const values_header = try store.readNodePropertyValueBlockHeaderFromFile(values_file);
    const value_record = try store.readNodePropertyValueRecordAt(values_file, name_index);
    const payload_start = try storage_data_plane_support.nodePropertyValueBlockHeaderAndRecordBytes(values_header.record_count);
    const value_offset = try std.math.add(u64, payload_start, value_record.offset);
    var corrupt_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try values_file.readPositionalAll(std.testing.io, &corrupt_byte, value_offset));
    corrupt_byte[0] ^= 0xff;
    try values_file.writePositionalAll(std.testing.io, &corrupt_byte, value_offset);
    values_file.close(std.testing.io);
    try std.testing.expectError(error.InvalidRecord, store.searchableNodeMetadataDigest(std.testing.allocator));
}

test "searchable metadata limited readers reject property delta before scanning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "bounded metadata delta");
    try store.setNodeStringProperty(std.testing.allocator, node_id, "summary", "searchable summary");

    const delta_bytes = try store.propertyPayloadDeltaByteCount();
    try std.testing.expect(delta_bytes > 0);
    try std.testing.expect((try store.searchableNodeMetadataDigestLimitedDeadline(std.testing.allocator, delta_bytes, .none)) != 0);
    try std.testing.expectError(
        error.SearchableMetadataBudgetExceeded,
        store.searchableNodeMetadataDigestLimitedDeadline(std.testing.allocator, delta_bytes - 1, .none),
    );
    try std.testing.expectError(
        error.SearchableMetadataBudgetExceeded,
        store.loadSearchableNodeMetadataSnapshotWithLimitsDeadline(std.testing.allocator, "searchable summary".len, delta_bytes - 1, .none),
    );
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        store.searchableNodeMetadataDigestLimitedDeadline(std.testing.allocator, delta_bytes, .immediate),
    );
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        store.loadSearchableNodeMetadataSnapshotWithLimitsDeadline(std.testing.allocator, "searchable summary".len, delta_bytes, .immediate),
    );
}

test "searchable metadata effective view includes legacy fallback without duplicate overrides" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "legacy searchable metadata");

    var legacy = std.ArrayList(storage_data_plane_support.NodePropertyIndexEntry).empty;
    defer {
        storage_data_plane_support.deinitNodePropertyIndexEntries(legacy.items, std.testing.allocator);
        legacy.deinit(std.testing.allocator);
    }
    try storage_data_plane_support.appendNodePropertyRecordForValue(&legacy, std.testing.allocator, node_id, "name", "legacy name");
    try storage_data_plane_support.appendNodePropertyRecordForValue(&legacy, std.testing.allocator, node_id, "summary", "legacy summary");
    try store.writeNodePropertyOverlay(legacy.items);

    const legacy_digest = try store.searchableNodeMetadataDigest(std.testing.allocator);
    try std.testing.expect(legacy_digest != 0);

    try store.setNodeStringProperty(std.testing.allocator, node_id, "name", "canonical name");
    const canonical_digest = try store.searchableNodeMetadataDigest(std.testing.allocator);
    try std.testing.expect(canonical_digest != legacy_digest);

    const live_bytes = "canonical name".len + "legacy summary".len;
    var snapshot = try store.loadSearchableNodeMetadataSnapshotLimited(std.testing.allocator, live_bytes);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.entries.len);
    var name_count: usize = 0;
    var summary_count: usize = 0;
    for (snapshot.entries) |entry| {
        const owner_matches = switch (entry.owner) {
            .node => |id| id == node_id,
            .edge => false,
        };
        if (!owner_matches) continue;
        if (entry.key_hash == storage_data_plane_support.nodePropertyKeyHash("name")) {
            name_count += 1;
            try std.testing.expectEqualStrings("canonical name", entry.string_value);
        } else if (entry.key_hash == storage_data_plane_support.nodePropertyKeyHash("summary")) {
            summary_count += 1;
            try std.testing.expectEqualStrings("legacy summary", entry.string_value);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), name_count);
    try std.testing.expectEqual(@as(usize, 1), summary_count);
    try std.testing.expectError(
        error.SearchableMetadataBudgetExceeded,
        store.loadSearchableNodeMetadataSnapshotLimited(std.testing.allocator, live_bytes - 1),
    );
}

test "searchable legacy metadata snapshot does not scan unrelated value records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const node_id = try store.addNode(.task, "legacy key-range metadata");

    var legacy = std.ArrayList(storage_data_plane_support.NodePropertyIndexEntry).empty;
    defer {
        storage_data_plane_support.deinitNodePropertyIndexEntries(legacy.items, std.testing.allocator);
        legacy.deinit(std.testing.allocator);
    }
    try storage_data_plane_support.appendNodePropertyRecordForValue(&legacy, std.testing.allocator, node_id, "name", "legacy searchable name");
    try storage_data_plane_support.appendNodePropertyRecordForValue(&legacy, std.testing.allocator, node_id, "status", "open");
    try store.writeNodePropertyOverlay(legacy.items);

    var index_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_props_overlay_index_path, .{});
    const index_header = try store.readNodePropertyIndexHeaderFromFile(index_file);
    var unrelated_index: ?u64 = null;
    var index: u64 = 0;
    while (index < index_header.record_count) : (index += 1) {
        const record = try store.readNodePropertyIndexRecordAt(index_file, index);
        if (record.key_hash == storage_data_plane_support.nodePropertyKeyHash("status")) {
            unrelated_index = index;
            break;
        }
    }
    index_file.close(std.testing.io);
    try std.testing.expect(unrelated_index != null);

    // A stale-text snapshot consumes only name/summary. Corrupting an
    // unrelated legacy value record must remain the responsibility of a
    // status reader or explicit validation, not turn this bounded key read
    // back into a full legacy-overlay scan.
    var values_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_props_overlay_values_path, .{ .mode = .read_write });
    const length_offset = std.math.add(u64, try storage_data_plane_support.nodePropertyValueRecordOffset(unrelated_index.?), 8) catch return error.RecordTooLarge;
    const zero_len = [_]u8{0} ** 4;
    try values_file.writePositionalAll(std.testing.io, &zero_len, length_offset);
    values_file.close(std.testing.io);

    try std.testing.expect((try store.searchableNodeMetadataDigest(std.testing.allocator)) != 0);
    var snapshot = try store.loadSearchableNodeMetadataSnapshotLimited(std.testing.allocator, "legacy searchable name".len);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.len);
    try std.testing.expectEqualStrings("legacy searchable name", snapshot.entries[0].string_value);
    try std.testing.expectError(error.InvalidRecord, store.getNodeStringProperty(std.testing.allocator, node_id, "status"));
}

test "searchable metadata digest binds values to their owners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .task, .text = "first" },
        .{ .id = .fromInt(2), .kind = .task, .text = "second" },
    });
    try store.appendPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = .fromInt(1) }, .key = "name", .value = .{ .string = "alpha" } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = "name", .value = .{ .string = "beta" } },
    });
    const before = try store.searchableNodeMetadataDigest(std.testing.allocator);

    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = .fromInt(1) }, .key = "name", .value = .{ .string = "beta" } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = "name", .value = .{ .string = "alpha" } },
    });
    const after = try store.searchableNodeMetadataDigest(std.testing.allocator);
    try std.testing.expect(after != before);
}

test "property point lookups do not materialize unrelated base blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "bounded property lookup");
    const unrelated = [_]u8{'x'} ** (64 * 1024);
    try store.appendPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = task_id }, .key = "status", .value = .{ .string = "open" } },
        .{ .owner = .{ .node = task_id }, .key = "task_recorded_ns", .value = .{ .uint = 42 } },
        .{ .owner = .{ .node = task_id }, .key = "unrelated_blob", .value = .{ .string = &unrelated } },
    });
    var legacy_overlay = std.ArrayList(storage_data_plane_support.NodePropertyIndexEntry).empty;
    defer {
        storage_data_plane_support.deinitNodePropertyIndexEntries(legacy_overlay.items, std.testing.allocator);
        legacy_overlay.deinit(std.testing.allocator);
    }
    try storage_data_plane_support.appendNodePropertyRecordForValue(
        &legacy_overlay,
        std.testing.allocator,
        task_id,
        "unrelated_legacy_blob",
        &unrelated,
    );
    try store.writeNodePropertyOverlay(legacy_overlay.items);

    // The old lookup path allocated every primary and legacy-overlay property
    // payload and therefore exhausted this buffer on either 64 KiB value.
    var string_scratch: [8 * 1024]u8 = undefined;
    var string_fixed = std.heap.FixedBufferAllocator.init(&string_scratch);
    var status_hits = try store.lookupNodeIdsByStringProperty(string_fixed.allocator(), "status", "open", .task, 10);
    defer status_hits.deinit(string_fixed.allocator());
    try std.testing.expectEqualSlices(core.NodeId, &.{task_id}, status_hits.items);

    var uint_scratch: [8 * 1024]u8 = undefined;
    var uint_fixed = std.heap.FixedBufferAllocator.init(&uint_scratch);
    var recorded_hits = try store.lookupNodeIdsByUintProperty(uint_fixed.allocator(), "task_recorded_ns", 42, .task, 10);
    defer recorded_hits.deinit(uint_fixed.allocator());
    try std.testing.expectEqualSlices(core.NodeId, &.{task_id}, recorded_hits.items);
}

test "store node property index supports governed typed exact lookup and repair rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const first = try store.addNode(.document, "doc");
    try store.setNodeStringProperty(std.testing.allocator, first, "test_group", "group_a");
    try store.setNodeStringProperty(std.testing.allocator, first, "schema_type", "document");
    try store.setNodeStringProperty(std.testing.allocator, first, "summary", "shared summary");
    try store.setNodeStringProperty(std.testing.allocator, first, "retrieval_hints", "markdown import");
    const second = try store.addNode(.observation, "chunk");
    try store.setNodeStringProperty(std.testing.allocator, second, "test_group", "group_a");
    try store.setNodeStringProperty(std.testing.allocator, second, "schema_type", "content_text");
    try store.setNodeStringProperty(std.testing.allocator, second, "summary", "shared summary");
    try store.setNodeStringProperty(std.testing.allocator, second, "retrieval_hints", "agent context");
    const timed = try store.addNode(.task, "timed task");
    try store.setNodeStringProperty(std.testing.allocator, timed, "test_group", "group_a");
    try store.setNodeStringProperty(std.testing.allocator, timed, "schema_type", "task");
    try store.setUintProperty(std.testing.allocator, .{ .node = timed }, "task_recorded_ns", 42);
    try store.setUintProperty(std.testing.allocator, .{ .node = timed }, "task_root_id", 7);
    const other = try store.addNode(.document, "group_b");
    try store.setNodeStringProperty(std.testing.allocator, other, "test_group", "group_b");
    try store.setNodeStringProperty(std.testing.allocator, other, "schema_type", "document");
    try store.setNodeStringProperty(std.testing.allocator, other, "summary", "different");
    try store.setUintProperty(std.testing.allocator, .{ .node = other }, "task_recorded_ns", 43);

    var group_hits = try store.lookupNodeIdsByStringProperty(std.testing.allocator, "test_group", "group_a", null, 10);
    defer group_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), group_hits.items.len);
    try std.testing.expectEqual(first, group_hits.items[0]);
    try std.testing.expectEqual(second, group_hits.items[1]);
    try std.testing.expectEqual(timed, group_hits.items[2]);

    var summary_hits = try store.lookupNodeIdsByStringProperty(std.testing.allocator, "summary", "shared summary", .observation, 10);
    defer summary_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), summary_hits.items.len);
    try std.testing.expectEqual(second, summary_hits.items[0]);

    try store.setNodeStringProperty(std.testing.allocator, second, "summary", "overlay summary");
    var old_summary_hits = try store.lookupNodeIdsByStringProperty(std.testing.allocator, "summary", "shared summary", .observation, 10);
    defer old_summary_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), old_summary_hits.items.len);
    var overlay_summary_hits = try store.lookupNodeIdsByStringProperty(std.testing.allocator, "summary", "overlay summary", .observation, 10);
    defer overlay_summary_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), overlay_summary_hits.items.len);
    try std.testing.expectEqual(second, overlay_summary_hits.items[0]);

    var limited_group_hits = try store.lookupNodeIdsByStringProperty(std.testing.allocator, "test_group", "group_a", null, 1);
    defer limited_group_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), limited_group_hits.items.len);

    var unsupported_hits = try store.lookupNodeIdsByStringProperty(std.testing.allocator, "content_hash", "x", null, 10);
    defer unsupported_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unsupported_hits.items.len);

    var timed_hits = try store.lookupNodeIdsByUintProperty(std.testing.allocator, "task_recorded_ns", 42, .task, 10);
    defer timed_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), timed_hits.items.len);
    try std.testing.expectEqual(timed, timed_hits.items[0]);

    var ranged_hits = try store.lookupNodeIdsByUintPropertyRange(std.testing.allocator, "task_recorded_ns", .{ .min = 43 }, null, 10);
    defer ranged_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ranged_hits.items.len);

    var exclusive_ranged_hits = try store.lookupNodeIdsByUintPropertyRange(std.testing.allocator, "task_recorded_ns", .{ .min = 42, .min_inclusive = false }, null, 10);
    defer exclusive_ranged_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), exclusive_ranged_hits.items.len);

    var bounded_empty_hits = try store.lookupNodeIdsByUintPropertyRange(std.testing.allocator, "task_recorded_ns", .{ .min = 42, .min_inclusive = false, .max = 43, .max_inclusive = false }, null, 10);
    defer bounded_empty_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), bounded_empty_hits.items.len);

    var task_root_hits = try store.lookupNodeIdsByUintProperty(std.testing.allocator, "task_root_id", 7, null, 10);
    defer task_root_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), task_root_hits.items.len);
    try std.testing.expectEqual(timed, task_root_hits.items[0]);

    var unsupported_uint_hits = try store.lookupNodeIdsByUintProperty(std.testing.allocator, "summary", 42, null, 10);
    defer unsupported_uint_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unsupported_uint_hits.items.len);

    try std.testing.expect(try store.fileExists(store.node_props_values_path));
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.node_props_values_path);
    var repaired_string_hits = try store.lookupNodeIdsByStringProperty(std.testing.allocator, "retrieval_hints", "agent context", null, 10);
    defer repaired_string_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), repaired_string_hits.items.len);
    try std.testing.expectEqual(second, repaired_string_hits.items[0]);
    try std.testing.expect(try store.fileExists(store.node_props_values_path));

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.node_props_index_path);
    var repaired_hits = try store.lookupNodeIdsByUintProperty(std.testing.allocator, "task_recorded_ns", 42, null, 10);
    defer repaired_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), repaired_hits.items.len);
    try std.testing.expectEqual(timed, repaired_hits.items[0]);
    try std.testing.expect(try store.fileExists(store.node_props_index_path));

    try std.testing.expect(try store.fileExists(store.property_payload_delta_path));
    {
        var delta = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{ .mode = .read_write });
        defer delta.close(std.testing.io);
        const delta_size = try store.regularFileSize(delta);
        try delta.setLength(std.testing.io, delta_size - 1);
    }
    try std.testing.expectError(error.InvalidRecord, store.lookupNodeIdsByStringProperty(std.testing.allocator, "summary", "overlay summary", null, 10));
}

test "store edge property overlay supports independently writable string payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const src = try store.addNode(.document, "doc");
    const dst = try store.addNode(.observation, "chunk");
    const other = try store.addNode(.observation, "other chunk");
    const edge_id = try store.nextEdgeId();
    try store.appendEdgeIndexed(.{ .id = edge_id, .src = src, .rel = .mentions, .dst = dst });
    const other_edge_id = try store.nextEdgeId();
    try store.appendEdgeIndexed(.{ .id = other_edge_id, .src = src, .rel = .mentions, .dst = other });

    try store.setStringProperty(std.testing.allocator, .{ .node = dst }, "summary", "generic node summary");
    const node_summary = (try store.getStringProperty(std.testing.allocator, .{ .node = dst }, "summary")).?;
    defer std.testing.allocator.free(node_summary);
    try std.testing.expectEqualStrings("generic node summary", node_summary);

    try store.setEdgeStringProperty(std.testing.allocator, edge_id, "source_span", "12:3-12:19");
    const source_span = (try store.getEdgeStringProperty(std.testing.allocator, edge_id, "source_span")).?;
    defer std.testing.allocator.free(source_span);
    try std.testing.expectEqualStrings("12:3-12:19", source_span);

    try store.setStringProperty(std.testing.allocator, .{ .edge = edge_id }, "created_by", "agent");
    try store.setStringProperty(std.testing.allocator, .{ .edge = other_edge_id }, "created_by", "human");
    var agent_edges = try store.lookupEdgeIdsByStringProperty(std.testing.allocator, "created_by", "agent", 10);
    defer agent_edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), agent_edges.items.len);
    try std.testing.expectEqual(edge_id, agent_edges.items[0]);
    var human_edges = try store.lookupEdgeIdsByStringProperty(std.testing.allocator, "created_by", "human", 10);
    defer human_edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), human_edges.items.len);
    try std.testing.expectEqual(other_edge_id, human_edges.items[0]);

    try store.setStringProperty(std.testing.allocator, .{ .edge = edge_id }, "created_by", "human");
    var old_agent_edges = try store.lookupEdgeIdsByStringProperty(std.testing.allocator, "created_by", "agent", 10);
    defer old_agent_edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), old_agent_edges.items.len);
    var updated_human_edges = try store.lookupEdgeIdsByStringProperty(std.testing.allocator, "created_by", "human", 10);
    defer updated_human_edges.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), updated_human_edges.items.len);
    try std.testing.expectEqual(edge_id, updated_human_edges.items[0]);
    try std.testing.expectEqual(other_edge_id, updated_human_edges.items[1]);

    try store.setStringProperty(std.testing.allocator, .{ .edge = edge_id }, "source_span", "13:1-13:7");
    const updated_span = (try store.getStringProperty(std.testing.allocator, .{ .edge = edge_id }, "source_span")).?;
    defer std.testing.allocator.free(updated_span);
    try std.testing.expectEqualStrings("13:1-13:7", updated_span);

    try store.setUintProperty(std.testing.allocator, .{ .node = dst }, "generation", 7);
    try std.testing.expectEqual(@as(?u64, 7), try store.getUintProperty(std.testing.allocator, .{ .node = dst }, "generation"));
    try store.setUintProperty(std.testing.allocator, .{ .node = dst }, "generation", 8);
    try std.testing.expectEqual(@as(?u64, 8), try store.getUintProperty(std.testing.allocator, .{ .node = dst }, "generation"));
    try store.setUintProperty(std.testing.allocator, .{ .edge = edge_id }, "order_key", 2048);
    try std.testing.expectEqual(@as(?u64, 2048), try store.getUintProperty(std.testing.allocator, .{ .edge = edge_id }, "order_key"));
    try std.testing.expectEqual(@as(?u64, null), try store.getUintProperty(std.testing.allocator, .{ .edge = edge_id }, "generation"));
    try std.testing.expectEqual(@as(?u64, null), try store.getUintProperty(std.testing.allocator, .{ .edge = edge_id }, "summary"));
    try store.setUintProperty(std.testing.allocator, .{ .edge = edge_id }, "line_start", 12);
    try std.testing.expectEqual(@as(?u64, 12), try store.getUintProperty(std.testing.allocator, .{ .edge = edge_id }, "line_start"));
    try std.testing.expectError(core.Error.InvalidId, store.setUintProperty(std.testing.allocator, .{ .edge = .fromInt(99) }, "order_key", 12));

    try std.testing.expectEqual(@as(?[]u8, null), try store.getEdgeStringProperty(std.testing.allocator, edge_id, "markdown_attr"));
    try store.setEdgeStringProperty(std.testing.allocator, edge_id, "summary", "edge summary");
    const edge_summary = (try store.getEdgeStringProperty(std.testing.allocator, edge_id, "summary")).?;
    defer std.testing.allocator.free(edge_summary);
    try std.testing.expectEqualStrings("edge summary", edge_summary);
    try std.testing.expectError(core.Error.InvalidId, store.setEdgeStringProperty(std.testing.allocator, .fromInt(99), "source_span", "missing edge"));

    try std.testing.expect(try store.fileExists(store.property_payload_delta_path));
    {
        var delta = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{ .mode = .read_write });
        defer delta.close(std.testing.io);
        const delta_size = try store.regularFileSize(delta);
        try delta.setLength(std.testing.io, delta_size - 1);
    }
    try std.testing.expectError(error.InvalidRecord, store.getEdgeStringProperty(std.testing.allocator, edge_id, "source_span"));
}

test "published edge overlay supports point properties external keys and delete without repair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .document, .text = "root" },
        .{ .id = .fromInt(2), .kind = .observation, .text = "base" },
        .{ .id = .fromInt(3), .kind = .observation, .text = "overlay" },
    });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "external_key", "doc:overlay");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "external_key", "content:base");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(3), "external_key", "content:overlay");

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacityPrecise(std.testing.allocator, 1024);
    for (1..1025) |raw_id| {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(raw_id),
            .src = .fromInt(1),
            .rel = .mentions,
            .dst = .fromInt(2),
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    try store.rebuildEdgeExternalKeyIndex();

    const overlay_id: core.EdgeId = .fromInt(1025);
    try store.appendEdgesBatch(&.{.{
        .id = overlay_id,
        .src = .fromInt(1),
        .rel = .mentions,
        .dst = .fromInt(3),
    }});
    const overlay_meta = try store.readCurrentIndexMeta();
    try std.testing.expectEqual(@as(u64, 1024), overlay_meta.edge_indexed_edges);
    try std.testing.expectEqual(@as(u64, 1), overlay_meta.edge_segment_edges);
    try std.testing.expect(try store.edgeStorageMatchesMeta(overlay_meta, true));

    const edge = try store.readEdgeById(overlay_id);
    try std.testing.expectEqual(@as(u64, 3), edge.dst.toInt());
    try store.setEdgeStringProperty(std.testing.allocator, overlay_id, "created_by", "overlay-agent");
    try store.setUintProperty(std.testing.allocator, .{ .edge = overlay_id }, "order_key", 4096);
    const created_by = (try store.getEdgeStringProperty(std.testing.allocator, overlay_id, "created_by")).?;
    defer std.testing.allocator.free(created_by);
    try std.testing.expectEqualStrings("overlay-agent", created_by);
    try std.testing.expectEqual(@as(?u64, 4096), try store.getUintProperty(std.testing.allocator, .{ .edge = overlay_id }, "order_key"));

    var property_hits = try store.lookupEdgeIdsByStringProperty(std.testing.allocator, "created_by", "overlay-agent", 10);
    defer property_hits.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(core.EdgeId, &.{overlay_id}, property_hits.items);

    const external_key = try edgeFactExternalKeyAlloc(std.testing.allocator, "doc:overlay", .mentions, "content:overlay");
    defer std.testing.allocator.free(external_key);
    try std.testing.expectEqual(overlay_id, (try store.lookupEdgeByExternalKey(std.testing.allocator, external_key)).?);
    try store.rebuildEdgeExternalKeyIndex();
    try std.testing.expectEqual(overlay_id, (try store.lookupEdgeByExternalKey(std.testing.allocator, external_key)).?);

    const visible_refs = try store.loadEdgeRefs(std.testing.allocator);
    defer std.testing.allocator.free(visible_refs);
    try std.testing.expectEqual(@as(usize, 1025), visible_refs.len);
    try std.testing.expectEqual(overlay_id, visible_refs[visible_refs.len - 1].edge_id);
    try std.testing.expectEqual(@as(u64, 3), visible_refs[visible_refs.len - 1].dst.toInt());

    try store.deleteEdge(overlay_id);
    const deleted_meta = try store.readCurrentIndexMeta();
    try std.testing.expectEqual(@as(u64, 1024), deleted_meta.edge_indexed_edges);
    try std.testing.expectEqual(@as(u64, 1), deleted_meta.edge_segment_edges);
    try std.testing.expectError(core.Error.InvalidId, store.readEdgeById(overlay_id));
    try std.testing.expectEqual(@as(?core.EdgeId, null), try store.lookupEdgeByExternalKey(std.testing.allocator, external_key));
    var deleted_property_hits = try store.lookupEdgeIdsByStringProperty(std.testing.allocator, "created_by", "overlay-agent", 10);
    defer deleted_property_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), deleted_property_hits.items.len);
    const refs_after_delete = try store.loadEdgeRefs(std.testing.allocator);
    defer std.testing.allocator.free(refs_after_delete);
    try std.testing.expectEqual(@as(usize, 1024), refs_after_delete.len);
}

test "store edge external key index supports fact and ordered projection lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const src = try store.addNode(.document, "doc");
    try store.setNodeStringProperty(std.testing.allocator, src, "external_key", "doc:one");
    const dst = try store.addNode(.observation, "chunk");
    try store.setNodeStringProperty(std.testing.allocator, dst, "external_key", "content:one");
    const fact_edge = try store.nextEdgeId();
    try store.appendEdgeIndexed(.{ .id = fact_edge, .src = src, .rel = .mentions, .dst = dst });

    const fact_key = try edgeFactExternalKeyAlloc(std.testing.allocator, "doc:one", .mentions, "content:one");
    defer std.testing.allocator.free(fact_key);
    try std.testing.expectEqual(fact_edge, (try store.lookupEdgeByExternalKey(std.testing.allocator, fact_key)).?);

    const ordered_edge = try store.nextEdgeId();
    try store.appendEdgeOrderedIndexed(.{ .id = ordered_edge, .src = src, .rel = @enumFromInt(@as(u16, schema.md_rel_paragraph_id)), .dst = dst }, 2048);

    const ordered_key = try orderedEdgeExternalKeyAlloc(std.testing.allocator, "doc:one", @enumFromInt(@as(u16, schema.md_rel_paragraph_id)), 2048);
    defer std.testing.allocator.free(ordered_key);
    try std.testing.expectEqual(ordered_edge, (try store.lookupEdgeByExternalKey(std.testing.allocator, ordered_key)).?);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_external_key_index_path);
    try std.testing.expectEqual(ordered_edge, (try store.lookupEdgeByExternalKey(std.testing.allocator, ordered_key)).?);
    try std.testing.expect(try store.fileExists(store.edge_external_key_index_path));
}

test "store edge external key lookup falls back when property-derived index is stale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "store" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const src = try store.addNode(.document, "doc");
    const dst = try store.addNode(.observation, "chunk");
    const edge = try store.nextEdgeId();
    try store.appendEdgeIndexed(.{ .id = edge, .src = src, .rel = .mentions, .dst = dst });
    try store.rebuildEdgeExternalKeyIndex();

    try store.setNodeStringProperty(std.testing.allocator, src, "external_key", "doc:late");
    try store.setNodeStringProperty(std.testing.allocator, dst, "external_key", "content:late");

    const key = try edgeFactExternalKeyAlloc(std.testing.allocator, "doc:late", .mentions, "content:late");
    defer std.testing.allocator.free(key);
    try std.testing.expectEqual(edge, (try store.lookupEdgeByExternalKey(std.testing.allocator, key)).?);
}

test "store rejects oversized node text before scanning or mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const huge_ptr: [*]const u8 = @ptrFromInt(1);
    const huge_text = huge_ptr[0 .. storage_data_plane_support.maxBinaryNodeTextLen() + 1];

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(error.RecordTooLarge, store.appendNode(.{
        .id = .fromInt(1),
        .kind = .document,
        .text = huge_text,
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store rejects max node id before mutating event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.testing.expectError(core.Error.InvalidId, store.appendNode(.{
        .id = .fromInt(std.math.maxInt(u64)),
        .kind = .file,
        .text = "max.zig",
    }));
    try std.testing.expectEqual(before, try store.fileSizeOrZero(store.events_bin_path));
}

test "store repairs corrupt node indexes after appending node event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_by_text_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });

    try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "src/other.zig" });
    try std.testing.expect((try store.fileSizeOrZero(store.events_bin_path)) > before);
    var repaired = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
    defer repaired.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/other.zig", repaired.text);
}

test "store repairs corrupt edge indexes after appending edge event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    const before = try store.fileSizeOrZero(store.events_bin_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_src_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });

    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try std.testing.expect((try store.fileSizeOrZero(store.events_bin_path)) > before);
    var records = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer records.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqual(@as(u64, 2), records.items[0].dst);
}

test "store repairs malformed edge index record after appending edge event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .document, .text = "README" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    const before = try store.fileSizeOrZero(store.events_bin_path);

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &[_]u8{1}, EdgeIndexHeader.encoded_len + 26);

    try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions });
    try std.testing.expect((try store.fileSizeOrZero(store.events_bin_path)) > before);
    var records = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer records.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
}

test "store rejects unsorted edge index before binary-search read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "a" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .file, .text = "b.zig" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(3), .dst = .fromInt(2), .rel = .mentions });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const zero_src = [_]u8{0} ** 8;
    try file.writePositionalAll(std.testing.io, &zero_src, EdgeIndexHeader.encoded_len + EdgeIndexRecord.encoded_len);

    try std.testing.expectError(
        error.InvalidRecord,
        store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1)),
    );
}

test "store escapes node texts with separators" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const weird_text = "src/main\tline\nslash\\carriage\r.zig";
    _ = try graph.addNode(.file, weird_text);
    try store.appendNode(graph.nodes.items[0]);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.nodes.items.len);
    try std.testing.expectEqualStrings(weird_text, loaded.nodes.items[0].text);
}

test "store replays records larger than read chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const long_text = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(long_text);
    @memset(long_text, 'x');
    long_text[1024] = '\n';
    long_text[2048] = '\t';
    long_text[4096] = '\\';

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.document, long_text);
    try store.appendNode(graph.nodes.items[0]);

    const stats_out = try store.stats();
    try std.testing.expectEqual(@as(usize, 1), stats_out.nodes);
    try std.testing.expectEqual(@as(usize, 0), stats_out.edges);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.nodes.items.len);
    try std.testing.expectEqualStrings(long_text, loaded.nodes.items[0].text);
}

test "store stats validates checksum beyond counted payload prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const long_text = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(long_text);
    @memset(long_text, 'x');

    try store.appendNode(.{ .id = .fromInt(1), .kind = .document, .text = long_text });

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, store.events_bin_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const corrupt_offset = storage_data_plane_support.BinaryRecordHeader.encoded_len + 10;
    try file.writePositionalAll(std.testing.io, "z", corrupt_offset);

    try std.testing.expectError(error.InvalidRecord, store.stats());
}

test "store loads indexed graph snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    try store.appendNode(graph.nodes.items[0]);

    var snapshot = try store.loadSnapshot();
    defer snapshot.deinit();
    try std.testing.expectEqual(file.toInt(), (try snapshot.index.findByText(.file, "src/main.zig")).?.toInt());
}

test "store repairs stale index metadata during snapshot load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "src/main.zig");
    try store.appendNode(graph.nodes.items[0]);

    var stale_bytes: [index_meta_format.encoded_len]u8 = undefined;
    const stale = IndexMeta{};
    index_meta_format.encode(stale, &stale_bytes);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.index_meta_path,
        .data = &stale_bytes,
        .flags = .{ .truncate = true },
    });

    var snapshot = try store.loadSnapshot();
    defer snapshot.deinit();

    const repaired = try store.readIndexMeta();
    try std.testing.expect(repaired.event_bytes > 0);
    try std.testing.expectEqual(@as(u64, 1), repaired.nodes);
    try std.testing.expectEqual(@as(u64, 0), repaired.edges);
}

test "store snapshot meta can be rebuilt from ensured index headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .task, .text = "snapshot meta" });
    try store.appendEdge(.{ .id = .fromInt(10), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try store.appendEdge(.{ .id = .fromInt(11), .src = .fromInt(2), .dst = .fromInt(3), .rel = .evidences });

    var graph = try store.loadGraph();
    defer graph.deinit();
    try store.ensurePersistentNodeIndexes(&graph);
    try store.ensurePersistentEdgeIndexes(&graph);

    const full = try store.currentIndexMeta(&graph);
    const from_headers = try store.currentIndexMetaFromIndexes(&graph);
    try std.testing.expectEqual(full.event_bytes, from_headers.event_bytes);
    try std.testing.expectEqual(full.nodes, from_headers.nodes);
    try std.testing.expectEqual(full.edges, from_headers.edges);
    try std.testing.expectEqual(full.node_digest, from_headers.node_digest);
    try std.testing.expectEqual(full.edge_digest, from_headers.edge_digest);
    try std.testing.expectEqual(full.edge_indexed_edges, from_headers.edge_indexed_edges);
    try std.testing.expectEqual(full.edge_index_digest, from_headers.edge_index_digest);
    try std.testing.expectEqual(full.max_edge_id_seen, from_headers.max_edge_id_seen);
    try std.testing.expect(storage_data_plane_support.indexMetaEquals(try store.readIndexMeta(), from_headers));

    var stale = from_headers;
    stale.node_by_text_order_digest ^= 1;
    stale.edge_by_src_order_digest ^= 1;
    try store.writeIndexMeta(stale);

    var snapshot = try store.loadSnapshot();
    defer snapshot.deinit();
    try std.testing.expect(storage_data_plane_support.indexMetaEquals(from_headers, try store.readIndexMeta()));
}

test "store rejects persistent reads when index metadata event bytes are stale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });

    var stale = try store.readIndexMeta();
    stale.event_bytes -= 1;
    try store.writeIndexMeta(stale);

    try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, .fromInt(1)));
    try std.testing.expectError(error.InvalidRecord, store.lookupNodesByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));
    try std.testing.expectError(error.InvalidRecord, store.scanNodeIds(std.testing.allocator, .file, 1));
    try std.testing.expectError(error.InvalidRecord, store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1)));
}

test "store defaults to fast reads with explicit full index validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .primary_text_write_mode = .bulk_ingest,
    });
    defer store.deinit();
    try std.testing.expect(!store.options.validate_indexes_on_read);
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    {
        var texts = try std.Io.Dir.cwd().createFile(std.testing.io, store.node_texts_path, .{
            .read = true,
            .truncate = false,
        });
        defer texts.close(std.testing.io);
        try texts.writePositionalAll(std.testing.io, "trailing garbage", (try texts.stat(std.testing.io)).size);
    }

    var node = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/main.zig", node.text);
    try std.testing.expectError(error.InvalidRecord, store.validatePersistentIndexes());
}

test "explicit persistent validation compares edge digest against append log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try store.validatePersistentIndexes();

    var corrupt_meta = try store.readIndexMeta();
    corrupt_meta.edge_digest ^= 0x8000_0000_0000_0000;
    try store.writeIndexMeta(corrupt_meta);

    try std.testing.expectError(error.InvalidRecord, store.validatePersistentIndexes());
}

test "edge meta fast path is header-only while explicit validation scans edge bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(2), .kind = .function, .text = "alpha" },
        .{ .id = .fromInt(3), .kind = .function, .text = "beta" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines },
        .{ .id = .fromInt(2), .src = .fromInt(1), .dst = .fromInt(3), .rel = .mentions },
    });

    const meta = try store.readIndexMeta();
    try std.testing.expect(try store.edgeIndexesMatchMeta(meta));

    var src_file = try std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{ .mode = .read_write });
    defer src_file.close(std.testing.io);
    var corrupt_byte: [1]u8 = undefined;
    const n = try src_file.readPositionalAll(std.testing.io, &corrupt_byte, EdgeIndexHeader.encoded_len);
    try std.testing.expectEqual(@as(usize, 1), n);
    corrupt_byte[0] ^= 0x01;
    try src_file.writePositionalAll(std.testing.io, &corrupt_byte, EdgeIndexHeader.encoded_len);

    try std.testing.expect(try store.edgeIndexesMatchMeta(meta));
    try std.testing.expectError(error.InvalidRecord, store.validatePersistentIndexes());
}

test "explicit persistent validation compares node digest against append log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.validatePersistentIndexes();

    var corrupt_meta = try store.readIndexMeta();
    corrupt_meta.node_digest ^= 0x8000_0000_0000_0000;
    try store.writeIndexMeta(corrupt_meta);

    try std.testing.expectError(error.InvalidRecord, store.validatePersistentIndexes());
}

test "store fast node reads reject stale node catalog digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });

    {
        var corrupt_meta = try store.readIndexMeta();
        corrupt_meta.node_digest ^= 1;
        try store.writeIndexMeta(corrupt_meta);

        try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, .fromInt(1)));
        try std.testing.expectError(error.InvalidRecord, store.lookupNodesByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));
        try std.testing.expectError(error.InvalidRecord, store.lookupNodeIdsByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));
        try std.testing.expectError(error.InvalidRecord, store.scanNodeIds(std.testing.allocator, .file, 1));
    }

    try store.createEmpty();
    {
        var by_id = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_id_path, .{ .mode = .read_write });
        defer by_id.close(std.testing.io);
        var bad_digest: [8]u8 = undefined;
        std.mem.writeInt(u64, &bad_digest, 0, .little);
        try by_id.writePositionalAll(std.testing.io, &bad_digest, 24);

        try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, .fromInt(1)));
        try std.testing.expectError(error.InvalidRecord, store.scanNodeIds(std.testing.allocator, .file, 1));
    }

    try store.createEmpty();
    {
        var by_text = try std.Io.Dir.cwd().openFile(std.testing.io, store.node_by_text_path, .{ .mode = .read_write });
        defer by_text.close(std.testing.io);
        var bad_digest: [8]u8 = undefined;
        std.mem.writeInt(u64, &bad_digest, 0, .little);
        try by_text.writePositionalAll(std.testing.io, &bad_digest, 16);

        try std.testing.expectError(error.InvalidRecord, store.lookupNodesByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));
        try std.testing.expectError(error.InvalidRecord, store.lookupNodeIdsByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));
    }
}

test "store fast node reads reject stale node text order metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });

    var stale_meta = try store.readIndexMeta();
    stale_meta.node_by_text_order_digest ^= 1;
    try store.writeIndexMeta(stale_meta);

    try std.testing.expectError(error.InvalidRecord, store.lookupNodesByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));
    try std.testing.expectError(error.InvalidRecord, store.lookupNodeIdsByTextLimited(std.testing.allocator, .file, "src/main.zig", 1));
    try std.testing.expectError(error.InvalidRecord, store.validatePersistentIndexes());
}

test "store refuses id allocation and append when event log outruns indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });

    var event = std.ArrayList(u8).empty;
    defer event.deinit(std.testing.allocator);
    try appendTestNodeRefEvent(&store, &event, std.testing.allocator, 2, .file, "stale.zig");
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, store.events_bin_path, .{
        .read = true,
        .truncate = false,
    });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, event.items, (try file.stat(std.testing.io)).size);

    try std.testing.expectError(error.InvalidRecord, store.nextNodeId());
    try std.testing.expectError(core.Error.InvalidId, store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "duplicate.zig" }));

    try std.testing.expectEqual(@as(u64, 3), (try store.nextNodeId()).toInt());
    var repaired = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
    defer repaired.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("stale.zig", repaired.text);
}

test "store refuses edge id allocation and append when event log outruns edge indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .document, .text = "README" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });

    var event = std.ArrayList(u8).empty;
    defer event.deinit(std.testing.allocator);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(std.testing.allocator);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 2);
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 1);
    try storage_data_plane_support.appendU16(&payload, std.testing.allocator, @intFromEnum(core.RelKind.mentions));
    try storage_data_plane_support.appendU64(&payload, std.testing.allocator, 3);
    try storage_data_plane_support.appendBinaryRecord(&event, std.testing.allocator, .edge, payload.items);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, store.events_bin_path, .{
        .read = true,
        .truncate = false,
    });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, event.items, (try file.stat(std.testing.io)).size);

    try std.testing.expectError(error.InvalidRecord, store.nextEdgeId());
    try std.testing.expectError(core.Error.InvalidId, store.appendEdge(.{
        .id = .fromInt(2),
        .src = .fromInt(2),
        .dst = .fromInt(3),
        .rel = .references,
    }));

    try std.testing.expectEqual(@as(u64, 3), (try store.nextEdgeId()).toInt());
    var records = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1));
    defer records.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqual(@as(u64, 3), records.items[1].dst);
}

test "store repairs corrupt persistent text index during snapshot load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "src/main.zig");
    try store.appendNode(graph.nodes.items[0]);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.node_by_text_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });

    var snapshot = try store.loadSnapshot();
    defer snapshot.deinit();

    var matches = try store.lookupNodesByTextLimited(std.testing.allocator, .file, "src/main.zig", 1);
    defer {
        for (matches.items) |*node| node.deinit(std.testing.allocator);
        matches.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
}

test "visible base edge iterator bounds tombstone scans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .concept, .text = "source" },
        .{ .id = .fromInt(2), .kind = .concept, .text = "deleted target" },
        .{ .id = .fromInt(3), .kind = .concept, .text = "visible target" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    try store.deleteEdge(.fromInt(1));

    var capped = try store.edgeIndexRecordsByNodeIterator(.src, .fromInt(1));
    defer capped.deinit();
    capped.max_physical_records = 1;
    try std.testing.expectError(core.Error.BudgetExceeded, capped.next());

    var visible = try store.readVisibleEdgeIndexRecordsByNodeLimited(
        std.testing.allocator,
        .src,
        .fromInt(1),
        .mentions,
        1,
    );
    defer visible.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), visible.items.len);
    try std.testing.expectEqual(@as(u64, 2), visible.items[0].edge_id);
}

test "visible edge by-node visitor merges reverse delta overlay and tombstones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const base_segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-base" });
    defer std.testing.allocator.free(base_segment_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "old source" },
        .{ .id = .fromInt(2), .kind = .file, .text = "shared target" },
        .{ .id = .fromInt(3), .kind = .file, .text = "delta source" },
    });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(base_segment_path));
    try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(3), .rel = .defines, .dst = .fromInt(2) });
    try store.deleteEdge(.fromInt(1));
    try store.appendEdge(.{ .id = .fromInt(3), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) });

    var incoming = try store.readVisibleEdgeIndexRecordsByNode(std.testing.allocator, .dst, .fromInt(2), null);
    defer incoming.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), incoming.items.len);
    try std.testing.expectEqual(@as(u64, 2), incoming.items[0].edge_id);
    try std.testing.expectEqual(@as(u64, 3), incoming.items[0].src);

    var old_mentions = try store.readVisibleEdgeIndexRecordsByNode(std.testing.allocator, .src, .fromInt(1), .mentions);
    defer old_mentions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), old_mentions.items.len);
    try std.testing.expectEqual(@as(u64, 3), old_mentions.items[0].edge_id);
    var limited_mentions = try store.readVisibleEdgeIndexRecordsByNodeLimited(std.testing.allocator, .src, .fromInt(1), .mentions, 1);
    defer limited_mentions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), limited_mentions.items.len);
    try std.testing.expectEqual(@as(u64, 3), limited_mentions.items[0].edge_id);

    var retention_registry = EdgeSegmentRetentionRegistry.init(std.testing.allocator);
    defer retention_registry.deinit();
    const RetainedContext = struct {
        registry: *EdgeSegmentRetentionRegistry,
        observed_pin: bool = false,

        fn visit(context: *@This(), record: EdgeIndexRecord) !bool {
            try std.testing.expectEqual(@as(u64, 2), record.edge_id);
            const active_paths = try context.registry.activeManifestPaths(std.testing.allocator);
            defer std.testing.allocator.free(active_paths);
            try std.testing.expectEqual(@as(usize, 1), active_paths.len);
            context.observed_pin = true;
            return true;
        }
    };
    var retained_context = RetainedContext{ .registry = &retention_registry };
    const stopped = try store.forEachVisibleEdgeIndexRecordByNodeRetained(
        std.testing.allocator,
        &retention_registry,
        .src,
        .fromInt(3),
        .defines,
        1,
        &retained_context,
        RetainedContext.visit,
    );
    try std.testing.expect(stopped);
    try std.testing.expect(retained_context.observed_pin);
    const active_paths = try retention_registry.activeManifestPaths(std.testing.allocator);
    defer std.testing.allocator.free(active_paths);
    try std.testing.expectEqual(@as(usize, 0), active_paths.len);
}

test "node rewrite preserves edge segment overlay edges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const base_edge_count = storage_data_plane_support.implicit_edge_delta_segment_min_base_edges;
    const node_count = base_edge_count + 2;

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, @intCast(node_count));
    var node_id: u64 = 1;
    while (node_id <= node_count) : (node_id += 1) {
        const text = try std.fmt.allocPrint(std.testing.allocator, "node-{d}", .{node_id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{
            .id = core.NodeId.fromInt(node_id),
            .kind = .concept,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, @intCast(base_edge_count));
    var edge_id: u64 = 1;
    while (edge_id <= base_edge_count) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = core.EdgeId.fromInt(edge_id),
            .src = core.NodeId.fromInt(1),
            .dst = core.NodeId.fromInt(edge_id + 1),
            .rel = .mentions,
        });
    }
    try store.appendEdgesBatch(base_edges.items);

    try store.appendEdge(.{
        .id = core.EdgeId.fromInt(base_edge_count + 1),
        .src = core.NodeId.fromInt(1),
        .dst = core.NodeId.fromInt(node_count),
        .rel = .evidences,
    });
    const overlay_meta = try store.readCurrentIndexMeta();
    try std.testing.expectEqual(base_edge_count + 1, overlay_meta.edges);
    try std.testing.expectEqual(base_edge_count, overlay_meta.edge_indexed_edges);

    const result = try store.updateNode(core.NodeId.fromInt(1), .decision, "updated root node");
    try std.testing.expectEqual(node_count, result.nodes_rewritten);
    try std.testing.expectEqual(base_edge_count + 1, result.edges_rewritten);
    try std.testing.expectEqual(@as(u64, 0), result.edges_removed);

    const rewritten_stats = try store.stats();
    try std.testing.expectEqual(node_count, rewritten_stats.nodes);
    try std.testing.expectEqual(base_edge_count + 1, rewritten_stats.edges);

    const rewritten_meta = try store.readCurrentIndexMeta();
    try std.testing.expectEqual(base_edge_count + 1, rewritten_meta.edges);
    try std.testing.expectEqual(base_edge_count + 1, rewritten_meta.edge_indexed_edges);

    var src_records = try store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, core.NodeId.fromInt(1));
    defer src_records.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, @intCast(base_edge_count + 1)), src_records.items.len);
    try std.testing.expectEqual(base_edge_count + 1, src_records.items[src_records.items.len - 1].edge_id);

    var graph = try store.loadGraph();
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, @intCast(node_count)), graph.nodes.items.len);
    var active_edges: usize = 0;
    var overlay_edge_found = false;
    for (graph.edges.items) |edge| {
        if (edge.status != .active) continue;
        active_edges += 1;
        if (edge.id.toInt() == base_edge_count + 1 and
            edge.src.toInt() == 1 and
            edge.dst.toInt() == node_count and
            edge.rel == .evidences)
        {
            overlay_edge_found = true;
        }
    }
    try std.testing.expectEqual(@as(usize, @intCast(base_edge_count + 1)), active_edges);
    try std.testing.expect(overlay_edge_found);
}

test "node rewrite preserves schema catalog and store format manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    _ = try store.addNode(.task, "task before rewrite");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "status", "completed");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, "task_completed_ns", 123);

    var registry = schema.Registry.init(std.testing.allocator);
    errdefer registry.deinit();
    try registry.addKernelTypes();
    try registry.addBuiltinProfile(.agent_dag);
    var cat = try catalog_mod.Catalog.fromRegistry(std.testing.allocator, registry);
    registry = schema.Registry.init(std.testing.allocator);
    defer cat.deinit();
    try store.writeCatalog(cat);

    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, ".tinykg", "store-manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    const manifest_dir = std.fs.path.dirname(manifest_path) orelse return error.TestUnexpectedResult;
    try std.Io.Dir.cwd().createDirPath(std.testing.io, manifest_dir);
    const manifest =
        \\{"store_manifest_version":1,"storage_format_version":2,"schema":{"schema_version":3,"enabled_profiles":["agent-dag"]}}
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = manifest,
        .flags = .{ .truncate = true },
    });

    const catalog_before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, store.catalog_path, std.testing.allocator, .limited(catalog_max_bytes));
    defer std.testing.allocator.free(catalog_before);

    _ = try store.updateNode(.fromInt(1), .task, "task after rewrite");

    const catalog_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, store.catalog_path, std.testing.allocator, .limited(catalog_max_bytes));
    defer std.testing.allocator.free(catalog_after);
    try std.testing.expectEqualSlices(u8, catalog_before, catalog_after);

    const manifest_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(manifest_after);
    try std.testing.expectEqualStrings(manifest, manifest_after);

    var decoded = (try store.readCatalog()) orelse return error.TestUnexpectedResult;
    defer decoded.deinit();
    try std.testing.expect(decoded.registry.hasNodeTypeId(@intFromEnum(core.NodeKind.task)));
    const status_after = (try store.getNodeStringProperty(std.testing.allocator, .fromInt(1), "status")).?;
    defer std.testing.allocator.free(status_after);
    try std.testing.expectEqualStrings("completed", status_after);
    try std.testing.expectEqual(@as(?u64, 123), try store.getUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, "task_completed_ns"));
}

test "node delete preserves unrelated latest property payload entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .concept, .text = "delete me" },
        .{ .id = .fromInt(2), .kind = .concept, .text = "survivor" },
        .{ .id = .fromInt(3), .kind = .concept, .text = "other" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .id = .fromInt(2), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(3) },
    });

    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "name", "deleted-owner");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "name", "survivor-base");
    try store.setEdgeStringProperty(std.testing.allocator, .fromInt(1), "created_by", "deleted-edge");
    try store.setEdgeStringProperty(std.testing.allocator, .fromInt(2), "created_by", "survivor-edge-base");
    const compacted = try store.compactPropertyPayloadDelta(std.testing.allocator);
    try std.testing.expect(compacted.compacted);
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "name", "survivor-delta");
    try store.setEdgeStringProperty(std.testing.allocator, .fromInt(2), "created_by", "survivor-edge-delta");

    const deleted = try store.deleteNode(.fromInt(1));
    try std.testing.expectEqual(@as(u64, 1), deleted.edges_removed);

    const survivor_name = (try store.getNodeStringProperty(std.testing.allocator, .fromInt(2), "name")).?;
    defer std.testing.allocator.free(survivor_name);
    try std.testing.expectEqualStrings("survivor-delta", survivor_name);
    const survivor_edge = (try store.getEdgeStringProperty(std.testing.allocator, .fromInt(2), "created_by")).?;
    defer std.testing.allocator.free(survivor_edge);
    try std.testing.expectEqualStrings("survivor-edge-delta", survivor_edge);
    try std.testing.expect((try store.getNodeStringProperty(std.testing.allocator, .fromInt(1), "name")) == null);
    var removed_edge_property = try store.readPropertyPayloadEntryForKey(std.testing.allocator, .{ .edge = .fromInt(1) }, "created_by");
    defer if (removed_edge_property) |*entry| entry.deinit(std.testing.allocator);
    try std.testing.expect(removed_edge_property == null);
}
