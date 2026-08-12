/// Node catalog primary-index publication and representation compaction.
/// The Store facade supplies paths, durable file operations, and shared format
/// primitives while this owner controls node-by-id and node-by-text shape
/// transitions, append admission, digest preservation, and repair publication.
pub fn NodeCatalogIndexOwner(comptime Ops: type) type {
    return struct {
        const std = Ops.dep_std;
        const core = Ops.dep_core;
        const graph_mod = Ops.dep_graph_mod;
        const Store = Ops.Store_dep;
        const NodeByIdHeader = Ops.NodeByIdHeader_dep;
        const NodeByIdRecord = Ops.NodeByIdRecord_dep;
        const NodeTextIndexHeader = Ops.NodeTextIndexHeader_dep;
        const NodeTextIndexRecord = Ops.NodeTextIndexRecord_dep;
        const IndexMeta = Ops.IndexMeta_dep;
        const NodeTextIndexDigest = Ops.NodeTextIndexDigest_dep;
        const NodeTextRepairPublishShape = Ops.NodeTextRepairPublishShape_dep;
        const TextSpan = Ops.TextSpan_dep;
        const NodeTextsView = Ops.NodeTextsView_dep;
        const StorageBufferedWriter = Ops.StorageBufferedWriter_dep;
        const nodeTextLenFitsU16 = Ops.nodeTextLenFitsU16_dep;
        const nodeRecordHasShortTextLen = Ops.nodeRecordHasShortTextLen_dep;
        const nodeRecordDigestFromParts = Ops.nodeRecordDigestFromParts_dep;
        const nodeTextHash = Ops.nodeTextHash_dep;
        const nodeByIdFileSizeForHeaderStore = Ops.nodeByIdFileSizeForHeaderStore_dep;
        const nodeByIdRecordOffsetForHeader = Ops.nodeByIdRecordOffsetForHeader_dep;
        const nodeByIdTextOffsetCheckpointCount = Ops.nodeByIdTextOffsetCheckpointCount_dep;
        const nodeByIdTextOffsetCheckpointTableOffset = Ops.nodeByIdTextOffsetCheckpointTableOffset_dep;
        const nodeByIdTextOffsetCheckpointOffset = Ops.nodeByIdTextOffsetCheckpointOffset_dep;
        const node_by_id_text_offset_checkpoint_stride = Ops.node_by_id_text_offset_checkpoint_stride_dep;
        const writeNodeByIdHeader = Ops.writeNodeByIdHeader_dep;
        const writeNodeByIdRecordAt = Ops.writeNodeByIdRecordAt_dep;
        const extendNodeByIdIndex = Ops.extendNodeByIdIndex_dep;
        const readNodeByIdRecordAt = Ops.readNodeByIdRecordAt_dep;
        const readNodeByIdRecordFromMap = Ops.readNodeByIdRecordFromMap_dep;
        const readDerivedNodeByIdTextLenAt = Ops.readDerivedNodeByIdTextLenAt_dep;
        const readNodeTextIndexRecordAtForHeaderWithTexts = Ops.readNodeTextIndexRecordAtForHeaderWithTexts_dep;
        const readNodeByIdHeaderFromFile = Ops.readNodeByIdHeaderFromFile_dep;
        const openReadOnlyMemoryMap = Ops.openReadOnlyMemoryMap_dep;
        const regularFileSize = Ops.regularFileSize_dep;
        const nodeTextIndexFileSizeForHeader = Ops.nodeTextIndexFileSizeForHeader_dep;
        const nodeTextIndexRecordOffsetForHeader = Ops.nodeTextIndexRecordOffsetForHeader_dep;
        const nodeTextIndexHeaderForRecords = Ops.nodeTextIndexHeaderForRecords_dep;
        const nodeTextIndexOrderDigestStep = Ops.nodeTextIndexOrderDigestStep_dep;
        const nodeTextIndexLessThan = Ops.nodeTextIndexLessThan_dep;
        const nodeTextRecordFitsHeader = Ops.nodeTextRecordFitsHeader_dep;
        const nodeTextRecordFitsStoredHeader = Ops.nodeTextRecordFitsStoredHeader_dep;
        const nodeTextIndexRecordDigestWithTexts = Ops.nodeTextIndexRecordDigestWithTexts_dep;
        const nodeTextsLogicalSize = Ops.nodeTextsLogicalSize_dep;
        const storage_write_buffer_bytes = Ops.storage_write_buffer_bytes_dep;
        const storageWriteBufferCapacity = Ops.storageWriteBufferCapacity_dep;
        const renameReplace = Ops.renameReplace_dep;
        const selfOptionsNeedSync = Ops.selfOptionsNeedSync_dep;
        const node_text_repair_index_publication = Ops.node_text_repair_index_publication_dep;
        const node_text_catalog_transaction = Ops.node_text_catalog_transaction_dep;
        const StorageNodeTextCatalogContext = Ops.StorageNodeTextCatalogContext_dep;
        const tmpPathFor = Ops.tmpPathFor_dep;
        const buildActiveNodeSet = Ops.buildActiveNodeSet_dep;
        const finalizePrimaryTextStorage = Ops.finalizePrimaryTextStorage_dep;
        const writeEmptyNodeTextDelta = Ops.writeEmptyNodeTextDelta_dep;
        const deleteNodeTextRunManifest = Ops.deleteNodeTextRunManifest_dep;
        const ensureCurrentNodeTextBaseHashFilter = Ops.ensureCurrentNodeTextBaseHashFilter_dep;

        pub fn appendNodeByIdIndexRecord(self: Store, node: graph_mod.Node, text_span: TextSpan) !NodeTextIndexRecord {
            const node_id = node.id.toInt();
            if (node_id == 0 or node_id == std.math.maxInt(u64)) return core.Error.InvalidId;
            if (node.text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
            if (text_span.len != node.text.len) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().createFile(self.io, self.node_by_id_path, .{
                .read = true,
                .truncate = false,
            });
            defer index_file.close(self.io);
            var header = try readNodeByIdHeaderFromFile(self, index_file);
            if (header.hasDerivedTextOffset()) {
                var text_records = std.ArrayList(NodeTextIndexRecord).empty;
                defer text_records.deinit(self.allocator);
                try text_records.ensureTotalCapacity(self.allocator, 1);

                var next_meta = IndexMeta{
                    .nodes = header.node_count,
                    .node_digest = header.node_digest,
                };
                const nodes = [_]graph_mod.Node{node};
                const text_spans = [_]TextSpan{text_span};
                if (try appendNodeByIdDerivedDenseTailBatch(self, index_file, &header, &nodes, &text_spans, &text_records, &next_meta)) {
                    if (text_records.items.len != 1) return error.InvalidRecord;
                    if (selfOptionsNeedSync(self)) try index_file.sync(self.io);
                    return text_records.items[0];
                }
            }
            if (header.hasDerivedTextOffset()) {
                try convertNodeByIdIndexToWideUniformRecords(self, index_file, &header);
            }
            const next_node_count = std.math.add(u64, header.node_count, 1) catch return error.RecordTooLarge;
            const next_max_node_id = @max(header.max_node_id, node_id);
            if (header.node_count == 0) {
                header = if (node.text.len == 0)
                    NodeByIdHeader{ .max_node_id = header.max_node_id, .node_count = header.node_count, .node_digest = header.node_digest }
                else
                    nodeByIdHeaderForUniformKind(node.kind, header.max_node_id, header.node_count, header.node_digest, nodeTextLenFitsU16(node.text.len));
                try writeNodeByIdHeader(self, index_file, header);
            } else if (header.hasUniformKind() and header.uniform_kind != @intFromEnum(node.kind)) {
                try convertNodeByIdIndexToFullRecords(self, index_file, &header);
            } else if (header.hasUniformKind() and header.hasShortTextLen() and !nodeTextLenFitsU16(node.text.len)) {
                try convertNodeByIdIndexToWideUniformRecords(self, index_file, &header);
            }
            _ = try nodeByIdFileSizeForHeaderStore(self, .{
                .max_node_id = next_max_node_id,
                .node_count = header.node_count,
                .node_digest = header.node_digest,
                .flags = header.flags,
                .record_len = header.record_len,
                .uniform_kind = header.uniform_kind,
            });
            if (node_id <= header.max_node_id) {
                const existing = try readNodeByIdRecordAt(self, index_file, header, node_id);
                if (existing.id != 0) return core.Error.InvalidId;
            }

            const node_digest = try nodeRecordDigestFromParts(node_id, node.kind, node.text);

            if (node_id > header.max_node_id) {
                try extendNodeByIdIndex(self, index_file, header.max_node_id, node_id);
                header.max_node_id = node_id;
            }

            const record = NodeByIdRecord{
                .id = node_id,
                .kind = @intFromEnum(node.kind),
                .text_offset = text_span.offset,
                .text_len = @intCast(node.text.len),
            };
            try writeNodeByIdRecordAt(self, index_file, header, record);
            header.node_count = next_node_count;
            header.node_digest ^= node_digest;
            try writeNodeByIdHeader(self, index_file, header);
            try compactNodeByIdIndexToDerivedTextOffsets(self, index_file, &header);
            if (selfOptionsNeedSync(self)) try index_file.sync(self.io);

            return .{
                .hash = nodeTextHash(node.text),
                .id = node_id,
                .kind = @intFromEnum(node.kind),
                .text_offset = text_span.offset,
                .text_len = @intCast(node.text.len),
            };
        }

        pub fn nodeByIdHeaderForUniformKind(kind: core.NodeKind, max_node_id: u64, node_count: u64, node_digest: u64, short_text_len: bool) NodeByIdHeader {
            var header = NodeByIdHeader.uniform(kind, short_text_len);
            header.max_node_id = max_node_id;
            header.node_count = node_count;
            header.node_digest = node_digest;
            return header;
        }

        pub fn nodeByIdCanUseUniformAppend(header: NodeByIdHeader, nodes: []const graph_mod.Node) bool {
            if (nodes.len == 0) return false;
            const first_kind = nodes[0].kind;
            if (header.node_count == 0) {
                for (nodes) |node| {
                    if (node.kind != first_kind) return false;
                }
                return true;
            }
            if (!header.hasUniformKind()) return false;
            if (header.uniform_kind != @intFromEnum(first_kind)) return false;
            for (nodes) |node| {
                if (node.kind != first_kind) return false;
            }
            return true;
        }

        pub fn nodeByIdBatchIsDenseTail(header: NodeByIdHeader, nodes: []const graph_mod.Node) bool {
            if (nodes.len == 0) return false;
            if (header.max_node_id == std.math.maxInt(u64)) return false;
            var expected_id = header.max_node_id + 1;
            for (nodes, 0..) |node, index| {
                if (node.id.toInt() != expected_id) return false;
                if (index + 1 < nodes.len) {
                    if (expected_id == std.math.maxInt(u64)) return false;
                    expected_id += 1;
                }
            }
            return true;
        }

        pub fn nodeByIdCanAppendDerivedDenseTail(header: NodeByIdHeader, nodes: []const graph_mod.Node) bool {
            return header.hasDerivedTextOffset() and
                nodeByIdBatchIsDenseTail(header, nodes) and
                nodeByIdCanUseUniformAppend(header, nodes) and
                nodeBatchTextsFitU16(nodes);
        }

        pub fn nodeBatchTextsFitU16(nodes: []const graph_mod.Node) bool {
            for (nodes) |node| {
                if (!nodeTextLenFitsU16(node.text.len)) return false;
            }
            return true;
        }

        pub fn nodeBatchHasZeroLengthText(nodes: []const graph_mod.Node) bool {
            for (nodes) |node| {
                if (node.text.len == 0) return true;
            }
            return false;
        }

        pub fn appendNodeByIdInitialDerivedDenseBatch(
            self: Store,
            file: std.Io.File,
            header: *NodeByIdHeader,
            nodes: []const graph_mod.Node,
            text_spans: []const TextSpan,
            text_records: *std.ArrayList(NodeTextIndexRecord),
            next_meta: *IndexMeta,
        ) !bool {
            if (nodes.len == 0) return false;
            if (nodes.len != text_spans.len) return error.InvalidRecord;
            if (header.node_count != 0 or header.max_node_id != 0 or header.node_digest != 0) return false;
            if (!nodeByIdBatchIsDenseTail(header.*, nodes)) return false;
            if (!nodeByIdCanUseUniformAppend(header.*, nodes)) return false;
            if (!nodeBatchTextsFitU16(nodes)) return false;
            if (text_spans[0].offset != 0) return false;
            if (try regularFileSize(self, file) != try nodeByIdFileSizeForHeaderStore(self, header.*)) return error.InvalidRecord;

            var validated_text_end: u64 = 0;
            for (nodes, text_spans) |node, text_span| {
                if (text_span.len != node.text.len) return error.InvalidRecord;
                if (text_span.offset != validated_text_end) return false;
                validated_text_end = std.math.add(u64, validated_text_end, text_span.len) catch return error.InvalidRecord;
            }

            var next_header = nodeByIdHeaderForUniformKind(
                nodes[0].kind,
                nodes[nodes.len - 1].id.toInt(),
                @intCast(nodes.len),
                0,
                true,
            );
            next_header.flags |= NodeByIdHeader.flag_derived_text_offset;
            next_header.record_len = next_header.expectedRecordLen();
            try next_header.validateShape();

            var record_writer = try StorageBufferedWriter.initAtOffset(
                self.allocator,
                self.io,
                file,
                storage_write_buffer_bytes,
                try nodeByIdRecordOffsetForHeader(next_header, nodes[0].id.toInt()),
            );
            defer record_writer.deinit();

            var len_bytes: [2]u8 = undefined;
            var expected_text_offset: u64 = 0;
            for (nodes, text_spans) |node, text_span| {
                if (text_span.offset != expected_text_offset) return error.InvalidRecord;
                const node_id = node.id.toInt();
                const node_digest = try nodeRecordDigestFromParts(node_id, node.kind, node.text);
                const text_len = std.math.cast(u16, node.text.len) orelse return error.InvalidRecord;
                std.mem.writeInt(u16, &len_bytes, text_len, .little);
                try record_writer.append(&len_bytes);
                try text_records.append(self.allocator, .{
                    .hash = nodeTextHash(node.text),
                    .id = node_id,
                    .kind = @intFromEnum(node.kind),
                    .text_offset = text_span.offset,
                    .text_len = @intCast(node.text.len),
                });
                next_meta.nodes = std.math.add(u64, next_meta.nodes, 1) catch return error.InvalidRecord;
                next_meta.node_digest ^= node_digest;
                expected_text_offset = std.math.add(u64, expected_text_offset, text_span.len) catch return error.InvalidRecord;
            }
            try record_writer.flush();

            next_header.node_digest = next_meta.node_digest;
            if (next_header.node_count != next_meta.nodes) return error.InvalidRecord;
            if (try record_writer.position() != try nodeByIdTextOffsetCheckpointTableOffset(next_header)) return error.InvalidRecord;
            const expected_new_size = try nodeByIdFileSizeForHeaderStore(self, next_header);
            try file.setLength(self.io, expected_new_size);

            var checkpoint_value: u64 = 0;
            var checkpoint_index: usize = 0;
            const checkpoint_count = try nodeByIdTextOffsetCheckpointCount(next_header);
            var block: u64 = 0;
            while (block < checkpoint_count) : (block += 1) {
                const block_start_base = std.math.mul(u64, block, node_by_id_text_offset_checkpoint_stride) catch return error.InvalidRecord;
                const block_start_id = std.math.add(u64, block_start_base, 1) catch return error.InvalidRecord;
                const before_block = std.math.cast(usize, block_start_id - 1) orelse return error.RecordTooLarge;
                if (before_block > text_spans.len) return error.InvalidRecord;
                while (checkpoint_index < before_block) : (checkpoint_index += 1) {
                    checkpoint_value = std.math.add(u64, checkpoint_value, text_spans[checkpoint_index].len) catch return error.InvalidRecord;
                }
                var checkpoint_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &checkpoint_bytes, checkpoint_value, .little);
                try file.writePositionalAll(self.io, &checkpoint_bytes, try nodeByIdTextOffsetCheckpointOffset(next_header, block));
            }

            try writeNodeByIdHeader(self, file, next_header);
            if (try regularFileSize(self, file) != expected_new_size) return error.InvalidRecord;
            header.* = next_header;
            return true;
        }

        pub fn appendNodeByIdDerivedDenseTailBatch(
            self: Store,
            file: std.Io.File,
            header: *NodeByIdHeader,
            nodes: []const graph_mod.Node,
            text_spans: []const TextSpan,
            text_records: *std.ArrayList(NodeTextIndexRecord),
            next_meta: *IndexMeta,
        ) !bool {
            if (!nodeByIdCanAppendDerivedDenseTail(header.*, nodes)) return false;
            if (nodes.len != text_spans.len) return error.InvalidRecord;

            const old_header = header.*;
            const old_size = try nodeByIdFileSizeForHeaderStore(self, old_header);
            if (try regularFileSize(self, file) != old_size) return error.InvalidRecord;

            var expected_text_offset: u64 = if (old_header.max_node_id == 0) 0 else blk: {
                const last = try readNodeByIdRecordAt(self, file, old_header, old_header.max_node_id);
                break :blk std.math.add(u64, last.text_offset, last.text_len) catch return error.InvalidRecord;
            };
            if (text_spans[0].offset != expected_text_offset) return false;
            var validated_text_end = expected_text_offset;
            for (nodes, text_spans) |node, text_span| {
                if (text_span.len != node.text.len) return error.InvalidRecord;
                if (text_span.offset != validated_text_end) return false;
                validated_text_end = std.math.add(u64, validated_text_end, text_span.len) catch return error.InvalidRecord;
            }

            const old_checkpoint_count = try nodeByIdTextOffsetCheckpointCount(old_header);
            const old_checkpoint_bytes_len_u64 = std.math.mul(u64, old_checkpoint_count, 8) catch return error.InvalidRecord;
            const old_checkpoint_bytes_len = std.math.cast(usize, old_checkpoint_bytes_len_u64) orelse return error.RecordTooLarge;
            const old_checkpoint_bytes = try self.allocator.alloc(u8, old_checkpoint_bytes_len);
            defer self.allocator.free(old_checkpoint_bytes);
            if (old_checkpoint_bytes.len != 0) {
                const bytes_read = try file.readPositionalAll(self.io, old_checkpoint_bytes, try nodeByIdTextOffsetCheckpointTableOffset(old_header));
                if (bytes_read != old_checkpoint_bytes.len) return error.InvalidRecord;
            }

            var next_header = old_header;
            next_header.max_node_id = nodes[nodes.len - 1].id.toInt();
            next_header.node_count = std.math.add(u64, old_header.node_count, @intCast(nodes.len)) catch return error.RecordTooLarge;

            var record_writer = try StorageBufferedWriter.initAtOffset(
                self.allocator,
                self.io,
                file,
                storage_write_buffer_bytes,
                try nodeByIdRecordOffsetForHeader(next_header, nodes[0].id.toInt()),
            );
            defer record_writer.deinit();

            var record_bytes: [NodeByIdRecord.uniform_short_derived_offset_encoded_len]u8 = undefined;
            for (nodes, text_spans) |node, text_span| {
                if (text_span.len != node.text.len) return error.InvalidRecord;
                if (text_span.offset != expected_text_offset) return error.InvalidRecord;
                const node_digest = try nodeRecordDigestFromParts(node.id.toInt(), node.kind, node.text);
                const record = NodeByIdRecord{
                    .id = node.id.toInt(),
                    .kind = @intFromEnum(node.kind),
                    .text_offset = text_span.offset,
                    .text_len = @intCast(node.text.len),
                };
                try record.encodeForHeader(next_header, &record_bytes);
                try record_writer.append(&record_bytes);
                try text_records.append(self.allocator, .{
                    .hash = nodeTextHash(node.text),
                    .id = node.id.toInt(),
                    .kind = @intFromEnum(node.kind),
                    .text_offset = text_span.offset,
                    .text_len = @intCast(node.text.len),
                });
                next_meta.nodes = std.math.add(u64, next_meta.nodes, 1) catch return error.InvalidRecord;
                next_meta.node_digest ^= node_digest;
                expected_text_offset = std.math.add(u64, expected_text_offset, text_span.len) catch return error.InvalidRecord;
            }
            try record_writer.flush();

            next_header.node_digest = next_meta.node_digest;
            if (next_header.node_count != next_meta.nodes) return error.InvalidRecord;
            if (try record_writer.position() != try nodeByIdTextOffsetCheckpointTableOffset(next_header)) return error.InvalidRecord;
            const expected_new_size = try nodeByIdFileSizeForHeaderStore(self, next_header);
            try file.setLength(self.io, expected_new_size);

            const new_checkpoint_table_offset = try nodeByIdTextOffsetCheckpointTableOffset(next_header);
            if (old_checkpoint_bytes.len != 0) {
                try file.writePositionalAll(self.io, old_checkpoint_bytes, new_checkpoint_table_offset);
            }

            const new_checkpoint_count = try nodeByIdTextOffsetCheckpointCount(next_header);
            var appended_len_prefix: u64 = 0;
            var appended_index: usize = 0;
            var block = old_checkpoint_count;
            while (block < new_checkpoint_count) : (block += 1) {
                const block_start_base = std.math.mul(u64, block, node_by_id_text_offset_checkpoint_stride) catch return error.InvalidRecord;
                const block_start_id = std.math.add(u64, block_start_base, 1) catch return error.InvalidRecord;
                if (block_start_id <= old_header.max_node_id) return error.InvalidRecord;
                const first_new_id = old_header.max_node_id + 1;
                const appended_before = std.math.cast(usize, block_start_id - first_new_id) orelse return error.RecordTooLarge;
                if (appended_before > text_spans.len) return error.InvalidRecord;
                while (appended_index < appended_before) : (appended_index += 1) {
                    appended_len_prefix = std.math.add(u64, appended_len_prefix, text_spans[appended_index].len) catch return error.InvalidRecord;
                }
                const checkpoint_value = std.math.add(u64, text_spans[0].offset, appended_len_prefix) catch return error.InvalidRecord;
                var checkpoint_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &checkpoint_bytes, checkpoint_value, .little);
                try file.writePositionalAll(self.io, &checkpoint_bytes, try nodeByIdTextOffsetCheckpointOffset(next_header, block));
            }

            try writeNodeByIdHeader(self, file, next_header);
            if (try regularFileSize(self, file) != expected_new_size) return error.InvalidRecord;
            header.* = next_header;
            return true;
        }

        pub fn convertNodeByIdIndexToFullRecords(self: Store, file: std.Io.File, header: *NodeByIdHeader) !void {
            if (!header.hasUniformKind()) return;
            const old_header = header.*;
            var full_header = NodeByIdHeader{
                .max_node_id = old_header.max_node_id,
                .node_count = old_header.node_count,
                .node_digest = old_header.node_digest,
            };
            try full_header.validateShape();
            try file.setLength(self.io, try nodeByIdFileSizeForHeaderStore(self, full_header));
            var id = old_header.max_node_id;
            while (id > 0) : (id -= 1) {
                const record = try readNodeByIdRecordAt(self, file, old_header, id);
                var bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
                try record.encode(&bytes);
                try file.writePositionalAll(self.io, &bytes, try nodeByIdRecordOffsetForHeader(full_header, id));
            }
            try writeNodeByIdHeader(self, file, full_header);
            header.* = full_header;
        }

        pub fn convertNodeByIdIndexToWideUniformRecords(self: Store, file: std.Io.File, header: *NodeByIdHeader) !void {
            if (!header.hasUniformKind() or !header.hasShortTextLen()) return;
            const old_header = header.*;
            var wide_header = NodeByIdHeader{
                .max_node_id = old_header.max_node_id,
                .node_count = old_header.node_count,
                .node_digest = old_header.node_digest,
                .flags = if (old_header.hasDerivedTextOffset())
                    NodeByIdHeader.flag_uniform_kind | NodeByIdHeader.flag_short_text_len
                else
                    NodeByIdHeader.flag_uniform_kind,
                .record_len = if (old_header.hasDerivedTextOffset())
                    NodeByIdRecord.uniform_short_text_len_encoded_len
                else
                    NodeByIdRecord.uniform_encoded_len,
                .uniform_kind = old_header.uniform_kind,
            };
            try wide_header.validateShape();
            if (old_header.hasDerivedTextOffset()) {
                const node_count = std.math.cast(usize, old_header.node_count) orelse return error.RecordTooLarge;
                var lengths = try self.allocator.alloc(u16, node_count);
                defer self.allocator.free(lengths);

                var id: u64 = 1;
                while (id <= old_header.max_node_id) : (id += 1) {
                    lengths[@intCast(id - 1)] = std.math.cast(u16, try readDerivedNodeByIdTextLenAt(self, file, old_header, id)) orelse return error.InvalidRecord;
                }

                try file.setLength(self.io, try nodeByIdFileSizeForHeaderStore(self, wide_header));
                var text_offset: u64 = 0;
                for (lengths, 0..) |text_len, index| {
                    const node_id: u64 = @intCast(index + 1);
                    const record = NodeByIdRecord{
                        .id = node_id,
                        .kind = old_header.uniform_kind,
                        .text_offset = text_offset,
                        .text_len = text_len,
                    };
                    var bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
                    const encoded = bytes[0..wide_header.record_len];
                    try record.encodeForHeader(wide_header, encoded);
                    try file.writePositionalAll(self.io, encoded, try nodeByIdRecordOffsetForHeader(wide_header, node_id));
                    text_offset = std.math.add(u64, text_offset, text_len) catch return error.InvalidRecord;
                }
                try writeNodeByIdHeader(self, file, wide_header);
                header.* = wide_header;
                return;
            }
            try file.setLength(self.io, try nodeByIdFileSizeForHeaderStore(self, wide_header));
            var id = old_header.max_node_id;
            while (id > 0) : (id -= 1) {
                const record = try readNodeByIdRecordAt(self, file, old_header, id);
                var bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
                const encoded = bytes[0..wide_header.record_len];
                try record.encodeForHeader(wide_header, encoded);
                try file.writePositionalAll(self.io, encoded, try nodeByIdRecordOffsetForHeader(wide_header, id));
            }
            try writeNodeByIdHeader(self, file, wide_header);
            header.* = wide_header;
        }

        pub fn compactNodeByIdIndexToUniformRecords(self: Store, file: std.Io.File, header: *NodeByIdHeader, kind: core.NodeKind) !void {
            if (header.hasUniformKind()) return;
            const old_header = header.*;
            const old_size = try nodeByIdFileSizeForHeaderStore(self, old_header);
            if (try regularFileSize(self, file) != old_size) return error.InvalidRecord;
            var old_map = openReadOnlyMemoryMap(self.io, file, old_size) catch null;
            defer if (old_map) |*mapped| mapped.destroy(self.io);

            var short_text_lens = true;
            var check_id: u64 = 1;
            while (check_id <= old_header.max_node_id) : (check_id += 1) {
                const record = if (old_map) |*mapped|
                    try readNodeByIdRecordFromMap(old_header, mapped, check_id)
                else
                    try readNodeByIdRecordAt(self, file, old_header, check_id);
                if (record.id != 0 and record.text_len == 0) return;
                if (record.id != 0 and !nodeRecordHasShortTextLen(record)) {
                    short_text_lens = false;
                    break;
                }
            }
            var uniform_header = nodeByIdHeaderForUniformKind(kind, old_header.max_node_id, old_header.node_count, old_header.node_digest, short_text_lens);
            try uniform_header.validateShape();
            var id: u64 = 1;
            while (id <= old_header.max_node_id) : (id += 1) {
                const record = if (old_map) |*mapped|
                    try readNodeByIdRecordFromMap(old_header, mapped, id)
                else
                    try readNodeByIdRecordAt(self, file, old_header, id);
                var bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
                const encoded = bytes[0..uniform_header.record_len];
                try record.encodeForHeader(uniform_header, encoded);
                try file.writePositionalAll(self.io, encoded, try nodeByIdRecordOffsetForHeader(uniform_header, id));
            }
            if (old_map) |*mapped| {
                mapped.destroy(self.io);
                old_map = null;
            }
            try file.setLength(self.io, try nodeByIdFileSizeForHeaderStore(self, uniform_header));
            try writeNodeByIdHeader(self, file, uniform_header);
            header.* = uniform_header;
        }

        pub fn rewriteNodeByIdIndexToUniformRecordsFromTextRepair(
            self: Store,
            file: std.Io.File,
            header: *NodeByIdHeader,
            kind: core.NodeKind,
            text_repair_file: std.Io.File,
            node_count: u64,
            short_text_lens: bool,
        ) !void {
            if (header.hasUniformKind()) return;
            const old_header = header.*;
            if (old_header.node_count != node_count) return error.InvalidRecord;
            var uniform_header = nodeByIdHeaderForUniformKind(kind, old_header.max_node_id, old_header.node_count, old_header.node_digest, short_text_lens);
            try uniform_header.validateShape();
            const expected_size = try nodeByIdFileSizeForHeaderStore(self, uniform_header);

            var record_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
            var text_record_bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
            var index: u64 = 0;
            while (index < node_count) : (index += 1) {
                const offset = std.math.mul(u64, index, NodeTextIndexRecord.encoded_len) catch return error.InvalidRecord;
                const n = try text_repair_file.readPositionalAll(self.io, &text_record_bytes, offset);
                if (n != text_record_bytes.len) return error.InvalidRecord;
                const text_record = try NodeTextIndexRecord.decode(&text_record_bytes);
                if (text_record.kind != @intFromEnum(kind)) return error.InvalidRecord;
                if (text_record.text_len == 0) return;
            }

            try file.setLength(self.io, 0);
            try file.setLength(self.io, expected_size);

            index = 0;
            while (index < node_count) : (index += 1) {
                const offset = std.math.mul(u64, index, NodeTextIndexRecord.encoded_len) catch return error.InvalidRecord;
                const n = try text_repair_file.readPositionalAll(self.io, &text_record_bytes, offset);
                if (n != text_record_bytes.len) return error.InvalidRecord;
                const text_record = try NodeTextIndexRecord.decode(&text_record_bytes);
                if (text_record.kind != @intFromEnum(kind)) return error.InvalidRecord;

                const node_record = NodeByIdRecord{
                    .id = text_record.id,
                    .kind = text_record.kind,
                    .text_offset = text_record.text_offset,
                    .text_len = text_record.text_len,
                };
                const encoded = record_bytes[0..uniform_header.record_len];
                try node_record.encodeForHeader(uniform_header, encoded);
                try file.writePositionalAll(self.io, encoded, try nodeByIdRecordOffsetForHeader(uniform_header, node_record.id));
            }

            try writeNodeByIdHeader(self, file, uniform_header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            header.* = uniform_header;
        }

        pub fn compactNodeByIdIndexToDerivedTextOffsets(self: Store, file: std.Io.File, header: *NodeByIdHeader) !void {
            try header.validateShape();
            if (header.hasDerivedTextOffset()) return;
            if (!header.hasUniformKind()) return;
            if (header.node_count == 0 or header.node_count != header.max_node_id) return;

            const old_header = header.*;
            const old_size = try nodeByIdFileSizeForHeaderStore(self, old_header);
            if (try regularFileSize(self, file) != old_size) return error.InvalidRecord;
            var old_map = openReadOnlyMemoryMap(self.io, file, old_size) catch null;
            defer if (old_map) |*mapped| mapped.destroy(self.io);

            const node_count = std.math.cast(usize, old_header.node_count) orelse return error.RecordTooLarge;
            var lengths = try self.allocator.alloc(u16, node_count);
            defer self.allocator.free(lengths);

            const texts_size = try nodeTextsLogicalSize(self);
            var expected_offset: u64 = 0;
            var id: u64 = 1;
            while (id <= old_header.max_node_id) : (id += 1) {
                const record = if (old_map) |*mapped|
                    try readNodeByIdRecordFromMap(old_header, mapped, id)
                else
                    try readNodeByIdRecordAt(self, file, old_header, id);
                if (record.id != id) return;
                if (record.text_offset != expected_offset) return;
                const short_len = std.math.cast(u16, record.text_len) orelse return;
                lengths[@intCast(id - 1)] = short_len;
                expected_offset = std.math.add(u64, expected_offset, record.text_len) catch return error.InvalidRecord;
            }
            if (expected_offset != texts_size) return;
            if (old_map) |*mapped| {
                mapped.destroy(self.io);
                old_map = null;
            }

            var derived_header = old_header;
            derived_header.flags |= NodeByIdHeader.flag_short_text_len | NodeByIdHeader.flag_derived_text_offset;
            derived_header.record_len = derived_header.expectedRecordLen();
            try derived_header.validateShape();

            var row_bytes: [2]u8 = undefined;
            for (lengths, 0..) |text_len, index| {
                std.mem.writeInt(u16, &row_bytes, text_len, .little);
                const node_id: u64 = @intCast(index + 1);
                try file.writePositionalAll(self.io, &row_bytes, try nodeByIdRecordOffsetForHeader(derived_header, node_id));
            }

            var checkpoint_offset_value: u64 = 0;
            var checkpoint_block: u64 = 0;
            for (lengths, 0..) |text_len, index| {
                if ((@as(u64, @intCast(index)) % node_by_id_text_offset_checkpoint_stride) == 0) {
                    var checkpoint_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &checkpoint_bytes, checkpoint_offset_value, .little);
                    try file.writePositionalAll(self.io, &checkpoint_bytes, try nodeByIdTextOffsetCheckpointOffset(derived_header, checkpoint_block));
                    checkpoint_block += 1;
                }
                checkpoint_offset_value = std.math.add(u64, checkpoint_offset_value, text_len) catch return error.InvalidRecord;
            }
            try file.setLength(self.io, try nodeByIdFileSizeForHeaderStore(self, derived_header));
            try writeNodeByIdHeader(self, file, derived_header);
            header.* = derived_header;
        }

        pub fn rewriteNodeByIdIndexToDerivedDenseLengths(
            self: Store,
            file: std.Io.File,
            header: *NodeByIdHeader,
            kind: core.NodeKind,
            lengths: []const u16,
        ) !void {
            try header.validateShape();
            if (header.node_count == 0 or header.node_count != header.max_node_id) return error.InvalidRecord;
            if (lengths.len != header.node_count) return error.InvalidRecord;

            var derived_header = nodeByIdHeaderForUniformKind(kind, header.max_node_id, header.node_count, header.node_digest, true);
            derived_header.flags |= NodeByIdHeader.flag_derived_text_offset;
            derived_header.record_len = derived_header.expectedRecordLen();
            try derived_header.validateShape();

            const expected_size = try nodeByIdFileSizeForHeaderStore(self, derived_header);
            try file.setLength(self.io, expected_size);

            var record_writer = try StorageBufferedWriter.initAtOffset(
                self.allocator,
                self.io,
                file,
                storage_write_buffer_bytes,
                try nodeByIdRecordOffsetForHeader(derived_header, 1),
            );
            defer record_writer.deinit();

            var row_bytes: [NodeByIdRecord.uniform_short_derived_offset_encoded_len]u8 = undefined;
            for (lengths) |text_len| {
                std.mem.writeInt(u16, &row_bytes, text_len, .little);
                try record_writer.append(&row_bytes);
            }
            try record_writer.flush();
            if (try record_writer.position() != try nodeByIdTextOffsetCheckpointTableOffset(derived_header)) return error.InvalidRecord;

            var checkpoint_offset_value: u64 = 0;
            var checkpoint_block: u64 = 0;
            for (lengths, 0..) |text_len, index| {
                if ((@as(u64, @intCast(index)) % node_by_id_text_offset_checkpoint_stride) == 0) {
                    var checkpoint_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &checkpoint_bytes, checkpoint_offset_value, .little);
                    try file.writePositionalAll(self.io, &checkpoint_bytes, try nodeByIdTextOffsetCheckpointOffset(derived_header, checkpoint_block));
                    checkpoint_block += 1;
                }
                checkpoint_offset_value = std.math.add(u64, checkpoint_offset_value, text_len) catch return error.InvalidRecord;
            }
            if (checkpoint_block != try nodeByIdTextOffsetCheckpointCount(derived_header)) return error.InvalidRecord;

            try writeNodeByIdHeader(self, file, derived_header);
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            header.* = derived_header;
        }

        pub fn appendNodeByIdIndexRecordsBatch(
            self: Store,
            old_meta: IndexMeta,
            nodes: []const graph_mod.Node,
            text_spans: []const TextSpan,
            text_records: *std.ArrayList(NodeTextIndexRecord),
            next_meta: *IndexMeta,
        ) !void {
            if (nodes.len == 0) return;
            if (nodes.len != text_spans.len) return error.InvalidRecord;

            var index_file = try std.Io.Dir.cwd().createFile(self.io, self.node_by_id_path, .{
                .read = true,
                .truncate = false,
            });
            defer index_file.close(self.io);
            var header = try readNodeByIdHeaderFromFile(self, index_file);
            if (header.node_count != old_meta.nodes) return error.InvalidRecord;
            if (header.node_digest != old_meta.node_digest) return error.InvalidRecord;
            if (header.node_count > header.max_node_id) return error.InvalidRecord;

            if (try appendNodeByIdInitialDerivedDenseBatch(self, index_file, &header, nodes, text_spans, text_records, next_meta)) {
                if (selfOptionsNeedSync(self)) {
                    try index_file.sync(self.io);
                }
                return;
            }

            if (try appendNodeByIdDerivedDenseTailBatch(self, index_file, &header, nodes, text_spans, text_records, next_meta)) {
                if (selfOptionsNeedSync(self)) {
                    try index_file.sync(self.io);
                }
                return;
            }

            if (header.hasDerivedTextOffset()) {
                try convertNodeByIdIndexToWideUniformRecords(self, index_file, &header);
            }

            var next_max_node_id = header.max_node_id;
            var dense_tail = true;
            var expected_dense_id = std.math.add(u64, header.max_node_id, 1) catch return error.InvalidRecord;
            for (nodes) |node| {
                const node_id = node.id.toInt();
                next_max_node_id = @max(next_max_node_id, node_id);
                if (node_id != expected_dense_id) dense_tail = false;
                expected_dense_id = std.math.add(u64, expected_dense_id, 1) catch std.math.maxInt(u64);
            }
            const has_zero_length_text = nodeBatchHasZeroLengthText(nodes);
            if (!has_zero_length_text and nodeByIdCanUseUniformAppend(header, nodes)) {
                if (header.node_count == 0) {
                    header = nodeByIdHeaderForUniformKind(nodes[0].kind, header.max_node_id, header.node_count, header.node_digest, nodeBatchTextsFitU16(nodes));
                    try writeNodeByIdHeader(self, index_file, header);
                }
                if (header.hasShortTextLen() and !nodeBatchTextsFitU16(nodes)) {
                    try convertNodeByIdIndexToWideUniformRecords(self, index_file, &header);
                }
            } else if (header.hasUniformKind()) {
                try convertNodeByIdIndexToFullRecords(self, index_file, &header);
            }
            _ = try nodeByIdFileSizeForHeaderStore(self, .{
                .max_node_id = next_max_node_id,
                .node_count = header.node_count,
                .node_digest = header.node_digest,
                .flags = header.flags,
                .record_len = header.record_len,
                .uniform_kind = header.uniform_kind,
            });

            if (next_max_node_id > header.max_node_id) {
                try extendNodeByIdIndex(self, index_file, header.max_node_id, next_max_node_id);
                header.max_node_id = next_max_node_id;
            }

            var dense_writer: ?StorageBufferedWriter = null;
            defer if (dense_writer) |*writer| writer.deinit();
            if (dense_tail) {
                dense_writer = try StorageBufferedWriter.initAtOffset(
                    self.allocator,
                    self.io,
                    index_file,
                    storage_write_buffer_bytes,
                    try nodeByIdRecordOffsetForHeader(header, nodes[0].id.toInt()),
                );
            }

            for (nodes, text_spans) |node, text_span| {
                const node_id = node.id.toInt();
                if (text_span.len != node.text.len) return error.InvalidRecord;
                const node_digest = try nodeRecordDigestFromParts(node_id, node.kind, node.text);
                const record = NodeByIdRecord{
                    .id = node_id,
                    .kind = @intFromEnum(node.kind),
                    .text_offset = text_span.offset,
                    .text_len = @intCast(node.text.len),
                };
                var record_bytes: [NodeByIdRecord.encoded_len]u8 = undefined;
                const encoded = record_bytes[0..header.record_len];
                try record.encodeForHeader(header, encoded);
                if (dense_writer) |*writer| {
                    try writer.append(encoded);
                } else {
                    try index_file.writePositionalAll(self.io, encoded, try nodeByIdRecordOffsetForHeader(header, node_id));
                }
                try text_records.append(self.allocator, .{
                    .hash = nodeTextHash(node.text),
                    .id = node_id,
                    .kind = @intFromEnum(node.kind),
                    .text_offset = text_span.offset,
                    .text_len = @intCast(node.text.len),
                });
                next_meta.nodes = std.math.add(u64, next_meta.nodes, 1) catch return error.InvalidRecord;
                next_meta.node_digest ^= node_digest;
            }

            if (dense_writer) |*writer| try writer.flush();

            header.node_count = next_meta.nodes;
            header.node_digest = next_meta.node_digest;
            try writeNodeByIdHeader(self, index_file, header);
            try compactNodeByIdIndexToDerivedTextOffsets(self, index_file, &header);
            if (selfOptionsNeedSync(self)) {
                try index_file.sync(self.io);
            }
        }

        pub fn writeMergedNodeTextIndexBatch(
            self: Store,
            old_meta: IndexMeta,
            batch_records: []NodeTextIndexRecord,
            batch_digest: u64,
            next_digest: u64,
            span_derive_mode: node_text_catalog_transaction.SpanDeriveMode,
        ) !void {
            try node_text_catalog_transaction.writeMergedBatch(
                StorageNodeTextCatalogContext.init(self),
                old_meta,
                batch_records,
                batch_digest,
                next_digest,
                span_derive_mode,
            );
        }

        pub fn appendSortedNodeTextIndexTail(self: Store, file: std.Io.File, old_header: NodeTextIndexHeader, record: NodeTextIndexRecord, record_digest: u64) !void {
            if (old_header.node_count == 0) {
                var new_header = nodeTextIndexHeaderForRecords(&.{record}, record_digest, nodeTextIndexOrderDigestStep(old_header.order_digest, 0, record));
                new_header.setTextHashUnique(true);
                try writeNodeTextIndexRecordAt(self, file, new_header, 0, record);
                try writeNodeTextIndexHeader(self, file, new_header);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
                return;
            }
            if (!nodeTextRecordFitsHeader(old_header, record)) return error.InvalidRecord;
            if (!try nodeTextRecordFitsStoredHeader(self, old_header, record)) return error.InvalidRecord;
            var header_bytes: [NodeTextIndexHeader.encoded_len]u8 = undefined;
            var new_header = NodeTextIndexHeader{
                .node_count = old_header.node_count + 1,
                .node_digest = old_header.node_digest ^ record_digest,
                .order_digest = nodeTextIndexOrderDigestStep(old_header.order_digest, old_header.node_count, record),
                .flags = old_header.flags,
                .record_len = old_header.record_len,
                .uniform_kind = old_header.uniform_kind,
            };
            new_header.setTextHashUnique(false);
            try writeNodeTextIndexRecordAt(self, file, old_header, old_header.node_count, record);
            new_header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
        }

        pub fn writeNodeTextIndexWithDigestWithTexts(self: Store, records: []const NodeTextIndexRecord, node_digest: u64, texts: *const NodeTextsView) !void {
            var index_digest = NodeTextIndexDigest{};
            for (records) |record| index_digest.add(record, try nodeTextIndexRecordDigestWithTexts(self, texts, record));
            if (index_digest.digest != node_digest) return error.InvalidRecord;
            const text_hash_unique = try sortedNodeTextRecordsHaveUniqueTextHashes(self, texts, records);

            const tmp_path = try tmpPathFor(self, self.node_by_text_path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer file.close(self.io);
                var header = nodeTextIndexHeaderForRecords(records, node_digest, index_digest.order_digest);
                header.setTextHashUnique(text_hash_unique);
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(try nodeTextIndexFileSizeForHeader(header)));
                defer writer.deinit();

                var header_bytes: [NodeTextIndexHeader.encoded_len]u8 = undefined;
                header.encode(&header_bytes);
                try writer.append(&header_bytes);
                for (records) |record| {
                    try writeNodeTextIndexRecordToWriter(&writer, header, record);
                }
                try writer.flush();
                try compactNodeTextIndexToDerivedRecords(self, file, &header);
                if (selfOptionsNeedSync(self)) try file.sync(self.io);
            }
            try renameReplace(self, tmp_path, self.node_by_text_path);
            try writeEmptyNodeTextDelta(self);
            try deleteNodeTextRunManifest(self);
            try ensureCurrentNodeTextBaseHashFilter(self);
        }

        pub fn storedNodeTextsEqual(self: Store, texts: *const NodeTextsView, lhs: NodeTextIndexRecord, rhs: NodeTextIndexRecord) !bool {
            if (lhs.text_len != rhs.text_len) return false;
            const rhs_name = try texts.readTextAlloc(self.allocator, rhs.text_offset, rhs.text_len);
            defer self.allocator.free(rhs_name);
            return try texts.matches(lhs.text_offset, lhs.text_len, rhs_name);
        }

        pub fn sortedNodeTextRecordsHaveUniqueTextHashes(self: Store, texts: *const NodeTextsView, records: []const NodeTextIndexRecord) !bool {
            _ = self;
            _ = texts;
            var previous: ?NodeTextIndexRecord = null;
            for (records) |record| {
                if (previous) |prev| {
                    if (!nodeTextIndexLessThan({}, prev, record)) return false;
                    if (prev.hash == record.hash) return false;
                }
                previous = record;
            }
            return true;
        }

        pub fn writeNodeTextIndexFromRepairSpool(
            self: Store,
            spool_path: []const u8,
            record_count: usize,
            node_digest: u64,
            publish_shape: ?NodeTextRepairPublishShape,
        ) !void {
            return node_text_repair_index_publication.publish(self, spool_path, record_count, node_digest, publish_shape);
        }

        pub fn writeNodeTextIndexHeader(self: Store, file: std.Io.File, header: NodeTextIndexHeader) !void {
            try header.validateShape();
            var header_bytes: [NodeTextIndexHeader.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try file.writePositionalAll(self.io, &header_bytes, 0);
        }

        pub fn writeNodeTextIndexRecordToWriter(writer: *StorageBufferedWriter, header: NodeTextIndexHeader, record: NodeTextIndexRecord) !void {
            var record_bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
            const encoded = record_bytes[0..header.record_len];
            try record.encodeForHeader(header, encoded);
            try writer.append(encoded);
        }

        pub fn writeNodeTextIndexRecordAt(self: Store, file: std.Io.File, header: NodeTextIndexHeader, index: u64, record: NodeTextIndexRecord) !void {
            var record_bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
            const encoded = record_bytes[0..header.record_len];
            try record.encodeForHeader(header, encoded);
            try file.writePositionalAll(self.io, encoded, try nodeTextIndexRecordOffsetForHeader(header, index));
        }

        pub fn compactNodeTextIndexToDerivedRecords(self: Store, file: std.Io.File, header: *NodeTextIndexHeader) !void {
            if (header.node_count == 0) return;
            try header.validateShape();
            var texts = try NodeTextsView.open(self);
            defer texts.deinit();
            const node_file_opt = std.Io.Dir.cwd().openFile(self.io, self.node_by_id_path, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            };
            defer if (node_file_opt) |node_file| node_file.close(self.io);
            var node_header: NodeByIdHeader = undefined;
            var node_map: ?std.Io.File.MemoryMap = null;
            defer if (node_map) |*mapped| mapped.destroy(self.io);
            var derive_text_span = false;
            if (node_file_opt) |node_file| {
                node_header = readNodeByIdHeaderFromFile(self, node_file) catch NodeByIdHeader{ .node_count = 0, .max_node_id = 0 };
                const node_file_size = regularFileSize(self, node_file) catch 0;
                if (node_header.node_count != 0 and
                    node_header.node_count == header.node_count and
                    node_file_size == (nodeByIdFileSizeForHeaderStore(self, node_header) catch std.math.maxInt(u64)))
                {
                    derive_text_span = true;
                    node_map = openReadOnlyMemoryMap(self.io, node_file, node_file_size) catch null;
                }
            }
            var uniform_kind: ?u16 = null;
            var short_text_len = true;
            var u32_id = true;
            var text_hash_unique = true;
            var previous_hash_record: ?NodeTextIndexRecord = null;
            var pos: u64 = 0;
            while (pos < header.node_count) : (pos += 1) {
                const record = try readNodeTextIndexRecordAtForHeaderWithTexts(self, file, header.*, pos, &texts);
                if (previous_hash_record) |prev| {
                    if (prev.hash == record.hash) {
                        text_hash_unique = false;
                    }
                }
                previous_hash_record = record;
                if (derive_text_span) {
                    const node_file = node_file_opt orelse return error.InvalidRecord;
                    const by_id = (if (node_map) |*mapped|
                        readNodeByIdRecordFromMap(node_header, mapped, record.id)
                    else
                        readNodeByIdRecordAt(self, node_file, node_header, record.id)) catch {
                        derive_text_span = false;
                        continue;
                    };
                    if (by_id.id != record.id or
                        by_id.kind != record.kind or
                        by_id.text_offset != record.text_offset or
                        by_id.text_len != record.text_len)
                    {
                        derive_text_span = false;
                    }
                }
                if (pos == 0) {
                    uniform_kind = record.kind;
                } else if (uniform_kind != null and uniform_kind.? != record.kind) {
                    uniform_kind = null;
                }
                if (record.text_len > std.math.maxInt(u16)) short_text_len = false;
                if (record.id > std.math.maxInt(u32)) u32_id = false;
            }
            var derived_header = NodeTextIndexHeader.withShape(header.node_count, header.node_digest, header.order_digest, uniform_kind, short_text_len, u32_id, false, derive_text_span);
            derived_header.setTextHashUnique(text_hash_unique);
            if (derived_header.record_len == header.record_len and
                derived_header.flags == header.flags and
                derived_header.uniform_kind == header.uniform_kind) return;
            pos = 0;
            while (pos < header.node_count) : (pos += 1) {
                const record = try readNodeTextIndexRecordAtForHeaderWithTexts(self, file, header.*, pos, &texts);
                try writeNodeTextIndexRecordAt(self, file, derived_header, pos, record);
            }
            try file.setLength(self.io, try nodeTextIndexFileSizeForHeader(derived_header));
            try writeNodeTextIndexHeader(self, file, derived_header);
            header.* = derived_header;
        }

        pub fn rebuildPersistentNodeIndexes(self: Store, graph: *const graph_mod.Graph) !void {
            var active_node_set = try buildActiveNodeSet(self.allocator, graph);
            defer active_node_set.deinit();
            const active_nodes = active_node_set.count;
            var max_node_id: u64 = 0;
            var first_kind: ?core.NodeKind = null;
            var mixed_kind = false;
            for (graph.nodes.items) |node| {
                if (node.status != .active) continue;
                const node_id = node.id.toInt();
                if (node.text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                max_node_id = @max(max_node_id, node_id);
                if (first_kind) |kind| {
                    if (kind != node.kind) mixed_kind = true;
                } else {
                    first_kind = node.kind;
                }
            }
            var short_text_lens = true;
            for (graph.nodes.items) |node| {
                if (node.status != .active) continue;
                if (!nodeTextLenFitsU16(node.text.len)) {
                    short_text_lens = false;
                    break;
                }
            }
            const has_zero_length_text = blk: {
                for (graph.nodes.items) |node| {
                    if (node.status == .active and node.text.len == 0) break :blk true;
                }
                break :blk false;
            };
            const uniform_kind = if (!mixed_kind and !has_zero_length_text) first_kind else null;
            var by_id_header = if (uniform_kind) |kind|
                nodeByIdHeaderForUniformKind(kind, max_node_id, active_nodes, 0, short_text_lens)
            else
                NodeByIdHeader{ .max_node_id = max_node_id, .node_count = active_nodes };
            _ = try nodeByIdFileSizeForHeaderStore(self, by_id_header);

            const texts_tmp_path = try tmpPathFor(self, self.node_texts_path);
            defer self.allocator.free(texts_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, texts_tmp_path) catch {};
            const by_id_tmp_path = try tmpPathFor(self, self.node_by_id_path);
            defer self.allocator.free(by_id_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, by_id_tmp_path) catch {};
            const node_text_repair_path = try std.fmt.allocPrint(self.allocator, "{s}.repair_texts.tmp", .{self.node_by_text_path});
            defer self.allocator.free(node_text_repair_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, node_text_repair_path) catch {};

            var node_digest: u64 = 0;
            var node_text_record_count: usize = 0;
            {
                var texts_file = try std.Io.Dir.cwd().createFile(self.io, texts_tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer texts_file.close(self.io);
                var texts_writer = try StorageBufferedWriter.init(self.allocator, self.io, texts_file, storage_write_buffer_bytes);
                defer texts_writer.deinit();
                var text_repair_file = try std.Io.Dir.cwd().createFile(self.io, node_text_repair_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer text_repair_file.close(self.io);
                var text_repair_writer = try StorageBufferedWriter.init(self.allocator, self.io, text_repair_file, storage_write_buffer_bytes);
                defer text_repair_writer.deinit();

                var index_file = try std.Io.Dir.cwd().createFile(self.io, by_id_tmp_path, .{
                    .read = true,
                    .truncate = true,
                });
                defer index_file.close(self.io);

                try writeNodeByIdHeader(self, index_file, by_id_header);
                try extendNodeByIdIndex(self, index_file, 0, max_node_id);

                for (graph.nodes.items) |node| {
                    if (node.status != .active) continue;
                    const node_id = node.id.toInt();
                    const text_offset = try texts_writer.position();
                    try texts_writer.append(node.text);
                    node_digest ^= try nodeRecordDigestFromParts(node_id, node.kind, node.text);

                    const record = NodeByIdRecord{
                        .id = node_id,
                        .kind = @intFromEnum(node.kind),
                        .text_offset = text_offset,
                        .text_len = @intCast(node.text.len),
                    };
                    try writeNodeByIdRecordAt(self, index_file, by_id_header, record);

                    const text_record = NodeTextIndexRecord{
                        .hash = nodeTextHash(node.text),
                        .id = node_id,
                        .kind = @intFromEnum(node.kind),
                        .text_offset = text_offset,
                        .text_len = @intCast(node.text.len),
                    };
                    var text_record_bytes: [NodeTextIndexRecord.encoded_len]u8 = undefined;
                    try text_record.encode(&text_record_bytes);
                    try text_repair_writer.append(&text_record_bytes);
                    node_text_record_count = std.math.add(usize, node_text_record_count, 1) catch return error.InvalidRecord;
                }

                try texts_writer.flush();
                if (try regularFileSize(self, texts_file) != try texts_writer.position()) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try texts_file.sync(self.io);
                try text_repair_writer.flush();
                const expected_text_repair_size = std.math.mul(u64, @intCast(node_text_record_count), NodeTextIndexRecord.encoded_len) catch return error.InvalidRecord;
                if (try text_repair_writer.position() != expected_text_repair_size) return error.InvalidRecord;
                if (try regularFileSize(self, text_repair_file) != expected_text_repair_size) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try text_repair_file.sync(self.io);
                if (@as(u64, @intCast(node_text_record_count)) != active_nodes) return error.InvalidRecord;
                by_id_header.node_count = active_nodes;
                by_id_header.node_digest = node_digest;
                try writeNodeByIdHeader(self, index_file, by_id_header);
                try compactNodeByIdIndexToDerivedTextOffsets(self, index_file, &by_id_header);
                if (selfOptionsNeedSync(self)) try index_file.sync(self.io);
            }

            try renameReplace(self, texts_tmp_path, self.node_texts_path);
            try renameReplace(self, by_id_tmp_path, self.node_by_id_path);
            try finalizePrimaryTextStorage(self);

            const node_text_publish_shape = NodeTextRepairPublishShape{
                .uniform_kind = if (uniform_kind) |kind| @intFromEnum(kind) else null,
                .u32_id = max_node_id <= std.math.maxInt(u32),
                .derived_hash = false,
                .derived_text_span = true,
            };
            try writeNodeTextIndexFromRepairSpool(self, node_text_repair_path, node_text_record_count, node_digest, node_text_publish_shape);
            try writeEmptyNodeTextDelta(self);
            try deleteNodeTextRunManifest(self);
            std.Io.Dir.cwd().deleteFile(self.io, node_text_repair_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        }

        test "node catalog index owner admits a dense derived tail" {
            var header = NodeByIdHeader.uniform(.task, true);
            header.max_node_id = 2;
            header.node_count = 2;
            header.flags |= NodeByIdHeader.flag_derived_text_offset;
            header.record_len = header.expectedRecordLen();
            const nodes = [_]graph_mod.Node{
                .{ .id = .fromInt(3), .kind = .task, .text = "three" },
                .{ .id = .fromInt(4), .kind = .task, .text = "four" },
            };
            try std.testing.expect(nodeByIdBatchIsDenseTail(header, &nodes));
            try std.testing.expect(nodeByIdCanAppendDerivedDenseTail(header, &nodes));
            try std.testing.expect(nodeByIdCanUseUniformAppend(header, &nodes));
        }

        test "node catalog index owner rejects sparse or mixed derived tails" {
            var header = NodeByIdHeader.uniform(.task, true);
            header.max_node_id = 2;
            header.node_count = 2;
            header.flags |= NodeByIdHeader.flag_derived_text_offset;
            header.record_len = header.expectedRecordLen();
            const sparse = [_]graph_mod.Node{
                .{ .id = .fromInt(4), .kind = .task, .text = "four" },
            };
            const mixed = [_]graph_mod.Node{
                .{ .id = .fromInt(3), .kind = .file, .text = "three" },
            };
            try std.testing.expect(!nodeByIdBatchIsDenseTail(header, &sparse));
            try std.testing.expect(!nodeByIdCanAppendDerivedDenseTail(header, &sparse));
            try std.testing.expect(!nodeByIdCanUseUniformAppend(header, &mixed));
        }

        test "node catalog index owner derives the narrow uniform header shape" {
            const header = nodeByIdHeaderForUniformKind(.decision, 7, 7, 99, true);
            try header.validateShape();
            try std.testing.expect(header.hasUniformKind());
            try std.testing.expect(header.hasShortTextLen());
            try std.testing.expect(!header.hasDerivedTextOffset());
            try std.testing.expectEqual(@as(u64, 7), header.node_count);
            try std.testing.expectEqual(@as(u64, 99), header.node_digest);
        }
    };
}
