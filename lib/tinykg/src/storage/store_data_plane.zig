/// Transitional coarse Store data-plane owner. The stable Store façade keeps
/// public/private method visibility while this owner is split further by
/// mutation, property, node-text and edge-segment responsibilities.
pub fn StoreDataPlane(comptime Ops: type) type {
    return struct {
        const Store = Ops.dep_Store;
        const node_catalog_index = Ops.dep_owners.node_catalog_index_owner;
        const std = Ops.dep_std;
        const builtin = Ops.dep_builtin;
        const core = Ops.dep_core;
        const graph_mod = Ops.dep_graph_mod;
        const schema = Ops.dep_schema;
        const catalog_mod = Ops.dep_catalog_mod;
        const catalog_max_bytes = Ops.dep_catalog_max_bytes;
        const segment_mod = Ops.dep_segment_mod;
        const segment_bundle = Ops.dep_segment_bundle;
        const segment_manifest = Ops.dep_segment_manifest;
        const segment_node_index = Ops.dep_segment_node_index;
        const snapshot_mod = Ops.dep_snapshot_mod;
        const read_only_memory_map = Ops.dep_read_only_memory_map;
        const edge_order_format = Ops.dep_edge_order_format;
        const index_meta_format = Ops.dep_index_meta_format;
        const edge_segment_manifest_format = Ops.dep_edge_segment_manifest_format;
        const node_text_run_manifest_format = Ops.dep_node_text_run_manifest_format;
        const retention = Ops.dep_retention;
        const store_paths_mod = Ops.dep_store_paths_mod;
        const EdgeTombstoneHeader = Ops.dep_support.EdgeTombstoneHeader;
        const EdgeTombstoneRecord = Ops.dep_support.EdgeTombstoneRecord;
        const EdgeIndexOrder = Ops.dep_EdgeIndexOrder;
        const EdgeIndexRelDerivation = Ops.dep_support.EdgeIndexRelDerivation;
        const EdgeIndexDenseKeyRunSpan = Ops.dep_support.EdgeIndexDenseKeyRunSpan;
        const EdgeIndexHeader = Ops.dep_EdgeIndexHeader;
        const EdgeIndexRecord = Ops.dep_EdgeIndexRecord;
        const EdgeIndexKeyRunRecord = Ops.dep_support.EdgeIndexKeyRunRecord;
        const edgeIndexKeyRunRecordLen = Ops.dep_support.edgeIndexKeyRunRecordLen;
        const edgeIndexKeyRunDirectorySizeForHeader = Ops.dep_support.edgeIndexKeyRunDirectorySizeForHeader;
        const edgeIndexKeyRunOffsetForHeader = Ops.dep_support.edgeIndexKeyRunOffsetForHeader;
        const EdgeOrderHeader = Ops.dep_support.EdgeOrderHeader;
        const EdgeOrderRecord = Ops.dep_EdgeOrderRecord;
        const EdgeOrderRecordVisitor = Ops.dep_EdgeOrderRecordVisitor;
        const ExternalKeyIndexHeader = Ops.dep_support.ExternalKeyIndexHeader;
        const ExternalKeyIndexRecord = Ops.dep_support.ExternalKeyIndexRecord;
        const EdgeExternalKeyIndexHeader = Ops.dep_support.EdgeExternalKeyIndexHeader;
        const EdgeExternalKeyIndexRecord = Ops.dep_support.EdgeExternalKeyIndexRecord;
        const EdgeSegmentIdRunSummary = Ops.dep_support.EdgeSegmentIdRunSummary;
        const IndexMeta = Ops.dep_IndexMeta;
        const NodeByIdHeader = Ops.dep_NodeByIdHeader;
        const NodeByIdRecord = Ops.dep_NodeByIdRecord;
        const NodeTextIndexHeader = Ops.dep_NodeTextIndexHeader;
        const NodeTextIndexRecord = Ops.dep_NodeTextIndexRecord;
        const NodePropertyIndexHeader = Ops.dep_support.NodePropertyIndexHeader;
        const NodePropertyIndexRecord = Ops.dep_support.NodePropertyIndexRecord;
        const PropertyPayloadIndexHeader = Ops.dep_support.PropertyPayloadIndexHeader;
        const PropertyPayloadIndexRecord = Ops.dep_support.PropertyPayloadIndexRecord;
        const PropertyPayloadDeltaHeader = Ops.dep_support.PropertyPayloadDeltaHeader;
        const NodePropertyValueBlockHeader = Ops.dep_support.NodePropertyValueBlockHeader;
        const NodePropertyValueRecord = Ops.dep_support.NodePropertyValueRecord;
        const property_payload_delta_header_len = Ops.dep_support.property_payload_delta_header_len;
        const property_payload_delta_entry_len = Ops.dep_support.property_payload_delta_entry_len;
        const property_payload_delta_digest_seed = Ops.dep_support.property_payload_delta_digest_seed;
        const property_snapshot_legacy_version = Ops.dep_support.property_snapshot_legacy_version;
        const property_snapshot_base_version = Ops.dep_support.property_snapshot_base_version;
        const property_snapshot_delta_version_base = Ops.dep_support.property_snapshot_delta_version_base;
        const StorageOptions = Ops.dep_StorageOptions;
        const NodeExternalKeyLookupEntry = Ops.dep_support.NodeExternalKeyLookupEntry;
        const NodeExternalKeyLookupCache = Ops.dep_NodeExternalKeyLookupCache;
        const EdgeExternalKeyLookupCache = Ops.dep_EdgeExternalKeyLookupCache;
        const currentProcessIdForTempPath = Ops.dep_support.currentProcessIdForTempPath;
        const EdgeSegmentMaintenanceBudget = Ops.dep_EdgeSegmentMaintenanceBudget;
        const EdgeSegmentMaintenanceResult = Ops.dep_EdgeSegmentMaintenanceResult;
        const EdgeSegmentGcResult = Ops.dep_EdgeSegmentGcResult;
        const EdgeSegmentRetentionWindow = Ops.dep_EdgeSegmentRetentionWindow;
        const EdgeSegmentRetentionRegistry = Ops.dep_EdgeSegmentRetentionRegistry;
        const EdgeSegmentRegisteredRetentionWindow = Ops.dep_EdgeSegmentRegisteredRetentionWindow;
        const NodeTextRunRetentionRegistry = Ops.dep_NodeTextRunRetentionRegistry;
        const NodeTextRunRegisteredRetentionWindow = Ops.dep_NodeTextRunRegisteredRetentionWindow;
        const manifest_process_lease = Ops.dep_support.manifest_process_lease;
        const ManifestProcessLeaseKind = Ops.dep_support.ManifestProcessLeaseKind;
        const edge_segment_gc = Ops.dep_support.edge_segment_gc;
        const node_text_run_gc = Ops.dep_support.node_text_run_gc;
        const store_temp_nonce = Ops.dep_store_temp_nonce;
        const repair_session = Ops.dep_support.repair_session;
        const PersistentRepairTimings = Ops.dep_PersistentRepairTimings;
        const edge_segment_publication = Ops.dep_support.edge_segment_publication;
        const NodeTextsCompressionResult = Ops.dep_NodeTextsCompressionResult;
        const PersistentValidateTimings = Ops.dep_PersistentValidateTimings;
        const edgeSegmentIdRunSummariesEqual = Ops.dep_support.edgeSegmentIdRunSummariesEqual;
        const NodeTextDeltaMaintenanceResult = Ops.dep_NodeTextDeltaMaintenanceResult;
        const NodeTextRunMaintenanceResult = Ops.dep_NodeTextRunMaintenanceResult;
        const NodeTextRunGcResult = Ops.dep_NodeTextRunGcResult;
        const StoreStats = Ops.dep_StoreStats;
        const EventCountState = Ops.dep_support.EventCountState;
        const storage_write_buffer_bytes = Ops.dep_support.storage_write_buffer_bytes;
        const edge_segment_current_max_path_bytes = Ops.dep_support.edge_segment_current_max_path_bytes;
        const implicit_edge_delta_segment_min_base_edges = Ops.dep_support.implicit_edge_delta_segment_min_base_edges;
        const edge_repair_sort_chunk_records = Ops.dep_support.edge_repair_sort_chunk_records;
        const edge_index_repair_key_run_memory_cap = Ops.dep_support.edge_index_repair_key_run_memory_cap;
        const edge_segment_id_sort_chunk_records = Ops.dep_support.edge_segment_id_sort_chunk_records;
        const node_text_delta_max_records = Ops.dep_support.node_text_delta_max_records;
        const node_text_single_append_delta_flush_records = Ops.dep_support.node_text_single_append_delta_flush_records;
        const node_text_run_manifest_max_entries = Ops.dep_support.node_text_run_manifest_max_entries;
        const node_text_run_max_records = Ops.dep_support.node_text_run_max_records;
        const node_text_run_current_max_path_bytes = Ops.dep_support.node_text_run_current_max_path_bytes;
        const NodeIndexSeenIds = Ops.dep_support.NodeIndexSeenIds;
        const NodeTextValidationHashes = Ops.dep_support.NodeTextValidationHashes;
        const StorageBufferedWriter = Ops.dep_support.StorageBufferedWriter;
        const storageWriteBufferCapacity = Ops.dep_support.storageWriteBufferCapacity;
        const externalKeyIndexRecordLessThan = Ops.dep_support.externalKeyIndexRecordLessThan;
        const externalKeyHash = Ops.dep_support.externalKeyHash;
        const externalKeyIndexFileSize = Ops.dep_support.externalKeyIndexFileSize;
        const externalKeyIndexRecordOffset = Ops.dep_support.externalKeyIndexRecordOffset;
        const NodePropertyIndexEntry = Ops.dep_support.NodePropertyIndexEntry;
        const deinitNodePropertyIndexEntries = Ops.dep_support.deinitNodePropertyIndexEntries;
        const PropertyPayloadIndexEntry = Ops.dep_support.PropertyPayloadIndexEntry;
        const PropertyPayloadDeltaScan = Ops.dep_support.PropertyPayloadDeltaScan;
        const deinitPropertyPayloadIndexEntries = Ops.dep_support.deinitPropertyPayloadIndexEntries;
        const nodePropertyIndexRecordLessThan = Ops.dep_support.nodePropertyIndexRecordLessThan;
        const nodePropertyIndexEntryLessThan = Ops.dep_support.nodePropertyIndexEntryLessThan;
        const edgeExternalKeyIndexRecordLessThan = Ops.dep_support.edgeExternalKeyIndexRecordLessThan;
        const nodePropertyKeyHash = Ops.dep_support.nodePropertyKeyHash;
        const nodePropertyValueHash = Ops.dep_support.nodePropertyValueHash;
        const edgeExternalKeyHash = Ops.dep_support.edgeExternalKeyHash;
        const edgeFactExternalKeyAlloc = Ops.dep_edgeFactExternalKeyAlloc;
        const orderedEdgeExternalKeyAlloc = Ops.dep_orderedEdgeExternalKeyAlloc;
        const nodePropertyIndexFileSize = Ops.dep_support.nodePropertyIndexFileSize;
        const nodePropertyIndexRecordOffset = Ops.dep_support.nodePropertyIndexRecordOffset;
        const nodePropertyValueBlockHeaderAndRecordBytes = Ops.dep_support.nodePropertyValueBlockHeaderAndRecordBytes;
        const nodePropertyValueBlockFileSize = Ops.dep_support.nodePropertyValueBlockFileSize;
        const nodePropertyValueRecordOffset = Ops.dep_support.nodePropertyValueRecordOffset;
        const propertyPayloadIndexFileSize = Ops.dep_support.propertyPayloadIndexFileSize;
        const propertyPayloadIndexRecordOffset = Ops.dep_support.propertyPayloadIndexRecordOffset;
        const edgeExternalKeyIndexFileSize = Ops.dep_support.edgeExternalKeyIndexFileSize;
        const edgeExternalKeyIndexRecordOffset = Ops.dep_support.edgeExternalKeyIndexRecordOffset;
        const nodePropertyStringKeySupported = Ops.dep_support.nodePropertyStringKeySupported;
        const nodePropertyUintKeySupported = Ops.dep_support.nodePropertyUintKeySupported;
        const nodePropertyOverlayStringKeySupported = Ops.dep_support.nodePropertyOverlayStringKeySupported;
        const edgePropertyOverlayStringKeySupported = Ops.dep_support.edgePropertyOverlayStringKeySupported;
        const nodePropertyPayloadUintKeySupported = Ops.dep_support.nodePropertyPayloadUintKeySupported;
        const propertyKeyNameValid = Ops.dep_support.propertyKeyNameValid;
        const stringPropertyKeySupportedForOwner = Ops.dep_support.stringPropertyKeySupportedForOwner;
        const uintPropertyKeySupportedForOwner = Ops.dep_support.uintPropertyKeySupportedForOwner;
        const propertyPayloadOwnerFromParts = Ops.dep_support.propertyPayloadOwnerFromParts;
        const propertyPayloadRecordLessThan = Ops.dep_support.propertyPayloadRecordLessThan;
        const propertyPayloadEntryLessThan = Ops.dep_support.propertyPayloadEntryLessThan;
        const propertyPayloadEntryMatchesOwnerKey = Ops.dep_support.propertyPayloadEntryMatchesOwnerKey;
        const PropertyPayloadOwnerKey = Ops.dep_support.PropertyPayloadOwnerKey;
        const PropertyPayloadOwnerKeySet = Ops.dep_support.PropertyPayloadOwnerKeySet;
        const PropertyPayloadNodeIdSet = Ops.dep_support.PropertyPayloadNodeIdSet;
        const PropertyPayloadOwnerFilter = Ops.dep_support.PropertyPayloadOwnerFilter;
        const PropertyPayloadLookupTarget = Ops.dep_support.PropertyPayloadLookupTarget;
        const SearchablePropertyByteBudget = Ops.dep_support.SearchablePropertyByteBudget;
        const PropertyPayloadIndexedTarget = Ops.dep_support.PropertyPayloadIndexedTarget;
        const PropertyPayloadKeyNameMap = Ops.dep_support.PropertyPayloadKeyNameMap;
        const PropertyPayloadSnapshotTarget = Ops.dep_support.PropertyPayloadSnapshotTarget;
        const PropertyPayloadDeltaTarget = Ops.dep_support.PropertyPayloadDeltaTarget;
        const propertyPayloadOwnerKey = Ops.dep_support.propertyPayloadOwnerKey;
        const appendStringPropertyPayloadRecord = Ops.dep_support.appendStringPropertyPayloadRecord;
        const appendUintPropertyPayloadRecord = Ops.dep_support.appendUintPropertyPayloadRecord;
        const appendNodePropertyRecordsFromText = Ops.dep_support.appendNodePropertyRecordsFromText;
        const nodePropertyValueFromTextAlloc = Ops.dep_support.nodePropertyValueFromTextAlloc;
        const nodePropertyUintValueFromText = Ops.dep_support.nodePropertyUintValueFromText;
        const NodeTextRunManifestEntry = Ops.dep_support.NodeTextRunManifestEntry;
        const OwnedNodeTextRunManifestEntry = Ops.dep_support.OwnedNodeTextRunManifestEntry;
        const NodeTextRunManifest = Ops.dep_support.NodeTextRunManifest;
        const NodeTextBaseHashFilter = Ops.dep_support.NodeTextBaseHashFilter;
        const NodeTextBaseHashFilterHeader = Ops.dep_support.NodeTextBaseHashFilterHeader;
        const StoredNode = Ops.dep_StoredNode;
        const StoredEdgeRef = Ops.dep_StoredEdgeRef;
        const NodeRewriteResult = Ops.dep_NodeRewriteResult;
        const PropertyOwner = Ops.dep_PropertyOwner;
        const PropertyPayloadWrite = Ops.dep_PropertyPayloadWrite;
        const SortedPropertyPayloadNext = Ops.dep_SortedPropertyPayloadNext;
        const PropertyPayloadUpsertResult = Ops.dep_PropertyPayloadUpsertResult;
        const PropertyPayloadCompactionResult = Ops.dep_PropertyPayloadCompactionResult;
        const PropertySnapshotValueKind = Ops.dep_PropertySnapshotValueKind;
        const PropertySnapshotEntry = Ops.dep_PropertySnapshotEntry;
        const PropertySnapshot = Ops.dep_PropertySnapshot;
        const PropertySnapshotLayerEntry = Ops.dep_PropertySnapshotLayerEntry;
        const PropertySnapshotLayerVisitor = Ops.dep_PropertySnapshotLayerVisitor;
        const EdgeIndexRecordVisitor = Ops.dep_EdgeIndexRecordVisitor;
        const NodeIndexLayoutHint = Ops.dep_NodeIndexLayoutHint;
        const TextSpan = Ops.dep_support.TextSpan;
        const store_bootstrap = Ops.dep_support.store_bootstrap;
        const persistent_rebuild_pipeline = Ops.dep_support.persistent_rebuild_pipeline;
        const node_text_repair_index_publication = Ops.dep_support.node_text_repair_index_publication;
        const edge_repair_index_publication = Ops.dep_support.edge_repair_index_publication;
        const edge_tombstone_repair_index_publication = Ops.dep_support.edge_tombstone_repair_index_publication;
        const property_payload_transaction = Ops.dep_support.property_payload_transaction;
        const primary_node_text = Ops.dep_support.primary_node_text;
        const store_cache_resources = Ops.dep_support.store_cache_resources;
        const store_opening = Ops.dep_support.store_opening;
        const edge_segment_query_opening = Ops.dep_support.edge_segment_query_opening;
        const edge_segment_window_compaction = Ops.dep_support.edge_segment_window_compaction;
        const edge_segment_maintenance = Ops.dep_support.edge_segment_maintenance;
        const StorageNodeTextLookupContext = Ops.dep_support.StorageNodeTextLookupContext;
        const node_text_lookup_view_data_plane = Ops.dep_support.node_text_lookup_view_data_plane;
        const StorageNodeTextCatalogContext = Ops.dep_support.StorageNodeTextCatalogContext;
        const node_text_catalog_transaction = Ops.dep_support.node_text_catalog_transaction;
        const node_text_maintenance = Ops.dep_support.node_text_maintenance;
        const selfOptionsNeedSync = Ops.dep_support.selfOptionsNeedSync;
        const storageMonotonicNs = Ops.dep_support.storageMonotonicNs;
        const storageElapsedNs = Ops.dep_support.storageElapsedNs;
        const indexMetaEquals = Ops.dep_support.indexMetaEquals;
        const segmentManifestUniqueEntry = Ops.dep_support.segmentManifestUniqueEntry;
        const segmentManifestHasEdgeEntry = Ops.dep_support.segmentManifestHasEdgeEntry;
        const segmentManifestEdgeEntries = Ops.dep_support.segmentManifestEdgeEntries;
        const segmentManifestEdgeCount = Ops.dep_support.segmentManifestEdgeCount;
        const segmentManifestEdgeDigest = Ops.dep_support.segmentManifestEdgeDigest;
        const clearEdgeSegmentSummary = Ops.dep_support.clearEdgeSegmentSummary;
        const edgeOrderDigestForMeta = Ops.dep_support.edgeOrderDigestForMeta;
        const edgeIndexByIdLessThan = Ops.dep_support.edgeIndexByIdLessThan;
        const edgeIndexLessThan = Ops.dep_support.edgeIndexLessThan;
        const edgeIndexBatchSorted = Ops.dep_support.edgeIndexBatchSorted;
        const edgeRecordsAreDenseIdTail = Ops.dep_support.edgeRecordsAreDenseIdTail;
        const edgeRecordHasU32NodeIds = Ops.dep_support.edgeRecordHasU32NodeIds;
        const edgeRecordsHaveU32NodeIds = Ops.dep_support.edgeRecordsHaveU32NodeIds;
        const edgeRecordHasU32EdgeId = Ops.dep_support.edgeRecordHasU32EdgeId;
        const edgeRecordsHaveU32EdgeIds = Ops.dep_support.edgeRecordsHaveU32EdgeIds;
        const edgeIndexHeaderWithBeneficialKeyRuns = Ops.dep_support.edgeIndexHeaderWithBeneficialKeyRuns;
        const denseEdgeIdRunSummaryForHeader = Ops.dep_support.denseEdgeIdRunSummaryForHeader;
        const edgeIndexIdEndpointCanStartRun = Ops.dep_support.edgeIndexIdEndpointCanStartRun;
        const edgeIndexDenseKeyRunSpanRecordForIndex = Ops.dep_support.edgeIndexDenseKeyRunSpanRecordForIndex;
        const edgeIndexKeyRunRecordsEquivalent = Ops.dep_support.edgeIndexKeyRunRecordsEquivalent;
        const edgeIndexMaybeBetterDenseKeyRunSpan = Ops.dep_support.edgeIndexMaybeBetterDenseKeyRunSpan;
        const edgeIndexNextRunStartForHeaderShape = Ops.dep_support.edgeIndexNextRunStartForHeaderShape;
        const edgeIndexRunRecordForStart = Ops.dep_support.edgeIndexRunRecordForStart;
        const edgeIndexRecordOpposite = Ops.dep_support.edgeIndexRecordOpposite;
        const validateAdjacentEdgeIndexKeyRuns = Ops.dep_support.validateAdjacentEdgeIndexKeyRuns;
        const nodeTextLenFitsU16 = Ops.dep_support.nodeTextLenFitsU16;
        const nodeRecordHasShortTextLen = Ops.dep_support.nodeRecordHasShortTextLen;
        const edge_index_rel_kind_count = Ops.dep_support.edge_index_rel_kind_count;
        const edgeIndexDefaultRelFromCounts = Ops.dep_support.edgeIndexDefaultRelFromCounts;
        const edgeIndexRelDerivationAddException = Ops.dep_support.edgeIndexRelDerivationAddException;
        const edgeRecordsDerivedRel = Ops.dep_support.edgeRecordsDerivedRel;
        const edgeRecordsExtendDerivedRel = Ops.dep_support.edgeRecordsExtendDerivedRel;
        const edgeIndexRelDerivationWithoutRecord = Ops.dep_support.edgeIndexRelDerivationWithoutRecord;
        const edgeIndexRecordToSegmentEdge = Ops.dep_support.edgeIndexRecordToSegmentEdge;
        const EdgeIndexRecordReader = Ops.dep_support.EdgeIndexRecordReader;
        const edgeIndexReaderRecordToSegmentEdge = Ops.dep_support.edgeIndexReaderRecordToSegmentEdge;
        const StoreTextsFileStream = Ops.dep_support.StoreTextsFileStream;
        const StoreCatalogByIdStream = Ops.dep_support.StoreCatalogByIdStream;
        const StoreEdgeRecordStream = Ops.dep_support.StoreEdgeRecordStream;
        const EdgeSortedRunStream = Ops.dep_support.EdgeSortedRunStream;
        const EdgeSortedRecordSliceStream = Ops.dep_support.EdgeSortedRecordSliceStream;
        const EdgeSortedRecordOrderStream = Ops.dep_support.EdgeSortedRecordOrderStream;
        const StoreSegmentBundleExactRuns = Ops.dep_support.StoreSegmentBundleExactRuns;
        const StoreSegmentBundleExactStream = Ops.dep_support.StoreSegmentBundleExactStream;
        const EdgeSegmentManifestEntry = Ops.dep_support.EdgeSegmentManifestEntry;
        const EdgeSegmentIdSidecarSummary = Ops.dep_support.EdgeSegmentIdSidecarSummary;
        const EdgeSegmentManifestSummary = Ops.dep_support.EdgeSegmentManifestSummary;
        const EdgeSegmentIdRunRange = Ops.dep_support.EdgeSegmentIdRunRange;
        const edgeSegmentIdRunRangeLessThan = Ops.dep_support.edgeSegmentIdRunRangeLessThan;
        const appendEdgeSegmentManifestRunRangeSorted = Ops.dep_support.appendEdgeSegmentManifestRunRangeSorted;
        const EdgeSegmentIdRunBuilder = Ops.dep_support.EdgeSegmentIdRunBuilder;
        const OwnedEdgeSegmentManifestEntry = Ops.dep_support.OwnedEdgeSegmentManifestEntry;
        const EdgeSegmentManifest = Ops.dep_support.EdgeSegmentManifest;
        const edge_segment_manifest_src_single = Ops.dep_support.edge_segment_manifest_src_single;
        const edge_segment_manifest_src_full = Ops.dep_support.edge_segment_manifest_src_full;
        const edge_segment_manifest_dst_single = Ops.dep_support.edge_segment_manifest_dst_single;
        const edge_segment_manifest_dst_full = Ops.dep_support.edge_segment_manifest_dst_full;
        const edge_segment_manifest_path_relative = Ops.dep_support.edge_segment_manifest_path_relative;
        const edge_segment_manifest_virtual_singleton = Ops.dep_support.edge_segment_manifest_virtual_singleton;
        const EdgeSegmentManifestPathEncoding = Ops.dep_support.EdgeSegmentManifestPathEncoding;
        const edgeSegmentManifestSafeRelativePath = Ops.dep_support.edgeSegmentManifestSafeRelativePath;
        const freeOwnedManifestPathList = Ops.dep_support.freeOwnedManifestPathList;
        const edgeSegmentManifestEntryMayContainNode = Ops.dep_support.edgeSegmentManifestEntryMayContainNode;
        const edgeSegmentManifestEntryIsVirtual = Ops.dep_support.edgeSegmentManifestEntryIsVirtual;
        const edgeSegmentManifestValidateVirtualEntry = Ops.dep_support.edgeSegmentManifestValidateVirtualEntry;
        const extendVirtualEdgeRun = Ops.dep_support.extendVirtualEdgeRun;
        const EdgeSegmentIdIndex = Ops.dep_support.EdgeSegmentIdIndex;
        const edge_segment_id_index_stack_scan_max = Ops.dep_support.edge_segment_id_index_stack_scan_max;
        const EdgeSegmentIdIndexHeader = Ops.dep_support.EdgeSegmentIdIndexHeader;
        const EdgeSegmentIdIndexWriter = Ops.dep_support.EdgeSegmentIdIndexWriter;
        const PublishedEdgeSegments = Ops.dep_PublishedEdgeSegments;
        const PublishedEdgeSegmentsCoverage = Ops.dep_PublishedEdgeSegmentsCoverage;
        const PublishedEdgeSegmentsForQuery = Ops.dep_PublishedEdgeSegmentsForQuery;
        const EdgeSegmentMergeStream = Ops.dep_support.EdgeSegmentMergeStream;
        const BaseAndSegmentMergeStream = Ops.dep_support.BaseAndSegmentMergeStream;
        const encodeEdgeSegmentManifestHeader = Ops.dep_support.encodeEdgeSegmentManifestHeader;
        const edgeSegmentManifestRunsCoverEntry = Ops.dep_support.edgeSegmentManifestRunsCoverEntry;
        const edgeSegmentManifestCanDeriveEdgeIdDigest = Ops.dep_support.edgeSegmentManifestCanDeriveEdgeIdDigest;
        const edgeSegmentManifestOrderDigestExtraLen = Ops.dep_support.edgeSegmentManifestOrderDigestExtraLen;
        const writeEdgeSegmentManifestOrderDigestExtra = Ops.dep_support.writeEdgeSegmentManifestOrderDigestExtra;
        const encodeEdgeSegmentManifestRunEncoding = Ops.dep_support.encodeEdgeSegmentManifestRunEncoding;
        const decodeEdgeSegmentManifestRunEncoding = Ops.dep_support.decodeEdgeSegmentManifestRunEncoding;
        const deriveEdgeSegmentManifestEdgeCountFromRunEncoding = Ops.dep_support.deriveEdgeSegmentManifestEdgeCountFromRunEncoding;
        const edgeSegmentManifestRunExtraLen = Ops.dep_support.edgeSegmentManifestRunExtraLen;
        const writeEdgeSegmentManifestRunExtra = Ops.dep_support.writeEdgeSegmentManifestRunExtra;
        const edgeSegmentManifestEdgeCountExtraLen = Ops.dep_support.edgeSegmentManifestEdgeCountExtraLen;
        const writeEdgeSegmentManifestEdgeCountExtra = Ops.dep_support.writeEdgeSegmentManifestEdgeCountExtra;
        const edgeSegmentManifestDigestExtraLen = Ops.dep_support.edgeSegmentManifestDigestExtraLen;
        const writeEdgeSegmentManifestDigestExtra = Ops.dep_support.writeEdgeSegmentManifestDigestExtra;
        const encodeEdgeSegmentManifestEndpointEncoding = Ops.dep_support.encodeEdgeSegmentManifestEndpointEncoding;
        const edgeSegmentManifestEndpointExtraLen = Ops.dep_support.edgeSegmentManifestEndpointExtraLen;
        const writeEdgeSegmentManifestEndpointExtra = Ops.dep_support.writeEdgeSegmentManifestEndpointExtra;
        const edgeSegmentManifestSingletonRelExtraLen = Ops.dep_support.edgeSegmentManifestSingletonRelExtraLen;
        const writeEdgeSegmentManifestSingletonRelExtra = Ops.dep_support.writeEdgeSegmentManifestSingletonRelExtra;
        const decodeEdgeSegmentManifestEndpointRanges = Ops.dep_support.decodeEdgeSegmentManifestEndpointRanges;
        const encodeEdgeSegmentManifestEntryHeaderForPath = Ops.dep_support.encodeEdgeSegmentManifestEntryHeaderForPath;
        const decodeEdgeSegmentManifestHeader = Ops.dep_support.decodeEdgeSegmentManifestHeader;
        const decodeEdgeSegmentManifestEntryHeader = Ops.dep_support.decodeEdgeSegmentManifestEntryHeader;
        const encodeEdgeSegmentIdIndexHeader = Ops.dep_support.encodeEdgeSegmentIdIndexHeader;
        const decodeEdgeSegmentIdIndexHeader = Ops.dep_support.decodeEdgeSegmentIdIndexHeader;
        const edgeSegmentIdIndexFileSize = Ops.dep_support.edgeSegmentIdIndexFileSize;
        const edgeSegmentIdDigest = Ops.dep_support.edgeSegmentIdDigest;
        const edgeSegmentIdIndexOrderDigest = Ops.dep_support.edgeSegmentIdIndexOrderDigest;
        const edgeSegmentIdRunSummaryFromRecords = Ops.dep_support.edgeSegmentIdRunSummaryFromRecords;
        const edgeSegmentIdSidecarSummaryFromCompleteRuns = Ops.dep_support.edgeSegmentIdSidecarSummaryFromCompleteRuns;
        const edgeSegmentIdSidecarSummaryFromCompleteRange = Ops.dep_support.edgeSegmentIdSidecarSummaryFromCompleteRange;
        const extendEdgeSegmentIdRunSummaryWithRecords = Ops.dep_support.extendEdgeSegmentIdRunSummaryWithRecords;
        const extendEdgeSegmentIdRunSummaryWithEdge = Ops.dep_support.extendEdgeSegmentIdRunSummaryWithEdge;
        const edgeSegmentIdIndexOrderDigestAt = Ops.dep_support.edgeSegmentIdIndexOrderDigestAt;
        const u64LessThan = Ops.dep_support.u64LessThan;
        const lowerBoundU64 = Ops.dep_support.lowerBoundU64;
        const upperBoundU64 = Ops.dep_support.upperBoundU64;
        const sortedSetIntersectsRange = Ops.dep_support.sortedSetIntersectsRange;
        const u64SortedContains = Ops.dep_support.u64SortedContains;
        const sortEdgeIndexRecords = Ops.dep_support.sortEdgeIndexRecords;
        const edgeIndexRecordOptionalOrderLessThan = Ops.dep_support.edgeIndexRecordOptionalOrderLessThan;
        const edgeOrderRecordLessThan = Ops.dep_support.edgeOrderRecordLessThan;
        const validateEdgeOrderRecord = Ops.dep_support.validateEdgeOrderRecord;
        const sortEdgeIndexRecordOrder = Ops.dep_support.sortEdgeIndexRecordOrder;
        const edgeRecordDigest = Ops.dep_support.edgeRecordDigest;
        const edgeOrderRecordDigest = Ops.dep_support.edgeOrderRecordDigest;
        const edgeIndexRecordFromEdge = Ops.dep_support.edgeIndexRecordFromEdge;
        const edgeIndexRecordEquals = Ops.dep_support.edgeIndexRecordEquals;
        const edgeTombstoneSliceContains = Ops.dep_support.edgeTombstoneSliceContains;
        const mergeEdgeTombstones = Ops.dep_support.mergeEdgeTombstones;
        const nodeRecordDigestFromParts = Ops.dep_support.nodeRecordDigestFromParts;
        const EdgeIndexDigest = Ops.dep_support.EdgeIndexDigest;
        const edgeIndexOrderDigestStep = Ops.dep_support.edgeIndexOrderDigestStep;
        const activeNodeCount = Ops.dep_support.activeNodeCount;
        const GraphEdgeIndexStats = Ops.dep_support.GraphEdgeIndexStats;
        const graphCurrentMetaStats = Ops.dep_support.graphCurrentMetaStats;
        const graphEdgeIndexStats = Ops.dep_support.graphEdgeIndexStats;
        const graphIndexStats = Ops.dep_support.graphIndexStats;
        const edgeTombstoneLessThan = Ops.dep_support.edgeTombstoneLessThan;
        const buildActiveNodeSet = Ops.dep_support.buildActiveNodeSet;
        const physicalEdgeRecord = Ops.dep_support.physicalEdgeRecord;
        const edgeIndexRecordKey = Ops.dep_support.edgeIndexRecordKey;
        const edgeIndexRecordNodeRelLessThan = Ops.dep_support.edgeIndexRecordNodeRelLessThan;
        const nodeTextHash = Ops.dep_support.nodeTextHash;
        const nodeTextIndexLessThan = Ops.dep_support.nodeTextIndexLessThan;
        const nodeTextIndexOrderDigestStep = Ops.dep_support.nodeTextIndexOrderDigestStep;
        const combinedNodeTextOrderDigestWithRuns = Ops.dep_support.combinedNodeTextOrderDigestWithRuns;
        const nodeTextRunHashFilterLenForRecords = Ops.dep_support.nodeTextRunHashFilterLenForRecords;
        const nodeTextRunHashFilterLenValid = Ops.dep_support.nodeTextRunHashFilterLenValid;
        const nodeTextBaseHashFilterLenForRecords = Ops.dep_support.nodeTextBaseHashFilterLenForRecords;
        const nodeTextHashFilterDigest = Ops.dep_support.nodeTextHashFilterDigest;
        const nodeTextRunHashFilterSet = Ops.dep_support.nodeTextRunHashFilterSet;
        const nodeTextRunManifestEpochDigestOwned = Ops.dep_support.nodeTextRunManifestEpochDigestOwned;
        const nodeTextRunManifestContentDigestOwned = Ops.dep_support.nodeTextRunManifestContentDigestOwned;
        const encodeNodeTextRunManifestHeader = Ops.dep_support.encodeNodeTextRunManifestHeader;
        const decodeNodeTextRunManifestHeader = Ops.dep_support.decodeNodeTextRunManifestHeader;
        const encodeNodeTextRunManifestEntryHeader = Ops.dep_support.encodeNodeTextRunManifestEntryHeader;
        const decodeNodeTextRunManifestEntryHeader = Ops.dep_support.decodeNodeTextRunManifestEntryHeader;
        const NodeTextIndexDigest = Ops.dep_support.NodeTextIndexDigest;
        const textSpansCoverTextsFile = Ops.dep_support.textSpansCoverTextsFile;
        const isReservedNodeId = Ops.dep_support.isReservedNodeId;
        const edgeIndexFileSize = Ops.dep_support.edgeIndexFileSize;
        const edgeIndexFileSizeForHeader = Ops.dep_support.edgeIndexFileSizeForHeader;
        const edgeTombstoneFileSize = Ops.dep_support.edgeTombstoneFileSize;
        const edgeTombstoneRecordOffset = Ops.dep_support.edgeTombstoneRecordOffset;
        const edgeIndexRecordOffsetForHeader = Ops.dep_support.edgeIndexRecordOffsetForHeader;
        const nodeByIdFileSize = Ops.dep_support.nodeByIdFileSize;
        const nodeByIdFileSizeForHeader = Ops.dep_support.nodeByIdFileSizeForHeader;
        const nodeByIdRecordOffsetForHeader = Ops.dep_support.nodeByIdRecordOffsetForHeader;
        const node_by_id_text_offset_checkpoint_stride = Ops.dep_support.node_by_id_text_offset_checkpoint_stride;
        const nodeByIdTextOffsetCheckpointCount = Ops.dep_support.nodeByIdTextOffsetCheckpointCount;
        const nodeByIdTextOffsetCheckpointBlock = Ops.dep_support.nodeByIdTextOffsetCheckpointBlock;
        const nodeByIdTextOffsetCheckpointTableOffset = Ops.dep_support.nodeByIdTextOffsetCheckpointTableOffset;
        const nodeByIdTextOffsetCheckpointOffset = Ops.dep_support.nodeByIdTextOffsetCheckpointOffset;
        const readDerivedNodeByIdTextLenFromMap = Ops.dep_support.readDerivedNodeByIdTextLenFromMap;
        const deriveNodeByIdTextOffsetFromMap = Ops.dep_support.deriveNodeByIdTextOffsetFromMap;
        const nodeTextIndexHeaderForRecords = Ops.dep_support.nodeTextIndexHeaderForRecords;
        const nodeTextIndexHeaderForSortedUniqueHashRecords = Ops.dep_support.nodeTextIndexHeaderForSortedUniqueHashRecords;
        const nodeTextRecordFitsHeader = Ops.dep_support.nodeTextRecordFitsHeader;
        const nodeTextHeaderForTail = Ops.dep_support.nodeTextHeaderForTail;
        const nodeTextIndexFileSizeForHeader = Ops.dep_support.nodeTextIndexFileSizeForHeader;
        const nodeTextIndexRecordOffsetForHeader = Ops.dep_support.nodeTextIndexRecordOffsetForHeader;
        const allZero = Ops.dep_support.allZero;
        const BinaryRecordKind = Ops.dep_support.BinaryRecordKind;
        const BinaryRecordHeader = Ops.dep_support.BinaryRecordHeader;
        const binaryPayloadChecksum = Ops.dep_support.binaryPayloadChecksum;
        const validateBinaryChecksum = Ops.dep_support.validateBinaryChecksum;
        const validateBinaryChecksumValue = Ops.dep_support.validateBinaryChecksumValue;
        const ensureBinaryPayloadFits = Ops.dep_support.ensureBinaryPayloadFits;
        const appendBinaryRecord = Ops.dep_support.appendBinaryRecord;
        const binary_edge_record_len = Ops.dep_support.binary_edge_record_len;
        const binary_edge_delete_record_len = Ops.dep_support.binary_edge_delete_record_len;
        const encodeBinaryRecordHeader = Ops.dep_support.encodeBinaryRecordHeader;
        const encodeBinaryNodeFixedPayload = Ops.dep_support.encodeBinaryNodeFixedPayload;
        const appendBinaryNodeBatchRecordToWriter = Ops.dep_support.appendBinaryNodeBatchRecordToWriter;
        const appendBinaryEdgeBatchRecordToWriter = Ops.dep_support.appendBinaryEdgeBatchRecordToWriter;
        const encodeBinaryEdgeRecord = Ops.dep_support.encodeBinaryEdgeRecord;
        const encodeBinaryEdgeDeleteRecord = Ops.dep_support.encodeBinaryEdgeDeleteRecord;
        const replayBinaryRecord = Ops.dep_support.replayBinaryRecord;
        const validateBinaryRecordPayload = Ops.dep_support.validateBinaryRecordPayload;
        const binary_node_payload_len = Ops.dep_support.binary_node_payload_len;
        const binary_node_batch_max_count = Ops.dep_support.binary_node_batch_max_count;
        const binary_edge_payload_len = Ops.dep_support.binary_edge_payload_len;
        const binary_edge_batch_max_count = Ops.dep_support.binary_edge_batch_max_count;
        const binary_edge_delete_payload_len = Ops.dep_support.binary_edge_delete_payload_len;
        const max_binary_count_payload_prefix_len = Ops.dep_support.max_binary_count_payload_prefix_len;
        const binary_count_read_chunk_len = Ops.dep_support.binary_count_read_chunk_len;
        const maxBinaryNodeTextLen = Ops.dep_support.maxBinaryNodeTextLen;
        const validateBinaryNodePayload = Ops.dep_support.validateBinaryNodePayload;
        const validateBinaryNodePayloadForCount = Ops.dep_support.validateBinaryNodePayloadForCount;
        const binaryNodeBatchCountFromPrefix = Ops.dep_support.binaryNodeBatchCountFromPrefix;
        const validateBinaryNodeBatchPayload = Ops.dep_support.validateBinaryNodeBatchPayload;
        const BinaryNodeBatchReader = Ops.dep_support.BinaryNodeBatchReader;
        const validateBinaryEdgePayload = Ops.dep_support.validateBinaryEdgePayload;
        const validateBinaryEdgeBatchHeader = Ops.dep_support.validateBinaryEdgeBatchHeader;
        const validateBinaryEdgeBatchEdge = Ops.dep_support.validateBinaryEdgeBatchEdge;
        const validateBinaryEdgeDeletePayload = Ops.dep_support.validateBinaryEdgeDeletePayload;
        const nodeKindFromInt = Ops.dep_support.nodeKindFromInt;
        const relKindFromInt = Ops.dep_support.relKindFromInt;
        const appendU16 = Ops.dep_support.appendU16;
        const appendU64 = Ops.dep_support.appendU64;
        const readU16 = Ops.dep_support.readU16;
        const readU32 = Ops.dep_support.readU32;
        const readU64 = Ops.dep_support.readU64;
        const NodeTextLookupRun = Ops.dep_NodeTextLookupRun;
        const LazyFirstNodeTextLookup = Ops.dep_LazyFirstNodeTextLookup;
        const NodeTextLookupView = Ops.dep_NodeTextLookupView;
        const NodeTextLookupTimings = Ops.dep_NodeTextLookupTimings;
        const NodeTextLookupOpenTimings = Ops.dep_NodeTextLookupOpenTimings;
        const NodeRewriteAction = Ops.dep_NodeRewriteAction;
        const NodeTextsAppendRecovery = Ops.dep_NodeTextsAppendRecovery;
        const EdgeTombstoneIndexView = Ops.dep_EdgeTombstoneIndexView;
        const EdgeIndexRecordIterator = Ops.dep_EdgeIndexRecordIterator;
        const VisibleEdgeIndexRecordIterator = Ops.dep_VisibleEdgeIndexRecordIterator;
        const UintPropertyRange = Ops.dep_UintPropertyRange;
        const NodeIdIterator = Ops.dep_NodeIdIterator;
        const NodeByIdIndexView = Ops.dep_NodeByIdIndexView;
        const EdgeBatchNodeExistenceCache = Ops.dep_EdgeBatchNodeExistenceCache;
        const NodeTextsView = Ops.dep_NodeTextsView;
        const NodeRecordView = Ops.dep_NodeRecordView;
        const NodeRecordIterator = Ops.dep_NodeRecordIterator;
        const EdgeIndexKeyRunBounds = Ops.dep_EdgeIndexKeyRunBounds;
        const EdgeIndexSequentialRecordReader = Ops.dep_EdgeIndexSequentialRecordReader;
        const ExplicitEdgeIndexSequentialReader = Ops.dep_ExplicitEdgeIndexSequentialReader;
        const EdgeAppendTailSpool = Ops.dep_EdgeAppendTailSpool;
        const EdgeSortedRunSet = Ops.dep_EdgeSortedRunSet;
        const EdgeSegmentIdIndexSummary = Ops.dep_EdgeSegmentIdIndexSummary;
        const EdgeIndexBatchWriteResult = Ops.dep_EdgeIndexBatchWriteResult;
        const SecondaryRepairKeyRun = Ops.dep_SecondaryRepairKeyRun;
        const DenseRingRepairSpoolShape = Ops.dep_DenseRingRepairSpoolShape;
        const validateSortedRepairEdgeRecords = Ops.dep_validateSortedRepairEdgeRecords;
        const validateSortedRepairEdgeRecordOrder = Ops.dep_validateSortedRepairEdgeRecordOrder;

        pub fn init(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Store {
            return initWithOptions(allocator, io, dir_path, .{});
        }

        pub fn initWithOptions(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, options: StorageOptions) !Store {
            return initWithOptionsCreate(allocator, io, dir_path, options, true);
        }

        pub fn open(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Store {
            return openWithOptions(allocator, io, dir_path, .{});
        }

        pub fn openWithOptions(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, options: StorageOptions) !Store {
            return initWithOptionsCreate(allocator, io, dir_path, options, false);
        }

        pub fn initWithOptionsCreate(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, options: StorageOptions, create: bool) !Store {
            return store_opening.open(.{
                .allocator = allocator,
                .io = io,
                .dir_path = dir_path,
                .options = options,
            }, create);
        }

        pub fn allocateOwned(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, options: StorageOptions) !Store {
            var owned_paths = try store_paths_mod.OwnedPaths.init(allocator, dir_path);
            errdefer owned_paths.deinit(allocator);
            var owned_caches = try store_cache_resources.init(allocator);
            errdefer owned_caches.deinit(allocator);

            return .{
                .allocator = allocator,
                .io = io,
                .dir_path = owned_paths.dir_path,
                .events_bin_path = owned_paths.events_bin_path,
                .index_meta_path = owned_paths.index_meta_path,
                .node_by_id_path = owned_paths.node_by_id_path,
                .node_texts_path = owned_paths.node_texts_path,
                .node_by_text_path = owned_paths.node_by_text_path,
                .node_by_text_base_filter_path = owned_paths.node_by_text_base_filter_path,
                .node_by_text_delta_path = owned_paths.node_by_text_delta_path,
                .external_key_index_path = owned_paths.external_key_index_path,
                .node_props_index_path = owned_paths.node_props_index_path,
                .node_props_values_path = owned_paths.node_props_values_path,
                .node_props_overlay_index_path = owned_paths.node_props_overlay_index_path,
                .node_props_overlay_values_path = owned_paths.node_props_overlay_values_path,
                .edge_props_overlay_index_path = owned_paths.edge_props_overlay_index_path,
                .edge_props_overlay_values_path = owned_paths.edge_props_overlay_values_path,
                .property_payload_index_path = owned_paths.property_payload_index_path,
                .property_payload_values_path = owned_paths.property_payload_values_path,
                .property_payload_delta_path = owned_paths.property_payload_delta_path,
                .edge_external_key_index_path = owned_paths.edge_external_key_index_path,
                .node_text_run_manifest_path = owned_paths.node_text_run_manifest_path,
                .node_text_run_current_path = owned_paths.node_text_run_current_path,
                .edge_by_id_path = owned_paths.edge_by_id_path,
                .edge_by_src_path = owned_paths.edge_by_src_path,
                .edge_by_dst_path = owned_paths.edge_by_dst_path,
                .edge_order_path = owned_paths.edge_order_path,
                .edge_tombstones_path = owned_paths.edge_tombstones_path,
                .edge_segment_manifest_path = owned_paths.edge_segment_manifest_path,
                .edge_segment_current_path = owned_paths.edge_segment_current_path,
                .catalog_path = owned_paths.catalog_path,
                .index_meta_cache = owned_caches.index_meta_cache,
                .node_text_delta_header_cache = owned_caches.node_text_delta_header_cache,
                .node_text_delta_run_cache = owned_caches.node_text_delta_run_cache,
                .node_text_run_manifest_cache = owned_caches.node_text_run_manifest_cache,
                .node_text_base_filter_cache = owned_caches.node_text_base_filter_cache,
                .options = options,
            };
        }

        pub fn deinit(self: *Store) void {
            var owned_caches = store_cache_resources.borrowOwner(self);
            owned_caches.deinit(self.allocator);
            var owned_paths = store_paths_mod.OwnedPaths.borrowOwner(self);
            owned_paths.deinit(self.allocator);
        }

        pub fn createEmpty(self: Store) !void {
            return store_bootstrap.ensure(self);
        }

        pub fn resetEmptyForTests(self: Store) !void {
            try std.Io.Dir.cwd().writeFile(self.io, .{
                .sub_path = self.events_bin_path,
                .data = "",
                .flags = .{ .truncate = true },
            });
            try writeIndexMeta(self, .{});
            try writeEmptyNodeIndexes(self);
            try writeExternalKeyIndex(self, &.{}, .{});
            try writeNodePropertyIndex(self, &.{}, .{});
            try writeEdgeExternalKeyIndex(self, &.{}, .{});
            std.Io.Dir.cwd().deleteFile(self.io, self.edge_props_overlay_index_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            std.Io.Dir.cwd().deleteFile(self.io, self.edge_props_overlay_values_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            std.Io.Dir.cwd().deleteFile(self.io, self.property_payload_index_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            std.Io.Dir.cwd().deleteFile(self.io, self.property_payload_values_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            const property_payload_redo_journal_path = try property_payload_transaction.Testing.baseRedoPath(self);
            defer self.allocator.free(property_payload_redo_journal_path);
            std.Io.Dir.cwd().deleteFile(self.io, property_payload_redo_journal_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            std.Io.Dir.cwd().deleteFile(self.io, self.property_payload_delta_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            const property_payload_delta_journal_path = try property_payload_transaction.Testing.deltaRedoPath(self);
            defer self.allocator.free(property_payload_delta_journal_path);
            std.Io.Dir.cwd().deleteFile(self.io, property_payload_delta_journal_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            var node_text_journal_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const node_text_journal_path = try nodeTextsAppendJournalPath(self, &node_text_journal_buffer);
            std.Io.Dir.cwd().deleteFile(self.io, node_text_journal_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            const node_text_journal_tmp_path = try tmpPathFor(self, node_text_journal_path);
            defer self.allocator.free(node_text_journal_tmp_path);
            std.Io.Dir.cwd().deleteFile(self.io, node_text_journal_tmp_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            const primary_text_tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.deflate.tmp", .{self.node_texts_path});
            defer self.allocator.free(primary_text_tmp_path);
            std.Io.Dir.cwd().deleteFile(self.io, primary_text_tmp_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            const primary_text_table_tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.deflate.table.tmp", .{self.node_texts_path});
            defer self.allocator.free(primary_text_table_tmp_path);
            std.Io.Dir.cwd().deleteFile(self.io, primary_text_table_tmp_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            try writeEdgeIndex(self, self.edge_by_id_path, &.{});
            try writeEdgeIndex(self, self.edge_by_src_path, &.{});
            try writeEdgeIndex(self, self.edge_by_dst_path, &.{});
            try writeEdgeOrderIndex(self, &.{});
            try writeEdgeTombstoneIndex(self, &.{});
            std.Io.Dir.cwd().deleteFile(self.io, self.edge_segment_manifest_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            std.Io.Dir.cwd().deleteFile(self.io, self.edge_segment_current_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            std.Io.Dir.cwd().deleteFile(self.io, self.node_text_run_manifest_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            std.Io.Dir.cwd().deleteFile(self.io, self.node_text_run_current_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            invalidateNodeTextRunManifestCache(self);
        }

        pub fn appendNode(self: Store, node: graph_mod.Node) !void {
            if (node.status != .active) return core.Error.Unsupported;
            if (node.text.len > maxBinaryNodeTextLen()) return error.RecordTooLarge;
            try graph_mod.validateNodeText(node.text);
            try reconcileNodeTextsBeforeAppend(self);
            const validate_start = if (self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
            try validateNodeIndexAppendWithRepair(self, node);
            if (self.node_append_timings) |timings| timings.validate_ns += storageElapsedNs(self.io, validate_start);
            const event_start = if (self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
            const rollback_event_bytes = try eventBytes(self);
            if (self.node_append_timings) |timings| timings.event_bytes_ns += storageElapsedNs(self.io, event_start);
            var published = false;
            var text_appended = false;
            errdefer if (!published) rollbackNodeAppendFailure(self, rollback_event_bytes, text_appended);

            const append_texts_start = if (self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
            const text_span = try appendNodeTextBytes(self, node.text);
            text_appended = true;
            if (self.node_append_timings) |timings| timings.append_texts_ns += storageElapsedNs(self.io, append_texts_start);
            const append_record_start = if (self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
            try appendNodeRecord(self, node, text_span);
            if (self.node_append_timings) |timings| timings.append_record_ns += storageElapsedNs(self.io, append_record_start);
            const indexes_current = refreshIndexesAfterCommittedAppend(self, .node, node, null, text_span);
            if (self.node_append_timings) |timings| timings.nodes += 1;
            published = true;
            // Keep the committed text journal until the whole append transaction,
            // including derived-index publication, has succeeded. If index work
            // fails, rollbackNodeAppendFailure may itself be unable to repair under
            // the same filesystem/allocation fault; the journal must survive as
            // the durable anchor that lets reopen or the next append remove the
            // now-unreferenced text tail.
            if (indexes_current) cleanupCommittedNodeTextsAppendJournal(self);
        }

        pub fn appendNodesBatch(self: Store, nodes: []const graph_mod.Node) !void {
            if (nodes.len == 0) return;
            try reconcileNodeTextsBeforeAppend(self);
            appendNodesBatchOnce(self, nodes) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    const repair_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
                    try repairPersistentIndexesFromLog(self);
                    if (self.node_batch_append_timings) |timings| {
                        timings.repair_retry_count += 1;
                        timings.repair_ns += storageElapsedNs(self.io, repair_start);
                    }
                    return try appendNodesBatchOnce(self, nodes);
                },
                else => |e| return e,
            };
        }

        pub fn appendNodesBatchOnce(self: Store, nodes: []const graph_mod.Node) !void {
            if (self.node_batch_append_timings) |timings| {
                timings.batches += 1;
                timings.nodes += @intCast(nodes.len);
            }

            const read_meta_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            const old_meta = try readCurrentIndexMetaForAppend(self);
            if (self.node_batch_append_timings) |timings| timings.read_meta_ns += storageElapsedNs(self.io, read_meta_start);

            const validate_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            try validateNodeBatchAppend(self, nodes, old_meta);
            if (self.node_batch_append_timings) |timings| timings.validate_ns += storageElapsedNs(self.io, validate_start);

            const event_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            const rollback_event_bytes = try eventBytes(self);
            const event_bytes_ns = if (self.node_batch_append_timings != null) storageElapsedNs(self.io, event_start) else 0;
            var published = false;
            var texts_appended = false;
            errdefer if (!published) rollbackNodeAppendFailure(self, rollback_event_bytes, texts_appended);

            const append_texts_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            const text_spans = try appendNodeTextsBatch(self, nodes);
            texts_appended = true;
            if (self.node_batch_append_timings) |timings| timings.append_texts_ns += storageElapsedNs(self.io, append_texts_start);
            defer self.allocator.free(text_spans);

            const event_records_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            try appendNodeBatchRecords(self, nodes, text_spans, rollback_event_bytes);
            if (self.node_batch_append_timings) |timings| timings.append_event_records_ns += event_bytes_ns + storageElapsedNs(self.io, event_records_start);

            var text_records = std.ArrayList(NodeTextIndexRecord).empty;
            defer text_records.deinit(self.allocator);
            try text_records.ensureTotalCapacity(self.allocator, nodes.len);

            var next_meta = old_meta;
            next_meta.event_bytes = try eventBytes(self);
            const by_id_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            try appendNodeByIdIndexRecordsBatch(self, old_meta, nodes, text_spans, &text_records, &next_meta);
            if (self.node_batch_append_timings) |timings| timings.by_id_index_ns += storageElapsedNs(self.io, by_id_start);

            const batch_node_digest = old_meta.node_digest ^ next_meta.node_digest;
            const node_text_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            if (!try publishNodeTextRunBatchIfPossible(self, old_meta, next_meta, text_records.items, batch_node_digest, .trusted_recent_by_id_append)) {
                if (!try writeNodeTextDeltaBatchIfPossible(self, old_meta, text_records.items, batch_node_digest, next_meta.node_digest)) {
                    var manifest = try readNodeTextRunManifest(self, self.allocator);
                    defer manifest.deinit(self.allocator);
                    const delta_header = try readNodeTextDeltaHeader(self);
                    var compacted_old_meta = old_meta;
                    if (try compactNodeTextRunWindowForMeta(self, old_meta, manifest.entries.items, delta_header, 0, &.{})) |_| {
                        compacted_old_meta = try readIndexMeta(self);
                    } else {
                        const compacted = try compactNodeTextOverlaysForMeta(self, old_meta.nodes, old_meta.node_digest, old_meta.node_by_text_order_digest, &.{});
                        compacted_old_meta.node_by_text_order_digest = compacted.order_digest;
                    }
                    if (compacted_old_meta.nodes != old_meta.nodes) return error.InvalidRecord;
                    if (compacted_old_meta.node_digest != old_meta.node_digest) return error.InvalidRecord;
                    if (!try publishNodeTextRunBatchIfPossible(self, compacted_old_meta, next_meta, text_records.items, batch_node_digest, .trusted_recent_by_id_append)) {
                        if (!try writeNodeTextDeltaBatchIfPossible(self, compacted_old_meta, text_records.items, batch_node_digest, next_meta.node_digest)) {
                            const compacted = try compactNodeTextOverlaysForMeta(self, compacted_old_meta.nodes, compacted_old_meta.node_digest, compacted_old_meta.node_by_text_order_digest, &.{});
                            compacted_old_meta.node_by_text_order_digest = compacted.order_digest;
                            try writeMergedNodeTextIndexBatch(self, compacted_old_meta, text_records.items, batch_node_digest, next_meta.node_digest, .trusted_recent_by_id_append);
                        }
                    }
                }
            }
            if (self.node_batch_append_timings) |timings| timings.node_text_index_ns += storageElapsedNs(self.io, node_text_start);

            const meta_write_start = if (self.node_batch_append_timings != null) storageMonotonicNs(self.io) else 0;
            try copyNodeTextOrderDigestFromHeader(self, &next_meta);
            updateExternalKeyIndexForNodeBatch(self, old_meta, next_meta, nodes) catch {};
            updateNodePropertyIndexForNodeBatch(self, old_meta, next_meta, nodes) catch {};
            try writeIndexMeta(self, next_meta);
            if (self.node_batch_append_timings) |timings| timings.meta_write_ns += storageElapsedNs(self.io, meta_write_start);
            published = true;
            cleanupCommittedNodeTextsAppendJournal(self);
        }

        pub fn rollbackNodeAppendFailure(self: Store, rollback_event_bytes: u64, texts_appended: bool) void {
            rollbackBatchAppend(self, rollback_event_bytes) catch {};
            if (!texts_appended) return;

            // Node text is published before its canonical event. Both single and
            // batch append retain the committed journal through derived-index
            // publication, so if this best-effort repair fails the durable anchor
            // remains for reopen or the next append instead of stranding an
            // unreachable text suffix.
            repairPersistentIndexesFromLog(self) catch {};
        }

        pub fn appendNodeRecord(self: Store, node: graph_mod.Node, text_span: TextSpan) !void {
            var payload: [binary_node_payload_len]u8 = undefined;
            _ = try encodeBinaryNodeFixedPayload(&payload, node, text_span);
            var record = std.ArrayList(u8).empty;
            defer record.deinit(self.allocator);
            try appendBinaryRecord(&record, self.allocator, .node, &payload);
            try appendRecord(self, record.items);
        }

        pub fn addNode(self: Store, kind: core.NodeKind, text: []const u8) !core.NodeId {
            var repaired = false;
            while (true) {
                const next_id_start = if (self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
                const id = nextNodeId(self) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidRecord => {
                        if (repaired) return err;
                        repaired = true;
                        try repairPersistentIndexesFromLog(self);
                        continue;
                    },
                    else => |e| return e,
                };
                if (self.node_append_timings) |timings| timings.next_id_ns += storageElapsedNs(self.io, next_id_start);
                appendNode(self, .{
                    .id = id,
                    .kind = kind,
                    .text = text,
                }) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidRecord => {
                        if (repaired) return err;
                        repaired = true;
                        try repairPersistentIndexesFromLog(self);
                        continue;
                    },
                    else => |e| return e,
                };
                return id;
            }
        }

        pub fn updateNode(self: Store, node_id: core.NodeId, kind: core.NodeKind, text: []const u8) !NodeRewriteResult {
            if (isReservedNodeId(node_id)) return core.Error.InvalidId;
            try graph_mod.validateNodeText(text);
            if (text.len > maxBinaryNodeTextLen()) return error.RecordTooLarge;
            return try rewriteNodeStore(self, .{ .update = .{ .node_id = node_id, .kind = kind, .text = text } });
        }

        pub fn deleteNode(self: Store, node_id: core.NodeId) !NodeRewriteResult {
            if (isReservedNodeId(node_id)) return core.Error.InvalidId;
            return try rewriteNodeStore(self, .{ .delete = .{ .node_id = node_id } });
        }

        pub fn rewriteNodeStore(self: Store, action: NodeRewriteAction) !NodeRewriteResult {
            const target_id = action.nodeId();
            var graph = try loadGraph(self);
            defer graph.deinit();
            if (graph.getNode(target_id) == null) return core.Error.NotFound;

            const nonce = store_temp_nonce.fetchAdd(1, .monotonic);
            const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.rewrite.{d}.tmp", .{ self.dir_path, nonce });
            defer self.allocator.free(tmp_path);
            const backup_path = try std.fmt.allocPrint(self.allocator, "{s}.rewrite.{d}.bak", .{ self.dir_path, nonce });
            defer self.allocator.free(backup_path);
            std.Io.Dir.cwd().deleteTree(self.io, tmp_path) catch {};
            std.Io.Dir.cwd().deleteTree(self.io, backup_path) catch {};
            errdefer std.Io.Dir.cwd().deleteTree(self.io, tmp_path) catch {};
            errdefer std.Io.Dir.cwd().deleteTree(self.io, backup_path) catch {};

            var result = NodeRewriteResult{};
            {
                var rewritten = try initWithOptions(self.allocator, self.io, tmp_path, self.options);
                defer rewritten.deinit();
                try rewritten.createEmpty();

                var rewrite_nodes = std.ArrayList(graph_mod.Node).empty;
                defer {
                    for (rewrite_nodes.items) |node| self.allocator.free(node.text);
                    rewrite_nodes.deinit(self.allocator);
                }
                try rewrite_nodes.ensureTotalCapacity(self.allocator, graph.nodes.items.len);
                for (graph.nodes.items) |node| {
                    var rewritten_kind = node.kind;
                    var rewritten_text: []const u8 = node.text;
                    var tombstone_text: ?[]u8 = null;
                    defer if (tombstone_text) |text| self.allocator.free(text);
                    var rewritten_node = graph_mod.Node{
                        .id = node.id,
                        .kind = undefined,
                        .text = undefined,
                    };
                    if (node.id == target_id) {
                        switch (action) {
                            .update => |update| {
                                rewritten_kind = update.kind;
                                rewritten_text = update.text;
                            },
                            .delete => {
                                rewritten_kind = .edit;
                                tombstone_text = try std.fmt.allocPrint(self.allocator, "__tinykg_deleted_node__ {}", .{node.id.toInt()});
                                rewritten_text = tombstone_text.?;
                            },
                        }
                    }
                    rewritten_node.kind = rewritten_kind;
                    rewritten_node.text = try self.allocator.dupe(u8, rewritten_text);
                    errdefer self.allocator.free(rewritten_node.text);
                    try rewrite_nodes.append(self.allocator, rewritten_node);
                    result.nodes_rewritten += 1;
                }
                try rewritten.appendNodesBatch(rewrite_nodes.items);

                var rewrite_edges = std.ArrayList(graph_mod.Edge).empty;
                defer rewrite_edges.deinit(self.allocator);
                try rewrite_edges.ensureTotalCapacity(self.allocator, graph.edges.items.len);
                var removed_edge_ids = std.AutoHashMap(u64, void).init(self.allocator);
                defer removed_edge_ids.deinit();
                for (graph.edges.items) |edge| {
                    if (edge.status != .active) continue;
                    const incident_to_deleted = switch (action) {
                        .update => false,
                        .delete => edge.src.toInt() == target_id.toInt() or edge.dst.toInt() == target_id.toInt(),
                    };
                    if (incident_to_deleted) {
                        try removed_edge_ids.put(edge.id.toInt(), {});
                        result.edges_removed += 1;
                        continue;
                    }
                    try rewrite_edges.append(self.allocator, edge);
                    result.edges_rewritten += 1;
                }
                try rewritten.appendEdgesBatch(rewrite_edges.items);

                var payload_entries = try readPropertyPayloadEntriesOrEmpty(self, self.allocator);
                defer {
                    deinitPropertyPayloadIndexEntries(payload_entries.items, self.allocator);
                    payload_entries.deinit(self.allocator);
                }
                if (payload_entries.items.len != 0) {
                    switch (action) {
                        .update => try writePropertyPayload(rewritten, payload_entries.items),
                        .delete => {
                            // The deleted node and incident edges lose their
                            // properties, but unrelated owners remain canonical.
                            // Dropping the whole payload here used to erase every
                            // task lifecycle/property in the store after deleting
                            // one node. Compact in place, transferring ownership
                            // of retained string values into the surviving prefix.
                            var retained: usize = 0;
                            for (payload_entries.items) |entry| {
                                const remove = (entry.record.owner_kind == PropertyPayloadIndexRecord.owner_kind_node and
                                    entry.record.owner_id == target_id.toInt()) or
                                    (entry.record.owner_kind == PropertyPayloadIndexRecord.owner_kind_edge and
                                        removed_edge_ids.contains(entry.record.owner_id));
                                if (remove) {
                                    var owned = entry;
                                    owned.deinit(self.allocator);
                                    continue;
                                }
                                payload_entries.items[retained] = entry;
                                retained += 1;
                            }
                            payload_entries.items.len = retained;
                            if (retained != 0) try writePropertyPayload(rewritten, payload_entries.items);
                        },
                    }
                }

                // A node-text rewrite replaces the whole directory, but the
                // embedded schema catalog and store-format manifest are canonical
                // control-plane state, not derived indexes. Recreating the target
                // with createEmpty() installs a kernel-only catalog and no
                // manifest; publishing that directory used to silently downgrade
                // a migrated v2/v3 store to "legacy" after any task text update.
                // Preserve both files inside the same COW transaction. Full-text
                // indexes are intentionally omitted because changed node text
                // makes them stale; callers may warm them explicitly.
                try copyRewriteControlPlane(self, &rewritten);
            }

            try std.Io.Dir.rename(.cwd(), self.dir_path, .cwd(), backup_path, self.io);
            var original_moved = true;
            errdefer if (original_moved) {
                std.Io.Dir.rename(.cwd(), backup_path, .cwd(), self.dir_path, self.io) catch {};
            };
            try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), self.dir_path, self.io);
            original_moved = false;
            // 整目录已换新:进程内 meta 缓存必须失效。缓存钥匙是 events.bin 字节数,
            // 而重写(记录对齐填充)常保字节数不变 → 不清则同进程后续读(如 update-node
            // 换店后的治理属性写)拿旧 digest 撞 InvalidRecord(revise→revise 必挂,存量 bug)。
            self.index_meta_cache.clear();
            try syncParentDirForPath(self, self.dir_path);
            std.Io.Dir.cwd().deleteTree(self.io, backup_path) catch {};
            return result;
        }

        pub fn copyRewriteControlPlane(self: Store, rewritten: *const Store) !void {
            _ = try copyRegularFileForRewrite(self, self.catalog_path, rewritten.catalog_path);

            const source_manifest = try std.fs.path.join(self.allocator, &.{ self.dir_path, ".tinykg", "store-manifest.json" });
            defer self.allocator.free(source_manifest);
            const target_manifest = try std.fs.path.join(self.allocator, &.{ rewritten.dir_path, ".tinykg", "store-manifest.json" });
            defer self.allocator.free(target_manifest);
            if (try copyRegularFileForRewrite(self, source_manifest, target_manifest)) {
                const target_manifest_dir = std.fs.path.dirname(target_manifest) orelse return error.InvalidRecord;
                try syncParentDirForPath(rewritten.*, target_manifest_dir);
            }
        }

        pub fn copyRegularFileForRewrite(self: Store, source_path: []const u8, target_path: []const u8) !bool {
            const stat = std.Io.Dir.cwd().statFile(self.io, source_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return false,
                else => |e| return e,
            };
            if (stat.kind != .file) return error.InvalidRecord;
            try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source_path, std.Io.Dir.cwd(), target_path, self.io, .{
                .replace = true,
                .make_path = true,
            });
            if (selfOptionsNeedSync(self)) {
                var target_file = try std.Io.Dir.cwd().openFile(self.io, target_path, .{ .mode = .read_write });
                defer target_file.close(self.io);
                try target_file.sync(self.io);
            }
            try syncParentDirForPath(self, target_path);
            return true;
        }

        pub fn appendEdge(self: Store, edge: graph_mod.Edge) !void {
            if (edge.status != .active) return core.Error.Unsupported;
            if (try appendEdgeSegmentDeltaOnce(self, edge)) return;
            try appendEdgeIndexed(self, edge);
        }

        pub fn appendEdgeIndexed(self: Store, edge: graph_mod.Edge) !void {
            if (edge.status != .active) return core.Error.Unsupported;
            const keep_segment_current = try edgeSegmentCurrentManifestReadable(self);
            try validateEdgeAppendWithRepair(self, edge);
            try appendEdgeRecord(self, edge);
            _ = refreshIndexesAfterCommittedAppend(self, .edge, null, edge, null);
            if (!keep_segment_current) try invalidateEdgeSegmentCurrent(self);
        }

        pub fn appendEdgeOrderedIndexed(self: Store, edge: graph_mod.Edge, order_key: u64) !void {
            if (order_key == std.math.maxInt(u64)) return error.InvalidRecord;
            try appendEdgeIndexed(self, edge);
            try insertEdgeOrderRecord(self, .{
                .src = edge.src.toInt(),
                .rel = @intFromEnum(edge.rel),
                .edge_id = edge.id.toInt(),
                .order_key = order_key,
            });
        }

        pub fn appendEdgesOrderedBatch(self: Store, edges: []const graph_mod.Edge, order_keys: []const u64) !void {
            if (edges.len != order_keys.len) return error.InvalidRecord;
            if (edges.len == 0) return;
            for (order_keys) |order_key| {
                if (order_key == std.math.maxInt(u64)) return error.InvalidRecord;
            }

            var records = readAllEdgeOrderRecords(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound => std.ArrayList(EdgeOrderRecord).empty,
                else => |e| return e,
            };
            defer records.deinit(self.allocator);
            try records.ensureUnusedCapacity(self.allocator, edges.len);
            for (edges, order_keys) |edge, order_key| {
                const record = EdgeOrderRecord{
                    .src = edge.src.toInt(),
                    .rel = @intFromEnum(edge.rel),
                    .edge_id = edge.id.toInt(),
                    .order_key = order_key,
                };
                try validateEdgeOrderRecord(record);
                records.appendAssumeCapacity(record);
            }
            std.mem.sort(EdgeOrderRecord, records.items, {}, edgeOrderRecordLessThan);

            try appendEdgesBatch(self, edges);
            try writeEdgeOrderIndex(self, records.items);
        }

        pub fn edgeSegmentCurrentManifestReadable(self: Store) !bool {
            var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);
            return true;
        }

        pub fn appendEdgeSegmentDeltaOnce(self: Store, edge: graph_mod.Edge) !bool {
            const old_meta = readCurrentIndexMetaForAppend(self) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            const can_segment_delta = canAppendEdgeBatchAsSegmentDelta(self, old_meta, &.{edge}) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            if (!can_segment_delta) return false;

            var edge_records = std.ArrayList(EdgeIndexRecord).empty;
            defer edge_records.deinit(self.allocator);
            try edge_records.ensureTotalCapacity(self.allocator, 1);

            var next_meta = old_meta;
            try validateEdgeBatchAppend(self, &.{edge}, old_meta, &edge_records, &next_meta, true);

            const rollback_event_bytes = try eventBytes(self);
            var published = false;
            errdefer if (!published) rollbackBatchAppend(self, rollback_event_bytes) catch {};

            try appendEdgeRecordAt(self, edge, rollback_event_bytes);
            next_meta.event_bytes = try eventBytes(self);
            next_meta.edge_indexed_edges = old_meta.edge_indexed_edges;
            next_meta.edge_index_digest = old_meta.edge_index_digest;
            try publishEdgeBatchSegmentIfManifestCurrent(self, old_meta, &next_meta, edge_records.items);
            try writeIndexMeta(self, next_meta);
            published = true;
            maintainEdgeSegmentsAfterCommittedAppend(self);
            return true;
        }

        pub fn deleteEdge(self: Store, edge_id: core.EdgeId) !void {
            deleteEdgeOnce(self, edge_id) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    try repairPersistentIndexesFromLog(self);
                    return try deleteEdgeOnce(self, edge_id);
                },
                else => |e| return e,
            };
        }

        pub fn deleteEdgesBatch(self: Store, edge_ids: []const core.EdgeId) !void {
            if (edge_ids.len == 0) return;
            deleteEdgesBatchOnce(self, edge_ids) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    try repairPersistentIndexesFromLog(self);
                    return try deleteEdgesBatchOnce(self, edge_ids);
                },
                else => |e| return e,
            };
        }

        pub fn deleteEdgeOnce(self: Store, edge_id: core.EdgeId) !void {
            if (edge_id == .none or edge_id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
            const old_meta = try readCurrentIndexMetaForAppend(self);
            if (!try edgeStorageMatchesMeta(self, old_meta, self.options.validate_indexes_on_read)) return error.InvalidRecord;
            const record = try readVisibleEdgeIndexRecordById(self, edge_id);

            const rollback_event_bytes = try eventBytes(self);
            var published = false;
            errdefer if (!published) rollbackBatchAppend(self, rollback_event_bytes) catch {};

            try appendEdgeDeleteRecord(self, edge_id);

            var next_meta = old_meta;
            if (next_meta.edges == 0) return error.InvalidRecord;
            next_meta.edges -= 1;
            next_meta.edge_digest ^= edgeRecordDigest(record);
            next_meta.event_bytes = try eventBytes(self);
            next_meta.max_edge_id_seen = @max(next_meta.max_edge_id_seen, edge_id.toInt());
            _ = try insertEdgeTombstone(self, record);
            try writeIndexMeta(self, next_meta);
            published = true;
        }

        pub fn deleteEdgesBatchOnce(self: Store, edge_ids: []const core.EdgeId) !void {
            const old_meta = try readCurrentIndexMetaForAppend(self);
            if (!try edgeStorageMatchesMeta(self, old_meta, self.options.validate_indexes_on_read)) return error.InvalidRecord;
            if (@as(u64, @intCast(edge_ids.len)) > old_meta.edges) return core.Error.InvalidId;

            var existing_tombstones = try readAllEdgeTombstones(self, self.allocator);
            defer existing_tombstones.deinit(self.allocator);

            var batch_tombstones = std.ArrayList(EdgeTombstoneRecord).empty;
            defer batch_tombstones.deinit(self.allocator);
            try batch_tombstones.ensureTotalCapacityPrecise(self.allocator, edge_ids.len);

            var batch_visible_digest: u64 = 0;
            for (edge_ids) |edge_id| {
                if (edge_id == .none or edge_id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
                if (edgeTombstoneSliceContains(existing_tombstones.items, edge_id.toInt())) return core.Error.InvalidId;
                const record = try readVisibleEdgeIndexRecordById(self, edge_id);
                const edge_digest = edgeRecordDigest(record);
                batch_tombstones.appendAssumeCapacity(.{
                    .edge_id = record.edge_id,
                    .edge_digest = edge_digest,
                });
                batch_visible_digest ^= edge_digest;
            }
            std.mem.sort(EdgeTombstoneRecord, batch_tombstones.items, {}, edgeTombstoneLessThan);
            for (batch_tombstones.items[1..], 1..) |record, i| {
                if (batch_tombstones.items[i - 1].edge_id == record.edge_id) return core.Error.InvalidId;
            }

            const rollback_event_bytes = try eventBytes(self);
            var published = false;
            errdefer if (!published) rollbackBatchAppend(self, rollback_event_bytes) catch {};

            try appendEdgeDeleteRecordsAt(self, edge_ids, rollback_event_bytes);

            var merged_tombstones = std.ArrayList(EdgeTombstoneRecord).empty;
            defer merged_tombstones.deinit(self.allocator);
            try merged_tombstones.ensureTotalCapacityPrecise(self.allocator, existing_tombstones.items.len + batch_tombstones.items.len);
            try mergeEdgeTombstones(existing_tombstones.items, batch_tombstones.items, &merged_tombstones);
            try writeEdgeTombstoneIndex(self, merged_tombstones.items);

            var next_meta = old_meta;
            next_meta.edges -= @intCast(edge_ids.len);
            next_meta.edge_digest ^= batch_visible_digest;
            next_meta.event_bytes = try eventBytes(self);
            for (edge_ids) |edge_id| next_meta.max_edge_id_seen = @max(next_meta.max_edge_id_seen, edge_id.toInt());
            try writeIndexMeta(self, next_meta);
            published = true;
        }

        pub fn appendEdgesBatch(self: Store, edges: []const graph_mod.Edge) !void {
            if (edges.len == 0) return;
            appendEdgesBatchOnce(self, edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    try repairPersistentIndexesFromLog(self);
                    return try appendEdgesBatchOnce(self, edges);
                },
                else => |e| return e,
            };
        }

        pub fn appendEdgesBatchOnce(self: Store, edges: []const graph_mod.Edge) !void {
            const old_meta = try readCurrentIndexMetaForAppend(self);
            var edge_records = std.ArrayList(EdgeIndexRecord).empty;
            defer edge_records.deinit(self.allocator);
            try edge_records.ensureTotalCapacity(self.allocator, edges.len);

            var next_meta = old_meta;
            const segment_delta_append = try canAppendEdgeBatchAsSegmentDelta(self, old_meta, edges);
            try validateEdgeBatchAppend(self, edges, old_meta, &edge_records, &next_meta, segment_delta_append);

            const rollback_event_bytes = try eventBytes(self);
            var published = false;
            errdefer if (!published) rollbackBatchAppend(self, rollback_event_bytes) catch {};

            try appendEdgeBatchRecords(self, edges, rollback_event_bytes);

            next_meta.event_bytes = try eventBytes(self);
            if (segment_delta_append) {
                next_meta.edge_indexed_edges = old_meta.edge_indexed_edges;
                next_meta.edge_index_digest = old_meta.edge_index_digest;
                try publishEdgeBatchSegmentIfManifestCurrent(self, old_meta, &next_meta, edge_records.items);
            } else {
                const id_result = try writeMergedEdgeIndexBatch(self, self.edge_by_id_path, .id, old_meta, edge_records.items, next_meta.edge_index_digest);
                const src_result = try writeMergedEdgeIndexBatch(self, self.edge_by_src_path, .src, old_meta, edge_records.items, next_meta.edge_index_digest);
                const dst_result = try writeMergedEdgeIndexBatch(self, self.edge_by_dst_path, .dst, old_meta, edge_records.items, next_meta.edge_index_digest);
                next_meta.edge_by_id_order_digest = id_result.order_digest;
                next_meta.edge_by_src_order_digest = src_result.order_digest;
                next_meta.edge_by_dst_order_digest = dst_result.order_digest;
                if (id_result.edge_id_runs) |edge_id_runs| {
                    next_meta.edge_by_id_runs = edge_id_runs;
                } else {
                    try copyEdgeOrderDigestsFromHeaders(self, &next_meta);
                }
                if (!try edgeSegmentMetaSummaryReadable(self, old_meta)) clearEdgeSegmentSummary(&next_meta);
                try publishEdgeBatchSegmentIfManifestCurrent(self, old_meta, &next_meta, edge_records.items);
            }
            try writeIndexMeta(self, next_meta);
            published = true;
            maintainEdgeSegmentsAfterCommittedAppend(self);
        }

        pub fn appendEdgeRecord(self: Store, edge: graph_mod.Edge) !void {
            var payload = std.ArrayList(u8).empty;
            defer payload.deinit(self.allocator);
            try appendU64(&payload, self.allocator, edge.id.toInt());
            try appendU64(&payload, self.allocator, edge.src.toInt());
            try appendU16(&payload, self.allocator, @intFromEnum(edge.rel));
            try appendU64(&payload, self.allocator, edge.dst.toInt());

            var record = std.ArrayList(u8).empty;
            defer record.deinit(self.allocator);
            try appendBinaryRecord(&record, self.allocator, .edge, payload.items);
            try appendRecord(self, record.items);
        }

        pub fn appendEdgeRecordAt(self: Store, edge: graph_mod.Edge, expected_offset: u64) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{ .mode = .read_write, .allow_directory = false });
            defer file.close(self.io);
            if (try regularFileSize(self, file) != expected_offset) return error.InvalidRecord;

            var record: [binary_edge_record_len]u8 = undefined;
            encodeBinaryEdgeRecord(&record, edge);
            try file.writePositionalAll(self.io, &record, expected_offset);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
        }

        pub fn appendEdgeDeleteRecord(self: Store, edge_id: core.EdgeId) !void {
            var record: [binary_edge_delete_record_len]u8 = undefined;
            encodeBinaryEdgeDeleteRecord(&record, edge_id);
            try appendRecord(self, &record);
        }

        pub fn appendEdgeDeleteRecordsAt(self: Store, edge_ids: []const core.EdgeId, expected_offset: u64) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{ .mode = .read_write, .allow_directory = false });
            defer file.close(self.io);
            if (try regularFileSize(self, file) != expected_offset) return error.InvalidRecord;

            var offset = expected_offset;
            var record: [binary_edge_delete_record_len]u8 = undefined;
            for (edge_ids) |edge_id| {
                encodeBinaryEdgeDeleteRecord(&record, edge_id);
                try file.writePositionalAll(self.io, &record, offset);
                offset = std.math.add(u64, offset, record.len) catch return error.InvalidRecord;
            }
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
        }

        pub fn ensureRawNodeTextsFile(self: Store) !void {
            return primary_node_text.ensureRaw(self);
        }

        pub fn compressNodeTextsFileIfSmaller(self: Store) !void {
            _ = try primary_node_text.compressIfSmaller(self);
        }

        pub fn compressNodeTextsFileIfSmallerWithResult(self: Store) !NodeTextsCompressionResult {
            return primary_node_text.compressIfSmaller(self);
        }

        pub fn finalizePrimaryTextStorage(self: Store) !void {
            _ = try primary_node_text.finalize(self);
        }

        pub fn finalizePrimaryTextStorageWithResult(self: Store) !NodeTextsCompressionResult {
            return primary_node_text.finalize(self);
        }

        pub fn primaryNodeTextLogicalBytes(self: Store) !u64 {
            return primary_node_text.logicalSize(self);
        }

        pub fn nodeTextsLogicalSize(self: Store) !u64 {
            return primary_node_text.logicalSize(self);
        }

        pub fn appendNodeTextBytes(self: Store, text: []const u8) !TextSpan {
            return primary_node_text.appendOne(self, text);
        }

        pub fn appendNodeTextsBatch(self: Store, nodes: []const graph_mod.Node) ![]TextSpan {
            return primary_node_text.appendBatch(self, nodes);
        }

        pub fn reconcileNodeTextsBeforeAppend(self: Store) !void {
            return primary_node_text.reconcileBeforeAppend(self);
        }

        pub fn nodeTextsAppendJournalPath(self: Store, buffer: []u8) ![]const u8 {
            return primary_node_text.appendJournalPath(self, buffer);
        }

        pub fn writeNodeTextsAppendJournal(self: Store, texts: *const NodeTextsView, suffix_offset: u64) !void {
            return primary_node_text.writeAppendJournal(self, texts, suffix_offset);
        }

        pub fn writeRawNodeTextsAppendJournal(self: Store, original_size: u64) !void {
            return primary_node_text.writeRawAppendJournal(self, original_size);
        }

        pub fn cleanupCommittedNodeTextsAppendJournal(self: Store) void {
            primary_node_text.cleanupCommittedAppendJournal(self);
        }

        pub fn markNodeTextsAppendJournalCommitted(self: Store) !void {
            return primary_node_text.markAppendJournalCommitted(self);
        }

        pub fn commitNodeTextsAppendJournalAfterMutation(self: Store) !void {
            return primary_node_text.commitAppendJournalAfterMutation(self);
        }

        pub fn recoverNodeTextsAppendJournal(self: Store) !NodeTextsAppendRecovery {
            return primary_node_text.recoverAppendJournal(self);
        }

        pub fn mutateCompressedNodeTextSlicesInPlace(self: Store, texts: *const NodeTextsView, slices: []const []const u8, append_bytes: u64) !void {
            return primary_node_text.mutateCompressedSlicesInPlace(self, texts, slices, append_bytes);
        }

        pub fn deflateNodeTextsBlock(input: []const u8, output: []u8, flate_buffer: []u8) usize {
            return primary_node_text.deflateBlock(input, output, flate_buffer);
        }

        pub fn appendNodeBatchRecords(self: Store, nodes: []const graph_mod.Node, text_spans: []const TextSpan, expected_offset: u64) !void {
            if (nodes.len != text_spans.len) return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{ .mode = .read_write, .allow_directory = false });
            defer file.close(self.io);
            if (try regularFileSize(self, file) != expected_offset) return error.InvalidRecord;

            var writer = try StorageBufferedWriter.initAtOffset(self.allocator, self.io, file, storage_write_buffer_bytes, expected_offset);
            defer writer.deinit();

            var marker_bytes: [BinaryRecordHeader.encoded_len]u8 = undefined;
            encodeBinaryRecordHeader(&marker_bytes, .batch_begin, 0, binaryPayloadChecksum(&.{}));
            try writer.append(&marker_bytes);

            var node_offset: usize = 0;
            while (node_offset < nodes.len) {
                const node_count = @min(nodes.len - node_offset, binary_node_batch_max_count);
                try appendBinaryNodeBatchRecordToWriter(
                    &writer,
                    self.allocator,
                    nodes[node_offset..][0..node_count],
                    text_spans[node_offset..][0..node_count],
                );
                node_offset += node_count;
            }

            encodeBinaryRecordHeader(&marker_bytes, .batch_commit, 0, binaryPayloadChecksum(&.{}));
            try writer.append(&marker_bytes);
            try writer.flush();
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
        }

        pub fn appendEdgeBatchRecords(self: Store, edges: []const graph_mod.Edge, expected_offset: u64) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{ .mode = .read_write, .allow_directory = false });
            defer file.close(self.io);
            if (try regularFileSize(self, file) != expected_offset) return error.InvalidRecord;

            var writer = try StorageBufferedWriter.initAtOffset(self.allocator, self.io, file, storage_write_buffer_bytes, expected_offset);
            defer writer.deinit();

            var marker_bytes: [BinaryRecordHeader.encoded_len]u8 = undefined;
            encodeBinaryRecordHeader(&marker_bytes, .batch_begin, 0, binaryPayloadChecksum(&.{}));
            try writer.append(&marker_bytes);

            var edge_offset: usize = 0;
            while (edge_offset < edges.len) {
                const edge_count = @min(edges.len - edge_offset, binary_edge_batch_max_count);
                try appendBinaryEdgeBatchRecordToWriter(&writer, self.allocator, edges[edge_offset..][0..edge_count]);
                edge_offset += edge_count;
            }

            encodeBinaryRecordHeader(&marker_bytes, .batch_commit, 0, binaryPayloadChecksum(&.{}));
            try writer.append(&marker_bytes);
            try writer.flush();
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
        }

        pub fn appendBatchMarker(self: Store, kind: BinaryRecordKind) !void {
            switch (kind) {
                .batch_begin, .batch_commit => {},
                .node, .node_batch, .edge, .edge_batch, .edge_delete => return core.Error.Unsupported,
            }
            var record = std.ArrayList(u8).empty;
            defer record.deinit(self.allocator);
            try appendBinaryRecord(&record, self.allocator, kind, &.{});
            try appendRecord(self, record.items);
        }

        pub fn nextNodeId(self: Store) !core.NodeId {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{});
            defer file.close(self.io);
            const meta = try readCurrentIndexMetaForAppend(self);
            const header = try readNodeByIdHeaderFromFile(self, file);
            if (header.node_count != meta.nodes) return error.InvalidRecord;
            const expected_size = try nodeByIdFileSizeForHeaderStore(self, header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (self.options.validate_indexes_on_read and !try nodeIndexValid(self, meta.nodes)) return error.InvalidRecord;
            if (header.max_node_id == std.math.maxInt(u64)) return error.InvalidRecord;
            const growth_flags: u16 = if (header.hasDerivedTextOffset()) NodeByIdHeader.flag_uniform_kind else header.flags;
            const growth_record_len: u16 = if (header.hasDerivedTextOffset()) NodeByIdRecord.uniform_encoded_len else header.record_len;
            _ = try nodeByIdFileSizeForHeaderStore(self, .{
                .max_node_id = header.max_node_id + 1,
                .node_count = header.node_count,
                .node_digest = header.node_digest,
                .flags = growth_flags,
                .record_len = growth_record_len,
                .uniform_kind = header.uniform_kind,
            });
            return core.NodeId.fromInt(header.max_node_id + 1);
        }

        pub fn nodeIndexLayoutHint(self: Store) !?NodeIndexLayoutHint {
            var file = std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(self.io);

            const meta = try readCurrentIndexMetaForAppend(self);
            const header = try readNodeByIdHeaderFromFile(self, file);
            if (header.node_count != meta.nodes) return error.InvalidRecord;
            if (header.node_digest != meta.node_digest) return error.InvalidRecord;
            const expected_size = try nodeByIdFileSizeForHeaderStore(self, header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            const dense_node_id_base: u32 = if (header.node_count != 0 and header.node_count == header.max_node_id and header.max_node_id <= std.math.maxInt(u32))
                1
            else
                0;
            const uniform_kind = if (header.hasUniformKind())
                nodeKindFromInt(header.uniform_kind) orelse return error.InvalidRecord
            else
                null;
            return .{
                .node_count = header.node_count,
                .dense_node_id_base = dense_node_id_base,
                .uniform_kind = uniform_kind,
            };
        }

        pub fn searchableNodeIndexLayoutHint(self: Store) !?NodeIndexLayoutHint {
            const hint = (try nodeIndexLayoutHint(self)) orelse return null;
            if (hint.node_count == 0) return hint;
            const uniform_kind = hint.uniform_kind orelse return null;
            // Deleted-node tombstones are stored as edit nodes with reserved text.
            // A uniform non-edit catalog proves every active node is searchable
            // without scanning text; mixed or edit-only catalogs must be checked
            // by the caller because they may contain tombstones.
            if (uniform_kind == .edit) return null;
            return hint;
        }

        pub fn nextEdgeId(self: Store) !core.EdgeId {
            const meta = try readCurrentIndexMetaForAppend(self);
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != .id or header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            if (header.order_digest != edgeOrderDigestForMeta(meta, .id)) return error.InvalidRecord;
            const expected_size = try edgeIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (header.edge_count != 0) {
                const last = try readEdgeIndexRecordAt(self, file, header, header.edge_count - 1);
                if (meta.max_edge_id_seen < last.edge_id) return error.InvalidRecord;
            }
            if (self.options.validate_indexes_on_read) {
                if (!try edgeIndexesValidatedAndMatchMeta(self, meta)) return error.InvalidRecord;
            }
            const max_edge_id = meta.max_edge_id_seen;
            if (max_edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            return core.EdgeId.fromInt(max_edge_id + 1);
        }

        pub fn readCurrentIndexMeta(self: Store) !IndexMeta {
            if (!self.options.validate_indexes_on_read and self.index_meta_cache.valid) {
                const meta = self.index_meta_cache.meta;
                if (meta.event_bytes == try eventBytes(self)) return meta;
                self.index_meta_cache.clear();
            }
            const meta = try readIndexMeta(self);
            if (meta.event_bytes != try eventBytes(self)) return error.InvalidRecord;
            if (!self.options.validate_indexes_on_read) {
                self.index_meta_cache.meta = meta;
                self.index_meta_cache.valid = true;
            }
            return meta;
        }

        pub fn readCurrentIndexMetaForAppend(self: Store) !IndexMeta {
            const meta = try readCurrentIndexMeta(self);
            if (!self.options.validate_indexes_on_read) return meta;
            const stats_out = try stats(self);
            if (meta.nodes != stats_out.nodes) return error.InvalidRecord;
            if (meta.edges != stats_out.edges) return error.InvalidRecord;
            if (meta.node_digest != stats_out.node_digest) return error.InvalidRecord;
            if (meta.edge_digest != stats_out.edge_digest) return error.InvalidRecord;
            return meta;
        }

        pub fn loadGraph(self: Store) !graph_mod.Graph {
            return loadGraphDeadline(self, .none);
        }

        pub fn loadGraphDeadline(self: Store, deadline: core.QueryDeadline) !graph_mod.Graph {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            var graph = graph_mod.Graph.init(self.allocator);
            errdefer graph.deinit();

            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{});
            defer file.close(self.io);
            try replayBinaryEvents(self, &graph, file, deadline);
            return graph;
        }

        pub fn loadSnapshot(self: Store) !snapshot_mod.GraphSnapshot {
            const graph = try loadGraph(self);
            var snapshot = try snapshot_mod.GraphSnapshot.init(self.allocator, graph);
            errdefer snapshot.deinit();
            try ensurePersistentNodeIndexes(self, &snapshot.graph);
            try ensurePersistentEdgeIndexes(self, &snapshot.graph);

            const expected = try currentIndexMetaFromIndexes(self, &snapshot.graph);
            const current = readIndexMeta(self) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => null,
                else => |e| return e,
            };
            if (current == null or !indexMetaEquals(current.?, expected)) {
                try writeIndexMeta(self, expected);
                _ = dropRedundantEdgeSegmentOverlayAfterBaseIndexCatchup(self) catch {};
            }
            return snapshot;
        }

        pub fn repairPersistentIndexesFromLog(self: Store) !void {
            var timings = PersistentRepairTimings{};
            try repairPersistentIndexesFromLogWithTimings(self, &timings);
        }

        pub fn repairPersistentIndexesFromLogWithTimings(self: Store, timings: *PersistentRepairTimings) !void {
            try repair_session.repair(self, timings);
        }

        pub fn validatePersistentIndexes(self: Store) !void {
            var timings = PersistentValidateTimings{};
            try validatePersistentIndexesWithTimings(self, &timings);
        }

        pub fn validatePersistentIndexesWithTimings(self: Store, timings: *PersistentValidateTimings) !void {
            timings.* = .{};
            const stats_start = storageMonotonicNs(self.io);
            const stats_out = try stats(self);
            timings.stats_ns = storageElapsedNs(self.io, stats_start);
            if (!try persistentIndexesCurrentWithTimings(self, stats_out, timings)) return error.InvalidRecord;
        }

        pub fn validatePersistentIndexFiles(self: Store) !void {
            if (!try fastPersistentIndexesCurrent(self)) return error.InvalidRecord;
        }

        pub fn refreshIndexesAfterCommittedAppend(self: Store, kind: BinaryRecordKind, node: ?graph_mod.Node, edge: ?graph_mod.Edge, node_text_span: ?TextSpan) bool {
            tryRefreshIndexesAfterCommittedAppend(self, kind, node, edge, node_text_span) catch {
                // The append log write already committed the event; surfacing
                // derived-index repair failure here would invite unsafe retries.
                // Report whether repair completed so node append can retain its
                // committed text journal when the indexes are still unusable.
                repairPersistentIndexesFromLog(self) catch return false;
            };
            return true;
        }

        pub fn tryRefreshIndexesAfterCommittedAppend(self: Store, kind: BinaryRecordKind, node: ?graph_mod.Node, edge: ?graph_mod.Edge, node_text_span: ?TextSpan) !void {
            switch (kind) {
                .node => try appendNodeIndexRecord(self, node.?, node_text_span orelse return error.InvalidRecord),
                .edge => try appendEdgeIndexRecord(self, edge.?),
                .edge_delete => return core.Error.Unsupported,
                .node_batch, .edge_batch, .batch_begin, .batch_commit => return core.Error.Unsupported,
            }
            const meta_start = if (kind == .node and self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
            try refreshIndexMetaAfterAppend(self, kind, node, edge);
            if (kind == .node) {
                if (self.node_append_timings) |timings| timings.meta_write_ns += storageElapsedNs(self.io, meta_start);
            }
        }

        pub fn maintainEdgeSegmentsAfterCommittedAppend(self: Store) void {
            const start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
            defer if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.segment_maintenance_calls += 1;
                delta_stats.segment_maintenance_ns += storageElapsedNs(self.io, start);
            };
            edge_segment_maintenance.afterCommittedAppend(self);
        }

        pub fn invalidateEdgeSegmentCurrent(self: Store) !void {
            std.Io.Dir.cwd().deleteFile(self.io, self.edge_segment_current_path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => |e| return e,
            };
            try syncParentDirForPath(self, self.edge_segment_current_path);
        }

        pub fn invalidateNodeTextRunCurrent(self: Store) !void {
            std.Io.Dir.cwd().deleteFile(self.io, self.node_text_run_current_path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => |e| return e,
            };
            try syncParentDirForPath(self, self.node_text_run_current_path);
        }

        pub fn hasCatalog(self: Store) !bool {
            return fileExists(self, self.catalog_path);
        }

        pub fn readCatalog(self: Store) !?catalog_mod.Catalog {
            const maybe_bytes = try readCatalogBytesAlloc(self, self.allocator);
            const bytes = maybe_bytes orelse return null;
            defer self.allocator.free(bytes);
            return try catalog_mod.decodeCatalog(self.allocator, bytes);
        }

        pub fn readCatalogBytesAlloc(self: Store, allocator: std.mem.Allocator) !?[]u8 {
            var file = std.Io.Dir.cwd().openFile(self.io, self.catalog_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.kind != .file or stat.size == 0 or stat.size > catalog_max_bytes) return error.InvalidRecord;
            const size: usize = @intCast(stat.size);
            const bytes = try allocator.alloc(u8, size);
            errdefer allocator.free(bytes);
            const read = try file.readPositionalAll(self.io, bytes, 0);
            if (read != bytes.len) return error.InvalidRecord;
            return bytes;
        }

        pub fn writeCatalog(self: Store, cat: catalog_mod.Catalog) !void {
            const encoded = try catalog_mod.encodeCatalog(self.allocator, cat);
            defer self.allocator.free(encoded);
            try writeCatalogEncoded(self, encoded);
        }

        pub fn restoreCatalogBytes(self: Store, encoded: []const u8) !void {
            var decoded = try catalog_mod.decodeCatalog(self.allocator, encoded);
            decoded.deinit();
            try writeCatalogEncoded(self, encoded);
        }

        pub fn writeCatalogEncoded(self: Store, encoded: []const u8) !void {
            const tmp_path = try tmpPathFor(self, self.catalog_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                try file.writePositionalAll(self.io, encoded, 0);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.catalog_path);
        }

        pub fn writeKernelCatalog(self: Store) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const cat = try catalog_mod.Catalog.kernelOnly(arena.allocator());
            try writeCatalog(self, cat);
        }

        pub fn stats(self: Store) !StoreStats {
            var state = EventCountState.init(self.allocator);
            defer state.deinit();
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{});
            defer file.close(self.io);
            try countBinaryEvents(self, file, &state);
            return state.stats;
        }

        pub fn nodeEventCountUpTo(self: Store, max_nodes: u64) !u64 {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{});
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            var offset: u64 = 0;
            var count: u64 = 0;
            var in_batch = false;
            while (true) {
                const parsed = try readBinaryRecordHeader(self, file, &offset) orelse break;
                try ensureBinaryPayloadFits(file_size, offset, parsed.payload_len);
                var prefix: [max_binary_count_payload_prefix_len]u8 = undefined;
                var prefix_len: usize = 0;
                try readBinaryPayloadPrefixAndValidateChecksum(self, file, offset, parsed, &prefix, &prefix_len);
                try advanceBinaryOffset(&offset, parsed.payload_len);
                const added: u64 = switch (parsed.kind) {
                    .batch_begin => blk: {
                        if (in_batch or parsed.payload_len != 0) return error.InvalidRecord;
                        in_batch = true;
                        break :blk 0;
                    },
                    .batch_commit => blk: {
                        if (!in_batch or parsed.payload_len != 0) return error.InvalidRecord;
                        in_batch = false;
                        break :blk 0;
                    },
                    .node => blk: {
                        _ = try validateBinaryNodePayloadForCount(prefix[0..prefix_len], parsed.payload_len);
                        break :blk 1;
                    },
                    .node_batch => blk: {
                        if (!in_batch) return error.InvalidRecord;
                        break :blk try binaryNodeBatchCountFromPrefix(prefix[0..prefix_len], parsed.payload_len);
                    },
                    .edge, .edge_batch, .edge_delete => 0,
                };
                count = std.math.add(u64, count, added) catch return error.RecordTooLarge;
                if (count > max_nodes) return std.math.add(u64, max_nodes, 1) catch return error.RecordTooLarge;
                if (offset == file_size and in_batch) return error.InvalidRecord;
            }
            if (in_batch) return error.InvalidRecord;
            return count;
        }

        pub fn fileExists(self: Store, path: []const u8) !bool {
            var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                error.NotDir => return false,
                error.IsDir => return false,
                else => |e| return e,
            };
            defer file.close(self.io);
            return (try file.stat(self.io)).kind == .file;
        }

        pub fn pathExists(self: Store, path: []const u8) !bool {
            var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                error.NotDir => return false,
                error.IsDir => return true,
                else => |e| return e,
            };
            defer file.close(self.io);
            return true;
        }

        pub fn anyDerivedGraphCatalogPathExists(self: Store) !bool {
            inline for (&.{
                self.index_meta_path,
                self.node_by_id_path,
                self.node_texts_path,
                self.node_by_text_path,
                self.node_by_text_delta_path,
                self.external_key_index_path,
                self.node_props_index_path,
                self.node_props_values_path,
                self.node_props_overlay_index_path,
                self.node_props_overlay_values_path,
                self.edge_props_overlay_index_path,
                self.edge_props_overlay_values_path,
                self.property_payload_index_path,
                self.property_payload_values_path,
                self.property_payload_delta_path,
                self.edge_external_key_index_path,
                self.node_text_run_manifest_path,
                self.node_text_run_current_path,
                self.edge_by_id_path,
                self.edge_by_src_path,
                self.edge_by_dst_path,
                self.edge_tombstones_path,
                self.catalog_path,
            }) |path| {
                if (try pathExists(self, path)) return true;
            }
            var node_text_journal_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const node_text_journal_path = try nodeTextsAppendJournalPath(self, &node_text_journal_buffer);
            if (try pathExists(self, node_text_journal_path)) return true;
            const node_text_journal_tmp_path = try tmpPathFor(self, node_text_journal_path);
            defer self.allocator.free(node_text_journal_tmp_path);
            if (try pathExists(self, node_text_journal_tmp_path)) return true;
            const primary_text_tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.deflate.tmp", .{self.node_texts_path});
            defer self.allocator.free(primary_text_tmp_path);
            if (try pathExists(self, primary_text_tmp_path)) return true;
            const primary_text_table_tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.deflate.table.tmp", .{self.node_texts_path});
            defer self.allocator.free(primary_text_table_tmp_path);
            if (try pathExists(self, primary_text_table_tmp_path)) return true;
            return false;
        }

        pub fn ensureStoreMarkerExists(self: Store) !void {
            if (try fileExists(self, self.events_bin_path)) return;
            return error.FileNotFound;
        }

        pub fn replayBinaryEvents(self: Store, graph: *graph_mod.Graph, file: std.Io.File, deadline: core.QueryDeadline) !void {
            var offset: u64 = 0;
            const file_size = try regularFileSize(self, file);
            var texts: ?NodeTextsView = null;
            defer if (texts) |*view| view.deinit();
            var in_batch = false;
            while (true) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const parsed = try readBinaryRecordHeader(self, file, &offset) orelse break;
                try ensureBinaryPayloadFits(file_size, offset, parsed.payload_len);
                const payload = try self.allocator.alloc(u8, parsed.payload_len);
                defer self.allocator.free(payload);
                const payload_len = try file.readPositionalAll(self.io, payload, offset);
                if (payload_len != payload.len) return error.InvalidRecord;
                try advanceBinaryOffset(&offset, payload.len);
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
                        if (texts == null) texts = try NodeTextsView.open(self);
                        const text = try texts.?.readTextAlloc(self.allocator, parsed_node.text_offset, parsed_node.text_len);
                        defer self.allocator.free(text);
                        graph.addNodeWithId(core.NodeId.fromInt(parsed_node.id), parsed_node.kind, text) catch |err| switch (err) {
                            core.Error.InvalidId => return error.InvalidRecord,
                            else => |e| return e,
                        };
                    },
                    .node_batch => {
                        if (!in_batch) return error.InvalidRecord;
                        var batch_reader = try BinaryNodeBatchReader.init(payload);
                        while (try batch_reader.next()) |parsed_node| {
                            if (deadline.expired()) return core.Error.BudgetExceeded;
                            {
                                if (texts == null) texts = try NodeTextsView.open(self);
                                const text = try texts.?.readTextAlloc(self.allocator, parsed_node.text_offset, parsed_node.text_len);
                                defer self.allocator.free(text);
                                graph.addNodeWithId(core.NodeId.fromInt(parsed_node.id), parsed_node.kind, text) catch |err| switch (err) {
                                    core.Error.InvalidId => return error.InvalidRecord,
                                    else => |e| return e,
                                };
                            }
                        }
                    },
                    .edge, .edge_delete => try replayBinaryRecord(graph, parsed.kind, payload, deadline),
                    .edge_batch => {
                        if (!in_batch) return error.InvalidRecord;
                        try replayBinaryRecord(graph, parsed.kind, payload, deadline);
                    },
                }
                if (deadline.expired()) return core.Error.BudgetExceeded;
            }
            if (in_batch) return error.InvalidRecord;
            if (deadline.expired()) return core.Error.BudgetExceeded;
        }

        pub fn countBinaryEvents(self: Store, file: std.Io.File, state: *EventCountState) !void {
            var offset: u64 = 0;
            const file_size = try regularFileSize(self, file);
            var texts: ?NodeTextsView = null;
            defer if (texts) |*view| view.deinit();
            var in_batch = false;
            while (true) {
                const parsed = try readBinaryRecordHeader(self, file, &offset) orelse return;
                try ensureBinaryPayloadFits(file_size, offset, parsed.payload_len);
                const payload_offset = offset;
                if (parsed.kind == .node_batch) {
                    const payload = try readBinaryPayloadAllocAndValidateChecksum(self, file, offset, parsed);
                    defer self.allocator.free(payload);
                    try advanceBinaryOffset(&offset, payload.len);
                    if (!in_batch) return error.InvalidRecord;
                    if (texts == null) texts = try NodeTextsView.open(self);
                    var batch_reader = try BinaryNodeBatchReader.init(payload);
                    while (try batch_reader.next()) |node| {
                        try state.addNode(node.id, try texts.?.digestStoredNode(node.id, node.kind, node.text_offset, node.text_len));
                    }
                    if (offset == file_size and in_batch) return error.InvalidRecord;
                    continue;
                }
                if (parsed.kind == .edge_batch) {
                    const payload = try readBinaryPayloadAllocAndValidateChecksum(self, file, offset, parsed);
                    defer self.allocator.free(payload);
                    try advanceBinaryOffset(&offset, payload.len);
                    if (!in_batch) return error.InvalidRecord;
                    const batch = try validateBinaryEdgeBatchHeader(payload);
                    var index: u32 = 0;
                    while (index < batch.count) : (index += 1) {
                        const edge = try validateBinaryEdgeBatchEdge(payload, batch, index);
                        try state.addEdge(edge.id, edge.src, @intFromEnum(edge.rel), edge.dst);
                    }
                    if (offset == file_size and in_batch) return error.InvalidRecord;
                    continue;
                }
                var prefix: [max_binary_count_payload_prefix_len]u8 = undefined;
                var prefix_len: usize = 0;
                try readBinaryPayloadPrefixAndValidateChecksum(self, file, offset, parsed, &prefix, &prefix_len);
                try advanceBinaryOffset(&offset, parsed.payload_len);
                switch (parsed.kind) {
                    .batch_begin => {
                        if (in_batch) return error.InvalidRecord;
                        if (parsed.payload_len != 0) return error.InvalidRecord;
                        in_batch = true;
                    },
                    .batch_commit => {
                        if (!in_batch) return error.InvalidRecord;
                        if (parsed.payload_len != 0) return error.InvalidRecord;
                        in_batch = false;
                    },
                    .node => {
                        const node = try validateBinaryNodePayloadForCount(prefix[0..prefix_len], parsed.payload_len);
                        _ = payload_offset;
                        if (texts == null) texts = try NodeTextsView.open(self);
                        try state.addNode(node.id, try texts.?.digestStoredNode(node.id, node.kind, node.text_offset, node.text_len));
                    },
                    .node_batch => unreachable,
                    .edge => {
                        if (prefix_len != binary_edge_payload_len) return error.InvalidRecord;
                        const edge = try validateBinaryEdgePayload(prefix[0..binary_edge_payload_len]);
                        try state.addEdge(edge.id, edge.src, @intFromEnum(edge.rel), edge.dst);
                    },
                    .edge_delete => {
                        if (prefix_len != binary_edge_delete_payload_len) return error.InvalidRecord;
                        const edge_id = try validateBinaryEdgeDeletePayload(prefix[0..binary_edge_delete_payload_len]);
                        try state.deleteEdge(edge_id.toInt());
                    },
                    .edge_batch => unreachable,
                }
                if (offset == file_size and in_batch) return error.InvalidRecord;
            }
        }

        pub fn maxEdgeIdEverSeenInLog(self: Store) !u64 {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{});
            defer file.close(self.io);
            var offset: u64 = 0;
            const file_size = try regularFileSize(self, file);
            var max_edge_id: u64 = 0;
            var in_batch = false;
            while (true) {
                const parsed = try readBinaryRecordHeader(self, file, &offset) orelse break;
                try ensureBinaryPayloadFits(file_size, offset, parsed.payload_len);
                if (parsed.kind == .node_batch) {
                    const payload = try readBinaryPayloadAllocAndValidateChecksum(self, file, offset, parsed);
                    defer self.allocator.free(payload);
                    try advanceBinaryOffset(&offset, payload.len);
                    if (!in_batch) return error.InvalidRecord;
                    try validateBinaryNodeBatchPayload(payload);
                    continue;
                }
                if (parsed.kind == .edge_batch) {
                    const payload = try readBinaryPayloadAllocAndValidateChecksum(self, file, offset, parsed);
                    defer self.allocator.free(payload);
                    try advanceBinaryOffset(&offset, payload.len);
                    if (!in_batch) return error.InvalidRecord;
                    const batch = try validateBinaryEdgeBatchHeader(payload);
                    var index: u32 = 0;
                    while (index < batch.count) : (index += 1) {
                        const edge = try validateBinaryEdgeBatchEdge(payload, batch, index);
                        max_edge_id = @max(max_edge_id, edge.id);
                    }
                    continue;
                }
                var prefix: [max_binary_count_payload_prefix_len]u8 = undefined;
                var prefix_len: usize = 0;
                try readBinaryPayloadPrefixAndValidateChecksum(self, file, offset, parsed, &prefix, &prefix_len);
                try advanceBinaryOffset(&offset, parsed.payload_len);
                switch (parsed.kind) {
                    .batch_begin => {
                        if (in_batch or parsed.payload_len != 0) return error.InvalidRecord;
                        in_batch = true;
                    },
                    .batch_commit => {
                        if (!in_batch or parsed.payload_len != 0) return error.InvalidRecord;
                        in_batch = false;
                    },
                    .node => {},
                    .node_batch => unreachable,
                    .edge => {
                        if (prefix_len != binary_edge_payload_len) return error.InvalidRecord;
                        const edge = try validateBinaryEdgePayload(prefix[0..binary_edge_payload_len]);
                        max_edge_id = @max(max_edge_id, edge.id);
                    },
                    .edge_delete => {
                        if (prefix_len != binary_edge_delete_payload_len) return error.InvalidRecord;
                        const edge_id = (try validateBinaryEdgeDeletePayload(prefix[0..binary_edge_delete_payload_len])).toInt();
                        max_edge_id = @max(max_edge_id, edge_id);
                    },
                    .edge_batch => unreachable,
                }
            }
            if (in_batch) return error.InvalidRecord;
            return max_edge_id;
        }

        pub fn regularFileSize(self: Store, file: std.Io.File) !u64 {
            const stat = try file.stat(self.io);
            if (stat.kind != .file) return error.IsDir;
            return stat.size;
        }

        pub fn readBinaryRecordHeader(self: Store, file: std.Io.File, offset: *u64) !?BinaryRecordHeader {
            var bytes: [BinaryRecordHeader.encoded_len]u8 = undefined;
            const header_len = try file.readPositionalAll(self.io, &bytes, offset.*);
            if (header_len == 0) return null;
            if (header_len != bytes.len) return error.InvalidRecord;
            try advanceBinaryOffset(offset, bytes.len);
            const header = try BinaryRecordHeader.decode(&bytes);
            return header;
        }

        pub fn advanceBinaryOffset(offset: *u64, amount: usize) !void {
            offset.* = std.math.add(u64, offset.*, amount) catch return error.InvalidRecord;
        }

        pub fn readBinaryPayloadPrefixAndValidateChecksum(
            self: Store,
            file: std.Io.File,
            payload_offset: u64,
            header: BinaryRecordHeader,
            prefix: *[max_binary_count_payload_prefix_len]u8,
            prefix_len: *usize,
        ) !void {
            var hasher = std.hash.Wyhash.init(0);
            var remaining: usize = header.payload_len;
            var offset = payload_offset;
            prefix_len.* = 0;
            var buffer: [binary_count_read_chunk_len]u8 = undefined;
            while (remaining != 0) {
                const chunk_len = @min(buffer.len, remaining);
                const chunk = buffer[0..chunk_len];
                const read_len = try file.readPositionalAll(self.io, chunk, offset);
                if (read_len != chunk.len) return error.InvalidRecord;
                hasher.update(chunk);
                if (prefix_len.* < prefix.len) {
                    const copy_len = @min(chunk.len, prefix.len - prefix_len.*);
                    @memcpy(prefix[prefix_len.* .. prefix_len.* + copy_len], chunk[0..copy_len]);
                    prefix_len.* += copy_len;
                }
                try advanceBinaryOffset(&offset, chunk.len);
                remaining -= chunk.len;
            }
            try validateBinaryChecksumValue(header, hasher.final());
        }

        pub fn readBinaryPayloadAllocAndValidateChecksum(self: Store, file: std.Io.File, payload_offset: u64, header: BinaryRecordHeader) ![]u8 {
            const payload = try self.allocator.alloc(u8, header.payload_len);
            errdefer self.allocator.free(payload);
            const read_len = try file.readPositionalAll(self.io, payload, payload_offset);
            if (read_len != payload.len) return error.InvalidRecord;
            try validateBinaryChecksum(header, payload);
            return payload;
        }

        pub fn binaryPayloadDigest(self: Store, file: std.Io.File, payload_offset: u64, payload_len: u32) !u64 {
            var hasher = std.hash.Wyhash.init(0);
            var remaining: usize = payload_len;
            var offset = payload_offset;
            var buffer: [binary_count_read_chunk_len]u8 = undefined;
            while (remaining != 0) {
                const chunk_len = @min(buffer.len, remaining);
                const chunk = buffer[0..chunk_len];
                const read_len = try file.readPositionalAll(self.io, chunk, offset);
                if (read_len != chunk.len) return error.InvalidRecord;
                hasher.update(chunk);
                try advanceBinaryOffset(&offset, chunk.len);
                remaining -= chunk.len;
            }
            return hasher.final();
        }

        pub fn appendRecord(self: Store, record: []const u8) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{ .mode = .read_write, .allow_directory = false });
            defer file.close(self.io);

            const size = try regularFileSize(self, file);
            try file.writePositionalAll(self.io, record, size);
            if (selfOptionsNeedSync(self)) {
                try file.sync(self.io);
            }
        }

        pub fn rollbackBatchAppend(self: Store, event_bytes: u64) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{ .mode = .read_write, .allow_directory = false });
            defer file.close(self.io);
            try file.setLength(self.io, event_bytes);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
            try repairPersistentIndexesFromLog(self);
        }

        pub fn truncateIncompleteBatchTail(self: Store) !bool {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{ .mode = .read_write, .allow_directory = false });
            defer file.close(self.io);

            var offset: u64 = 0;
            const file_size = try regularFileSize(self, file);
            var batch_begin_offset: ?u64 = null;
            while (offset < file_size) {
                const record_start = offset;
                const parsed = readBinaryRecordHeader(self, file, &offset) catch |err| switch (err) {
                    error.InvalidRecord => {
                        if (batch_begin_offset) |begin| return try truncateEventLogTo(self, file, begin);
                        return err;
                    },
                    else => |e| return e,
                } orelse break;
                ensureBinaryPayloadFits(file_size, offset, parsed.payload_len) catch |err| switch (err) {
                    error.InvalidRecord => {
                        if (batch_begin_offset) |begin| return try truncateEventLogTo(self, file, begin);
                        return err;
                    },
                    else => |e| return e,
                };

                const payload = try self.allocator.alloc(u8, parsed.payload_len);
                defer self.allocator.free(payload);
                const payload_len = try file.readPositionalAll(self.io, payload, offset);
                if (payload_len != payload.len) {
                    if (batch_begin_offset) |begin| return try truncateEventLogTo(self, file, begin);
                    return error.InvalidRecord;
                }
                advanceBinaryOffset(&offset, payload.len) catch return error.InvalidRecord;
                validateBinaryChecksum(parsed, payload) catch |err| switch (err) {
                    error.InvalidRecord => {
                        if (batch_begin_offset) |begin| return try truncateEventLogTo(self, file, begin);
                        return err;
                    },
                    else => |e| return e,
                };
                validateBinaryRecordPayload(parsed.kind, payload) catch |err| switch (err) {
                    error.InvalidRecord => {
                        if (batch_begin_offset) |begin| return try truncateEventLogTo(self, file, begin);
                        return err;
                    },
                    else => |e| return e,
                };

                switch (parsed.kind) {
                    .batch_begin => {
                        if (batch_begin_offset != null) return error.InvalidRecord;
                        batch_begin_offset = record_start;
                    },
                    .batch_commit => {
                        if (batch_begin_offset == null) return error.InvalidRecord;
                        batch_begin_offset = null;
                    },
                    .node, .node_batch, .edge, .edge_batch, .edge_delete => {},
                }
            }
            if (batch_begin_offset) |begin| return try truncateEventLogTo(self, file, begin);
            return false;
        }

        pub fn truncateEventLogTo(self: Store, file: std.Io.File, event_bytes: u64) !bool {
            try file.setLength(self.io, event_bytes);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
            return true;
        }

        pub fn rebuildPersistentIndexesFromLogStreamingReuseTexts(
            self: Store,
            reuse_node_texts: bool,
            timings: ?*PersistentRepairTimings,
        ) !void {
            try persistent_rebuild_pipeline.rebuild(self, reuse_node_texts, timings);
        }

        pub fn readIndexMeta(self: Store) !IndexMeta {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.index_meta_path, .{});
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            var bytes: [index_meta_format.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            if (file_size != bytes.len) return error.InvalidRecord;
            return index_meta_format.decode(&bytes);
        }

        pub fn eventByteCount(self: Store) !u64 {
            return eventBytes(self);
        }

        pub fn propertyPayloadDeltaByteCount(self: Store) !u64 {
            var file = std.Io.Dir.cwd().openFile(self.io, self.property_payload_delta_path, .{ .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => return 0,
                else => |e| return e,
            };
            defer file.close(self.io);
            return regularFileSize(self, file);
        }

        pub fn writeIndexMeta(self: Store, meta: IndexMeta) !void {
            var bytes: [index_meta_format.encoded_len]u8 = undefined;
            index_meta_format.encode(meta, &bytes);
            const tmp_path = try tmpPathFor(self, self.index_meta_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                try file.writePositionalAll(self.io, &bytes, 0);
                if (selfOptionsNeedSync(self)) {
                    try file.sync(self.io);
                }
            }
            try renameReplace(self, tmp_path, self.index_meta_path);
            self.index_meta_cache.meta = meta;
            self.index_meta_cache.valid = true;
            if (self.node_text_run_manifest_cache.valid) {
                self.node_text_run_manifest_cache.event_bytes = meta.event_bytes;
            }
        }

        pub fn currentIndexMeta(self: Store, graph: *const graph_mod.Graph) !IndexMeta {
            const graph_stats = try graphIndexStats(self.allocator, graph);
            return .{
                .event_bytes = try eventBytes(self),
                .nodes = graph_stats.active_nodes,
                .edges = graph_stats.visible_edges,
                .node_digest = graph_stats.node_digest,
                .edge_digest = graph_stats.edge_digest,
                .node_by_text_order_digest = graph_stats.node_by_text_order_digest,
                .edge_indexed_edges = graph_stats.physical_edges,
                .edge_index_digest = graph_stats.physical_edge_digest,
                .edge_by_id_order_digest = graph_stats.edge_by_id_order_digest,
                .edge_by_src_order_digest = graph_stats.edge_by_src_order_digest,
                .edge_by_dst_order_digest = graph_stats.edge_by_dst_order_digest,
                .max_edge_id_seen = graph_stats.max_edge_id_seen,
            };
        }

        pub fn currentIndexMetaFromIndexes(self: Store, graph: *const graph_mod.Graph) !IndexMeta {
            const graph_stats = try graphCurrentMetaStats(self.allocator, graph);
            const edge_header = try readEdgeIndexHeader(self, self.edge_by_id_path);
            var meta = IndexMeta{
                .event_bytes = try eventBytes(self),
                .nodes = graph_stats.active_nodes,
                .edges = graph_stats.visible_edges,
                .node_digest = graph_stats.node_digest,
                .edge_digest = graph_stats.edge_digest,
                .edge_indexed_edges = edge_header.edge_count,
                .edge_index_digest = edge_header.edge_digest,
                .max_edge_id_seen = graph_stats.max_edge_id_seen,
            };
            try copyNodeTextOrderDigestFromHeader(self, &meta);
            try copyEdgeOrderDigestsFromHeaders(self, &meta);
            return meta;
        }

        pub fn refreshIndexMetaAfterAppend(self: Store, kind: BinaryRecordKind, node: ?graph_mod.Node, edge: ?graph_mod.Edge) !void {
            const current = readIndexMeta(self) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => null,
                else => |e| return e,
            };
            if (current) |meta| {
                var next = meta;
                next.event_bytes = try eventBytes(self);
                switch (kind) {
                    .node => {
                        const appended = node orelse return error.InvalidRecord;
                        next.nodes = std.math.add(u64, next.nodes, 1) catch return error.InvalidRecord;
                        next.node_digest ^= try nodeRecordDigestFromParts(appended.id.toInt(), appended.kind, appended.text);
                        try copyNodeTextOrderDigestFromHeader(self, &next);
                    },
                    .edge => {
                        const appended = edge orelse return error.InvalidRecord;
                        const digest = edgeRecordDigest(.{
                            .src = appended.src.toInt(),
                            .dst = appended.dst.toInt(),
                            .edge_id = appended.id.toInt(),
                            .rel = @intFromEnum(appended.rel),
                        });
                        next.edges = std.math.add(u64, next.edges, 1) catch return error.InvalidRecord;
                        next.edge_digest ^= digest;
                        next.edge_indexed_edges = std.math.add(u64, next.edge_indexed_edges, 1) catch return error.InvalidRecord;
                        next.edge_index_digest ^= digest;
                        next.max_edge_id_seen = @max(next.max_edge_id_seen, appended.id.toInt());
                        const edge_id_runs = extendEdgeSegmentIdRunSummaryWithEdge(
                            meta.edge_by_id_runs,
                            meta.edge_indexed_edges,
                            appended.id.toInt(),
                        );
                        try copyEdgeOrderDigestsFromHeadersWithIdRuns(self, &next, edge_id_runs);
                        if (!try edgeSegmentMetaSummaryReadable(self, meta)) clearEdgeSegmentSummary(&next);
                    },
                    .edge_delete => return core.Error.Unsupported,
                    .node_batch, .edge_batch, .batch_begin, .batch_commit => return core.Error.Unsupported,
                }
                if (kind == .node) {
                    updateExternalKeyIndexForNodeAppend(self, meta, next, node.?) catch {};
                    updateNodePropertyIndexForNodeAppend(self, meta, next, node.?) catch {};
                }
                try writeIndexMeta(self, next);
                return;
            }

            const stats_out = try stats(self);
            try writeIndexMetaFromStats(self, stats_out);
        }

        pub fn writeIndexMetaFromStats(self: Store, stats_out: StoreStats) !void {
            const edge_header = readEdgeIndexHeader(self, self.edge_by_id_path) catch |err| switch (err) {
                error.FileNotFound => EdgeIndexHeader{ .order = .id, .edge_count = @intCast(stats_out.edges), .edge_digest = stats_out.edge_digest },
                else => |e| return e,
            };
            var meta = IndexMeta{
                .event_bytes = try eventBytes(self),
                .nodes = @intCast(stats_out.nodes),
                .edges = @intCast(stats_out.edges),
                .node_digest = stats_out.node_digest,
                .edge_digest = stats_out.edge_digest,
                .edge_indexed_edges = edge_header.edge_count,
                .edge_index_digest = edge_header.edge_digest,
                .max_edge_id_seen = try maxEdgeIdEverSeenInLog(self),
            };
            try copyNodeTextOrderDigestFromHeader(self, &meta);
            try copyEdgeOrderDigestsFromHeaders(self, &meta);
            try writeIndexMeta(self, meta);
        }

        pub fn copyNodeTextOrderDigestFromHeader(self: Store, meta: *IndexMeta) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{});
            defer file.close(self.io);
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            const delta_header = try readNodeTextDeltaHeader(self);
            var manifest = try readNodeTextRunManifest(self, self.allocator);
            defer manifest.deinit(self.allocator);
            const run_count = manifest.totalNodeCount();
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;
            if (header.node_count + delta_header.node_count + run_count != meta.nodes) return error.InvalidRecord;
            if ((header.node_digest ^ delta_header.node_digest ^ manifest.nodeDigest()) != meta.node_digest) return error.InvalidRecord;
            const expected_size = try nodeTextIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            meta.node_by_text_order_digest = combinedNodeTextOrderDigestWithRuns(header, delta_header, manifest.entries.items);
        }

        pub fn copyEdgeOrderDigestsFromHeaders(self: Store, meta: *IndexMeta) !void {
            try copyEdgeOrderDigestsFromHeadersWithIdRuns(self, meta, null);
        }

        pub fn copyEdgeOrderDigestsFromHeadersWithIdRuns(self: Store, meta: *IndexMeta, edge_id_runs: ?EdgeSegmentIdRunSummary) !void {
            var id_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer id_file.close(self.io);
            const id_header = try readEdgeIndexHeaderFromFile(self, id_file);
            try validateEdgeHeaderForMeta(id_header, meta.*, .id);
            meta.edge_by_id_order_digest = id_header.order_digest;
            if (edge_id_runs) |runs| {
                if (try edgeIdRunSummaryMatchesFile(self, id_file, id_header, runs)) {
                    meta.edge_by_id_runs = runs;
                } else {
                    meta.edge_by_id_runs = try edgeIdRunSummaryForIndexFile(self, id_file, id_header);
                }
            } else {
                meta.edge_by_id_runs = try edgeIdRunSummaryForIndexFile(self, id_file, id_header);
            }

            const src_header = try readEdgeIndexHeader(self, self.edge_by_src_path);
            try validateEdgeHeaderForMeta(src_header, meta.*, .src);
            meta.edge_by_src_order_digest = src_header.order_digest;

            const dst_header = try readEdgeIndexHeader(self, self.edge_by_dst_path);
            try validateEdgeHeaderForMeta(dst_header, meta.*, .dst);
            meta.edge_by_dst_order_digest = dst_header.order_digest;
        }

        pub fn validateEdgeHeaderForMeta(header: EdgeIndexHeader, meta: IndexMeta, order: EdgeIndexOrder) !void {
            if (header.order != order) return error.InvalidRecord;
            if (header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
        }

        pub fn edgeIdRunSummaryForIndexFile(self: Store, file: std.Io.File, header: EdgeIndexHeader) !EdgeSegmentIdRunSummary {
            if (header.order != .id) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try edgeIndexFileSizeForHeader(header)) return error.InvalidRecord;
            if (try denseEdgeIdRunSummaryForHeader(header)) |summary| return summary;
            if (header.edge_count == 0) return .{};
            var builder = EdgeSegmentIdRunBuilder{};
            var previous: u64 = 0;
            var pos: u64 = 0;
            while (pos < header.edge_count) : (pos += 1) {
                const record = try readEdgeIndexRecordAt(self, file, header, pos);
                if (pos != 0 and record.edge_id <= previous) return error.InvalidRecord;
                previous = record.edge_id;
                builder.add(record.edge_id);
            }
            return builder.finish();
        }

        pub fn persistentIndexesCurrent(self: Store, stats_out: StoreStats) !bool {
            return try persistentIndexesCurrentWithTimings(self, stats_out, null);
        }

        pub fn persistentIndexesCurrentWithTimings(self: Store, stats_out: StoreStats, timings: ?*PersistentValidateTimings) !bool {
            const meta = readCurrentIndexMeta(self) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            if (meta.nodes != stats_out.nodes or meta.edges != stats_out.edges) return false;
            if (meta.node_digest != stats_out.node_digest) return false;
            if (meta.edge_digest != stats_out.edge_digest) return false;
            const index_files_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const ok = try persistentIndexFilesMatchMetaWithTimings(self, meta, timings);
            if (timings) |t| t.index_files_ns = storageElapsedNs(self.io, index_files_start);
            return ok;
        }

        pub fn fastPersistentIndexesCurrent(self: Store) !bool {
            const meta = readCurrentIndexMeta(self) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            return try persistentIndexFilesMatchMetaWithTimings(self, meta, null);
        }

        pub fn persistentIndexFilesMatchMeta(self: Store, meta: IndexMeta) !bool {
            return try persistentIndexFilesMatchMetaWithTimings(self, meta, null);
        }

        pub fn persistentIndexFilesMatchMetaWithTimings(self: Store, meta: IndexMeta, timings: ?*PersistentValidateTimings) !bool {
            const node_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const nodes_ok = nodeIndexValidWithTimings(self, meta.nodes, timings) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => false,
                else => |e| return e,
            };
            if (timings) |t| t.node_index_ns = storageElapsedNs(self.io, node_start);
            if (!nodes_ok) return false;
            const node_text_meta_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const node_text_meta_ok = try nodeTextIndexMatchesMeta(self, meta);
            if (timings) |t| t.node_text_meta_ns = storageElapsedNs(self.io, node_text_meta_start);
            if (!node_text_meta_ok) return false;
            const edge_by_id_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const id_digest = edgeIndexValidatedDigest(self, self.edge_by_id_path, .id, meta.edge_indexed_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            if (timings) |t| t.edge_by_id_ns = storageElapsedNs(self.io, edge_by_id_start);
            const edge_by_src_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const src_digest = edgeIndexValidatedDigest(self, self.edge_by_src_path, .src, meta.edge_indexed_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            if (timings) |t| t.edge_by_src_ns = storageElapsedNs(self.io, edge_by_src_start);
            const edge_by_dst_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const dst_digest = edgeIndexValidatedDigest(self, self.edge_by_dst_path, .dst, meta.edge_indexed_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            if (timings) |t| t.edge_by_dst_ns = storageElapsedNs(self.io, edge_by_dst_start);
            const edge_consistency_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const consistent = id_digest.eql(src_digest) and id_digest.eql(dst_digest);
            if (timings) |t| t.edge_consistency_ns = storageElapsedNs(self.io, edge_consistency_start);
            if (!consistent) return false;
            const edge_tombstone_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const tombstones_ok = edgeTombstonesMatchPhysicalIndex(self, meta) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => false,
                else => |e| return e,
            };
            if (timings) |t| t.edge_tombstone_ns = storageElapsedNs(self.io, edge_tombstone_start);
            if (!tombstones_ok) return false;
            const edge_meta_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const edge_meta_ok = validatedEdgeIndexDigestsMatchMeta(self, meta, id_digest, src_digest, dst_digest) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => false,
                else => |e| return e,
            };
            if (edge_meta_ok) {
                if (timings) |t| t.edge_meta_ns = storageElapsedNs(self.io, edge_meta_start);
                return true;
            }
            const edge_segment_ok = edgeSegmentManifestMatchesMetaWithTimings(self, meta, timings) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => false,
                else => |e| return e,
            };
            if (timings) |t| t.edge_meta_ns = storageElapsedNs(self.io, edge_meta_start);
            return edge_segment_ok;
        }

        pub fn nodeTextIndexMatchesMeta(self: Store, meta: IndexMeta) !bool {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{});
            defer file.close(self.io);
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            const delta_header = try readNodeTextDeltaHeader(self);
            var manifest = try readNodeTextRunManifest(self, self.allocator);
            defer manifest.deinit(self.allocator);
            const run_count = manifest.totalNodeCount();
            if (run_count == std.math.maxInt(u64)) return false;
            return header.node_count + delta_header.node_count + run_count == meta.nodes and
                (header.node_digest ^ delta_header.node_digest ^ manifest.nodeDigest()) == meta.node_digest and
                combinedNodeTextOrderDigestWithRuns(header, delta_header, manifest.entries.items) == meta.node_by_text_order_digest;
        }

        pub fn edgeTombstonesMatchPhysicalIndex(self: Store, meta: IndexMeta) !bool {
            var tombstone_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_tombstones_path, .{});
            defer tombstone_file.close(self.io);
            const tombstone_header = try readEdgeTombstoneHeaderFromFile(self, tombstone_file);
            if (tombstone_header.count > meta.edge_indexed_edges) return false;
            if (try regularFileSize(self, tombstone_file) != try edgeTombstoneFileSize(tombstone_header.count)) return false;

            var edge_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer edge_file.close(self.io);
            const edge_header = try readEdgeIndexHeaderFromFile(self, edge_file);
            if (edge_header.order != .id) return false;
            if (edge_header.edge_count != meta.edge_indexed_edges) return false;
            if (edge_header.edge_digest != meta.edge_index_digest) return false;
            if (edge_header.order_digest != meta.edge_by_id_order_digest) return false;
            if (try regularFileSize(self, edge_file) != try edgeIndexFileSizeForHeader(edge_header)) return false;

            var digest: u64 = 0;
            var previous: u64 = 0;
            var edge_scan_pos: u64 = 0;
            var pos: u64 = 0;
            while (pos < tombstone_header.count) : (pos += 1) {
                const tombstone = try readEdgeTombstoneRecordAt(self, tombstone_file, pos);
                if (tombstone.edge_id <= previous) return false;
                previous = tombstone.edge_id;
                var matched = false;
                while (edge_scan_pos < edge_header.edge_count) {
                    const edge = try readEdgeIndexRecordAt(self, edge_file, edge_header, edge_scan_pos);
                    edge_scan_pos += 1;
                    if (edge.edge_id < tombstone.edge_id) continue;
                    if (edge.edge_id != tombstone.edge_id) return false;
                    digest ^= edgeRecordDigest(edge);
                    matched = true;
                    break;
                }
                if (!matched) return false;
            }
            return digest == tombstone_header.digest;
        }

        pub fn readEdgeIndexHeader(self: Store, path: []const u8) !EdgeIndexHeader {
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            var bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            const header = try EdgeIndexHeader.decode(&bytes);
            const expected_size = edgeIndexFileSizeForHeader(header) catch return error.InvalidRecord;
            if (file_size != expected_size) return error.InvalidRecord;
            return header;
        }

        pub fn readEdgeTombstoneIndexHeader(self: Store) !EdgeTombstoneHeader {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_tombstones_path, .{});
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            const header = try readEdgeTombstoneHeaderFromFile(self, file);
            if (file_size != try edgeTombstoneFileSize(header.count)) return error.InvalidRecord;
            return header;
        }

        pub fn edgeTombstoneCount(self: Store) !u64 {
            const header = try readEdgeTombstoneIndexHeader(self);
            return header.count;
        }

        pub fn visiblePlusTombstoneEdgeCount(self: Store, meta: IndexMeta) !u64 {
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            return std.math.add(u64, meta.edges, tombstone_header.count) catch return error.InvalidRecord;
        }

        pub fn visibleEdgeIndexRecordsIterator(self: Store, order: EdgeIndexOrder) !VisibleEdgeIndexRecordIterator {
            const path = switch (order) {
                .id => self.edge_by_id_path,
                .src => self.edge_by_src_path,
                .dst => self.edge_by_dst_path,
            };
            const meta = try readCurrentIndexMeta(self);
            if (self.options.validate_indexes_on_read) {
                if (!try edgeIndexesValidatedAndMatchMeta(self, meta)) return error.InvalidRecord;
            }
            var reader = try openEdgeIndexRecordReader(self, path, order, meta);
            errdefer reader.deinit();
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            var tombstones: ?EdgeTombstoneIndexView = null;
            errdefer if (tombstones) |*view| view.deinit();
            if (tombstone_header.count != 0) tombstones = try EdgeTombstoneIndexView.open(self);
            return .{
                .reader = reader,
                .tombstones = tombstones,
            };
        }

        pub fn scanVisibleEdgeIndexRecords(
            self: Store,
            allocator: std.mem.Allocator,
            context: *anyopaque,
            visit: EdgeIndexRecordVisitor,
        ) !u64 {
            const meta = try readCurrentIndexMeta(self);
            var count: u64 = 0;
            var digest: u64 = 0;
            var opened = try openPublishedEdgeSegmentsForQuery(self, allocator);
            defer if (opened) |*segments| segments.deinit();
            if (opened) |*segments| {
                const tombstone_header = try readEdgeTombstoneIndexHeader(self);
                var tombstones: ?EdgeTombstoneIndexView = null;
                defer if (tombstones) |*view| view.deinit();
                if (tombstone_header.count != 0 and segments.coverage != .visible_full) {
                    tombstones = try EdgeTombstoneIndexView.open(self);
                }

                if (segments.coverage == .delta) {
                    var base = try openEdgeIndexRecordReader(self, self.edge_by_src_path, .src, meta);
                    defer base.deinit();
                    var stream = BaseAndSegmentMergeStream.initWithVirtualFiltered(
                        allocator,
                        &base,
                        &segments.segments.segments,
                        segments.segments.virtual_edges.items,
                        .forward,
                        if (tombstones) |*view| view else null,
                    );
                    defer stream.deinit();
                    try stream.reset();
                    while (try stream.next()) |edge| {
                        const record = EdgeIndexRecord{
                            .src = edge.src.toInt(),
                            .dst = edge.dst.toInt(),
                            .edge_id = edge.edge_id.toInt(),
                            .rel = @intFromEnum(edge.rel),
                        };
                        try visit(context, record);
                        count = std.math.add(u64, count, 1) catch return error.RecordTooLarge;
                        digest ^= edgeRecordDigest(record);
                    }
                } else {
                    var stream = if (tombstones) |*view|
                        EdgeSegmentMergeStream.initWithVirtualFiltered(
                            allocator,
                            &segments.segments.segments,
                            segments.segments.virtual_edges.items,
                            .forward,
                            view,
                        )
                    else
                        EdgeSegmentMergeStream.initWithVirtual(
                            allocator,
                            &segments.segments.segments,
                            segments.segments.virtual_edges.items,
                            .forward,
                        );
                    defer stream.deinit();
                    try stream.reset();
                    while (try stream.next()) |edge| {
                        const record = EdgeIndexRecord{
                            .src = edge.src.toInt(),
                            .dst = edge.dst.toInt(),
                            .edge_id = edge.edge_id.toInt(),
                            .rel = @intFromEnum(edge.rel),
                        };
                        try visit(context, record);
                        count = std.math.add(u64, count, 1) catch return error.RecordTooLarge;
                        digest ^= edgeRecordDigest(record);
                    }
                }
            } else {
                var records = try visibleEdgeIndexRecordsIterator(self, .src);
                defer records.deinit();
                while (try records.next()) |record| {
                    try visit(context, record);
                    count = std.math.add(u64, count, 1) catch return error.RecordTooLarge;
                    digest ^= edgeRecordDigest(record);
                }
            }
            if (count != meta.edges or digest != meta.edge_digest) return error.InvalidRecord;
            return count;
        }

        pub fn edgeIndexRecordsByNodeIterator(self: Store, order: EdgeIndexOrder, node_id: core.NodeId) !EdgeIndexRecordIterator {
            return edgeIndexRecordsByNodeAndRelationIterator(self, order, node_id, null);
        }

        pub fn edgeIndexRecordsByNodeAndRelationIterator(self: Store, order: EdgeIndexOrder, node_id: core.NodeId, rel_filter: ?core.RelKind) !EdgeIndexRecordIterator {
            if (isReservedNodeId(node_id)) return core.Error.InvalidId;
            const path = switch (order) {
                .id => return core.Error.Unsupported,
                .src => self.edge_by_src_path,
                .dst => self.edge_by_dst_path,
            };
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            errdefer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != order) return error.InvalidRecord;
            const meta = try readCurrentIndexMeta(self);
            if (header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            if (header.order_digest != edgeOrderDigestForMeta(meta, order)) return error.InvalidRecord;
            const expected_size = try edgeIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (self.options.validate_indexes_on_read) {
                if (!try edgeIndexesValidatedAndMatchMeta(self, meta)) return error.InvalidRecord;
            }
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            var tombstones: ?EdgeTombstoneIndexView = null;
            errdefer if (tombstones) |*view| view.deinit();
            if (tombstone_header.count != 0) tombstones = try EdgeTombstoneIndexView.open(self);

            var map = openReadOnlyMemoryMap(self.io, file, expected_size) catch null;
            errdefer if (map) |*mapped| mapped.destroy(self.io);

            const key = node_id.toInt();
            const rel_value: ?u16 = if (rel_filter) |rel| @intFromEnum(rel) else null;
            var lo: u64 = 0;
            var end: u64 = header.edge_count;
            if (header.hasKeyRuns()) {
                const bounds = if (map) |*mapped|
                    try edgeIndexKeyRunBoundsForKeyFromMap(header, mapped, key)
                else
                    try edgeIndexKeyRunBoundsForKeyAt(self, file, header, key);
                if (bounds) |range| {
                    lo = range.start;
                    end = range.end;
                } else {
                    lo = 0;
                    end = 0;
                }
            }
            if (!header.hasKeyRuns() or rel_value != null) {
                var hi: u64 = end;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const record = if (map) |*mapped|
                        try readEdgeIndexRecordFromMap(header, mapped, mid)
                    else
                        try readEdgeIndexRecordAt(self, file, header, mid);
                    const before_target = if (rel_value) |rel|
                        edgeIndexRecordNodeRelLessThan(record, order, key, rel)
                    else
                        edgeIndexRecordKey(record, order) < key;
                    if (before_target) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
            }

            return .{
                .store = self,
                .file = file,
                .map = map,
                .header = header,
                .order = order,
                .key = key,
                .rel_filter = rel_value,
                .tombstones = tombstones,
                .pos = lo,
                .end = end,
            };
        }

        pub fn readEdgeIndexRecordsByNode(self: Store, allocator: std.mem.Allocator, order: EdgeIndexOrder, node_id: core.NodeId) !std.ArrayList(EdgeIndexRecord) {
            return readEdgeIndexRecordsByNodeLimited(self, allocator, order, node_id, (core.QueryBudget{}).max_visited_edges);
        }

        pub fn readEdgeIndexRecordsByNodeOrdered(self: Store, allocator: std.mem.Allocator, node_id: core.NodeId) !std.ArrayList(EdgeIndexRecord) {
            var order_map = try readEdgeOrderMap(self, allocator);
            defer order_map.deinit();
            return readEdgeIndexRecordsByNodeOrderedWithOrderMap(self, allocator, node_id, &order_map);
        }

        pub fn readEdgeIndexRecordsByNodeOrderedWithOrderMap(self: Store, allocator: std.mem.Allocator, node_id: core.NodeId, order_map: *std.AutoHashMap(u64, u64)) !std.ArrayList(EdgeIndexRecord) {
            var records = try readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(self, allocator, node_id);
            errdefer records.deinit(allocator);
            if (order_map.count() != 0) {
                std.mem.sort(EdgeIndexRecord, records.items, order_map, edgeIndexRecordOptionalOrderLessThan);
            } else {
                std.mem.sort(EdgeIndexRecord, records.items, {}, edgeIndexByIdLessThan);
            }
            return records;
        }

        pub fn readVisibleEdgeIndexRecordsByNode(
            self: Store,
            allocator: std.mem.Allocator,
            order: EdgeIndexOrder,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
        ) !std.ArrayList(EdgeIndexRecord) {
            return readVisibleEdgeIndexRecordsByNodeLimited(
                self,
                allocator,
                order,
                node_id,
                rel_filter,
                (core.QueryBudget{}).max_visited_edges,
            );
        }

        pub fn readVisibleEdgeIndexRecordsByNodeLimited(
            self: Store,
            allocator: std.mem.Allocator,
            order: EdgeIndexOrder,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            max_records: usize,
        ) !std.ArrayList(EdgeIndexRecord) {
            const CollectContext = struct {
                allocator: std.mem.Allocator,
                records: *std.ArrayList(EdgeIndexRecord),

                fn visit(context: *@This(), record: EdgeIndexRecord) !bool {
                    try context.records.append(context.allocator, record);
                    return false;
                }
            };
            var records = std.ArrayList(EdgeIndexRecord).empty;
            errdefer records.deinit(allocator);
            var context = CollectContext{ .allocator = allocator, .records = &records };
            _ = try forEachVisibleEdgeIndexRecordByNode(
                self,
                allocator,
                order,
                node_id,
                rel_filter,
                max_records,
                &context,
                CollectContext.visit,
            );
            return records;
        }

        pub fn forEachVisibleEdgeIndexRecordByNode(
            self: Store,
            allocator: std.mem.Allocator,
            order: EdgeIndexOrder,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            max_records: usize,
            context: anytype,
            comptime callback: fn (@TypeOf(context), EdgeIndexRecord) anyerror!bool,
        ) !bool {
            return forEachVisibleEdgeIndexRecordByNodeMaybeRetained(
                self,
                allocator,
                null,
                order,
                node_id,
                rel_filter,
                max_records,
                context,
                callback,
            );
        }

        pub fn forEachVisibleEdgeIndexRecordByNodeRetained(
            self: Store,
            allocator: std.mem.Allocator,
            registry: *EdgeSegmentRetentionRegistry,
            order: EdgeIndexOrder,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            max_records: usize,
            context: anytype,
            comptime callback: fn (@TypeOf(context), EdgeIndexRecord) anyerror!bool,
        ) !bool {
            return forEachVisibleEdgeIndexRecordByNodeMaybeRetained(
                self,
                allocator,
                registry,
                order,
                node_id,
                rel_filter,
                max_records,
                context,
                callback,
            );
        }

        pub fn forEachVisibleEdgeIndexRecordByNodeMaybeRetained(
            self: Store,
            allocator: std.mem.Allocator,
            registry: ?*EdgeSegmentRetentionRegistry,
            order: EdgeIndexOrder,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            max_records: usize,
            context: anytype,
            comptime callback: fn (@TypeOf(context), EdgeIndexRecord) anyerror!bool,
        ) !bool {
            const direction: segment_mod.Direction = switch (order) {
                .src => .forward,
                .dst => .reverse,
                .id => return core.Error.Unsupported,
            };
            var segments_for_query = if (registry) |retention_registry|
                try openPublishedEdgeSegmentsForQueryForNodeRetained(self, allocator, retention_registry, direction, node_id)
            else
                try openPublishedEdgeSegmentsForQueryForNode(self, allocator, direction, node_id);
            defer if (segments_for_query) |*opened| opened.deinit();

            var emitted: usize = 0;
            const scan_limit = @max(max_records, (core.QueryBudget{}).max_visited_edges);
            const base_scan_limit = std.math.cast(u64, scan_limit) orelse std.math.maxInt(u64);
            if (segments_for_query) |*opened| {
                if (opened.coverage == .delta) {
                    var base = try edgeIndexRecordsByNodeAndRelationIterator(self, order, node_id, rel_filter);
                    defer base.deinit();
                    base.max_physical_records = base_scan_limit;
                    while (try base.next()) |record| {
                        if (emitted >= max_records) return core.Error.BudgetExceeded;
                        emitted += 1;
                        if (try callback(context, record)) return true;
                    }
                }
                const SegmentContext = struct {
                    inner: @TypeOf(context),
                    emitted: *usize,
                    max_records: usize,

                    fn visit(segment_context: *@This(), edge: segment_mod.EdgeRecord) !bool {
                        if (segment_context.emitted.* >= segment_context.max_records) return core.Error.BudgetExceeded;
                        segment_context.emitted.* += 1;
                        return callback(segment_context.inner, .{
                            .src = edge.src.toInt(),
                            .dst = edge.dst.toInt(),
                            .edge_id = edge.edge_id.toInt(),
                            .rel = @intFromEnum(edge.rel),
                        });
                    }
                };
                var segment_context = SegmentContext{
                    .inner = context,
                    .emitted = &emitted,
                    .max_records = max_records,
                };
                // Segment tombstone filtering happens inside the storage wrapper,
                // so its physical-edge budget cannot represent this API's visible
                // record budget. Keep the two limits independent: callbacks count
                // visible records above, while the scan cap still bounds work on a
                // tombstone-heavy adjacency.
                return if (opened.coverage == .visible_full)
                    try opened.segments.forEachNeighbor(direction, node_id, rel_filter, scan_limit, &segment_context, SegmentContext.visit)
                else
                    try forEachOpenedPublishedEdgeSegmentNeighbor(self, &opened.segments, direction, node_id, rel_filter, scan_limit, &segment_context, SegmentContext.visit);
            }

            var base = try edgeIndexRecordsByNodeAndRelationIterator(self, order, node_id, rel_filter);
            defer base.deinit();
            base.max_physical_records = base_scan_limit;
            while (try base.next()) |record| {
                if (emitted >= max_records) return core.Error.BudgetExceeded;
                emitted += 1;
                if (try callback(context, record)) return true;
            }
            return false;
        }

        pub fn readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(self: Store, allocator: std.mem.Allocator, node_id: core.NodeId) !std.ArrayList(EdgeIndexRecord) {
            return readVisibleEdgeIndexRecordsByNode(self, allocator, .src, node_id, null);
        }

        pub fn readEdgeIndexRecordsByNodeLimited(self: Store, allocator: std.mem.Allocator, order: EdgeIndexOrder, node_id: core.NodeId, max_records: usize) !std.ArrayList(EdgeIndexRecord) {
            var iter = try edgeIndexRecordsByNodeIterator(self, order, node_id);
            defer iter.deinit();
            var out = std.ArrayList(EdgeIndexRecord).empty;
            errdefer out.deinit(allocator);
            while (try iter.next()) |record| {
                if (out.items.len >= max_records) return core.Error.BudgetExceeded;
                try out.append(allocator, record);
            }
            return out;
        }

        pub fn readEdgeOrderRecordsByNode(self: Store, allocator: std.mem.Allocator, node_id: core.NodeId) !std.ArrayList(EdgeOrderRecord) {
            if (isReservedNodeId(node_id)) return core.Error.InvalidId;
            var all = readAllEdgeOrderRecords(self, allocator) catch |err| switch (err) {
                error.FileNotFound => return std.ArrayList(EdgeOrderRecord).empty,
                else => |e| return e,
            };
            errdefer all.deinit(allocator);
            var out = std.ArrayList(EdgeOrderRecord).empty;
            errdefer out.deinit(allocator);
            for (all.items) |record| {
                if (record.src == node_id.toInt()) try out.append(allocator, record);
            }
            all.deinit(allocator);
            return out;
        }

        pub fn readEdgeOrderMap(self: Store, allocator: std.mem.Allocator) !std.AutoHashMap(u64, u64) {
            var order_map = std.AutoHashMap(u64, u64).init(allocator);
            errdefer order_map.deinit();
            var records = readAllEdgeOrderRecords(self, allocator) catch |err| switch (err) {
                error.FileNotFound => return order_map,
                else => |e| return e,
            };
            defer records.deinit(allocator);
            try order_map.ensureTotalCapacity(@intCast(records.items.len));
            for (records.items) |record| order_map.putAssumeCapacity(record.edge_id, record.order_key);
            return order_map;
        }

        pub fn scanEdgeOrderRecords(self: Store, context: *anyopaque, visit: EdgeOrderRecordVisitor) !u64 {
            var file = std.Io.Dir.cwd().openFile(self.io, self.edge_order_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return 0,
                else => |e| return e,
            };
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (file_size < edge_order_format.header_encoded_len) return error.InvalidRecord;
            var header_bytes: [edge_order_format.header_encoded_len]u8 = undefined;
            if (try file.readPositionalAll(self.io, &header_bytes, 0) != header_bytes.len) return error.InvalidRecord;
            const header = edge_order_format.decodeHeader(&header_bytes);
            const payload_bytes = std.math.mul(u64, header.count, edge_order_format.record_encoded_len) catch return error.InvalidRecord;
            if (file_size != std.math.add(u64, edge_order_format.header_encoded_len, payload_bytes) catch return error.InvalidRecord) return error.InvalidRecord;

            var digest: u64 = 0;
            var pos: u64 = edge_order_format.header_encoded_len;
            var previous: ?EdgeOrderRecord = null;
            var index: u64 = 0;
            while (index < header.count) : (index += 1) {
                var record_bytes: [edge_order_format.record_encoded_len]u8 = undefined;
                if (try file.readPositionalAll(self.io, &record_bytes, pos) != record_bytes.len) return error.InvalidRecord;
                pos = std.math.add(u64, pos, edge_order_format.record_encoded_len) catch return error.InvalidRecord;
                const record = try edge_order_format.decodeRecord(&record_bytes);
                if (previous) |prior| {
                    if (!edgeOrderRecordLessThan({}, prior, record)) return error.InvalidRecord;
                    if (prior.edge_id == record.edge_id) return error.InvalidRecord;
                }
                digest ^= edgeOrderRecordDigest(record);
                try visit(context, record);
                previous = record;
            }
            if (digest != header.digest) return error.InvalidRecord;
            return header.count;
        }

        pub fn replaceEdgeOrderIndexRemappedFrom(
            self: Store,
            source: Store,
            rel_remap: []const u16,
            invalid_rel: u16,
        ) !u64 {
            return replaceEdgeOrderIndexFrom(self, source, rel_remap, invalid_rel, false);
        }

        pub fn replaceEdgeOrderIndexFromPresentEdges(self: Store, source: Store) !u64 {
            return replaceEdgeOrderIndexFrom(self, source, null, std.math.maxInt(u16), true);
        }

        pub fn replaceEdgeOrderIndexFrom(
            self: Store,
            source: Store,
            rel_remap: ?[]const u16,
            invalid_rel: u16,
            present_only: bool,
        ) !u64 {
            // Keep creation and publication anchored to one already-open Store
            // directory. In particular, do not make a second cwd-relative lookup
            // of the complete staging path after a large repair transaction on
            // Windows. A genuinely missing Store root now fails at openDir instead
            // of being hidden by retries or by silently recreating the directory.
            var store_dir = try std.Io.Dir.cwd().openDir(self.io, self.dir_path, .{});
            defer store_dir.close(self.io);
            const final_basename = std.fs.path.basename(self.edge_order_path);
            const tmp_basename = try std.fmt.allocPrint(self.allocator, "{s}.copy.tmp", .{final_basename});
            defer self.allocator.free(tmp_basename);
            errdefer store_dir.deleteFile(self.io, tmp_basename) catch {};
            var count: u64 = 0;
            {
                var file = try store_dir.createFile(self.io, tmp_basename, .{ .read = true, .truncate = true });
                defer file.close(self.io);
                var writer = try StorageBufferedWriter.initAtOffset(
                    self.allocator,
                    self.io,
                    file,
                    storage_write_buffer_bytes,
                    edge_order_format.header_encoded_len,
                );
                defer writer.deinit();
                const CopyContext = struct {
                    writer: *StorageBufferedWriter,
                    target: Store,
                    rel_remap: ?[]const u16,
                    invalid_rel: u16,
                    present_only: bool,
                    previous: ?EdgeOrderRecord = null,
                    count: u64 = 0,
                    digest: u64 = 0,

                    fn visit(raw_context: *anyopaque, source_record: EdgeOrderRecord) anyerror!void {
                        const context: *@This() = @ptrCast(@alignCast(raw_context));
                        const target_rel = if (context.rel_remap) |remap| blk: {
                            if (source_record.rel >= remap.len) return error.InvalidRecord;
                            const remapped = remap[source_record.rel];
                            if (remapped == context.invalid_rel or relKindFromInt(remapped) == null) return error.InvalidRecord;
                            break :blk remapped;
                        } else source_record.rel;
                        var target_record = source_record;
                        target_record.rel = target_rel;
                        try validateEdgeOrderRecord(target_record);
                        if (context.present_only) {
                            const target_edge = readVisibleEdgeIndexRecordById(context.target, .fromInt(target_record.edge_id)) catch |err| switch (err) {
                                core.Error.NotFound, core.Error.InvalidId => return,
                                else => |e| return e,
                            };
                            if (target_edge.src != target_record.src or
                                target_edge.rel != target_record.rel) return error.InvalidRecord;
                        }
                        if (context.previous) |prior| {
                            if (!edgeOrderRecordLessThan({}, prior, target_record)) return error.InvalidRecord;
                            if (prior.edge_id == target_record.edge_id) return error.InvalidRecord;
                        }
                        var bytes: [edge_order_format.record_encoded_len]u8 = undefined;
                        edge_order_format.encodeRecord(target_record, &bytes);
                        try context.writer.append(&bytes);
                        context.count = std.math.add(u64, context.count, 1) catch return error.RecordTooLarge;
                        context.digest ^= edgeOrderRecordDigest(target_record);
                        context.previous = target_record;
                    }
                };
                var context = CopyContext{
                    .writer = &writer,
                    .target = self,
                    .rel_remap = rel_remap,
                    .invalid_rel = invalid_rel,
                    .present_only = present_only,
                };
                const source_count = try source.scanEdgeOrderRecords(&context, CopyContext.visit);
                if (context.count > source_count or (!present_only and source_count != context.count)) return error.InvalidRecord;
                try writer.flush();
                var header_bytes: [edge_order_format.header_encoded_len]u8 = undefined;
                edge_order_format.encodeHeader(.{ .count = context.count, .digest = context.digest }, &header_bytes);
                try file.writePositionalAll(self.io, &header_bytes, 0);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
                count = context.count;
            }
            try std.Io.Dir.rename(store_dir, tmp_basename, store_dir, final_basename, self.io);
            try syncParentDirForPath(self, self.edge_order_path);
            return count;
        }

        pub fn upsertEdgeOrderRecordsBatch(self: Store, allocator: std.mem.Allocator, updates: []const EdgeOrderRecord) !void {
            if (updates.len == 0) return;
            for (updates) |u| try validateEdgeOrderRecord(u);
            var records = readAllEdgeOrderRecords(self, allocator) catch |err| switch (err) {
                error.FileNotFound => std.ArrayList(EdgeOrderRecord).empty,
                else => |e| return e,
            };
            defer records.deinit(allocator);
            var updated_ids = std.AutoHashMap(u64, u64).init(allocator); // edge_id → new order_key
            defer updated_ids.deinit();
            for (updates) |u| try updated_ids.put(u.edge_id, u.order_key);
            var missing = std.AutoHashMap(u64, void).init(allocator);
            defer missing.deinit();
            for (updates) |u| try missing.put(u.edge_id, {});
            for (records.items) |*r| {
                if (updated_ids.get(r.edge_id)) |nk| {
                    r.order_key = nk;
                    _ = missing.remove(r.edge_id);
                }
            }
            // 旧边此前无 order 记录(如非 ordered append 的历史边)→ 补插。
            for (updates) |u| {
                if (missing.contains(u.edge_id)) try records.append(allocator, u);
            }
            std.mem.sort(EdgeOrderRecord, records.items, {}, edgeOrderRecordLessThan);
            try writeEdgeOrderIndex(self, records.items);
        }

        pub fn insertEdgeOrderRecord(self: Store, record: EdgeOrderRecord) !void {
            try validateEdgeOrderRecord(record);
            var records = readAllEdgeOrderRecords(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound => std.ArrayList(EdgeOrderRecord).empty,
                else => |e| return e,
            };
            defer records.deinit(self.allocator);
            try records.append(self.allocator, record);
            std.mem.sort(EdgeOrderRecord, records.items, {}, edgeOrderRecordLessThan);
            try writeEdgeOrderIndex(self, records.items);
        }

        pub fn readAllEdgeOrderRecordsForTest(self: Store, allocator: std.mem.Allocator) !std.ArrayList(EdgeOrderRecord) {
            return readAllEdgeOrderRecords(self, allocator);
        }

        pub fn readAllEdgeOrderRecords(self: Store, allocator: std.mem.Allocator) !std.ArrayList(EdgeOrderRecord) {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_order_path, .{});
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (file_size < edge_order_format.header_encoded_len) return error.InvalidRecord;
            var header_bytes: [edge_order_format.header_encoded_len]u8 = undefined;
            const header_read = try file.readPositionalAll(self.io, &header_bytes, 0);
            if (header_read != header_bytes.len) return error.InvalidRecord;
            const header = edge_order_format.decodeHeader(&header_bytes);
            const payload_bytes = std.math.mul(u64, header.count, edge_order_format.record_encoded_len) catch return error.InvalidRecord;
            const expected_size = edge_order_format.header_encoded_len + payload_bytes;
            if (file_size != expected_size) return error.InvalidRecord;
            var records = std.ArrayList(EdgeOrderRecord).empty;
            errdefer records.deinit(allocator);
            try records.ensureTotalCapacityPrecise(allocator, @intCast(header.count));
            var digest: u64 = 0;
            var pos: u64 = edge_order_format.header_encoded_len;
            var previous: ?EdgeOrderRecord = null;
            var index: u64 = 0;
            while (index < header.count) : (index += 1) {
                var record_bytes: [edge_order_format.record_encoded_len]u8 = undefined;
                const n = try file.readPositionalAll(self.io, &record_bytes, pos);
                if (n != record_bytes.len) return error.InvalidRecord;
                pos += edge_order_format.record_encoded_len;
                const record = try edge_order_format.decodeRecord(&record_bytes);
                if (previous) |prev| {
                    if (!edgeOrderRecordLessThan({}, prev, record)) return error.InvalidRecord;
                    if (prev.edge_id == record.edge_id) return error.InvalidRecord;
                }
                digest ^= edgeOrderRecordDigest(record);
                records.appendAssumeCapacity(record);
                previous = record;
            }
            if (digest != header.digest) return error.InvalidRecord;
            return records;
        }

        pub fn readNodeById(self: Store, allocator: std.mem.Allocator, node_id: core.NodeId) !?StoredNode {
            const id = node_id.toInt();
            if (isReservedNodeId(node_id)) return core.Error.InvalidId;
            const meta = try readCurrentIndexMeta(self);
            if (self.options.validate_indexes_on_read and !try nodeIndexValid(self, meta.nodes)) return error.InvalidRecord;
            var view = try NodeByIdIndexView.open(self, meta);
            defer view.deinit();
            const record = (try view.readOptionalRecord(id)) orelse return null;
            return try readStoredNodeFromRecord(self, allocator, record);
        }

        pub fn lookupNodeByExternalKey(self: Store, allocator: std.mem.Allocator, external_key: []const u8, kind_filter: ?core.NodeKind) !?core.NodeId {
            var hits = try lookupNodeIdsByStringProperty(self, allocator, "external_key", external_key, kind_filter, 1);
            defer hits.deinit(allocator);
            if (hits.items.len == 0) return null;
            return hits.items[0];
        }

        pub fn buildNodeExternalKeyLookupCache(self: Store, allocator: std.mem.Allocator) !NodeExternalKeyLookupCache {
            var cache = NodeExternalKeyLookupCache{
                .allocator = allocator,
                .entries = std.StringHashMap(std.ArrayList(NodeExternalKeyLookupEntry)).init(allocator),
            };
            errdefer cache.deinit();
            var iterator = try nodeRecordsIterator(self, null);
            defer iterator.deinit();
            while (try iterator.next(allocator)) |node| {
                defer {
                    var mutable = node;
                    mutable.deinit(allocator);
                }
                const external_key = try getNodeStringProperty(self, allocator, node.id, "external_key");
                defer if (external_key) |key| allocator.free(key);
                const key = external_key orelse continue;
                if (cache.entries.getPtr(key)) |entries| {
                    try entries.append(allocator, .{ .id = node.id, .kind = node.kind });
                } else {
                    const owned_key = try allocator.dupe(u8, key);
                    errdefer allocator.free(owned_key);
                    var entries: std.ArrayList(NodeExternalKeyLookupEntry) = .empty;
                    errdefer entries.deinit(allocator);
                    try entries.append(allocator, .{ .id = node.id, .kind = node.kind });
                    try cache.entries.putNoClobber(owned_key, entries);
                }
            }
            return cache;
        }

        pub fn lookupNodeByExternalKeyCached(self: Store, allocator: std.mem.Allocator, external_key: []const u8, kind_filter: ?core.NodeKind, cache: *NodeExternalKeyLookupCache) !?core.NodeId {
            _ = self;
            _ = allocator;
            if (external_key.len == 0) return null;
            const entries = cache.entries.get(external_key) orelse return null;
            for (entries.items) |entry| {
                if (kind_filter) |filter| {
                    if (entry.kind != filter) continue;
                }
                return entry.id;
            }
            return null;
        }

        pub fn lookupNodeByExternalKeyFromCurrentIndex(self: Store, allocator: std.mem.Allocator, external_key: []const u8, kind_filter: ?core.NodeKind) !?core.NodeId {
            if (external_key.len == 0) return null;
            const meta = try readCurrentIndexMeta(self);
            var file = try std.Io.Dir.cwd().openFile(self.io, self.external_key_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readExternalKeyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest) return error.InvalidRecord;
            const expected_size = try externalKeyIndexFileSize(header.record_count);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            const key_hash = externalKeyHash(external_key);
            const first = try externalKeyIndexLowerBound(self, file, header, key_hash);
            var index = first;
            while (index < header.record_count) : (index += 1) {
                const record = try readExternalKeyIndexRecordAt(self, file, index);
                if (record.hash != key_hash) break;
                const node_id: core.NodeId = .fromInt(record.node_id);
                var node = (try readNodeById(self, allocator, node_id)) orelse continue;
                defer node.deinit(allocator);
                if (kind_filter) |filter| {
                    if (node.kind != filter) continue;
                }
                const stored_key = try getNodeStringProperty(self, allocator, node_id, "external_key");
                defer if (stored_key) |key| allocator.free(key);
                if (stored_key) |key| if (std.mem.eql(u8, key, external_key)) return node_id;
            }
            return null;
        }

        pub fn rebuildExternalKeyIndex(self: Store) !void {
            const meta = try readCurrentIndexMeta(self);
            var records = std.ArrayList(ExternalKeyIndexRecord).empty;
            defer records.deinit(self.allocator);
            var payload_entries = try readPropertyPayloadEntriesOrEmpty(self, self.allocator);
            defer {
                deinitPropertyPayloadIndexEntries(payload_entries.items, self.allocator);
                payload_entries.deinit(self.allocator);
            }
            var iterator = try nodeRecordsIterator(self, null);
            defer iterator.deinit();
            while (try iterator.next(self.allocator)) |node| {
                defer {
                    var mutable = node;
                    mutable.deinit(self.allocator);
                }
                if (propertyPayloadStringValue(payload_entries.items, .{ .node = node.id }, "external_key")) |key| {
                    try records.append(self.allocator, .{
                        .hash = externalKeyHash(key),
                        .node_id = node.id.toInt(),
                    });
                }
            }
            try writeExternalKeyIndex(self, records.items, meta);
        }

        pub fn readExternalKeyIndexHeaderFromFile(self: Store, file: std.Io.File) !ExternalKeyIndexHeader {
            var bytes: [ExternalKeyIndexHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return ExternalKeyIndexHeader.decode(&bytes);
        }

        pub fn readExternalKeyIndexRecordAt(self: Store, file: std.Io.File, index: u64) !ExternalKeyIndexRecord {
            var bytes: [ExternalKeyIndexRecord.encoded_len]u8 = undefined;
            const offset = try externalKeyIndexRecordOffset(index);
            const n = try file.readPositionalAll(self.io, &bytes, offset);
            if (n != bytes.len) return error.InvalidRecord;
            return ExternalKeyIndexRecord.decode(&bytes);
        }

        pub fn externalKeyIndexLowerBound(self: Store, file: std.Io.File, header: ExternalKeyIndexHeader, key_hash: u64) !u64 {
            var lo: u64 = 0;
            var hi: u64 = header.record_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const record = try readExternalKeyIndexRecordAt(self, file, mid);
                if (record.hash < key_hash) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn writeExternalKeyIndex(self: Store, records: []ExternalKeyIndexRecord, meta: IndexMeta) !void {
            std.mem.sort(ExternalKeyIndexRecord, records, {}, externalKeyIndexRecordLessThan);
            const tmp_path = try tmpPathFor(self, self.external_key_index_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(try externalKeyIndexFileSize(@intCast(records.len))));
                defer writer.deinit();
                const header = ExternalKeyIndexHeader{
                    .record_count = @intCast(records.len),
                    .node_count = meta.nodes,
                    .node_digest = meta.node_digest,
                };
                var header_bytes: [ExternalKeyIndexHeader.encoded_len]u8 = undefined;
                header.encode(&header_bytes);
                try writer.append(&header_bytes);
                var previous: ?ExternalKeyIndexRecord = null;
                for (records) |record| {
                    if (previous) |prev| {
                        if (!externalKeyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                    }
                    var record_bytes: [ExternalKeyIndexRecord.encoded_len]u8 = undefined;
                    try record.encode(&record_bytes);
                    try writer.append(&record_bytes);
                    previous = record;
                }
                try writer.flush();
                if (try regularFileSize(self, file) != try externalKeyIndexFileSize(@intCast(records.len))) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.external_key_index_path);
        }

        pub fn readExternalKeyIndexRecordsForMeta(self: Store, allocator: std.mem.Allocator, meta: IndexMeta) !std.ArrayList(ExternalKeyIndexRecord) {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.external_key_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readExternalKeyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try externalKeyIndexFileSize(header.record_count)) return error.InvalidRecord;
            var records = std.ArrayList(ExternalKeyIndexRecord).empty;
            errdefer records.deinit(allocator);
            try records.ensureTotalCapacity(allocator, std.math.cast(usize, header.record_count) orelse return error.RecordTooLarge);
            var previous: ?ExternalKeyIndexRecord = null;
            var index: u64 = 0;
            while (index < header.record_count) : (index += 1) {
                const record = try readExternalKeyIndexRecordAt(self, file, index);
                if (previous) |prev| {
                    if (!externalKeyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                records.appendAssumeCapacity(record);
                previous = record;
            }
            return records;
        }

        pub fn updateExternalKeyIndexForNodeAppend(self: Store, old_meta: IndexMeta, next_meta: IndexMeta, node: graph_mod.Node) !void {
            _ = self;
            _ = old_meta;
            _ = next_meta;
            _ = node;
        }

        pub fn updateExternalKeyIndexForNodeBatch(self: Store, old_meta: IndexMeta, next_meta: IndexMeta, nodes: []const graph_mod.Node) !void {
            _ = self;
            _ = old_meta;
            _ = next_meta;
            _ = nodes;
        }

        pub fn lookupNodeIdsByStringProperty(self: Store, allocator: std.mem.Allocator, key: []const u8, value: []const u8, kind_filter: ?core.NodeKind, max_nodes: usize) !std.ArrayList(core.NodeId) {
            var derived = derived: {
                break :derived lookupNodeIdsByStringPropertyFromCurrentIndex(self, allocator, key, value, kind_filter, max_nodes) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidRecord => {
                        try rebuildNodePropertyIndex(self);
                        break :derived try lookupNodeIdsByStringPropertyFromCurrentIndex(self, allocator, key, value, kind_filter, max_nodes);
                    },
                    else => |e| return e,
                };
            };
            defer derived.deinit(allocator);
            var overlay = try readNodePropertyOverlayEntriesForKeyOrEmpty(
                self,
                allocator,
                self.node_props_overlay_index_path,
                self.node_props_overlay_values_path,
                key,
            );
            defer {
                deinitNodePropertyIndexEntries(overlay.items, allocator);
                overlay.deinit(allocator);
            }
            var payload_overlay = try readPropertyPayloadEntriesForKeyOrEmpty(self, allocator, key);
            defer {
                deinitPropertyPayloadIndexEntries(payload_overlay.items, allocator);
                payload_overlay.deinit(allocator);
            }
            var out = std.ArrayList(core.NodeId).empty;
            errdefer out.deinit(allocator);
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();
            for (derived.items) |node_id| {
                if (out.items.len >= max_nodes) break;
                if (propertyPayloadStringValue(payload_overlay.items, .{ .node = node_id }, key)) |payload_value| {
                    if (!std.mem.eql(u8, payload_value, value)) continue;
                } else if (nodePropertyOverlayStringValue(overlay.items, node_id, key)) |overlay_value| {
                    if (!std.mem.eql(u8, overlay_value, value)) continue;
                }
                try appendUniqueNodeId(allocator, &out, &seen, node_id);
            }
            try appendNodeIdsByStringPropertyPayloadOverlay(self, allocator, &out, &seen, payload_overlay.items, key, value, kind_filter, max_nodes);
            try appendNodeIdsByStringPropertyOverlay(self, allocator, &out, &seen, overlay.items, payload_overlay.items, key, value, kind_filter, max_nodes);
            return out;
        }

        pub fn appendUniqueNodeId(allocator: std.mem.Allocator, out: *std.ArrayList(core.NodeId), seen: *std.AutoHashMap(u64, void), node_id: core.NodeId) !void {
            const gop = try seen.getOrPut(node_id.toInt());
            if (gop.found_existing) return;
            try out.append(allocator, node_id);
        }

        pub fn edgeIdLessThan(_: void, a: core.EdgeId, b: core.EdgeId) bool {
            return a.toInt() < b.toInt();
        }

        pub fn appendUniqueEdgeId(allocator: std.mem.Allocator, out: *std.ArrayList(core.EdgeId), edge_id: core.EdgeId) !void {
            for (out.items) |existing| {
                if (existing == edge_id) return;
            }
            try out.append(allocator, edge_id);
        }

        pub fn nodePropertyOverlayEntryMatchesNodeKey(entry: NodePropertyIndexEntry, node_id: core.NodeId, key: []const u8) bool {
            return entry.record.node_id == node_id.toInt() and
                entry.record.value_type == NodePropertyIndexRecord.value_type_string and
                entry.record.key_hash == nodePropertyKeyHash(key);
        }

        pub fn nodePropertyOverlayStringValue(entries: []const NodePropertyIndexEntry, node_id: core.NodeId, key: []const u8) ?[]const u8 {
            for (entries) |entry| {
                if (nodePropertyOverlayEntryMatchesNodeKey(entry, node_id, key)) {
                    return entry.value;
                }
            }
            return null;
        }

        pub fn appendNodeIdsByStringPropertyOverlay(self: Store, allocator: std.mem.Allocator, out: *std.ArrayList(core.NodeId), seen: *std.AutoHashMap(u64, void), entries: []const NodePropertyIndexEntry, payload_entries: []const PropertyPayloadIndexEntry, key: []const u8, value: []const u8, kind_filter: ?core.NodeKind, max_nodes: usize) !void {
            if (max_nodes == 0 or value.len == 0 or !nodePropertyOverlayStringKeySupported(key)) return;
            const key_hash = nodePropertyKeyHash(key);
            const value_hash = nodePropertyValueHash(value);
            for (entries) |entry| {
                if (out.items.len >= max_nodes) break;
                if (entry.record.key_hash != key_hash or entry.record.value_type != NodePropertyIndexRecord.value_type_string or entry.record.value_hash != value_hash) continue;
                const concrete = entry.value orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, concrete, value)) continue;
                const node_id: core.NodeId = .fromInt(entry.record.node_id);
                if (propertyPayloadStringValue(payload_entries, .{ .node = node_id }, key) != null) continue;
                var node = (try readNodeById(self, allocator, node_id)) orelse continue;
                defer node.deinit(allocator);
                if (kind_filter) |filter| {
                    if (node.kind != filter) continue;
                }
                try appendUniqueNodeId(allocator, out, seen, node_id);
            }
        }

        pub fn appendNodeIdsByStringPropertyPayloadOverlay(self: Store, allocator: std.mem.Allocator, out: *std.ArrayList(core.NodeId), seen: *std.AutoHashMap(u64, void), entries: []const PropertyPayloadIndexEntry, key: []const u8, value: []const u8, kind_filter: ?core.NodeKind, max_nodes: usize) !void {
            if (max_nodes == 0 or value.len == 0 or !nodePropertyOverlayStringKeySupported(key)) return;
            const key_hash = nodePropertyKeyHash(key);
            const value_hash = nodePropertyValueHash(value);
            for (entries) |entry| {
                if (out.items.len >= max_nodes) break;
                if (entry.record.owner_kind != PropertyPayloadIndexRecord.owner_kind_node) continue;
                if (entry.record.key_hash != key_hash or entry.record.value_type != PropertyPayloadIndexRecord.value_type_string or entry.record.value_hash != value_hash) continue;
                const concrete = entry.value orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, concrete, value)) continue;
                const node_id: core.NodeId = .fromInt(entry.record.owner_id);
                var node = (try readNodeById(self, allocator, node_id)) orelse continue;
                defer node.deinit(allocator);
                if (kind_filter) |filter| {
                    if (node.kind != filter) continue;
                }
                try appendUniqueNodeId(allocator, out, seen, node_id);
            }
        }

        pub fn lookupEdgeIdsByStringProperty(self: Store, allocator: std.mem.Allocator, key: []const u8, value: []const u8, max_edges: usize) !std.ArrayList(core.EdgeId) {
            var out = std.ArrayList(core.EdgeId).empty;
            errdefer out.deinit(allocator);
            if (max_edges == 0 or value.len == 0 or !edgePropertyOverlayStringKeySupported(key)) return out;

            var payload_entries = try readPropertyPayloadEntriesForKeyOrEmpty(self, allocator, key);
            defer {
                deinitPropertyPayloadIndexEntries(payload_entries.items, allocator);
                payload_entries.deinit(allocator);
            }

            const key_hash = nodePropertyKeyHash(key);
            const value_hash = nodePropertyValueHash(value);
            for (payload_entries.items) |entry| {
                if (out.items.len >= max_edges) break;
                if (entry.record.owner_kind != PropertyPayloadIndexRecord.owner_kind_edge) continue;
                if (entry.record.key_hash != key_hash or entry.record.value_type != PropertyPayloadIndexRecord.value_type_string or entry.record.value_hash != value_hash) continue;
                const concrete = entry.value orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, concrete, value)) continue;
                const edge_id: core.EdgeId = .fromInt(entry.record.owner_id);
                if (!try visibleEdgeIdExists(self, edge_id)) continue;
                try appendUniqueEdgeId(allocator, &out, edge_id);
            }

            var legacy_entries = try readNodePropertyOverlayEntriesForKeyOrEmpty(
                self,
                allocator,
                self.edge_props_overlay_index_path,
                self.edge_props_overlay_values_path,
                key,
            );
            defer {
                deinitNodePropertyIndexEntries(legacy_entries.items, allocator);
                legacy_entries.deinit(allocator);
            }
            for (legacy_entries.items) |entry| {
                if (out.items.len >= max_edges) break;
                if (entry.record.key_hash != key_hash or entry.record.value_type != NodePropertyIndexRecord.value_type_string or entry.record.value_hash != value_hash) continue;
                const concrete = entry.value orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, concrete, value)) continue;
                const edge_id: core.EdgeId = .fromInt(entry.record.node_id);
                if (propertyPayloadStringValue(payload_entries.items, .{ .edge = edge_id }, key) != null) continue;
                if (!try visibleEdgeIdExists(self, edge_id)) continue;
                try appendUniqueEdgeId(allocator, &out, edge_id);
            }
            std.mem.sort(core.EdgeId, out.items, {}, edgeIdLessThan);
            return out;
        }

        pub fn lookupNodeIdsByStringPropertyFromCurrentIndex(self: Store, allocator: std.mem.Allocator, key: []const u8, value: []const u8, kind_filter: ?core.NodeKind, max_nodes: usize) !std.ArrayList(core.NodeId) {
            var out = std.ArrayList(core.NodeId).empty;
            errdefer out.deinit(allocator);
            if (max_nodes == 0 or value.len == 0 or !nodePropertyStringKeySupported(key)) return out;
            const meta = try readCurrentIndexMeta(self);
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;
            var values_file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != meta.nodes or values_header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

            const key_hash = nodePropertyKeyHash(key);
            const value_hash = nodePropertyValueHash(value);
            const first = try nodePropertyIndexLowerBound(self, file, header, key_hash, NodePropertyIndexRecord.value_type_string, value_hash);
            var index = first;
            while (index < header.record_count and out.items.len < max_nodes) : (index += 1) {
                const record = try readNodePropertyIndexRecordAt(self, file, index);
                if (record.key_hash != key_hash or record.value_type != NodePropertyIndexRecord.value_type_string or record.value_hash != value_hash) break;
                const node_id: core.NodeId = .fromInt(record.node_id);
                var node = (try readNodeById(self, allocator, node_id)) orelse continue;
                defer node.deinit(allocator);
                if (kind_filter) |filter| {
                    if (node.kind != filter) continue;
                }
                const payload_value = try readNodePropertyValuePayloadAt(self, allocator, values_file, values_header, index, record);
                defer if (payload_value) |concrete| allocator.free(concrete);
                if (payload_value) |concrete| {
                    if (std.mem.eql(u8, concrete, value)) try out.append(allocator, node_id);
                }
            }
            return out;
        }

        pub fn lookupNodeIdsByUintProperty(self: Store, allocator: std.mem.Allocator, key: []const u8, value: u64, kind_filter: ?core.NodeKind, max_nodes: usize) !std.ArrayList(core.NodeId) {
            var derived = lookupNodeIdsByUintPropertyFromCurrentIndex(self, allocator, key, value, kind_filter, max_nodes) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => blk: {
                    try rebuildNodePropertyIndex(self);
                    break :blk try lookupNodeIdsByUintPropertyFromCurrentIndex(self, allocator, key, value, kind_filter, max_nodes);
                },
                else => |e| return e,
            };
            defer derived.deinit(allocator);

            var payload_overlay = try readPropertyPayloadEntriesForKeyOrEmpty(self, allocator, key);
            defer {
                deinitPropertyPayloadIndexEntries(payload_overlay.items, allocator);
                payload_overlay.deinit(allocator);
            }

            var out = std.ArrayList(core.NodeId).empty;
            errdefer out.deinit(allocator);
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();
            for (derived.items) |node_id| {
                if (out.items.len >= max_nodes) break;
                if (propertyPayloadUintValue(payload_overlay.items, .{ .node = node_id }, key)) |payload_value| {
                    if (payload_value != value) continue;
                }
                try appendUniqueNodeId(allocator, &out, &seen, node_id);
            }
            try appendNodeIdsByUintPropertyPayloadOverlay(self, allocator, &out, &seen, payload_overlay.items, key, .{ .min = value, .max = value }, kind_filter, max_nodes);
            return out;
        }

        pub fn lookupNodeIdsByUintPropertyFromCurrentIndex(self: Store, allocator: std.mem.Allocator, key: []const u8, value: u64, kind_filter: ?core.NodeKind, max_nodes: usize) !std.ArrayList(core.NodeId) {
            var out = std.ArrayList(core.NodeId).empty;
            errdefer out.deinit(allocator);
            if (max_nodes == 0 or !nodePropertyUintKeySupported(key)) return out;
            const meta = try readCurrentIndexMeta(self);
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;

            const key_hash = nodePropertyKeyHash(key);
            const first = try nodePropertyIndexLowerBound(self, file, header, key_hash, NodePropertyIndexRecord.value_type_uint, value);
            var index = first;
            while (index < header.record_count and out.items.len < max_nodes) : (index += 1) {
                const record = try readNodePropertyIndexRecordAt(self, file, index);
                if (record.key_hash != key_hash or record.value_type != NodePropertyIndexRecord.value_type_uint or record.value_hash != value) break;
                const node_id: core.NodeId = .fromInt(record.node_id);
                var node = (try readNodeById(self, allocator, node_id)) orelse continue;
                defer node.deinit(allocator);
                if (kind_filter) |filter| {
                    if (node.kind != filter) continue;
                }
                if (nodePropertyUintValueFromText(allocator, node.text, key)) |concrete| {
                    if (concrete == value) try out.append(allocator, node_id);
                }
            }
            return out;
        }

        pub fn lookupNodeIdsByUintPropertyRange(self: Store, allocator: std.mem.Allocator, key: []const u8, range: UintPropertyRange, kind_filter: ?core.NodeKind, max_nodes: usize) !std.ArrayList(core.NodeId) {
            var derived = lookupNodeIdsByUintPropertyRangeFromCurrentIndex(self, allocator, key, range, kind_filter, max_nodes) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => blk: {
                    try rebuildNodePropertyIndex(self);
                    break :blk try lookupNodeIdsByUintPropertyRangeFromCurrentIndex(self, allocator, key, range, kind_filter, max_nodes);
                },
                else => |e| return e,
            };
            defer derived.deinit(allocator);

            var payload_overlay = try readPropertyPayloadEntriesForKeyOrEmpty(self, allocator, key);
            defer {
                deinitPropertyPayloadIndexEntries(payload_overlay.items, allocator);
                payload_overlay.deinit(allocator);
            }

            var out = std.ArrayList(core.NodeId).empty;
            errdefer out.deinit(allocator);
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();
            for (derived.items) |node_id| {
                if (out.items.len >= max_nodes) break;
                if (propertyPayloadUintValue(payload_overlay.items, .{ .node = node_id }, key)) |payload_value| {
                    if (!range.contains(payload_value)) continue;
                }
                try appendUniqueNodeId(allocator, &out, &seen, node_id);
            }
            try appendNodeIdsByUintPropertyPayloadOverlay(self, allocator, &out, &seen, payload_overlay.items, key, range, kind_filter, max_nodes);
            return out;
        }

        pub fn lookupNodeIdsByUintPropertyRangeFromCurrentIndex(self: Store, allocator: std.mem.Allocator, key: []const u8, range: UintPropertyRange, kind_filter: ?core.NodeKind, max_nodes: usize) !std.ArrayList(core.NodeId) {
            var out = std.ArrayList(core.NodeId).empty;
            errdefer out.deinit(allocator);
            if (max_nodes == 0 or !nodePropertyUintKeySupported(key)) return out;
            if (range.min != null and range.max != null and range.min.? > range.max.?) return out;
            if (range.min != null and range.max != null and range.min.? == range.max.? and (!range.min_inclusive or !range.max_inclusive)) return out;
            const meta = try readCurrentIndexMeta(self);
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;

            const key_hash = nodePropertyKeyHash(key);
            const start_value = range.min orelse 0;
            const first = try nodePropertyIndexLowerBound(self, file, header, key_hash, NodePropertyIndexRecord.value_type_uint, start_value);
            var index = first;
            while (index < header.record_count and out.items.len < max_nodes) : (index += 1) {
                const record = try readNodePropertyIndexRecordAt(self, file, index);
                if (record.key_hash != key_hash or record.value_type != NodePropertyIndexRecord.value_type_uint) break;
                const value = record.value_hash;
                if (range.max) |max| {
                    if (range.max_inclusive) {
                        if (value > max) break;
                    } else if (value >= max) break;
                }
                if (!range.contains(value)) continue;
                const node_id: core.NodeId = .fromInt(record.node_id);
                var node = (try readNodeById(self, allocator, node_id)) orelse continue;
                defer node.deinit(allocator);
                if (kind_filter) |filter| {
                    if (node.kind != filter) continue;
                }
                if (nodePropertyUintValueFromText(allocator, node.text, key)) |concrete| {
                    if (range.contains(concrete)) try out.append(allocator, node_id);
                }
            }
            return out;
        }

        pub fn appendNodeIdsByUintPropertyPayloadOverlay(self: Store, allocator: std.mem.Allocator, out: *std.ArrayList(core.NodeId), seen: *std.AutoHashMap(u64, void), entries: []const PropertyPayloadIndexEntry, key: []const u8, range: UintPropertyRange, kind_filter: ?core.NodeKind, max_nodes: usize) !void {
            if (max_nodes == 0 or !nodePropertyPayloadUintKeySupported(key)) return;
            const key_hash = nodePropertyKeyHash(key);
            for (entries) |entry| {
                if (out.items.len >= max_nodes) break;
                if (entry.record.owner_kind != PropertyPayloadIndexRecord.owner_kind_node) continue;
                if (entry.record.key_hash != key_hash or entry.record.value_type != PropertyPayloadIndexRecord.value_type_uint) continue;
                if (!range.contains(entry.record.value_hash)) continue;
                const node_id: core.NodeId = .fromInt(entry.record.owner_id);
                var node = (try readNodeById(self, allocator, node_id)) orelse continue;
                defer node.deinit(allocator);
                if (kind_filter) |filter| {
                    if (node.kind != filter) continue;
                }
                try appendUniqueNodeId(allocator, out, seen, node_id);
            }
        }

        pub fn rebuildNodePropertyIndex(self: Store) !void {
            const meta = try readCurrentIndexMeta(self);
            var entries = std.ArrayList(NodePropertyIndexEntry).empty;
            defer {
                deinitNodePropertyIndexEntries(entries.items, self.allocator);
                entries.deinit(self.allocator);
            }
            var iterator = try nodeRecordsIterator(self, null);
            defer iterator.deinit();
            while (try iterator.next(self.allocator)) |node| {
                defer {
                    var mutable = node;
                    mutable.deinit(self.allocator);
                }
                try appendNodePropertyRecordsFromText(&entries, self.allocator, node.id, node.text);
            }
            try writeNodePropertyIndex(self, entries.items, meta);
        }

        pub fn readNodePropertyIndexHeaderFromFile(self: Store, file: std.Io.File) !NodePropertyIndexHeader {
            var bytes: [NodePropertyIndexHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return NodePropertyIndexHeader.decode(&bytes);
        }

        pub fn readNodePropertyIndexRecordAt(self: Store, file: std.Io.File, index: u64) !NodePropertyIndexRecord {
            var bytes: [NodePropertyIndexRecord.encoded_len]u8 = undefined;
            const offset = try nodePropertyIndexRecordOffset(index);
            const n = try file.readPositionalAll(self.io, &bytes, offset);
            if (n != bytes.len) return error.InvalidRecord;
            return NodePropertyIndexRecord.decode(&bytes);
        }

        pub fn readNodePropertyValueBlockHeaderFromFile(self: Store, file: std.Io.File) !NodePropertyValueBlockHeader {
            var bytes: [NodePropertyValueBlockHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return NodePropertyValueBlockHeader.decode(&bytes);
        }

        pub fn readNodePropertyValueRecordAt(self: Store, file: std.Io.File, index: u64) !NodePropertyValueRecord {
            var bytes: [NodePropertyValueRecord.encoded_len]u8 = undefined;
            const offset = try nodePropertyValueRecordOffset(index);
            const n = try file.readPositionalAll(self.io, &bytes, offset);
            if (n != bytes.len) return error.InvalidRecord;
            return NodePropertyValueRecord.decode(&bytes);
        }

        pub fn readNodePropertyValuePayloadAt(self: Store, allocator: std.mem.Allocator, file: std.Io.File, header: NodePropertyValueBlockHeader, index: u64, record: NodePropertyIndexRecord) !?[]u8 {
            const value_record = try readNodePropertyValueRecordAt(self, file, index);
            if (record.value_type == NodePropertyIndexRecord.value_type_uint) {
                if (value_record.offset != 0 or value_record.len != 0) return error.InvalidRecord;
                return null;
            }
            if (record.value_type != NodePropertyIndexRecord.value_type_string) return error.InvalidRecord;
            if (value_record.len == 0) return error.InvalidRecord;
            const value_end = std.math.add(u64, value_record.offset, value_record.len) catch return error.InvalidRecord;
            if (value_end > header.payload_bytes) return error.InvalidRecord;
            const payload_start = try nodePropertyValueBlockHeaderAndRecordBytes(header.record_count);
            const file_offset = std.math.add(u64, payload_start, value_record.offset) catch return error.InvalidRecord;
            const value = try allocator.alloc(u8, value_record.len);
            errdefer allocator.free(value);
            const n = try file.readPositionalAll(self.io, value, file_offset);
            if (n != value.len) return error.InvalidRecord;
            if (nodePropertyValueHash(value) != record.value_hash) return error.InvalidRecord;
            return value;
        }

        pub fn readPropertyPayloadIndexHeaderFromFile(self: Store, file: std.Io.File) !PropertyPayloadIndexHeader {
            var bytes: [PropertyPayloadIndexHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return PropertyPayloadIndexHeader.decode(&bytes);
        }

        pub fn readPropertyPayloadIndexRecordAt(self: Store, file: std.Io.File, index: u64) !PropertyPayloadIndexRecord {
            var bytes: [PropertyPayloadIndexRecord.encoded_len]u8 = undefined;
            const offset = try propertyPayloadIndexRecordOffset(index);
            const n = try file.readPositionalAll(self.io, &bytes, offset);
            if (n != bytes.len) return error.InvalidRecord;
            return PropertyPayloadIndexRecord.decode(&bytes);
        }

        pub fn propertyPayloadKeyHashLowerBound(self: Store, file: std.Io.File, record_count: u64, key_hash: u64) !u64 {
            var lo: u64 = 0;
            var hi = record_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const record = try readPropertyPayloadIndexRecordAt(self, file, mid);
                if (record.key_hash < key_hash) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn validatePropertyPayloadIndexOrderIfStrict(self: Store, file: std.Io.File, header: PropertyPayloadIndexHeader) !void {
            return validatePropertyPayloadIndexOrderIfStrictDeadline(self, file, header, .none);
        }

        pub fn validatePropertyPayloadIndexOrderIfStrictDeadline(
            self: Store,
            file: std.Io.File,
            header: PropertyPayloadIndexHeader,
            deadline: core.QueryDeadline,
        ) !void {
            if (!self.options.validate_indexes_on_read) return;
            var previous: ?PropertyPayloadIndexRecord = null;
            var index: u64 = 0;
            while (index < header.record_count) : (index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const record = try readPropertyPayloadIndexRecordAt(self, file, index);
                if (previous) |prev| {
                    if (!propertyPayloadRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                previous = record;
            }
        }

        pub fn readPropertyPayloadValuePayloadAt(self: Store, allocator: std.mem.Allocator, file: std.Io.File, header: NodePropertyValueBlockHeader, index: u64, record: PropertyPayloadIndexRecord) !?[]u8 {
            const value_record = try readNodePropertyValueRecordAt(self, file, index);
            if (record.value_type == PropertyPayloadIndexRecord.value_type_uint) {
                if (value_record.offset != 0 or value_record.len != 0) return error.InvalidRecord;
                return null;
            }
            if (record.value_type != PropertyPayloadIndexRecord.value_type_string) return error.InvalidRecord;
            if (value_record.len == 0) return error.InvalidRecord;
            const value_end = std.math.add(u64, value_record.offset, value_record.len) catch return error.InvalidRecord;
            if (value_end > header.payload_bytes) return error.InvalidRecord;
            const payload_start = try nodePropertyValueBlockHeaderAndRecordBytes(header.record_count);
            const file_offset = std.math.add(u64, payload_start, value_record.offset) catch return error.InvalidRecord;
            const value = try allocator.alloc(u8, value_record.len);
            errdefer allocator.free(value);
            const n = try file.readPositionalAll(self.io, value, file_offset);
            if (n != value.len) return error.InvalidRecord;
            if (nodePropertyValueHash(value) != record.value_hash) return error.InvalidRecord;
            return value;
        }

        pub fn nodePropertyIndexLowerBound(self: Store, file: std.Io.File, header: NodePropertyIndexHeader, key_hash: u64, value_type: u8, value_hash: u64) !u64 {
            var lo: u64 = 0;
            var hi: u64 = header.record_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const record = try readNodePropertyIndexRecordAt(self, file, mid);
                if (record.key_hash < key_hash or
                    (record.key_hash == key_hash and record.value_type < value_type) or
                    (record.key_hash == key_hash and record.value_type == value_type and record.value_hash < value_hash))
                {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn writeNodePropertyIndex(self: Store, entries: []NodePropertyIndexEntry, meta: IndexMeta) !void {
            try writeNodePropertyIndexFiles(self, self.node_props_index_path, self.node_props_values_path, entries, meta);
        }

        pub fn writeNodePropertyIndexFiles(self: Store, index_path: []const u8, values_path: []const u8, entries: []NodePropertyIndexEntry, meta: IndexMeta) !void {
            std.mem.sort(NodePropertyIndexEntry, entries, {}, nodePropertyIndexEntryLessThan);
            const tmp_path = try tmpPathFor(self, index_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(try nodePropertyIndexFileSize(@intCast(entries.len))));
                defer writer.deinit();
                const header = NodePropertyIndexHeader{
                    .record_count = @intCast(entries.len),
                    .node_count = meta.nodes,
                    .node_digest = meta.node_digest,
                };
                var header_bytes: [NodePropertyIndexHeader.encoded_len]u8 = undefined;
                header.encode(&header_bytes);
                try writer.append(&header_bytes);
                var previous: ?NodePropertyIndexRecord = null;
                for (entries) |entry| {
                    const record = entry.record;
                    if (previous) |prev| {
                        if (!nodePropertyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                    }
                    var record_bytes: [NodePropertyIndexRecord.encoded_len]u8 = undefined;
                    try record.encode(&record_bytes);
                    try writer.append(&record_bytes);
                    previous = record;
                }
                try writer.flush();
                if (try regularFileSize(self, file) != try nodePropertyIndexFileSize(@intCast(entries.len))) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try writeNodePropertyValueBlock(self, values_path, entries, meta);
            try renameReplace(self, tmp_path, index_path);
        }

        pub fn writeNodePropertyValueBlock(self: Store, values_path: []const u8, entries: []const NodePropertyIndexEntry, meta: IndexMeta) !void {
            const tmp_path = try tmpPathFor(self, values_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            const value_records = try self.allocator.alloc(NodePropertyValueRecord, entries.len);
            defer self.allocator.free(value_records);
            var payload_bytes: u64 = 0;
            var payload_digest: u64 = 0;
            var digest_bytes: [8]u8 = undefined;
            for (entries, 0..) |entry, i| {
                if (entry.record.value_type == NodePropertyIndexRecord.value_type_string) {
                    const value = entry.value orelse return error.InvalidRecord;
                    if (value.len == 0 or nodePropertyValueHash(value) != entry.record.value_hash) return error.InvalidRecord;
                    const len_u32 = std.math.cast(u32, value.len) orelse return error.RecordTooLarge;
                    value_records[i] = .{ .offset = payload_bytes, .len = len_u32 };
                    std.mem.writeInt(u64, &digest_bytes, entry.record.key_hash, .little);
                    payload_digest ^= std.hash.Wyhash.hash(0x544B_5056, &digest_bytes);
                    std.mem.writeInt(u64, &digest_bytes, entry.record.value_hash, .little);
                    payload_digest ^= std.hash.Wyhash.hash(0x544B_5056, &digest_bytes);
                    payload_digest ^= std.hash.Wyhash.hash(0x544B_5056, value);
                    payload_bytes = std.math.add(u64, payload_bytes, value.len) catch return error.RecordTooLarge;
                } else if (entry.record.value_type == NodePropertyIndexRecord.value_type_uint) {
                    if (entry.value != null) return error.InvalidRecord;
                    value_records[i] = .{ .offset = 0, .len = 0 };
                } else {
                    return error.InvalidRecord;
                }
            }
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                const file_size = try nodePropertyValueBlockFileSize(@intCast(entries.len), payload_bytes);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(file_size));
                defer writer.deinit();
                const header = NodePropertyValueBlockHeader{
                    .record_count = @intCast(entries.len),
                    .node_count = meta.nodes,
                    .node_digest = meta.node_digest,
                    .payload_bytes = payload_bytes,
                    .payload_digest = payload_digest,
                };
                var header_bytes: [NodePropertyValueBlockHeader.encoded_len]u8 = undefined;
                header.encode(&header_bytes);
                try writer.append(&header_bytes);
                var value_record_bytes: [NodePropertyValueRecord.encoded_len]u8 = undefined;
                for (value_records) |record| {
                    record.encode(&value_record_bytes);
                    try writer.append(&value_record_bytes);
                }
                for (entries) |entry| {
                    if (entry.record.value_type == NodePropertyIndexRecord.value_type_string) {
                        try writer.append(entry.value.?);
                    }
                }
                try writer.flush();
                if (try regularFileSize(self, file) != file_size) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, values_path);
        }

        pub fn applyPropertyPayloadDeltaEntryIndexed(
            allocator: std.mem.Allocator,
            target: PropertyPayloadIndexedTarget,
            record: PropertyPayloadIndexRecord,
            string_value: ?[]const u8,
        ) !void {
            const owner_key = PropertyPayloadOwnerKey{
                .owner_kind = record.owner_kind,
                .owner_id = record.owner_id,
                .key_hash = record.key_hash,
            };
            const existing_index = target.positions.get(owner_key);
            const old_len = if (existing_index) |index| blk: {
                if (index >= target.entries.items.len) return error.InvalidRecord;
                break :blk if (target.entries.items[index].value) |value| value.len else 0;
            } else 0;
            const next_budget_bytes = if (target.searchable_byte_budget) |budget|
                try budget.afterReplace(old_len, if (string_value) |value| value.len else 0)
            else
                0;
            const owned = if (string_value) |value| try allocator.dupe(u8, value) else null;
            errdefer if (owned) |value| allocator.free(value);
            if (existing_index) |index| {
                target.entries.items[index].deinit(allocator);
                target.entries.items[index] = .{ .record = record, .value = owned };
                if (target.searchable_byte_budget) |budget| budget.used_bytes = next_budget_bytes;
                return;
            }

            try target.entries.ensureUnusedCapacity(allocator, 1);
            const position = try target.positions.getOrPut(owner_key);
            if (position.found_existing) return error.InvalidRecord;
            position.value_ptr.* = target.entries.items.len;
            target.entries.appendAssumeCapacity(.{ .record = record, .value = owned });
            if (target.searchable_byte_budget) |budget| budget.used_bytes = next_budget_bytes;
        }

        pub fn applyPropertyPayloadDeltaEntryToSnapshot(
            allocator: std.mem.Allocator,
            target: PropertyPayloadSnapshotTarget,
            record: PropertyPayloadIndexRecord,
            string_value: ?[]const u8,
        ) !void {
            if (!target.owner_filter.matches(record.owner_kind, record.owner_id)) return;
            const value_kind: PropertySnapshotValueKind = switch (record.value_type) {
                PropertyPayloadIndexRecord.value_type_string => .string,
                PropertyPayloadIndexRecord.value_type_uint => .uint,
                else => return error.InvalidRecord,
            };
            const owned = if (value_kind == .string)
                try allocator.dupe(u8, string_value orelse return error.InvalidRecord)
            else
                &.{};
            errdefer if (value_kind == .string) allocator.free(owned);
            const replacement = PropertySnapshotEntry{
                .owner = try propertyPayloadOwnerFromParts(record.owner_kind, record.owner_id),
                .key_hash = record.key_hash,
                .value_kind = value_kind,
                .string_len = if (value_kind == .string) @intCast(owned.len) else 0,
                .string_value = owned,
                .uint_value = if (value_kind == .uint) record.value_hash else 0,
            };
            const owner_key = PropertyPayloadOwnerKey{
                .owner_kind = record.owner_kind,
                .owner_id = record.owner_id,
                .key_hash = record.key_hash,
            };
            if (target.positions.get(owner_key)) |position| {
                if (position >= target.entries.items.len) return error.InvalidRecord;
                if (target.entries.items[position].value_kind == .string) allocator.free(target.entries.items[position].string_value);
                target.entries.items[position] = replacement;
                return;
            }
            try target.entries.ensureUnusedCapacity(allocator, 1);
            const position = try target.positions.getOrPut(owner_key);
            if (position.found_existing) return error.InvalidRecord;
            position.value_ptr.* = target.entries.items.len;
            target.entries.appendAssumeCapacity(replacement);
        }

        pub fn parsePropertyPayloadDeltaPayload(
            allocator: std.mem.Allocator,
            header: PropertyPayloadDeltaHeader,
            payload: []const u8,
            target: PropertyPayloadDeltaTarget,
        ) !void {
            if (payload.len != header.payload_len or std.hash.Wyhash.hash(property_payload_delta_digest_seed, payload) != header.payload_digest) return error.InvalidRecord;
            const min_entry_bytes = property_payload_delta_entry_len + 1;
            if (header.write_count > payload.len / min_entry_bytes) return error.InvalidRecord;
            var frame_keys = PropertyPayloadOwnerKeySet.init(allocator);
            defer frame_keys.deinit();
            try frame_keys.ensureTotalCapacity(header.write_count);
            var offset: usize = 0;
            var write_index: u32 = 0;
            while (write_index < header.write_count) : (write_index += 1) {
                if (payload.len - offset < property_payload_delta_entry_len) return error.InvalidRecord;
                const raw = payload[offset..][0..property_payload_delta_entry_len];
                offset += property_payload_delta_entry_len;
                if (!allZero(raw[32..40])) return error.InvalidRecord;
                const owner_kind = raw[0];
                const value_type = raw[1];
                const key_len = readU16(raw[2..4]);
                const value_len = readU32(raw[4..8]);
                const owner_id = readU64(raw[8..16]);
                const key_hash = readU64(raw[16..24]);
                const value_hash = readU64(raw[24..32]);
                if ((owner_kind != PropertyPayloadIndexRecord.owner_kind_node and owner_kind != PropertyPayloadIndexRecord.owner_kind_edge) or
                    (value_type != PropertyPayloadIndexRecord.value_type_string and value_type != PropertyPayloadIndexRecord.value_type_uint) or
                    owner_id == 0 or owner_id == std.math.maxInt(u64) or key_len == 0)
                {
                    return error.InvalidRecord;
                }
                const body_len = std.math.add(usize, key_len, value_len) catch return error.InvalidRecord;
                if (payload.len - offset < body_len) return error.InvalidRecord;
                const key = payload[offset..][0..key_len];
                const string_value = payload[offset + key_len .. offset + body_len];
                offset += body_len;
                if (!propertyKeyNameValid(key) or nodePropertyKeyHash(key) != key_hash) return error.InvalidRecord;
                const owner: PropertyOwner = if (owner_kind == PropertyPayloadIndexRecord.owner_kind_node)
                    .{ .node = .fromInt(owner_id) }
                else
                    .{ .edge = .fromInt(owner_id) };
                const frame_key = try frame_keys.getOrPut(.{
                    .owner_kind = owner_kind,
                    .owner_id = owner_id,
                    .key_hash = key_hash,
                });
                if (frame_key.found_existing) return error.InvalidRecord;
                if (value_type == PropertyPayloadIndexRecord.value_type_string) {
                    if (value_len == 0 or nodePropertyValueHash(string_value) != value_hash or !stringPropertyKeySupportedForOwner(owner, key)) return error.InvalidRecord;
                } else if (value_len != 0 or !uintPropertyKeySupportedForOwner(owner, key)) {
                    return error.InvalidRecord;
                }
                const record = PropertyPayloadIndexRecord{
                    .key_hash = key_hash,
                    .value_hash = value_hash,
                    .owner_id = owner_id,
                    .owner_kind = owner_kind,
                    .value_type = value_type,
                };
                switch (target) {
                    .none => {},
                    .all => |out| try applyPropertyPayloadDeltaEntryIndexed(
                        allocator,
                        out,
                        record,
                        if (value_type == PropertyPayloadIndexRecord.value_type_string) string_value else null,
                    ),
                    .searchable => |out| {
                        if (owner_kind == PropertyPayloadIndexRecord.owner_kind_node and
                            value_type == PropertyPayloadIndexRecord.value_type_string and
                            (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "summary")))
                        {
                            try applyPropertyPayloadDeltaEntryIndexed(allocator, out, record, string_value);
                        }
                    },
                    .key => |lookup| {
                        if (lookup.key_hash == key_hash and std.mem.eql(u8, lookup.key_name, key)) {
                            if (lookup.owner_filter) |filter| {
                                if (!filter.matches(owner_kind, owner_id)) continue;
                            }
                            try applyPropertyPayloadDeltaEntryIndexed(
                                allocator,
                                .{ .entries = lookup.entries, .positions = lookup.positions },
                                record,
                                if (value_type == PropertyPayloadIndexRecord.value_type_string) string_value else null,
                            );
                        }
                    },
                    .snapshot => |lookup| {
                        const expected_name = lookup.key_names.get(key_hash) orelse continue;
                        if (!std.mem.eql(u8, expected_name, key)) continue;
                        try applyPropertyPayloadDeltaEntryToSnapshot(allocator, lookup, record, if (value_type == PropertyPayloadIndexRecord.value_type_string) string_value else null);
                    },
                    .existing_keys => |lookup| {
                        const owner_key = PropertyPayloadOwnerKey{
                            .owner_kind = owner_kind,
                            .owner_id = owner_id,
                            .key_hash = key_hash,
                        };
                        if (lookup.wanted.contains(owner_key)) try lookup.found.put(owner_key, {});
                    },
                    .lookup => |lookup| {
                        if (lookup.owner_key.owner_kind == owner_kind and
                            lookup.owner_key.owner_id == owner_id and
                            lookup.owner_key.key_hash == key_hash and
                            std.mem.eql(u8, lookup.key_name, key))
                        {
                            if (lookup.value) |*previous| previous.deinit(allocator);
                            const owned = if (value_type == PropertyPayloadIndexRecord.value_type_string)
                                try allocator.dupe(u8, string_value)
                            else
                                null;
                            lookup.value = .{ .record = record, .value = owned };
                        }
                    },
                    .layer_scan => |scan| {
                        if (scan.next_version.* == std.math.maxInt(u64)) return error.RecordTooLarge;
                        const version = scan.next_version.*;
                        scan.next_version.* += 1;
                        try scan.visit(scan.context, .{
                            .owner = owner,
                            .key_hash = key_hash,
                            .version = version,
                            .value_kind = if (value_type == PropertyPayloadIndexRecord.value_type_string) .string else .uint,
                            .string_value = if (value_type == PropertyPayloadIndexRecord.value_type_string) string_value else &.{},
                            .uint_value = if (value_type == PropertyPayloadIndexRecord.value_type_uint) value_hash else 0,
                        });
                    },
                }
            }
            if (offset != payload.len) return error.InvalidRecord;
        }

        pub fn scanPropertyPayloadDelta(
            self: Store,
            allocator: std.mem.Allocator,
            target: PropertyPayloadDeltaTarget,
            allow_partial_tail: bool,
        ) !PropertyPayloadDeltaScan {
            return scanPropertyPayloadDeltaLimited(self, allocator, target, allow_partial_tail, null, .none);
        }

        pub fn scanPropertyPayloadDeltaLimited(
            self: Store,
            allocator: std.mem.Allocator,
            target: PropertyPayloadDeltaTarget,
            allow_partial_tail: bool,
            max_scan_bytes: ?u64,
            deadline: core.QueryDeadline,
        ) !PropertyPayloadDeltaScan {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            var file = std.Io.Dir.cwd().openFile(self.io, self.property_payload_delta_path, .{ .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => return .{},
                else => |e| return e,
            };
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            // Capture and admit the complete scan range before reading the first
            // frame. A caller that promises bounded fallback I/O must never walk
            // a giant append-only delta and reject only after doing the work.
            // Later concurrent appends are outside this fixed snapshot range.
            if (max_scan_bytes) |limit| {
                if (file_size > limit) return error.SearchableMetadataBudgetExceeded;
            }
            var scan = PropertyPayloadDeltaScan{};
            while (scan.valid_bytes < file_size) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const remaining = file_size - scan.valid_bytes;
                if (remaining < property_payload_delta_header_len) {
                    if (!allow_partial_tail) return error.InvalidRecord;
                    scan.trailing_partial = true;
                    return scan;
                }
                var header_bytes: [property_payload_delta_header_len]u8 = undefined;
                const header_n = try file.readPositionalAll(self.io, &header_bytes, scan.valid_bytes);
                if (header_n != header_bytes.len) return error.InvalidRecord;
                const header = PropertyPayloadDeltaHeader.decode(&header_bytes) catch |err| {
                    if (!allow_partial_tail) return err;
                    scan.trailing_partial = true;
                    return scan;
                };
                const frame_len = std.math.add(u64, property_payload_delta_header_len, header.payload_len) catch return error.InvalidRecord;
                if (remaining < frame_len) {
                    if (!allow_partial_tail) return error.InvalidRecord;
                    scan.trailing_partial = true;
                    return scan;
                }
                if (header.sequence != std.math.add(u64, scan.last_sequence, 1) catch return error.InvalidRecord) {
                    if (!allow_partial_tail) return error.InvalidRecord;
                    scan.trailing_partial = true;
                    return scan;
                }
                const payload = try allocator.alloc(u8, header.payload_len);
                defer allocator.free(payload);
                const payload_offset = std.math.add(u64, scan.valid_bytes, property_payload_delta_header_len) catch return error.InvalidRecord;
                const payload_n = try file.readPositionalAll(self.io, payload, payload_offset);
                if (payload_n != payload.len) return error.InvalidRecord;
                parsePropertyPayloadDeltaPayload(allocator, header, payload, target) catch |err| {
                    if (!allow_partial_tail) return err;
                    scan.trailing_partial = true;
                    return scan;
                };
                scan.valid_bytes = std.math.add(u64, scan.valid_bytes, frame_len) catch return error.InvalidRecord;
                scan.last_sequence = header.sequence;
                scan.last_digest = header.payload_digest;
            }
            return scan;
        }

        pub fn readNodePropertyIndexEntriesForMeta(self: Store, allocator: std.mem.Allocator, meta: IndexMeta) !std.ArrayList(NodePropertyIndexEntry) {
            return try readNodePropertyIndexEntriesFromFiles(self, allocator, self.node_props_index_path, self.node_props_values_path, meta);
        }

        pub fn readNodePropertyIndexEntriesFromFiles(self: Store, allocator: std.mem.Allocator, index_path: []const u8, values_path: []const u8, meta: IndexMeta) !std.ArrayList(NodePropertyIndexEntry) {
            var file = try std.Io.Dir.cwd().openFile(self.io, index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;
            var entries = std.ArrayList(NodePropertyIndexEntry).empty;
            errdefer {
                deinitNodePropertyIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            try entries.ensureTotalCapacity(allocator, std.math.cast(usize, header.record_count) orelse return error.RecordTooLarge);
            var values_file = try std.Io.Dir.cwd().openFile(self.io, values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != meta.nodes or values_header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;
            var previous: ?NodePropertyIndexRecord = null;
            var index: u64 = 0;
            while (index < header.record_count) : (index += 1) {
                const record = try readNodePropertyIndexRecordAt(self, file, index);
                if (previous) |prev| {
                    if (!nodePropertyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                const value = try readNodePropertyValuePayloadAt(self, allocator, values_file, values_header, index, record);
                entries.appendAssumeCapacity(.{ .record = record, .value = value });
                previous = record;
            }
            return entries;
        }

        pub fn readPropertyPayloadEntriesFromFiles(self: Store, allocator: std.mem.Allocator, index_path: []const u8, values_path: []const u8) !std.ArrayList(PropertyPayloadIndexEntry) {
            var file = try std.Io.Dir.cwd().openFile(self.io, index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readPropertyPayloadIndexHeaderFromFile(self, file);
            if (header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try propertyPayloadIndexFileSize(header.record_count)) return error.InvalidRecord;
            var entries = std.ArrayList(PropertyPayloadIndexEntry).empty;
            errdefer {
                deinitPropertyPayloadIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            try entries.ensureTotalCapacity(allocator, std.math.cast(usize, header.record_count) orelse return error.RecordTooLarge);
            var values_file = try std.Io.Dir.cwd().openFile(self.io, values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;
            var previous: ?PropertyPayloadIndexRecord = null;
            var index: u64 = 0;
            while (index < header.record_count) : (index += 1) {
                const record = try readPropertyPayloadIndexRecordAt(self, file, index);
                if (previous) |prev| {
                    if (!propertyPayloadRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                const value = try readPropertyPayloadValuePayloadAt(self, allocator, values_file, values_header, index, record);
                entries.appendAssumeCapacity(.{ .record = record, .value = value });
                previous = record;
            }
            return entries;
        }

        pub fn nodePropertyOverlayMeta() IndexMeta {
            return .{};
        }

        pub fn readNodePropertyOverlayEntriesOrEmpty(self: Store, allocator: std.mem.Allocator) !std.ArrayList(NodePropertyIndexEntry) {
            const has_index = try fileExists(self, self.node_props_overlay_index_path);
            const has_values = try fileExists(self, self.node_props_overlay_values_path);
            if (!has_index and !has_values) return std.ArrayList(NodePropertyIndexEntry).empty;
            if (has_index != has_values) return error.InvalidRecord;
            return try readNodePropertyIndexEntriesFromFiles(self, allocator, self.node_props_overlay_index_path, self.node_props_overlay_values_path, nodePropertyOverlayMeta());
        }

        pub fn readNodePropertyOverlayEntriesForKeyOrEmpty(
            self: Store,
            allocator: std.mem.Allocator,
            index_path: []const u8,
            values_path: []const u8,
            key: []const u8,
        ) !std.ArrayList(NodePropertyIndexEntry) {
            return try readNodePropertyOverlayEntriesForKeyOwnersOrEmpty(self, allocator, index_path, values_path, key, null);
        }

        pub fn readNodePropertyOverlayEntriesForKeyOwnersOrEmpty(
            self: Store,
            allocator: std.mem.Allocator,
            index_path: []const u8,
            values_path: []const u8,
            key: []const u8,
            wanted_node_ids: ?*const PropertyPayloadNodeIdSet,
        ) !std.ArrayList(NodePropertyIndexEntry) {
            const has_index = try fileExists(self, index_path);
            const has_values = try fileExists(self, values_path);
            if (!has_index and !has_values) return std.ArrayList(NodePropertyIndexEntry).empty;
            if (has_index != has_values) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().openFile(self.io, index_path, .{ .allow_directory = false });
            defer index_file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, index_file);
            if (header.node_count != 0 or header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, index_file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;

            var values_file = try std.Io.Dir.cwd().openFile(self.io, values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

            var entries = std.ArrayList(NodePropertyIndexEntry).empty;
            errdefer {
                deinitNodePropertyIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            const key_hash = nodePropertyKeyHash(key);
            var index = try nodePropertyIndexLowerBound(self, index_file, header, key_hash, 0, 0);
            while (index < header.record_count) : (index += 1) {
                const record = try readNodePropertyIndexRecordAt(self, index_file, index);
                if (record.key_hash != key_hash) break;
                if (wanted_node_ids) |wanted| {
                    if (!wanted.contains(record.node_id)) continue;
                }
                const value = try readNodePropertyValuePayloadAt(self, allocator, values_file, values_header, index, record);
                errdefer if (value) |owned| allocator.free(owned);
                try entries.append(allocator, .{ .record = record, .value = value });
            }
            return entries;
        }

        pub fn writeNodePropertyOverlay(self: Store, entries: []NodePropertyIndexEntry) !void {
            try writeNodePropertyIndexFiles(self, self.node_props_overlay_index_path, self.node_props_overlay_values_path, entries, nodePropertyOverlayMeta());
        }

        pub fn readEdgePropertyOverlayEntriesOrEmpty(self: Store, allocator: std.mem.Allocator) !std.ArrayList(NodePropertyIndexEntry) {
            const has_index = try fileExists(self, self.edge_props_overlay_index_path);
            const has_values = try fileExists(self, self.edge_props_overlay_values_path);
            if (!has_index and !has_values) return std.ArrayList(NodePropertyIndexEntry).empty;
            if (has_index != has_values) return error.InvalidRecord;
            return try readNodePropertyIndexEntriesFromFiles(self, allocator, self.edge_props_overlay_index_path, self.edge_props_overlay_values_path, nodePropertyOverlayMeta());
        }

        pub fn writeEdgePropertyOverlay(self: Store, entries: []NodePropertyIndexEntry) !void {
            try writeNodePropertyIndexFiles(self, self.edge_props_overlay_index_path, self.edge_props_overlay_values_path, entries, nodePropertyOverlayMeta());
        }

        pub fn readPropertyPayloadEntriesOrEmpty(self: Store, allocator: std.mem.Allocator) !std.ArrayList(PropertyPayloadIndexEntry) {
            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            var entries = if (!has_index and !has_values)
                std.ArrayList(PropertyPayloadIndexEntry).empty
            else blk: {
                if (has_index != has_values) return error.InvalidRecord;
                break :blk try readPropertyPayloadEntriesFromFiles(self, allocator, self.property_payload_index_path, self.property_payload_values_path);
            };
            errdefer {
                deinitPropertyPayloadIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            var positions = std.AutoHashMap(PropertyPayloadOwnerKey, usize).init(allocator);
            defer positions.deinit();
            try positions.ensureTotalCapacity(std.math.cast(u32, entries.items.len) orelse return error.RecordTooLarge);
            for (entries.items, 0..) |entry, index| {
                const position = try positions.getOrPut(.{
                    .owner_kind = entry.record.owner_kind,
                    .owner_id = entry.record.owner_id,
                    .key_hash = entry.record.key_hash,
                });
                if (position.found_existing) return error.InvalidRecord;
                position.value_ptr.* = index;
            }
            _ = try scanPropertyPayloadDelta(self, allocator, .{ .all = .{
                .entries = &entries,
                .positions = &positions,
            } }, false);
            std.mem.sort(PropertyPayloadIndexEntry, entries.items, {}, propertyPayloadEntryLessThan);
            return entries;
        }

        pub fn readPropertyPayloadEntriesForKeyOrEmpty(self: Store, allocator: std.mem.Allocator, key: []const u8) !std.ArrayList(PropertyPayloadIndexEntry) {
            return try readPropertyPayloadEntriesForKeyOwnersOrEmpty(self, allocator, key, null, true);
        }

        pub fn readPropertyPayloadEntriesForKeyOwnersOrEmpty(
            self: Store,
            allocator: std.mem.Allocator,
            key: []const u8,
            owner_filter: ?PropertyPayloadOwnerFilter,
            include_delta: bool,
        ) !std.ArrayList(PropertyPayloadIndexEntry) {
            var entries = std.ArrayList(PropertyPayloadIndexEntry).empty;
            errdefer {
                deinitPropertyPayloadIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            var positions = std.AutoHashMap(PropertyPayloadOwnerKey, usize).init(allocator);
            defer positions.deinit();

            const key_hash = nodePropertyKeyHash(key);
            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            if (has_index != has_values) return error.InvalidRecord;
            if (has_index) {
                var index_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_index_path, .{ .allow_directory = false });
                defer index_file.close(self.io);
                const header = try readPropertyPayloadIndexHeaderFromFile(self, index_file);
                if (header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, index_file) != try propertyPayloadIndexFileSize(header.record_count)) return error.InvalidRecord;
                try validatePropertyPayloadIndexOrderIfStrict(self, index_file, header);

                var values_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_values_path, .{ .allow_directory = false });
                defer values_file.close(self.io);
                const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
                if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

                var index = try propertyPayloadKeyHashLowerBound(self, index_file, header.record_count, key_hash);
                while (index < header.record_count) : (index += 1) {
                    const record = try readPropertyPayloadIndexRecordAt(self, index_file, index);
                    if (record.key_hash != key_hash) break;
                    if (owner_filter) |filter| {
                        if (!filter.matches(record.owner_kind, record.owner_id)) continue;
                    }
                    const owner_key = PropertyPayloadOwnerKey{
                        .owner_kind = record.owner_kind,
                        .owner_id = record.owner_id,
                        .key_hash = record.key_hash,
                    };
                    const position = try positions.getOrPut(owner_key);
                    if (position.found_existing) return error.InvalidRecord;
                    const value = try readPropertyPayloadValuePayloadAt(self, allocator, values_file, values_header, index, record);
                    errdefer if (value) |owned| allocator.free(owned);
                    try entries.append(allocator, .{ .record = record, .value = value });
                    position.value_ptr.* = entries.items.len - 1;
                }
            }

            if (include_delta) {
                _ = try scanPropertyPayloadDelta(self, allocator, .{ .key = .{
                    .key_hash = key_hash,
                    .key_name = key,
                    .entries = &entries,
                    .positions = &positions,
                    .owner_filter = owner_filter,
                } }, false);
            }
            std.mem.sort(PropertyPayloadIndexEntry, entries.items, {}, propertyPayloadEntryLessThan);
            return entries;
        }

        pub fn readSearchablePropertyPayloadEntriesOrEmpty(
            self: Store,
            allocator: std.mem.Allocator,
            byte_budget: ?*SearchablePropertyByteBudget,
            delta_scan_byte_budget: ?u64,
            deadline: core.QueryDeadline,
        ) !std.ArrayList(PropertyPayloadIndexEntry) {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            var entries = std.ArrayList(PropertyPayloadIndexEntry).empty;
            errdefer {
                deinitPropertyPayloadIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            var positions = std.AutoHashMap(PropertyPayloadOwnerKey, usize).init(allocator);
            defer positions.deinit();
            // The common steady state has an immutable base and no delta. Keep
            // metadata digest/snapshot reads within their tiny allocation budget;
            // the owner-key map is needed only when latest-wins delta records can
            // actually replace base entries. `pathExists` intentionally preserves
            // directories/other invalid path kinds so the scan below still fails
            // closed instead of treating corruption as an absent delta.
            const has_delta = try pathExists(self, self.property_payload_delta_path);

            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            if (has_index != has_values) return error.InvalidRecord;
            if (has_index) {
                var index_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_index_path, .{ .allow_directory = false });
                defer index_file.close(self.io);
                const header = try readPropertyPayloadIndexHeaderFromFile(self, index_file);
                if (header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, index_file) != try propertyPayloadIndexFileSize(header.record_count)) return error.InvalidRecord;
                try validatePropertyPayloadIndexOrderIfStrictDeadline(self, index_file, header, deadline);

                var values_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_values_path, .{ .allow_directory = false });
                defer values_file.close(self.io);
                const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
                if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

                // The immutable index is ordered by key hash.  Stale-text checks
                // need only `name` and `summary`; walking every unrelated
                // lifecycle/blob property made a quick search-open O(all
                // properties).  Probe the two contiguous ranges directly while
                // retaining the same record/value validation for every selected
                // entry.  Full-file validation remains the responsibility of
                // maintenance and readers that actually consume the other keys.
                const searchable_hashes = [_]u64{
                    nodePropertyKeyHash("name"),
                    nodePropertyKeyHash("summary"),
                };
                if (searchable_hashes[0] == searchable_hashes[1]) return error.InvalidRecord;
                for (searchable_hashes) |key_hash| {
                    var previous: ?PropertyPayloadIndexRecord = null;
                    var index = try propertyPayloadKeyHashLowerBound(self, index_file, header.record_count, key_hash);
                    while (index < header.record_count) : (index += 1) {
                        if (deadline.expired()) return core.Error.BudgetExceeded;
                        const record = try readPropertyPayloadIndexRecordAt(self, index_file, index);
                        if (record.key_hash != key_hash) break;
                        if (previous) |prev| {
                            if (!propertyPayloadRecordLessThan({}, prev, record)) return error.InvalidRecord;
                        }
                        const value_record = try readNodePropertyValueRecordAt(self, values_file, index);
                        if (record.value_type == PropertyPayloadIndexRecord.value_type_uint) {
                            if (value_record.offset != 0 or value_record.len != 0) return error.InvalidRecord;
                        } else if (record.value_type == PropertyPayloadIndexRecord.value_type_string) {
                            if (value_record.len == 0) return error.InvalidRecord;
                            const payload_end = std.math.add(u64, value_record.offset, value_record.len) catch return error.InvalidRecord;
                            if (payload_end > values_header.payload_bytes) return error.InvalidRecord;
                            if (record.owner_kind == PropertyPayloadIndexRecord.owner_kind_node) {
                                const next_budget_bytes = if (byte_budget) |budget|
                                    try budget.afterReplace(0, @intCast(value_record.len))
                                else
                                    0;
                                const value = (try readPropertyPayloadValuePayloadAt(self, allocator, values_file, values_header, index, record)) orelse return error.InvalidRecord;
                                errdefer allocator.free(value);
                                const position = if (has_delta) try positions.getOrPut(.{
                                    .owner_kind = record.owner_kind,
                                    .owner_id = record.owner_id,
                                    .key_hash = record.key_hash,
                                }) else null;
                                if (position) |entry| {
                                    if (entry.found_existing) return error.InvalidRecord;
                                }
                                try entries.append(allocator, .{ .record = record, .value = value });
                                if (position) |entry| entry.value_ptr.* = entries.items.len - 1;
                                if (byte_budget) |budget| budget.used_bytes = next_budget_bytes;
                            }
                        } else {
                            return error.InvalidRecord;
                        }
                        previous = record;
                    }
                }
            }

            if (has_delta) {
                _ = try scanPropertyPayloadDeltaLimited(self, allocator, .{ .searchable = .{
                    .entries = &entries,
                    .positions = &positions,
                    .searchable_byte_budget = byte_budget,
                } }, false, delta_scan_byte_budget, deadline);
            }
            std.mem.sort(PropertyPayloadIndexEntry, entries.items, {}, propertyPayloadEntryLessThan);
            return entries;
        }

        pub fn addSearchableNodeMetadataDigest(
            digest: *u64,
            seed: u64,
            owner_id: u64,
            key_hash: u64,
            value_hash: u64,
            value: []const u8,
        ) void {
            var entry_hasher = std.hash.Wyhash.init(seed);
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, owner_id, .little);
            entry_hasher.update(&bytes);
            std.mem.writeInt(u64, &bytes, key_hash, .little);
            entry_hasher.update(&bytes);
            std.mem.writeInt(u64, &bytes, value_hash, .little);
            entry_hasher.update(&bytes);
            entry_hasher.update(value);
            // Records are stored in multiple ordered physical layers, but the
            // stale anchor should not depend on traversal order. Hash each full
            // association first, then combine record digests commutatively.
            // Hashing tuple fields independently would make swapping two values
            // between owners invisible because every component still appears in
            // the same XOR multiset.
            digest.* ^= entry_hasher.final();
        }

        pub fn addSearchableNodeMetadataDigestFromValueFile(
            self: Store,
            digest: *u64,
            seed: u64,
            owner_id: u64,
            key_hash: u64,
            value_hash: u64,
            file: std.Io.File,
            file_offset: u64,
            value_len: u32,
            deadline: core.QueryDeadline,
        ) !void {
            var entry_hasher = std.hash.Wyhash.init(seed);
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, owner_id, .little);
            entry_hasher.update(&bytes);
            std.mem.writeInt(u64, &bytes, key_hash, .little);
            entry_hasher.update(&bytes);
            std.mem.writeInt(u64, &bytes, value_hash, .little);
            entry_hasher.update(&bytes);

            var value_hasher = std.hash.Wyhash.init(0x544B_5056);
            var scratch: [16 * 1024]u8 = undefined;
            var consumed: u64 = 0;
            while (consumed < value_len) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const remaining = @as(u64, value_len) - consumed;
                const take: usize = @intCast(@min(remaining, scratch.len));
                const offset = std.math.add(u64, file_offset, consumed) catch return error.InvalidRecord;
                const n = try file.readPositionalAll(self.io, scratch[0..take], offset);
                if (n != take) return error.InvalidRecord;
                value_hasher.update(scratch[0..take]);
                entry_hasher.update(scratch[0..take]);
                consumed += take;
            }
            if (value_hasher.final() != value_hash) return error.InvalidRecord;
            digest.* ^= entry_hasher.final();
        }

        pub fn searchableNodeCanonicalBaseMetadataDigest(
            self: Store,
            overridden: ?*const std.AutoHashMap(PropertyPayloadOwnerKey, usize),
            deadline: core.QueryDeadline,
        ) !u64 {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            if (!has_index and !has_values) return 0;
            if (has_index != has_values) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_index_path, .{ .allow_directory = false });
            defer index_file.close(self.io);
            const header = try readPropertyPayloadIndexHeaderFromFile(self, index_file);
            if (header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, index_file) != try propertyPayloadIndexFileSize(header.record_count)) return error.InvalidRecord;
            try validatePropertyPayloadIndexOrderIfStrictDeadline(self, index_file, header, deadline);

            var values_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;
            const payload_start = try nodePropertyValueBlockHeaderAndRecordBytes(values_header.record_count);

            const searchable_hashes = [_]u64{
                nodePropertyKeyHash("name"),
                nodePropertyKeyHash("summary"),
            };
            if (searchable_hashes[0] == searchable_hashes[1]) return error.InvalidRecord;
            var digest: u64 = 0;
            for (searchable_hashes) |key_hash| {
                var previous: ?PropertyPayloadIndexRecord = null;
                var index = try propertyPayloadKeyHashLowerBound(self, index_file, header.record_count, key_hash);
                while (index < header.record_count) : (index += 1) {
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    const record = try readPropertyPayloadIndexRecordAt(self, index_file, index);
                    if (record.key_hash != key_hash) break;
                    if (previous) |prev| {
                        if (!propertyPayloadRecordLessThan({}, prev, record)) return error.InvalidRecord;
                    }
                    const value_record = try readNodePropertyValueRecordAt(self, values_file, index);
                    if (record.value_type == PropertyPayloadIndexRecord.value_type_uint) {
                        if (value_record.offset != 0 or value_record.len != 0) return error.InvalidRecord;
                    } else if (record.value_type == PropertyPayloadIndexRecord.value_type_string) {
                        if (value_record.len == 0) return error.InvalidRecord;
                        const payload_end = std.math.add(u64, value_record.offset, value_record.len) catch return error.InvalidRecord;
                        if (payload_end > values_header.payload_bytes) return error.InvalidRecord;
                        if (record.owner_kind == PropertyPayloadIndexRecord.owner_kind_node) {
                            const file_offset = std.math.add(u64, payload_start, value_record.offset) catch return error.InvalidRecord;
                            var ignored_digest: u64 = 0;
                            const digest_target = if (overridden) |positions|
                                if (positions.contains(.{
                                    .owner_kind = record.owner_kind,
                                    .owner_id = record.owner_id,
                                    .key_hash = record.key_hash,
                                })) &ignored_digest else &digest
                            else
                                &digest;
                            try addSearchableNodeMetadataDigestFromValueFile(
                                self,
                                digest_target,
                                0x544B_534D,
                                record.owner_id,
                                record.key_hash,
                                record.value_hash,
                                values_file,
                                file_offset,
                                value_record.len,
                                deadline,
                            );
                        }
                    } else {
                        return error.InvalidRecord;
                    }
                    previous = record;
                }
            }
            return digest;
        }

        pub fn searchableNodeLegacyMetadataDigest(self: Store, deadline: core.QueryDeadline) !u64 {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const has_index = try fileExists(self, self.node_props_overlay_index_path);
            const has_values = try fileExists(self, self.node_props_overlay_values_path);
            if (!has_index and !has_values) return 0;
            if (has_index != has_values) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_overlay_index_path, .{ .allow_directory = false });
            defer index_file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, index_file);
            if (header.node_count != 0 or header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, index_file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;

            var values_file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_overlay_values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;
            const payload_start = try nodePropertyValueBlockHeaderAndRecordBytes(values_header.record_count);

            const searchable_hashes = [_]u64{
                nodePropertyKeyHash("name"),
                nodePropertyKeyHash("summary"),
            };
            if (searchable_hashes[0] == searchable_hashes[1]) return error.InvalidRecord;
            var digest: u64 = 0;
            for (searchable_hashes) |key_hash| {
                var previous: ?NodePropertyIndexRecord = null;
                var index = try nodePropertyIndexLowerBound(self, index_file, header, key_hash, 0, 0);
                while (index < header.record_count) : (index += 1) {
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    const record = try readNodePropertyIndexRecordAt(self, index_file, index);
                    if (record.key_hash != key_hash) break;
                    if (previous) |prev| {
                        if (!nodePropertyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                    }
                    if (record.value_type == NodePropertyIndexRecord.value_type_uint) {
                        const value_record = try readNodePropertyValueRecordAt(self, values_file, index);
                        if (value_record.offset != 0 or value_record.len != 0) return error.InvalidRecord;
                    } else if (record.value_type == NodePropertyIndexRecord.value_type_string) {
                        const value_record = try readNodePropertyValueRecordAt(self, values_file, index);
                        if (value_record.len == 0) return error.InvalidRecord;
                        const payload_end = std.math.add(u64, value_record.offset, value_record.len) catch return error.InvalidRecord;
                        if (payload_end > values_header.payload_bytes) return error.InvalidRecord;
                        const file_offset = std.math.add(u64, payload_start, value_record.offset) catch return error.InvalidRecord;
                        // Domain-separate the legacy layer so an identical value
                        // present in both physical layers cannot XOR-cancel the
                        // whole metadata anchor to zero.
                        try addSearchableNodeMetadataDigestFromValueFile(
                            self,
                            &digest,
                            0x544B_534C,
                            record.node_id,
                            record.key_hash,
                            record.value_hash,
                            values_file,
                            file_offset,
                            value_record.len,
                            deadline,
                        );
                    } else {
                        return error.InvalidRecord;
                    }
                    previous = record;
                }
            }
            return digest;
        }

        pub fn searchableNodeMetadataDigest(self: Store, allocator: std.mem.Allocator) !u64 {
            return searchableNodeMetadataDigestInternal(self, allocator, null, .none);
        }

        pub fn searchableNodeMetadataDigestLimitedDeadline(
            self: Store,
            allocator: std.mem.Allocator,
            max_delta_scan_bytes: u64,
            deadline: core.QueryDeadline,
        ) !u64 {
            return searchableNodeMetadataDigestInternal(self, allocator, max_delta_scan_bytes, deadline);
        }

        pub fn searchableNodeMetadataDigestInternal(
            self: Store,
            allocator: std.mem.Allocator,
            max_delta_scan_bytes: ?u64,
            deadline: core.QueryDeadline,
        ) !u64 {
            // Hash immutable value ranges directly from disk instead of owning
            // every base name/summary merely to prove that a large text index is
            // current. An append-only delta still needs a latest-wins owner map,
            // but its working set is proportional only to the bounded delta, not
            // to the complete immutable base.
            if (!try pathExists(self, self.property_payload_delta_path)) {
                return (try searchableNodeCanonicalBaseMetadataDigest(self, null, deadline)) ^
                    (try searchableNodeLegacyMetadataDigest(self, deadline));
            }

            var entries = std.ArrayList(PropertyPayloadIndexEntry).empty;
            defer {
                deinitPropertyPayloadIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            var positions = std.AutoHashMap(PropertyPayloadOwnerKey, usize).init(allocator);
            defer positions.deinit();
            _ = try scanPropertyPayloadDeltaLimited(
                self,
                allocator,
                .{ .searchable = .{
                    .entries = &entries,
                    .positions = &positions,
                } },
                false,
                max_delta_scan_bytes,
                deadline,
            );

            var digest = try searchableNodeCanonicalBaseMetadataDigest(self, &positions, deadline);
            for (entries.items) |entry| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const record = entry.record;
                if (record.owner_kind != PropertyPayloadIndexRecord.owner_kind_node or
                    record.value_type != PropertyPayloadIndexRecord.value_type_string) return error.InvalidRecord;
                const value = entry.value orelse return error.InvalidRecord;
                addSearchableNodeMetadataDigest(&digest, 0x544B_534D, record.owner_id, record.key_hash, record.value_hash, value);
            }
            // Layer-domain separation avoids duplicate-value XOR cancellation.
            digest ^= try searchableNodeLegacyMetadataDigest(self, deadline);
            return digest;
        }

        pub fn writePropertyPayload(self: Store, entries: []PropertyPayloadIndexEntry) !void {
            try property_payload_transaction.publishBase(self, entries);
        }

        pub fn deinitPropertySnapshotList(entries: *std.ArrayList(PropertySnapshotEntry), allocator: std.mem.Allocator) void {
            for (entries.items) |entry| {
                if (entry.value_kind == .string) allocator.free(entry.string_value);
            }
            entries.deinit(allocator);
        }

        pub fn appendSearchableNodeOverlaySnapshot(
            self: Store,
            allocator: std.mem.Allocator,
            out: *std.ArrayList(PropertySnapshotEntry),
            effective_positions: *std.AutoHashMap(PropertyPayloadOwnerKey, usize),
            byte_budget: ?*SearchablePropertyByteBudget,
            deadline: core.QueryDeadline,
        ) !void {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const has_index = try fileExists(self, self.node_props_overlay_index_path);
            const has_values = try fileExists(self, self.node_props_overlay_values_path);
            if (!has_index and !has_values) return;
            if (has_index != has_values) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_overlay_index_path, .{ .allow_directory = false });
            defer index_file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, index_file);
            if (header.node_count != 0 or header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, index_file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;

            var values_file = try std.Io.Dir.cwd().openFile(self.io, self.node_props_overlay_values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

            const searchable_hashes = [_]u64{
                nodePropertyKeyHash("name"),
                nodePropertyKeyHash("summary"),
            };
            if (searchable_hashes[0] == searchable_hashes[1]) return error.InvalidRecord;
            for (searchable_hashes) |key_hash| {
                var previous: ?NodePropertyIndexRecord = null;
                var index = try nodePropertyIndexLowerBound(self, index_file, header, key_hash, 0, 0);
                while (index < header.record_count) : (index += 1) {
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    const record = try readNodePropertyIndexRecordAt(self, index_file, index);
                    if (record.key_hash != key_hash) break;
                    if (previous) |prev| {
                        if (!nodePropertyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                    }
                    const value_record = try readNodePropertyValueRecordAt(self, values_file, index);
                    if (record.value_type == NodePropertyIndexRecord.value_type_uint) {
                        if (value_record.offset != 0 or value_record.len != 0) return error.InvalidRecord;
                    } else if (record.value_type == NodePropertyIndexRecord.value_type_string) {
                        if (value_record.len == 0) return error.InvalidRecord;
                        const payload_end = std.math.add(u64, value_record.offset, value_record.len) catch return error.InvalidRecord;
                        if (payload_end > values_header.payload_bytes) return error.InvalidRecord;
                        // The append-friendly property payload is the canonical
                        // overlay.  Historical stores may still carry the same
                        // owner/key in node_props_overlay; point reads prefer the
                        // canonical value, so the full-text snapshot and its byte
                        // budget must do the same instead of materializing both.
                        const owner_key = PropertyPayloadOwnerKey{
                            .owner_kind = PropertyPayloadIndexRecord.owner_kind_node,
                            .owner_id = record.node_id,
                            .key_hash = record.key_hash,
                        };
                        if (effective_positions.contains(owner_key)) {
                            previous = record;
                            continue;
                        }
                        const next_budget_bytes = if (byte_budget) |budget|
                            try budget.afterReplace(0, @intCast(value_record.len))
                        else
                            0;
                        const value = (try readNodePropertyValuePayloadAt(self, allocator, values_file, values_header, index, record)) orelse return error.InvalidRecord;
                        errdefer allocator.free(value);
                        try out.append(allocator, .{
                            .owner = .{ .node = core.NodeId.fromInt(record.node_id) },
                            .key_hash = record.key_hash,
                            .value_kind = .string,
                            .string_len = @intCast(value.len),
                            .string_value = value,
                        });
                        try effective_positions.putNoClobber(owner_key, out.items.len - 1);
                        if (byte_budget) |budget| budget.used_bytes = next_budget_bytes;
                    } else {
                        return error.InvalidRecord;
                    }
                    previous = record;
                }
            }
        }

        pub fn appendSearchablePropertyPayloadSnapshot(
            self: Store,
            allocator: std.mem.Allocator,
            out: *std.ArrayList(PropertySnapshotEntry),
            byte_budget: ?*SearchablePropertyByteBudget,
            delta_scan_byte_budget: ?u64,
            deadline: core.QueryDeadline,
        ) !void {
            var entries = try readSearchablePropertyPayloadEntriesOrEmpty(self, allocator, byte_budget, delta_scan_byte_budget, deadline);
            defer {
                deinitPropertyPayloadIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            try out.ensureUnusedCapacity(allocator, entries.items.len);
            for (entries.items) |*entry| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const value = entry.value orelse return error.InvalidRecord;
                out.appendAssumeCapacity(.{
                    .owner = .{ .node = core.NodeId.fromInt(entry.record.owner_id) },
                    .key_hash = entry.record.key_hash,
                    .value_kind = .string,
                    .string_len = @intCast(value.len),
                    .string_value = value,
                });
                entry.value = null;
            }
        }

        pub fn loadSearchableNodeMetadataSnapshot(self: Store, allocator: std.mem.Allocator) !PropertySnapshot {
            return try loadSearchableNodeMetadataSnapshotInternal(self, allocator, null, null, .none);
        }

        pub fn loadSearchableNodeMetadataSnapshotLimited(
            self: Store,
            allocator: std.mem.Allocator,
            max_string_bytes: u64,
        ) !PropertySnapshot {
            var budget = SearchablePropertyByteBudget{ .max_bytes = max_string_bytes };
            return try loadSearchableNodeMetadataSnapshotInternal(self, allocator, &budget, null, .none);
        }

        pub fn loadSearchableNodeMetadataSnapshotWithLimitsDeadline(
            self: Store,
            allocator: std.mem.Allocator,
            max_string_bytes: u64,
            max_delta_scan_bytes: u64,
            deadline: core.QueryDeadline,
        ) !PropertySnapshot {
            var budget = SearchablePropertyByteBudget{ .max_bytes = max_string_bytes };
            return try loadSearchableNodeMetadataSnapshotInternal(self, allocator, &budget, max_delta_scan_bytes, deadline);
        }

        pub fn loadSearchableNodeMetadataSnapshotInternal(
            self: Store,
            allocator: std.mem.Allocator,
            byte_budget: ?*SearchablePropertyByteBudget,
            delta_scan_byte_budget: ?u64,
            deadline: core.QueryDeadline,
        ) !PropertySnapshot {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            var out = std.ArrayList(PropertySnapshotEntry).empty;
            errdefer deinitPropertySnapshotList(&out, allocator);
            // Load the canonical payload first.  Legacy node_props_overlay is a
            // fallback only; this ordering makes precedence explicit, avoids
            // duplicate live values, and keeps the hard byte budget aligned with
            // the effective metadata consumed by point reads and text indexing.
            try appendSearchablePropertyPayloadSnapshot(self, allocator, &out, byte_budget, delta_scan_byte_budget, deadline);
            const has_legacy_index = try fileExists(self, self.node_props_overlay_index_path);
            const has_legacy_values = try fileExists(self, self.node_props_overlay_values_path);
            if (has_legacy_index != has_legacy_values) return error.InvalidRecord;
            if (!has_legacy_index) return .{ .entries = try out.toOwnedSlice(allocator) };
            var canonical_positions = std.AutoHashMap(PropertyPayloadOwnerKey, usize).init(allocator);
            defer canonical_positions.deinit();
            try canonical_positions.ensureTotalCapacity(std.math.cast(u32, out.items.len) orelse return error.RecordTooLarge);
            for (out.items, 0..) |entry, index| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const node_id = switch (entry.owner) {
                    .node => |id| id,
                    .edge => return error.InvalidRecord,
                };
                const position = try canonical_positions.getOrPut(.{
                    .owner_kind = PropertyPayloadIndexRecord.owner_kind_node,
                    .owner_id = node_id.toInt(),
                    .key_hash = entry.key_hash,
                });
                if (position.found_existing) return error.InvalidRecord;
                position.value_ptr.* = index;
            }
            try appendSearchableNodeOverlaySnapshot(self, allocator, &out, &canonical_positions, byte_budget, deadline);
            return .{ .entries = try out.toOwnedSlice(allocator) };
        }

        pub fn loadNodePropertySnapshotForKeys(self: Store, allocator: std.mem.Allocator, keys: []const []const u8) !PropertySnapshot {
            return try loadPropertySnapshotForKeysFiltered(
                self,
                allocator,
                keys,
                PropertyPayloadIndexRecord.owner_kind_node,
                self.node_props_overlay_index_path,
                self.node_props_overlay_values_path,
                null,
            );
        }

        pub fn loadNodePropertySnapshotForNodeIds(
            self: Store,
            allocator: std.mem.Allocator,
            node_ids: []const core.NodeId,
            keys: []const []const u8,
        ) !PropertySnapshot {
            var wanted_node_ids = PropertyPayloadNodeIdSet.init(allocator);
            defer wanted_node_ids.deinit();
            try wanted_node_ids.ensureTotalCapacity(std.math.cast(u32, node_ids.len) orelse return error.RecordTooLarge);
            for (node_ids) |node_id| {
                if (node_id == .none or node_id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
                try wanted_node_ids.put(node_id.toInt(), {});
            }
            return try loadPropertySnapshotForKeysFiltered(
                self,
                allocator,
                keys,
                PropertyPayloadIndexRecord.owner_kind_node,
                self.node_props_overlay_index_path,
                self.node_props_overlay_values_path,
                &wanted_node_ids,
            );
        }

        pub fn loadEdgePropertySnapshotForEdgeIds(
            self: Store,
            allocator: std.mem.Allocator,
            edge_ids: []const core.EdgeId,
            keys: []const []const u8,
        ) !PropertySnapshot {
            var wanted_edge_ids = PropertyPayloadNodeIdSet.init(allocator);
            defer wanted_edge_ids.deinit();
            try wanted_edge_ids.ensureTotalCapacity(std.math.cast(u32, edge_ids.len) orelse return error.RecordTooLarge);
            for (edge_ids) |edge_id| {
                if (edge_id == .none or edge_id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
                try wanted_edge_ids.put(edge_id.toInt(), {});
            }
            return try loadPropertySnapshotForKeysFiltered(
                self,
                allocator,
                keys,
                PropertyPayloadIndexRecord.owner_kind_edge,
                self.edge_props_overlay_index_path,
                self.edge_props_overlay_values_path,
                &wanted_edge_ids,
            );
        }

        pub fn loadPropertySnapshotForKeysFiltered(
            self: Store,
            allocator: std.mem.Allocator,
            keys: []const []const u8,
            owner_kind: u8,
            legacy_index_path: []const u8,
            legacy_values_path: []const u8,
            wanted_owner_ids: ?*const PropertyPayloadNodeIdSet,
        ) !PropertySnapshot {
            if (owner_kind != PropertyPayloadIndexRecord.owner_kind_node and
                owner_kind != PropertyPayloadIndexRecord.owner_kind_edge) return error.InvalidRecord;
            const owner_filter = PropertyPayloadOwnerFilter{
                .owner_kind = owner_kind,
                .owner_ids = wanted_owner_ids,
            };
            var out = std.ArrayList(PropertySnapshotEntry).empty;
            errdefer deinitPropertySnapshotList(&out, allocator);
            var positions = std.AutoHashMap(PropertyPayloadOwnerKey, usize).init(allocator);
            defer positions.deinit();
            var key_hashes = PropertyPayloadKeyNameMap.init(allocator);
            defer key_hashes.deinit();

            for (keys) |key| {
                if (!propertyKeyNameValid(key) or
                    (owner_kind == PropertyPayloadIndexRecord.owner_kind_node and std.mem.eql(u8, key, "text"))) return error.InvalidRecord;
                const key_hash = nodePropertyKeyHash(key);
                const key_entry = try key_hashes.getOrPut(key_hash);
                if (key_entry.found_existing) return error.InvalidRecord;
                key_entry.value_ptr.* = key;

                var legacy = try readNodePropertyOverlayEntriesForKeyOwnersOrEmpty(
                    self,
                    allocator,
                    legacy_index_path,
                    legacy_values_path,
                    key,
                    wanted_owner_ids,
                );
                defer {
                    deinitNodePropertyIndexEntries(legacy.items, allocator);
                    legacy.deinit(allocator);
                }
                for (legacy.items) |*entry| {
                    const owner_key = PropertyPayloadOwnerKey{
                        .owner_kind = owner_kind,
                        .owner_id = entry.record.node_id,
                        .key_hash = entry.record.key_hash,
                    };
                    const position = try positions.getOrPut(owner_key);
                    if (position.found_existing) return error.InvalidRecord;
                    const value_kind: PropertySnapshotValueKind = switch (entry.record.value_type) {
                        NodePropertyIndexRecord.value_type_string => .string,
                        NodePropertyIndexRecord.value_type_uint => .uint,
                        else => return error.InvalidRecord,
                    };
                    try out.append(allocator, .{
                        .owner = try propertyPayloadOwnerFromParts(owner_kind, entry.record.node_id),
                        .key_hash = entry.record.key_hash,
                        .value_kind = value_kind,
                        .string_len = if (value_kind == .string) @intCast((entry.value orelse return error.InvalidRecord).len) else 0,
                        .string_value = if (value_kind == .string) entry.value.? else &.{},
                        .uint_value = if (value_kind == .uint) entry.record.value_hash else 0,
                    });
                    if (value_kind == .string) entry.value = null;
                    position.value_ptr.* = out.items.len - 1;
                }

                var payload = try readPropertyPayloadEntriesForKeyOwnersOrEmpty(self, allocator, key, owner_filter, false);
                defer {
                    deinitPropertyPayloadIndexEntries(payload.items, allocator);
                    payload.deinit(allocator);
                }
                for (payload.items) |*entry| {
                    if (entry.record.owner_kind != owner_kind) return error.InvalidRecord;
                    const owner_key = PropertyPayloadOwnerKey{
                        .owner_kind = entry.record.owner_kind,
                        .owner_id = entry.record.owner_id,
                        .key_hash = entry.record.key_hash,
                    };
                    const value_kind: PropertySnapshotValueKind = switch (entry.record.value_type) {
                        PropertyPayloadIndexRecord.value_type_string => .string,
                        PropertyPayloadIndexRecord.value_type_uint => .uint,
                        else => return error.InvalidRecord,
                    };
                    const replacement = PropertySnapshotEntry{
                        .owner = try propertyPayloadOwnerFromParts(owner_kind, entry.record.owner_id),
                        .key_hash = entry.record.key_hash,
                        .value_kind = value_kind,
                        .string_len = if (value_kind == .string) @intCast((entry.value orelse return error.InvalidRecord).len) else 0,
                        .string_value = if (value_kind == .string) entry.value.? else &.{},
                        .uint_value = if (value_kind == .uint) entry.record.value_hash else 0,
                    };
                    if (positions.get(owner_key)) |position| {
                        if (position >= out.items.len) return error.InvalidRecord;
                        if (out.items[position].value_kind == .string) allocator.free(out.items[position].string_value);
                        out.items[position] = replacement;
                    } else {
                        try out.ensureUnusedCapacity(allocator, 1);
                        const position = try positions.getOrPut(owner_key);
                        if (position.found_existing) return error.InvalidRecord;
                        position.value_ptr.* = out.items.len;
                        out.appendAssumeCapacity(replacement);
                    }
                    if (value_kind == .string) entry.value = null;
                }
            }
            // All requested lifecycle/metadata keys share one validated delta
            // pass.  This is the hot path for task-frontier and effective-status
            // queries; scanning once per key made latency grow as keys*history.
            _ = try scanPropertyPayloadDelta(self, allocator, .{ .snapshot = .{
                .key_names = &key_hashes,
                .entries = &out,
                .positions = &positions,
                .owner_filter = owner_filter,
            } }, false);
            return .{ .entries = try out.toOwnedSlice(allocator) };
        }

        pub fn scanLegacyPropertySnapshotLayer(
            self: Store,
            allocator: std.mem.Allocator,
            index_path: []const u8,
            values_path: []const u8,
            owner_kind: u8,
            context: *anyopaque,
            visit: PropertySnapshotLayerVisitor,
        ) !void {
            const has_index = try fileExists(self, index_path);
            const has_values = try fileExists(self, values_path);
            if (!has_index and !has_values) return;
            if (has_index != has_values) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().openFile(self.io, index_path, .{ .allow_directory = false });
            defer index_file.close(self.io);
            const header = try readNodePropertyIndexHeaderFromFile(self, index_file);
            if (header.node_count != 0 or header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, index_file) != try nodePropertyIndexFileSize(header.record_count)) return error.InvalidRecord;

            var values_file = try std.Io.Dir.cwd().openFile(self.io, values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

            var previous: ?NodePropertyIndexRecord = null;
            var index: u64 = 0;
            while (index < header.record_count) : (index += 1) {
                const record = try readNodePropertyIndexRecordAt(self, index_file, index);
                if (previous) |prev| {
                    if (!nodePropertyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                const value = try readNodePropertyValuePayloadAt(self, allocator, values_file, values_header, index, record);
                defer if (value) |owned| allocator.free(owned);
                const value_kind: PropertySnapshotValueKind = switch (record.value_type) {
                    NodePropertyIndexRecord.value_type_string => .string,
                    NodePropertyIndexRecord.value_type_uint => .uint,
                    else => return error.InvalidRecord,
                };
                try visit(context, .{
                    .owner = try propertyPayloadOwnerFromParts(owner_kind, record.node_id),
                    .key_hash = record.key_hash,
                    .version = property_snapshot_legacy_version,
                    .value_kind = value_kind,
                    .string_value = if (value_kind == .string) value orelse return error.InvalidRecord else &.{},
                    .uint_value = if (value_kind == .uint) record.value_hash else 0,
                });
                previous = record;
            }
        }

        pub fn scanCanonicalPropertySnapshotLayer(
            self: Store,
            allocator: std.mem.Allocator,
            context: *anyopaque,
            visit: PropertySnapshotLayerVisitor,
        ) !void {
            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            if (!has_index and !has_values) return;
            if (has_index != has_values) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_index_path, .{ .allow_directory = false });
            defer index_file.close(self.io);
            const header = try readPropertyPayloadIndexHeaderFromFile(self, index_file);
            if (header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, index_file) != try propertyPayloadIndexFileSize(header.record_count)) return error.InvalidRecord;

            var values_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_values_path, .{ .allow_directory = false });
            defer values_file.close(self.io);
            const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
            if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
            if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

            var previous: ?PropertyPayloadIndexRecord = null;
            var index: u64 = 0;
            while (index < header.record_count) : (index += 1) {
                const record = try readPropertyPayloadIndexRecordAt(self, index_file, index);
                if (previous) |prev| {
                    if (!propertyPayloadRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                const value = try readPropertyPayloadValuePayloadAt(self, allocator, values_file, values_header, index, record);
                defer if (value) |owned| allocator.free(owned);
                const value_kind: PropertySnapshotValueKind = switch (record.value_type) {
                    PropertyPayloadIndexRecord.value_type_string => .string,
                    PropertyPayloadIndexRecord.value_type_uint => .uint,
                    else => return error.InvalidRecord,
                };
                try visit(context, .{
                    .owner = try propertyPayloadOwnerFromParts(record.owner_kind, record.owner_id),
                    .key_hash = record.key_hash,
                    .version = property_snapshot_base_version,
                    .value_kind = value_kind,
                    .string_value = if (value_kind == .string) value orelse return error.InvalidRecord else &.{},
                    .uint_value = if (value_kind == .uint) record.value_hash else 0,
                });
                previous = record;
            }
        }

        pub fn scanPropertySnapshotLayers(
            self: Store,
            allocator: std.mem.Allocator,
            context: *anyopaque,
            visit: PropertySnapshotLayerVisitor,
        ) !void {
            try scanLegacyPropertySnapshotLayer(
                self,
                allocator,
                self.node_props_overlay_index_path,
                self.node_props_overlay_values_path,
                PropertyPayloadIndexRecord.owner_kind_node,
                context,
                visit,
            );
            try scanLegacyPropertySnapshotLayer(
                self,
                allocator,
                self.edge_props_overlay_index_path,
                self.edge_props_overlay_values_path,
                PropertyPayloadIndexRecord.owner_kind_edge,
                context,
                visit,
            );
            try scanCanonicalPropertySnapshotLayer(self, allocator, context, visit);
            var next_version = property_snapshot_delta_version_base;
            _ = try scanPropertyPayloadDelta(self, allocator, .{ .layer_scan = .{
                .context = context,
                .visit = visit,
                .next_version = &next_version,
            } }, false);
        }

        pub fn loadPropertySnapshot(self: Store, allocator: std.mem.Allocator) !PropertySnapshot {
            var out = std.ArrayList(PropertySnapshotEntry).empty;
            errdefer deinitPropertySnapshotList(&out, allocator);

            var node_overlay = try readNodePropertyOverlayEntriesOrEmpty(self, allocator);
            defer {
                deinitNodePropertyIndexEntries(node_overlay.items, allocator);
                node_overlay.deinit(allocator);
            }
            try out.ensureUnusedCapacity(allocator, node_overlay.items.len);
            for (node_overlay.items) |entry| {
                const string_value = if (entry.record.value_type == NodePropertyIndexRecord.value_type_string)
                    try allocator.dupe(u8, entry.value orelse return error.InvalidRecord)
                else
                    &.{};
                errdefer if (entry.record.value_type == NodePropertyIndexRecord.value_type_string) allocator.free(string_value);
                out.appendAssumeCapacity(.{
                    .owner = .{ .node = core.NodeId.fromInt(entry.record.node_id) },
                    .key_hash = entry.record.key_hash,
                    .value_kind = if (entry.record.value_type == NodePropertyIndexRecord.value_type_uint) .uint else .string,
                    .string_len = if (entry.record.value_type == NodePropertyIndexRecord.value_type_string)
                        @intCast(string_value.len)
                    else
                        0,
                    .string_value = string_value,
                    .uint_value = if (entry.record.value_type == NodePropertyIndexRecord.value_type_uint) entry.record.value_hash else 0,
                });
            }

            var edge_overlay = try readEdgePropertyOverlayEntriesOrEmpty(self, allocator);
            defer {
                deinitNodePropertyIndexEntries(edge_overlay.items, allocator);
                edge_overlay.deinit(allocator);
            }
            try out.ensureUnusedCapacity(allocator, edge_overlay.items.len);
            for (edge_overlay.items) |entry| {
                const string_value = if (entry.record.value_type == NodePropertyIndexRecord.value_type_string)
                    try allocator.dupe(u8, entry.value orelse return error.InvalidRecord)
                else
                    &.{};
                errdefer if (entry.record.value_type == NodePropertyIndexRecord.value_type_string) allocator.free(string_value);
                out.appendAssumeCapacity(.{
                    .owner = .{ .edge = core.EdgeId.fromInt(entry.record.node_id) },
                    .key_hash = entry.record.key_hash,
                    .value_kind = if (entry.record.value_type == NodePropertyIndexRecord.value_type_uint) .uint else .string,
                    .string_len = if (entry.record.value_type == NodePropertyIndexRecord.value_type_string)
                        @intCast(string_value.len)
                    else
                        0,
                    .string_value = string_value,
                    .uint_value = if (entry.record.value_type == NodePropertyIndexRecord.value_type_uint) entry.record.value_hash else 0,
                });
            }

            var payload = try readPropertyPayloadEntriesOrEmpty(self, allocator);
            defer {
                deinitPropertyPayloadIndexEntries(payload.items, allocator);
                payload.deinit(allocator);
            }
            try out.ensureUnusedCapacity(allocator, payload.items.len);
            for (payload.items) |entry| {
                const owner: PropertyOwner = switch (entry.record.owner_kind) {
                    PropertyPayloadIndexRecord.owner_kind_node => .{ .node = core.NodeId.fromInt(entry.record.owner_id) },
                    PropertyPayloadIndexRecord.owner_kind_edge => .{ .edge = core.EdgeId.fromInt(entry.record.owner_id) },
                    else => return error.InvalidRecord,
                };
                const string_value = if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_string)
                    try allocator.dupe(u8, entry.value orelse return error.InvalidRecord)
                else
                    &.{};
                errdefer if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_string) allocator.free(string_value);
                out.appendAssumeCapacity(.{
                    .owner = owner,
                    .key_hash = entry.record.key_hash,
                    .value_kind = if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_uint) .uint else .string,
                    .string_len = if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_string)
                        @intCast(string_value.len)
                    else
                        0,
                    .string_value = string_value,
                    .uint_value = if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_uint) entry.record.value_hash else 0,
                });
            }

            return .{ .entries = try out.toOwnedSlice(allocator) };
        }

        pub fn appendPropertiesBatch(self: Store, allocator: std.mem.Allocator, writes: []const PropertyPayloadWrite) !void {
            if (writes.len == 0) return;
            var entries = try readPropertyPayloadEntriesOrEmpty(self, allocator);
            defer {
                deinitPropertyPayloadIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }

            var seen = std.AutoHashMap(PropertyPayloadOwnerKey, void).init(allocator);
            defer seen.deinit();
            const expected_count = std.math.add(usize, entries.items.len, writes.len) catch return error.RecordTooLarge;
            try seen.ensureTotalCapacity(std.math.cast(u32, expected_count) orelse return error.RecordTooLarge);
            for (entries.items) |entry| {
                try seen.put(.{
                    .owner_kind = entry.record.owner_kind,
                    .owner_id = entry.record.owner_id,
                    .key_hash = entry.record.key_hash,
                }, {});
            }

            for (writes) |write| {
                const key = propertyPayloadOwnerKey(write.owner, write.key);
                const seen_entry = try seen.getOrPut(key);
                if (seen_entry.found_existing) return error.InvalidRecord;
                switch (write.value) {
                    .string => |value| {
                        if (!stringPropertyKeySupportedForOwner(write.owner, write.key) or value.len == 0) return error.InvalidRecord;
                        try appendStringPropertyPayloadRecord(&entries, allocator, write.owner, write.key, value);
                    },
                    .uint => |value| {
                        if (!uintPropertyKeySupportedForOwner(write.owner, write.key)) return error.InvalidRecord;
                        try appendUintPropertyPayloadRecord(&entries, allocator, write.owner, write.key, value);
                    },
                }
            }

            try writePropertyPayload(self, entries.items);
        }

        pub fn ensureEmptyPropertyPayloadReplacementTarget(self: Store) !void {
            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            if (has_index != has_values) return error.InvalidRecord;
            if (has_index) {
                var index_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_index_path, .{ .allow_directory = false });
                defer index_file.close(self.io);
                const header = try readPropertyPayloadIndexHeaderFromFile(self, index_file);
                if (header.record_count != 0 or header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, index_file) != try propertyPayloadIndexFileSize(0)) return error.InvalidRecord;
                var values_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_values_path, .{ .allow_directory = false });
                defer values_file.close(self.io);
                const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
                if (values_header.record_count != 0 or values_header.node_count != 0 or values_header.node_digest != 0 or
                    values_header.payload_bytes != 0 or values_header.payload_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(0, 0)) return error.InvalidRecord;
            }
            const delta_scan = try scanPropertyPayloadDelta(self, self.allocator, .none, false);
            if (delta_scan.valid_bytes != 0 or delta_scan.last_sequence != 0) return error.InvalidRecord;
            const RejectNonEmpty = struct {
                fn visit(_: *anyopaque, _: PropertySnapshotLayerEntry) anyerror!void {
                    return error.InvalidRecord;
                }
            };
            var empty_context: u8 = 0;
            try scanPropertySnapshotLayers(self, self.allocator, &empty_context, RejectNonEmpty.visit);
        }

        pub fn replaceEmptyPropertyPayloadFromSortedStream(
            self: Store,
            expected_count: u64,
            context: *anyopaque,
            next: SortedPropertyPayloadNext,
        ) !void {
            try ensureEmptyPropertyPayloadReplacementTarget(self);
            try property_payload_transaction.replaceEmptyBaseFromSortedStream(self, expected_count, context, next);
        }

        pub fn validatePropertyPayloadWrite(self: Store, allocator: std.mem.Allocator, write: PropertyPayloadWrite) !void {
            switch (write.value) {
                .string => |value| {
                    if (!stringPropertyKeySupportedForOwner(write.owner, write.key) or value.len == 0) return error.InvalidRecord;
                },
                .uint => {
                    if (!uintPropertyKeySupportedForOwner(write.owner, write.key)) return error.InvalidRecord;
                },
            }
            switch (write.owner) {
                .node => |node_id| {
                    var node = (try readNodeById(self, allocator, node_id)) orelse return core.Error.NotFound;
                    node.deinit(allocator);
                },
                .edge => |edge_id| if (!try visibleEdgeIdExists(self, edge_id)) return core.Error.InvalidId,
            }
        }

        pub fn countExistingPropertyPayloadKeys(
            self: Store,
            allocator: std.mem.Allocator,
            wanted: *const PropertyPayloadOwnerKeySet,
            delta_scan: *PropertyPayloadDeltaScan,
        ) !usize {
            var found = PropertyPayloadOwnerKeySet.init(allocator);
            defer found.deinit();
            try found.ensureTotalCapacity(@intCast(wanted.count()));

            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            if (has_index != has_values) return error.InvalidRecord;
            if (has_index) {
                var index_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_index_path, .{ .allow_directory = false });
                defer index_file.close(self.io);
                const header = try readPropertyPayloadIndexHeaderFromFile(self, index_file);
                if (header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, index_file) != try propertyPayloadIndexFileSize(header.record_count)) return error.InvalidRecord;
                try validatePropertyPayloadIndexOrderIfStrict(self, index_file, header);

                var values_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_values_path, .{ .allow_directory = false });
                defer values_file.close(self.io);
                const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
                if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

                var wanted_it = wanted.keyIterator();
                while (wanted_it.next()) |wanted_key| {
                    var index = try propertyPayloadKeyHashLowerBound(self, index_file, header.record_count, wanted_key.key_hash);
                    while (index < header.record_count) : (index += 1) {
                        const record = try readPropertyPayloadIndexRecordAt(self, index_file, index);
                        if (record.key_hash != wanted_key.key_hash) break;
                        if (record.owner_kind == wanted_key.owner_kind and record.owner_id == wanted_key.owner_id) {
                            try found.put(wanted_key.*, {});
                            break;
                        }
                    }
                }
            }

            delta_scan.* = try scanPropertyPayloadDelta(self, allocator, .{ .existing_keys = .{ .wanted = wanted, .found = &found } }, false);
            return found.count();
        }

        pub fn upsertPropertiesBatch(self: Store, allocator: std.mem.Allocator, writes: []const PropertyPayloadWrite) !PropertyPayloadUpsertResult {
            if (writes.len == 0) return .{};

            var write_keys = PropertyPayloadOwnerKeySet.init(allocator);
            defer write_keys.deinit();
            try write_keys.ensureTotalCapacity(std.math.cast(u32, writes.len) orelse return error.RecordTooLarge);
            for (writes) |write| {
                try validatePropertyPayloadWrite(self, allocator, write);
                const entry = try write_keys.getOrPut(propertyPayloadOwnerKey(write.owner, write.key));
                if (entry.found_existing) return error.InvalidRecord;
            }

            // The existing-key pass already validates and walks the complete
            // delta. Reuse its tail/sequence as the append precondition instead of
            // immediately rescanning an ever-growing journal a second time.
            // Raw Store callers still owe the documented external writer lock;
            // CLI lifecycle commands hold it across this whole operation.
            var delta_scan: PropertyPayloadDeltaScan = undefined;
            const replaced = try countExistingPropertyPayloadKeys(self, allocator, &write_keys, &delta_scan);
            try property_payload_transaction.publishDelta(self, allocator, writes, delta_scan);
            return .{
                .writes_applied = writes.len,
                .entries_replaced = replaced,
                .payload_publish_count = 1,
            };
        }

        pub fn compactPropertyPayloadDelta(self: Store, allocator: std.mem.Allocator) !PropertyPayloadCompactionResult {
            return property_payload_transaction.compactDelta(self, allocator);
        }

        pub fn readPropertyPayloadEntryForKey(
            self: Store,
            allocator: std.mem.Allocator,
            owner: PropertyOwner,
            key: []const u8,
        ) !?PropertyPayloadIndexEntry {
            var lookup = PropertyPayloadLookupTarget{
                .owner_key = propertyPayloadOwnerKey(owner, key),
                .key_name = key,
            };
            errdefer lookup.deinit(allocator);

            const has_index = try fileExists(self, self.property_payload_index_path);
            const has_values = try fileExists(self, self.property_payload_values_path);
            if (has_index != has_values) return error.InvalidRecord;
            if (has_index) {
                var index_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_index_path, .{ .allow_directory = false });
                defer index_file.close(self.io);
                const header = try readPropertyPayloadIndexHeaderFromFile(self, index_file);
                if (header.owner_count != 0 or header.owner_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, index_file) != try propertyPayloadIndexFileSize(header.record_count)) return error.InvalidRecord;
                try validatePropertyPayloadIndexOrderIfStrict(self, index_file, header);

                var values_file = try std.Io.Dir.cwd().openFile(self.io, self.property_payload_values_path, .{ .allow_directory = false });
                defer values_file.close(self.io);
                const values_header = try readNodePropertyValueBlockHeaderFromFile(self, values_file);
                if (values_header.record_count != header.record_count or values_header.node_count != 0 or values_header.node_digest != 0) return error.InvalidRecord;
                if (try regularFileSize(self, values_file) != try nodePropertyValueBlockFileSize(values_header.record_count, values_header.payload_bytes)) return error.InvalidRecord;

                var index = try propertyPayloadKeyHashLowerBound(self, index_file, header.record_count, lookup.owner_key.key_hash);
                while (index < header.record_count) : (index += 1) {
                    const record = try readPropertyPayloadIndexRecordAt(self, index_file, index);
                    if (record.key_hash != lookup.owner_key.key_hash) break;
                    if (record.owner_kind != lookup.owner_key.owner_kind or record.owner_id != lookup.owner_key.owner_id) continue;
                    if (lookup.value != null) return error.InvalidRecord;
                    const value = try readPropertyPayloadValuePayloadAt(self, allocator, values_file, values_header, index, record);
                    lookup.value = .{ .record = record, .value = value };
                }
            }

            _ = try scanPropertyPayloadDelta(self, allocator, .{ .lookup = &lookup }, false);
            const result = lookup.value;
            lookup.value = null;
            return result;
        }

        pub fn propertyPayloadStringValue(entries: []const PropertyPayloadIndexEntry, owner: PropertyOwner, key: []const u8) ?[]const u8 {
            for (entries) |entry| {
                if (!propertyPayloadEntryMatchesOwnerKey(entry, owner, key)) continue;
                if (entry.record.value_type != PropertyPayloadIndexRecord.value_type_string) continue;
                return entry.value;
            }
            return null;
        }

        pub fn propertyPayloadUintValue(entries: []const PropertyPayloadIndexEntry, owner: PropertyOwner, key: []const u8) ?u64 {
            for (entries) |entry| {
                if (!propertyPayloadEntryMatchesOwnerKey(entry, owner, key)) continue;
                if (entry.record.value_type != PropertyPayloadIndexRecord.value_type_uint) continue;
                if (entry.value != null) return null;
                return entry.record.value_hash;
            }
            return null;
        }

        pub fn setStringPropertyPayload(self: Store, allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8, value: []const u8) !void {
            _ = try upsertPropertiesBatch(self, allocator, &.{.{
                .owner = owner,
                .key = key,
                .value = .{ .string = value },
            }});
        }

        pub fn setUintPropertyPayload(self: Store, allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8, value: u64) !void {
            _ = try upsertPropertiesBatch(self, allocator, &.{.{
                .owner = owner,
                .key = key,
                .value = .{ .uint = value },
            }});
        }

        pub fn setNodeStringProperty(self: Store, allocator: std.mem.Allocator, node_id: core.NodeId, key: []const u8, value: []const u8) !void {
            if (!nodePropertyOverlayStringKeySupported(key)) return error.InvalidRecord;
            try setStringPropertyPayload(self, allocator, .{ .node = node_id }, key, value);
        }

        pub fn getNodeStringProperty(self: Store, allocator: std.mem.Allocator, node_id: core.NodeId, key: []const u8) !?[]u8 {
            if (!nodePropertyStringKeySupported(key)) return null;
            var node = (try readNodeById(self, allocator, node_id)) orelse return core.Error.NotFound;
            defer node.deinit(allocator);
            if (nodePropertyOverlayStringKeySupported(key)) {
                var payload_entry = try readPropertyPayloadEntryForKey(self, allocator, .{ .node = node_id }, key);
                defer if (payload_entry) |*entry| entry.deinit(allocator);
                if (payload_entry) |*entry| {
                    if (entry.record.value_type != PropertyPayloadIndexRecord.value_type_string) return error.InvalidRecord;
                    const value = entry.value orelse return error.InvalidRecord;
                    entry.value = null;
                    return value;
                }
                var entries = try readNodePropertyOverlayEntriesOrEmpty(self, allocator);
                defer {
                    deinitNodePropertyIndexEntries(entries.items, allocator);
                    entries.deinit(allocator);
                }
                if (nodePropertyOverlayStringValue(entries.items, node_id, key)) |value| return try allocator.dupe(u8, value);
            }
            return try nodePropertyValueFromTextAlloc(allocator, node.text, key);
        }

        pub fn edgePropertyOverlayEntryMatchesEdgeKey(entry: NodePropertyIndexEntry, edge_id: core.EdgeId, key: []const u8) bool {
            return entry.record.node_id == edge_id.toInt() and
                entry.record.key_hash == nodePropertyKeyHash(key) and
                entry.record.value_type == NodePropertyIndexRecord.value_type_string;
        }

        pub fn setEdgeStringProperty(self: Store, allocator: std.mem.Allocator, edge_id: core.EdgeId, key: []const u8, value: []const u8) !void {
            if (!edgePropertyOverlayStringKeySupported(key)) return error.InvalidRecord;
            try setStringPropertyPayload(self, allocator, .{ .edge = edge_id }, key, value);
        }

        pub fn getEdgeStringProperty(self: Store, allocator: std.mem.Allocator, edge_id: core.EdgeId, key: []const u8) !?[]u8 {
            if (!edgePropertyOverlayStringKeySupported(key)) return null;
            _ = try readVisibleEdgeIndexRecordById(self, edge_id);
            var payload_entry = try readPropertyPayloadEntryForKey(self, allocator, .{ .edge = edge_id }, key);
            defer if (payload_entry) |*entry| entry.deinit(allocator);
            if (payload_entry) |*entry| {
                if (entry.record.value_type != PropertyPayloadIndexRecord.value_type_string) return error.InvalidRecord;
                const value = entry.value orelse return error.InvalidRecord;
                entry.value = null;
                return value;
            }
            var entries = try readEdgePropertyOverlayEntriesOrEmpty(self, allocator);
            defer {
                deinitNodePropertyIndexEntries(entries.items, allocator);
                entries.deinit(allocator);
            }
            for (entries.items) |entry| {
                if (!edgePropertyOverlayEntryMatchesEdgeKey(entry, edge_id, key)) continue;
                const value = entry.value orelse return error.InvalidRecord;
                return try allocator.dupe(u8, value);
            }
            return null;
        }

        pub fn setUintProperty(self: Store, allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8, value: u64) !void {
            try setUintPropertyPayload(self, allocator, owner, key, value);
        }

        pub fn getUintProperty(self: Store, allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8) !?u64 {
            if (!uintPropertyKeySupportedForOwner(owner, key)) return null;
            switch (owner) {
                .node => |node_id| {
                    var node = (try readNodeById(self, allocator, node_id)) orelse return core.Error.NotFound;
                    node.deinit(allocator);
                },
                .edge => |edge_id| _ = try readVisibleEdgeIndexRecordById(self, edge_id),
            }
            var entry = try readPropertyPayloadEntryForKey(self, allocator, owner, key) orelse return null;
            defer entry.deinit(allocator);
            if (entry.record.value_type != PropertyPayloadIndexRecord.value_type_uint or entry.value != null) return error.InvalidRecord;
            return entry.record.value_hash;
        }

        pub fn setStringProperty(self: Store, allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8, value: []const u8) !void {
            switch (owner) {
                .node => |node_id| try setNodeStringProperty(self, allocator, node_id, key, value),
                .edge => |edge_id| try setEdgeStringProperty(self, allocator, edge_id, key, value),
            }
        }

        pub fn getStringProperty(self: Store, allocator: std.mem.Allocator, owner: PropertyOwner, key: []const u8) !?[]u8 {
            return switch (owner) {
                .node => |node_id| try getNodeStringProperty(self, allocator, node_id, key),
                .edge => |edge_id| try getEdgeStringProperty(self, allocator, edge_id, key),
            };
        }

        pub fn updateNodePropertyIndexForNodeAppend(self: Store, old_meta: IndexMeta, next_meta: IndexMeta, node: graph_mod.Node) !void {
            var new_entries = std.ArrayList(NodePropertyIndexEntry).empty;
            defer {
                deinitNodePropertyIndexEntries(new_entries.items, self.allocator);
                new_entries.deinit(self.allocator);
            }
            try appendNodePropertyRecordsFromText(&new_entries, self.allocator, node.id, node.text);
            if (new_entries.items.len == 0) return;
            var entries = try readNodePropertyIndexEntriesForMeta(self, self.allocator, old_meta);
            defer {
                deinitNodePropertyIndexEntries(entries.items, self.allocator);
                entries.deinit(self.allocator);
            }
            try entries.appendSlice(self.allocator, new_entries.items);
            new_entries.items.len = 0;
            try writeNodePropertyIndex(self, entries.items, next_meta);
        }

        pub fn updateNodePropertyIndexForNodeBatch(self: Store, old_meta: IndexMeta, next_meta: IndexMeta, nodes: []const graph_mod.Node) !void {
            var entries = try readNodePropertyIndexEntriesForMeta(self, self.allocator, old_meta);
            defer {
                deinitNodePropertyIndexEntries(entries.items, self.allocator);
                entries.deinit(self.allocator);
            }
            const before = entries.items.len;
            for (nodes) |node| try appendNodePropertyRecordsFromText(&entries, self.allocator, node.id, node.text);
            if (entries.items.len != before) try writeNodePropertyIndex(self, entries.items, next_meta);
        }

        pub fn lookupEdgeByExternalKey(self: Store, allocator: std.mem.Allocator, external_key: []const u8) !?core.EdgeId {
            const indexed = lookupEdgeByExternalKeyFromCurrentIndex(self, allocator, external_key) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => blk: {
                    try rebuildEdgeExternalKeyIndex(self);
                    break :blk try lookupEdgeByExternalKeyFromCurrentIndex(self, allocator, external_key);
                },
                else => |e| return e,
            };
            if (indexed) |edge_id| return edge_id;
            return try scanEdgeByExternalKey(self, allocator, external_key);
        }

        pub fn buildEdgeExternalKeyLookupCache(self: Store, allocator: std.mem.Allocator) !EdgeExternalKeyLookupCache {
            var node_keys = try nodeExternalKeyMap(self, allocator);
            errdefer {
                var iterator = node_keys.iterator();
                while (iterator.next()) |entry| allocator.free(entry.value_ptr.*);
                node_keys.deinit();
            }
            var order_map = try edgeOrderMap(self, allocator);
            errdefer order_map.deinit();
            return .{
                .allocator = allocator,
                .node_keys = node_keys,
                .order_map = order_map,
            };
        }

        pub fn lookupEdgeByExternalKeyCached(self: Store, allocator: std.mem.Allocator, external_key: []const u8, cache: *EdgeExternalKeyLookupCache) !?core.EdgeId {
            if (try lookupEdgeRecordByExternalKeyCached(self, allocator, external_key, cache)) |record| return .fromInt(record.edge_id);
            return null;
        }

        pub fn lookupEdgeRecordByExternalKeyCached(self: Store, allocator: std.mem.Allocator, external_key: []const u8, cache: *EdgeExternalKeyLookupCache) !?EdgeIndexRecord {
            const indexed = lookupEdgeByExternalKeyFromCurrentIndexCached(self, allocator, external_key, cache) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => blk: {
                    try rebuildEdgeExternalKeyIndex(self);
                    break :blk try lookupEdgeByExternalKeyFromCurrentIndexCached(self, allocator, external_key, cache);
                },
                else => |e| return e,
            };
            if (indexed) |edge| return edge;
            return try scanEdgeRecordByExternalKeyCached(self, allocator, external_key, cache);
        }

        pub fn lookupFactEdgeByNodeExternalKeys(self: Store, allocator: std.mem.Allocator, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !?core.EdgeId {
            const external_key = try factEdgeExternalKeyForNodesAlloc(self, allocator, src, rel, dst);
            defer if (external_key) |key| allocator.free(key);
            if (external_key) |key| {
                if (try lookupEdgeByExternalKey(self, allocator, key)) |edge_id| return edge_id;
            } else {
                return null;
            }
            var records = try readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(self, allocator, src);
            defer records.deinit(allocator);
            for (records.items) |record| {
                if (record.rel == @intFromEnum(rel) and record.dst == dst.toInt()) return .fromInt(record.edge_id);
            }
            return null;
        }

        pub fn refreshFactEdgeExternalKeyIndexAfterAppend(self: Store, edge: graph_mod.Edge) !void {
            const current_meta = try readCurrentIndexMeta(self);
            const record = EdgeIndexRecord{
                .src = edge.src.toInt(),
                .dst = edge.dst.toInt(),
                .edge_id = edge.id.toInt(),
                .rel = @intFromEnum(edge.rel),
            };
            const edge_digest = edgeRecordDigest(record);
            if (current_meta.edge_indexed_edges == 0) return error.InvalidRecord;
            if (current_meta.edges == 0) return error.InvalidRecord;
            var previous_meta = current_meta;
            previous_meta.edges -= 1;
            previous_meta.edge_digest ^= edge_digest;
            previous_meta.edge_indexed_edges -= 1;
            previous_meta.edge_index_digest ^= edge_digest;
            var records = try readEdgeExternalKeyIndexRecordsForMeta(self, self.allocator, previous_meta);
            defer records.deinit(self.allocator);
            var node_keys = try nodeExternalKeyMap(self, self.allocator);
            defer {
                var iterator = node_keys.iterator();
                while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
                node_keys.deinit();
            }
            const before = records.items.len;
            try appendFactEdgeExternalKeyRecordForEdge(self, &records, node_keys, record);
            if (records.items.len == before) return;
            try writeEdgeExternalKeyIndex(self, records.items, current_meta);
        }

        pub fn lookupEdgeByExternalKeyFromCurrentIndex(self: Store, allocator: std.mem.Allocator, external_key: []const u8) !?core.EdgeId {
            if (external_key.len == 0) return null;
            const meta = try readCurrentIndexMeta(self);
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_external_key_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readEdgeExternalKeyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest or
                header.edge_count != meta.edge_indexed_edges or header.edge_digest != meta.edge_index_digest)
            {
                return error.InvalidRecord;
            }
            if (try regularFileSize(self, file) != try edgeExternalKeyIndexFileSize(header.record_count)) return error.InvalidRecord;

            const key_hash = edgeExternalKeyHash(external_key);
            const first = try edgeExternalKeyIndexLowerBound(self, file, header, key_hash);
            var index: u64 = first;
            while (index < header.record_count) : (index += 1) {
                const record = try readEdgeExternalKeyIndexRecordAt(self, file, index);
                if (record.hash != key_hash) break;
                if (try edgeMatchesExternalKey(self, allocator, record.edge_id, external_key)) return .fromInt(record.edge_id);
            }
            return null;
        }

        pub fn lookupEdgeByExternalKeyFromCurrentIndexCached(self: Store, allocator: std.mem.Allocator, external_key: []const u8, cache: *EdgeExternalKeyLookupCache) !?EdgeIndexRecord {
            if (external_key.len == 0) return null;
            const meta = try readCurrentIndexMeta(self);
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_external_key_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readEdgeExternalKeyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest or
                header.edge_count != meta.edge_indexed_edges or header.edge_digest != meta.edge_index_digest)
            {
                return error.InvalidRecord;
            }
            if (try regularFileSize(self, file) != try edgeExternalKeyIndexFileSize(header.record_count)) return error.InvalidRecord;

            const key_hash = edgeExternalKeyHash(external_key);
            const first = try edgeExternalKeyIndexLowerBound(self, file, header, key_hash);
            var index: u64 = first;
            while (index < header.record_count) : (index += 1) {
                const record = try readEdgeExternalKeyIndexRecordAt(self, file, index);
                if (record.hash != key_hash) break;
                if (try edgeRecordMatchesExternalKeyCached(self, allocator, record.edge_id, external_key, cache)) |edge| return edge;
            }
            return null;
        }

        pub fn scanEdgeByExternalKey(self: Store, allocator: std.mem.Allocator, external_key: []const u8) !?core.EdgeId {
            var cache = try buildEdgeExternalKeyLookupCache(self, allocator);
            defer cache.deinit();
            if (try scanEdgeRecordByExternalKeyCached(self, allocator, external_key, &cache)) |edge| return .fromInt(edge.edge_id);
            return null;
        }

        pub fn scanEdgeRecordByExternalKeyCached(self: Store, allocator: std.mem.Allocator, external_key: []const u8, cache: *EdgeExternalKeyLookupCache) !?EdgeIndexRecord {
            if (external_key.len == 0) return null;
            const ScanContext = struct {
                store: Store,
                allocator: std.mem.Allocator,
                external_key: []const u8,
                cache: *EdgeExternalKeyLookupCache,
                found: ?EdgeIndexRecord = null,

                fn visit(raw_context: *anyopaque, edge: EdgeIndexRecord) anyerror!void {
                    const context: *@This() = @ptrCast(@alignCast(raw_context));
                    // Keep consuming the stream after a match. The terminal
                    // count/digest check is part of the storage integrity
                    // contract, not an optional cost of an unsuccessful lookup.
                    if (context.found != null) return;
                    context.found = try edgeRecordMatchesExternalKeyCachedRecord(
                        context.store,
                        context.allocator,
                        edge,
                        context.external_key,
                        context.cache,
                    );
                }
            };
            var context = ScanContext{
                .store = self,
                .allocator = allocator,
                .external_key = external_key,
                .cache = cache,
            };
            _ = try scanVisibleEdgeIndexRecords(self, allocator, &context, ScanContext.visit);
            return context.found;
        }

        pub fn factEdgeExternalKeyForNodesAlloc(self: Store, allocator: std.mem.Allocator, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !?[]u8 {
            var src_node = (try readNodeById(self, allocator, src)) orelse return null;
            defer src_node.deinit(allocator);
            var dst_node = (try readNodeById(self, allocator, dst)) orelse return null;
            defer dst_node.deinit(allocator);
            const src_key = try getNodeStringProperty(self, allocator, src, "external_key");
            defer if (src_key) |key| allocator.free(key);
            const dst_key = try getNodeStringProperty(self, allocator, dst, "external_key");
            defer if (dst_key) |key| allocator.free(key);
            if (src_key == null or dst_key == null) return null;
            return try edgeFactExternalKeyAlloc(allocator, src_key.?, rel, dst_key.?);
        }

        pub fn edgeMatchesExternalKey(self: Store, allocator: std.mem.Allocator, edge_id: u64, external_key: []const u8) !bool {
            const edge = readVisibleEdgeIndexRecordById(self, .fromInt(edge_id)) catch |err| switch (err) {
                core.Error.InvalidId => return false,
                else => |e| return e,
            };
            var order_map = try edgeOrderMap(self, allocator);
            defer order_map.deinit();
            var node_keys = try nodeExternalKeyMap(self, allocator);
            defer {
                var iterator = node_keys.iterator();
                while (iterator.next()) |entry| allocator.free(entry.value_ptr.*);
                node_keys.deinit();
            }
            const src_key = node_keys.get(edge.src) orelse return false;
            const rel: core.RelKind = @enumFromInt(edge.rel);
            if (order_map.get(edge.edge_id)) |order_key| {
                const key = try orderedEdgeExternalKeyAlloc(allocator, src_key, rel, order_key);
                defer allocator.free(key);
                return std.mem.eql(u8, key, external_key);
            }
            const dst_key = node_keys.get(edge.dst) orelse return false;
            const key = try edgeFactExternalKeyAlloc(allocator, src_key, rel, dst_key);
            defer allocator.free(key);
            return std.mem.eql(u8, key, external_key);
        }

        pub fn edgeMatchesExternalKeyCached(self: Store, allocator: std.mem.Allocator, edge_id: u64, external_key: []const u8, cache: *EdgeExternalKeyLookupCache) !bool {
            return (try edgeRecordMatchesExternalKeyCached(self, allocator, edge_id, external_key, cache)) != null;
        }

        pub fn edgeRecordMatchesExternalKeyCached(self: Store, allocator: std.mem.Allocator, edge_id: u64, external_key: []const u8, cache: *EdgeExternalKeyLookupCache) !?EdgeIndexRecord {
            const edge = readVisibleEdgeIndexRecordById(self, .fromInt(edge_id)) catch |err| switch (err) {
                core.Error.InvalidId => return null,
                else => |e| return e,
            };
            return try edgeRecordMatchesExternalKeyCachedRecord(self, allocator, edge, external_key, cache);
        }

        pub fn edgeRecordMatchesExternalKeyCachedRecord(self: Store, allocator: std.mem.Allocator, edge: EdgeIndexRecord, external_key: []const u8, cache: *EdgeExternalKeyLookupCache) !?EdgeIndexRecord {
            _ = self;
            const src_key = cache.node_keys.get(edge.src) orelse return null;
            const rel: core.RelKind = @enumFromInt(edge.rel);
            if (cache.order_map.get(edge.edge_id)) |order_key| {
                const key = try orderedEdgeExternalKeyAlloc(allocator, src_key, rel, order_key);
                defer allocator.free(key);
                if (std.mem.eql(u8, key, external_key)) return edge;
                return null;
            }
            const dst_key = cache.node_keys.get(edge.dst) orelse return null;
            const key = try edgeFactExternalKeyAlloc(allocator, src_key, rel, dst_key);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, external_key)) return edge;
            return null;
        }

        pub fn rebuildEdgeExternalKeyIndex(self: Store) !void {
            const meta = try readCurrentIndexMeta(self);
            var records = std.ArrayList(EdgeExternalKeyIndexRecord).empty;
            defer records.deinit(self.allocator);
            var node_keys = try nodeExternalKeyMap(self, self.allocator);
            defer {
                var iterator = node_keys.iterator();
                while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
                node_keys.deinit();
            }
            var order_map = try edgeOrderMap(self, self.allocator);
            defer order_map.deinit();
            const RebuildContext = struct {
                store: Store,
                records: *std.ArrayList(EdgeExternalKeyIndexRecord),
                node_keys: std.AutoHashMap(u64, []u8),
                order_map: std.AutoHashMap(u64, u64),

                fn visit(raw_context: *anyopaque, edge: EdgeIndexRecord) anyerror!void {
                    const context: *@This() = @ptrCast(@alignCast(raw_context));
                    try appendEdgeExternalKeyRecordsForEdge(context.store, context.records, context.node_keys, context.order_map, edge);
                }
            };
            var context = RebuildContext{
                .store = self,
                .records = &records,
                .node_keys = node_keys,
                .order_map = order_map,
            };
            _ = try scanVisibleEdgeIndexRecords(self, self.allocator, &context, RebuildContext.visit);
            try writeEdgeExternalKeyIndex(self, records.items, meta);
        }

        pub fn nodeExternalKeyMap(self: Store, allocator: std.mem.Allocator) !std.AutoHashMap(u64, []u8) {
            var out = std.AutoHashMap(u64, []u8).init(allocator);
            errdefer {
                var iterator = out.iterator();
                while (iterator.next()) |entry| allocator.free(entry.value_ptr.*);
                out.deinit();
            }
            var payload_entries = try readPropertyPayloadEntriesOrEmpty(self, allocator);
            defer {
                deinitPropertyPayloadIndexEntries(payload_entries.items, allocator);
                payload_entries.deinit(allocator);
            }
            var iterator = try nodeRecordsIterator(self, null);
            defer iterator.deinit();
            while (try iterator.next(allocator)) |node| {
                defer {
                    var mutable = node;
                    mutable.deinit(allocator);
                }
                if (propertyPayloadStringValue(payload_entries.items, .{ .node = node.id }, "external_key")) |external_key| {
                    const owned_key = try allocator.dupe(u8, external_key);
                    errdefer allocator.free(owned_key);
                    try out.put(node.id.toInt(), owned_key);
                }
            }
            return out;
        }

        pub fn edgeOrderMap(self: Store, allocator: std.mem.Allocator) !std.AutoHashMap(u64, u64) {
            var out = std.AutoHashMap(u64, u64).init(allocator);
            errdefer out.deinit();
            var order_records = readAllEdgeOrderRecords(self, allocator) catch |err| switch (err) {
                error.FileNotFound => return out,
                else => |e| return e,
            };
            defer order_records.deinit(allocator);
            for (order_records.items) |record| try out.put(record.edge_id, record.order_key);
            return out;
        }

        pub fn appendEdgeExternalKeyRecordsForEdge(
            self: Store,
            records: *std.ArrayList(EdgeExternalKeyIndexRecord),
            node_keys: std.AutoHashMap(u64, []u8),
            order_map: std.AutoHashMap(u64, u64),
            edge: EdgeIndexRecord,
        ) !void {
            const src_key = node_keys.get(edge.src) orelse return;
            const rel: core.RelKind = @enumFromInt(edge.rel);
            if (order_map.get(edge.edge_id)) |order_key| {
                const key = try orderedEdgeExternalKeyAlloc(self.allocator, src_key, rel, order_key);
                defer self.allocator.free(key);
                try records.append(self.allocator, .{
                    .hash = edgeExternalKeyHash(key),
                    .edge_id = edge.edge_id,
                });
                return;
            }
            const dst_key = node_keys.get(edge.dst) orelse return;
            const key = try edgeFactExternalKeyAlloc(self.allocator, src_key, rel, dst_key);
            defer self.allocator.free(key);
            try records.append(self.allocator, .{
                .hash = edgeExternalKeyHash(key),
                .edge_id = edge.edge_id,
            });
        }

        pub fn appendFactEdgeExternalKeyRecordForEdge(
            self: Store,
            records: *std.ArrayList(EdgeExternalKeyIndexRecord),
            node_keys: std.AutoHashMap(u64, []u8),
            edge: EdgeIndexRecord,
        ) !void {
            const src_key = node_keys.get(edge.src) orelse return;
            const dst_key = node_keys.get(edge.dst) orelse return;
            const rel: core.RelKind = @enumFromInt(edge.rel);
            const key = try edgeFactExternalKeyAlloc(self.allocator, src_key, rel, dst_key);
            defer self.allocator.free(key);
            try records.append(self.allocator, .{
                .hash = edgeExternalKeyHash(key),
                .edge_id = edge.edge_id,
            });
        }

        pub fn readEdgeExternalKeyIndexHeaderFromFile(self: Store, file: std.Io.File) !EdgeExternalKeyIndexHeader {
            var bytes: [EdgeExternalKeyIndexHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return EdgeExternalKeyIndexHeader.decode(&bytes);
        }

        pub fn readEdgeExternalKeyIndexRecordAt(self: Store, file: std.Io.File, index: u64) !EdgeExternalKeyIndexRecord {
            var bytes: [EdgeExternalKeyIndexRecord.encoded_len]u8 = undefined;
            const offset = try edgeExternalKeyIndexRecordOffset(index);
            const n = try file.readPositionalAll(self.io, &bytes, offset);
            if (n != bytes.len) return error.InvalidRecord;
            return EdgeExternalKeyIndexRecord.decode(&bytes);
        }

        pub fn edgeExternalKeyIndexLowerBound(self: Store, file: std.Io.File, header: EdgeExternalKeyIndexHeader, key_hash: u64) !u64 {
            var lo: u64 = 0;
            var hi: u64 = header.record_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const record = try readEdgeExternalKeyIndexRecordAt(self, file, mid);
                if (record.hash < key_hash) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn writeEdgeExternalKeyIndex(self: Store, records: []EdgeExternalKeyIndexRecord, meta: IndexMeta) !void {
            std.mem.sort(EdgeExternalKeyIndexRecord, records, {}, edgeExternalKeyIndexRecordLessThan);
            const tmp_path = try tmpPathFor(self, self.edge_external_key_index_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(try edgeExternalKeyIndexFileSize(@intCast(records.len))));
                defer writer.deinit();
                const header = EdgeExternalKeyIndexHeader{
                    .record_count = @intCast(records.len),
                    .node_count = meta.nodes,
                    .node_digest = meta.node_digest,
                    .edge_count = meta.edge_indexed_edges,
                    .edge_digest = meta.edge_index_digest,
                };
                var header_bytes: [EdgeExternalKeyIndexHeader.encoded_len]u8 = undefined;
                header.encode(&header_bytes);
                try writer.append(&header_bytes);
                var previous: ?EdgeExternalKeyIndexRecord = null;
                for (records) |record| {
                    if (previous) |prev| {
                        if (!edgeExternalKeyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                    }
                    var record_bytes: [EdgeExternalKeyIndexRecord.encoded_len]u8 = undefined;
                    try record.encode(&record_bytes);
                    try writer.append(&record_bytes);
                    previous = record;
                }
                try writer.flush();
                if (try regularFileSize(self, file) != try edgeExternalKeyIndexFileSize(@intCast(records.len))) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.edge_external_key_index_path);
        }

        pub fn readEdgeExternalKeyIndexRecordsForMeta(self: Store, allocator: std.mem.Allocator, meta: IndexMeta) !std.ArrayList(EdgeExternalKeyIndexRecord) {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_external_key_index_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readEdgeExternalKeyIndexHeaderFromFile(self, file);
            if (header.node_count != meta.nodes or header.node_digest != meta.node_digest or
                header.edge_count != meta.edge_indexed_edges or header.edge_digest != meta.edge_index_digest)
            {
                return error.InvalidRecord;
            }
            if (try regularFileSize(self, file) != try edgeExternalKeyIndexFileSize(header.record_count)) return error.InvalidRecord;
            var records = std.ArrayList(EdgeExternalKeyIndexRecord).empty;
            errdefer records.deinit(allocator);
            try records.ensureTotalCapacity(allocator, std.math.cast(usize, header.record_count) orelse return error.RecordTooLarge);
            var previous: ?EdgeExternalKeyIndexRecord = null;
            var index: u64 = 0;
            while (index < header.record_count) : (index += 1) {
                const record = try readEdgeExternalKeyIndexRecordAt(self, file, index);
                if (previous) |prev| {
                    if (!edgeExternalKeyIndexRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                records.appendAssumeCapacity(record);
                previous = record;
            }
            return records;
        }

        pub fn nodeExistsById(self: Store, node_id: core.NodeId) !bool {
            if (isReservedNodeId(node_id)) return core.Error.InvalidId;
            var view = try openNodeByIdIndexView(self);
            defer view.deinit();
            return try view.nodeExists(node_id);
        }

        pub fn openNodeByIdIndexView(self: Store) !NodeByIdIndexView {
            const meta = try readCurrentIndexMeta(self);
            if (self.options.validate_indexes_on_read and !try nodeIndexValid(self, meta.nodes)) return error.InvalidRecord;
            return try NodeByIdIndexView.open(self, meta);
        }

        pub fn openNodeRecordView(self: Store) !NodeRecordView {
            const meta = try readCurrentIndexMeta(self);
            if (self.options.validate_indexes_on_read and !try nodeIndexValid(self, meta.nodes)) return error.InvalidRecord;
            return try NodeRecordView.open(self, meta);
        }

        pub fn nodeRecordsIterator(self: Store, kind_filter: ?core.NodeKind) !NodeRecordIterator {
            return .{
                .view = try openNodeRecordView(self),
                .kind_filter = kind_filter,
            };
        }

        pub fn lookupNodesByText(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8) !std.ArrayList(StoredNode) {
            const max_nodes = (core.QueryBudget{}).max_visited_nodes;
            var view = try openNodeTextLookupView(self, allocator);
            defer view.deinit();
            var ids = try view.lookupIdsInto(allocator, kind_filter, text, try boundedSentinelCap(max_nodes), .empty);
            defer ids.deinit(allocator);
            if (ids.items.len > max_nodes) return core.Error.BudgetExceeded;
            return try materializeTextLookupIdsWithViews(self, allocator, view.meta, kind_filter, text, ids.items, &view.node_view, &view.texts_view);
        }

        pub fn lookupNodesByTextLimited(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_nodes: usize) !std.ArrayList(StoredNode) {
            if (max_nodes == 0) return .empty;
            if (max_nodes == 1) {
                var lookup = try lookupFirstIdByTextLazy(self, allocator, kind_filter, text, null);
                defer lookup.deinit();
                const id = lookup.id orelse return .empty;
                var single = [_]core.NodeId{id};
                return try materializeTextLookupIdsWithViews(self, allocator, lookup.meta, kind_filter, text, single[0..], &lookup.node_view, &lookup.texts_view);
            }
            var view = try openNodeTextLookupView(self, allocator);
            defer view.deinit();
            var ids = try view.lookupIdsInto(allocator, kind_filter, text, max_nodes, .empty);
            defer ids.deinit(allocator);
            return try materializeTextLookupIdsWithViews(self, allocator, view.meta, kind_filter, text, ids.items, &view.node_view, &view.texts_view);
        }

        pub fn lookupNodesByTextLimitedWithTimings(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_nodes: usize, timings: *NodeTextLookupTimings) !std.ArrayList(StoredNode) {
            if (max_nodes == 0) return .empty;
            if (max_nodes == 1) {
                var lookup = try lookupFirstIdByTextLazy(self, allocator, kind_filter, text, timings);
                defer lookup.deinit();
                const id = lookup.id orelse return .empty;
                var single = [_]core.NodeId{id};
                const materialize_start = monotonicNs(self);
                const nodes = try materializeTextLookupIdsWithViews(self, allocator, lookup.meta, kind_filter, text, single[0..], &lookup.node_view, &lookup.texts_view);
                timings.materialize_ns += elapsedNs(self, materialize_start);
                return nodes;
            }
            var view = try openNodeTextLookupView(self, allocator);
            defer view.deinit();
            var ids = try view.lookupIdsIntoWithTimings(allocator, kind_filter, text, max_nodes, .empty, timings);
            defer ids.deinit(allocator);
            const materialize_start = monotonicNs(self);
            const nodes = try materializeTextLookupIdsWithViews(self, allocator, view.meta, kind_filter, text, ids.items, &view.node_view, &view.texts_view);
            timings.materialize_ns += elapsedNs(self, materialize_start);
            return nodes;
        }

        pub fn materializeTextLookupIdsWithViews(
            self: Store,
            allocator: std.mem.Allocator,
            meta: IndexMeta,
            kind_filter: ?core.NodeKind,
            text: []const u8,
            ids: []const core.NodeId,
            node_view: *?NodeByIdIndexView,
            texts_view: *?NodeTextsView,
        ) !std.ArrayList(StoredNode) {
            _ = texts_view;
            var out = std.ArrayList(StoredNode).empty;
            errdefer {
                for (out.items) |*node| node.deinit(allocator);
                out.deinit(allocator);
            }
            try out.ensureTotalCapacity(allocator, ids.len);
            if (ids.len == 0) return out;
            const nodes = try ensureNodeByIdIndexView(self, meta, node_view);
            for (ids) |id| {
                const record = (try nodes.readOptionalRecord(id.toInt())) orelse return error.InvalidRecord;
                if (record.id != id.toInt()) return error.InvalidRecord;
                const kind = try record.nodeKind();
                if (kind_filter) |filter| {
                    if (kind != filter) return error.InvalidRecord;
                }
                const owned_text = try allocator.dupe(u8, text);
                errdefer allocator.free(owned_text);
                try out.append(allocator, .{
                    .id = id,
                    .kind = kind,
                    .text = owned_text,
                });
            }
            return out;
        }

        pub fn lookupNodeIdsByTextLimited(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_nodes: usize) !std.ArrayList(core.NodeId) {
            return try lookupNodeIdsByTextLimitedWithMaybeTimings(self, allocator, kind_filter, text, max_nodes, null);
        }

        pub fn lookupNodeIdsByTextLimitedWithTimings(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_nodes: usize, timings: *NodeTextLookupTimings) !std.ArrayList(core.NodeId) {
            return try lookupNodeIdsByTextLimitedWithMaybeTimings(self, allocator, kind_filter, text, max_nodes, timings);
        }

        pub fn lookupFirstNodeIdByText(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8) !?core.NodeId {
            var lookup = try lookupFirstIdByTextLazy(self, allocator, kind_filter, text, null);
            defer lookup.deinit();
            return lookup.id;
        }

        pub fn lookupFirstNodeIdByTextWithTimings(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, timings: *NodeTextLookupTimings) !?core.NodeId {
            var lookup = try lookupFirstIdByTextLazy(self, allocator, kind_filter, text, timings);
            const id = lookup.id;
            const cleanup_start = monotonicNs(self);
            lookup.deinit();
            timings.cleanup_ns += elapsedNs(self, cleanup_start);
            return id;
        }

        pub fn lookupNodeIdsByTextLimitedWithMaybeTimings(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_nodes: usize, timings: ?*NodeTextLookupTimings) !std.ArrayList(core.NodeId) {
            var out = std.ArrayList(core.NodeId).empty;
            if (max_nodes == 0) return out;

            if (max_nodes == 1) {
                var lookup = try lookupFirstIdByTextLazy(self, allocator, kind_filter, text, timings);
                defer lookup.deinit();
                if (lookup.id) |id| {
                    try out.append(allocator, id);
                }
                return out;
            }
            var view = try openNodeTextLookupView(self, allocator);
            defer view.deinit();
            return try view.lookupIdsIntoWithTimings(allocator, kind_filter, text, max_nodes, out, timings);
        }

        pub fn lookupFirstIdByTextLazy(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, timings: ?*NodeTextLookupTimings) !LazyFirstNodeTextLookup {
            return node_text_lookup_view_data_plane.lookupFirstLazy(
                StorageNodeTextLookupContext.init(self),
                allocator,
                kind_filter,
                text,
                timings,
            );
        }

        pub fn lookupFirstIdByTextLazyAfterBaseMiss(self: Store, kind_filter: ?core.NodeKind, text: []const u8, hash: u64, meta: IndexMeta, base_header: NodeTextIndexHeader, timings: ?*NodeTextLookupTimings) !LazyFirstNodeTextLookup {
            return node_text_lookup_view_data_plane.lookupFirstLazyAfterBaseMiss(
                StorageNodeTextLookupContext.init(self),
                kind_filter,
                text,
                hash,
                meta,
                base_header,
                timings,
            );
        }

        pub fn openNodeTextLookupView(self: Store, allocator: std.mem.Allocator) !NodeTextLookupView {
            return openNodeTextLookupViewMaybeRetained(self, allocator, null, null);
        }

        pub fn openNodeTextLookupViewWithTimings(self: Store, allocator: std.mem.Allocator, timings: *NodeTextLookupOpenTimings) !NodeTextLookupView {
            return openNodeTextLookupViewMaybeRetained(self, allocator, null, timings);
        }

        pub fn openNodeTextLookupViewRetained(self: Store, allocator: std.mem.Allocator, registry: *NodeTextRunRetentionRegistry) !NodeTextLookupView {
            return openNodeTextLookupViewMaybeRetained(self, allocator, registry, null);
        }

        pub fn openNodeTextLookupViewMaybeRetained(self: Store, allocator: std.mem.Allocator, retention_registry: ?*NodeTextRunRetentionRegistry, timings: ?*NodeTextLookupOpenTimings) !NodeTextLookupView {
            return node_text_lookup_view_data_plane.openView(
                StorageNodeTextLookupContext.init(self),
                allocator,
                retention_registry,
                timings,
            );
        }

        pub fn cachedNodeTextDeltaRun(self: Store, expected_header: NodeTextIndexHeader) !?NodeTextLookupRun {
            return node_text_lookup_view_data_plane.cachedDeltaRun(
                StorageNodeTextLookupContext.init(self),
                expected_header,
                self.node_text_delta_run_cache,
            );
        }

        pub fn refreshNodeTextDeltaRunCache(self: Store, expected_header: NodeTextIndexHeader) void {
            node_text_lookup_view_data_plane.refreshDeltaRunCache(
                StorageNodeTextLookupContext.init(self),
                expected_header,
                self.node_text_delta_run_cache,
            );
        }

        pub fn monotonicNs(self: Store) u128 {
            const timestamp = std.Io.Clock.awake.now(self.io).nanoseconds;
            return if (timestamp < 0) 0 else @intCast(timestamp);
        }

        pub fn elapsedNs(self: Store, start: u128) u128 {
            const now = monotonicNs(self);
            return if (now >= start) now - start else 0;
        }

        pub fn collectNodeTextLookupRun(
            self: Store,
            allocator: std.mem.Allocator,
            run: NodeTextLookupRun,
            meta: IndexMeta,
            hash: u64,
            kind_filter: ?core.NodeKind,
            text: []const u8,
            max_collect: usize,
            out: *std.ArrayList(core.NodeId),
            node_view: *?NodeByIdIndexView,
            texts_view: *?NodeTextsView,
            timings: ?*NodeTextLookupTimings,
        ) !void {
            return node_text_lookup_view_data_plane.collectRun(
                StorageNodeTextLookupContext.init(self),
                allocator,
                run,
                meta,
                hash,
                kind_filter,
                text,
                max_collect,
                out,
                node_view,
                texts_view,
                timings,
            );
        }

        pub fn collectFirstNodeTextLookupRun(
            self: Store,
            run: NodeTextLookupRun,
            meta: IndexMeta,
            hash: u64,
            kind_filter: ?core.NodeKind,
            text: []const u8,
            best: *?core.NodeId,
            node_view: *?NodeByIdIndexView,
            texts_view: *?NodeTextsView,
            timings: ?*NodeTextLookupTimings,
        ) !void {
            return node_text_lookup_view_data_plane.collectFirstRun(
                StorageNodeTextLookupContext.init(self),
                run,
                meta,
                hash,
                kind_filter,
                text,
                best,
                node_view,
                texts_view,
                timings,
            );
        }

        pub fn findNodeTextHashLowerBound(
            self: Store,
            file: std.Io.File,
            map: ?*const std.Io.File.MemoryMap,
            header: NodeTextIndexHeader,
            hash: u64,
            texts_view: ?*const NodeTextsView,
            node_view: ?*const NodeByIdIndexView,
            timings: ?*NodeTextLookupTimings,
        ) !u64 {
            return node_text_lookup_view_data_plane.findHashLowerBound(
                StorageNodeTextLookupContext.init(self),
                .{
                    .file = file,
                    .map = map,
                    .header = header,
                },
                hash,
                texts_view,
                node_view,
                timings,
            );
        }

        pub fn boundedSentinelCap(max_nodes: usize) !usize {
            return std.math.add(usize, max_nodes, 1) catch return core.Error.BudgetExceeded;
        }

        pub fn scanNodeIds(self: Store, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, max_ids: usize) !std.ArrayList(core.NodeId) {
            var out = std.ArrayList(core.NodeId).empty;
            errdefer out.deinit(allocator);
            if (max_ids == 0) return out;

            var iter = try nodeIdsIterator(self, kind_filter);
            defer iter.deinit();
            while (out.items.len < max_ids) {
                const node_id = (try iter.next()) orelse break;
                try out.append(allocator, node_id);
            }
            return out;
        }

        pub fn ensureNodeByIdIndexView(self: Store, meta: IndexMeta, view: *?NodeByIdIndexView) !*NodeByIdIndexView {
            if (view.* == null) view.* = try NodeByIdIndexView.open(self, meta);
            return &view.*.?;
        }

        pub fn ensureNodeTextsView(self: Store, view: *?NodeTextsView) !*NodeTextsView {
            if (view.* == null) view.* = try NodeTextsView.open(self);
            return &view.*.?;
        }

        pub fn nodeIdsIterator(self: Store, kind_filter: ?core.NodeKind) !NodeIdIterator {
            var index_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{});
            errdefer index_file.close(self.io);
            const meta = try readCurrentIndexMeta(self);
            const header = try readNodeByIdHeaderFromFile(self, index_file);
            if (header.node_count != meta.nodes) return error.InvalidRecord;
            if (header.node_digest != meta.node_digest) return error.InvalidRecord;
            const expected_size = try nodeByIdFileSizeForHeaderStore(self, header);
            if (try regularFileSize(self, index_file) != expected_size) return error.InvalidRecord;
            if (self.options.validate_indexes_on_read and !try nodeIndexValid(self, meta.nodes)) return error.InvalidRecord;

            var map = openReadOnlyMemoryMap(self.io, index_file, expected_size) catch null;
            errdefer if (map) |*mapped| mapped.destroy(self.io);

            return .{
                .store = self,
                .file = index_file,
                .map = map,
                .kind_filter = kind_filter,
                .header = header,
                .next_id = 1,
                .max_node_id = header.max_node_id,
                .expected_nodes = header.node_count,
            };
        }

        pub fn readNodeByIdHeaderFromFile(self: Store, file: std.Io.File) !NodeByIdHeader {
            var bytes: [NodeByIdHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return NodeByIdHeader.decode(&bytes);
        }

        pub fn readNodeByIdRecordAt(self: Store, file: std.Io.File, header: NodeByIdHeader, node_id: u64) !NodeByIdRecord {
            if (node_id == 0) return error.InvalidRecord;
            try header.validateShape();
            if (header.hasDerivedTextOffset()) {
                if (node_id > header.max_node_id) return error.InvalidRecord;
                const text_len = try readDerivedNodeByIdTextLenAt(self, file, header, node_id);
                const text_offset = try deriveNodeByIdTextOffsetFromFile(self, file, header, node_id);
                return .{
                    .id = node_id,
                    .kind = header.uniform_kind,
                    .text_offset = text_offset,
                    .text_len = text_len,
                };
            }
            var bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
            const record_bytes = bytes[0..header.record_len];
            const offset = try nodeByIdRecordOffsetForHeader(header, node_id);
            const n = try file.readPositionalAll(self.io, record_bytes, offset);
            if (n != record_bytes.len) return error.InvalidRecord;
            return NodeByIdRecord.decodeSliceAtForHeader(header, node_id, record_bytes);
        }

        pub fn readNodeByIdRecordFromMap(header: NodeByIdHeader, map: *const std.Io.File.MemoryMap, node_id: u64) !NodeByIdRecord {
            if (node_id == 0) return error.InvalidRecord;
            try header.validateShape();
            if (header.hasDerivedTextOffset()) {
                if (node_id > header.max_node_id) return error.InvalidRecord;
                const text_len = try readDerivedNodeByIdTextLenFromMap(header, map, node_id);
                const text_offset = try deriveNodeByIdTextOffsetFromMap(header, map, node_id);
                return .{
                    .id = node_id,
                    .kind = header.uniform_kind,
                    .text_offset = text_offset,
                    .text_len = text_len,
                };
            }
            const offset = try nodeByIdRecordOffsetForHeader(header, node_id);
            const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
            const end = std.math.add(usize, start, header.record_len) catch return error.InvalidRecord;
            if (end > map.memory.len) return error.InvalidRecord;
            return NodeByIdRecord.decodeSliceAtForHeader(header, node_id, map.memory[start..end]);
        }

        pub fn readDerivedNodeByIdTextLenAt(self: Store, file: std.Io.File, header: NodeByIdHeader, node_id: u64) !u32 {
            var len_bytes: [2]u8 = undefined;
            const offset = try nodeByIdRecordOffsetForHeader(header, node_id);
            if (try file.readPositionalAll(self.io, &len_bytes, offset) != len_bytes.len) return error.InvalidRecord;
            return readU16(&len_bytes);
        }

        pub fn deriveNodeByIdTextOffsetFromFile(self: Store, file: std.Io.File, header: NodeByIdHeader, node_id: u64) !u64 {
            const block = try nodeByIdTextOffsetCheckpointBlock(node_id);
            var checkpoint_bytes: [8]u8 = undefined;
            const checkpoint_offset = try nodeByIdTextOffsetCheckpointOffset(header, block);
            if (try file.readPositionalAll(self.io, &checkpoint_bytes, checkpoint_offset) != checkpoint_bytes.len) return error.InvalidRecord;
            var text_offset = readU64(&checkpoint_bytes);
            var id = block * node_by_id_text_offset_checkpoint_stride + 1;
            while (id < node_id) : (id += 1) {
                text_offset = std.math.add(u64, text_offset, try readDerivedNodeByIdTextLenAt(self, file, header, id)) catch return error.InvalidRecord;
            }
            return text_offset;
        }

        pub fn readNodeRecordById(self: Store, node_id: u64) !NodeByIdRecord {
            var index_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{});
            defer index_file.close(self.io);
            const header = try readNodeByIdHeaderFromFile(self, index_file);
            const expected_size = try nodeByIdFileSizeForHeaderStore(self, header);
            if (try regularFileSize(self, index_file) != expected_size) return error.InvalidRecord;
            if (node_id == 0 or node_id > header.max_node_id) return error.InvalidRecord;
            const record = try readNodeByIdRecordAt(self, index_file, header, node_id);
            if (record.id != node_id) return error.InvalidRecord;
            return record;
        }

        pub fn readNodeTextIndexHeaderFromFile(self: Store, file: std.Io.File) !NodeTextIndexHeader {
            var bytes: [NodeTextIndexHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return NodeTextIndexHeader.decode(&bytes);
        }

        pub fn readNodeTextIndexRecordAt(self: Store, file: std.Io.File, index: u64) !NodeTextIndexRecord {
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            return readNodeTextIndexRecordAtForHeader(self, file, header, index);
        }

        pub fn readNodeTextIndexRecordAtForHeader(self: Store, file: std.Io.File, header: NodeTextIndexHeader, index: u64) !NodeTextIndexRecord {
            return readNodeTextIndexRecordAtForHeaderWithTextsAndNodes(self, file, header, index, null, null);
        }

        pub fn readNodeTextIndexRecordAtForHeaderWithTexts(
            self: Store,
            file: std.Io.File,
            header: NodeTextIndexHeader,
            index: u64,
            texts_view: ?*const NodeTextsView,
        ) !NodeTextIndexRecord {
            return readNodeTextIndexRecordAtForHeaderWithTextsAndNodes(self, file, header, index, texts_view, null);
        }

        pub fn readNodeTextIndexRecordAtForHeaderWithTextsAndNodes(
            self: Store,
            file: std.Io.File,
            header: NodeTextIndexHeader,
            index: u64,
            texts_view: ?*const NodeTextsView,
            node_view: ?*const NodeByIdIndexView,
        ) !NodeTextIndexRecord {
            try header.validateShape();
            var bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
            const record_bytes = bytes[0..header.record_len];
            const offset = try nodeTextIndexRecordOffsetForHeader(header, index);
            const n = try file.readPositionalAll(self.io, record_bytes, offset);
            if (n != record_bytes.len) return error.InvalidRecord;
            const record = try NodeTextIndexRecord.decodeSliceForHeader(header, record_bytes);
            return finishNodeTextIndexRecordDecode(self, header, record, texts_view, node_view);
        }

        pub fn readNodeTextIndexRecordHashAtForHeader(
            self: Store,
            file: std.Io.File,
            header: NodeTextIndexHeader,
            index: u64,
            texts_view: ?*const NodeTextsView,
            node_view: ?*const NodeByIdIndexView,
        ) !u64 {
            try header.validateShape();
            var bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
            const record_bytes = bytes[0..header.record_len];
            const offset = try nodeTextIndexRecordOffsetForHeader(header, index);
            const n = try file.readPositionalAll(self.io, record_bytes, offset);
            if (n != record_bytes.len) return error.InvalidRecord;
            const record = try NodeTextIndexRecord.decodeSliceForHeader(header, record_bytes);
            if (!header.hasDerivedHash() and !self.options.validate_indexes_on_read) return record.hash;
            return (try finishNodeTextIndexRecordDecode(self, header, record, texts_view, node_view)).hash;
        }

        pub fn readNodeTextIndexRecordAtForValidation(
            self: Store,
            file: std.Io.File,
            header: NodeTextIndexHeader,
            index: u64,
            node_view: ?*const NodeByIdIndexView,
        ) !NodeTextIndexRecord {
            try header.validateShape();
            if (index >= header.node_count) return error.InvalidRecord;
            var bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
            const record_bytes = bytes[0..header.record_len];
            const offset = try nodeTextIndexRecordOffsetForHeader(header, index);
            const n = try file.readPositionalAll(self.io, record_bytes, offset);
            if (n != record_bytes.len) return error.InvalidRecord;
            var record = try NodeTextIndexRecord.decodeSliceForHeader(header, record_bytes);
            if (header.hasDerivedTextSpan()) {
                const by_id = if (node_view) |nodes|
                    try nodes.readRecord(record.id)
                else
                    try readNodeRecordById(self, record.id);
                if (by_id.id != record.id) return error.InvalidRecord;
                if (by_id.kind != record.kind) return error.InvalidRecord;
                record.text_offset = by_id.text_offset;
                record.text_len = by_id.text_len;
            }
            return record;
        }

        pub fn finishNodeTextIndexRecordDecode(
            self: Store,
            header: NodeTextIndexHeader,
            decoded_record: NodeTextIndexRecord,
            texts_view: ?*const NodeTextsView,
            node_view: ?*const NodeByIdIndexView,
        ) !NodeTextIndexRecord {
            var record = decoded_record;
            if (header.hasDerivedTextSpan()) {
                const by_id = if (node_view) |nodes|
                    try nodes.readRecord(record.id)
                else
                    try readNodeRecordById(self, record.id);
                if (by_id.id != record.id) return error.InvalidRecord;
                if (by_id.kind != record.kind) return error.InvalidRecord;
                record.text_offset = by_id.text_offset;
                record.text_len = by_id.text_len;
            }
            if (!header.hasDerivedHash()) return record;
            if (texts_view) |texts| {
                record.hash = try texts.hashStoredText(record.text_offset, record.text_len);
                return record;
            }
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            record.hash = try texts.hashStoredText(record.text_offset, record.text_len);
            return record;
        }

        pub fn readNodeTextIndexRecordHashFromMapForHeader(
            self: Store,
            header: NodeTextIndexHeader,
            map: *const std.Io.File.MemoryMap,
            index: u64,
            texts_view: ?*const NodeTextsView,
            node_view: ?*const NodeByIdIndexView,
        ) !u64 {
            try header.validateShape();
            const offset = try nodeTextIndexRecordOffsetForHeader(header, index);
            const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
            const end = std.math.add(usize, start, header.record_len) catch return error.InvalidRecord;
            if (end > map.memory.len) return error.InvalidRecord;
            const record = try NodeTextIndexRecord.decodeSliceForHeader(header, map.memory[start..end]);
            if (!header.hasDerivedHash() and !self.options.validate_indexes_on_read) return record.hash;
            return (try finishNodeTextIndexRecordDecode(self, header, record, texts_view, node_view)).hash;
        }

        pub fn readNodeTextIndexRecordFromMap(map: *const std.Io.File.MemoryMap, index: u64) !NodeTextIndexRecord {
            if (map.memory.len < NodeTextIndexHeader.encoded_len) return error.InvalidRecord;
            const header_bytes: *const [NodeTextIndexHeader.encoded_len]u8 = map.memory[0..NodeTextIndexHeader.encoded_len];
            const header = try NodeTextIndexHeader.decode(header_bytes);
            return readNodeTextIndexRecordFromMapForHeader(header, map, index);
        }

        pub fn readNodeTextIndexRecordFromMapForHeader(header: NodeTextIndexHeader, map: *const std.Io.File.MemoryMap, index: u64) !NodeTextIndexRecord {
            return readNodeTextIndexRecordFromMapForHeaderWithTextsAndNodes(header, map, index, null, null);
        }

        pub fn readNodeTextIndexRecordFromMapForHeaderWithTexts(
            header: NodeTextIndexHeader,
            map: *const std.Io.File.MemoryMap,
            index: u64,
            texts_view: ?*const NodeTextsView,
        ) !NodeTextIndexRecord {
            return readNodeTextIndexRecordFromMapForHeaderWithTextsAndNodes(header, map, index, texts_view, null);
        }

        pub fn readNodeTextIndexRecordFromMapForHeaderWithTextsAndNodes(
            header: NodeTextIndexHeader,
            map: *const std.Io.File.MemoryMap,
            index: u64,
            texts_view: ?*const NodeTextsView,
            node_view: ?*const NodeByIdIndexView,
        ) !NodeTextIndexRecord {
            try header.validateShape();
            const offset = try nodeTextIndexRecordOffsetForHeader(header, index);
            const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
            const end = std.math.add(usize, start, header.record_len) catch return error.InvalidRecord;
            if (end > map.memory.len) return error.InvalidRecord;
            var record = try NodeTextIndexRecord.decodeSliceForHeader(header, map.memory[start..end]);
            if (header.hasDerivedTextSpan()) {
                const nodes = node_view orelse return error.InvalidRecord;
                const by_id = try nodes.readRecord(record.id);
                if (by_id.id != record.id) return error.InvalidRecord;
                if (by_id.kind != record.kind) return error.InvalidRecord;
                record.text_offset = by_id.text_offset;
                record.text_len = by_id.text_len;
            }
            if (header.hasDerivedHash()) {
                const texts = texts_view orelse return error.InvalidRecord;
                record.hash = try texts.hashStoredText(record.text_offset, record.text_len);
            }
            return record;
        }

        pub fn readNodeTextRunManifest(self: Store, allocator: std.mem.Allocator) !NodeTextRunManifest {
            if (try readNodeTextRunCurrentPath(self, allocator)) |manifest_path| {
                defer allocator.free(manifest_path);
                return readNodeTextRunManifestFile(self, allocator, manifest_path) catch |err| switch (err) {
                    error.FileNotFound => error.InvalidRecord,
                    else => |e| e,
                };
            }
            return NodeTextRunManifest{};
        }

        pub fn cachedNodeTextRunManifestForMeta(self: Store, meta: IndexMeta) !?*const NodeTextRunManifest {
            if (!self.options.validate_indexes_on_read and
                self.node_text_run_manifest_cache.valid and
                self.node_text_run_manifest_cache.event_bytes == meta.event_bytes)
            {
                return &self.node_text_run_manifest_cache.manifest;
            }
            return cachedNodeTextRunManifestWithEventBytes(self, meta.event_bytes);
        }

        pub fn cachedNodeTextRunManifest(self: Store) !?*const NodeTextRunManifest {
            return cachedNodeTextRunManifestWithEventBytes(self, null);
        }

        pub fn cachedNodeTextRunManifestWithEventBytes(self: Store, event_bytes: ?u64) !?*const NodeTextRunManifest {
            const manifest_path = (try readNodeTextRunCurrentPath(self, self.allocator)) orelse {
                self.node_text_run_manifest_cache.clear(self.allocator);
                return null;
            };
            defer self.allocator.free(manifest_path);

            if (self.node_text_run_manifest_cache.valid and std.mem.eql(u8, self.node_text_run_manifest_cache.path, manifest_path)) {
                if (event_bytes) |bytes| self.node_text_run_manifest_cache.event_bytes = bytes;
                return &self.node_text_run_manifest_cache.manifest;
            }

            try replaceNodeTextRunManifestCache(self, manifest_path);
            if (event_bytes) |bytes| self.node_text_run_manifest_cache.event_bytes = bytes;
            return &self.node_text_run_manifest_cache.manifest;
        }

        pub fn replaceNodeTextRunManifestCache(self: Store, manifest_path: []const u8) !void {
            self.node_text_run_manifest_cache.clear(self.allocator);
            self.node_text_run_manifest_cache.path = try self.allocator.dupe(u8, manifest_path);
            errdefer self.node_text_run_manifest_cache.clear(self.allocator);
            self.node_text_run_manifest_cache.manifest = readNodeTextRunManifestFile(self, self.allocator, manifest_path) catch |err| switch (err) {
                error.FileNotFound => return error.InvalidRecord,
                else => |e| return e,
            };
            self.node_text_run_manifest_cache.valid = true;
        }

        pub fn warmNodeTextRunManifestCache(self: Store, manifest_path: []const u8) void {
            replaceNodeTextRunManifestCache(self, manifest_path) catch {
                invalidateNodeTextRunManifestCache(self);
            };
        }

        pub fn invalidateNodeTextRunManifestCache(self: Store) void {
            self.node_text_run_manifest_cache.clear(self.allocator);
        }

        pub fn nodeTextHeaderMatchesBaseFilter(expected: NodeTextIndexHeader, actual: NodeTextIndexHeader) bool {
            return expected.node_count == actual.node_count and
                expected.node_digest == actual.node_digest and
                expected.order_digest == actual.order_digest and
                expected.flags == actual.flags and
                expected.record_len == actual.record_len and
                expected.uniform_kind == actual.uniform_kind;
        }

        pub fn cachedNodeTextBaseHashFilter(self: Store, expected_header: ?NodeTextIndexHeader) !?*const NodeTextBaseHashFilter {
            if (self.node_text_base_filter_cache.valid) {
                if (expected_header == null or nodeTextHeaderMatchesBaseFilter(expected_header.?, self.node_text_base_filter_cache.filter.header)) {
                    return &self.node_text_base_filter_cache.filter;
                }
                self.node_text_base_filter_cache.clear(self.allocator);
            }
            if (self.node_text_base_filter_cache.known_absent) return null;
            var loaded = (try readCurrentNodeTextBaseHashFilter(self, expected_header)) orelse {
                self.node_text_base_filter_cache.known_absent = true;
                return null;
            };
            errdefer loaded.deinit(self.allocator);
            self.node_text_base_filter_cache.clear(self.allocator);
            self.node_text_base_filter_cache.filter = loaded;
            self.node_text_base_filter_cache.valid = true;
            loaded = .{ .header = .{ .node_count = 0 } };
            return &self.node_text_base_filter_cache.filter;
        }

        pub fn nodeTextBaseFilterMatchesCurrentBase(self: Store, filter_header: NodeTextIndexHeader) !bool {
            var file = std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{ .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer file.close(self.io);
            const current_header = try readNodeTextIndexHeaderFromFile(self, file);
            if (!nodeTextHeaderMatchesBaseFilter(filter_header, current_header)) return false;
            if (try regularFileSize(self, file) != try nodeTextIndexFileSizeForHeader(current_header)) return error.InvalidRecord;
            return true;
        }

        pub fn readCurrentNodeTextBaseHashFilter(self: Store, expected_header: ?NodeTextIndexHeader) !?NodeTextBaseHashFilter {
            var file = std.Io.Dir.cwd().openFile(self.io, self.node_by_text_base_filter_path, .{ .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (file_size < NodeTextBaseHashFilterHeader.encoded_len) return null;
            var header_bytes: [NodeTextBaseHashFilterHeader.encoded_len]u8 = undefined;
            const header_n = try file.readPositionalAll(self.io, &header_bytes, 0);
            if (header_n != header_bytes.len) return null;
            const sidecar_header = NodeTextBaseHashFilterHeader.decode(&header_bytes) catch return null;
            if (expected_header) |expected| {
                if (!nodeTextHeaderMatchesBaseFilter(expected, sidecar_header.node_text_header)) return null;
            }
            const expected_size = std.math.add(u64, NodeTextBaseHashFilterHeader.encoded_len, sidecar_header.filter_len) catch return null;
            if (file_size != expected_size) return null;
            const filter_len = std.math.cast(usize, sidecar_header.filter_len) orelse return null;
            const filter = try self.allocator.alloc(u8, filter_len);
            errdefer self.allocator.free(filter);
            const filter_n = try file.readPositionalAll(self.io, filter, NodeTextBaseHashFilterHeader.encoded_len);
            if (filter_n != filter.len) {
                self.allocator.free(filter);
                return null;
            }
            if (nodeTextHashFilterDigest(filter) != sidecar_header.filter_digest) {
                self.allocator.free(filter);
                return null;
            }
            return NodeTextBaseHashFilter{
                .header = sidecar_header.node_text_header,
                .filter = filter,
            };
        }

        pub fn ensureNodeTextBaseHashFilter(self: Store, expected_header: NodeTextIndexHeader) !void {
            const filter_len = nodeTextBaseHashFilterLenForRecords(expected_header.node_count);
            if (filter_len == 0) {
                std.Io.Dir.cwd().deleteFile(self.io, self.node_by_text_base_filter_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| return e,
                };
                self.node_text_base_filter_cache.clear(self.allocator);
                return;
            }
            if (try cachedNodeTextBaseHashFilter(self, expected_header)) |_| {
                return;
            }
            try writeNodeTextBaseHashFilter(self, expected_header);
        }

        pub fn ensureCurrentNodeTextBaseHashFilter(self: Store) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            if (try regularFileSize(self, file) != try nodeTextIndexFileSizeForHeader(header)) return error.InvalidRecord;
            try ensureNodeTextBaseHashFilter(self, header);
        }

        pub fn writeNodeTextBaseHashFilter(self: Store, expected_header: NodeTextIndexHeader) !void {
            const filter_len = nodeTextBaseHashFilterLenForRecords(expected_header.node_count);
            if (filter_len == 0) return;
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{ .allow_directory = false });
            defer file.close(self.io);
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            if (!nodeTextHeaderMatchesBaseFilter(expected_header, header)) return error.InvalidRecord;
            if (try regularFileSize(self, file) != try nodeTextIndexFileSizeForHeader(header)) return error.InvalidRecord;

            const filter = try self.allocator.alloc(u8, filter_len);
            defer self.allocator.free(filter);
            @memset(filter, 0);

            var texts: ?NodeTextsView = null;
            defer if (texts) |*view| view.deinit();
            var nodes: ?NodeByIdIndexView = null;
            defer if (nodes) |*view| view.deinit();
            const texts_for_hash = if (header.hasDerivedHash()) blk: {
                texts = try NodeTextsView.open(self);
                break :blk &texts.?;
            } else null;
            const nodes_for_hash = if (header.hasDerivedHash() and header.hasDerivedTextSpan()) blk: {
                const meta = try readIndexMeta(self);
                nodes = try NodeByIdIndexView.open(self, meta);
                break :blk &nodes.?;
            } else null;

            var pos: u64 = 0;
            while (pos < header.node_count) : (pos += 1) {
                nodeTextRunHashFilterSet(filter, try readNodeTextIndexRecordHashAtForHeader(self, file, header, pos, texts_for_hash, nodes_for_hash));
            }

            const tmp_path = try tmpPathFor(self, self.node_by_text_base_filter_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var out_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer out_file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, out_file, try storageWriteBufferCapacity(NodeTextBaseHashFilterHeader.encoded_len + filter.len));
                defer writer.deinit();
                const sidecar_header = NodeTextBaseHashFilterHeader{
                    .node_text_header = header,
                    .filter_len = @intCast(filter.len),
                    .filter_digest = nodeTextHashFilterDigest(filter),
                };
                var header_bytes: [NodeTextBaseHashFilterHeader.encoded_len]u8 = undefined;
                try sidecar_header.encode(&header_bytes);
                try writer.append(&header_bytes);
                try writer.append(filter);
                try writer.flush();
                if (selfOptionsNeedSync(self)) try out_file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.node_by_text_base_filter_path);
            self.node_text_base_filter_cache.clear(self.allocator);
            const cached_filter = try readCurrentNodeTextBaseHashFilter(self, header);
            if (cached_filter) |loaded_filter| {
                self.node_text_base_filter_cache.filter = loaded_filter;
                self.node_text_base_filter_cache.valid = true;
            }
        }

        pub fn readNodeTextRunManifestFile(self: Store, allocator: std.mem.Allocator, manifest_path: []const u8) !NodeTextRunManifest {
            var file = try std.Io.Dir.cwd().openFile(self.io, manifest_path, .{});
            var file_owned = true;
            defer if (file_owned) file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (file_size < NodeTextRunManifest.header_len) return error.InvalidRecord;
            const backing_size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
            var map = openReadOnlyMemoryMap(self.io, file, file_size) catch null;
            errdefer if (map) |*mapped| mapped.destroy(self.io);
            const backing = if (map) |*mapped| mapped.memory else blk: {
                const bytes = try allocator.alloc(u8, backing_size);
                errdefer allocator.free(bytes);
                if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.InvalidRecord;
                break :blk bytes;
            };
            const header_bytes: *const [NodeTextRunManifest.header_len]u8 = backing[0..NodeTextRunManifest.header_len];
            const header = try decodeNodeTextRunManifestHeader(header_bytes);
            if (header.run_count > node_text_run_manifest_max_entries) return error.InvalidRecord;

            var manifest = NodeTextRunManifest{
                .total_node_count = header.total_nodes,
                .node_digest = header.node_digest,
                .aggregates_valid = true,
                .backing = backing,
                .io = self.io,
                .file = if (map != null) file else null,
                .map = map,
            };
            if (map != null) {
                file_owned = false;
                map = null;
            }
            errdefer manifest.deinit(allocator);
            try manifest.entries.ensureTotalCapacity(allocator, header.run_count);
            var offset: u64 = NodeTextRunManifest.header_len;
            var total_count: u64 = 0;
            var total_digest: u64 = 0;
            var pos: usize = 0;
            while (pos < header.run_count) : (pos += 1) {
                const entry_end = std.math.add(u64, offset, NodeTextRunManifest.entry_header_len) catch return error.InvalidRecord;
                if (entry_end > file_size) return error.InvalidRecord;
                const entry_start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                const entry_bytes: *const [NodeTextRunManifest.entry_header_len]u8 = backing[entry_start..][0..NodeTextRunManifest.entry_header_len];
                const entry = try decodeNodeTextRunManifestEntryHeader(entry_bytes);
                if (entry.node_count == 0 or entry.node_count > node_text_run_max_records) return error.InvalidRecord;
                if (entry.path_len == 0 or entry.path_len > node_text_run_current_max_path_bytes) return error.InvalidRecord;
                offset = entry_end;
                const path_end = std.math.add(u64, offset, entry.path_len) catch return error.InvalidRecord;
                if (path_end > file_size) return error.InvalidRecord;
                const path_start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                const path_end_usize = std.math.cast(usize, path_end) orelse return error.RecordTooLarge;
                const path = backing[path_start..path_end_usize];
                offset = path_end;
                if (!nodeTextRunHashFilterLenValid(entry.hash_filter_len)) return error.InvalidRecord;
                const filter_end = std.math.add(u64, offset, entry.hash_filter_len) catch return error.InvalidRecord;
                if (filter_end > file_size) return error.InvalidRecord;
                const filter_start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                const filter_end_usize = std.math.cast(usize, filter_end) orelse return error.RecordTooLarge;
                const hash_filter = backing[filter_start..filter_end_usize];
                offset = filter_end;
                total_count = std.math.add(u64, total_count, entry.node_count) catch return error.InvalidRecord;
                total_digest ^= entry.node_digest;
                manifest.entries.appendAssumeCapacity(.{
                    .node_count = entry.node_count,
                    .node_digest = entry.node_digest,
                    .order_digest = entry.order_digest,
                    .min_node_id = entry.min_node_id,
                    .max_node_id = entry.max_node_id,
                    .min_hash = entry.min_hash,
                    .max_hash = entry.max_hash,
                    .path = path,
                    .path_digest = std.hash.Wyhash.hash(0x544B_4E52, path),
                    .has_path_digest = true,
                    .hash_filter = hash_filter,
                });
            }
            if (offset != file_size) return error.InvalidRecord;
            if (total_count != header.total_nodes) return error.InvalidRecord;
            if (total_digest != header.node_digest) return error.InvalidRecord;
            if (self.options.validate_indexes_on_read and nodeTextRunManifestContentDigestOwned(manifest.entries.items) != header.content_digest) return error.InvalidRecord;
            if (isNodeTextRunManifestEpochPath(self, manifest_path)) {
                const expected_path = try nodeTextRunManifestEpochPath(self, total_count, nodeTextRunManifestEpochDigestOwned(manifest.entries.items));
                defer self.allocator.free(expected_path);
                if (!std.mem.eql(u8, manifest_path, expected_path)) return error.InvalidRecord;
            }
            return manifest;
        }

        pub fn writeNodeTextRunManifestEntries(self: Store, entries: []const NodeTextRunManifestEntry) !void {
            return writeNodeTextRunManifestEntriesExcept(self, entries, &.{});
        }

        pub fn writeNodeTextRunManifestEntriesExcept(self: Store, entries: []const NodeTextRunManifestEntry, pinned_manifest_paths: []const []const u8) !void {
            if (entries.len > node_text_run_manifest_max_entries) return core.Error.BudgetExceeded;
            const total_nodes = try nodeTextRunManifestTotalNodes(entries);
            const epoch_digest = nodeTextRunManifestEpochDigest(entries);
            const epoch_path = try nodeTextRunManifestEpochPath(self, total_nodes, epoch_digest);
            defer self.allocator.free(epoch_path);
            const previous_epoch_path = try readNodeTextRunCurrentPath(self, self.allocator);
            defer if (previous_epoch_path) |path| self.allocator.free(path);

            // Once CURRENT is renamed, `epoch_path` is live even if the following
            // parent-directory sync reports an error. Never arm an errdefer that
            // can remove a possibly published manifest. An unreferenced epoch from
            // an earlier failure is harmless and the normal GC pass can reclaim it.
            try writeNodeTextRunManifestFile(self, epoch_path, entries);
            try writeNodeTextRunCurrent(self, epoch_path);
            warmNodeTextRunManifestCache(self, epoch_path);
            if (previous_epoch_path) |path| {
                if (!std.mem.eql(u8, path, epoch_path)) {
                    // CURRENT already names the new epoch. Retiring its predecessor
                    // is post-commit GC and must not turn a successful publication
                    // into an error or unwind callers that own newly referenced runs.
                    deleteSupersededNodeTextRunManifestEpochExcept(self, path, pinned_manifest_paths) catch {};
                }
            }
        }

        pub fn deleteSupersededNodeTextRunManifestEpochExcept(self: Store, manifest_path: []const u8, pinned_manifest_paths: []const []const u8) !void {
            if (!isNodeTextRunManifestEpochPath(self, manifest_path)) return;
            if (manifestPathListContains(pinned_manifest_paths, manifest_path)) return;
            if (try nodeTextRunManifestEpochHasActiveProcessLease(self, manifest_path)) return;
            std.Io.Dir.cwd().deleteFile(self.io, manifest_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        }

        pub fn isNodeTextRunManifestEpochPath(self: Store, manifest_path: []const u8) bool {
            const manifest_dir = std.fs.path.dirname(manifest_path) orelse return false;
            if (!std.mem.eql(u8, manifest_dir, self.dir_path)) return false;
            const manifest_leaf = std.fs.path.basename(self.node_text_run_manifest_path);
            const path_leaf = std.fs.path.basename(manifest_path);
            return node_text_run_gc.isManifestEpochLeaf(path_leaf, manifest_leaf);
        }

        pub fn nodeTextRunManifestEpochHasActiveProcessLease(self: Store, manifest_path: []const u8) !bool {
            const process_paths = try manifest_process_lease.activePaths(self, .node_text_run, self.allocator);
            defer freeOwnedManifestPathList(self.allocator, process_paths);
            return manifestPathListContains(process_paths, manifest_path);
        }

        pub fn manifestPathListContains(paths: []const []const u8, needle: []const u8) bool {
            for (paths) |path| {
                if (std.mem.eql(u8, path, needle)) return true;
            }
            return false;
        }

        pub fn nodeTextRunManifestTotalNodes(entries: []const NodeTextRunManifestEntry) !u64 {
            return node_text_run_manifest_format.totalNodes(entries);
        }

        pub fn nodeTextRunManifestEpochDigest(entries: []const NodeTextRunManifestEntry) u64 {
            return node_text_run_manifest_format.epochDigest(entries);
        }

        pub fn nodeTextRunManifestEpochPath(self: Store, total_nodes: u64, digest: u64) ![]u8 {
            return std.fmt.allocPrint(self.allocator, "{s}.{d}.{x}", .{ self.node_text_run_manifest_path, total_nodes, digest });
        }

        pub fn writeNodeTextRunManifestFile(self: Store, manifest_path: []const u8, entries: []const NodeTextRunManifestEntry) !void {
            const tmp_path = try tmpPathFor(self, manifest_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, storage_write_buffer_bytes);
                defer writer.deinit();

                var header: [NodeTextRunManifest.header_len]u8 = undefined;
                try encodeNodeTextRunManifestHeader(entries, &header);
                try writer.append(&header);

                var entry_header: [NodeTextRunManifest.entry_header_len]u8 = undefined;
                for (entries) |entry| {
                    try encodeNodeTextRunManifestEntryHeader(entry, &entry_header);
                    try writer.append(&entry_header);
                    try writer.append(entry.path);
                    try writer.append(entry.hash_filter);
                }
                try writer.flush();
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, manifest_path);
        }

        pub fn writeNodeTextRunCurrent(self: Store, manifest_path: []const u8) !void {
            if (manifest_path.len == 0 or manifest_path.len > node_text_run_current_max_path_bytes) return error.RecordTooLarge;
            const tmp_path = try tmpPathFor(self, self.node_text_run_current_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(self.io);
                try file.writePositionalAll(self.io, manifest_path, 0);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.node_text_run_current_path);
            invalidateNodeTextRunManifestCache(self);
        }

        pub fn readNodeTextRunCurrentPath(self: Store, allocator: std.mem.Allocator) !?[]u8 {
            var file = std.Io.Dir.cwd().openFile(self.io, self.node_text_run_current_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (file_size == 0 or file_size > node_text_run_current_max_path_bytes) return error.InvalidRecord;
            const path_len = std.math.cast(usize, file_size) orelse return error.InvalidRecord;
            const path = try allocator.alloc(u8, path_len);
            errdefer allocator.free(path);
            const n = try file.readPositionalAll(self.io, path, 0);
            if (n != path.len) return error.InvalidRecord;
            return path;
        }

        pub fn readEdgeIndexRecordById(self: Store, edge_id: core.EdgeId) !EdgeIndexRecord {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer file.close(self.io);
            const meta = try readCurrentIndexMeta(self);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != .id) return error.InvalidRecord;
            if (header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            if (header.order_digest != edgeOrderDigestForMeta(meta, .id)) return error.InvalidRecord;
            const expected_size = try edgeIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            const id = edge_id.toInt();
            const record = try readEdgeIndexRecordByIdFromOpenFile(self, file, header, id);
            if (try edgeTombstoneContains(self, id)) return core.Error.InvalidId;
            return record;
        }

        pub fn readVisibleEdgeIndexRecordById(self: Store, edge_id: core.EdgeId) !EdgeIndexRecord {
            const base_record: ?EdgeIndexRecord = readEdgeIndexRecordById(self, edge_id) catch |err| switch (err) {
                core.Error.InvalidId => null,
                else => |e| return e,
            };
            if (base_record) |record| return record;
            const raw_id = edge_id.toInt();
            if (raw_id == 0 or raw_id == std.math.maxInt(u64) or try edgeTombstoneContains(self, raw_id)) return core.Error.InvalidId;
            var opened = (try openPublishedEdgeSegmentsForQuery(self, self.allocator)) orelse return core.Error.InvalidId;
            defer opened.deinit();
            var stream = EdgeSegmentMergeStream.initWithVirtual(
                self.allocator,
                &opened.segments.segments,
                opened.segments.virtual_edges.items,
                .forward,
            );
            defer stream.deinit();
            try stream.reset();
            while (try stream.next()) |edge| {
                if (edge.edge_id.toInt() != raw_id) continue;
                return .{
                    .src = edge.src.toInt(),
                    .dst = edge.dst.toInt(),
                    .edge_id = raw_id,
                    .rel = @intFromEnum(edge.rel),
                };
            }
            return core.Error.InvalidId;
        }

        pub fn readEdgeById(self: Store, edge_id: core.EdgeId) !graph_mod.Edge {
            const record = try readVisibleEdgeIndexRecordById(self, edge_id);
            return .{
                .id = .fromInt(record.edge_id),
                .src = .fromInt(record.src),
                .rel = @enumFromInt(record.rel),
                .dst = .fromInt(record.dst),
            };
        }

        pub fn loadEdgeRefs(self: Store, allocator: std.mem.Allocator) ![]StoredEdgeRef {
            var out = std.ArrayList(StoredEdgeRef).empty;
            errdefer out.deinit(allocator);
            const meta = try readCurrentIndexMeta(self);
            try out.ensureTotalCapacityPrecise(allocator, std.math.cast(usize, meta.edges) orelse return error.RecordTooLarge);
            const Context = struct {
                allocator: std.mem.Allocator,
                refs: *std.ArrayList(StoredEdgeRef),

                fn visit(raw: *anyopaque, record: EdgeIndexRecord) !void {
                    const context: *@This() = @ptrCast(@alignCast(raw));
                    try context.refs.append(context.allocator, .{
                        .src = core.NodeId.fromInt(record.src),
                        .dst = core.NodeId.fromInt(record.dst),
                        .edge_id = core.EdgeId.fromInt(record.edge_id),
                        .rel = try record.relKind(),
                    });
                }
            };
            var context = Context{ .allocator = allocator, .refs = &out };
            _ = try scanVisibleEdgeIndexRecords(self, allocator, &context, Context.visit);
            return try out.toOwnedSlice(allocator);
        }

        pub fn readEdgeIndexRecordByIdFromOpenFile(self: Store, file: std.Io.File, header: EdgeIndexHeader, id: u64) !EdgeIndexRecord {
            if (header.order != .id) return error.InvalidRecord;
            if (id == 0 or id == std.math.maxInt(u64)) return core.Error.InvalidId;
            var lo: u64 = 0;
            var hi: u64 = header.edge_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const record = try readEdgeIndexRecordAt(self, file, header, mid);
                if (record.edge_id < id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo >= header.edge_count) return core.Error.InvalidId;
            const record = try readEdgeIndexRecordAt(self, file, header, lo);
            if (record.edge_id != id) return core.Error.InvalidId;
            return record;
        }

        pub fn readAllEdgeTombstones(self: Store, allocator: std.mem.Allocator) !std.ArrayList(EdgeTombstoneRecord) {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_tombstones_path, .{});
            defer file.close(self.io);
            const header = try readEdgeTombstoneHeaderFromFile(self, file);
            const expected_size = try edgeTombstoneFileSize(header.count);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            var edge_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer edge_file.close(self.io);
            const edge_header = try readEdgeIndexHeaderFromFile(self, edge_file);
            if (edge_header.order != .id) return error.InvalidRecord;
            if (try regularFileSize(self, edge_file) != try edgeIndexFileSizeForHeader(edge_header)) return error.InvalidRecord;
            var out = std.ArrayList(EdgeTombstoneRecord).empty;
            errdefer out.deinit(allocator);
            try out.ensureTotalCapacity(allocator, @intCast(header.count));
            var digest: u64 = 0;
            var previous: u64 = 0;
            var pos: u64 = 0;
            while (pos < header.count) : (pos += 1) {
                var record = try readEdgeTombstoneRecordAt(self, file, pos);
                if (record.edge_id <= previous) return error.InvalidRecord;
                previous = record.edge_id;
                record.edge_digest = edgeRecordDigest(try readEdgeIndexRecordByIdFromOpenFile(self, edge_file, edge_header, record.edge_id));
                digest ^= record.edge_digest;
                out.appendAssumeCapacity(record);
            }
            if (digest != header.digest) return error.InvalidRecord;
            return out;
        }

        pub fn edgeTombstoneContains(self: Store, edge_id: u64) !bool {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_tombstones_path, .{});
            defer file.close(self.io);
            const header = try readEdgeTombstoneHeaderFromFile(self, file);
            const expected_size = try edgeTombstoneFileSize(header.count);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            var lo: u64 = 0;
            var hi: u64 = header.count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const record = try readEdgeTombstoneRecordAt(self, file, mid);
                if (record.edge_id < edge_id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo >= header.count) return false;
            const record = try readEdgeTombstoneRecordAt(self, file, lo);
            return record.edge_id == edge_id;
        }

        pub fn insertEdgeTombstone(self: Store, record: EdgeIndexRecord) !EdgeTombstoneHeader {
            const tombstone = EdgeTombstoneRecord{
                .edge_id = record.edge_id,
                .edge_digest = edgeRecordDigest(record),
            };
            return insertEdgeTombstoneStreaming(self, tombstone);
        }

        pub fn insertEdgeTombstoneStreaming(self: Store, tombstone: EdgeTombstoneRecord) !EdgeTombstoneHeader {
            if (tombstone.edge_id == 0 or tombstone.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            var old_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_tombstones_path, .{});
            defer old_file.close(self.io);
            const old_header = try readEdgeTombstoneHeaderFromFile(self, old_file);
            const old_size = try edgeTombstoneFileSize(old_header.count);
            if (try regularFileSize(self, old_file) != old_size) return error.InvalidRecord;
            const new_count = std.math.add(u64, old_header.count, 1) catch return error.InvalidRecord;

            const tmp_path = try tmpPathFor(self, self.edge_tombstones_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            var new_header = EdgeTombstoneHeader{ .count = new_count, .digest = 0 };
            {
                var new_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer new_file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, new_file, try storageWriteBufferCapacity(try edgeTombstoneFileSize(new_count)));
                defer writer.deinit();

                var header_bytes: [EdgeTombstoneHeader.encoded_len]u8 = undefined;
                const placeholder_header = EdgeTombstoneHeader{ .count = new_count, .digest = 0 };
                placeholder_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var record_bytes: [EdgeTombstoneRecord.encoded_len]u8 = undefined;
                var new_digest: u64 = old_header.digest;
                var previous: u64 = 0;
                var inserted = false;
                var written: u64 = 0;
                var pos: u64 = 0;
                while (pos < old_header.count) : (pos += 1) {
                    const old_record = try readEdgeTombstoneRecordAt(self, old_file, pos);
                    if (old_record.edge_id <= previous) return error.InvalidRecord;
                    if (!inserted and tombstone.edge_id < old_record.edge_id) {
                        tombstone.encode(&record_bytes);
                        try writer.append(&record_bytes);
                        new_digest ^= tombstone.edge_digest;
                        written += 1;
                        previous = tombstone.edge_id;
                        inserted = true;
                    }
                    if (old_record.edge_id <= previous) return if (old_record.edge_id == tombstone.edge_id) core.Error.InvalidId else error.InvalidRecord;
                    old_record.encode(&record_bytes);
                    try writer.append(&record_bytes);
                    written += 1;
                    previous = old_record.edge_id;
                }
                if (!inserted) {
                    if (tombstone.edge_id <= previous) return if (tombstone.edge_id == previous) core.Error.InvalidId else error.InvalidRecord;
                    tombstone.encode(&record_bytes);
                    try writer.append(&record_bytes);
                    new_digest ^= tombstone.edge_digest;
                    written += 1;
                }
                if (written != new_count) return error.InvalidRecord;
                new_header.digest = new_digest;
                try writer.flush();
                if (try writer.position() != try edgeTombstoneFileSize(new_count)) return error.InvalidRecord;
                new_header.encode(&header_bytes);
                try new_file.writePositionalAll(self.io, &header_bytes, 0);
                if (selfOptionsNeedSync(self)) try new_file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.edge_tombstones_path);
            return new_header;
        }

        pub fn readStoredNodeFromRecord(self: Store, allocator: std.mem.Allocator, record: NodeByIdRecord) !StoredNode {
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            return texts.readStoredNode(allocator, record);
        }

        pub fn readEdgeIndexHeaderFromFile(self: Store, file: std.Io.File) !EdgeIndexHeader {
            var bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return EdgeIndexHeader.decode(&bytes);
        }

        pub fn readEdgeTombstoneHeaderFromFile(self: Store, file: std.Io.File) !EdgeTombstoneHeader {
            var bytes: [EdgeTombstoneHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return EdgeTombstoneHeader.decode(&bytes);
        }

        pub fn readEdgeIndexRecordAt(self: Store, file: std.Io.File, header: EdgeIndexHeader, index: u64) !EdgeIndexRecord {
            try header.validateShape();
            const run: ?EdgeIndexKeyRunRecord = if (header.hasKeyRuns())
                try readEdgeIndexKeyRunForRecordAt(self, file, header, index)
            else
                null;
            var bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            const record_bytes = bytes[0..header.record_len];
            const offset = try edgeIndexRecordOffsetForHeader(header, index);
            const n = try file.readPositionalAll(self.io, record_bytes, offset);
            if (n != record_bytes.len) return error.InvalidRecord;
            return EdgeIndexRecord.decodeSliceAtForHeader(header, index, record_bytes, run);
        }

        pub fn readEdgeTombstoneRecordAt(self: Store, file: std.Io.File, index: u64) !EdgeTombstoneRecord {
            var bytes: [EdgeTombstoneRecord.encoded_len]u8 = undefined;
            const offset = try edgeTombstoneRecordOffset(index);
            const n = try file.readPositionalAll(self.io, &bytes, offset);
            if (n != bytes.len) return error.InvalidRecord;
            return EdgeTombstoneRecord.decode(&bytes);
        }

        pub fn readEdgeIndexRecordFromMap(header: EdgeIndexHeader, map: *const std.Io.File.MemoryMap, index: u64) !EdgeIndexRecord {
            try header.validateShape();
            const run: ?EdgeIndexKeyRunRecord = if (header.hasKeyRuns())
                try readEdgeIndexKeyRunForRecordFromMap(header, map, index)
            else
                null;
            const offset = try edgeIndexRecordOffsetForHeader(header, index);
            const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
            const end = std.math.add(usize, start, header.record_len) catch return error.InvalidRecord;
            if (end > map.memory.len) return error.InvalidRecord;
            return EdgeIndexRecord.decodeSliceAtForHeader(header, index, map.memory[start..end], run);
        }

        pub fn readEdgeIndexKeyRunAt(self: Store, file: std.Io.File, header: EdgeIndexHeader, run_index: u64) !EdgeIndexKeyRunRecord {
            if (!header.hasKeyRuns() or run_index >= header.key_run_count) return error.InvalidRecord;
            const dense_end = if (header.hasKeyRunDenseSpan())
                try std.math.add(u64, header.key_run_dense_run_start, header.key_run_dense_count)
            else
                0;
            if (header.hasKeyRunDenseSpan() and run_index >= header.key_run_dense_run_start and run_index < dense_end) {
                return edgeIndexDenseKeyRunSpanRecordForIndex(header, run_index);
            }
            var bytes: [40]u8 = undefined;
            const run_bytes = bytes[0..edgeIndexKeyRunRecordLen(header)];
            const offset = try edgeIndexKeyRunOffsetForHeader(header, run_index);
            const n = try file.readPositionalAll(self.io, run_bytes, offset);
            if (n != run_bytes.len) return error.InvalidRecord;
            return EdgeIndexKeyRunRecord.decodeSliceForHeader(header, run_bytes);
        }

        pub fn readEdgeIndexKeyRunForRecordAt(self: Store, file: std.Io.File, header: EdgeIndexHeader, index: u64) !EdgeIndexKeyRunRecord {
            const run_index = try edgeIndexKeyRunIndexForRecordAt(self, file, header, index);
            const run = try readEdgeIndexKeyRunAt(self, file, header, run_index);
            if (run_index == 0 and run.start != 0) return error.InvalidRecord;
            if (run_index + 1 < header.key_run_count) {
                const next = try readEdgeIndexKeyRunAt(self, file, header, run_index + 1);
                try validateAdjacentEdgeIndexKeyRuns(header, run, next);
                if (index >= next.start) return error.InvalidRecord;
            }
            return run;
        }

        pub fn edgeIndexKeyRunIndexForRecordAt(self: Store, file: std.Io.File, header: EdgeIndexHeader, index: u64) !u64 {
            if (!header.hasKeyRuns() or index >= header.edge_count) return error.InvalidRecord;
            var lo: u64 = 0;
            var hi: u64 = header.key_run_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const run = try readEdgeIndexKeyRunAt(self, file, header, mid);
                if (run.start <= index) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo == 0) return error.InvalidRecord;
            return lo - 1;
        }

        pub fn readEdgeIndexKeyRunFromMap(header: EdgeIndexHeader, map: *const std.Io.File.MemoryMap, run_index: u64) !EdgeIndexKeyRunRecord {
            if (!header.hasKeyRuns() or run_index >= header.key_run_count) return error.InvalidRecord;
            const dense_end = if (header.hasKeyRunDenseSpan())
                try std.math.add(u64, header.key_run_dense_run_start, header.key_run_dense_count)
            else
                0;
            if (header.hasKeyRunDenseSpan() and run_index >= header.key_run_dense_run_start and run_index < dense_end) {
                return edgeIndexDenseKeyRunSpanRecordForIndex(header, run_index);
            }
            const offset = try edgeIndexKeyRunOffsetForHeader(header, run_index);
            const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
            const end = std.math.add(usize, start, edgeIndexKeyRunRecordLen(header)) catch return error.InvalidRecord;
            if (end > map.memory.len) return error.InvalidRecord;
            return EdgeIndexKeyRunRecord.decodeSliceForHeader(header, map.memory[start..end]);
        }

        pub fn readEdgeIndexKeyRunForRecordFromMap(header: EdgeIndexHeader, map: *const std.Io.File.MemoryMap, index: u64) !EdgeIndexKeyRunRecord {
            const run_index = try edgeIndexKeyRunIndexForRecordFromMap(header, map, index);
            const run = try readEdgeIndexKeyRunFromMap(header, map, run_index);
            if (run_index == 0 and run.start != 0) return error.InvalidRecord;
            if (run_index + 1 < header.key_run_count) {
                const next = try readEdgeIndexKeyRunFromMap(header, map, run_index + 1);
                try validateAdjacentEdgeIndexKeyRuns(header, run, next);
                if (index >= next.start) return error.InvalidRecord;
            }
            return run;
        }

        pub fn edgeIndexKeyRunIndexForRecordFromMap(header: EdgeIndexHeader, map: *const std.Io.File.MemoryMap, index: u64) !u64 {
            if (!header.hasKeyRuns() or index >= header.edge_count) return error.InvalidRecord;
            var lo: u64 = 0;
            var hi: u64 = header.key_run_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const run = try readEdgeIndexKeyRunFromMap(header, map, mid);
                if (run.start <= index) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo == 0) return error.InvalidRecord;
            return lo - 1;
        }

        pub fn edgeIndexKeyRunBoundsForKeyAt(self: Store, file: std.Io.File, header: EdgeIndexHeader, key: u64) !?EdgeIndexKeyRunBounds {
            if (!header.hasKeyRuns()) return error.InvalidRecord;
            if (header.order == .id) return error.InvalidRecord;
            var lo: u64 = 0;
            var hi: u64 = header.key_run_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const run = try readEdgeIndexKeyRunAt(self, file, header, mid);
                if (run.key < key) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo >= header.key_run_count) return null;
            const run = try readEdgeIndexKeyRunAt(self, file, header, lo);
            if (run.key != key) return null;
            if (lo == 0 and run.start != 0) return error.InvalidRecord;
            var last = run;
            var run_index = lo + 1;
            while (run_index < header.key_run_count) : (run_index += 1) {
                const next = try readEdgeIndexKeyRunAt(self, file, header, run_index);
                try validateAdjacentEdgeIndexKeyRuns(header, last, next);
                if (next.key != key) break;
                last = next;
            }
            const end = if (run_index < header.key_run_count) end: {
                const next = try readEdgeIndexKeyRunAt(self, file, header, run_index);
                break :end next.start;
            } else header.edge_count;
            return .{ .start = run.start, .end = end };
        }

        pub fn edgeIndexKeyRunBoundsForKeyFromMap(header: EdgeIndexHeader, map: *const std.Io.File.MemoryMap, key: u64) !?EdgeIndexKeyRunBounds {
            if (!header.hasKeyRuns()) return error.InvalidRecord;
            if (header.order == .id) return error.InvalidRecord;
            var lo: u64 = 0;
            var hi: u64 = header.key_run_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const run = try readEdgeIndexKeyRunFromMap(header, map, mid);
                if (run.key < key) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo >= header.key_run_count) return null;
            const run = try readEdgeIndexKeyRunFromMap(header, map, lo);
            if (run.key != key) return null;
            if (lo == 0 and run.start != 0) return error.InvalidRecord;
            var last = run;
            var run_index = lo + 1;
            while (run_index < header.key_run_count) : (run_index += 1) {
                const next = try readEdgeIndexKeyRunFromMap(header, map, run_index);
                try validateAdjacentEdgeIndexKeyRuns(header, last, next);
                if (next.key != key) break;
                last = next;
            }
            const end = if (run_index < header.key_run_count) end: {
                const next = try readEdgeIndexKeyRunFromMap(header, map, run_index);
                break :end next.start;
            } else header.edge_count;
            return .{ .start = run.start, .end = end };
        }

        pub fn readEdgeTombstoneRecordFromMap(map: *const std.Io.File.MemoryMap, index: u64) !EdgeTombstoneRecord {
            const offset = try edgeTombstoneRecordOffset(index);
            const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
            const end = std.math.add(usize, start, EdgeTombstoneRecord.encoded_len) catch return error.InvalidRecord;
            if (end > map.memory.len) return error.InvalidRecord;
            return EdgeTombstoneRecord.decodeSlice(map.memory[start..end]);
        }

        pub fn openReadOnlyMemoryMap(io: std.Io, file: std.Io.File, file_size: u64) !std.Io.File.MemoryMap {
            const len = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
            return read_only_memory_map.create(io, file, len);
        }

        pub fn readAllEdgeIndexRecords(self: Store, allocator: std.mem.Allocator, path: []const u8, order: EdgeIndexOrder) !std.ArrayList(EdgeIndexRecord) {
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != order) return error.InvalidRecord;
            const expected_size = try edgeIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var out = std.ArrayList(EdgeIndexRecord).empty;
            errdefer out.deinit(allocator);
            var reader = try EdgeIndexSequentialRecordReader.init(self, file, header);
            var pos: u64 = 0;
            while (pos < header.edge_count) : (pos += 1) {
                try out.append(allocator, try reader.read(pos));
            }
            return out;
        }

        pub fn openEdgeIndexRecordReader(self: Store, path: []const u8, order: EdgeIndexOrder, meta: IndexMeta) !EdgeIndexRecordReader {
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            errdefer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != order) return error.InvalidRecord;
            if (header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            if (header.order_digest != edgeOrderDigestForMeta(meta, order)) return error.InvalidRecord;
            const expected_size = try edgeIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var map = openReadOnlyMemoryMap(self.io, file, expected_size) catch null;
            errdefer if (map) |*mapped| mapped.destroy(self.io);
            return .{
                .store = self,
                .file = file,
                .map = map,
                .header = header,
                .edge_count = header.edge_count,
            };
        }

        pub fn publishEdgeAdjacencySegment(self: Store, segment_dir_path: []const u8) !u64 {
            const meta = try readCurrentIndexMeta(self);
            if (!try edgeIndexesMatchMeta(self, meta)) return error.InvalidRecord;

            var segment = try segment_mod.ImmutableAdjacencySegment.initEmpty(self.allocator, self.io, segment_dir_path);
            errdefer segment.deinit();

            const forward_summary = blk: {
                var reader = try openEdgeIndexRecordReader(self, self.edge_by_src_path, .src, meta);
                defer reader.deinit();
                break :blk try segment.writeOrderedRecordReaderSummary(.forward, reader.edge_count, &reader, edgeIndexReaderRecordToSegmentEdge);
            };

            const reverse_summary = blk: {
                var reader = try openEdgeIndexRecordReader(self, self.edge_by_dst_path, .dst, meta);
                defer reader.deinit();
                break :blk try segment.writeOrderedRecordReaderSummary(.reverse, reader.edge_count, &reader, edgeIndexReaderRecordToSegmentEdge);
            };
            const written_summary = try segment_mod.ImmutableAdjacencySegment.summarizeWrittenEdgeStreams(forward_summary, reverse_summary);
            const edge_id_summary = written_summary.edge_id_summary;
            const endpoint_summary = written_summary.endpoint_summary;
            const edge_id_index = blk: {
                var reader = try openEdgeIndexRecordReader(self, self.edge_by_id_path, .id, meta);
                defer reader.deinit();
                break :blk try writeEdgeSegmentIdIndexFromEdgeIndexReader(self, segment_dir_path, &reader, edge_id_summary);
            };
            const manifest_summary = try writeEdgeSegmentManifest(self, segment_dir_path, written_summary.edge_digest, edge_id_summary, endpoint_summary, edge_id_index.edge_id_order_digest, edge_id_index.edge_id_runs);
            var next_meta = meta;
            setEdgeSegmentSummary(&next_meta, manifest_summary);
            try writeIndexMeta(self, next_meta);
            segment.deinit();
            return meta.edge_indexed_edges;
        }

        pub fn publishSegmentBundle(self: Store, root_dir: []const u8) !void {
            const meta = try readCurrentIndexMeta(self);
            if (meta.nodes == 0 or meta.edges == 0) return error.InvalidRecord;
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            if (!try nodeTextIndexMatchesMeta(self, meta)) return error.InvalidRecord;
            if (!try edgeIndexBaseHeadersMatchMeta(self, meta)) return error.InvalidRecord;
            const expected_physical_edges = std.math.add(u64, meta.edges, tombstone_header.count) catch return error.InvalidRecord;
            const wal_checkpoint_bytes = try eventBytes(self);
            if (try segmentBundleMatchesCurrent(self, root_dir, meta, wal_checkpoint_bytes)) return;
            var reusable_node_snapshot = try pinSegmentBundleSnapshotWithReusableNode(self, root_dir, meta);
            defer if (reusable_node_snapshot) |*snapshot| snapshot.deinit(self.allocator);
            const reusable_node_entry: ?segment_manifest.Entry = if (reusable_node_snapshot) |snapshot|
                try segmentManifestUniqueEntry(snapshot, .node)
            else
                null;

            try std.Io.Dir.cwd().createDirPath(self.io, root_dir);
            if (reusable_node_snapshot) |snapshot| {
                if (try publishSegmentBundleEdgeDeltaIfPossible(self, root_dir, meta, wal_checkpoint_bytes, snapshot)) return;
            }

            var tombstones: ?EdgeTombstoneIndexView = null;
            defer if (tombstones) |*view| view.deinit();
            if (tombstone_header.count != 0) tombstones = try EdgeTombstoneIndexView.open(self);
            const tombstone_view = if (tombstones) |*view| view else null;

            var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound => EdgeSegmentManifest{},
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);
            const manifest_edges = manifest.totalEdgeCount();
            var covered_physical_edges: ?u64 = null;
            const use_base_indexes = if (manifest_edges == 0) true else blk: {
                covered_physical_edges = try edgeSegmentManifestCoveredPhysicalEdges(self, meta, manifest_edges);
                if (covered_physical_edges == null) {
                    if (!try edgeIndexesMatchMeta(self, meta)) return error.InvalidRecord;
                    break :blk true;
                }
                break :blk false;
            };
            if (use_base_indexes) {
                if (!try edgeIndexesMatchMeta(self, meta)) return error.InvalidRecord;
                var forward_reader = try openEdgeIndexRecordReader(self, self.edge_by_src_path, .src, meta);
                defer forward_reader.deinit();
                var reverse_reader = try openEdgeIndexRecordReader(self, self.edge_by_dst_path, .dst, meta);
                defer reverse_reader.deinit();
                if (tombstone_view == null and meta.edge_indexed_edges == meta.edges) {
                    return try publishSegmentBundleEdgeReaders(
                        self,
                        root_dir,
                        meta,
                        wal_checkpoint_bytes,
                        reusable_node_entry,
                        &forward_reader,
                        edgeIndexReaderRecordToSegmentEdge,
                        &reverse_reader,
                        edgeIndexReaderRecordToSegmentEdge,
                    );
                }
                var forward_stream = StoreEdgeRecordStream{ .reader = &forward_reader, .tombstones = tombstone_view };
                var reverse_stream = StoreEdgeRecordStream{ .reader = &reverse_reader, .tombstones = tombstone_view };
                return try publishSegmentBundleEdgeStreams(
                    self,
                    root_dir,
                    meta,
                    wal_checkpoint_bytes,
                    reusable_node_entry,
                    &forward_stream,
                    StoreEdgeRecordStream.reset,
                    StoreEdgeRecordStream.next,
                    &reverse_stream,
                    StoreEdgeRecordStream.reset,
                    StoreEdgeRecordStream.next,
                );
            }

            const physical_edges = covered_physical_edges.?;
            if (physical_edges != expected_physical_edges) return error.InvalidRecord;
            var segments = try PublishedEdgeSegments.openFromManifest(self.allocator, self.io, manifest.entries.items);
            defer segments.deinit();
            const physical_digest = meta.edge_digest ^ tombstone_header.digest;
            const segment_digest = try segments.edgeDigest();
            if (manifest_edges == physical_edges) {
                if (segment_digest != physical_digest) return error.InvalidRecord;
            } else if ((meta.edge_index_digest ^ segment_digest) != physical_digest) return error.InvalidRecord;
            if (manifest_edges == physical_edges) {
                var forward_stream = EdgeSegmentMergeStream.initWithVirtualFiltered(self.allocator, &segments.segments, segments.virtual_edges.items, .forward, tombstone_view);
                defer forward_stream.deinit();
                var reverse_stream = EdgeSegmentMergeStream.initWithVirtualFiltered(self.allocator, &segments.segments, segments.virtual_edges.items, .reverse, tombstone_view);
                defer reverse_stream.deinit();
                return try publishSegmentBundleEdgeStreams(
                    self,
                    root_dir,
                    meta,
                    wal_checkpoint_bytes,
                    reusable_node_entry,
                    &forward_stream,
                    EdgeSegmentMergeStream.reset,
                    EdgeSegmentMergeStream.next,
                    &reverse_stream,
                    EdgeSegmentMergeStream.reset,
                    EdgeSegmentMergeStream.next,
                );
            }

            var forward_reader = try openEdgeIndexRecordReader(self, self.edge_by_src_path, .src, meta);
            defer forward_reader.deinit();
            var reverse_reader = try openEdgeIndexRecordReader(self, self.edge_by_dst_path, .dst, meta);
            defer reverse_reader.deinit();
            var forward_stream = BaseAndSegmentMergeStream.initWithVirtualFiltered(self.allocator, &forward_reader, &segments.segments, segments.virtual_edges.items, .forward, tombstone_view);
            defer forward_stream.deinit();
            var reverse_stream = BaseAndSegmentMergeStream.initWithVirtualFiltered(self.allocator, &reverse_reader, &segments.segments, segments.virtual_edges.items, .reverse, tombstone_view);
            defer reverse_stream.deinit();
            try publishSegmentBundleEdgeStreams(
                self,
                root_dir,
                meta,
                wal_checkpoint_bytes,
                reusable_node_entry,
                &forward_stream,
                BaseAndSegmentMergeStream.reset,
                BaseAndSegmentMergeStream.next,
                &reverse_stream,
                BaseAndSegmentMergeStream.reset,
                BaseAndSegmentMergeStream.next,
            );
        }

        pub fn publishSegmentBundleEdgeStreams(
            self: Store,
            root_dir: []const u8,
            meta: IndexMeta,
            wal_checkpoint_bytes: u64,
            reusable_node_entry: ?segment_manifest.Entry,
            forward_context: anytype,
            comptime forward_reset: fn (@TypeOf(forward_context)) anyerror!void,
            comptime forward_next: fn (@TypeOf(forward_context)) anyerror!?segment_mod.EdgeRecord,
            reverse_context: anytype,
            comptime reverse_reset: fn (@TypeOf(reverse_context)) anyerror!void,
            comptime reverse_next: fn (@TypeOf(reverse_context)) anyerror!?segment_mod.EdgeRecord,
        ) !void {
            if (reusable_node_entry) |node_entry| {
                return try segment_bundle.publishTrustedOrderedEdgeStreamsWithNodeEntry(
                    self.allocator,
                    self.io,
                    root_dir,
                    node_entry,
                    meta.edges,
                    wal_checkpoint_bytes,
                    forward_context,
                    forward_reset,
                    forward_next,
                    reverse_context,
                    reverse_reset,
                    reverse_next,
                );
            }

            var texts_stream = try StoreTextsFileStream.init(self.allocator, self);
            defer texts_stream.deinit();
            var by_id_stream = try StoreCatalogByIdStream.init(self, meta);
            defer by_id_stream.deinit();
            var exact_runs = try StoreSegmentBundleExactRuns.build(self, root_dir, meta);
            defer exact_runs.deinit();
            var exact_stream = StoreSegmentBundleExactStream.init(self.allocator, self, exact_runs.paths.items);
            defer exact_stream.deinit();
            try segment_bundle.publishTrustedOrderedCatalogAndEdgeStreams(
                self.allocator,
                self.io,
                root_dir,
                meta.nodes,
                meta.node_digest,
                &texts_stream,
                StoreTextsFileStream.reset,
                StoreTextsFileStream.next,
                &by_id_stream,
                StoreCatalogByIdStream.reset,
                StoreCatalogByIdStream.next,
                &exact_stream,
                StoreSegmentBundleExactStream.reset,
                StoreSegmentBundleExactStream.next,
                meta.edges,
                wal_checkpoint_bytes,
                forward_context,
                forward_reset,
                forward_next,
                reverse_context,
                reverse_reset,
                reverse_next,
            );
        }

        pub fn publishSegmentBundleEdgeReaders(
            self: Store,
            root_dir: []const u8,
            meta: IndexMeta,
            wal_checkpoint_bytes: u64,
            reusable_node_entry: ?segment_manifest.Entry,
            forward_context: anytype,
            comptime forward_read: fn (@TypeOf(forward_context), u64) anyerror!segment_mod.EdgeRecord,
            reverse_context: anytype,
            comptime reverse_read: fn (@TypeOf(reverse_context), u64) anyerror!segment_mod.EdgeRecord,
        ) !void {
            if (reusable_node_entry) |node_entry| {
                return try segment_bundle.publishTrustedOrderedEdgeReadersWithNodeEntry(
                    self.allocator,
                    self.io,
                    root_dir,
                    node_entry,
                    meta.edges,
                    wal_checkpoint_bytes,
                    forward_context,
                    forward_read,
                    reverse_context,
                    reverse_read,
                );
            }

            var texts_stream = try StoreTextsFileStream.init(self.allocator, self);
            defer texts_stream.deinit();
            var by_id_stream = try StoreCatalogByIdStream.init(self, meta);
            defer by_id_stream.deinit();
            var exact_runs = try StoreSegmentBundleExactRuns.build(self, root_dir, meta);
            defer exact_runs.deinit();
            var exact_stream = StoreSegmentBundleExactStream.init(self.allocator, self, exact_runs.paths.items);
            defer exact_stream.deinit();
            try segment_bundle.publishTrustedOrderedCatalogAndEdgeReaders(
                self.allocator,
                self.io,
                root_dir,
                meta.nodes,
                meta.node_digest,
                &texts_stream,
                StoreTextsFileStream.reset,
                StoreTextsFileStream.next,
                &by_id_stream,
                StoreCatalogByIdStream.reset,
                StoreCatalogByIdStream.next,
                &exact_stream,
                StoreSegmentBundleExactStream.reset,
                StoreSegmentBundleExactStream.next,
                meta.edges,
                wal_checkpoint_bytes,
                forward_context,
                forward_read,
                reverse_context,
                reverse_read,
            );
        }

        pub fn segmentBundleMatchesCurrent(self: Store, root_dir: []const u8, meta: IndexMeta, wal_checkpoint_bytes: u64) !bool {
            if (meta.event_bytes != wal_checkpoint_bytes) return false;

            const manifest_dir = try std.fs.path.join(self.allocator, &.{ root_dir, segment_bundle.manifest_leaf });
            defer self.allocator.free(manifest_dir);

            var manifest_store = try segment_manifest.Store.init(self.allocator, self.io, manifest_dir);
            defer manifest_store.deinit();
            var snapshot = manifest_store.pinCurrent() catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer snapshot.deinit(self.allocator);

            if (snapshot.wal_checkpoint_bytes != wal_checkpoint_bytes) return false;

            var node_seen = false;
            var edge_seen = false;
            var edge_count: u64 = 0;
            var edge_digest: u64 = 0;
            for (snapshot.entries.items) |entry| switch (entry.kind) {
                .node => {
                    if (node_seen) return false;
                    if (entry.node_count != meta.nodes) return false;
                    if (entry.node_digest != meta.node_digest) return false;
                    const summary = entry.node_catalog_summary orelse return false;
                    if (summary.node_count != meta.nodes) return false;
                    node_seen = true;
                },
                .edge => {
                    edge_count = std.math.add(u64, edge_count, entry.edge_count) catch return false;
                    edge_digest ^= entry.segment_digest;
                    edge_seen = true;
                },
                else => return false,
            };
            return node_seen and edge_seen and edge_count == meta.edges and edge_digest == meta.edge_digest;
        }

        pub fn pinSegmentBundleSnapshotWithReusableNode(self: Store, root_dir: []const u8, meta: IndexMeta) !?segment_manifest.Snapshot {
            const manifest_dir = try std.fs.path.join(self.allocator, &.{ root_dir, segment_bundle.manifest_leaf });
            defer self.allocator.free(manifest_dir);

            var manifest_store = try segment_manifest.Store.init(self.allocator, self.io, manifest_dir);
            defer manifest_store.deinit();
            var snapshot = manifest_store.pinCurrent() catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            errdefer snapshot.deinit(self.allocator);

            const node_entry = segmentManifestUniqueEntry(snapshot, .node) catch |err| switch (err) {
                error.InvalidRecord => {
                    snapshot.deinit(self.allocator);
                    return null;
                },
                else => |e| return e,
            };
            if (!segmentManifestHasEdgeEntry(snapshot)) {
                snapshot.deinit(self.allocator);
                return null;
            }
            if (node_entry.node_count != meta.nodes or node_entry.node_digest != meta.node_digest) {
                snapshot.deinit(self.allocator);
                return null;
            }
            const summary = node_entry.node_catalog_summary orelse {
                snapshot.deinit(self.allocator);
                return null;
            };
            if (summary.node_count != meta.nodes) {
                snapshot.deinit(self.allocator);
                return null;
            }
            var catalog = segment_node_index.openTrustedFromManifestEntry(self.allocator, self.io, root_dir, node_entry) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    snapshot.deinit(self.allocator);
                    return null;
                },
                else => |e| return e,
            };
            catalog.deinit();
            return snapshot;
        }

        pub fn publishSegmentBundleEdgeDeltaIfPossible(
            self: Store,
            root_dir: []const u8,
            meta: IndexMeta,
            wal_checkpoint_bytes: u64,
            snapshot: segment_manifest.Snapshot,
        ) !bool {
            if (snapshot.wal_checkpoint_bytes >= wal_checkpoint_bytes) return false;

            const node_entry = segmentManifestUniqueEntry(snapshot, .node) catch |err| switch (err) {
                error.InvalidRecord => return false,
            };
            const existing_edge_entries = segmentManifestEdgeEntries(self.allocator, snapshot) catch |err| switch (err) {
                error.InvalidRecord => return false,
                else => |e| return e,
            };
            defer self.allocator.free(existing_edge_entries);
            const compact_threshold = self.options.auto_compact_edge_segment_entries;
            if (compact_threshold != 0 and existing_edge_entries.len >= compact_threshold) return false;

            var tail = try readEdgeAppendTailSpool(self, snapshot.wal_checkpoint_bytes, wal_checkpoint_bytes);
            defer tail.deinit(self);
            if (tail.count == 0) return false;
            if (tail.count > meta.edges) return false;

            const old_edge_count = std.math.sub(u64, meta.edges, @intCast(tail.count)) catch return false;
            if (try segmentManifestEdgeCount(existing_edge_entries) != old_edge_count) return false;
            if (segmentManifestEdgeDigest(existing_edge_entries) != (meta.edge_digest ^ tail.digest)) return false;

            if (tail.count <= edge_repair_sort_chunk_records) {
                var forward_records = std.ArrayList(EdgeIndexRecord).empty;
                defer forward_records.deinit(self.allocator);
                var reverse_order = std.ArrayList(u32).empty;
                defer reverse_order.deinit(self.allocator);
                try readEdgeTailSortedChunksFromSpool(self, tail.path.?, tail.count, &forward_records, &reverse_order);

                var forward_stream = EdgeSortedRecordSliceStream.init(forward_records.items);
                var reverse_stream = EdgeSortedRecordOrderStream.init(forward_records.items, reverse_order.items);
                try segment_bundle.publishEdgeDeltaWithExistingEntriesStreams(
                    self.allocator,
                    self.io,
                    root_dir,
                    node_entry,
                    existing_edge_entries,
                    @intCast(tail.count),
                    wal_checkpoint_bytes,
                    &forward_stream,
                    EdgeSortedRecordSliceStream.reset,
                    EdgeSortedRecordSliceStream.next,
                    &reverse_stream,
                    EdgeSortedRecordOrderStream.reset,
                    EdgeSortedRecordOrderStream.next,
                );
                return true;
            }

            var forward_runs = try buildEdgeSortedRunsFromSpool(self, root_dir, "forward", .src, tail.path.?, tail.count, tail.nonce);
            defer forward_runs.deinit();
            var reverse_runs = try buildEdgeSortedRunsFromSpool(self, root_dir, "reverse", .dst, tail.path.?, tail.count, tail.nonce);
            defer reverse_runs.deinit();
            var forward_stream = EdgeSortedRunStream.init(self.allocator, self, .src, forward_runs.paths.items);
            defer forward_stream.deinit();
            var reverse_stream = EdgeSortedRunStream.init(self.allocator, self, .dst, reverse_runs.paths.items);
            defer reverse_stream.deinit();
            try segment_bundle.publishEdgeDeltaWithExistingEntriesStreams(
                self.allocator,
                self.io,
                root_dir,
                node_entry,
                existing_edge_entries,
                @intCast(tail.count),
                wal_checkpoint_bytes,
                &forward_stream,
                EdgeSortedRunStream.reset,
                EdgeSortedRunStream.next,
                &reverse_stream,
                EdgeSortedRunStream.reset,
                EdgeSortedRunStream.next,
            );
            return true;
        }

        pub fn readEdgeAppendTailSpool(self: Store, checkpoint_bytes: u64, end_bytes: u64) !EdgeAppendTailSpool {
            if (checkpoint_bytes >= end_bytes) return .{};

            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{});
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (end_bytes > file_size or checkpoint_bytes > end_bytes) return error.InvalidRecord;

            const pid = currentProcessIdForTempPath();
            const nonce = store_temp_nonce.fetchAdd(1, .monotonic);
            const spool_path = try std.fmt.allocPrint(self.allocator, "{s}.edge_tail.{d}.{d}.{d}.{d}.spool.tmp", .{
                self.events_bin_path,
                checkpoint_bytes,
                end_bytes,
                pid,
                nonce,
            });
            var keep_spool_path = false;
            defer if (!keep_spool_path) {
                std.Io.Dir.cwd().deleteFile(self.io, spool_path) catch {};
                self.allocator.free(spool_path);
            };

            var spool_file = try std.Io.Dir.cwd().createFile(self.io, spool_path, .{
                .read = true,
                .truncate = true,
            });
            defer spool_file.close(self.io);
            var writer = try StorageBufferedWriter.init(self.allocator, self.io, spool_file, storage_write_buffer_bytes);
            defer writer.deinit();

            var offset = checkpoint_bytes;
            var in_batch = false;
            var count: usize = 0;
            var digest: u64 = 0;
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            while (offset < end_bytes) {
                const parsed = try readBinaryRecordHeader(self, file, &offset) orelse return error.InvalidRecord;
                try ensureBinaryPayloadFits(file_size, offset, parsed.payload_len);
                if (@as(u64, parsed.payload_len) > end_bytes - offset) return error.InvalidRecord;
                switch (parsed.kind) {
                    .batch_begin => {
                        if (in_batch or parsed.payload_len != 0) {
                            return .{};
                        }
                        try validateBinaryChecksumValue(parsed, binaryPayloadChecksum(&.{}));
                        in_batch = true;
                    },
                    .batch_commit => {
                        if (!in_batch or parsed.payload_len != 0) {
                            return .{};
                        }
                        try validateBinaryChecksumValue(parsed, binaryPayloadChecksum(&.{}));
                        in_batch = false;
                    },
                    .edge => {
                        if (parsed.payload_len != binary_edge_payload_len) {
                            return .{};
                        }
                        var payload: [binary_edge_payload_len]u8 = undefined;
                        const read_len = try file.readPositionalAll(self.io, &payload, offset);
                        if (read_len != payload.len) return error.InvalidRecord;
                        try validateBinaryChecksum(parsed, &payload);
                        const parsed_edge = try validateBinaryEdgePayload(&payload);
                        const record = EdgeIndexRecord{
                            .src = parsed_edge.src,
                            .dst = parsed_edge.dst,
                            .edge_id = parsed_edge.id,
                            .rel = @intFromEnum(parsed_edge.rel),
                        };
                        record.encode(&record_bytes);
                        try writer.append(&record_bytes);
                        count = std.math.add(usize, count, 1) catch return error.RecordTooLarge;
                        digest ^= edgeRecordDigest(record);
                    },
                    .edge_batch => {
                        if (!in_batch) return .{};
                        const payload = try readBinaryPayloadAllocAndValidateChecksum(self, file, offset, parsed);
                        defer self.allocator.free(payload);
                        const batch = try validateBinaryEdgeBatchHeader(payload);
                        var index: u32 = 0;
                        while (index < batch.count) : (index += 1) {
                            const parsed_edge = try validateBinaryEdgeBatchEdge(payload, batch, index);
                            const record = EdgeIndexRecord{
                                .src = parsed_edge.src,
                                .dst = parsed_edge.dst,
                                .edge_id = parsed_edge.id,
                                .rel = @intFromEnum(parsed_edge.rel),
                            };
                            record.encode(&record_bytes);
                            try writer.append(&record_bytes);
                            count = std.math.add(usize, count, 1) catch return error.RecordTooLarge;
                            digest ^= edgeRecordDigest(record);
                        }
                    },
                    .node, .node_batch, .edge_delete => {
                        return .{};
                    },
                }
                try advanceBinaryOffset(&offset, parsed.payload_len);
            }
            if (offset != end_bytes or in_batch) {
                return .{};
            }
            if (count == 0) return .{};

            try writer.flush();
            const expected_size = std.math.mul(u64, @intCast(count), EdgeIndexRecord.encoded_len) catch return error.RecordTooLarge;
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, spool_file) != expected_size) return error.InvalidRecord;
            if (selfOptionsNeedSync(self)) try spool_file.sync(self.io);

            keep_spool_path = true;
            return .{
                .path = spool_path,
                .count = count,
                .digest = digest,
                .nonce = nonce,
            };
        }

        pub fn readEdgeTailSortedChunksFromSpool(
            self: Store,
            spool_path: []const u8,
            record_count: usize,
            forward_records: *std.ArrayList(EdgeIndexRecord),
            reverse_order: *std.ArrayList(u32),
        ) !void {
            if (record_count == 0 or record_count > edge_repair_sort_chunk_records) return error.InvalidRecord;
            if (record_count > std.math.maxInt(u32)) return error.InvalidRecord;
            var spool_file = try std.Io.Dir.cwd().openFile(self.io, spool_path, .{});
            defer spool_file.close(self.io);
            const expected_spool_size = std.math.mul(u64, @intCast(record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            try forward_records.ensureTotalCapacityPrecise(self.allocator, record_count);
            try reverse_order.ensureTotalCapacityPrecise(self.allocator, record_count);
            const chunk_bytes = try self.allocator.alloc(u8, std.math.mul(usize, record_count, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord);
            defer self.allocator.free(chunk_bytes);

            try readEdgeRepairSpoolChunk(self, spool_file, 0, record_count, chunk_bytes, forward_records);
            sortEdgeIndexRecords(.src, forward_records.items);
            try validateSortedRepairEdgeRecords(.src, forward_records.items);
            for (forward_records.items, 0..) |_, index| reverse_order.appendAssumeCapacity(@intCast(index));
            sortEdgeIndexRecordOrder(.dst, forward_records.items, reverse_order.items);
            try validateSortedRepairEdgeRecordOrder(.dst, forward_records.items, reverse_order.items);
        }

        pub fn buildEdgeSortedRunsFromSpool(
            self: Store,
            root_dir: []const u8,
            label: []const u8,
            order: EdgeIndexOrder,
            spool_path: []const u8,
            record_count: usize,
            nonce: u64,
        ) !EdgeSortedRunSet {
            var spool_file = try std.Io.Dir.cwd().openFile(self.io, spool_path, .{});
            defer spool_file.close(self.io);
            const expected_spool_size = std.math.mul(u64, @intCast(record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            var runs = EdgeSortedRunSet{ .allocator = self.allocator, .store = self };
            errdefer runs.deinit();

            var chunk = std.ArrayList(EdgeIndexRecord).empty;
            defer chunk.deinit(self.allocator);
            const max_chunk_records = @min(record_count, edge_repair_sort_chunk_records);
            try chunk.ensureTotalCapacityPrecise(self.allocator, max_chunk_records);
            const chunk_bytes = try self.allocator.alloc(u8, std.math.mul(usize, max_chunk_records, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord);
            defer self.allocator.free(chunk_bytes);

            var read_pos: usize = 0;
            while (read_pos < record_count) {
                chunk.clearRetainingCapacity();
                const take = @min(edge_repair_sort_chunk_records, record_count - read_pos);
                try readEdgeRepairSpoolChunk(self, spool_file, read_pos, take, chunk_bytes, &chunk);
                sortEdgeIndexRecords(order, chunk.items);
                const pid = currentProcessIdForTempPath();
                const run_path = try std.fmt.allocPrint(self.allocator, "{s}/.edge-tail-{s}-{c}-{d}-{d}-{d}.tmp", .{
                    root_dir,
                    label,
                    @intFromEnum(order),
                    pid,
                    nonce,
                    runs.paths.items.len,
                });
                var run_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
                    if (run_path_owned) self.allocator.free(run_path);
                }
                try writeRepairEdgeRun(self, run_path, chunk.items);
                try runs.paths.append(self.allocator, run_path);
                run_path_owned = false;
                read_pos += take;
            }
            if (runs.paths.items.len == 0) return error.InvalidRecord;
            return runs;
        }

        pub fn publishEdgeBatchSegmentIfManifestCurrent(self: Store, old_meta: IndexMeta, next_meta: *IndexMeta, batch_records: []EdgeIndexRecord) !void {
            if (batch_records.len == 0) return;
            const manifest_read_start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
            var manifest_found = true;
            var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    manifest_found = false;
                    break :blk EdgeSegmentManifest{};
                },
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);
            if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.segment_publish_manifest_read_ns += storageElapsedNs(self.io, manifest_read_start);
            }
            if (!manifest_found and (next_meta.edge_indexed_edges != old_meta.edge_indexed_edges or old_meta.edge_indexed_edges < implicit_edge_delta_segment_min_base_edges)) return;
            if (try edgeSegmentManifestCoveredPhysicalEdges(self, old_meta, manifest.totalEdgeCount()) == null) return;

            const publish_start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
            if (batch_records.len == 1) {
                const record = batch_records[0];
                const edge_id = record.edge_id;
                const rel = try record.relKind();
                var entries = std.ArrayList(EdgeSegmentManifestEntry).empty;
                defer entries.deinit(self.allocator);
                try entries.ensureTotalCapacity(self.allocator, manifest.entries.items.len + 1);
                for (manifest.entries.items) |entry| {
                    entries.appendAssumeCapacity(.{
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
                    });
                }
                const new_entry = EdgeSegmentManifestEntry{
                    .edge_count = 1,
                    .edge_digest = edgeRecordDigest(record),
                    .edge_id_range = .{ .min = edge_id, .max = edge_id },
                    .edge_id_digest = edgeSegmentIdDigest(edge_id),
                    .edge_id_runs = .{ .run_count = 1, .first_min = edge_id, .first_max = edge_id },
                    .src_node_range = .{ .min = record.src, .max = record.src },
                    .dst_node_range = .{ .min = record.dst, .max = record.dst },
                    .singleton_rel = rel,
                    .path = "",
                };
                if (entries.items.len == 0 or !try extendVirtualEdgeRun(&entries.items[entries.items.len - 1], new_entry)) {
                    entries.appendAssumeCapacity(new_entry);
                }
                const manifest_write_start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
                try writeEdgeSegmentManifestEntries(self, entries.items);
                setEdgeSegmentSummary(next_meta, try edgeSegmentManifestSummary(self, entries.items));
                if (self.edge_batch_segment_delta_stats) |delta_stats| {
                    delta_stats.segment_publish_manifest_write_ns += storageElapsedNs(self.io, manifest_write_start);
                    delta_stats.segment_publish_batches += 1;
                    delta_stats.segment_publish_edges += 1;
                    delta_stats.segment_publish_ns += storageElapsedNs(self.io, publish_start);
                }
                return;
            }
            const segment_path = try edgeBatchSegmentPath(self, old_meta, next_meta.*);
            defer self.allocator.free(segment_path);
            if (try pathExists(self, segment_path)) return error.AlreadyExists;
            var segment_unpublished = true;
            errdefer if (segment_unpublished) std.Io.Dir.cwd().deleteTree(self.io, segment_path) catch {};
            const segment_write_start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
            const batch_edge_id_index = try writeEdgeBatchSegment(self, segment_path, batch_records);
            if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.segment_publish_segment_write_ns += storageElapsedNs(self.io, segment_write_start);
            }

            var entries = std.ArrayList(EdgeSegmentManifestEntry).empty;
            defer entries.deinit(self.allocator);
            try entries.ensureTotalCapacity(self.allocator, manifest.entries.items.len + 1);
            for (manifest.entries.items) |entry| {
                entries.appendAssumeCapacity(.{
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
                });
            }
            entries.appendAssumeCapacity(.{
                .edge_count = @intCast(batch_records.len),
                .edge_digest = batch_edge_id_index.edge_digest,
                .edge_id_range = batch_edge_id_index.edge_id_summary.range,
                .edge_id_digest = batch_edge_id_index.edge_id_summary.digest,
                .edge_id_order_digest = batch_edge_id_index.edge_id_order_digest,
                .edge_id_runs = batch_edge_id_index.edge_id_runs,
                .src_node_range = batch_edge_id_index.endpoint_summary.src_range,
                .dst_node_range = batch_edge_id_index.endpoint_summary.dst_range,
                .path = segment_path,
            });
            const manifest_write_start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
            // The CURRENT rename is an irreversible commit point. From here on,
            // preserve the segment on every error; an unreferenced segment can be
            // collected later, while deleting a possibly referenced one corrupts
            // the published manifest.
            segment_unpublished = false;
            try writeEdgeSegmentManifestEntries(self, entries.items);
            setEdgeSegmentSummary(next_meta, try edgeSegmentManifestSummary(self, entries.items));
            if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.segment_publish_manifest_write_ns += storageElapsedNs(self.io, manifest_write_start);
            }
            if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.segment_publish_batches += 1;
                delta_stats.segment_publish_edges += @intCast(batch_records.len);
                delta_stats.segment_publish_ns += storageElapsedNs(self.io, publish_start);
            }
        }

        pub fn edgeBatchSegmentPath(self: Store, old_meta: IndexMeta, next_meta: IndexMeta) ![]u8 {
            const parent = try std.fs.path.join(self.allocator, &.{ self.dir_path, "edge_segments" });
            defer self.allocator.free(parent);
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
            const leaf = try std.fmt.allocPrint(self.allocator, "l0-{}-{}-{}", .{ old_meta.edge_indexed_edges, next_meta.edge_indexed_edges, next_meta.event_bytes });
            defer self.allocator.free(leaf);
            return try std.fs.path.join(self.allocator, &.{ parent, leaf });
        }

        pub fn writeEdgeBatchSegment(self: Store, segment_dir_path: []const u8, batch_records: []EdgeIndexRecord) !EdgeSegmentIdIndexSummary {
            var segment = try segment_mod.ImmutableAdjacencySegment.initEmpty(self.allocator, self.io, segment_dir_path);
            errdefer segment.deinit();

            sortEdgeIndexRecords(.src, batch_records);
            const forward_summary = try segment.writeOrderedRecordsSummary(.forward, EdgeIndexRecord, batch_records, edgeIndexRecordToSegmentEdge);
            sortEdgeIndexRecords(.dst, batch_records);
            const reverse_summary = try segment.writeOrderedRecordsSummary(.reverse, EdgeIndexRecord, batch_records, edgeIndexRecordToSegmentEdge);

            const written_summary = try segment_mod.ImmutableAdjacencySegment.summarizeWrittenEdgeStreams(forward_summary, reverse_summary);
            const edge_id_summary = written_summary.edge_id_summary;
            const endpoint_summary = written_summary.endpoint_summary;
            sortEdgeIndexRecords(.id, batch_records);
            const edge_id_order_digest = edgeSegmentIdIndexOrderDigest(batch_records);
            const edge_id_index = try writeEdgeSegmentIdIndexFromRecords(self, segment_dir_path, batch_records, edge_id_summary, edge_id_order_digest);
            segment.deinit();
            return .{
                .edge_digest = written_summary.edge_digest,
                .edge_id_summary = edge_id_summary,
                .endpoint_summary = endpoint_summary,
                .edge_id_order_digest = edge_id_index.edge_id_order_digest,
                .edge_id_runs = edge_id_index.edge_id_runs,
            };
        }

        pub fn compactPublishedEdgeSegments(self: Store, segment_dir_path: []const u8) !u64 {
            if (try pathExists(self, segment_dir_path)) return error.AlreadyExists;
            var manifest = try readEdgeSegmentManifest(self, self.allocator);
            defer manifest.deinit(self.allocator);
            const meta = try readCurrentIndexMeta(self);
            const manifest_edges = manifest.totalEdgeCount();
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            const covered_physical_edges = try edgeSegmentManifestCoveredPhysicalEdges(self, meta, manifest_edges);
            if (covered_physical_edges == null and !try edgeSegmentManifestCoversVisibleEdges(self, meta, manifest_edges)) {
                if (try edgeIndexesMatchMeta(self, meta)) {
                    return try publishEdgeAdjacencySegment(self, segment_dir_path);
                }
                return error.InvalidRecord;
            }
            const source_edges = covered_physical_edges orelse meta.edges;
            const filters_tombstones = tombstone_header.count != 0 and covered_physical_edges != null;
            const total_edges = if (filters_tombstones) meta.edges else source_edges;
            const delta_overlay = covered_physical_edges != null and manifest_edges != source_edges;

            var segments = try PublishedEdgeSegments.openFromManifest(self.allocator, self.io, manifest.entries.items);
            defer segments.deinit();
            if (!filters_tombstones and tombstone_header.count != 0 and manifest_edges == meta.edges) {
                if (try segments.edgeDigest() != meta.edge_digest) return error.InvalidRecord;
            }

            var tombstones: ?EdgeTombstoneIndexView = null;
            defer if (tombstones) |*view| view.deinit();
            if (filters_tombstones) tombstones = try EdgeTombstoneIndexView.open(self);
            const tombstone_view = if (tombstones) |*view| view else null;

            var segment = try segment_mod.ImmutableAdjacencySegment.initEmpty(self.allocator, self.io, segment_dir_path);
            errdefer segment.deinit();
            var segment_unpublished = true;
            errdefer if (segment_unpublished) std.Io.Dir.cwd().deleteTree(self.io, segment_dir_path) catch {};

            var forward_summary: segment_mod.ImmutableAdjacencySegment.WrittenEdgeStreamSummary = undefined;
            var reverse_summary: segment_mod.ImmutableAdjacencySegment.WrittenEdgeStreamSummary = undefined;
            if (delta_overlay) {
                {
                    var reader = try openEdgeIndexRecordReader(self, self.edge_by_src_path, .src, meta);
                    defer reader.deinit();
                    var stream = BaseAndSegmentMergeStream.initWithVirtualFiltered(self.allocator, &reader, &segments.segments, segments.virtual_edges.items, .forward, tombstone_view);
                    defer stream.deinit();
                    forward_summary = try segment.writeTrustedOrderedEdgeStreamSummary(.forward, total_edges, &stream, BaseAndSegmentMergeStream.reset, BaseAndSegmentMergeStream.next);
                }
                {
                    var reader = try openEdgeIndexRecordReader(self, self.edge_by_dst_path, .dst, meta);
                    defer reader.deinit();
                    var stream = BaseAndSegmentMergeStream.initWithVirtualFiltered(self.allocator, &reader, &segments.segments, segments.virtual_edges.items, .reverse, tombstone_view);
                    defer stream.deinit();
                    reverse_summary = try segment.writeTrustedOrderedEdgeStreamSummary(.reverse, total_edges, &stream, BaseAndSegmentMergeStream.reset, BaseAndSegmentMergeStream.next);
                }
            } else {
                {
                    var stream = EdgeSegmentMergeStream.initWithVirtualFiltered(self.allocator, &segments.segments, segments.virtual_edges.items, .forward, tombstone_view);
                    defer stream.deinit();
                    forward_summary = try segment.writeTrustedOrderedEdgeStreamSummary(.forward, total_edges, &stream, EdgeSegmentMergeStream.reset, EdgeSegmentMergeStream.next);
                }
                {
                    var stream = EdgeSegmentMergeStream.initWithVirtualFiltered(self.allocator, &segments.segments, segments.virtual_edges.items, .reverse, tombstone_view);
                    defer stream.deinit();
                    reverse_summary = try segment.writeTrustedOrderedEdgeStreamSummary(.reverse, total_edges, &stream, EdgeSegmentMergeStream.reset, EdgeSegmentMergeStream.next);
                }
            }

            const written_summary = try segment_mod.ImmutableAdjacencySegment.summarizeWrittenEdgeStreams(forward_summary, reverse_summary);
            const edge_id_summary = written_summary.edge_id_summary;
            const endpoint_summary = written_summary.endpoint_summary;
            try segment.openWrittenViewsWithSummaries(forward_summary, reverse_summary);
            const edge_id_index = try writeEdgeSegmentIdIndexFromSegment(self, segment_dir_path, &segment, edge_id_summary);
            segment_unpublished = false;
            const manifest_summary = try writeEdgeSegmentManifest(self, segment_dir_path, written_summary.edge_digest, edge_id_summary, endpoint_summary, edge_id_index.edge_id_order_digest, edge_id_index.edge_id_runs);
            try updateIndexMetaEdgeSegmentSummary(self, manifest_summary);
            segment.deinit();
            return total_edges;
        }

        pub fn gcUnreferencedEdgeSegments(self: Store) !EdgeSegmentGcResult {
            return gcUnreferencedEdgeSegmentsExcept(self, &.{});
        }

        pub fn currentEdgeSegmentManifestPath(self: Store, allocator: std.mem.Allocator) !?[]u8 {
            return readEdgeSegmentCurrentPath(self, allocator);
        }

        pub fn openEdgeSegmentRetentionWindow(self: Store, allocator: std.mem.Allocator) !EdgeSegmentRetentionWindow {
            var window = retention.initEdgeSegmentRetentionWindow(allocator);
            errdefer window.deinit();
            if (try currentEdgeSegmentManifestPath(self, allocator)) |path| {
                try retention.appendOwnedEdgeSegmentManifestPath(&window, path);
            }
            return window;
        }

        pub fn openRegisteredEdgeSegmentRetentionWindow(self: Store, registry: *EdgeSegmentRetentionRegistry) !EdgeSegmentRegisteredRetentionWindow {
            var acquired = (try manifest_process_lease.acquireCurrent(self, registry.allocator, .edge_segment)) orelse
                return .{ .registry = registry };
            errdefer acquired.deinit();
            const retained_path = try retention.retainOwnedEdgeSegmentManifestPath(registry, acquired.takeManifestPath());
            return .{
                .registry = registry,
                .manifest_path = retained_path,
                .process_lease = acquired.takeProcessLease(),
            };
        }

        pub fn gcUnreferencedEdgeSegmentsRetainingRegistry(self: Store, registry: *const EdgeSegmentRetentionRegistry) !EdgeSegmentGcResult {
            const pinned_paths = try registry.activeManifestPaths(self.allocator);
            defer self.allocator.free(pinned_paths);
            return gcUnreferencedEdgeSegmentsExcept(self, pinned_paths);
        }

        pub fn gcUnreferencedEdgeSegmentsWithProcessLeases(self: Store) !EdgeSegmentGcResult {
            return gcUnreferencedEdgeSegmentsExceptAndProcessLeases(self, &.{});
        }

        pub fn dropRedundantEdgeSegmentOverlayAfterBaseIndexCatchup(self: Store) !bool {
            const meta = try readCurrentIndexMeta(self);
            if (meta.edge_segment_edges != 0) return false;
            if (meta.edge_indexed_edges != try visiblePlusTombstoneEdgeCount(self, meta)) return false;

            const current_manifest_path = try readEdgeSegmentCurrentPath(self, self.allocator);
            defer if (current_manifest_path) |path| self.allocator.free(path);
            const current_path = current_manifest_path orelse return false;

            var manifest = readEdgeSegmentManifestFile(self, self.allocator, current_path) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);
            try validateEdgeSegmentManifestPath(self, self.allocator, current_path, manifest.entries.items);
            for (manifest.entries.items) |entry| {
                if (edgeSegmentManifestEntryIsVirtual(entry)) continue;
                if (!try edgeSegmentPathIsImplicitL0(self, entry.path)) return false;
            }

            // Withdraw CURRENT before sampling leases. A reader publishes its
            // lease between two CURRENT reads; after this durable unlink, every
            // reader that accepted `current_path` must already have a visible
            // lease, while a later reader will fail its second read and never use
            // the old files. Sampling first would leave a race where a reader
            // stabilizes the old CURRENT after the sample and loses its segment.
            std.Io.Dir.cwd().deleteFile(self.io, self.edge_segment_current_path) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            try syncParentDirForPath(self, self.edge_segment_current_path);

            const protected_paths = try manifest_process_lease.pinnedPaths(self, .edge_segment, self.allocator, &.{});
            defer freeOwnedManifestPathList(self.allocator, protected_paths);
            for (protected_paths) |path| {
                if (std.mem.eql(u8, path, current_path)) {
                    // Keep the old epoch discoverable for a later cleanup pass.
                    // The temporary withdrawal above closed the acquisition race;
                    // republishing now is safe because every accepted reader has
                    // a lease that the next pass will sample after withdrawing it
                    // again. A crash before this point only leaks redundant files.
                    try writeEdgeSegmentCurrent(self, current_path);
                    return false;
                }
            }

            // All entries were admitted above as direct implicit-L0 children.
            // Anchor recursive deletion to that already-validated segment root so
            // a Windows full-path lookup can never widen cleanup to the Store root
            // after CURRENT has been withdrawn.
            const segment_root = try edgeSegmentManifestSegmentRoot(self, self.allocator);
            defer self.allocator.free(segment_root);
            const segment_root_dir = std.Io.Dir.cwd().openDir(self.io, segment_root, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            };
            defer if (segment_root_dir) |dir| dir.close(self.io);
            if (segment_root_dir) |dir| {
                for (manifest.entries.items) |entry| {
                    dir.deleteTree(self.io, std.fs.path.basename(entry.path)) catch |err| switch (err) {
                        // CURRENT is already durably withdrawn and the base index
                        // covers these edges. Windows can still deny unlink while
                        // an mmap/AV handle drains; leaving unreferenced garbage
                        // for the normal GC pass is safe, while failing here would
                        // report an error after the logical commit point.
                        error.AccessDenied, error.FileBusy => {},
                        else => |e| return e,
                    };
                }
            }
            std.Io.Dir.cwd().deleteFile(self.io, current_path) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.FileBusy => {},
                else => |e| return e,
            };
            return true;
        }

        pub fn edgeSegmentPathIsImplicitL0(self: Store, path: []const u8) !bool {
            const parent = try std.fs.path.join(self.allocator, &.{ self.dir_path, "edge_segments" });
            defer self.allocator.free(parent);
            const dirname = std.fs.path.dirname(path) orelse return false;
            return std.mem.eql(u8, dirname, parent) and std.mem.startsWith(u8, std.fs.path.basename(path), "l0-");
        }

        pub fn gcUnreferencedEdgeSegmentsExceptAndProcessLeases(self: Store, pinned_manifest_paths: []const []const u8) !EdgeSegmentGcResult {
            const protected_paths = try manifest_process_lease.pinnedPaths(self, .edge_segment, self.allocator, pinned_manifest_paths);
            defer freeOwnedManifestPathList(self.allocator, protected_paths);
            return gcUnreferencedEdgeSegmentsExcept(self, protected_paths);
        }

        pub fn currentNodeTextRunManifestPath(self: Store, allocator: std.mem.Allocator) !?[]u8 {
            return readNodeTextRunCurrentPath(self, allocator);
        }

        pub fn openRegisteredNodeTextRunRetentionWindow(self: Store, registry: *NodeTextRunRetentionRegistry) !NodeTextRunRegisteredRetentionWindow {
            var acquired = (try manifest_process_lease.acquireCurrent(self, registry.allocator, .node_text_run)) orelse
                return .{ .registry = registry };
            errdefer acquired.deinit();
            const retained_path = try retention.retainOwnedNodeTextRunManifestPath(registry, acquired.takeManifestPath());
            return .{
                .registry = registry,
                .manifest_path = retained_path,
                .process_lease = acquired.takeProcessLease(),
            };
        }

        pub fn gcUnreferencedNodeTextRunsRetainingRegistry(self: Store, registry: *const NodeTextRunRetentionRegistry) !NodeTextRunGcResult {
            const pinned_paths = try registry.activeManifestPaths(self.allocator);
            defer self.allocator.free(pinned_paths);
            return gcUnreferencedNodeTextRunsExcept(self, pinned_paths);
        }

        pub fn gcUnreferencedNodeTextRunsWithProcessLeases(self: Store) !NodeTextRunGcResult {
            return gcUnreferencedNodeTextRunsExceptAndProcessLeases(self, &.{});
        }

        pub fn gcUnreferencedNodeTextRunsExceptAndProcessLeases(self: Store, pinned_manifest_paths: []const []const u8) !NodeTextRunGcResult {
            const protected_paths = try manifest_process_lease.pinnedPaths(self, .node_text_run, self.allocator, pinned_manifest_paths);
            defer freeOwnedManifestPathList(self.allocator, protected_paths);
            return gcUnreferencedNodeTextRunsExcept(self, protected_paths);
        }

        pub fn manifestProcessLeaseDirPath(self: Store, allocator: std.mem.Allocator) ![]u8 {
            return try std.fs.path.join(allocator, &.{ self.dir_path, ".tinykg_leases" });
        }

        pub fn currentManifestPathForProcessLease(
            self: Store,
            allocator: std.mem.Allocator,
            kind: ManifestProcessLeaseKind,
        ) !?[]u8 {
            return switch (kind) {
                .edge_segment => try currentEdgeSegmentManifestPath(self, allocator),
                .node_text_run => try currentNodeTextRunManifestPath(self, allocator),
            };
        }

        pub fn gcUnreferencedEdgeSegmentsExcept(self: Store, pinned_manifest_paths: []const []const u8) !EdgeSegmentGcResult {
            const result = try edge_segment_gc.collect(self, pinned_manifest_paths);
            return .{
                .deleted_segments = result.deleted_segments,
                .deleted_manifests = result.deleted_manifests,
            };
        }

        pub fn autoCompactEdgeSegmentsIfNeeded(self: Store) !bool {
            return edge_segment_maintenance.autoCompactIfNeeded(self);
        }

        pub fn compactEdgeSegmentsBudgeted(self: Store, budget: EdgeSegmentMaintenanceBudget) !EdgeSegmentMaintenanceResult {
            return compactEdgeSegmentsBudgetedExcept(self, budget, &.{});
        }

        pub fn compactEdgeSegmentsBudgetedRetainingRegistry(self: Store, budget: EdgeSegmentMaintenanceBudget, registry: *const EdgeSegmentRetentionRegistry) !EdgeSegmentMaintenanceResult {
            const pinned_paths = try registry.activeManifestPaths(self.allocator);
            defer self.allocator.free(pinned_paths);
            return compactEdgeSegmentsBudgetedExcept(self, budget, pinned_paths);
        }

        pub fn compactEdgeSegmentsBudgetedWithProcessLeases(self: Store, budget: EdgeSegmentMaintenanceBudget) !EdgeSegmentMaintenanceResult {
            return compactEdgeSegmentsBudgetedExceptAndProcessLeases(self, budget, &.{});
        }

        pub fn compactEdgeSegmentsBudgetedExceptAndProcessLeases(
            self: Store,
            budget: EdgeSegmentMaintenanceBudget,
            pinned_manifest_paths: []const []const u8,
        ) !EdgeSegmentMaintenanceResult {
            const protected_paths = try manifest_process_lease.pinnedPaths(self, .edge_segment, self.allocator, pinned_manifest_paths);
            defer freeOwnedManifestPathList(self.allocator, protected_paths);
            return compactEdgeSegmentsBudgetedExcept(self, budget, protected_paths);
        }

        pub fn compactEdgeSegmentsBudgetedExcept(self: Store, budget: EdgeSegmentMaintenanceBudget, pinned_manifest_paths: []const []const u8) !EdgeSegmentMaintenanceResult {
            return edge_segment_maintenance.compactBudgeted(self, budget, pinned_manifest_paths);
        }

        pub fn compactEdgeSegmentManifestRange(
            self: Store,
            segment_dir_path: []const u8,
            entries: []const OwnedEdgeSegmentManifestEntry,
            compact_start: usize,
            compact_count: usize,
            compacted_edges: u64,
        ) !u64 {
            return edge_segment_window_compaction.compact(
                self,
                segment_dir_path,
                entries,
                compact_start,
                compact_count,
                compacted_edges,
            );
        }

        pub fn edgeAutoCompactedSegmentPath(self: Store, total_edges: u64, segment_count: usize, manifest_digest: u64) ![]u8 {
            const parent = try std.fs.path.join(self.allocator, &.{ self.dir_path, "edge_segments" });
            defer self.allocator.free(parent);
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
            const event_bytes = try eventBytes(self);
            const leaf = try std.fmt.allocPrint(self.allocator, "auto-compact-{}-{}-{}-{x}", .{ total_edges, event_bytes, segment_count, manifest_digest });
            defer self.allocator.free(leaf);
            return try std.fs.path.join(self.allocator, &.{ parent, leaf });
        }

        pub fn canAppendEdgeBatchAsSegmentDelta(self: Store, old_meta: IndexMeta, edges: []const graph_mod.Edge) !bool {
            if (edges.len == 0) return false;
            const summary_current = try edgeSegmentMetaSummaryCurrent(self, old_meta);
            var manifest_found = summary_current;
            const manifest_edges = if (summary_current) old_meta.edge_segment_edges else blk: {
                var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                    error.FileNotFound => {
                        manifest_found = false;
                        break :blk @as(u64, 0);
                    },
                    else => |e| return e,
                };
                defer manifest.deinit(self.allocator);
                break :blk manifest.totalEdgeCount();
            };
            if (!manifest_found and old_meta.edge_indexed_edges < implicit_edge_delta_segment_min_base_edges) return false;
            if (try edgeSegmentManifestCoveredPhysicalEdges(self, old_meta, manifest_edges) == null) return false;
            if (try edgeIndexTailExceedsHighWater(self, old_meta)) return false;
            return try edgeBatchIdsAreNewForSegmentDelta(self, old_meta, edges, summary_current);
        }

        pub fn edgeBatchIdsAreNewForSegmentDelta(self: Store, meta: IndexMeta, edges: []const graph_mod.Edge, edge_segment_summary_current: bool) !bool {
            if (edges.len == 0) return true;
            var sorted_previous: u64 = 0;
            var sorted_candidate_min: u64 = std.math.maxInt(u64);
            var sorted_candidate_max: u64 = 0;
            var sorted_candidate_count: usize = 0;
            var sorted_needs_existing_check = false;
            for (edges, 0..) |edge, index| {
                const id = edge.id.toInt();
                if (id == 0 or id == std.math.maxInt(u64)) return false;
                if (index != 0 and id <= sorted_previous) break;
                if (id <= meta.max_edge_id_seen) {
                    sorted_needs_existing_check = true;
                    sorted_candidate_count += 1;
                    sorted_candidate_min = @min(sorted_candidate_min, id);
                    sorted_candidate_max = @max(sorted_candidate_max, id);
                }
                sorted_previous = id;
            } else {
                if (sorted_needs_existing_check) {
                    if (self.edge_batch_segment_delta_stats) |delta_stats| {
                        delta_stats.slow_path_batches += 1;
                        delta_stats.slow_path_sorted_batches += 1;
                        delta_stats.slow_path_candidate_ids += sorted_candidate_count;
                    }

                    var existing_candidates = std.ArrayList(u64).empty;
                    defer existing_candidates.deinit(self.allocator);
                    try existing_candidates.ensureTotalCapacity(self.allocator, sorted_candidate_count);
                    for (edges) |edge| {
                        const id = edge.id.toInt();
                        if (id <= meta.max_edge_id_seen) existing_candidates.appendAssumeCapacity(id);
                    }
                    return try edgeSortedCandidateIdsAreNewForSegmentDelta(
                        self,
                        meta,
                        existing_candidates.items,
                        sorted_candidate_min,
                        sorted_candidate_max,
                        edge_segment_summary_current,
                    );
                }
                if (self.edge_batch_segment_delta_stats) |delta_stats| delta_stats.fast_path_batches += 1;
                return true;
            }

            var seen = std.AutoHashMap(u64, void).init(self.allocator);
            defer seen.deinit();
            try seen.ensureTotalCapacity(@intCast(edges.len));
            var candidate_min: u64 = std.math.maxInt(u64);
            var candidate_max: u64 = 0;
            var candidate_count: usize = 0;
            var needs_existing_check = false;
            for (edges) |edge| {
                const id = edge.id.toInt();
                if (id == 0 or id == std.math.maxInt(u64)) return false;
                if (id <= meta.max_edge_id_seen) {
                    needs_existing_check = true;
                    candidate_count += 1;
                    candidate_min = @min(candidate_min, id);
                    candidate_max = @max(candidate_max, id);
                }
                const entry = try seen.getOrPut(id);
                if (entry.found_existing) return false;
            }
            if (!needs_existing_check) return true;
            if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.slow_path_batches += 1;
                delta_stats.slow_path_candidate_ids += candidate_count;
            }

            var existing_candidates = std.ArrayList(u64).empty;
            defer existing_candidates.deinit(self.allocator);
            try existing_candidates.ensureTotalCapacity(self.allocator, candidate_count);
            for (edges) |edge| {
                const id = edge.id.toInt();
                if (id <= meta.max_edge_id_seen) existing_candidates.appendAssumeCapacity(id);
            }
            std.mem.sort(u64, existing_candidates.items, {}, u64LessThan);

            return try edgeSortedCandidateIdsAreNewForSegmentDelta(self, meta, existing_candidates.items, candidate_min, candidate_max, edge_segment_summary_current);
        }

        pub fn edgeSortedCandidateIdsAreNewForSegmentDelta(
            self: Store,
            meta: IndexMeta,
            existing_candidates: []const u64,
            candidate_min: u64,
            candidate_max: u64,
            edge_segment_summary_current: bool,
        ) !bool {
            var id_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer id_file.close(self.io);
            const id_header = try validateEdgeIndexHeaderForAppend(self, id_file, .id, meta);
            const base_check_start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
            var base_candidate_checks: usize = existing_candidates.len;
            const base_intersects = blk: {
                if (try edgeIdRunSummaryMatchesFile(self, id_file, id_header, meta.edge_by_id_runs)) {
                    base_candidate_checks = meta.edge_by_id_runs.intersectingSortedIdCount(existing_candidates);
                    break :blk base_candidate_checks != 0;
                }
                break :blk try edgeIdSortedSetIntersectsFile(self, id_file, id_header, existing_candidates);
            };
            if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.base_id_checks += base_candidate_checks;
                delta_stats.base_id_check_ns += storageElapsedNs(self.io, base_check_start);
            }
            if (base_intersects) return false;
            if (try edgeIdSetIntersectsTombstones(self, existing_candidates)) return false;
            const overlay_check_start = if (self.edge_batch_segment_delta_stats != null) storageMonotonicNs(self.io) else 0;
            defer if (self.edge_batch_segment_delta_stats) |delta_stats| {
                delta_stats.overlay_checks += 1;
                delta_stats.overlay_check_ns += storageElapsedNs(self.io, overlay_check_start);
            };
            if (try edgeIdSetIntersectsSegmentOverlayAfterEligibility(self, meta, existing_candidates, candidate_min, candidate_max, edge_segment_summary_current)) return false;
            return true;
        }

        pub fn edgeIdSetIntersectsTombstones(self: Store, ids_by_id: []const u64) !bool {
            if (ids_by_id.len == 0) return false;
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            if (tombstone_header.count == 0) return false;
            var tombstones = try EdgeTombstoneIndexView.open(self);
            defer tombstones.deinit();
            for (ids_by_id) |edge_id| {
                if (try tombstones.contains(edge_id)) return true;
            }
            return false;
        }

        pub fn edgeSegmentManifestCoveredPhysicalEdges(self: Store, meta: IndexMeta, manifest_edges: u64) !?u64 {
            const physical_edges = try visiblePlusTombstoneEdgeCount(self, meta);
            if (manifest_edges == physical_edges) return physical_edges;
            if (meta.edge_indexed_edges > physical_edges) return null;
            if (manifest_edges == physical_edges - meta.edge_indexed_edges) {
                if (!try edgeIndexBaseHeadersMatchMeta(self, meta)) return null;
                return physical_edges;
            }
            return null;
        }

        pub fn edgeSegmentManifestCoversVisibleEdges(self: Store, meta: IndexMeta, manifest_edges: u64) !bool {
            if (manifest_edges != meta.edges) return false;
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            return tombstone_header.count != 0;
        }

        pub fn edgeSegmentManifestMatchesMeta(self: Store, meta: IndexMeta) !bool {
            return try edgeSegmentManifestMatchesMetaWithTimings(self, meta, null);
        }

        pub fn edgeSegmentManifestMatchesMetaWithTimings(self: Store, meta: IndexMeta, timings: ?*PersistentValidateTimings) !bool {
            const manifest_read_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);
            if (timings) |t| t.edge_segment_manifest_read_ns = storageElapsedNs(self.io, manifest_read_start);
            const manifest_edges = manifest.totalEdgeCount();
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            const physical_edges = try edgeSegmentManifestCoveredPhysicalEdges(self, meta, manifest_edges);
            const visible_full = tombstone_header.count != 0 and manifest_edges == meta.edges;
            if (physical_edges == null and !visible_full) return false;
            const segment_open_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            var segments = PublishedEdgeSegments.init(self.allocator);
            try segments.openTrustedEntriesForQuery(self.io, manifest.entries.items);
            defer segments.deinit();
            if (timings) |t| t.edge_segment_open_ns = storageElapsedNs(self.io, segment_open_start);
            const segment_digest_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const segment_digest = edgeSegmentManifestOwnedEdgeDigest(manifest.entries.items);
            if (timings) |t| t.edge_segment_digest_ns = storageElapsedNs(self.io, segment_digest_start);
            if (visible_full and segment_digest == meta.edge_digest) return true;
            const covered_edges = physical_edges orelse return false;
            const physical_digest = meta.edge_digest ^ tombstone_header.digest;
            if (manifest_edges == covered_edges) return segment_digest == physical_digest;
            return (meta.edge_index_digest ^ segment_digest) == physical_digest;
        }

        pub fn forEachPublishedEdgeSegmentNeighbor(
            self: Store,
            direction: segment_mod.Direction,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            max_edges: usize,
            context: anytype,
            comptime callback: fn (@TypeOf(context), segment_mod.EdgeRecord) anyerror!bool,
        ) !?bool {
            var segments = (try openPublishedEdgeSegments(self, self.allocator)) orelse return null;
            defer segments.deinit();
            return try forEachOpenedPublishedEdgeSegmentNeighbor(self, &segments, direction, node_id, rel_filter, max_edges, context, callback);
        }

        pub fn forEachOpenedPublishedEdgeSegmentNeighbor(
            self: Store,
            segments: *PublishedEdgeSegments,
            direction: segment_mod.Direction,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            max_edges: usize,
            context: anytype,
            comptime callback: fn (@TypeOf(context), segment_mod.EdgeRecord) anyerror!bool,
        ) !bool {
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            if (tombstone_header.count == 0) {
                return try segments.forEachNeighbor(direction, node_id, rel_filter, max_edges, context, callback);
            }
            var tombstone_view = try EdgeTombstoneIndexView.open(self);
            defer tombstone_view.deinit();
            const Wrapper = struct {
                tombstones: *EdgeTombstoneIndexView,
                context: @TypeOf(context),

                fn visit(wrapper: *@This(), edge: segment_mod.EdgeRecord) !bool {
                    if (try wrapper.tombstones.contains(edge.edge_id.toInt())) return false;
                    return try callback(wrapper.context, edge);
                }
            };
            var wrapper = Wrapper{ .tombstones = &tombstone_view, .context = context };
            return try segments.forEachNeighbor(direction, node_id, rel_filter, max_edges, &wrapper, Wrapper.visit);
        }

        pub fn openPublishedEdgeSegment(self: Store, allocator: std.mem.Allocator) !?segment_mod.ImmutableAdjacencySegment {
            var segments = (try openPublishedEdgeSegments(self, allocator)) orelse return null;
            errdefer segments.deinit();
            if (segments.segments.items.len != 1 or segments.virtual_edges.items.len != 0) {
                segments.deinit();
                return null;
            }
            const segment = segments.segments.items[0];
            segments.segments.clearRetainingCapacity();
            segments.deinit();
            return segment;
        }

        pub fn openPublishedEdgeSegments(self: Store, allocator: std.mem.Allocator) !?PublishedEdgeSegments {
            var manifest = readEdgeSegmentManifest(self, allocator) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer manifest.deinit(allocator);
            const meta = try readCurrentIndexMeta(self);
            if (manifest.totalEdgeCount() != try visiblePlusTombstoneEdgeCount(self, meta)) return null;

            var segments = PublishedEdgeSegments.init(allocator);
            errdefer segments.deinit();
            try segments.openEntries(self.io, manifest.entries.items);
            return segments;
        }

        pub fn openPublishedEdgeSegmentsForQuery(self: Store, allocator: std.mem.Allocator) !?PublishedEdgeSegmentsForQuery {
            return edge_segment_query_opening.openCurrent(self, allocator, null, null);
        }

        pub fn openPublishedEdgeSegmentsForQueryRetained(
            self: Store,
            allocator: std.mem.Allocator,
            registry: *EdgeSegmentRetentionRegistry,
        ) !?PublishedEdgeSegmentsForQuery {
            return edge_segment_query_opening.openRetained(self, allocator, registry, null, null);
        }

        pub fn openPublishedEdgeSegmentsForQueryForNode(
            self: Store,
            allocator: std.mem.Allocator,
            direction: segment_mod.Direction,
            node_id: core.NodeId,
        ) !?PublishedEdgeSegmentsForQuery {
            return edge_segment_query_opening.openCurrent(self, allocator, direction, node_id);
        }

        pub fn openPublishedEdgeSegmentsForQueryForNodeRetained(
            self: Store,
            allocator: std.mem.Allocator,
            registry: *EdgeSegmentRetentionRegistry,
            direction: segment_mod.Direction,
            node_id: core.NodeId,
        ) !?PublishedEdgeSegmentsForQuery {
            return edge_segment_query_opening.openRetained(self, allocator, registry, direction, node_id);
        }

        pub fn openPublishedEdgeSegmentDataForQuery(
            self: Store,
            allocator: std.mem.Allocator,
            manifest: *const EdgeSegmentManifest,
            coverage: PublishedEdgeSegmentsCoverage,
            filter_direction: ?segment_mod.Direction,
            filter_node_id: ?core.NodeId,
            filtered: bool,
        ) !?PublishedEdgeSegmentsForQuery {
            var segments = PublishedEdgeSegments.init(allocator);
            errdefer segments.deinit();
            const node_id = if (filter_node_id) |id| id.toInt() else 0;
            const segment_capacity = if (filtered) blk: {
                var matching: usize = 0;
                for (manifest.entries.items) |entry| {
                    if (edgeSegmentManifestEntryMayContainNode(entry, filter_direction.?, node_id)) matching += 1;
                }
                break :blk matching;
            } else manifest.entries.items.len;
            try segments.segments.ensureTotalCapacityPrecise(allocator, segment_capacity);
            if (self.options.validate_indexes_on_read) {
                for (manifest.entries.items) |entry| {
                    if (filtered and !edgeSegmentManifestEntryMayContainNode(entry, filter_direction.?, node_id)) continue;
                    try segments.openEntry(self.io, entry);
                }
            } else {
                for (manifest.entries.items) |entry| {
                    if (filtered and !edgeSegmentManifestEntryMayContainNode(entry, filter_direction.?, node_id)) continue;
                    if (coverage == .visible_full) {
                        try segments.openTrustedEntryForQuery(self.io, entry);
                    } else if (filter_direction) |direction| {
                        try segments.openTrustedEntryDirectionForQuery(self.io, entry, direction);
                    } else {
                        try segments.openTrustedEntryForQuery(self.io, entry);
                    }
                }
            }
            return .{ .segments = segments, .coverage = coverage };
        }

        pub fn writeEdgeSegmentManifest(
            self: Store,
            segment_dir_path: []const u8,
            edge_digest: u64,
            edge_id_summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
            endpoint_summary: segment_mod.ImmutableAdjacencySegment.EndpointSummary,
            edge_id_order_digest: u64,
            edge_id_runs: EdgeSegmentIdRunSummary,
        ) !EdgeSegmentManifestSummary {
            const entry = EdgeSegmentManifestEntry{
                .edge_count = edge_id_summary.count,
                .edge_digest = edge_digest,
                .edge_id_range = edge_id_summary.range,
                .edge_id_digest = edge_id_summary.digest,
                .edge_id_order_digest = edge_id_order_digest,
                .edge_id_runs = edge_id_runs,
                .src_node_range = endpoint_summary.src_range,
                .dst_node_range = endpoint_summary.dst_range,
                .path = segment_dir_path,
            };
            try writeEdgeSegmentManifestEntries(self, &.{entry});
            return try edgeSegmentManifestSummary(self, &.{entry});
        }

        pub fn edgeSegmentManifestTotalEdges(entries: []const EdgeSegmentManifestEntry) !u64 {
            return edge_segment_manifest_format.totalEdges(entries);
        }

        pub fn edgeSegmentManifestSummary(self: Store, entries: []const EdgeSegmentManifestEntry) !EdgeSegmentManifestSummary {
            return .{
                .total_edges = try edgeSegmentManifestTotalEdges(entries),
                .manifest_digest = try edgeSegmentManifestDigest(self, entries),
                .edge_id_runs = try edgeSegmentManifestIdRunSummary(self.allocator, entries),
            };
        }

        pub fn edgeSegmentManifestIdRunSummary(allocator: std.mem.Allocator, entries: anytype) !EdgeSegmentIdRunSummary {
            var stream_builder = EdgeSegmentIdRunBuilder{};
            var previous_max: u64 = 0;
            var has_previous = false;
            var stream_sorted = true;
            for (entries) |entry| {
                const covered_count = try entry.edge_id_runs.coveredCount();
                if (covered_count != entry.edge_count) return .{};
                switch (entry.edge_id_runs.run_count) {
                    0 => return .{},
                    1 => if (!appendEdgeSegmentManifestRunRangeSorted(
                        &stream_builder,
                        &has_previous,
                        &previous_max,
                        entry.edge_id_runs.first_min,
                        entry.edge_id_runs.first_max,
                    )) {
                        stream_sorted = false;
                        break;
                    },
                    2 => {
                        if (!appendEdgeSegmentManifestRunRangeSorted(
                            &stream_builder,
                            &has_previous,
                            &previous_max,
                            entry.edge_id_runs.first_min,
                            entry.edge_id_runs.first_max,
                        )) {
                            stream_sorted = false;
                            break;
                        }
                        if (!appendEdgeSegmentManifestRunRangeSorted(
                            &stream_builder,
                            &has_previous,
                            &previous_max,
                            entry.edge_id_runs.second_min,
                            entry.edge_id_runs.second_max,
                        )) {
                            stream_sorted = false;
                            break;
                        }
                    },
                    else => return error.InvalidRecord,
                }
            }
            if (stream_sorted) return stream_builder.finish();

            var ranges = std.ArrayList(EdgeSegmentIdRunRange).empty;
            defer ranges.deinit(allocator);
            const max_ranges = std.math.mul(usize, entries.len, 2) catch return error.RecordTooLarge;
            try ranges.ensureTotalCapacity(allocator, max_ranges);
            for (entries) |entry| {
                const covered_count = try entry.edge_id_runs.coveredCount();
                if (covered_count != entry.edge_count) return .{};
                switch (entry.edge_id_runs.run_count) {
                    0 => return .{},
                    1 => ranges.appendAssumeCapacity(.{
                        .min = entry.edge_id_runs.first_min,
                        .max = entry.edge_id_runs.first_max,
                    }),
                    2 => {
                        ranges.appendAssumeCapacity(.{
                            .min = entry.edge_id_runs.first_min,
                            .max = entry.edge_id_runs.first_max,
                        });
                        ranges.appendAssumeCapacity(.{
                            .min = entry.edge_id_runs.second_min,
                            .max = entry.edge_id_runs.second_max,
                        });
                    },
                    else => return error.InvalidRecord,
                }
            }
            std.mem.sort(EdgeSegmentIdRunRange, ranges.items, {}, edgeSegmentIdRunRangeLessThan);
            var builder = EdgeSegmentIdRunBuilder{};
            for (ranges.items) |range| builder.addRange(range.min, range.max);
            return builder.finish();
        }

        pub fn setEdgeSegmentSummary(meta: *IndexMeta, summary: EdgeSegmentManifestSummary) void {
            meta.edge_segment_edges = summary.total_edges;
            meta.edge_segment_manifest_digest = summary.manifest_digest;
            meta.edge_segment_id_runs = summary.edge_id_runs;
        }

        pub fn updateIndexMetaEdgeSegmentSummary(self: Store, summary: EdgeSegmentManifestSummary) !void {
            var meta = try readIndexMeta(self);
            setEdgeSegmentSummary(&meta, summary);
            try writeIndexMeta(self, meta);
        }

        pub fn writeEdgeSegmentManifestEntries(self: Store, entries: []const EdgeSegmentManifestEntry) !void {
            try edge_segment_publication.publish(self, entries);
        }

        pub fn updateEdgeSegmentManifestDigestFields(hasher: *std.hash.Wyhash, entry: anytype) void {
            edge_segment_manifest_format.updateDigestFields(hasher, entry);
        }

        pub fn updateEdgeSegmentManifestDigestEncodedPath(hasher: *std.hash.Wyhash, path_encoding: EdgeSegmentManifestPathEncoding) void {
            edge_segment_manifest_format.updateDigestEncodedPath(hasher, path_encoding);
        }

        pub fn edgeSegmentManifestDigest(self: Store, entries: []const EdgeSegmentManifestEntry) !u64 {
            var hasher = std.hash.Wyhash.init(0x544B_4D46);
            for (entries) |entry| {
                updateEdgeSegmentManifestDigestFields(&hasher, entry);
                updateEdgeSegmentManifestDigestEncodedPath(&hasher, try edgeSegmentManifestPathEncoding(self, entry.path));
            }
            return hasher.final();
        }

        pub fn edgeSegmentManifestOwnedDigest(self: Store, entries: []const OwnedEdgeSegmentManifestEntry) !u64 {
            var hasher = std.hash.Wyhash.init(0x544B_4D46);
            for (entries) |entry| {
                updateEdgeSegmentManifestDigestFields(&hasher, entry);
                updateEdgeSegmentManifestDigestEncodedPath(&hasher, try edgeSegmentManifestPathEncoding(self, entry.path));
            }
            return hasher.final();
        }

        pub fn edgeSegmentManifestOwnedLegacyDigest(entries: []const OwnedEdgeSegmentManifestEntry) u64 {
            return edge_segment_manifest_format.ownedLegacyDigest(entries);
        }

        pub fn edgeSegmentManifestOwnedTotalEdges(entries: []const OwnedEdgeSegmentManifestEntry) ?u64 {
            return edge_segment_manifest_format.ownedTotalEdges(entries);
        }

        pub fn edgeSegmentManifestOwnedEdgeDigest(entries: []const OwnedEdgeSegmentManifestEntry) u64 {
            var digest: u64 = 0;
            for (entries) |entry| digest ^= entry.edge_digest;
            return digest;
        }

        pub fn edgeSegmentManifestEpochPath(self: Store, total_edges: u64, digest: u64) ![]u8 {
            return try edgeSegmentManifestEpochPathWithAllocator(self, self.allocator, total_edges, digest);
        }

        pub fn edgeSegmentManifestEpochPathWithAllocator(self: Store, allocator: std.mem.Allocator, total_edges: u64, digest: u64) ![]u8 {
            return std.fmt.allocPrint(allocator, "{s}.{d}.{x}", .{ self.edge_segment_manifest_path, total_edges, digest });
        }

        pub fn edgeSegmentManifestSegmentRoot(self: Store, allocator: std.mem.Allocator) ![]u8 {
            return try std.fs.path.join(allocator, &.{ self.dir_path, "edge_segments" });
        }

        pub fn edgeSegmentManifestRelativeSuffix(self: Store, segment_path: []const u8) !?[]const u8 {
            const root = try edgeSegmentManifestSegmentRoot(self, self.allocator);
            defer self.allocator.free(root);
            if (!std.mem.startsWith(u8, segment_path, root)) return null;
            if (segment_path.len <= root.len + 1) return null;
            if (!std.fs.path.isSep(segment_path[root.len])) return null;
            const suffix = segment_path[root.len + 1 ..];
            if (!edgeSegmentManifestSafeRelativePath(suffix)) return null;
            return suffix;
        }

        pub fn edgeSegmentManifestPathEncoding(self: Store, segment_path: []const u8) !EdgeSegmentManifestPathEncoding {
            if (segment_path.len == 0) return .{ .flags = 0, .bytes = "" };
            if (try edgeSegmentManifestRelativeSuffix(self, segment_path)) |suffix| {
                return .{ .flags = edge_segment_manifest_path_relative, .bytes = suffix };
            }
            return .{ .flags = 0, .bytes = segment_path };
        }

        pub fn restoreEdgeSegmentManifestPath(self: Store, allocator: std.mem.Allocator, flags: u32, stored_path: []const u8) ![]u8 {
            if ((flags & edge_segment_manifest_path_relative) == 0) {
                if (try edgeSegmentManifestRelativeSuffix(self, stored_path) != null) return error.InvalidRecord;
                return try allocator.dupe(u8, stored_path);
            }
            if (!edgeSegmentManifestSafeRelativePath(stored_path)) return error.InvalidRecord;
            const root = try edgeSegmentManifestSegmentRoot(self, allocator);
            defer allocator.free(root);
            return try std.fs.path.join(allocator, &.{ root, stored_path });
        }

        pub fn writeEdgeSegmentManifestFile(self: Store, manifest_path: []const u8, entries: []const EdgeSegmentManifestEntry) !void {
            const tmp_path = try tmpPathFor(self, manifest_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(self.io);
                var offset: u64 = 0;
                var header: [EdgeSegmentManifest.header_len]u8 = undefined;
                try encodeEdgeSegmentManifestHeader(entries, &header);
                try file.writePositionalAll(self.io, &header, offset);
                offset += header.len;

                var entry_header: [EdgeSegmentManifest.entry_header_len]u8 = undefined;
                for (entries) |entry| {
                    const path_encoding = try edgeSegmentManifestPathEncoding(self, entry.path);
                    try encodeEdgeSegmentManifestEntryHeaderForPath(entry, path_encoding.bytes.len, path_encoding.flags, &entry_header);
                    try file.writePositionalAll(self.io, &entry_header, offset);
                    offset += entry_header.len;
                    var edge_digest_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &edge_digest_bytes, entry.edge_digest, .little);
                    try file.writePositionalAll(self.io, &edge_digest_bytes, offset);
                    offset += edge_digest_bytes.len;
                    const entry_flags = std.mem.readInt(u32, entry_header[4..8], .little);
                    offset = try writeEdgeSegmentManifestOrderDigestExtra(self.io, file, offset, entry, entry_flags);
                    offset = try writeEdgeSegmentManifestRunExtra(self.io, file, offset, try encodeEdgeSegmentManifestRunEncoding(entry));
                    offset = try writeEdgeSegmentManifestEdgeCountExtra(self.io, file, offset, entry, entry_flags);
                    offset = try writeEdgeSegmentManifestDigestExtra(self.io, file, offset, entry, entry_flags);
                    offset = try writeEdgeSegmentManifestEndpointExtra(self.io, file, offset, try encodeEdgeSegmentManifestEndpointEncoding(entry));
                    offset = try writeEdgeSegmentManifestSingletonRelExtra(self.io, file, offset, entry, entry_flags);
                    try file.writePositionalAll(self.io, path_encoding.bytes, offset);
                    offset = std.math.add(u64, offset, path_encoding.bytes.len) catch return error.RecordTooLarge;
                }
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, manifest_path);
        }

        pub fn edgeSegmentIdIndexPath(self: Store, segment_dir_path: []const u8) ![]u8 {
            return std.fs.path.join(self.allocator, &.{ segment_dir_path, "edge_ids.idx" });
        }

        const edge_segment_id_index = Ops.dep_owners.edge_segment_id_index_owner;
        pub const writeEdgeSegmentIdIndexFromSegment = edge_segment_id_index.writeEdgeSegmentIdIndexFromSegment;
        pub const buildEdgeSegmentIdSortedRunsFromSpool = edge_segment_id_index.buildEdgeSegmentIdSortedRunsFromSpool;
        pub const readEdgeSegmentIdSpoolChunk = edge_segment_id_index.readEdgeSegmentIdSpoolChunk;
        pub const writeEdgeSegmentIdIndexFromSingleSpoolChunk = edge_segment_id_index.writeEdgeSegmentIdIndexFromSingleSpoolChunk;
        pub const writeEdgeSegmentIdIndexFromSortedIds = edge_segment_id_index.writeEdgeSegmentIdIndexFromSortedIds;
        pub const writeEdgeSegmentIdRunFile = edge_segment_id_index.writeEdgeSegmentIdRunFile;
        pub const writeEdgeSegmentIdIndexFromRunFiles = edge_segment_id_index.writeEdgeSegmentIdIndexFromRunFiles;
        pub const writeEdgeSegmentIdIndexFromRecords = edge_segment_id_index.writeEdgeSegmentIdIndexFromRecords;
        pub const writeEdgeSegmentIdIndexFromEdgeIndexReader = edge_segment_id_index.writeEdgeSegmentIdIndexFromEdgeIndexReader;
        pub const compareEdgeSegmentIdIndexRunHeapEntry = edge_segment_id_index.compareEdgeSegmentIdIndexRunHeapEntry;
        pub const writeEdgeSegmentIdIndexFromManifestEntries = edge_segment_id_index.writeEdgeSegmentIdIndexFromManifestEntries;
        pub const beginEdgeSegmentIdIndexFile = edge_segment_id_index.beginEdgeSegmentIdIndexFile;
        pub const edgeSegmentIdIndexContains = edge_segment_id_index.edgeSegmentIdIndexContains;
        pub const edgeSegmentIdIndexIntersects = edge_segment_id_index.edgeSegmentIdIndexIntersects;
        pub const trustedSingletonEdgeSegmentId = edge_segment_id_index.trustedSingletonEdgeSegmentId;
        pub const trustedRunSummaryMayIntersect = edge_segment_id_index.trustedRunSummaryMayIntersect;
        pub const validateTrustedRunSummary = edge_segment_id_index.validateTrustedRunSummary;
        pub const validateEdgeSegmentIdIndexHeader = edge_segment_id_index.validateEdgeSegmentIdIndexHeader;
        pub const edgeSegmentIdIndexContainsInFile = edge_segment_id_index.edgeSegmentIdIndexContainsInFile;
        pub const edgeSegmentIdIndexIntersectsSortedInFile = edge_segment_id_index.edgeSegmentIdIndexIntersectsSortedInFile;
        pub const edgeSegmentIdIndexIntersectsSmallSortedInFile = edge_segment_id_index.edgeSegmentIdIndexIntersectsSmallSortedInFile;
        pub const edgeSegmentIdIndexLowerBoundInFile = edge_segment_id_index.edgeSegmentIdIndexLowerBoundInFile;
        pub const edgeSegmentIdIndexLowerBoundInFileFrom = edge_segment_id_index.edgeSegmentIdIndexLowerBoundInFileFrom;
        pub const readEdgeSegmentIdIndexRecordAt = edge_segment_id_index.readEdgeSegmentIdIndexRecordAt;

        pub fn writeEdgeSegmentCurrent(self: Store, manifest_path: []const u8) !void {
            const manifest_leaf = std.fs.path.basename(manifest_path);
            if (manifest_leaf.len == 0 or manifest_leaf.len > edge_segment_current_max_path_bytes) return error.RecordTooLarge;
            const tmp_path = try tmpPathFor(self, self.edge_segment_current_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(self.io);
                try file.writePositionalAll(self.io, manifest_leaf, 0);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.edge_segment_current_path);
        }

        pub fn readEdgeSegmentManifest(self: Store, allocator: std.mem.Allocator) !EdgeSegmentManifest {
            if (try readEdgeSegmentCurrentPath(self, allocator)) |manifest_path| {
                defer allocator.free(manifest_path);
                return readEdgeSegmentManifestAtPath(self, allocator, manifest_path) catch |err| switch (err) {
                    error.FileNotFound => error.InvalidRecord,
                    else => |e| e,
                };
            }
            return error.FileNotFound;
        }

        pub fn readEdgeSegmentManifestAtPath(self: Store, allocator: std.mem.Allocator, manifest_path: []const u8) !EdgeSegmentManifest {
            var manifest = try readEdgeSegmentManifestFile(self, allocator, manifest_path);
            errdefer manifest.deinit(allocator);
            try validateEdgeSegmentManifestPath(self, allocator, manifest_path, manifest.entries.items);
            manifest.ranges_trusted = true;
            return manifest;
        }

        pub fn validateEdgeSegmentManifestPath(
            self: Store,
            allocator: std.mem.Allocator,
            manifest_path: []const u8,
            entries: []const OwnedEdgeSegmentManifestEntry,
        ) !void {
            const total_edges = edgeSegmentManifestOwnedTotalEdges(entries) orelse return error.InvalidRecord;
            const digest = try edgeSegmentManifestOwnedDigest(self, entries);
            const expected_path = try edgeSegmentManifestEpochPathWithAllocator(self, allocator, total_edges, digest);
            defer allocator.free(expected_path);
            if (std.mem.eql(u8, manifest_path, expected_path)) return;
            const legacy_digest = edgeSegmentManifestOwnedLegacyDigest(entries);
            const legacy_expected_path = try edgeSegmentManifestEpochPathWithAllocator(self, allocator, total_edges, legacy_digest);
            defer allocator.free(legacy_expected_path);
            if (!std.mem.eql(u8, manifest_path, legacy_expected_path)) return error.InvalidRecord;
        }

        pub fn readEdgeSegmentCurrentPath(self: Store, allocator: std.mem.Allocator) !?[]u8 {
            var file = std.Io.Dir.cwd().openFile(self.io, self.edge_segment_current_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (file_size == 0 or file_size > edge_segment_current_max_path_bytes) return error.InvalidRecord;
            const path_len = std.math.cast(usize, file_size) orelse return error.InvalidRecord;
            const path = try allocator.alloc(u8, path_len);
            errdefer allocator.free(path);
            const n = try file.readPositionalAll(self.io, path, 0);
            if (n != path.len) return error.InvalidRecord;
            if (std.mem.eql(u8, path, std.fs.path.basename(path))) {
                const resolved_path = try std.fs.path.join(allocator, &.{ self.dir_path, path });
                allocator.free(path);
                return resolved_path;
            }
            if (!std.fs.path.isAbsolute(path)) return error.InvalidRecord;
            return path;
        }

        pub fn readEdgeSegmentManifestFile(self: Store, allocator: std.mem.Allocator, manifest_path: []const u8) !EdgeSegmentManifest {
            var file = try std.Io.Dir.cwd().openFile(self.io, manifest_path, .{});
            defer file.close(self.io);
            const file_size = try regularFileSize(self, file);
            if (file_size < EdgeSegmentManifest.header_len) return error.InvalidRecord;
            var header_bytes: [EdgeSegmentManifest.header_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &header_bytes, 0);
            if (n != header_bytes.len) return error.InvalidRecord;
            const header = try decodeEdgeSegmentManifestHeader(&header_bytes);
            var manifest = EdgeSegmentManifest{};
            errdefer manifest.deinit(allocator);
            try manifest.entries.ensureTotalCapacity(allocator, header.segment_count);

            var offset: u64 = EdgeSegmentManifest.header_len;
            var total_edges: u64 = 0;
            var entry_index: u32 = 0;
            while (entry_index < header.segment_count) : (entry_index += 1) {
                const entry_header_end = std.math.add(u64, offset, EdgeSegmentManifest.entry_header_len) catch return error.InvalidRecord;
                if (entry_header_end > file_size) return error.InvalidRecord;
                var entry_header_bytes: [EdgeSegmentManifest.entry_header_len]u8 = undefined;
                const entry_n = try file.readPositionalAll(self.io, &entry_header_bytes, offset);
                if (entry_n != entry_header_bytes.len) return error.InvalidRecord;
                offset = entry_header_end;
                const entry_header = try decodeEdgeSegmentManifestEntryHeader(&entry_header_bytes);
                const edge_digest_end = std.math.add(u64, offset, 8) catch return error.InvalidRecord;
                if (edge_digest_end > file_size) return error.InvalidRecord;
                var edge_digest_bytes: [8]u8 = undefined;
                const edge_digest_n = try file.readPositionalAll(self.io, &edge_digest_bytes, offset);
                if (edge_digest_n != edge_digest_bytes.len) return error.InvalidRecord;
                const edge_digest = std.mem.readInt(u64, &edge_digest_bytes, .little);
                offset = edge_digest_end;
                const order_digest_extra_len = try edgeSegmentManifestOrderDigestExtraLen(entry_header.entry_flags);
                var edge_id_order_digest: u64 = 0;
                if (order_digest_extra_len != 0) {
                    const order_digest_extra_end = std.math.add(u64, offset, order_digest_extra_len) catch return error.InvalidRecord;
                    if (order_digest_extra_end > file_size) return error.InvalidRecord;
                    var order_digest_extra: [8]u8 = undefined;
                    const order_digest_extra_n = try file.readPositionalAll(self.io, &order_digest_extra, offset);
                    if (order_digest_extra_n != order_digest_extra.len) return error.InvalidRecord;
                    edge_id_order_digest = std.mem.readInt(u64, &order_digest_extra, .little);
                    if (edge_id_order_digest == 0) return error.InvalidRecord;
                    offset = order_digest_extra_end;
                }
                const run_extra_len = try edgeSegmentManifestRunExtraLen(entry_header.entry_flags);
                var first_max: u64 = 0;
                var second_min: u64 = 0;
                if (run_extra_len != 0) {
                    const run_extra_end = std.math.add(u64, offset, run_extra_len) catch return error.InvalidRecord;
                    if (run_extra_end > file_size) return error.InvalidRecord;
                    var run_extra: [16]u8 = undefined;
                    const run_extra_n = try file.readPositionalAll(self.io, run_extra[0..run_extra_len], offset);
                    if (run_extra_n != run_extra_len) return error.InvalidRecord;
                    first_max = std.mem.readInt(u64, run_extra[0..8], .little);
                    second_min = std.mem.readInt(u64, run_extra[8..16], .little);
                    offset = run_extra_end;
                }
                const edge_count_extra_len = try edgeSegmentManifestEdgeCountExtraLen(entry_header.entry_flags);
                const edge_count = if (edge_count_extra_len != 0) count: {
                    const edge_count_extra_end = std.math.add(u64, offset, edge_count_extra_len) catch return error.InvalidRecord;
                    if (edge_count_extra_end > file_size) return error.InvalidRecord;
                    var edge_count_extra: [8]u8 = undefined;
                    const edge_count_extra_n = try file.readPositionalAll(self.io, &edge_count_extra, offset);
                    if (edge_count_extra_n != edge_count_extra.len) return error.InvalidRecord;
                    const explicit_edge_count = std.mem.readInt(u64, &edge_count_extra, .little);
                    if (explicit_edge_count == 0) return error.InvalidRecord;
                    offset = edge_count_extra_end;
                    break :count explicit_edge_count;
                } else try deriveEdgeSegmentManifestEdgeCountFromRunEncoding(entry_header.edge_id_range, entry_header.entry_flags, first_max, second_min);
                const edge_id_runs = try decodeEdgeSegmentManifestRunEncoding(edge_count, entry_header.edge_id_range, entry_header.entry_flags, first_max, second_min);
                const digest_extra_len = try edgeSegmentManifestDigestExtraLen(entry_header.entry_flags);
                var edge_id_digest: u64 = 0;
                if (digest_extra_len != 0) {
                    const digest_extra_end = std.math.add(u64, offset, digest_extra_len) catch return error.InvalidRecord;
                    if (digest_extra_end > file_size) return error.InvalidRecord;
                    var digest_extra: [8]u8 = undefined;
                    const digest_extra_n = try file.readPositionalAll(self.io, &digest_extra, offset);
                    if (digest_extra_n != digest_extra.len) return error.InvalidRecord;
                    if (edge_id_order_digest == 0 and edgeSegmentManifestRunsCoverEntry(edge_count, entry_header.edge_id_range, edge_id_runs)) {
                        return error.InvalidRecord;
                    }
                    edge_id_digest = std.mem.readInt(u64, &digest_extra, .little);
                    offset = digest_extra_end;
                } else if (!edgeSegmentManifestRunsCoverEntry(edge_count, entry_header.edge_id_range, edge_id_runs) or edge_id_order_digest != 0) {
                    return error.InvalidRecord;
                }
                const endpoint_extra_len = try edgeSegmentManifestEndpointExtraLen(entry_header.entry_flags);
                var src_node_min: u64 = 0;
                var src_node_max: u64 = 0;
                var dst_node_min: u64 = 0;
                var dst_node_max: u64 = 0;
                if (endpoint_extra_len != 0) {
                    const endpoint_extra_end = std.math.add(u64, offset, endpoint_extra_len) catch return error.InvalidRecord;
                    if (endpoint_extra_end > file_size) return error.InvalidRecord;
                    var endpoint_extra: [32]u8 = undefined;
                    const endpoint_extra_n = try file.readPositionalAll(self.io, endpoint_extra[0..endpoint_extra_len], offset);
                    if (endpoint_extra_n != endpoint_extra_len) return error.InvalidRecord;
                    var endpoint_extra_pos: usize = 0;
                    if ((entry_header.entry_flags & edge_segment_manifest_src_full) == 0) {
                        src_node_min = std.mem.readInt(u64, endpoint_extra[endpoint_extra_pos..][0..8], .little);
                        endpoint_extra_pos += 8;
                    }
                    if ((entry_header.entry_flags & (edge_segment_manifest_src_single | edge_segment_manifest_src_full)) == 0) {
                        src_node_max = std.mem.readInt(u64, endpoint_extra[endpoint_extra_pos..][0..8], .little);
                        endpoint_extra_pos += 8;
                    }
                    if ((entry_header.entry_flags & edge_segment_manifest_dst_full) == 0) {
                        dst_node_min = std.mem.readInt(u64, endpoint_extra[endpoint_extra_pos..][0..8], .little);
                        endpoint_extra_pos += 8;
                    }
                    if ((entry_header.entry_flags & (edge_segment_manifest_dst_single | edge_segment_manifest_dst_full)) == 0) {
                        dst_node_max = std.mem.readInt(u64, endpoint_extra[endpoint_extra_pos..][0..8], .little);
                        endpoint_extra_pos += 8;
                    }
                    if (endpoint_extra_pos != endpoint_extra_len) return error.InvalidRecord;
                    offset = endpoint_extra_end;
                }
                const endpoint_ranges = try decodeEdgeSegmentManifestEndpointRanges(
                    entry_header.entry_flags,
                    src_node_min,
                    dst_node_min,
                    src_node_max,
                    dst_node_max,
                );
                const singleton_rel_extra_len = try edgeSegmentManifestSingletonRelExtraLen(entry_header.entry_flags);
                var singleton_rel: ?core.RelKind = null;
                if (singleton_rel_extra_len != 0) {
                    const singleton_rel_extra_end = std.math.add(u64, offset, singleton_rel_extra_len) catch return error.InvalidRecord;
                    if (singleton_rel_extra_end > file_size) return error.InvalidRecord;
                    var singleton_rel_extra: [2]u8 = undefined;
                    const singleton_rel_extra_n = try file.readPositionalAll(self.io, &singleton_rel_extra, offset);
                    if (singleton_rel_extra_n != singleton_rel_extra.len) return error.InvalidRecord;
                    singleton_rel = relKindFromInt(std.mem.readInt(u16, &singleton_rel_extra, .little)) orelse return error.InvalidRecord;
                    offset = singleton_rel_extra_end;
                }
                const path_end = std.math.add(u64, offset, entry_header.path_len) catch return error.InvalidRecord;
                if (path_end > file_size) return error.InvalidRecord;
                const restored_path = path: {
                    if ((entry_header.entry_flags & edge_segment_manifest_virtual_singleton) != 0) {
                        if (entry_header.path_len != 0) return error.InvalidRecord;
                        break :path try allocator.dupe(u8, "");
                    }
                    const stored_path = try allocator.alloc(u8, entry_header.path_len);
                    defer allocator.free(stored_path);
                    const path_n = try file.readPositionalAll(self.io, stored_path, offset);
                    if (path_n != stored_path.len) return error.InvalidRecord;
                    break :path try restoreEdgeSegmentManifestPath(self, allocator, entry_header.entry_flags, stored_path);
                };
                errdefer allocator.free(restored_path);
                offset = path_end;
                total_edges = std.math.add(u64, total_edges, edge_count) catch return error.InvalidRecord;
                const entry = OwnedEdgeSegmentManifestEntry{
                    .edge_count = edge_count,
                    .edge_digest = edge_digest,
                    .edge_id_range = entry_header.edge_id_range,
                    .edge_id_digest = edge_id_digest,
                    .edge_id_order_digest = edge_id_order_digest,
                    .edge_id_runs = edge_id_runs,
                    .src_node_range = endpoint_ranges.src_node_range,
                    .dst_node_range = endpoint_ranges.dst_node_range,
                    .singleton_rel = singleton_rel,
                    .path = restored_path,
                };
                if (edgeSegmentManifestEntryIsVirtual(entry)) {
                    try edgeSegmentManifestValidateVirtualEntry(entry);
                } else if ((entry_header.entry_flags & edge_segment_manifest_virtual_singleton) != 0) return error.InvalidRecord;
                manifest.entries.appendAssumeCapacity(entry);
            }
            if (offset != file_size or total_edges != header.total_edges) return error.InvalidRecord;
            return manifest;
        }

        pub fn ensurePersistentEdgeIndexes(self: Store, graph: *const graph_mod.Graph) !void {
            const graph_stats = try graphEdgeIndexStats(self.allocator, graph);
            const expected_edges = graph_stats.physical_edges;
            const id_digest = edgeIndexValidatedDigest(self, self.edge_by_id_path, .id, expected_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => null,
                else => |e| return e,
            };
            const src_digest = edgeIndexValidatedDigest(self, self.edge_by_src_path, .src, expected_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => null,
                else => |e| return e,
            };
            const dst_digest = edgeIndexValidatedDigest(self, self.edge_by_dst_path, .dst, expected_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => null,
                else => |e| return e,
            };
            const consistent_ok = consistent: {
                const id = id_digest orelse break :consistent false;
                const src = src_digest orelse break :consistent false;
                const dst = dst_digest orelse break :consistent false;
                break :consistent id.eql(src) and id.eql(dst);
            };
            const digest_ok = if (consistent_ok) edgeIndexHeadersMatchGraphStats(self, graph_stats) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => false,
                else => |e| return e,
            } else false;
            if (!consistent_ok or !digest_ok) try rebuildPersistentEdgeIndexes(self, graph);
        }

        pub fn ensurePersistentNodeIndexes(self: Store, graph: *const graph_mod.Graph) !void {
            const expected_nodes = activeNodeCount(graph);
            const ok = nodeIndexValid(self, expected_nodes) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => false,
                else => |e| return e,
            };
            if (!ok) try rebuildPersistentNodeIndexes(self, graph);
        }

        pub fn nodeIndexValid(self: Store, expected_nodes: u64) !bool {
            return try nodeIndexValidWithTimings(self, expected_nodes, null);
        }

        pub fn nodeIndexValidWithTimings(self: Store, expected_nodes: u64, timings: ?*PersistentValidateTimings) !bool {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{});
            defer file.close(self.io);
            const header = try readNodeByIdHeaderFromFile(self, file);
            if (header.node_count != expected_nodes) return false;
            const size = try fileSizeOrZero(self, self.node_by_id_path);
            if (size != try nodeByIdFileSizeForHeaderStore(self, header)) return false;
            var by_id_map = openReadOnlyMemoryMap(self.io, file, size) catch null;
            defer if (by_id_map) |*mapped| mapped.destroy(self.io);
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            const texts_size = texts.size;
            var validation_hashes: ?NodeTextValidationHashes = if (texts.shouldCacheValidationHashes())
                try NodeTextValidationHashes.init(self.allocator, header.max_node_id, expected_nodes)
            else
                null;
            defer if (validation_hashes) |*hashes| hashes.deinit(self.allocator);
            if (timings) |t| {
                if (validation_hashes) |*hashes| {
                    t.node_text_hash_cache_enabled = true;
                    t.node_text_hash_cache_bytes = hashes.estimatedBytes();
                }
            }

            var id: u64 = 1;
            var seen: u64 = 0;
            var by_id_digest: u64 = 0;
            var texts_cover_in_id_order = true;
            var texts_cover_cursor: u64 = 0;
            const by_id_scan_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            while (id <= header.max_node_id) : (id += 1) {
                const record = if (by_id_map) |*mapped|
                    try readNodeByIdRecordFromMap(header, mapped, id)
                else
                    try readNodeByIdRecordAt(self, file, header, id);
                if (record.id == 0) continue;
                if (record.id != id) return false;
                if (record.text_offset > texts_size or record.text_len > texts_size - record.text_offset) return false;
                if (texts_cover_in_id_order) {
                    if (record.text_offset == texts_cover_cursor) {
                        texts_cover_cursor = std.math.add(u64, texts_cover_cursor, record.text_len) catch return false;
                    } else {
                        texts_cover_in_id_order = false;
                    }
                }
                const node_kind = try record.nodeKind();
                const hashes = try texts.validationHash(record.id, node_kind, record.text_offset, record.text_len);
                by_id_digest ^= hashes.node_digest;
                if (validation_hashes) |*cache| {
                    try cache.put(record.id, .{
                        .text_hash = hashes.text_hash,
                        .node_digest = hashes.node_digest,
                    });
                }
                seen += 1;
            }
            if (seen != expected_nodes) return false;
            if (by_id_digest != header.node_digest) return false;
            if (texts_cover_in_id_order) {
                if (texts_cover_cursor != texts_size) return false;
            } else if (!try nodeByIdTextSpansCoverTextsFile(self, file, if (by_id_map) |*mapped| mapped else null, header, texts_size)) {
                return false;
            }
            if (timings) |t| t.node_by_id_scan_ns = storageElapsedNs(self.io, by_id_scan_start);

            var text_index_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{});
            defer text_index_file.close(self.io);
            const text_header = try readNodeTextIndexHeaderFromFile(self, text_index_file);
            const delta_file = std.Io.Dir.cwd().openFile(self.io, self.node_by_text_delta_path, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            };
            defer if (delta_file) |delta_open_file| delta_open_file.close(self.io);
            const delta_header = if (delta_file) |delta_open_file|
                try readNodeTextIndexHeaderFromFile(self, delta_open_file)
            else
                NodeTextIndexHeader{ .node_count = 0 };
            if (delta_header.node_count > node_text_delta_max_records) return false;
            var run_manifest = try readNodeTextRunManifest(self, self.allocator);
            defer run_manifest.deinit(self.allocator);
            const run_count = run_manifest.totalNodeCount();
            if (run_count == std.math.maxInt(u64)) return false;
            if (text_header.node_count + delta_header.node_count + run_count != expected_nodes) return false;
            if ((text_header.node_digest ^ delta_header.node_digest ^ run_manifest.nodeDigest()) != header.node_digest) return false;
            const text_index_size = try fileSizeOrZero(self, self.node_by_text_path);
            if (text_index_size != try nodeTextIndexFileSizeForHeader(text_header)) return false;
            const delta_index_size = try fileSizeOrZero(self, self.node_by_text_delta_path);
            if (delta_index_size != try nodeTextIndexFileSizeForHeader(delta_header)) return false;

            var pos: u64 = 0;
            var previous: ?NodeTextIndexRecord = null;
            var by_text_digest = NodeTextIndexDigest{};
            var indexed_node_ids = try NodeIndexSeenIds.init(self.allocator, header.max_node_id, expected_nodes);
            defer indexed_node_ids.deinit(self.allocator);
            var validation_node_view: ?NodeByIdIndexView = null;
            defer if (validation_node_view) |*view| view.deinit();
            const validation_node_meta = IndexMeta{
                .nodes = expected_nodes,
                .node_digest = header.node_digest,
            };
            const by_text_scan_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const text_span_node_view = if (text_header.hasDerivedTextSpan()) try ensureNodeByIdIndexView(self, validation_node_meta, &validation_node_view) else null;
            while (pos < text_header.node_count) : (pos += 1) {
                var record = try readNodeTextIndexRecordAtForValidation(self, text_index_file, text_header, pos, text_span_node_view);
                if (record.id == 0 or record.id > header.max_node_id) return false;
                if (record.text_offset > texts_size or record.text_len > texts_size - record.text_offset) return false;
                if (!text_header.hasDerivedTextSpan()) {
                    const by_id = if (by_id_map) |*mapped|
                        try readNodeByIdRecordFromMap(header, mapped, record.id)
                    else
                        try readNodeByIdRecordAt(self, file, header, record.id);
                    if (by_id.id != record.id) return false;
                    if (by_id.kind != record.kind) return false;
                    if (by_id.text_offset != record.text_offset or by_id.text_len != record.text_len) return false;
                }
                const digests = if (validation_hashes) |*cache|
                    try cache.get(record.id)
                else
                    try texts.validationHash(record.id, try record.nodeKind(), record.text_offset, record.text_len);
                if (text_header.hasDerivedHash()) {
                    record.hash = digests.text_hash;
                } else if (digests.text_hash != record.hash) return false;
                by_text_digest.add(record, digests.node_digest);
                if (try indexed_node_ids.put(record.id)) return false;
                if (previous) |prev| {
                    if (nodeTextIndexLessThan({}, record, prev)) return false;
                    if (record.id == prev.id) return false;
                }
                previous = record;
            }
            if (timings) |t| t.node_by_text_scan_ns = storageElapsedNs(self.io, by_text_scan_start);

            var delta_digest = NodeTextIndexDigest{};
            pos = 0;
            const delta_scan_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            const delta_span_node_view = if (delta_header.hasDerivedTextSpan()) try ensureNodeByIdIndexView(self, validation_node_meta, &validation_node_view) else null;
            while (pos < delta_header.node_count) : (pos += 1) {
                var record = try readNodeTextIndexRecordAtForValidation(self, delta_file orelse return false, delta_header, pos, delta_span_node_view);
                if (record.id == 0 or record.id > header.max_node_id) return false;
                if (record.text_offset > texts_size or record.text_len > texts_size - record.text_offset) return false;
                if (!delta_header.hasDerivedTextSpan()) {
                    const by_id = if (by_id_map) |*mapped|
                        try readNodeByIdRecordFromMap(header, mapped, record.id)
                    else
                        try readNodeByIdRecordAt(self, file, header, record.id);
                    if (by_id.id != record.id) return false;
                    if (by_id.kind != record.kind) return false;
                    if (by_id.text_offset != record.text_offset or by_id.text_len != record.text_len) return false;
                }
                const digests = if (validation_hashes) |*cache|
                    try cache.get(record.id)
                else
                    try texts.validationHash(record.id, try record.nodeKind(), record.text_offset, record.text_len);
                if (delta_header.hasDerivedHash()) {
                    record.hash = digests.text_hash;
                } else if (digests.text_hash != record.hash) return false;
                delta_digest.add(record, digests.node_digest);
                if (try indexed_node_ids.put(record.id)) return false;
            }
            if (timings) |t| t.node_text_delta_scan_ns = storageElapsedNs(self.io, delta_scan_start);
            if (delta_digest.count != delta_header.node_count) return false;
            if (delta_digest.digest != delta_header.node_digest) return false;
            if (delta_digest.order_digest != delta_header.order_digest) return false;
            var run_digest_all: u64 = 0;
            const run_scan_start = if (timings != null) storageMonotonicNs(self.io) else 0;
            for (run_manifest.entries.items) |entry| {
                var run_file = try std.Io.Dir.cwd().openFile(self.io, entry.path, .{});
                defer run_file.close(self.io);
                const run_header = try readNodeTextIndexHeaderFromFile(self, run_file);
                if (run_header.node_count != entry.node_count or
                    run_header.node_digest != entry.node_digest or
                    run_header.order_digest != entry.order_digest) return false;
                const run_size = try regularFileSize(self, run_file);
                if (run_size != try nodeTextIndexFileSizeForHeader(run_header)) return false;
                var run_digest = NodeTextIndexDigest{};
                previous = null;
                pos = 0;
                const run_span_node_view = if (run_header.hasDerivedTextSpan()) try ensureNodeByIdIndexView(self, validation_node_meta, &validation_node_view) else null;
                while (pos < run_header.node_count) : (pos += 1) {
                    var record = try readNodeTextIndexRecordAtForValidation(self, run_file, run_header, pos, run_span_node_view);
                    if (record.id == 0 or record.id > header.max_node_id) return false;
                    if (record.text_offset > texts_size or record.text_len > texts_size - record.text_offset) return false;
                    if (!run_header.hasDerivedTextSpan()) {
                        const by_id = if (by_id_map) |*mapped|
                            try readNodeByIdRecordFromMap(header, mapped, record.id)
                        else
                            try readNodeByIdRecordAt(self, file, header, record.id);
                        if (by_id.id != record.id) return false;
                        if (by_id.kind != record.kind) return false;
                        if (by_id.text_offset != record.text_offset or by_id.text_len != record.text_len) return false;
                    }
                    const digests = if (validation_hashes) |*cache|
                        try cache.get(record.id)
                    else
                        try texts.validationHash(record.id, try record.nodeKind(), record.text_offset, record.text_len);
                    if (run_header.hasDerivedHash()) {
                        record.hash = digests.text_hash;
                    } else if (digests.text_hash != record.hash) return false;
                    run_digest.add(record, digests.node_digest);
                    if (try indexed_node_ids.put(record.id)) return false;
                    if (previous) |prev| {
                        if (nodeTextIndexLessThan({}, record, prev)) return false;
                        if (record.id == prev.id) return false;
                    }
                    previous = record;
                }
                if (run_digest.count != run_header.node_count) return false;
                if (run_digest.digest != run_header.node_digest) return false;
                if (run_digest.order_digest != run_header.order_digest) return false;
                run_digest_all ^= run_digest.digest;
            }
            if (timings) |t| t.node_text_run_scan_ns = storageElapsedNs(self.io, run_scan_start);
            if (indexed_node_ids.count() != expected_nodes) return false;
            return by_text_digest.count == text_header.node_count and
                by_text_digest.digest == text_header.node_digest and
                by_text_digest.order_digest == text_header.order_digest and
                by_text_digest.count + delta_digest.count + run_count == seen and
                (by_text_digest.digest ^ delta_digest.digest ^ run_digest_all) == header.node_digest;
        }

        pub fn nodeByIdTextSpansCoverTextsFile(self: Store, file: std.Io.File, map: ?*const std.Io.File.MemoryMap, header: NodeByIdHeader, texts_size: u64) !bool {
            var text_spans = std.ArrayList(TextSpan).empty;
            defer text_spans.deinit(self.allocator);
            var id: u64 = 1;
            while (id <= header.max_node_id) : (id += 1) {
                const record = if (map) |mapped|
                    try readNodeByIdRecordFromMap(header, mapped, id)
                else
                    try readNodeByIdRecordAt(self, file, header, id);
                if (record.id == 0) continue;
                if (record.id != id) return false;
                if (record.text_offset > texts_size or record.text_len > texts_size - record.text_offset) return false;
                try text_spans.append(self.allocator, .{ .offset = record.text_offset, .len = record.text_len });
            }
            return textSpansCoverTextsFile(text_spans.items, texts_size);
        }

        pub fn nodeTextHashMatches(self: Store, record: NodeTextIndexRecord) !bool {
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            return try texts.hashMatches(record);
        }

        pub fn nodeRecordDigestFromTextSpan(self: Store, record: NodeByIdRecord) !u64 {
            return nodeRecordDigestFromStoredText(self, record.id, try record.nodeKind(), record.text_offset, record.text_len);
        }

        pub fn nodeTextIndexRecordDigest(self: Store, record: NodeTextIndexRecord) !u64 {
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            return nodeTextIndexRecordDigestWithTexts(self, &texts, record);
        }

        pub fn nodeTextIndexRecordDigestWithTexts(self: Store, texts: *const NodeTextsView, record: NodeTextIndexRecord) !u64 {
            _ = self;
            return texts.digestStoredNode(record.id, try record.nodeKind(), record.text_offset, record.text_len);
        }

        pub fn nodeRecordDigestFromStoredTextView(self: Store, texts: *const NodeTextsView, id: u64, kind: core.NodeKind, offset: u64, len: u32) !u64 {
            _ = self;
            return texts.digestStoredNode(id, kind, offset, len);
        }

        pub fn nodeRecordDigestFromStoredText(self: Store, id: u64, kind: core.NodeKind, offset: u64, len: u32) !u64 {
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            return nodeRecordDigestFromStoredTextView(self, &texts, id, kind, offset, len);
        }

        pub fn edgeIndexValid(self: Store, path: []const u8, order: EdgeIndexOrder, expected_edges: u64) !bool {
            _ = edgeIndexValidatedDigest(self, path, order, expected_edges) catch |err| switch (err) {
                error.InvalidRecord => return false,
                else => |e| return e,
            };
            return true;
        }

        pub fn edgeIndexValidatedDigest(self: Store, path: []const u8, order: EdgeIndexOrder, expected_edges: u64) !EdgeIndexDigest {
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != order or header.edge_count != expected_edges) return error.InvalidRecord;
            if (order == .id) {
                const meta = try readCurrentIndexMeta(self);
                if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            }
            const size = try regularFileSize(self, file);
            if (size != try edgeIndexFileSizeForHeader(header)) return error.InvalidRecord;

            var node_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{});
            defer node_file.close(self.io);
            const node_header = try readNodeByIdHeaderFromFile(self, node_file);
            const node_index_size = try fileSizeOrZero(self, self.node_by_id_path);
            if (node_index_size != try nodeByIdFileSizeForHeaderStore(self, node_header)) return error.InvalidRecord;
            var node_map = openReadOnlyMemoryMap(self.io, node_file, node_index_size) catch null;
            defer if (node_map) |*mapped| mapped.destroy(self.io);

            var pos: u64 = 0;
            var previous: ?EdgeIndexRecord = null;
            var digest = EdgeIndexDigest{};
            var reader = try EdgeIndexSequentialRecordReader.init(self, file, header);
            while (pos < header.edge_count) : (pos += 1) {
                const record = try reader.read(pos);
                digest.add(record);
                if (!try nodeIdPresentInIndex(self, node_file, if (node_map) |*mapped| mapped else null, node_header, record.src)) return error.InvalidRecord;
                if (!try nodeIdPresentInIndex(self, node_file, if (node_map) |*mapped| mapped else null, node_header, record.dst)) return error.InvalidRecord;
                if (previous) |prev| {
                    if (edgeIndexLessThan(order, record, prev)) return error.InvalidRecord;
                    if (order == .id and record.edge_id == prev.edge_id) return error.InvalidRecord;
                }
                previous = record;
            }
            if (digest.digest != header.edge_digest) return error.InvalidRecord;
            if (digest.order_digest != header.order_digest) return error.InvalidRecord;
            return digest;
        }

        pub fn edgeIndexesConsistent(self: Store, expected_edges: u64) !bool {
            const by_id = try edgeIndexDigest(self, self.edge_by_id_path, .id, expected_edges);
            const by_src = try edgeIndexDigest(self, self.edge_by_src_path, .src, expected_edges);
            const by_dst = try edgeIndexDigest(self, self.edge_by_dst_path, .dst, expected_edges);
            return by_id.eql(by_src) and by_id.eql(by_dst);
        }

        pub fn edgeIndexesValidatedAndMatchMeta(self: Store, meta: IndexMeta) !bool {
            if (!try edgeBaseIndexesValidatedAndMatchMeta(self, meta)) return false;
            return try edgeIndexHeadersMatchMeta(self, meta);
        }

        pub fn edgeBaseIndexesValidatedAndMatchMeta(self: Store, meta: IndexMeta) !bool {
            const id_digest = edgeIndexValidatedDigest(self, self.edge_by_id_path, .id, meta.edge_indexed_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            const src_digest = edgeIndexValidatedDigest(self, self.edge_by_src_path, .src, meta.edge_indexed_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            const dst_digest = edgeIndexValidatedDigest(self, self.edge_by_dst_path, .dst, meta.edge_indexed_edges) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            if (!id_digest.eql(src_digest) or !id_digest.eql(dst_digest)) return false;
            if (id_digest.count != meta.edge_indexed_edges or id_digest.digest != meta.edge_index_digest) return false;
            if (id_digest.order_digest != meta.edge_by_id_order_digest) return false;
            if (src_digest.order_digest != meta.edge_by_src_order_digest) return false;
            return dst_digest.order_digest == meta.edge_by_dst_order_digest;
        }

        pub fn edgeIndexesMatchMeta(self: Store, meta: IndexMeta) !bool {
            // Runtime currentness check only. Explicit validation still scans
            // edge-index record bodies via persistentIndexFilesMatchMetaWithTimings.
            return try edgeIndexHeadersMatchMeta(self, meta);
        }

        pub fn validatedEdgeIndexDigestsMatchMeta(self: Store, meta: IndexMeta, id_digest: EdgeIndexDigest, src_digest: EdgeIndexDigest, dst_digest: EdgeIndexDigest) !bool {
            if (meta.edge_indexed_edges < meta.edges) return false;
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            if (tombstone_header.count > meta.edge_indexed_edges) return false;
            if (meta.edge_indexed_edges - tombstone_header.count != meta.edges) return false;
            if ((meta.edge_index_digest ^ tombstone_header.digest) != meta.edge_digest) return false;
            if (id_digest.count != meta.edge_indexed_edges or id_digest.digest != meta.edge_index_digest) return false;
            if (src_digest.count != meta.edge_indexed_edges or src_digest.digest != meta.edge_index_digest) return false;
            if (dst_digest.count != meta.edge_indexed_edges or dst_digest.digest != meta.edge_index_digest) return false;
            if (id_digest.order_digest != meta.edge_by_id_order_digest) return false;
            if (src_digest.order_digest != meta.edge_by_src_order_digest) return false;
            if (dst_digest.order_digest != meta.edge_by_dst_order_digest) return false;
            return true;
        }

        pub fn edgeIndexHeadersMatchGraphStats(self: Store, graph_stats: GraphEdgeIndexStats) !bool {
            // The caller has already run per-index validation and cross-index
            // streamed digest checks; this only compares those trusted headers and
            // tombstones against the graph-derived count/digest identity.
            if (graph_stats.physical_edges < graph_stats.visible_edges) return false;
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            if (tombstone_header.count > graph_stats.physical_edges) return false;
            if (graph_stats.physical_edges - tombstone_header.count != graph_stats.visible_edges) return false;
            if ((graph_stats.physical_edge_digest ^ tombstone_header.digest) != graph_stats.edge_digest) return false;

            const id_header = try readEdgeIndexHeader(self, self.edge_by_id_path);
            if (id_header.order != .id or id_header.edge_count != graph_stats.physical_edges) return false;
            if (id_header.edge_digest != graph_stats.physical_edge_digest) return false;
            const src_header = try readEdgeIndexHeader(self, self.edge_by_src_path);
            if (src_header.order != .src or src_header.edge_count != graph_stats.physical_edges) return false;
            if (src_header.edge_digest != graph_stats.physical_edge_digest) return false;
            const dst_header = try readEdgeIndexHeader(self, self.edge_by_dst_path);
            if (dst_header.order != .dst or dst_header.edge_count != graph_stats.physical_edges) return false;
            return dst_header.edge_digest == graph_stats.physical_edge_digest;
        }

        pub fn edgeIndexHeadersMatchMeta(self: Store, meta: IndexMeta) !bool {
            if (meta.edge_indexed_edges < meta.edges) return false;
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            if (tombstone_header.count > meta.edge_indexed_edges) return false;
            if (meta.edge_indexed_edges - tombstone_header.count != meta.edges) return false;
            if ((meta.edge_index_digest ^ tombstone_header.digest) != meta.edge_digest) return false;
            return try edgeIndexBaseHeadersMatchMeta(self, meta);
        }

        pub fn edgeStorageMatchesMeta(self: Store, meta: IndexMeta, validate_base_records: bool) !bool {
            const base_matches = if (validate_base_records)
                try edgeBaseIndexesValidatedAndMatchMeta(self, meta)
            else
                try edgeIndexBaseHeadersMatchMeta(self, meta);
            if (!base_matches) return false;
            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
            const physical_edges = std.math.add(u64, meta.edges, tombstone_header.count) catch return false;
            if (meta.edge_indexed_edges > physical_edges) return false;
            if (meta.edge_indexed_edges == physical_edges) {
                return (meta.edge_index_digest ^ tombstone_header.digest) == meta.edge_digest;
            }
            // The base indexes intentionally lag while an immutable segment
            // overlay owns the physical suffix (or the complete visible set).
            // Treat that publication as current only after validating its count
            // and digest identity against the same IndexMeta snapshot.
            return try edgeSegmentManifestMatchesMeta(self, meta);
        }

        pub fn edgeIndexBaseHeadersMatchMeta(self: Store, meta: IndexMeta) !bool {
            if (!try edgeIndexHeaderFileMatchesMeta(self, self.edge_by_id_path, .id, meta.edge_indexed_edges, meta.edge_index_digest, meta.edge_by_id_order_digest)) return false;
            if (!try edgeIndexHeaderFileMatchesMeta(self, self.edge_by_src_path, .src, meta.edge_indexed_edges, meta.edge_index_digest, meta.edge_by_src_order_digest)) return false;
            if (!try edgeIndexHeaderFileMatchesMeta(self, self.edge_by_dst_path, .dst, meta.edge_indexed_edges, meta.edge_index_digest, meta.edge_by_dst_order_digest)) return false;
            return true;
        }

        pub fn edgeIndexHeaderFileMatchesMeta(self: Store, path: []const u8, order: EdgeIndexOrder, edge_count: u64, edge_digest: u64, order_digest: u64) !bool {
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != order or header.edge_count != edge_count) return false;
            if (header.edge_digest != edge_digest or header.order_digest != order_digest) return false;
            return try regularFileSize(self, file) == try edgeIndexFileSizeForHeader(header);
        }

        pub fn edgeIndexDigest(self: Store, path: []const u8, order: EdgeIndexOrder, expected_edges: u64) !EdgeIndexDigest {
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != order or header.edge_count != expected_edges) return error.InvalidRecord;
            const size = try regularFileSize(self, file);
            if (size != try edgeIndexFileSizeForHeader(header)) return error.InvalidRecord;

            var digest = EdgeIndexDigest{};
            var reader = try EdgeIndexSequentialRecordReader.init(self, file, header);
            var pos: u64 = 0;
            while (pos < header.edge_count) : (pos += 1) {
                const record = try reader.read(pos);
                digest.add(record);
            }
            if (digest.digest != header.edge_digest) return error.InvalidRecord;
            if (digest.order_digest != header.order_digest) return error.InvalidRecord;
            return digest;
        }

        pub fn nodeIdPresentInIndex(self: Store, file: std.Io.File, map: ?*const std.Io.File.MemoryMap, header: NodeByIdHeader, id: u64) !bool {
            if (id == 0 or id > header.max_node_id) return false;
            const record = if (map) |mapped|
                try readNodeByIdRecordFromMap(header, mapped, id)
            else
                try readNodeByIdRecordAt(self, file, header, id);
            return record.id == id;
        }

        pub fn rebuildPersistentEdgeIndexes(self: Store, graph: *const graph_mod.Graph) !void {
            const edge_repair_path = try std.fmt.allocPrint(self.allocator, "{s}.repair_edges.tmp", .{self.edge_by_id_path});
            defer self.allocator.free(edge_repair_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, edge_repair_path) catch {};
            const tombstone_repair_path = try std.fmt.allocPrint(self.allocator, "{s}.repair_tombstones.tmp", .{self.edge_tombstones_path});
            defer self.allocator.free(tombstone_repair_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tombstone_repair_path) catch {};

            var edge_record_count: usize = 0;
            var tombstone_count: usize = 0;
            var tombstone_digest: u64 = 0;

            {
                var edge_file = try std.Io.Dir.cwd().createFile(self.io, edge_repair_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer edge_file.close(self.io);
                var edge_writer = try StorageBufferedWriter.init(self.allocator, self.io, edge_file, storage_write_buffer_bytes);
                defer edge_writer.deinit();

                var tombstone_file = try std.Io.Dir.cwd().createFile(self.io, tombstone_repair_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer tombstone_file.close(self.io);
                var tombstone_writer = try StorageBufferedWriter.init(self.allocator, self.io, tombstone_file, storage_write_buffer_bytes);
                defer tombstone_writer.deinit();

                var active_nodes = try buildActiveNodeSet(self.allocator, graph);
                defer active_nodes.deinit();
                var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
                var tombstone_bytes: [EdgeTombstoneRecord.encoded_len]u8 = undefined;
                for (graph.edges.items) |edge| {
                    const record = (try physicalEdgeRecord(&active_nodes, edge)) orelse continue;
                    record.encode(&record_bytes);
                    try edge_writer.append(&record_bytes);
                    edge_record_count = std.math.add(usize, edge_record_count, 1) catch return error.InvalidRecord;
                    if (edge.status == .deleted) {
                        const edge_digest = edgeRecordDigest(record);
                        const tombstone = EdgeTombstoneRecord{
                            .edge_id = record.edge_id,
                            .edge_digest = edge_digest,
                        };
                        tombstone.encode(&tombstone_bytes);
                        try tombstone_writer.append(&tombstone_bytes);
                        tombstone_count = std.math.add(usize, tombstone_count, 1) catch return error.InvalidRecord;
                        tombstone_digest ^= edge_digest;
                    }
                }

                try edge_writer.flush();
                const expected_edge_repair_size = std.math.mul(u64, @intCast(edge_record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                if (try edge_writer.position() != expected_edge_repair_size) return error.InvalidRecord;
                if (try regularFileSize(self, edge_file) != expected_edge_repair_size) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try edge_file.sync(self.io);

                try tombstone_writer.flush();
                const expected_tombstone_repair_size = std.math.mul(u64, @intCast(tombstone_count), EdgeTombstoneRecord.encoded_len) catch return error.InvalidRecord;
                if (try tombstone_writer.position() != expected_tombstone_repair_size) return error.InvalidRecord;
                if (try regularFileSize(self, tombstone_file) != expected_tombstone_repair_size) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try tombstone_file.sync(self.io);
            }

            try writeEdgeIndexesFromRepairSpool(self, edge_repair_path, edge_record_count, null);
            std.Io.Dir.cwd().deleteFile(self.io, edge_repair_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };

            try writeEdgeTombstoneIndexFromRepairSpool(self, tombstone_repair_path, tombstone_count, tombstone_digest);
            std.Io.Dir.cwd().deleteFile(self.io, tombstone_repair_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        }

        pub fn appendEdgeIndexRecord(self: Store, edge: graph_mod.Edge) !void {
            if (edge.status != .active) return;
            const record = edgeIndexRecordFromEdge(edge);

            try insertEdgeIndexRecord(self, self.edge_by_id_path, .id, record);
            try insertEdgeIndexRecord(self, self.edge_by_src_path, .src, record);
            try insertEdgeIndexRecord(self, self.edge_by_dst_path, .dst, record);
        }

        pub fn insertEdgeIndexRecord(self: Store, path: []const u8, order: EdgeIndexOrder, record: EdgeIndexRecord) !void {
            var old_file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_write, .allow_directory = false });
            defer old_file.close(self.io);
            const old_header = try readEdgeIndexHeaderFromFile(self, old_file);
            if (old_header.order != order) return error.InvalidRecord;
            const expected_old_size = try edgeIndexFileSizeForHeader(old_header);
            if (try regularFileSize(self, old_file) != expected_old_size) return error.InvalidRecord;
            if (old_header.edge_count == std.math.maxInt(u64)) return error.RecordTooLarge;
            const next_count = old_header.edge_count + 1;
            const record_digest = edgeRecordDigest(record);
            const next_order_digest = edgeIndexOrderDigestStep(old_header.order_digest, old_header.edge_count, record);
            const next_header = edgeIndexHeaderForTail(order, old_header, next_count, old_header.edge_digest ^ record_digest, next_order_digest, &.{record});

            if (old_header.edge_count == 0) {
                return try appendSortedEdgeIndexTail(self, old_file, old_header, next_header, record);
            }
            const last = try readEdgeIndexRecordAt(self, old_file, old_header, old_header.edge_count - 1);
            if (!old_header.hasKeyRuns() and !edgeIndexLessThan(order, record, last)) {
                if (old_header.record_len == next_header.record_len) {
                    return try appendSortedEdgeIndexTail(self, old_file, old_header, next_header, record);
                }
            }

            const rewrite_header = edgeIndexHeaderForSingleFullRewrite(order, next_count, old_header.edge_digest ^ record_digest, 0, old_header, record);
            const expected_new_size = try edgeIndexFileSizeForHeader(rewrite_header);
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var new_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer new_file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, new_file, try storageWriteBufferCapacity(expected_new_size));
                defer writer.deinit();

                var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
                const placeholder_header = rewrite_header;
                placeholder_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var new_digest = EdgeIndexDigest{};
                var old_digest = EdgeIndexDigest{};
                var prev_old: ?EdgeIndexRecord = null;
                var inserted = false;
                var pos: u64 = 0;
                while (pos < old_header.edge_count) : (pos += 1) {
                    const current = try readEdgeIndexRecordAt(self, old_file, old_header, pos);
                    if (prev_old) |prev| {
                        if (!edgeIndexLessThan(order, prev, current)) return error.InvalidRecord;
                    }
                    prev_old = current;
                    old_digest.add(current);
                    if (!inserted and edgeIndexLessThan(order, record, current)) {
                        try writeEdgeIndexRecordToWriter(&writer, rewrite_header, new_digest.count, record);
                        new_digest.addWithDigest(record, record_digest);
                        inserted = true;
                    }
                    try writeEdgeIndexRecordToWriter(&writer, rewrite_header, new_digest.count, current);
                    new_digest.add(current);
                }
                if (old_digest.count != old_header.edge_count or old_digest.digest != old_header.edge_digest or old_digest.order_digest != old_header.order_digest) return error.InvalidRecord;
                if (!inserted) {
                    try writeEdgeIndexRecordToWriter(&writer, rewrite_header, new_digest.count, record);
                    new_digest.addWithDigest(record, record_digest);
                }
                if (new_digest.count != next_count) return error.InvalidRecord;
                if (new_digest.digest != placeholder_header.edge_digest) return error.InvalidRecord;
                try writer.flush();
                if (try writer.position() != expected_new_size) return error.InvalidRecord;
                if (try regularFileSize(self, new_file) != expected_new_size) return error.InvalidRecord;
                var new_header = rewrite_header;
                new_header.edge_digest = new_digest.digest;
                new_header.order_digest = new_digest.order_digest;
                new_header.encode(&header_bytes);
                try new_file.writePositionalAll(self.io, &header_bytes, 0);
                if (selfOptionsNeedSync(self)) try new_file.sync(self.io);
            }
            try renameReplace(self, tmp_path, path);
        }

        pub fn writeMergedEdgeIndexBatch(self: Store, path: []const u8, order: EdgeIndexOrder, old_meta: IndexMeta, batch_records: []EdgeIndexRecord, next_digest: u64) !EdgeIndexBatchWriteResult {
            if (batch_records.len == 0) return .{
                .order_digest = edgeOrderDigestForMeta(old_meta, order),
                .edge_id_runs = if (order == .id) old_meta.edge_by_id_runs else null,
            };
            const next_count = std.math.add(u64, old_meta.edge_indexed_edges, @intCast(batch_records.len)) catch return error.RecordTooLarge;
            var old_file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_write });
            defer old_file.close(self.io);
            const old_header = try readEdgeIndexHeaderFromFile(self, old_file);
            if (old_header.order != order) return error.InvalidRecord;
            if (old_header.edge_count != old_meta.edge_indexed_edges) return error.InvalidRecord;
            if (old_header.edge_digest != old_meta.edge_index_digest) return error.InvalidRecord;
            if (old_header.order_digest != edgeOrderDigestForMeta(old_meta, order)) return error.InvalidRecord;
            const expected_old_size = try edgeIndexFileSizeForHeader(old_header);
            if (try regularFileSize(self, old_file) != expected_old_size) return error.InvalidRecord;

            var batch_sorted = edgeIndexBatchSorted(order, batch_records);
            if (batch_sorted) {
                if (try appendSortedEdgeIndexBatchTailIfPossible(self, old_file, old_header, order, batch_records, next_count, next_digest)) |order_digest| {
                    var edge_id_runs = if (order == .id)
                        extendEdgeSegmentIdRunSummaryWithRecords(old_meta.edge_by_id_runs, old_header.edge_count, batch_records)
                    else
                        null;
                    if (edge_id_runs) |runs| {
                        const next_header = try readEdgeIndexHeaderFromFile(self, old_file);
                        if (!try edgeIdRunSummaryMatchesFile(self, old_file, next_header, runs)) edge_id_runs = null;
                    }
                    return .{
                        .order_digest = order_digest,
                        .edge_id_runs = edge_id_runs,
                    };
                }
            }
            if (!batch_sorted) {
                sortEdgeIndexRecords(order, batch_records);
                batch_sorted = true;
                if (try appendSortedEdgeIndexBatchTailIfPossible(self, old_file, old_header, order, batch_records, next_count, next_digest)) |order_digest| {
                    var edge_id_runs = if (order == .id)
                        extendEdgeSegmentIdRunSummaryWithRecords(old_meta.edge_by_id_runs, old_header.edge_count, batch_records)
                    else
                        null;
                    if (edge_id_runs) |runs| {
                        const next_header = try readEdgeIndexHeaderFromFile(self, old_file);
                        if (!try edgeIdRunSummaryMatchesFile(self, old_file, next_header, runs)) edge_id_runs = null;
                    }
                    return .{
                        .order_digest = order_digest,
                        .edge_id_runs = edge_id_runs,
                    };
                }
            }
            std.debug.assert(batch_sorted);

            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            var merged_order_digest: u64 = 0;
            const rewrite_header = EdgeIndexHeader.withShape(
                order,
                next_count,
                next_digest,
                0,
                false,
                old_header.hasU32NodeIds() and edgeRecordsHaveU32NodeIds(batch_records),
                old_header.hasU32EdgeIds() and edgeRecordsHaveU32EdgeIds(batch_records),
                edgeRecordsExtendDerivedRel(old_header, batch_records),
            );
            const expected_new_size = try edgeIndexFileSizeForHeader(rewrite_header);
            {
                var new_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer new_file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, new_file, try storageWriteBufferCapacity(expected_new_size));
                defer writer.deinit();

                var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
                const placeholder_header = rewrite_header;
                placeholder_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var batch_pos: usize = 0;
                var old_digest = EdgeIndexDigest{};
                var new_digest = EdgeIndexDigest{};
                var prev_old: ?EdgeIndexRecord = null;
                var old_pos: u64 = 0;
                while (old_pos < old_header.edge_count) : (old_pos += 1) {
                    const current = try readEdgeIndexRecordAt(self, old_file, old_header, old_pos);
                    if (prev_old) |prev| {
                        if (!edgeIndexLessThan(order, prev, current)) return error.InvalidRecord;
                    }
                    prev_old = current;
                    old_digest.add(current);
                    while (batch_pos < batch_records.len and edgeIndexLessThan(order, batch_records[batch_pos], current)) : (batch_pos += 1) {
                        try writeEdgeIndexRecordToWriter(&writer, rewrite_header, new_digest.count, batch_records[batch_pos]);
                        new_digest.add(batch_records[batch_pos]);
                    }
                    try writeEdgeIndexRecordToWriter(&writer, rewrite_header, new_digest.count, current);
                    new_digest.add(current);
                }
                if (old_digest.count != old_meta.edge_indexed_edges or old_digest.digest != old_meta.edge_index_digest or old_digest.order_digest != old_header.order_digest) return error.InvalidRecord;
                while (batch_pos < batch_records.len) : (batch_pos += 1) {
                    try writeEdgeIndexRecordToWriter(&writer, rewrite_header, new_digest.count, batch_records[batch_pos]);
                    new_digest.add(batch_records[batch_pos]);
                }
                if (new_digest.count != next_count or new_digest.digest != next_digest) return error.InvalidRecord;
                try writer.flush();
                if (try writer.position() != expected_new_size) return error.InvalidRecord;
                if (try regularFileSize(self, new_file) != expected_new_size) return error.InvalidRecord;
                var new_header = rewrite_header;
                new_header.edge_digest = new_digest.digest;
                new_header.order_digest = new_digest.order_digest;
                new_header.encode(&header_bytes);
                try new_file.writePositionalAll(self.io, &header_bytes, 0);
                if (selfOptionsNeedSync(self)) try new_file.sync(self.io);
                merged_order_digest = new_digest.order_digest;
            }
            try renameReplace(self, tmp_path, path);
            return .{ .order_digest = merged_order_digest };
        }

        pub fn writeEdgeIndexWithoutRecord(self: Store, path: []const u8, order: EdgeIndexOrder, old_meta: IndexMeta, removed: EdgeIndexRecord, next_digest: u64) !void {
            if (old_meta.edges == 0) return error.InvalidRecord;
            const next_count = old_meta.edges - 1;

            var old_file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_write });
            defer old_file.close(self.io);
            const old_header = try readEdgeIndexHeaderFromFile(self, old_file);
            if (old_header.order != order) return error.InvalidRecord;
            if (old_header.edge_count != old_meta.edges) return error.InvalidRecord;
            if (old_header.edge_digest != old_meta.edge_digest) return error.InvalidRecord;
            if (old_header.order_digest != edgeOrderDigestForMeta(old_meta, order)) return error.InvalidRecord;
            const expected_old_size = try edgeIndexFileSizeForHeader(old_header);
            if (try regularFileSize(self, old_file) != expected_old_size) return error.InvalidRecord;

            const rewrite_header = edgeIndexHeaderWithoutRecord(order, next_count, next_digest, 0, old_header, removed);
            const expected_new_size = try edgeIndexFileSizeForHeader(rewrite_header);
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var new_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer new_file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, new_file, try storageWriteBufferCapacity(expected_new_size));
                defer writer.deinit();

                var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
                const placeholder_header = rewrite_header;
                placeholder_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var old_digest = EdgeIndexDigest{};
                var new_digest = EdgeIndexDigest{};
                var prev_old: ?EdgeIndexRecord = null;
                var removed_count: u64 = 0;
                var old_pos: u64 = 0;
                while (old_pos < old_header.edge_count) : (old_pos += 1) {
                    const current = try readEdgeIndexRecordAt(self, old_file, old_header, old_pos);
                    if (prev_old) |prev| {
                        if (!edgeIndexLessThan(order, prev, current)) return error.InvalidRecord;
                    }
                    prev_old = current;
                    old_digest.add(current);
                    if (edgeIndexRecordEquals(current, removed)) {
                        removed_count += 1;
                        continue;
                    }
                    try writeEdgeIndexRecordToWriter(&writer, rewrite_header, new_digest.count, current);
                    new_digest.add(current);
                }
                if (removed_count != 1) return error.InvalidRecord;
                if (old_digest.count != old_header.edge_count or old_digest.digest != old_header.edge_digest or old_digest.order_digest != old_header.order_digest) return error.InvalidRecord;
                if (new_digest.count != next_count or new_digest.digest != next_digest) return error.InvalidRecord;
                try writer.flush();
                if (try writer.position() != expected_new_size) return error.InvalidRecord;
                if (try regularFileSize(self, new_file) != expected_new_size) return error.InvalidRecord;
                var new_header = rewrite_header;
                new_header.edge_digest = new_digest.digest;
                new_header.order_digest = new_digest.order_digest;
                new_header.encode(&header_bytes);
                try new_file.writePositionalAll(self.io, &header_bytes, 0);
                if (selfOptionsNeedSync(self)) try new_file.sync(self.io);
            }
            try renameReplace(self, tmp_path, path);
        }

        pub fn appendSortedEdgeIndexBatchTailIfPossible(
            self: Store,
            file: std.Io.File,
            old_header: EdgeIndexHeader,
            order: EdgeIndexOrder,
            batch_records: []const EdgeIndexRecord,
            next_count: u64,
            next_digest: u64,
        ) !?u64 {
            if (batch_records.len == 0) return old_header.order_digest;

            if (old_header.edge_count != 0) {
                const last_old = try readEdgeIndexRecordAt(self, file, old_header, old_header.edge_count - 1);
                if (!edgeIndexLessThan(order, last_old, batch_records[0])) return null;
            }

            var edge_digest = old_header.edge_digest;
            var order_digest = old_header.order_digest;
            var edge_count = old_header.edge_count;
            for (batch_records) |record| {
                edge_digest ^= edgeRecordDigest(record);
                order_digest = edgeIndexOrderDigestStep(order_digest, edge_count, record);
                edge_count = std.math.add(u64, edge_count, 1) catch return error.RecordTooLarge;
            }
            if (edge_count != next_count or edge_digest != next_digest) return error.InvalidRecord;

            const new_header = edgeIndexHeaderForTail(order, old_header, next_count, edge_digest, order_digest, batch_records);
            if (old_header.edge_count == 0 and new_header.hasKeyRuns()) {
                try file.setLength(self.io, 0);
                const expected_new_size = try edgeIndexFileSizeForHeader(new_header);
                try writeCompleteEdgeIndexFile(self, file, new_header, batch_records, expected_new_size);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
                return order_digest;
            }
            if (old_header.hasKeyRuns()) return null;
            if (old_header.edge_count != 0 and old_header.record_len != new_header.record_len) return null;
            const expected_new_size = try edgeIndexFileSizeForHeader(new_header);
            const tail_bytes = std.math.mul(u64, @intCast(batch_records.len), new_header.record_len) catch return error.RecordTooLarge;
            var writer = try StorageBufferedWriter.initAtOffset(
                self.allocator,
                self.io,
                file,
                try storageWriteBufferCapacity(tail_bytes),
                try edgeIndexRecordOffsetForHeader(new_header, old_header.edge_count),
            );
            defer writer.deinit();
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            for (batch_records, 0..) |record, i| {
                const encoded = record_bytes[0..new_header.record_len];
                try record.encodeForHeader(new_header, old_header.edge_count + @as(u64, @intCast(i)), null, encoded);
                try writer.append(encoded);
            }
            try writer.flush();
            if (try writer.position() != expected_new_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_new_size) return error.InvalidRecord;

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            new_header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
            return order_digest;
        }

        pub fn appendSortedEdgeIndexTail(self: Store, file: std.Io.File, old_header: EdgeIndexHeader, new_header: EdgeIndexHeader, record: EdgeIndexRecord) !void {
            if (new_header.edge_count != old_header.edge_count + 1) return error.InvalidRecord;
            if (old_header.edge_count == 0 and new_header.hasKeyRuns()) {
                try file.setLength(self.io, 0);
                const expected_new_size = try edgeIndexFileSizeForHeader(new_header);
                try writeCompleteEdgeIndexFile(self, file, new_header, &.{record}, expected_new_size);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
                return;
            }
            if (old_header.hasKeyRuns() or new_header.hasKeyRuns()) return error.InvalidRecord;
            if (old_header.edge_count != 0 and old_header.record_len != new_header.record_len) return error.InvalidRecord;
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            const encoded = record_bytes[0..new_header.record_len];
            try record.encodeForHeader(new_header, old_header.edge_count, null, encoded);
            const record_offset = try edgeIndexRecordOffsetForHeader(new_header, old_header.edge_count);
            try file.writePositionalAll(self.io, encoded, record_offset);
            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            new_header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
            if (try regularFileSize(self, file) != try edgeIndexFileSizeForHeader(new_header)) return error.InvalidRecord;
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
        }
        pub const rebuildPersistentNodeIndexes = node_catalog_index.rebuildPersistentNodeIndexes;

        pub fn writeEmptyNodeIndexes(self: Store) !void {
            const texts_tmp_path = try tmpPathFor(self, self.node_texts_path);
            defer self.allocator.free(texts_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, texts_tmp_path) catch {};
            const by_id_tmp_path = try tmpPathFor(self, self.node_by_id_path);
            defer self.allocator.free(by_id_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, by_id_tmp_path) catch {};

            {
                var texts_file = try std.Io.Dir.cwd().createFile(self.io, texts_tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer texts_file.close(self.io);
                if (selfOptionsNeedSync(self)) try texts_file.sync(self.io);

                var index_file = try std.Io.Dir.cwd().createFile(self.io, by_id_tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer index_file.close(self.io);
                try writeNodeByIdHeader(self, index_file, .{ .max_node_id = 0, .node_count = 0 });
                if (selfOptionsNeedSync(self)) try index_file.sync(self.io);
            }

            try renameReplace(self, texts_tmp_path, self.node_texts_path);
            try renameReplace(self, by_id_tmp_path, self.node_by_id_path);

            try writeNodeTextIndex(self, &.{});
        }

        pub fn appendNodeIndexRecord(self: Store, node: graph_mod.Node, text_span: TextSpan) !void {
            if (node.status != .active) return;
            const old_meta = try readIndexMeta(self);
            const by_id_start = if (self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
            const text_record = try appendNodeByIdIndexRecord(self, node, text_span);
            if (self.node_append_timings) |timings| timings.by_id_index_ns += storageElapsedNs(self.io, by_id_start);
            const text_index_start = if (self.node_append_timings != null) storageMonotonicNs(self.io) else 0;
            try appendNodeTextIndexRecordChecked(self, text_record, old_meta.nodes, old_meta.node_digest, old_meta.node_by_text_order_digest);
            if (self.node_append_timings) |timings| timings.node_text_index_ns += storageElapsedNs(self.io, text_index_start);
        }
        pub const appendNodeByIdIndexRecord = node_catalog_index.appendNodeByIdIndexRecord;
        pub const nodeByIdHeaderForUniformKind = node_catalog_index.nodeByIdHeaderForUniformKind;
        pub const nodeByIdCanUseUniformAppend = node_catalog_index.nodeByIdCanUseUniformAppend;
        pub const nodeByIdBatchIsDenseTail = node_catalog_index.nodeByIdBatchIsDenseTail;
        pub const nodeByIdCanAppendDerivedDenseTail = node_catalog_index.nodeByIdCanAppendDerivedDenseTail;
        pub const nodeBatchTextsFitU16 = node_catalog_index.nodeBatchTextsFitU16;
        pub const nodeBatchHasZeroLengthText = node_catalog_index.nodeBatchHasZeroLengthText;
        pub const appendNodeByIdInitialDerivedDenseBatch = node_catalog_index.appendNodeByIdInitialDerivedDenseBatch;
        pub const appendNodeByIdDerivedDenseTailBatch = node_catalog_index.appendNodeByIdDerivedDenseTailBatch;
        pub const convertNodeByIdIndexToFullRecords = node_catalog_index.convertNodeByIdIndexToFullRecords;
        pub const convertNodeByIdIndexToWideUniformRecords = node_catalog_index.convertNodeByIdIndexToWideUniformRecords;
        pub const compactNodeByIdIndexToUniformRecords = node_catalog_index.compactNodeByIdIndexToUniformRecords;
        pub const rewriteNodeByIdIndexToUniformRecordsFromTextRepair = node_catalog_index.rewriteNodeByIdIndexToUniformRecordsFromTextRepair;
        pub const compactNodeByIdIndexToDerivedTextOffsets = node_catalog_index.compactNodeByIdIndexToDerivedTextOffsets;
        pub const rewriteNodeByIdIndexToDerivedDenseLengths = node_catalog_index.rewriteNodeByIdIndexToDerivedDenseLengths;
        pub const appendNodeByIdIndexRecordsBatch = node_catalog_index.appendNodeByIdIndexRecordsBatch;

        pub fn appendNodeTextIndexRecordChecked(self: Store, record: NodeTextIndexRecord, expected_count: u64, expected_digest: u64, expected_order_digest: u64) !void {
            var expected_order = expected_order_digest;
            var compacted = false;
            while (true) {
                var old_meta = IndexMeta{
                    .nodes = expected_count,
                    .node_digest = expected_digest,
                    .node_by_text_order_digest = expected_order,
                };
                var compact_overlays = false;
                {
                    var old_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{ .mode = .read_write, .allow_directory = false });
                    defer old_file.close(self.io);
                    const old_header = try readNodeTextIndexHeaderFromFile(self, old_file);
                    const delta_header = try readNodeTextDeltaHeader(self);
                    var manifest = try readNodeTextRunManifest(self, self.allocator);
                    defer manifest.deinit(self.allocator);
                    const run_count = manifest.totalNodeCount();
                    if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;
                    if (old_header.node_count + delta_header.node_count + run_count != expected_count) return error.InvalidRecord;
                    if ((old_header.node_digest ^ delta_header.node_digest ^ manifest.nodeDigest()) != expected_digest) return error.InvalidRecord;
                    if (combinedNodeTextOrderDigestWithRuns(old_header, delta_header, manifest.entries.items) != expected_order) return error.InvalidRecord;

                    if (delta_header.node_count == 0 and old_header.node_count == 0) {
                        return try appendNodeTextIndexRecordWithHeader(self, old_file, old_header, record);
                    }
                    if (delta_header.node_count == 0) {
                        const last = try readNodeTextIndexRecordAtForHeader(self, old_file, old_header, old_header.node_count - 1);
                        if (!nodeTextIndexLessThan({}, record, last)) {
                            return try appendNodeTextIndexRecordWithHeader(self, old_file, old_header, record);
                        }
                    }

                    if (delta_header.node_count >= node_text_single_append_delta_flush_records) {
                        if (try publishNodeTextDeltaAsRunForMeta(self, old_meta, old_header, delta_header, manifest.entries.items)) |next_order| {
                            expected_order = next_order;
                            compacted = false;
                            continue;
                        }
                    }
                    if (delta_header.node_count < node_text_delta_max_records) {
                        try ensureNodeTextBaseHashFilter(self, old_header);
                        return try appendNodeTextDeltaRecord(self, record, delta_header);
                    }
                    if (try publishNodeTextRunRecordIfPossible(self, old_meta, record)) {
                        return;
                    }
                    if (compacted) return error.InvalidRecord;
                    compact_overlays = true;
                }
                if (compact_overlays) {
                    var manifest = try readNodeTextRunManifest(self, self.allocator);
                    defer manifest.deinit(self.allocator);
                    const delta_header = try readNodeTextDeltaHeader(self);
                    if (try compactNodeTextRunWindowForMeta(self, old_meta, manifest.entries.items, delta_header, 0, &.{})) |_| {
                        old_meta = try readIndexMeta(self);
                        if (old_meta.nodes != expected_count) return error.InvalidRecord;
                        if (old_meta.node_digest != expected_digest) return error.InvalidRecord;
                        expected_order = old_meta.node_by_text_order_digest;
                    } else {
                        const compacted_overlays = try compactNodeTextOverlaysForMeta(self, expected_count, expected_digest, expected_order, &.{});
                        expected_order = compacted_overlays.order_digest;
                    }
                    compacted = true;
                    continue;
                }
            }
        }

        pub fn publishNodeTextRunRecordIfPossible(self: Store, old_meta: IndexMeta, record: NodeTextIndexRecord) !bool {
            const record_digest = try nodeTextIndexRecordDigest(self, record);
            var next_meta = old_meta;
            next_meta.nodes = std.math.add(u64, next_meta.nodes, 1) catch return error.RecordTooLarge;
            next_meta.node_digest ^= record_digest;
            next_meta.event_bytes = try eventBytes(self);
            var batch = [_]NodeTextIndexRecord{record};
            return publishNodeTextRunBatchIfPossible(self, old_meta, next_meta, batch[0..], record_digest, .verify_by_id);
        }

        pub fn publishNodeTextDeltaAsRunForMeta(
            self: Store,
            meta: IndexMeta,
            base_header: NodeTextIndexHeader,
            delta_header: NodeTextIndexHeader,
            manifest_entries: []const OwnedNodeTextRunManifestEntry,
        ) !?u64 {
            return node_text_catalog_transaction.publishDeltaAsRun(
                StorageNodeTextCatalogContext.init(self),
                meta,
                base_header,
                delta_header,
                manifest_entries,
            );
        }

        pub fn appendNodeTextIndexRecord(self: Store, record: NodeTextIndexRecord) !void {
            var old_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{ .mode = .read_write, .allow_directory = false });
            defer old_file.close(self.io);
            const old_header = try readNodeTextIndexHeaderFromFile(self, old_file);
            try appendNodeTextIndexRecordWithHeader(self, old_file, old_header, record);
        }

        pub fn appendNodeTextIndexRecordWithHeader(self: Store, old_file: std.Io.File, old_header: NodeTextIndexHeader, record: NodeTextIndexRecord) !void {
            const expected_old_size = try nodeTextIndexFileSizeForHeader(old_header);
            if (try regularFileSize(self, old_file) != expected_old_size) return error.InvalidRecord;
            if (old_header.node_count == std.math.maxInt(u64)) return error.RecordTooLarge;
            _ = try nodeTextIndexFileSizeForHeader(.{
                .node_count = old_header.node_count + 1,
                .flags = old_header.flags,
                .record_len = old_header.record_len,
                .uniform_kind = old_header.uniform_kind,
            });
            const record_digest = try nodeTextIndexRecordDigest(self, record);

            if (old_header.node_count == 0) {
                return try appendSortedNodeTextIndexTail(self, old_file, old_header, record, record_digest);
            }
            const last = try readNodeTextIndexRecordAtForHeader(self, old_file, old_header, old_header.node_count - 1);
            if (!nodeTextIndexLessThan({}, record, last)) {
                if (try nodeTextRecordFitsStoredHeader(self, old_header, record)) {
                    return try appendSortedNodeTextIndexTail(self, old_file, old_header, record, record_digest);
                }
                var manifest = try readNodeTextRunManifest(self, self.allocator);
                defer manifest.deinit(self.allocator);
                if (manifest.totalNodeCount() != 0) {
                    try ensureNodeTextBaseHashFilter(self, old_header);
                    return try appendNodeTextDeltaRecord(self, record, .{ .node_count = 0 });
                }
                return try rewriteNodeTextIndexWithSortedTail(self, old_file, old_header, record);
            }
            try ensureNodeTextBaseHashFilter(self, old_header);
            return try appendNodeTextDeltaRecord(self, record, .{ .node_count = 0 });
        }

        pub fn nodeTextRecordFitsStoredHeader(self: Store, header: NodeTextIndexHeader, record: NodeTextIndexRecord) !bool {
            if (!nodeTextRecordFitsHeader(header, record)) return false;
            if (!header.hasDerivedTextSpan()) return true;
            const by_id = readNodeRecordById(self, record.id) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            return by_id.id == record.id and
                by_id.kind == record.kind and
                by_id.text_offset == record.text_offset and
                by_id.text_len == record.text_len;
        }

        pub fn rewriteNodeTextIndexWithSortedTail(self: Store, old_file: std.Io.File, old_header: NodeTextIndexHeader, record: NodeTextIndexRecord) !void {
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            const record_digest = try nodeTextIndexRecordDigestWithTexts(self, &texts, record);
            const next_count = old_header.node_count + 1;
            const output_header = nodeTextHeaderForTail(
                old_header,
                next_count,
                old_header.node_digest ^ record_digest,
                nodeTextIndexOrderDigestStep(old_header.order_digest, old_header.node_count, record),
                &.{record},
            );
            const tmp_path = try tmpPathFor(self, self.node_by_text_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            var new_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                .read = true,
                .truncate = true,
            });
            defer new_file.close(self.io);
            var writer = try StorageBufferedWriter.init(self.allocator, self.io, new_file, try storageWriteBufferCapacity(try nodeTextIndexFileSizeForHeader(output_header)));
            defer writer.deinit();

            var header_bytes: [NodeTextIndexHeader.encoded_len]u8 = undefined;
            output_header.encode(&header_bytes);
            try writer.append(&header_bytes);

            var digest = NodeTextIndexDigest{};
            var previous: ?NodeTextIndexRecord = null;
            var pos: u64 = 0;
            while (pos < old_header.node_count) : (pos += 1) {
                const old_record = try readNodeTextIndexRecordAtForHeaderWithTexts(self, old_file, old_header, pos, &texts);
                if (previous) |prev| {
                    if (!nodeTextIndexLessThan({}, prev, old_record)) return error.InvalidRecord;
                    if (prev.id == old_record.id) return error.InvalidRecord;
                }
                digest.add(old_record, try nodeTextIndexRecordDigestWithTexts(self, &texts, old_record));
                try writeNodeTextIndexRecordToWriter(&writer, output_header, old_record);
                previous = old_record;
            }
            if (digest.count != old_header.node_count) return error.InvalidRecord;
            if (digest.digest != old_header.node_digest) return error.InvalidRecord;
            if (digest.order_digest != old_header.order_digest) return error.InvalidRecord;
            if (previous) |prev| {
                if (nodeTextIndexLessThan({}, record, prev)) return error.InvalidRecord;
                if (record.id == prev.id) return error.InvalidRecord;
            }
            digest.add(record, record_digest);
            if (digest.count != output_header.node_count) return error.InvalidRecord;
            if (digest.digest != output_header.node_digest) return error.InvalidRecord;
            if (digest.order_digest != output_header.order_digest) return error.InvalidRecord;
            try writeNodeTextIndexRecordToWriter(&writer, output_header, record);
            try writer.flush();
            if (try writer.position() != try nodeTextIndexFileSizeForHeader(output_header)) return error.InvalidRecord;
            if (selfOptionsNeedSync(self)) try new_file.sync(self.io);
            try renameReplace(self, tmp_path, self.node_by_text_path);
        }

        pub fn readNodeTextDeltaHeader(self: Store) !NodeTextIndexHeader {
            if (!self.options.validate_indexes_on_read and self.node_text_delta_header_cache.valid) {
                return self.node_text_delta_header_cache.header;
            }
            var file = std.Io.Dir.cwd().openFile(self.io, self.node_by_text_delta_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    const header = NodeTextIndexHeader{ .node_count = 0 };
                    if (!self.options.validate_indexes_on_read) {
                        self.node_text_delta_header_cache.header = header;
                        self.node_text_delta_header_cache.valid = true;
                    }
                    return header;
                },
                else => |e| return e,
            };
            defer file.close(self.io);
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            if (header.node_count > node_text_delta_max_records) return error.InvalidRecord;
            const expected_size = try nodeTextIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (!self.options.validate_indexes_on_read) {
                self.node_text_delta_header_cache.header = header;
                self.node_text_delta_header_cache.valid = true;
            }
            return header;
        }

        pub fn appendNodeTextDeltaRecord(self: Store, record: NodeTextIndexRecord, old_header_hint: NodeTextIndexHeader) !void {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_delta_path, .{ .mode = .read_write, .allow_directory = false });
            var file_open = true;
            defer if (file_open) file.close(self.io);
            const old_header = try readNodeTextIndexHeaderFromFile(self, file);
            if (old_header.node_count != old_header_hint.node_count) return error.InvalidRecord;
            if (old_header.node_count >= node_text_delta_max_records) return core.Error.BudgetExceeded;
            const expected_old_size = try nodeTextIndexFileSizeForHeader(old_header);
            if (try regularFileSize(self, file) != expected_old_size) return error.InvalidRecord;
            const next_count = old_header.node_count + 1;

            if (old_header.node_count == 0) {
                const record_digest = try nodeTextIndexRecordDigest(self, record);
                const new_header = nodeTextIndexHeaderForSortedUniqueHashRecords(&.{record}, record_digest, nodeTextIndexOrderDigestStep(0, 0, record));
                try writeNodeTextIndexRecordAt(self, file, new_header, 0, record);
                try writeNodeTextIndexHeader(self, file, new_header);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
                self.node_text_delta_header_cache.header = new_header;
                self.node_text_delta_header_cache.valid = true;
                refreshNodeTextDeltaRunCache(self, new_header);
                return;
            }

            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            var records = std.ArrayList(NodeTextIndexRecord).empty;
            defer records.deinit(self.allocator);
            try records.ensureTotalCapacity(self.allocator, @intCast(next_count));

            var old_digest = NodeTextIndexDigest{};
            var pos: u64 = 0;
            while (pos < old_header.node_count) : (pos += 1) {
                const old_record = try readNodeTextIndexRecordAtForHeaderWithTexts(self, file, old_header, pos, &texts);
                old_digest.add(old_record, try nodeTextIndexRecordDigestWithTexts(self, &texts, old_record));
                records.appendAssumeCapacity(old_record);
            }
            if (old_digest.count != old_header.node_count) return error.InvalidRecord;
            if (old_digest.digest != old_header.node_digest) return error.InvalidRecord;
            if (old_digest.order_digest != old_header.order_digest) return error.InvalidRecord;

            records.appendAssumeCapacity(record);
            std.mem.sort(NodeTextIndexRecord, records.items, {}, nodeTextIndexLessThan);

            var next_digest = NodeTextIndexDigest{};
            var previous: ?NodeTextIndexRecord = null;
            for (records.items) |sorted_record| {
                if (previous) |prev| {
                    if (!nodeTextIndexLessThan({}, prev, sorted_record)) return error.InvalidRecord;
                }
                next_digest.add(sorted_record, try nodeTextIndexRecordDigestWithTexts(self, &texts, sorted_record));
                previous = sorted_record;
            }
            if (next_digest.count != next_count) return error.InvalidRecord;

            file.close(self.io);
            file_open = false;

            const tmp_path = try tmpPathFor(self, self.node_by_text_delta_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            var next_header = NodeTextIndexHeader{ .node_count = 0 };
            {
                var tmp_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer tmp_file.close(self.io);
                next_header = nodeTextIndexHeaderForSortedUniqueHashRecords(records.items, next_digest.digest, next_digest.order_digest);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, tmp_file, try storageWriteBufferCapacity(try nodeTextIndexFileSizeForHeader(next_header)));
                defer writer.deinit();

                var header_bytes: [NodeTextIndexHeader.encoded_len]u8 = undefined;
                next_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                for (records.items) |sorted_record| {
                    try writeNodeTextIndexRecordToWriter(&writer, next_header, sorted_record);
                }
                try writer.flush();
                if (selfOptionsNeedSync(self)) try tmp_file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.node_by_text_delta_path);
            self.node_text_delta_header_cache.header = next_header;
            self.node_text_delta_header_cache.valid = true;
            refreshNodeTextDeltaRunCache(self, next_header);
        }

        pub fn compactNodeTextDeltaBudgeted(self: Store, max_delta_records: u64) !NodeTextDeltaMaintenanceResult {
            return node_text_maintenance.compactDelta(self, max_delta_records);
        }

        pub fn compactNodeTextRunsBudgeted(self: Store, max_run_records: u64) !NodeTextRunMaintenanceResult {
            return compactNodeTextRunsBudgetedExcept(self, max_run_records, &.{});
        }

        pub fn compactNodeTextRunsBudgetedRetainingRegistry(self: Store, max_run_records: u64, registry: *const NodeTextRunRetentionRegistry) !NodeTextRunMaintenanceResult {
            const pinned_paths = try registry.activeManifestPaths(self.allocator);
            defer self.allocator.free(pinned_paths);
            return compactNodeTextRunsBudgetedExcept(self, max_run_records, pinned_paths);
        }

        pub fn compactNodeTextRunsBudgetedWithProcessLeases(self: Store, max_run_records: u64) !NodeTextRunMaintenanceResult {
            return compactNodeTextRunsBudgetedExceptAndProcessLeases(self, max_run_records, &.{});
        }

        pub fn compactNodeTextRunsBudgetedExceptAndProcessLeases(
            self: Store,
            max_run_records: u64,
            pinned_manifest_paths: []const []const u8,
        ) !NodeTextRunMaintenanceResult {
            const protected_paths = try manifest_process_lease.pinnedPaths(self, .node_text_run, self.allocator, pinned_manifest_paths);
            defer freeOwnedManifestPathList(self.allocator, protected_paths);
            return compactNodeTextRunsBudgetedExcept(self, max_run_records, protected_paths);
        }

        pub fn compactNodeTextRunsBudgetedExcept(self: Store, max_run_records: u64, pinned_manifest_paths: []const []const u8) !NodeTextRunMaintenanceResult {
            return node_text_maintenance.compactRuns(self, max_run_records, pinned_manifest_paths);
        }

        pub fn gcUnreferencedNodeTextRuns(self: Store) !NodeTextRunGcResult {
            return gcUnreferencedNodeTextRunsExcept(self, &.{});
        }

        pub fn gcUnreferencedNodeTextRunsExcept(self: Store, pinned_manifest_paths: []const []const u8) !NodeTextRunGcResult {
            const result = try node_text_run_gc.collect(self, pinned_manifest_paths);
            return .{
                .deleted_runs = result.deleted_runs,
                .deleted_manifests = result.deleted_manifests,
            };
        }

        pub fn addNodeTextRunManifestLivePaths(self: Store, manifest_path: []const u8, live_run_paths: *std.StringHashMap([]u8)) !void {
            var manifest = try readNodeTextRunManifestFile(self, self.allocator, manifest_path);
            defer manifest.deinit(self.allocator);
            try live_run_paths.ensureUnusedCapacity(@intCast(manifest.entries.items.len));
            for (manifest.entries.items) |entry| {
                if (live_run_paths.contains(entry.path)) continue;
                const owned_path = try self.allocator.dupe(u8, entry.path);
                live_run_paths.putAssumeCapacityNoClobber(owned_path, owned_path);
            }
        }

        pub fn nodeTextRunPathsForPinnedManifests(self: Store, pinned_manifest_paths: []const []const u8) !std.StringHashMap([]u8) {
            var run_paths = std.StringHashMap([]u8).init(self.allocator);
            errdefer freeOwnedPathSet(self, &run_paths);
            for (pinned_manifest_paths) |manifest_path| {
                try addNodeTextRunManifestLivePaths(self, manifest_path, &run_paths);
            }
            return run_paths;
        }

        pub fn freeOwnedPathSet(self: Store, path_set: *std.StringHashMap([]u8)) void {
            var iter = path_set.valueIterator();
            while (iter.next()) |path| self.allocator.free(path.*);
            path_set.deinit();
        }

        pub fn compactNodeTextDeltaForMeta(self: Store, expected_count: u64, expected_digest: u64, expected_order_digest: u64) !u64 {
            return node_text_catalog_transaction.compactDelta(
                StorageNodeTextCatalogContext.init(self),
                expected_count,
                expected_digest,
                expected_order_digest,
            );
        }

        pub fn writeEmptyNodeTextDelta(self: Store) !void {
            const tmp_path = try tmpPathFor(self, self.node_by_text_delta_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                try writeNodeTextIndexHeader(self, file, .{ .node_count = 0 });
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.node_by_text_delta_path);
            self.node_text_delta_header_cache.header = .{ .node_count = 0 };
            self.node_text_delta_header_cache.valid = true;
            self.node_text_delta_run_cache.clear();
        }

        pub fn deleteNodeTextRunManifest(self: Store) !void {
            _ = try deleteNodeTextRunManifestExcept(self, &.{});
        }

        pub fn deleteNodeTextRunManifestExcept(self: Store, pinned_manifest_paths: []const []const u8) !NodeTextRunGcResult {
            invalidateNodeTextRunManifestCache(self);
            std.Io.Dir.cwd().deleteFile(self.io, self.node_text_run_manifest_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            // The CURRENT unlink must be durable before GC removes the manifest
            // and run files it named. Otherwise a crash can resurrect CURRENT and
            // leave it pointing at files that were already reclaimed.
            try invalidateNodeTextRunCurrent(self);
            return gcUnreferencedNodeTextRunsExceptAndProcessLeases(self, pinned_manifest_paths);
        }

        pub fn compactNodeTextRunWindowForMeta(
            self: Store,
            meta: IndexMeta,
            manifest_entries: []const OwnedNodeTextRunManifestEntry,
            delta_header: NodeTextIndexHeader,
            max_run_records: u64,
            pinned_manifest_paths: []const []const u8,
        ) !?NodeTextRunMaintenanceResult {
            return node_text_catalog_transaction.compactRunWindow(
                StorageNodeTextCatalogContext.init(self),
                meta,
                manifest_entries,
                delta_header,
                max_run_records,
                pinned_manifest_paths,
            );
        }

        pub fn compactNodeTextOverlaysForMeta(
            self: Store,
            expected_count: u64,
            expected_digest: u64,
            expected_order_digest: u64,
            pinned_manifest_paths: []const []const u8,
        ) !node_text_catalog_transaction.OverlayCompactionResult {
            return node_text_catalog_transaction.compactOverlays(
                StorageNodeTextCatalogContext.init(self),
                expected_count,
                expected_digest,
                expected_order_digest,
                pinned_manifest_paths,
            );
        }
        pub const writeMergedNodeTextIndexBatch = node_catalog_index.writeMergedNodeTextIndexBatch;

        pub fn publishNodeTextRunBatchIfPossible(
            self: Store,
            old_meta: IndexMeta,
            next_meta: IndexMeta,
            batch_records: []NodeTextIndexRecord,
            batch_digest: u64,
            span_derive_mode: node_text_catalog_transaction.SpanDeriveMode,
        ) !bool {
            return node_text_catalog_transaction.publishRunBatch(
                StorageNodeTextCatalogContext.init(self),
                old_meta,
                next_meta,
                batch_records,
                batch_digest,
                span_derive_mode,
            );
        }

        pub fn nodeTextRecordsCanDeriveSpansFromById(self: Store, records: []const NodeTextIndexRecord) !bool {
            if (records.len == 0) return false;
            var node_file = std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer node_file.close(self.io);
            const node_header = try readNodeByIdHeaderFromFile(self, node_file);
            if (node_header.node_count == 0) return false;
            const node_file_size = try regularFileSize(self, node_file);
            if (node_file_size != try nodeByIdFileSizeForHeaderStore(self, node_header)) return false;
            var node_map = openReadOnlyMemoryMap(self.io, node_file, node_file_size) catch null;
            defer if (node_map) |*mapped| mapped.destroy(self.io);

            for (records) |record| {
                if (record.id == 0 or record.id > node_header.max_node_id) return false;
                const by_id = if (node_map) |*mapped|
                    try readNodeByIdRecordFromMap(node_header, mapped, record.id)
                else
                    try readNodeByIdRecordAt(self, node_file, node_header, record.id);
                if (by_id.id != record.id or
                    by_id.kind != record.kind or
                    by_id.text_offset != record.text_offset or
                    by_id.text_len != record.text_len)
                {
                    return false;
                }
            }
            return true;
        }

        pub fn buildNodeTextRunHashFilterForRecords(self: Store, records: []const NodeTextIndexRecord) ![]u8 {
            const filter_len = nodeTextRunHashFilterLenForRecords(@intCast(records.len));
            if (filter_len == 0) return try self.allocator.alloc(u8, 0);
            const filter = try self.allocator.alloc(u8, filter_len);
            @memset(filter, 0);
            for (records) |record| nodeTextRunHashFilterSet(filter, record.hash);
            return filter;
        }

        pub fn buildNodeTextRunHashFilterFromFile(self: Store, path: []const u8, expected_records: u64) ![]u8 {
            const filter_len = nodeTextRunHashFilterLenForRecords(expected_records);
            if (filter_len == 0) return try self.allocator.alloc(u8, 0);
            var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            if (header.node_count != expected_records) return error.InvalidRecord;
            const expected_size = try nodeTextIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var texts: ?NodeTextsView = null;
            defer if (texts) |*view| view.deinit();
            var nodes: ?NodeByIdIndexView = null;
            defer if (nodes) |*view| view.deinit();
            if (header.hasDerivedHash()) {
                texts = try NodeTextsView.open(self);
                if (header.hasDerivedTextSpan()) {
                    const meta = try readCurrentIndexMeta(self);
                    nodes = try NodeByIdIndexView.open(self, meta);
                }
            }

            const filter = try self.allocator.alloc(u8, filter_len);
            errdefer self.allocator.free(filter);
            @memset(filter, 0);
            var pos: u64 = 0;
            while (pos < header.node_count) : (pos += 1) {
                const hash = try readNodeTextIndexRecordHashAtForHeader(self, file, header, pos, if (texts) |*view| view else null, if (nodes) |*view| view else null);
                nodeTextRunHashFilterSet(filter, hash);
            }
            return filter;
        }

        pub fn writeNodeTextDeltaBatchIfPossible(
            self: Store,
            old_meta: IndexMeta,
            batch_records: []NodeTextIndexRecord,
            batch_digest: u64,
            next_digest: u64,
        ) !bool {
            return node_text_catalog_transaction.writeDeltaBatch(
                StorageNodeTextCatalogContext.init(self),
                old_meta,
                batch_records,
                batch_digest,
                next_digest,
            );
        }
        pub const appendSortedNodeTextIndexTail = node_catalog_index.appendSortedNodeTextIndexTail;

        pub fn readAllNodeTextIndexRecords(self: Store, allocator: std.mem.Allocator) !std.ArrayList(NodeTextIndexRecord) {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{});
            defer file.close(self.io);
            const header = try readNodeTextIndexHeaderFromFile(self, file);
            const expected_size = try nodeTextIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            var out = std.ArrayList(NodeTextIndexRecord).empty;
            errdefer out.deinit(allocator);
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            var pos: u64 = 0;
            while (pos < header.node_count) : (pos += 1) {
                try out.append(allocator, try readNodeTextIndexRecordAtForHeaderWithTexts(self, file, header, pos, &texts));
            }
            const delta_header = try readNodeTextDeltaHeader(self);
            if (delta_header.node_count != 0) {
                var delta_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_delta_path, .{});
                defer delta_file.close(self.io);
                pos = 0;
                while (pos < delta_header.node_count) : (pos += 1) {
                    try out.append(allocator, try readNodeTextIndexRecordAtForHeaderWithTexts(self, delta_file, delta_header, pos, &texts));
                }
            }
            var manifest = try readNodeTextRunManifest(self, allocator);
            defer manifest.deinit(allocator);
            for (manifest.entries.items) |entry| {
                var run_file = try std.Io.Dir.cwd().openFile(self.io, entry.path, .{});
                defer run_file.close(self.io);
                const run_header = try readNodeTextIndexHeaderFromFile(self, run_file);
                if (run_header.node_count != entry.node_count or
                    run_header.node_digest != entry.node_digest or
                    run_header.order_digest != entry.order_digest) return error.InvalidRecord;
                pos = 0;
                while (pos < run_header.node_count) : (pos += 1) {
                    try out.append(allocator, try readNodeTextIndexRecordAtForHeaderWithTexts(self, run_file, run_header, pos, &texts));
                }
            }
            if (delta_header.node_count != 0 or manifest.entries.items.len != 0) {
                std.mem.sort(NodeTextIndexRecord, out.items, {}, nodeTextIndexLessThan);
            }
            return out;
        }

        pub fn writeNodeTextIndex(self: Store, records: []const NodeTextIndexRecord) !void {
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            var node_digest: u64 = 0;
            for (records) |record| node_digest ^= try nodeTextIndexRecordDigestWithTexts(self, &texts, record);
            try writeNodeTextIndexWithDigestWithTexts(self, records, node_digest, &texts);
        }

        pub fn writeNodeTextIndexWithDigest(self: Store, records: []const NodeTextIndexRecord, node_digest: u64) !void {
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            try writeNodeTextIndexWithDigestWithTexts(self, records, node_digest, &texts);
        }
        pub const writeNodeTextIndexWithDigestWithTexts = node_catalog_index.writeNodeTextIndexWithDigestWithTexts;
        pub const storedNodeTextsEqual = node_catalog_index.storedNodeTextsEqual;
        pub const sortedNodeTextRecordsHaveUniqueTextHashes = node_catalog_index.sortedNodeTextRecordsHaveUniqueTextHashes;
        pub const writeNodeTextIndexFromRepairSpool = node_catalog_index.writeNodeTextIndexFromRepairSpool;

        pub fn validateNodeIndexAppend(self: Store, node: graph_mod.Node) !void {
            if (node.status != .active) return;
            const node_id = node.id.toInt();
            if (node_id == 0 or node_id == std.math.maxInt(u64)) return core.Error.InvalidId;
            const meta = try readCurrentIndexMetaForAppend(self);
            if (self.options.validate_indexes_on_read and !try nodeIndexValid(self, meta.nodes)) return error.InvalidRecord;
            var index_file = std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => |e| return e,
            };
            defer index_file.close(self.io);
            const header = try readNodeByIdHeaderFromFile(self, index_file);
            if (header.node_count != meta.nodes) return error.InvalidRecord;
            if (header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (header.node_count > header.max_node_id) return error.InvalidRecord;
            const expected_size = try nodeByIdFileSizeForHeaderStore(self, header);
            if (try regularFileSize(self, index_file) != expected_size) return error.InvalidRecord;
            const empty_uniform = header.node_count == 0;
            const short_text_len = nodeTextLenFitsU16(node.text.len);
            const would_convert = !empty_uniform and header.hasUniformKind() and header.uniform_kind != @intFromEnum(node.kind);
            const derived_dense_tail = header.hasDerivedTextOffset() and !would_convert and short_text_len and
                header.max_node_id != std.math.maxInt(u64) and node_id == header.max_node_id + 1;
            const would_expand_derived = !would_convert and header.hasDerivedTextOffset() and !derived_dense_tail;
            const would_widen_uniform = !would_convert and header.hasUniformKind() and header.hasShortTextLen() and !short_text_len;
            const next_flags: u16 = if (empty_uniform)
                NodeByIdHeader.flag_uniform_kind | if (short_text_len) NodeByIdHeader.flag_short_text_len else 0
            else if (would_convert)
                0
            else if (derived_dense_tail)
                NodeByIdHeader.flag_uniform_kind | NodeByIdHeader.flag_short_text_len | NodeByIdHeader.flag_derived_text_offset
            else if (would_expand_derived)
                NodeByIdHeader.flag_uniform_kind | if (short_text_len) NodeByIdHeader.flag_short_text_len else 0
            else if (would_widen_uniform)
                header.flags & ~NodeByIdHeader.flag_short_text_len
            else
                header.flags;
            const next_record_len: u16 = if (empty_uniform)
                if (short_text_len) NodeByIdRecord.uniform_short_text_len_encoded_len else NodeByIdRecord.uniform_encoded_len
            else if (would_convert)
                NodeByIdRecord.encoded_len
            else if (derived_dense_tail)
                NodeByIdRecord.uniform_short_derived_offset_encoded_len
            else if (would_expand_derived)
                if (short_text_len) NodeByIdRecord.uniform_short_text_len_encoded_len else NodeByIdRecord.uniform_encoded_len
            else if (would_widen_uniform)
                NodeByIdRecord.uniform_encoded_len
            else
                header.record_len;
            const next_node_count_for_size = if (derived_dense_tail) header.node_count + 1 else header.node_count;
            _ = try nodeByIdFileSizeForHeaderStore(self, .{
                .max_node_id = @max(header.max_node_id, node_id),
                .node_count = next_node_count_for_size,
                .node_digest = header.node_digest,
                .flags = next_flags,
                .record_len = next_record_len,
                .uniform_kind = if (empty_uniform) @intFromEnum(node.kind) else if (would_convert) 0 else header.uniform_kind,
            });
            if (node_id > header.max_node_id) return;
            const existing = try readNodeByIdRecordAt(self, index_file, header, node_id);
            if (existing.id == 0 and header.node_count == header.max_node_id) return error.InvalidRecord;
            if (existing.id != 0) return core.Error.InvalidId;
        }

        pub fn validateNodeBatchAppend(self: Store, nodes: []const graph_mod.Node, meta: IndexMeta) !void {
            var seen = std.AutoHashMap(u64, void).init(self.allocator);
            defer seen.deinit();
            try seen.ensureTotalCapacity(@intCast(nodes.len));

            var index_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{});
            defer index_file.close(self.io);
            const header = try readNodeByIdHeaderFromFile(self, index_file);
            if (header.node_count != meta.nodes) return error.InvalidRecord;
            if (header.node_digest != meta.node_digest) return error.InvalidRecord;
            if (header.node_count > header.max_node_id) return error.InvalidRecord;
            const expected_size = try nodeByIdFileSizeForHeaderStore(self, header);
            if (try regularFileSize(self, index_file) != expected_size) return error.InvalidRecord;
            if (self.options.validate_indexes_on_read and !try nodeIndexValid(self, meta.nodes)) return error.InvalidRecord;

            var texts_file = try std.Io.Dir.cwd().openFile(self.io, self.node_texts_path, .{});
            defer texts_file.close(self.io);
            _ = try regularFileSize(self, texts_file);

            var text_index_file = try std.Io.Dir.cwd().openFile(self.io, self.node_by_text_path, .{});
            defer text_index_file.close(self.io);
            const text_header = try readNodeTextIndexHeaderFromFile(self, text_index_file);
            const delta_header = try readNodeTextDeltaHeader(self);
            var manifest = try readNodeTextRunManifest(self, self.allocator);
            defer manifest.deinit(self.allocator);
            const run_count = manifest.totalNodeCount();
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;
            if (text_header.node_count + delta_header.node_count + run_count != meta.nodes) return error.InvalidRecord;
            if ((text_header.node_digest ^ delta_header.node_digest ^ manifest.nodeDigest()) != meta.node_digest) return error.InvalidRecord;
            if (combinedNodeTextOrderDigestWithRuns(text_header, delta_header, manifest.entries.items) != meta.node_by_text_order_digest) return error.InvalidRecord;
            if (try regularFileSize(self, text_index_file) != try nodeTextIndexFileSizeForHeader(text_header)) return error.InvalidRecord;
            if (try fileSizeOrZero(self, self.node_by_text_delta_path) != try nodeTextIndexFileSizeForHeader(delta_header)) return error.InvalidRecord;

            var next_count = meta.nodes;
            var next_max = header.max_node_id;
            var next_record_len = header.record_len;
            var next_flags = header.flags;
            var next_uniform_kind = header.uniform_kind;
            const derived_dense_tail_batch = nodeByIdCanAppendDerivedDenseTail(header, nodes);
            const has_zero_length_text = nodeBatchHasZeroLengthText(nodes);
            if (header.hasUniformKind() and (has_zero_length_text or !nodeByIdCanUseUniformAppend(header, nodes))) {
                next_record_len = NodeByIdRecord.encoded_len;
                next_flags = 0;
                next_uniform_kind = 0;
            } else if (derived_dense_tail_batch) {
                next_record_len = NodeByIdRecord.uniform_short_derived_offset_encoded_len;
                next_flags = NodeByIdHeader.flag_uniform_kind | NodeByIdHeader.flag_short_text_len | NodeByIdHeader.flag_derived_text_offset;
            } else if (header.hasDerivedTextOffset()) {
                next_record_len = NodeByIdRecord.uniform_encoded_len;
                next_flags = NodeByIdHeader.flag_uniform_kind;
            } else if (header.node_count == 0 and !has_zero_length_text and nodeByIdCanUseUniformAppend(header, nodes)) {
                const short_text_lens = nodeBatchTextsFitU16(nodes);
                next_record_len = if (short_text_lens) NodeByIdRecord.uniform_short_text_len_encoded_len else NodeByIdRecord.uniform_encoded_len;
                next_flags = NodeByIdHeader.flag_uniform_kind | if (short_text_lens) NodeByIdHeader.flag_short_text_len else 0;
                next_uniform_kind = @intFromEnum(nodes[0].kind);
            } else if (header.hasUniformKind() and header.hasShortTextLen() and !nodeBatchTextsFitU16(nodes)) {
                next_record_len = NodeByIdRecord.uniform_encoded_len;
                next_flags = header.flags & ~NodeByIdHeader.flag_short_text_len;
            }
            for (nodes) |node| {
                if (node.status != .active) return core.Error.Unsupported;
                if (node.text.len > maxBinaryNodeTextLen()) return error.RecordTooLarge;
                try graph_mod.validateNodeText(node.text);
                const node_id = node.id.toInt();
                if (node_id == 0 or node_id == std.math.maxInt(u64)) return core.Error.InvalidId;
                const entry = try seen.getOrPut(node_id);
                if (entry.found_existing) return core.Error.InvalidId;
                next_count = std.math.add(u64, next_count, 1) catch return error.RecordTooLarge;
                next_max = @max(next_max, node_id);
                _ = try nodeByIdFileSizeForHeaderStore(self, .{
                    .max_node_id = next_max,
                    .node_count = if (derived_dense_tail_batch) next_count else header.node_count,
                    .node_digest = header.node_digest,
                    .flags = next_flags,
                    .record_len = next_record_len,
                    .uniform_kind = next_uniform_kind,
                });
                if (node_id <= header.max_node_id) {
                    const existing = try readNodeByIdRecordAt(self, index_file, header, node_id);
                    if (existing.id == 0 and header.node_count == header.max_node_id) return error.InvalidRecord;
                    if (existing.id != 0) return core.Error.InvalidId;
                }
            }
        }

        pub fn validateNodeIndexAppendWithRepair(self: Store, node: graph_mod.Node) !void {
            validateNodeIndexAppend(self, node) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    try repairPersistentIndexesFromLog(self);
                    return try validateNodeIndexAppend(self, node);
                },
                else => |e| return e,
            };
        }

        pub fn validateEdgeAppend(self: Store, edge: graph_mod.Edge) !void {
            if (edge.id == .none or edge.id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
            if (edge.src == .none or edge.dst == .none) return core.Error.InvalidId;
            if (edge.src.toInt() == std.math.maxInt(u64) or edge.dst.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
            const meta = try readCurrentIndexMetaForAppend(self);
            var id_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer id_file.close(self.io);
            const id_header = try validateEdgeIndexHeaderForAppend(self, id_file, .id, meta);
            if (id_header.edge_count != 0) {
                const last = try readEdgeIndexRecordAt(self, id_file, id_header, id_header.edge_count - 1);
                if (last.edge_id > meta.max_edge_id_seen) return error.InvalidRecord;
            }
            var src_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_src_path, .{});
            defer src_file.close(self.io);
            _ = try validateEdgeIndexHeaderForAppend(self, src_file, .src, meta);
            var dst_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_dst_path, .{});
            defer dst_file.close(self.io);
            _ = try validateEdgeIndexHeaderForAppend(self, dst_file, .dst, meta);
            if (self.options.validate_indexes_on_read) {
                if (!try edgeIndexesValidatedAndMatchMeta(self, meta)) return error.InvalidRecord;
            }
            if (try edgeIdExistsInFile(self, id_file, id_header, edge.id.toInt())) return core.Error.InvalidId;
            if (edge.id.toInt() <= meta.max_edge_id_seen) {
                if (try edgeTombstoneContains(self, edge.id.toInt())) return core.Error.InvalidId;
                if (try edgeIdExistsInSegmentOverlay(self, meta, edge.id.toInt())) return core.Error.InvalidId;
            }
            var src = (try readNodeById(self, self.allocator, edge.src)) orelse return core.Error.NotFound;
            defer src.deinit(self.allocator);
            var dst = (try readNodeById(self, self.allocator, edge.dst)) orelse return core.Error.NotFound;
            defer dst.deinit(self.allocator);
        }

        pub fn validateEdgeAppendWithRepair(self: Store, edge: graph_mod.Edge) !void {
            validateEdgeAppend(self, edge) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    try repairPersistentIndexesFromLog(self);
                    return try validateEdgeAppend(self, edge);
                },
                else => |e| return e,
            };
        }

        pub fn validateEdgeBatchAppend(
            self: Store,
            edges: []const graph_mod.Edge,
            meta: IndexMeta,
            edge_records: *std.ArrayList(EdgeIndexRecord),
            next_meta: *IndexMeta,
            segment_delta_append: bool,
        ) !void {
            var node_view = try NodeByIdIndexView.open(self, meta);
            defer node_view.deinit();

            var id_file: ?std.Io.File = null;
            defer if (id_file) |file| file.close(self.io);
            var id_header: ?EdgeIndexHeader = null;
            const ids_known_new = if (segment_delta_append) true else blk: {
                id_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
                id_header = try validateEdgeIndexHeaderForAppend(self, id_file.?, .id, meta);
                if (id_header.?.edge_count != 0) {
                    const last = try readEdgeIndexRecordAt(self, id_file.?, id_header.?, id_header.?.edge_count - 1);
                    if (last.edge_id > meta.max_edge_id_seen) return error.InvalidRecord;
                }
                var src_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_src_path, .{});
                defer src_file.close(self.io);
                _ = try validateEdgeIndexHeaderForAppend(self, src_file, .src, meta);
                var dst_file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_dst_path, .{});
                defer dst_file.close(self.io);
                _ = try validateEdgeIndexHeaderForAppend(self, dst_file, .dst, meta);

                if (self.options.validate_indexes_on_read) {
                    if (!try edgeIndexesValidatedAndMatchMeta(self, meta)) return error.InvalidRecord;
                }
                break :blk try edgeBatchIdsAppendAfterTail(self, id_file.?, id_header.?, meta, edges);
            };
            if (segment_delta_append and !ids_known_new) return error.InvalidRecord;
            var seen = std.AutoHashMap(u64, void).init(self.allocator);
            defer seen.deinit();
            if (!ids_known_new) try seen.ensureTotalCapacity(@intCast(edges.len));
            var node_cache = EdgeBatchNodeExistenceCache{};
            var tombstone_view: ?EdgeTombstoneIndexView = null;
            defer if (tombstone_view) |*view| view.deinit();
            var tombstone_view_loaded = false;

            next_meta.* = meta;
            for (edges) |edge| {
                if (edge.status != .active) return core.Error.Unsupported;
                const record = edgeIndexRecordFromEdge(edge);
                if (record.edge_id == 0 or record.edge_id == std.math.maxInt(u64)) return core.Error.InvalidId;
                if (record.src == 0 or record.dst == 0 or record.src == std.math.maxInt(u64) or record.dst == std.math.maxInt(u64)) return core.Error.InvalidId;
                if (!ids_known_new) {
                    const entry = try seen.getOrPut(record.edge_id);
                    if (entry.found_existing) return core.Error.InvalidId;
                    if (try edgeIdExistsInFile(self, id_file.?, id_header.?, record.edge_id)) return core.Error.InvalidId;
                    if (record.edge_id <= meta.max_edge_id_seen) {
                        if (!tombstone_view_loaded) {
                            const tombstone_header = try readEdgeTombstoneIndexHeader(self);
                            if (tombstone_header.count != 0) tombstone_view = try EdgeTombstoneIndexView.open(self);
                            tombstone_view_loaded = true;
                        }
                        if (tombstone_view) |*view| {
                            if (try view.contains(record.edge_id)) return core.Error.InvalidId;
                        }
                        if (try edgeIdExistsInSegmentOverlay(self, meta, record.edge_id)) return core.Error.InvalidId;
                    }
                }
                if (!try node_cache.nodeExists(&node_view, record.src)) return core.Error.NotFound;
                if (!try node_cache.nodeExists(&node_view, record.dst)) return core.Error.NotFound;
                edge_records.appendAssumeCapacity(record);
                next_meta.edges = std.math.add(u64, next_meta.edges, 1) catch return error.RecordTooLarge;
                next_meta.edge_digest ^= edgeRecordDigest(record);
                next_meta.edge_indexed_edges = std.math.add(u64, next_meta.edge_indexed_edges, 1) catch return error.RecordTooLarge;
                next_meta.edge_index_digest ^= edgeRecordDigest(record);
                next_meta.max_edge_id_seen = @max(next_meta.max_edge_id_seen, record.edge_id);
            }
            _ = try edgeIndexFileSize(next_meta.edge_indexed_edges);
        }

        pub fn edgeBatchIdsAppendAfterTail(self: Store, id_file: std.Io.File, id_header: EdgeIndexHeader, meta: IndexMeta, edges: []const graph_mod.Edge) !bool {
            if (edges.len == 0) return true;
            const first_id = edges[0].id.toInt();
            if (first_id == 0 or first_id == std.math.maxInt(u64)) return false;
            if (first_id <= meta.max_edge_id_seen) return false;

            if (id_header.edge_count != 0) {
                const last = try readEdgeIndexRecordAt(self, id_file, id_header, id_header.edge_count - 1);
                if (last.edge_id >= first_id) return false;
            }

            var previous = first_id;
            var pos: usize = 1;
            while (pos < edges.len) : (pos += 1) {
                const current = edges[pos].id.toInt();
                if (current == 0 or current == std.math.maxInt(u64)) return false;
                if (current <= previous) return false;
                previous = current;
            }
            return true;
        }

        pub fn validateEdgeIndexHeaderForAppend(self: Store, file: std.Io.File, order: EdgeIndexOrder, meta: IndexMeta) !EdgeIndexHeader {
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != order) return error.InvalidRecord;
            if (header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            if (header.order_digest != edgeOrderDigestForMeta(meta, order)) return error.InvalidRecord;
            const expected_size = try edgeIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            return header;
        }

        pub fn edgeIdExists(self: Store, edge_id: core.EdgeId) !bool {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer file.close(self.io);
            const meta = try readCurrentIndexMeta(self);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != .id) return error.InvalidRecord;
            if (header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            if (header.order_digest != edgeOrderDigestForMeta(meta, .id)) return error.InvalidRecord;
            const expected_size = try edgeIndexFileSizeForHeader(header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            return try edgeIdExistsInFile(self, file, header, edge_id.toInt());
        }

        pub fn visibleEdgeIdExists(self: Store, edge_id: core.EdgeId) !bool {
            const raw_id = edge_id.toInt();
            if (raw_id == 0 or raw_id == std.math.maxInt(u64)) return false;
            if (try edgeTombstoneContains(self, raw_id)) return false;
            if (try edgeIdExists(self, edge_id)) return true;
            const meta = try readCurrentIndexMeta(self);
            return try edgeIdExistsInSegmentOverlay(self, meta, raw_id);
        }

        pub fn edgeSegmentMetaSummaryCurrent(self: Store, meta: IndexMeta) !bool {
            if (meta.edge_segment_edges == 0) return false;
            try meta.edge_segment_id_runs.validate();
            if (meta.edge_segment_id_runs.run_count == 0) return false;
            if (try meta.edge_segment_id_runs.coveredCount() != meta.edge_segment_edges) return false;
            if (try edgeSegmentManifestCoveredPhysicalEdges(self, meta, meta.edge_segment_edges) == null) {
                if (!try edgeSegmentManifestCoversVisibleEdges(self, meta, meta.edge_segment_edges)) return false;
            }
            const current_path = (try readEdgeSegmentCurrentPath(self, self.allocator)) orelse return false;
            defer self.allocator.free(current_path);
            const expected_path = try edgeSegmentManifestEpochPathWithAllocator(self, self.allocator, meta.edge_segment_edges, meta.edge_segment_manifest_digest);
            defer self.allocator.free(expected_path);
            return std.mem.eql(u8, current_path, expected_path);
        }

        pub fn edgeSegmentMetaSummaryReadable(self: Store, meta: IndexMeta) !bool {
            if (meta.edge_segment_edges == 0) return false;
            try meta.edge_segment_id_runs.validate();
            if (meta.edge_segment_id_runs.run_count == 0) return false;
            if (try meta.edge_segment_id_runs.coveredCount() != meta.edge_segment_edges) return false;
            const current_path = (try readEdgeSegmentCurrentPath(self, self.allocator)) orelse return false;
            defer self.allocator.free(current_path);
            const expected_path = try edgeSegmentManifestEpochPathWithAllocator(self, self.allocator, meta.edge_segment_edges, meta.edge_segment_manifest_digest);
            defer self.allocator.free(expected_path);
            if (!std.mem.eql(u8, current_path, expected_path)) return false;
            var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return false,
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);
            return manifest.totalEdgeCount() == meta.edge_segment_edges;
        }

        pub fn edgeSegmentMetaSummaryContains(self: Store, meta: IndexMeta, edge_id: u64) !?bool {
            if (!try edgeSegmentMetaSummaryCurrent(self, meta)) return null;
            return meta.edge_segment_id_runs.contains(edge_id);
        }

        pub fn edgeSegmentMetaSummaryIntersects(self: Store, meta: IndexMeta, ids_by_id: []const u64) !?bool {
            if (!try edgeSegmentMetaSummaryCurrent(self, meta)) return null;
            return meta.edge_segment_id_runs.intersectsSortedIds(ids_by_id);
        }

        pub fn edgeIdSetIntersectsSegmentOverlayAfterEligibility(
            self: Store,
            meta: IndexMeta,
            ids_by_id: []const u64,
            min_edge_id: u64,
            max_edge_id: u64,
            edge_segment_summary_current: bool,
        ) !bool {
            if (edge_segment_summary_current) {
                return meta.edge_segment_id_runs.intersectsSortedIds(ids_by_id);
            }
            return try edgeIdSetIntersectsSegmentOverlay(self, meta, ids_by_id, min_edge_id, max_edge_id);
        }

        pub fn edgeIdExistsInSegmentOverlay(self: Store, meta: IndexMeta, edge_id: u64) !bool {
            if (try edgeSegmentMetaSummaryContains(self, meta, edge_id)) |contains| return contains;

            var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);

            const manifest_edges = manifest.totalEdgeCount();
            const physical_edges = (try edgeSegmentManifestCoveredPhysicalEdges(self, meta, manifest_edges)) orelse return error.InvalidRecord;
            if (manifest_edges != physical_edges and meta.edge_indexed_edges >= physical_edges) return false;

            for (manifest.entries.items) |entry| {
                if (manifest.ranges_trusted and (edge_id < entry.edge_id_range.min or edge_id > entry.edge_id_range.max)) continue;
                if (manifest.ranges_trusted) {
                    const single = [_]u64{edge_id};
                    if (try trustedRunSummaryMayIntersect(entry, &single)) |may_intersect| {
                        if (may_intersect) return true;
                        continue;
                    }
                    if (try trustedSingletonEdgeSegmentId(entry)) |singleton_id| {
                        if (edge_id == singleton_id) return true;
                        continue;
                    }
                }
                if (try edgeSegmentIdIndexContains(self, entry, edge_id)) |found| {
                    if (found) return true;
                    continue;
                }
                var segment = try segment_mod.ImmutableAdjacencySegment.open(self.allocator, self.io, entry.path);
                defer segment.deinit();
                if (try segment.edgeCount() != entry.edge_count) return error.InvalidRecord;
                if (!try segment.mayContainEdgeId(edge_id)) continue;
                var iter = try segment.edgeIterator(.forward);
                while (try iter.next()) |edge| {
                    if (edge.edge_id.toInt() == edge_id) return true;
                }
            }
            return false;
        }

        pub fn edgeIdSetIntersectsSegmentOverlay(
            self: Store,
            meta: IndexMeta,
            ids_by_id: []const u64,
            min_edge_id: u64,
            max_edge_id: u64,
        ) !bool {
            if (try edgeSegmentMetaSummaryIntersects(self, meta, ids_by_id)) |intersects| return intersects;

            var manifest = readEdgeSegmentManifest(self, self.allocator) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer manifest.deinit(self.allocator);

            const manifest_edges = manifest.totalEdgeCount();
            const physical_edges = (try edgeSegmentManifestCoveredPhysicalEdges(self, meta, manifest_edges)) orelse return error.InvalidRecord;
            if (manifest_edges != physical_edges and meta.edge_indexed_edges >= physical_edges) return false;

            for (manifest.entries.items) |entry| {
                if (self.edge_batch_segment_delta_stats) |delta_stats| delta_stats.overlay_entries_considered += 1;
                if (manifest.ranges_trusted and (max_edge_id < entry.edge_id_range.min or min_edge_id > entry.edge_id_range.max)) {
                    if (self.edge_batch_segment_delta_stats) |delta_stats| delta_stats.overlay_entries_range_skipped += 1;
                    continue;
                }
                const entry_ids = if (manifest.ranges_trusted) blk: {
                    const start = lowerBoundU64(ids_by_id, entry.edge_id_range.min);
                    if (start >= ids_by_id.len or ids_by_id[start] > entry.edge_id_range.max) {
                        if (self.edge_batch_segment_delta_stats) |delta_stats| delta_stats.overlay_entries_range_skipped += 1;
                        continue;
                    }
                    const end = upperBoundU64(ids_by_id, entry.edge_id_range.max);
                    break :blk ids_by_id[start..end];
                } else ids_by_id;
                if (manifest.ranges_trusted) {
                    if (try trustedRunSummaryMayIntersect(entry, entry_ids)) |may_intersect| {
                        if (may_intersect) return true;
                        if (self.edge_batch_segment_delta_stats) |delta_stats| delta_stats.overlay_entries_range_skipped += 1;
                        continue;
                    }
                    if (try trustedSingletonEdgeSegmentId(entry)) |_| return true;
                }
                if (self.edge_batch_segment_delta_stats) |delta_stats| delta_stats.overlay_sidecar_checks += 1;
                if (try edgeSegmentIdIndexIntersects(self, entry, entry_ids)) |found| {
                    if (found) return true;
                    continue;
                }
                if (self.edge_batch_segment_delta_stats) |delta_stats| delta_stats.overlay_csr_fallbacks += 1;
                var segment = try segment_mod.ImmutableAdjacencySegment.open(self.allocator, self.io, entry.path);
                defer segment.deinit();
                if (try segment.edgeCount() != entry.edge_count) return error.InvalidRecord;
                if (!try segment.edgeIdRangeMayIntersect(min_edge_id, max_edge_id)) continue;
                var iter = try segment.edgeIterator(.forward);
                while (try iter.next()) |edge| {
                    if (u64SortedContains(ids_by_id, edge.edge_id.toInt())) return true;
                }
            }
            return false;
        }

        pub fn edgeIndexTailExceedsHighWater(self: Store, meta: IndexMeta) !bool {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.edge_by_id_path, .{});
            defer file.close(self.io);
            const header = try readEdgeIndexHeaderFromFile(self, file);
            if (header.order != .id) return error.InvalidRecord;
            if (header.edge_count != meta.edge_indexed_edges) return error.InvalidRecord;
            if (header.edge_digest != meta.edge_index_digest) return error.InvalidRecord;
            if (header.order_digest != edgeOrderDigestForMeta(meta, .id)) return error.InvalidRecord;
            if (header.edge_count == 0) return false;
            if (header.hasDenseId()) {
                if (try regularFileSize(self, file) != try edgeIndexFileSizeForHeader(header)) return error.InvalidRecord;
                return header.edge_count > meta.max_edge_id_seen;
            }
            const last = try readEdgeIndexRecordAt(self, file, header, header.edge_count - 1);
            return last.edge_id > meta.max_edge_id_seen;
        }

        pub fn edgeIdExistsInFile(self: Store, file: std.Io.File, header: EdgeIndexHeader, id: u64) !bool {
            if (header.order == .id and header.hasDenseId()) {
                if (try regularFileSize(self, file) != try edgeIndexFileSizeForHeader(header)) return error.InvalidRecord;
                return id != 0 and id <= header.edge_count;
            }
            const lo = try edgeIdLowerBoundInFileFrom(self, file, header, id, 0);
            if (lo >= header.edge_count) return false;
            const record = try readEdgeIndexRecordAt(self, file, header, lo);
            return record.edge_id == id;
        }

        pub fn edgeIdSortedSetIntersectsFile(self: Store, file: std.Io.File, header: EdgeIndexHeader, ids_by_id: []const u64) !bool {
            if (ids_by_id.len == 0 or header.edge_count == 0) return false;
            if (header.order == .id and header.hasDenseId()) {
                if (try regularFileSize(self, file) != try edgeIndexFileSizeForHeader(header)) return error.InvalidRecord;
                const pos = lowerBoundU64(ids_by_id, 1);
                return pos < ids_by_id.len and ids_by_id[pos] <= header.edge_count;
            }
            var id_index: usize = 0;
            var base_index = try edgeIdLowerBoundInFileFrom(self, file, header, ids_by_id[id_index], 0);
            while (id_index < ids_by_id.len and base_index < header.edge_count) {
                const record = try readEdgeIndexRecordAt(self, file, header, base_index);
                const candidate = ids_by_id[id_index];
                if (record.edge_id == candidate) return true;
                if (record.edge_id < candidate) {
                    base_index = try edgeIdLowerBoundInFileFrom(self, file, header, candidate, base_index + 1);
                    continue;
                }
                id_index += 1;
                while (id_index < ids_by_id.len and ids_by_id[id_index] < record.edge_id) {
                    id_index += 1;
                }
                if (id_index >= ids_by_id.len) return false;
                if (ids_by_id[id_index] == record.edge_id) return true;
                base_index = try edgeIdLowerBoundInFileFrom(self, file, header, ids_by_id[id_index], base_index);
            }
            return false;
        }

        pub fn edgeIdRunSummaryMatchesFile(self: Store, file: std.Io.File, header: EdgeIndexHeader, summary: EdgeSegmentIdRunSummary) !bool {
            try summary.validate();
            if (try denseEdgeIdRunSummaryForHeader(header)) |expected| {
                if (try regularFileSize(self, file) != try edgeIndexFileSizeForHeader(header)) return error.InvalidRecord;
                return edgeSegmentIdRunSummariesEqual(summary, expected);
            }
            if (header.edge_count == 0) return summary.run_count == 0;
            if (summary.run_count == 0) return false;
            const covered_count = try summary.coveredCount();
            if (covered_count != header.edge_count) return false;
            const first = try readEdgeIndexRecordAt(self, file, header, 0);
            if (first.edge_id != summary.first_min) return false;
            if (summary.run_count == 1) {
                const last = try readEdgeIndexRecordAt(self, file, header, header.edge_count - 1);
                return last.edge_id == summary.first_max;
            }
            const first_len = std.math.add(u64, summary.first_max - summary.first_min, 1) catch return error.InvalidRecord;
            const first_last = try readEdgeIndexRecordAt(self, file, header, first_len - 1);
            if (first_last.edge_id != summary.first_max) return false;
            const second_first = try readEdgeIndexRecordAt(self, file, header, first_len);
            if (second_first.edge_id != summary.second_min) return false;
            const last = try readEdgeIndexRecordAt(self, file, header, header.edge_count - 1);
            return last.edge_id == summary.second_max;
        }

        pub fn edgeIdLowerBoundInFileFrom(self: Store, file: std.Io.File, header: EdgeIndexHeader, id: u64, start: u64) !u64 {
            if (start > header.edge_count) return error.InvalidRecord;
            var lo: u64 = start;
            var hi: u64 = header.edge_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const record = try readEdgeIndexRecordAt(self, file, header, mid);
                if (record.edge_id < id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn extendNodeByIdIndex(self: Store, file: std.Io.File, old_max_id: u64, new_max_id: u64) !void {
            if (new_max_id <= old_max_id) return;
            const header = try readNodeByIdHeaderFromFile(self, file);
            try file.setLength(self.io, try nodeByIdFileSizeForHeaderStore(self, .{
                .max_node_id = new_max_id,
                .node_count = header.node_count,
                .node_digest = header.node_digest,
                .flags = header.flags,
                .record_len = header.record_len,
                .uniform_kind = header.uniform_kind,
            }));
        }

        pub fn writeNodeByIdHeader(self: Store, file: std.Io.File, header: NodeByIdHeader) !void {
            try header.validateShape();
            var header_bytes: [NodeByIdHeader.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
        }

        pub fn writeNodeByIdRecordAt(self: Store, file: std.Io.File, header: NodeByIdHeader, record: NodeByIdRecord) !void {
            var record_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
            const encoded = record_bytes[0..header.record_len];
            try record.encodeForHeader(header, encoded);
            try file.writePositionalAll(self.io, encoded, try nodeByIdRecordOffsetForHeader(header, record.id));
        }

        pub fn writeEdgeIndexRecordAt(self: Store, file: std.Io.File, header: EdgeIndexHeader, index: u64, record: EdgeIndexRecord) !void {
            if (header.hasKeyRuns()) return error.InvalidRecord;
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            const encoded = record_bytes[0..header.record_len];
            try record.encodeForHeader(header, index, null, encoded);
            try file.writePositionalAll(self.io, encoded, try edgeIndexRecordOffsetForHeader(header, index));
        }

        pub fn compactEdgeIndexToDerivedRecords(self: Store, file: std.Io.File, header: *EdgeIndexHeader) !void {
            if (header.hasKeyRuns()) return;
            var dense_id = header.order == .id;
            var u32_node_ids = header.edge_count != 0;
            var u32_edge_ids = header.order != .id and header.edge_count != 0;
            var rel_counts: [edge_index_rel_kind_count]u64 = [_]u64{0} ** edge_index_rel_kind_count;
            {
                var reader = try ExplicitEdgeIndexSequentialReader.init(self.allocator, self.io, file, header.*);
                defer reader.deinit();
                var check_pos: u64 = 0;
                while (try reader.next()) |record| : (check_pos += 1) {
                    if (dense_id) {
                        const expected_edge_id = std.math.add(u64, check_pos, 1) catch return error.InvalidRecord;
                        if (record.edge_id != expected_edge_id) dense_id = false;
                    }
                    if (u32_node_ids and !edgeRecordHasU32NodeIds(record)) u32_node_ids = false;
                    if (u32_edge_ids and !edgeRecordHasU32EdgeId(record)) u32_edge_ids = false;
                    const rel_kind = relKindFromInt(record.rel) orelse return error.InvalidRecord;
                    rel_counts[@intFromEnum(rel_kind)] += 1;
                }
                if (check_pos != header.edge_count) return error.InvalidRecord;
            }
            var rel_derivation: ?EdgeIndexRelDerivation = null;
            if (edgeIndexDefaultRelFromCounts(rel_counts, header.edge_count)) |default_rel| {
                var derivation = EdgeIndexRelDerivation{ .default_rel = default_rel };
                var reader = try ExplicitEdgeIndexSequentialReader.init(self.allocator, self.io, file, header.*);
                defer reader.deinit();
                while (try reader.next()) |record| {
                    if (record.rel != default_rel and !edgeIndexRelDerivationAddException(&derivation, record.edge_id, record.rel)) {
                        derivation.exception_count = std.math.maxInt(u8);
                        break;
                    }
                }
                if (derivation.exception_count <= derivation.exception_edge_ids.len) rel_derivation = derivation;
            }
            const derived_header = EdgeIndexHeader.withShape(header.order, header.edge_count, header.edge_digest, header.order_digest, dense_id, u32_node_ids, u32_edge_ids, rel_derivation);
            if (!(derived_header.record_len == header.record_len and derived_header.flags == header.flags and derived_header.default_rel == header.default_rel and derived_header.rel_exception_count == header.rel_exception_count and std.mem.eql(u64, &derived_header.rel_exception_edge_ids, &header.rel_exception_edge_ids) and std.mem.eql(u16, &derived_header.rel_exception_rels, &header.rel_exception_rels))) {
                var reader = try ExplicitEdgeIndexSequentialReader.init(self.allocator, self.io, file, header.*);
                defer reader.deinit();
                var writer = try StorageBufferedWriter.initAtOffset(
                    self.allocator,
                    self.io,
                    file,
                    storage_write_buffer_bytes,
                    EdgeIndexHeader.encoded_len,
                );
                defer writer.deinit();
                var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
                var pos: u64 = 0;
                while (try reader.next()) |record| : (pos += 1) {
                    const encoded = record_bytes[0..derived_header.record_len];
                    try record.encodeForHeader(derived_header, pos, null, encoded);
                    try writer.append(encoded);
                }
                if (pos != header.edge_count) return error.InvalidRecord;
                try writer.flush();
                if (try writer.position() != try edgeIndexFileSizeForHeader(derived_header)) return error.InvalidRecord;
                try file.setLength(self.io, try edgeIndexFileSizeForHeader(derived_header));
                var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
                derived_header.encode(&header_bytes);
                try file.writePositionalAll(self.io, &header_bytes, 0);
                header.* = derived_header;
            }

            if (try compactIdEdgeIndexToEndpointRuns(self, file, header)) return;
            if (try compactSecondaryEdgeIndexToDenseKeyRuns(self, file, header)) return;
        }

        pub fn compactIdEdgeIndexToEndpointRuns(self: Store, file: std.Io.File, header: *EdgeIndexHeader) !bool {
            if (header.order != .id or !header.hasDenseId() or !header.hasU32NodeIds() or !header.hasDerivedRel() or header.hasKeyRuns() or header.edge_count == 0) return false;

            const expected_size = try edgeIndexFileSizeForHeader(header.*);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            var map = openReadOnlyMemoryMap(self.io, file, expected_size) catch null;
            defer if (map) |*mapped| mapped.destroy(self.io);

            var runs = std.ArrayList(EdgeIndexKeyRunRecord).empty;
            defer runs.deinit(self.allocator);

            var pos: u64 = 0;
            while (pos < header.edge_count) {
                const first = if (map) |*mapped|
                    try readEdgeIndexRecordFromMap(header.*, mapped, pos)
                else
                    try readEdgeIndexRecordAt(self, file, header.*, pos);
                if (!edgeIndexIdEndpointCanStartRun(first)) return false;
                if (runs.items.len >= edge_index_repair_key_run_memory_cap / 12) return false;
                try runs.append(self.allocator, .{
                    .key = first.src,
                    .start = pos,
                    .opposite = first.dst,
                });

                pos += 1;
                var previous = first;
                while (pos < header.edge_count) : (pos += 1) {
                    const record = if (map) |*mapped|
                        try readEdgeIndexRecordFromMap(header.*, mapped, pos)
                    else
                        try readEdgeIndexRecordAt(self, file, header.*, pos);
                    if (!edgeIndexIdEndpointCanStartRun(record)) return false;
                    const expected_src = std.math.add(u64, previous.src, 1) catch break;
                    const expected_dst = std.math.add(u64, previous.dst, 1) catch break;
                    if (record.src != expected_src or record.dst != expected_dst) break;
                    previous = record;
                }
            }
            if (runs.items.len == 0 or runs.items.len > std.math.maxInt(u32)) return false;

            const key_run_header = header.withKeyRuns(@intCast(runs.items.len), true, false);
            if (key_run_header.record_len != 0) return false;
            const next_size = try edgeIndexFileSizeForHeader(key_run_header);
            if (next_size >= try edgeIndexFileSizeForHeader(header.*)) return false;

            if (map) |*mapped| {
                mapped.destroy(self.io);
                map = null;
            }

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            key_run_header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
            var run_bytes: [40]u8 = undefined;
            var offset: u64 = EdgeIndexHeader.encoded_len;
            for (runs.items) |run| {
                const encoded = run_bytes[0..edgeIndexKeyRunRecordLen(key_run_header)];
                try run.encodeForHeader(key_run_header, encoded);
                try file.writePositionalAll(self.io, encoded, offset);
                offset += encoded.len;
            }
            try file.setLength(self.io, next_size);
            header.* = key_run_header;
            return true;
        }

        pub fn compactSecondaryEdgeIndexToDenseKeyRuns(self: Store, file: std.Io.File, header: *EdgeIndexHeader) !bool {
            if (header.order == .id or !header.hasU32NodeIds() or !header.hasU32EdgeIds() or !header.hasDerivedRel() or header.hasKeyRuns() or header.edge_count == 0) return false;
            if (header.edge_count > std.math.maxInt(u32)) return false;
            if (try compactSecondaryEdgeIndexToPartialDenseKeyRuns(self, file, header)) return true;

            const expected_size = try edgeIndexFileSizeForHeader(header.*);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            var map = openReadOnlyMemoryMap(self.io, file, expected_size) catch null;
            defer if (map) |*mapped| mapped.destroy(self.io);

            var first_run: EdgeIndexKeyRunRecord = undefined;
            var previous_run: EdgeIndexKeyRunRecord = undefined;
            var current_key: u64 = 0;
            var current_opposite: u64 = 0;
            var current_start: u64 = 0;
            var current_edge_id_base: u64 = 0;
            var current_edge_id_step: u64 = 0;
            var current_len: u64 = 0;
            var run_count: u64 = 0;
            var start_step: u64 = 0;
            var edge_id_base_step: u64 = 0;
            var uniform_edge_id_step: u64 = 0;
            var first_opposite: u64 = 0;

            const FinishRun = struct {
                fn finish(
                    order: EdgeIndexOrder,
                    run_count_ptr: *u64,
                    first_run_ptr: *EdgeIndexKeyRunRecord,
                    previous_run_ptr: *EdgeIndexKeyRunRecord,
                    start_step_ptr: *u64,
                    edge_id_base_step_ptr: *u64,
                    uniform_edge_id_step_ptr: *u64,
                    first_opposite_ptr: *u64,
                    key: u64,
                    opposite: u64,
                    start: u64,
                    edge_id_base: u64,
                    edge_id_step: u64,
                    len: u64,
                ) !bool {
                    if (key == 0 or key > std.math.maxInt(u32)) return false;
                    if (opposite == 0 or opposite > std.math.maxInt(u32)) return false;
                    if (edge_id_base == 0 or edge_id_base > std.math.maxInt(u32)) return false;
                    if (start > std.math.maxInt(u32)) return false;
                    if (len == 0) return false;
                    if (len > 1) {
                        if (edge_id_step == 0 or edge_id_step > std.math.maxInt(u32)) return false;
                        if (uniform_edge_id_step_ptr.* == 0) {
                            uniform_edge_id_step_ptr.* = edge_id_step;
                        } else if (uniform_edge_id_step_ptr.* != edge_id_step) {
                            return false;
                        }
                    }

                    const run = EdgeIndexKeyRunRecord{
                        .key = key,
                        .start = start,
                        .opposite = opposite,
                        .edge_id_base = edge_id_base,
                        .edge_id_step = edge_id_step,
                    };
                    if (run_count_ptr.* == 0) {
                        if (key != 1) return false;
                        first_run_ptr.* = run;
                        first_opposite_ptr.* = opposite;
                    } else {
                        if (key != previous_run_ptr.key + 1) return false;
                        if (start <= previous_run_ptr.start or edge_id_base <= previous_run_ptr.edge_id_base) return false;
                        const next_start_step = start - previous_run_ptr.start;
                        const next_edge_base_step = edge_id_base - previous_run_ptr.edge_id_base;
                        if (run_count_ptr.* == 1) {
                            start_step_ptr.* = next_start_step;
                            edge_id_base_step_ptr.* = next_edge_base_step;
                        } else if (start_step_ptr.* != next_start_step or edge_id_base_step_ptr.* != next_edge_base_step) {
                            return false;
                        }
                        switch (order) {
                            .id => return false,
                            .src => if (previous_run_ptr.opposite != previous_run_ptr.key + 1) return false,
                            .dst => if (run.opposite != run.key - 1) return false,
                        }
                    }
                    previous_run_ptr.* = run;
                    run_count_ptr.* += 1;
                    return true;
                }
            };

            var pos: u64 = 0;
            while (pos < header.edge_count) : (pos += 1) {
                const record = if (map) |*mapped|
                    try readEdgeIndexRecordFromMap(header.*, mapped, pos)
                else
                    try readEdgeIndexRecordAt(self, file, header.*, pos);
                if (!edgeRecordHasU32NodeIds(record) or !edgeRecordHasU32EdgeId(record)) return false;
                const key = edgeIndexRecordKey(record, header.order);
                const opposite = edgeIndexRecordOpposite(record, header.order) orelse return false;
                if (current_len == 0) {
                    current_key = key;
                    current_opposite = opposite;
                    current_start = pos;
                    current_edge_id_base = record.edge_id;
                    current_edge_id_step = 0;
                    current_len = 1;
                    continue;
                }
                if (key != current_key) {
                    if (!try FinishRun.finish(header.order, &run_count, &first_run, &previous_run, &start_step, &edge_id_base_step, &uniform_edge_id_step, &first_opposite, current_key, current_opposite, current_start, current_edge_id_base, current_edge_id_step, current_len)) return false;
                    current_key = key;
                    current_opposite = opposite;
                    current_start = pos;
                    current_edge_id_base = record.edge_id;
                    current_edge_id_step = 0;
                    current_len = 1;
                    continue;
                }
                if (opposite != current_opposite) return false;
                if (current_len == 1) {
                    if (record.edge_id <= current_edge_id_base) return false;
                    current_edge_id_step = record.edge_id - current_edge_id_base;
                } else {
                    const expected_delta = std.math.mul(u64, current_len, current_edge_id_step) catch return false;
                    const expected = std.math.add(u64, current_edge_id_base, expected_delta) catch return false;
                    if (record.edge_id != expected) return false;
                }
                current_len += 1;
            }
            if (current_len == 0) return false;
            if (!try FinishRun.finish(header.order, &run_count, &first_run, &previous_run, &start_step, &edge_id_base_step, &uniform_edge_id_step, &first_opposite, current_key, current_opposite, current_start, current_edge_id_base, current_edge_id_step, current_len)) return false;
            if (run_count < 2 or run_count > std.math.maxInt(u32)) return false;
            if (uniform_edge_id_step == 0 or start_step == 0 or edge_id_base_step == 0) return false;
            switch (header.order) {
                .id => return false,
                .src => if (previous_run.opposite != 1) return false,
                .dst => if (first_opposite != previous_run.key) return false,
            }

            const dense = EdgeIndexDenseKeyRunSpan{
                .run_start = 0,
                .count = run_count,
                .key_base = first_run.key,
                .start_base = first_run.start,
                .start_step = start_step,
                .edge_id_base = first_run.edge_id_base,
                .edge_id_base_step = edge_id_base_step,
            };
            const key_run_header = header
                .withKeyRuns(@intCast(run_count), true, true)
                .withKeyRunRingOpposite(previous_run.key)
                .withKeyRunUniformEdgeIdStep(uniform_edge_id_step)
                .withKeyRunDenseSpan(dense);
            if (key_run_header.record_len != 0) return false;
            const next_size = try edgeIndexFileSizeForHeader(key_run_header);
            if (next_size >= try edgeIndexFileSizeForHeader(header.*)) return false;

            if (map) |*mapped| {
                mapped.destroy(self.io);
                map = null;
            }

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            key_run_header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
            try file.setLength(self.io, next_size);
            header.* = key_run_header;
            return true;
        }

        pub fn readSecondaryRepairKeyRunAt(self: Store, file: std.Io.File, header: EdgeIndexHeader, start: u64) !?SecondaryRepairKeyRun {
            if (header.order == .id or start >= header.edge_count) return null;
            const first = try readEdgeIndexRecordAt(self, file, header, start);
            if (!edgeRecordHasU32NodeIds(first) or !edgeRecordHasU32EdgeId(first)) return null;
            const key = edgeIndexRecordKey(first, header.order);
            const opposite = edgeIndexRecordOpposite(first, header.order) orelse return null;
            if (key == 0 or key > std.math.maxInt(u32)) return null;
            if (opposite == 0 or opposite > std.math.maxInt(u32)) return null;
            var step: u64 = 0;
            var len: u64 = 1;
            var pos = start + 1;
            while (pos < header.edge_count) : (pos += 1) {
                const record = try readEdgeIndexRecordAt(self, file, header, pos);
                if (!edgeRecordHasU32NodeIds(record) or !edgeRecordHasU32EdgeId(record)) return null;
                if (edgeIndexRecordKey(record, header.order) != key) break;
                const record_opposite = edgeIndexRecordOpposite(record, header.order) orelse return null;
                if (record_opposite != opposite) break;
                if (len == 1) {
                    if (record.edge_id <= first.edge_id) break;
                    step = record.edge_id - first.edge_id;
                    if (step > std.math.maxInt(u32)) return null;
                } else {
                    const expected_delta = std.math.mul(u64, len, step) catch return null;
                    const expected = std.math.add(u64, first.edge_id, expected_delta) catch return null;
                    if (record.edge_id != expected) break;
                }
                len += 1;
            }
            return .{
                .run = .{
                    .key = key,
                    .start = start,
                    .opposite = opposite,
                    .edge_id_base = first.edge_id,
                    .edge_id_step = step,
                },
                .next_pos = pos,
            };
        }

        pub fn readSecondaryRepairKeyRunFromMap(header: EdgeIndexHeader, map: *const std.Io.File.MemoryMap, start: u64) !?SecondaryRepairKeyRun {
            if (header.order == .id or start >= header.edge_count) return null;
            const first = try readEdgeIndexRecordFromMap(header, map, start);
            if (!edgeRecordHasU32NodeIds(first) or !edgeRecordHasU32EdgeId(first)) return null;
            const key = edgeIndexRecordKey(first, header.order);
            const opposite = edgeIndexRecordOpposite(first, header.order) orelse return null;
            if (key == 0 or key > std.math.maxInt(u32)) return null;
            if (opposite == 0 or opposite > std.math.maxInt(u32)) return null;
            var step: u64 = 0;
            var len: u64 = 1;
            var pos = start + 1;
            while (pos < header.edge_count) : (pos += 1) {
                const record = try readEdgeIndexRecordFromMap(header, map, pos);
                if (!edgeRecordHasU32NodeIds(record) or !edgeRecordHasU32EdgeId(record)) return null;
                if (edgeIndexRecordKey(record, header.order) != key) break;
                const record_opposite = edgeIndexRecordOpposite(record, header.order) orelse return null;
                if (record_opposite != opposite) break;
                if (len == 1) {
                    if (record.edge_id <= first.edge_id) break;
                    step = record.edge_id - first.edge_id;
                    if (step > std.math.maxInt(u32)) return null;
                } else {
                    const expected_delta = std.math.mul(u64, len, step) catch return null;
                    const expected = std.math.add(u64, first.edge_id, expected_delta) catch return null;
                    if (record.edge_id != expected) break;
                }
                len += 1;
            }
            return .{
                .run = .{
                    .key = key,
                    .start = start,
                    .opposite = opposite,
                    .edge_id_base = first.edge_id,
                    .edge_id_step = step,
                },
                .next_pos = pos,
            };
        }

        pub fn compactSecondaryEdgeIndexToPartialDenseKeyRuns(self: Store, file: std.Io.File, header: *EdgeIndexHeader) !bool {
            const expected_size = try edgeIndexFileSizeForHeader(header.*);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            var map = openReadOnlyMemoryMap(self.io, file, expected_size) catch null;
            defer if (map) |*mapped| mapped.destroy(self.io);

            var uniform_step: u64 = 0;
            var max_key: u64 = 0;
            var run_count: u64 = 0;
            var best: ?EdgeIndexDenseKeyRunSpan = null;
            var best_score: u64 = 0;
            var span_start_index: u64 = 0;
            var span_start: EdgeIndexKeyRunRecord = undefined;
            var previous: EdgeIndexKeyRunRecord = undefined;
            var span_count: u64 = 0;
            var start_step: u64 = 0;
            var edge_id_base_step: u64 = 0;

            var pos: u64 = 0;
            while (pos < header.edge_count) {
                const scanned = (if (map) |*mapped|
                    try readSecondaryRepairKeyRunFromMap(header.*, mapped, pos)
                else
                    try readSecondaryRepairKeyRunAt(self, file, header.*, pos)) orelse return false;
                const run = scanned.run;
                if (run.key > max_key) max_key = run.key;
                if (run.edge_id_base == 0 or run.edge_id_base > std.math.maxInt(u32)) return false;
                if (run.edge_id_step != 0) {
                    if (uniform_step == 0) {
                        uniform_step = run.edge_id_step;
                    } else if (uniform_step != run.edge_id_step) {
                        return false;
                    }
                }

                const eligible = uniform_step != 0 and run.edge_id_step == uniform_step;
                if (eligible and span_count != 0) {
                    const continues = run.key == previous.key + 1 and
                        run.start > previous.start and
                        run.edge_id_base > previous.edge_id_base;
                    if (continues) {
                        const next_start_step = run.start - previous.start;
                        const next_edge_base_step = run.edge_id_base - previous.edge_id_base;
                        if (span_count == 1) {
                            start_step = next_start_step;
                            edge_id_base_step = next_edge_base_step;
                            span_count = 2;
                        } else if (next_start_step == start_step and next_edge_base_step == edge_id_base_step) {
                            span_count += 1;
                        } else {
                            best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                            span_start_index = run_count;
                            span_start = run;
                            start_step = 0;
                            edge_id_base_step = 0;
                            span_count = 1;
                        }
                    } else {
                        best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                        span_start_index = run_count;
                        span_start = run;
                        start_step = 0;
                        edge_id_base_step = 0;
                        span_count = 1;
                    }
                } else if (eligible) {
                    best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                    span_start_index = run_count;
                    span_start = run;
                    start_step = 0;
                    edge_id_base_step = 0;
                    span_count = 1;
                } else {
                    best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                    span_count = 0;
                    start_step = 0;
                    edge_id_base_step = 0;
                }

                previous = run;
                run_count += 1;
                pos = scanned.next_pos;
            }
            best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
            const dense = best orelse return false;
            if (run_count == 0 or run_count > std.math.maxInt(u32) or max_key < 2 or max_key > std.math.maxInt(u32)) return false;
            if (uniform_step == 0) return false;

            const key_run_header = header
                .withKeyRuns(@intCast(run_count), true, true)
                .withKeyRunRingOpposite(max_key)
                .withKeyRunUniformEdgeIdStep(uniform_step)
                .withKeyRunDenseSpan(dense);
            if (key_run_header.record_len != 0) return false;
            const next_size = try edgeIndexFileSizeForHeader(key_run_header);
            if (next_size >= try edgeIndexFileSizeForHeader(header.*)) return false;
            const explicit_bytes = try edgeIndexKeyRunDirectorySizeForHeader(key_run_header);
            if (explicit_bytes > edge_index_repair_key_run_memory_cap) return false;

            var explicit_runs = std.ArrayList(EdgeIndexKeyRunRecord).empty;
            defer explicit_runs.deinit(self.allocator);
            try explicit_runs.ensureTotalCapacityPrecise(self.allocator, @intCast(explicit_bytes / edgeIndexKeyRunRecordLen(key_run_header)));

            const dense_end = dense.run_start + dense.count;
            pos = 0;
            var run_index: u64 = 0;
            while (pos < header.edge_count) : (run_index += 1) {
                const scanned = (if (map) |*mapped|
                    try readSecondaryRepairKeyRunFromMap(header.*, mapped, pos)
                else
                    try readSecondaryRepairKeyRunAt(self, file, header.*, pos)) orelse return false;
                const run = scanned.run;
                if (run_index >= dense.run_start and run_index < dense_end) {
                    const expected = try edgeIndexDenseKeyRunSpanRecordForIndex(key_run_header, run_index);
                    if (!edgeIndexKeyRunRecordsEquivalent(key_run_header, expected, run)) return false;
                } else {
                    try explicit_runs.append(self.allocator, run);
                }
                pos = scanned.next_pos;
            }
            if (run_index != run_count) return false;

            if (map) |*mapped| {
                mapped.destroy(self.io);
                map = null;
            }

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            key_run_header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
            var run_bytes: [40]u8 = undefined;
            var write_offset: u64 = EdgeIndexHeader.encoded_len;
            for (explicit_runs.items) |run| {
                const encoded = run_bytes[0..edgeIndexKeyRunRecordLen(key_run_header)];
                try run.encodeForHeader(key_run_header, encoded);
                try file.writePositionalAll(self.io, encoded, write_offset);
                write_offset += encoded.len;
            }
            try file.setLength(self.io, next_size);
            header.* = key_run_header;
            return true;
        }

        pub fn edgeIndexHeaderForTail(order: EdgeIndexOrder, old_header: EdgeIndexHeader, next_count: u64, edge_digest: u64, order_digest: u64, tail_records: []const EdgeIndexRecord) EdgeIndexHeader {
            const dense_id = order == .id and (old_header.edge_count == 0 or old_header.hasDenseId()) and edgeRecordsAreDenseIdTail(old_header.edge_count, tail_records);
            const u32_node_ids = tail_records.len != 0 and (old_header.edge_count == 0 or old_header.hasU32NodeIds()) and edgeRecordsHaveU32NodeIds(tail_records);
            const u32_edge_ids = !dense_id and tail_records.len != 0 and (old_header.edge_count == 0 or old_header.hasU32EdgeIds()) and edgeRecordsHaveU32EdgeIds(tail_records);
            const rel_derivation = if (old_header.edge_count == 0)
                edgeRecordsDerivedRel(tail_records)
            else
                edgeRecordsExtendDerivedRel(old_header, tail_records);
            const header = EdgeIndexHeader.withShape(order, next_count, edge_digest, order_digest, dense_id, u32_node_ids, u32_edge_ids, rel_derivation);
            if (old_header.edge_count == 0) return edgeIndexHeaderWithBeneficialKeyRuns(order, header, tail_records);
            return header;
        }

        pub fn edgeIndexHeaderForCompleteRecords(order: EdgeIndexOrder, records: []const EdgeIndexRecord, edge_digest: u64, order_digest: u64) EdgeIndexHeader {
            const count: u64 = @intCast(records.len);
            const dense_id = order == .id and edgeRecordsAreDenseIdTail(0, records);
            const header = EdgeIndexHeader.withShape(order, count, edge_digest, order_digest, dense_id, edgeRecordsHaveU32NodeIds(records), !dense_id and edgeRecordsHaveU32EdgeIds(records), edgeRecordsDerivedRel(records));
            return edgeIndexHeaderWithBeneficialKeyRuns(order, header, records);
        }

        pub fn edgeIndexHeaderForSingleFullRewrite(order: EdgeIndexOrder, next_count: u64, edge_digest: u64, order_digest: u64, old_header: EdgeIndexHeader, inserted: EdgeIndexRecord) EdgeIndexHeader {
            const rel_derivation = edgeRecordsExtendDerivedRel(old_header, &.{inserted});
            return EdgeIndexHeader.withShape(order, next_count, edge_digest, order_digest, false, old_header.hasU32NodeIds() and edgeRecordHasU32NodeIds(inserted), old_header.hasU32EdgeIds() and edgeRecordHasU32EdgeId(inserted), rel_derivation);
        }

        pub fn edgeIndexHeaderWithoutRecord(order: EdgeIndexOrder, next_count: u64, edge_digest: u64, order_digest: u64, old_header: EdgeIndexHeader, removed: EdgeIndexRecord) EdgeIndexHeader {
            const dense_id = order == .id and old_header.hasDenseId() and removed.edge_id == old_header.edge_count;
            const rel_derivation = edgeIndexRelDerivationWithoutRecord(old_header, removed, next_count);
            return EdgeIndexHeader.withShape(order, next_count, edge_digest, order_digest, dense_id, next_count != 0 and old_header.hasU32NodeIds(), !dense_id and next_count != 0 and old_header.hasU32EdgeIds(), rel_derivation);
        }

        pub fn writeEdgeIndexRecordToWriter(writer: *StorageBufferedWriter, header: EdgeIndexHeader, index: u64, record: EdgeIndexRecord) !void {
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            const encoded = record_bytes[0..header.record_len];
            try record.encodeForHeader(header, index, null, encoded);
            try writer.append(encoded);
        }

        pub fn writeEdgeIndexRunsToWriter(writer: *StorageBufferedWriter, header: EdgeIndexHeader, records: []const EdgeIndexRecord) !void {
            if (!header.hasKeyRuns()) return;
            var run_bytes: [40]u8 = undefined;
            var run_count: u32 = 0;
            var run_start: usize = 0;
            while (run_start < records.len) {
                const run = try edgeIndexRunRecordForStart(header, records, run_start);
                const dense_end = if (header.hasKeyRunDenseSpan())
                    try std.math.add(u64, header.key_run_dense_run_start, header.key_run_dense_count)
                else
                    0;
                if (header.hasKeyRunDenseSpan() and run_count >= header.key_run_dense_run_start and run_count < dense_end) {
                    const expected = try edgeIndexDenseKeyRunSpanRecordForIndex(header, run_count);
                    if (!edgeIndexKeyRunRecordsEquivalent(header, expected, run)) return error.InvalidRecord;
                } else {
                    const encoded = run_bytes[0..edgeIndexKeyRunRecordLen(header)];
                    try run.encodeForHeader(header, encoded);
                    try writer.append(encoded);
                }
                run_count += 1;
                run_start = edgeIndexNextRunStartForHeaderShape(header, records, run_start) orelse return error.InvalidRecord;
            }
            if (run_count != header.key_run_count) return error.InvalidRecord;
        }

        pub fn writeCompleteEdgeIndexFile(self: Store, file: std.Io.File, header: EdgeIndexHeader, records: []const EdgeIndexRecord, expected_size: u64) !void {
            var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try writer.append(&header_bytes);
            try writeEdgeIndexRunsToWriter(&writer, header, records);
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            var current_run: ?EdgeIndexKeyRunRecord = null;
            var next_run_start: usize = 0;
            if (header.hasKeyRuns() and records.len != 0) {
                current_run = try edgeIndexRunRecordForStart(header, records, 0);
                next_run_start = edgeIndexNextRunStartForHeaderShape(header, records, 0) orelse return error.InvalidRecord;
            }
            for (records, 0..) |record, i| {
                if (header.hasKeyRuns()) {
                    if (current_run) |run| {
                        if (i == next_run_start) {
                            const next_run = try edgeIndexRunRecordForStart(header, records, i);
                            if (i != 0) try validateAdjacentEdgeIndexKeyRuns(header, run, next_run);
                            current_run = next_run;
                            next_run_start = edgeIndexNextRunStartForHeaderShape(header, records, i) orelse return error.InvalidRecord;
                        }
                    } else return error.InvalidRecord;
                }
                const encoded = record_bytes[0..header.record_len];
                try record.encodeForHeader(header, @intCast(i), current_run, encoded);
                try writer.append(encoded);
            }
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
        }
        pub const writeNodeTextIndexHeader = node_catalog_index.writeNodeTextIndexHeader;
        pub const writeNodeTextIndexRecordToWriter = node_catalog_index.writeNodeTextIndexRecordToWriter;
        pub const writeNodeTextIndexRecordAt = node_catalog_index.writeNodeTextIndexRecordAt;
        pub const compactNodeTextIndexToDerivedRecords = node_catalog_index.compactNodeTextIndexToDerivedRecords;

        pub fn writeEdgeIndexesFromRepairSpool(self: Store, spool_path: []const u8, record_count: usize, timings: ?*PersistentRepairTimings) !void {
            return edge_repair_index_publication.publish(self, spool_path, record_count, timings);
        }

        pub fn writeEdgeIndexFromRepairSpool(self: Store, path: []const u8, order: EdgeIndexOrder, spool_path: []const u8, record_count: usize) !void {
            return edge_repair_index_publication.writeOne(self, path, order, spool_path, record_count);
        }

        pub fn readEdgeRepairSpoolChunk(self: Store, file: std.Io.File, start_index: usize, record_count: usize, buffer: []u8, out: *std.ArrayList(EdgeIndexRecord)) !void {
            return edge_repair_index_publication.readSpoolChunk(self, file, start_index, record_count, buffer, out);
        }

        pub fn writeRepairEdgeRun(self: Store, path: []const u8, records: []const EdgeIndexRecord) !void {
            return edge_repair_index_publication.writeRun(self, path, records);
        }

        pub fn detectDenseRingRepairSpoolShape(self: Store, spool_path: []const u8, record_count: usize) !?DenseRingRepairSpoolShape {
            return edge_repair_index_publication.detectDenseRing(self, spool_path, record_count);
        }

        pub fn writeDenseRingIdEdgeIndex(self: Store, path: []const u8, shape: DenseRingRepairSpoolShape) !bool {
            return edge_repair_index_publication.writeDenseRingId(self, path, shape);
        }

        pub fn writeDenseRingSecondaryEdgeIndex(self: Store, path: []const u8, order: EdgeIndexOrder, shape: DenseRingRepairSpoolShape) !bool {
            return edge_repair_index_publication.writeDenseRingSecondary(self, path, order, shape);
        }

        pub fn writeEdgeIndex(self: Store, path: []const u8, records: []const EdgeIndexRecord) !void {
            const order: EdgeIndexOrder = if (std.mem.eql(u8, path, self.edge_by_id_path))
                .id
            else if (std.mem.eql(u8, path, self.edge_by_dst_path))
                .dst
            else
                .src;
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                var digest = EdgeIndexDigest{};
                for (records) |record| digest.add(record);
                const header = edgeIndexHeaderForCompleteRecords(order, records, digest.digest, digest.order_digest);
                const expected_size = try edgeIndexFileSizeForHeader(header);
                try writeCompleteEdgeIndexFile(self, file, header, records, expected_size);
                if (selfOptionsNeedSync(self)) {
                    try file.sync(self.io);
                }
            }
            try renameReplace(self, tmp_path, path);
        }

        pub fn writeEdgeTombstoneIndex(self: Store, records: []const EdgeTombstoneRecord) !void {
            const tmp_path = try tmpPathFor(self, self.edge_tombstones_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(try edgeTombstoneFileSize(@intCast(records.len))));
                defer writer.deinit();

                var digest: u64 = 0;
                for (records, 0..) |record, i| {
                    if (record.edge_id == 0 or record.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                    if (i != 0 and records[i - 1].edge_id >= record.edge_id) return error.InvalidRecord;
                    digest ^= record.edge_digest;
                }
                var header_bytes: [EdgeTombstoneHeader.encoded_len]u8 = undefined;
                const header = EdgeTombstoneHeader{
                    .count = @intCast(records.len),
                    .digest = digest,
                };
                header.encode(&header_bytes);
                try writer.append(&header_bytes);
                var record_bytes: [EdgeTombstoneRecord.encoded_len]u8 = undefined;
                for (records) |record| {
                    record.encode(&record_bytes);
                    try writer.append(&record_bytes);
                }
                try writer.flush();
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.edge_tombstones_path);
        }

        pub fn writeEdgeOrderIndex(self: Store, records: []const EdgeOrderRecord) !void {
            const tmp_path = try tmpPathFor(self, self.edge_order_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                const payload_bytes = std.math.mul(u64, @intCast(records.len), edge_order_format.record_encoded_len) catch return error.InvalidRecord;
                const file_size = edge_order_format.header_encoded_len + payload_bytes;
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(file_size));
                defer writer.deinit();

                var digest: u64 = 0;
                for (records, 0..) |record, i| {
                    try validateEdgeOrderRecord(record);
                    if (i != 0 and !edgeOrderRecordLessThan({}, records[i - 1], record)) return error.InvalidRecord;
                    if (i != 0 and records[i - 1].edge_id == record.edge_id) return error.InvalidRecord;
                    digest ^= edgeOrderRecordDigest(record);
                }
                var header_bytes: [edge_order_format.header_encoded_len]u8 = undefined;
                const header = EdgeOrderHeader{
                    .count = @intCast(records.len),
                    .digest = digest,
                };
                edge_order_format.encodeHeader(header, &header_bytes);
                try writer.append(&header_bytes);
                var record_bytes: [edge_order_format.record_encoded_len]u8 = undefined;
                for (records) |record| {
                    edge_order_format.encodeRecord(record, &record_bytes);
                    try writer.append(&record_bytes);
                }
                try writer.flush();
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.edge_order_path);
        }

        pub fn writeEdgeTombstoneIndexFromRepairSpool(self: Store, spool_path: []const u8, record_count: usize, expected_digest: u64) !void {
            return edge_tombstone_repair_index_publication.publish(self, spool_path, record_count, expected_digest);
        }

        pub fn eventBytes(self: Store) !u64 {
            var file = try std.Io.Dir.cwd().openFile(self.io, self.events_bin_path, .{});
            defer file.close(self.io);
            return regularFileSize(self, file);
        }

        pub fn fileSizeOrZero(self: Store, path: []const u8) !u64 {
            var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return 0,
                error.NotDir => return 0,
                error.IsDir => return error.IsDir,
                else => |e| return e,
            };
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.kind != .file) return error.IsDir;
            return stat.size;
        }

        pub fn nodeByIdFileSizeForStore(self: Store, max_node_id: u64) !u64 {
            const size = try nodeByIdFileSize(max_node_id);
            if (size > self.options.max_node_by_id_index_bytes) return error.RecordTooLarge;
            return size;
        }

        pub fn nodeByIdFileSizeForHeaderStore(self: Store, header: NodeByIdHeader) !u64 {
            const size = try nodeByIdFileSizeForHeader(header);
            if (size > self.options.max_node_by_id_index_bytes) return error.RecordTooLarge;
            return size;
        }

        pub fn tmpPathFor(self: Store, path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        }

        pub fn renameReplace(self: Store, tmp_path: []const u8, final_path: []const u8) !void {
            if (std.fs.path.isAbsolute(tmp_path) or std.fs.path.isAbsolute(final_path)) {
                try std.Io.Dir.renameAbsolute(tmp_path, final_path, self.io);
            } else {
                try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), final_path, self.io);
            }
            try syncParentDirForPath(self, final_path);
        }

        pub fn syncParentDirForPath(self: Store, path: []const u8) !void {
            if (!selfOptionsNeedSync(self)) return;
            if (builtin.os.tag == .windows) return;
            const dir_path = std.fs.path.dirname(path) orelse ".";
            var dir_file = if (std.fs.path.isAbsolute(dir_path))
                try std.Io.Dir.openFileAbsolute(self.io, dir_path, .{ .allow_directory = true })
            else
                try std.Io.Dir.cwd().openFile(self.io, dir_path, .{ .allow_directory = true });
            defer dir_file.close(self.io);
            try dir_file.sync(self.io);
        }

        test "store data plane rejects binary offset overflow" {
            var offset: u64 = std.math.maxInt(u64);
            try std.testing.expectError(error.InvalidRecord, advanceBinaryOffset(&offset, 1));
        }

        test "store data plane bounds write buffers by file size" {
            try std.testing.expectEqual(@as(usize, 1), try storageWriteBufferCapacity(1));
            try std.testing.expectEqual(storage_write_buffer_bytes, try storageWriteBufferCapacity(std.math.maxInt(u64)));
        }

        test "store data plane short text lane preserves u16 boundary" {
            try std.testing.expect(nodeTextLenFitsU16(std.math.maxInt(u16)));
            try std.testing.expect(!nodeTextLenFitsU16(@as(usize, std.math.maxInt(u16)) + 1));
        }

        test "store data plane node text hash is deterministic" {
            try std.testing.expectEqual(nodeTextHash("alpha"), nodeTextHash("alpha"));
            try std.testing.expect(nodeTextHash("alpha") != nodeTextHash("beta"));
        }
    };
}
