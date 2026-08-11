/// Edge-segment id-index construction and lookup lifecycle. The Store data
/// plane supplies concrete paths, manifest entries, run resources, durability,
/// and record readers while this owner controls external sorting, file layout,
/// trusted-summary admission, and bounded intersection queries.
pub fn EdgeSegmentIdIndexOwner(comptime Ops: type) type {
    return struct {
        const std = Ops.dep_std;
        const Store = Ops.Store_dep;
        const segment_mod = Ops.segment_mod_dep;
        const EdgeIndexRecord = Ops.EdgeIndexRecord_dep;
        const EdgeIndexRecordReader = Ops.EdgeIndexRecordReader_dep;
        const EdgeSegmentIdIndexHeader = Ops.EdgeSegmentIdIndexHeader_dep;
        const EdgeSegmentIdIndex = Ops.EdgeSegmentIdIndex_dep;
        const EdgeSegmentIdIndexRunHeapEntry = Ops.EdgeSegmentIdIndexRunHeapEntry_dep;
        const EdgeSegmentIdIndexRunReader = Ops.EdgeSegmentIdIndexRunReader_dep;
        const EdgeSegmentIdIndexWriter = Ops.EdgeSegmentIdIndexWriter_dep;
        const EdgeSegmentIdRunBuilder = Ops.EdgeSegmentIdRunBuilder_dep;
        const EdgeSegmentIdRunSet = Ops.EdgeSegmentIdRunSet_dep;
        const EdgeSegmentIdSidecarSummary = Ops.EdgeSegmentIdSidecarSummary_dep;
        const OwnedEdgeSegmentManifestEntry = Ops.OwnedEdgeSegmentManifestEntry_dep;
        const StorageBufferedWriter = Ops.StorageBufferedWriter_dep;
        const edgeSegmentIdSidecarSummaryFromCompleteRange = Ops.edgeSegmentIdSidecarSummaryFromCompleteRange_dep;
        const regularFileSize = Ops.regularFileSize_dep;
        const edge_segment_id_sort_chunk_records = Ops.edge_segment_id_sort_chunk_records_dep;
        const edgeSegmentIdDigest = Ops.edgeSegmentIdDigest_dep;
        const storageWriteBufferCapacity = Ops.storageWriteBufferCapacity_dep;
        const edgeSegmentIdIndexPath = Ops.edgeSegmentIdIndexPath_dep;
        const edgeSegmentIdRunSummaryFromRecords = Ops.edgeSegmentIdRunSummaryFromRecords_dep;
        const edgeSegmentManifestIdRunSummary = Ops.edgeSegmentManifestIdRunSummary_dep;
        const encodeEdgeSegmentIdIndexHeader = Ops.encodeEdgeSegmentIdIndexHeader_dep;
        const edgeSegmentManifestCanDeriveEdgeIdDigest = Ops.edgeSegmentManifestCanDeriveEdgeIdDigest_dep;
        const sortedSetIntersectsRange = Ops.sortedSetIntersectsRange_dep;
        const edgeSegmentManifestRunsCoverEntry = Ops.edgeSegmentManifestRunsCoverEntry_dep;
        const lowerBoundU64 = Ops.lowerBoundU64_dep;
        const edge_segment_id_index_stack_scan_max = Ops.edge_segment_id_index_stack_scan_max_dep;
        const currentProcessIdForTempPath = Ops.currentProcessIdForTempPath_dep;
        const u64LessThan = Ops.u64LessThan_dep;
        const edgeSegmentIdIndexOrderDigestAt = Ops.edgeSegmentIdIndexOrderDigestAt_dep;
        const selfOptionsNeedSync = Ops.selfOptionsNeedSync_dep;
        const tmpPathFor = Ops.tmpPathFor_dep;
        const edgeSegmentIdSidecarSummaryFromCompleteRuns = Ops.edgeSegmentIdSidecarSummaryFromCompleteRuns_dep;
        const edgeSegmentIdIndexFileSize = Ops.edgeSegmentIdIndexFileSize_dep;
        const store_temp_nonce = Ops.store_temp_nonce_dep;
        const renameReplace = Ops.renameReplace_dep;
        const openReadOnlyMemoryMap = Ops.openReadOnlyMemoryMap_dep;
        const decodeEdgeSegmentIdIndexHeader = Ops.decodeEdgeSegmentIdIndexHeader_dep;
        pub fn writeEdgeSegmentIdIndexFromSegment(
            self: Store,
            segment_dir_path: []const u8,
            segment: *segment_mod.ImmutableAdjacencySegment,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
        ) !EdgeSegmentIdSidecarSummary {
            if (try edgeSegmentIdSidecarSummaryFromCompleteRange(summary)) |sidecar_summary| return sidecar_summary;

            const pid = currentProcessIdForTempPath();
            const nonce = store_temp_nonce.fetchAdd(1, .monotonic);
            const spool_path = try std.fmt.allocPrint(self.allocator, "{s}/.edge-id-sidecar-spool-{d}-{d}.tmp", .{
                segment_dir_path,
                pid,
                nonce,
            });
            defer self.allocator.free(spool_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, spool_path) catch {};

            {
                var spool_file = try std.Io.Dir.cwd().createFile(self.io, spool_path, .{ .read = true, .truncate = true });
                defer spool_file.close(self.io);
                const spool_size = std.math.mul(u64, summary.count, 8) catch return error.RecordTooLarge;
                var writer = try StorageBufferedWriter.init(self.allocator, self.io, spool_file, try storageWriteBufferCapacity(spool_size));
                defer writer.deinit();

                var written: u64 = 0;
                var min_seen: u64 = std.math.maxInt(u64);
                var max_seen: u64 = 0;
                var digest: u64 = 0;
                var id_bytes: [8]u8 = undefined;
                var iter = try segment.edgeIterator(.forward);
                while (try iter.next()) |edge| {
                    const edge_id = edge.edge_id.toInt();
                    if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                    std.mem.writeInt(u64, &id_bytes, edge_id, .little);
                    try writer.append(&id_bytes);
                    written += 1;
                    min_seen = @min(min_seen, edge_id);
                    max_seen = @max(max_seen, edge_id);
                    digest ^= edgeSegmentIdDigest(edge_id);
                }
                if (written != summary.count) return error.InvalidRecord;
                if (min_seen != summary.range.min or max_seen != summary.range.max) return error.InvalidRecord;
                if (digest != summary.digest) return error.InvalidRecord;
                try writer.flush();
                if (try writer.position() != spool_size) return error.InvalidRecord;
                if (try regularFileSize(self, spool_file) != spool_size) return error.InvalidRecord;
                if (selfOptionsNeedSync(self)) try spool_file.sync(self.io);
            }

            if (summary.count <= edge_segment_id_sort_chunk_records) {
                const sidecar_summary = try writeEdgeSegmentIdIndexFromSingleSpoolChunk(self, segment_dir_path, spool_path, summary);
                std.Io.Dir.cwd().deleteFile(self.io, spool_path) catch {};
                return sidecar_summary;
            }

            var runs = try buildEdgeSegmentIdSortedRunsFromSpool(self, segment_dir_path, spool_path, summary.count, nonce);
            defer runs.deinit();
            const sidecar_summary = try writeEdgeSegmentIdIndexFromRunFiles(self, segment_dir_path, runs.paths.items, summary);
            std.Io.Dir.cwd().deleteFile(self.io, spool_path) catch {};
            return sidecar_summary;
        }

        pub fn buildEdgeSegmentIdSortedRunsFromSpool(
            self: Store,
            segment_dir_path: []const u8,
            spool_path: []const u8,
            record_count: u64,
            nonce: u64,
        ) !EdgeSegmentIdRunSet {
            const record_count_usize = std.math.cast(usize, record_count) orelse return error.RecordTooLarge;
            var spool_file = try std.Io.Dir.cwd().openFile(self.io, spool_path, .{});
            defer spool_file.close(self.io);
            const expected_spool_size = std.math.mul(u64, record_count, 8) catch return error.RecordTooLarge;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            var runs = EdgeSegmentIdRunSet{ .allocator = self.allocator, .store = self };
            errdefer runs.deinit();

            var chunk = std.ArrayList(u64).empty;
            defer chunk.deinit(self.allocator);
            const max_chunk_records = @min(record_count_usize, edge_segment_id_sort_chunk_records);
            try chunk.ensureTotalCapacityPrecise(self.allocator, max_chunk_records);
            const chunk_bytes = try self.allocator.alloc(u8, std.math.mul(usize, max_chunk_records, 8) catch return error.RecordTooLarge);
            defer self.allocator.free(chunk_bytes);

            const pid = currentProcessIdForTempPath();
            var read_pos: usize = 0;
            while (read_pos < record_count_usize) {
                chunk.clearRetainingCapacity();
                const take = @min(edge_segment_id_sort_chunk_records, record_count_usize - read_pos);
                try readEdgeSegmentIdSpoolChunk(self, spool_file, read_pos, take, chunk_bytes, &chunk);
                std.mem.sort(u64, chunk.items, {}, u64LessThan);
                const run_path = try std.fmt.allocPrint(self.allocator, "{s}/.edge-id-sidecar-run-{d}-{d}-{d}.tmp", .{
                    segment_dir_path,
                    pid,
                    nonce,
                    runs.paths.items.len,
                });
                var run_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
                    if (run_path_owned) self.allocator.free(run_path);
                }
                try writeEdgeSegmentIdRunFile(self, run_path, chunk.items);
                try runs.paths.append(self.allocator, run_path);
                run_path_owned = false;
                read_pos += take;
            }
            if (runs.paths.items.len == 0) return error.InvalidRecord;
            return runs;
        }

        pub fn readEdgeSegmentIdSpoolChunk(self: Store, file: std.Io.File, start_index: usize, record_count: usize, buffer: []u8, out: *std.ArrayList(u64)) !void {
            const byte_count = std.math.mul(usize, record_count, 8) catch return error.RecordTooLarge;
            if (byte_count > buffer.len) return error.InvalidRecord;
            const offset = std.math.mul(u64, @intCast(start_index), 8) catch return error.RecordTooLarge;
            const n = try file.readPositionalAll(self.io, buffer[0..byte_count], offset);
            if (n != byte_count) return error.InvalidRecord;
            var cursor: usize = 0;
            while (cursor < byte_count) : (cursor += 8) {
                var id_bytes: [8]u8 = undefined;
                @memcpy(&id_bytes, buffer[cursor .. cursor + 8]);
                const edge_id = std.mem.readInt(u64, &id_bytes, .little);
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                out.appendAssumeCapacity(edge_id);
            }
        }

        pub fn writeEdgeSegmentIdIndexFromSingleSpoolChunk(
            self: Store,
            segment_dir_path: []const u8,
            spool_path: []const u8,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
        ) !EdgeSegmentIdSidecarSummary {
            if (summary.count == 0) return error.InvalidRecord;
            const record_count_usize = std.math.cast(usize, summary.count) orelse return error.RecordTooLarge;
            if (record_count_usize > edge_segment_id_sort_chunk_records) return error.InvalidRecord;
            var spool_file = try std.Io.Dir.cwd().openFile(self.io, spool_path, .{});
            defer spool_file.close(self.io);
            const expected_spool_size = std.math.mul(u64, summary.count, 8) catch return error.RecordTooLarge;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            var edge_ids = std.ArrayList(u64).empty;
            defer edge_ids.deinit(self.allocator);
            try edge_ids.ensureTotalCapacityPrecise(self.allocator, record_count_usize);
            const chunk_bytes = try self.allocator.alloc(u8, std.math.mul(usize, record_count_usize, 8) catch return error.RecordTooLarge);
            defer self.allocator.free(chunk_bytes);

            try readEdgeSegmentIdSpoolChunk(self, spool_file, 0, record_count_usize, chunk_bytes, &edge_ids);
            std.mem.sort(u64, edge_ids.items, {}, u64LessThan);
            return try writeEdgeSegmentIdIndexFromSortedIds(self, segment_dir_path, edge_ids.items, summary);
        }

        pub fn writeEdgeSegmentIdIndexFromSortedIds(
            self: Store,
            segment_dir_path: []const u8,
            edge_ids: []const u64,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
        ) !EdgeSegmentIdSidecarSummary {
            if (@as(u64, @intCast(edge_ids.len)) != summary.count) return error.InvalidRecord;
            if (edge_ids.len == 0) return error.InvalidRecord;

            var previous: u64 = 0;
            var min_seen: u64 = std.math.maxInt(u64);
            var max_seen: u64 = 0;
            var digest: u64 = 0;
            var order_digest: u64 = 0;
            var run_builder = EdgeSegmentIdRunBuilder{};
            for (edge_ids, 0..) |edge_id, index| {
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (index != 0 and edge_id <= previous) return error.InvalidRecord;
                previous = edge_id;
                min_seen = @min(min_seen, edge_id);
                max_seen = @max(max_seen, edge_id);
                digest ^= edgeSegmentIdDigest(edge_id);
                order_digest ^= edgeSegmentIdIndexOrderDigestAt(index, edge_id);
                run_builder.add(edge_id);
            }
            if (min_seen != summary.range.min or max_seen != summary.range.max) return error.InvalidRecord;
            if (digest != summary.digest) return error.InvalidRecord;

            const final_runs = run_builder.finish();
            if (try edgeSegmentIdSidecarSummaryFromCompleteRuns(summary, final_runs)) |sidecar_summary| return sidecar_summary;

            const path = try edgeSegmentIdIndexPath(self, segment_dir_path);
            defer self.allocator.free(path);
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(self.io);
                var writer = try beginEdgeSegmentIdIndexFile(self, file, summary, order_digest);
                for (edge_ids, 0..) |edge_id, index| {
                    try writer.write(self, index, edge_id);
                }
                try writer.finish(self);
            }
            try renameReplace(self, tmp_path, path);
            return .{
                .edge_id_order_digest = order_digest,
                .edge_id_runs = final_runs,
            };
        }

        pub fn writeEdgeSegmentIdRunFile(self: Store, path: []const u8, edge_ids: []const u64) !void {
            const expected_size = std.math.mul(u64, @intCast(edge_ids.len), 8) catch return error.RecordTooLarge;
            var file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .truncate = true });
            defer file.close(self.io);
            var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();
            var previous: u64 = 0;
            var id_bytes: [8]u8 = undefined;
            for (edge_ids, 0..) |edge_id, index| {
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (index != 0 and edge_id <= previous) return error.InvalidRecord;
                previous = edge_id;
                std.mem.writeInt(u64, &id_bytes, edge_id, .little);
                try writer.append(&id_bytes);
            }
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
        }

        pub fn writeEdgeSegmentIdIndexFromRunFiles(
            self: Store,
            segment_dir_path: []const u8,
            run_paths: []const []const u8,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
        ) !EdgeSegmentIdSidecarSummary {
            if (run_paths.len == 0) return error.InvalidRecord;
            const path = try edgeSegmentIdIndexPath(self, segment_dir_path);
            defer self.allocator.free(path);
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            var readers = std.ArrayList(EdgeSegmentIdIndexRunReader).empty;
            defer {
                for (readers.items) |*reader| reader.deinit(self.allocator, self.io);
                readers.deinit(self.allocator);
            }
            try readers.ensureTotalCapacityPrecise(self.allocator, run_paths.len);

            var queue = std.PriorityQueue(EdgeSegmentIdIndexRunHeapEntry, void, compareEdgeSegmentIdIndexRunHeapEntry).initContext({});
            defer queue.deinit(self.allocator);
            try queue.ensureTotalCapacityPrecise(self.allocator, run_paths.len);

            for (run_paths) |run_path| {
                var run_file = try std.Io.Dir.cwd().openFile(self.io, run_path, .{});
                errdefer run_file.close(self.io);
                const run_size = try regularFileSize(self, run_file);
                if (run_size == 0 or run_size % 8 != 0) return error.InvalidRecord;
                var map = openReadOnlyMemoryMap(self.io, run_file, run_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(self.io);
                var buffer: []u8 = &.{};
                errdefer self.allocator.free(buffer);
                if (map == null) {
                    buffer = try self.allocator.alloc(u8, try storageWriteBufferCapacity(run_size));
                }
                const reader_index = readers.items.len;
                readers.appendAssumeCapacity(.{
                    .file = run_file,
                    .map = map,
                    .base_offset = 0,
                    .next_index = 0,
                    .count = run_size / 8,
                    .buffer = buffer,
                    .file_offset = 0,
                });
                map = null;
                buffer = &.{};
                const first = (try readers.items[reader_index].next(self)) orelse return error.InvalidRecord;
                try queue.push(self.allocator, .{ .run_index = reader_index, .edge_id = first });
            }

            var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
            defer file.close(self.io);
            const expected_size = try edgeSegmentIdIndexFileSize(summary.count);
            var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();
            var placeholder_header: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            encodeEdgeSegmentIdIndexHeader(summary, 0, &placeholder_header);
            try writer.append(&placeholder_header);

            var written: u64 = 0;
            var digest: u64 = 0;
            var order_digest: u64 = 0;
            var run_builder = EdgeSegmentIdRunBuilder{};
            var previous: u64 = 0;
            var min_seen: u64 = std.math.maxInt(u64);
            var max_seen: u64 = 0;
            while (queue.pop()) |entry| {
                if (entry.edge_id == 0 or entry.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (written != 0 and entry.edge_id <= previous) return error.InvalidRecord;
                previous = entry.edge_id;
                min_seen = @min(min_seen, entry.edge_id);
                max_seen = @max(max_seen, entry.edge_id);
                digest ^= edgeSegmentIdDigest(entry.edge_id);
                run_builder.add(entry.edge_id);
                const order_index = std.math.cast(usize, written) orelse return error.RecordTooLarge;
                order_digest ^= edgeSegmentIdIndexOrderDigestAt(order_index, entry.edge_id);

                var id_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &id_bytes, entry.edge_id, .little);
                try writer.append(&id_bytes);
                written += 1;

                const reader = &readers.items[entry.run_index];
                if (try reader.next(self)) |next_id| {
                    try queue.push(self.allocator, .{ .run_index = entry.run_index, .edge_id = next_id });
                }
            }

            if (written != summary.count) return error.InvalidRecord;
            if (min_seen != summary.range.min or max_seen != summary.range.max) return error.InvalidRecord;
            if (digest != summary.digest) return error.InvalidRecord;
            const final_runs = run_builder.finish();
            if (try edgeSegmentIdSidecarSummaryFromCompleteRuns(summary, final_runs)) |sidecar_summary| {
                std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
                return sidecar_summary;
            }
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var final_header: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            encodeEdgeSegmentIdIndexHeader(summary, order_digest, &final_header);
            try file.writePositionalAll(self.io, &final_header, 0);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
            try renameReplace(self, tmp_path, path);
            return .{
                .edge_id_order_digest = order_digest,
                .edge_id_runs = final_runs,
            };
        }

        pub fn writeEdgeSegmentIdIndexFromRecords(
            self: Store,
            segment_dir_path: []const u8,
            records_by_id: []const EdgeIndexRecord,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
            edge_id_order_digest: u64,
        ) !EdgeSegmentIdSidecarSummary {
            if (records_by_id.len != summary.count) return error.InvalidRecord;
            const runs = edgeSegmentIdRunSummaryFromRecords(records_by_id);
            if (try edgeSegmentIdSidecarSummaryFromCompleteRuns(summary, runs)) |sidecar_summary| return sidecar_summary;

            const path = try edgeSegmentIdIndexPath(self, segment_dir_path);
            defer self.allocator.free(path);
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            {
                var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(self.io);
                var writer = try beginEdgeSegmentIdIndexFile(self, file, summary, edge_id_order_digest);
                for (records_by_id, 0..) |record, index| {
                    try writer.write(self, index, record.edge_id);
                }
                try writer.finish(self);
            }
            try renameReplace(self, tmp_path, path);
            return .{
                .edge_id_order_digest = edge_id_order_digest,
                .edge_id_runs = runs,
            };
        }

        pub fn writeEdgeSegmentIdIndexFromEdgeIndexReader(
            self: Store,
            segment_dir_path: []const u8,
            reader: *EdgeIndexRecordReader,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
        ) !EdgeSegmentIdSidecarSummary {
            if (reader.edge_count != summary.count) return error.InvalidRecord;
            if (try edgeSegmentIdSidecarSummaryFromCompleteRange(summary)) |sidecar_summary| return sidecar_summary;

            const path = try edgeSegmentIdIndexPath(self, segment_dir_path);
            defer self.allocator.free(path);
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
            defer file.close(self.io);
            const expected_size = try edgeSegmentIdIndexFileSize(summary.count);
            var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();

            var placeholder_header: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            encodeEdgeSegmentIdIndexHeader(summary, 0, &placeholder_header);
            try writer.append(&placeholder_header);

            var written: u64 = 0;
            var previous: u64 = 0;
            var min_seen: u64 = std.math.maxInt(u64);
            var max_seen: u64 = 0;
            var digest: u64 = 0;
            var order_digest: u64 = 0;
            var run_builder = EdgeSegmentIdRunBuilder{};
            while (written < reader.edge_count) : (written += 1) {
                const record = try reader.read(written);
                const edge_id = record.edge_id;
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (written != 0 and edge_id <= previous) return error.InvalidRecord;
                previous = edge_id;
                min_seen = @min(min_seen, edge_id);
                max_seen = @max(max_seen, edge_id);
                digest ^= edgeSegmentIdDigest(edge_id);
                run_builder.add(edge_id);
                const order_index = std.math.cast(usize, written) orelse return error.RecordTooLarge;
                order_digest ^= edgeSegmentIdIndexOrderDigestAt(order_index, edge_id);

                var id_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &id_bytes, edge_id, .little);
                try writer.append(&id_bytes);
            }

            if (written != summary.count) return error.InvalidRecord;
            if (min_seen != summary.range.min or max_seen != summary.range.max) return error.InvalidRecord;
            if (digest != summary.digest) return error.InvalidRecord;
            const final_runs = run_builder.finish();
            if (try edgeSegmentIdSidecarSummaryFromCompleteRuns(summary, final_runs)) |sidecar_summary| {
                std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
                return sidecar_summary;
            }
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var final_header: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            encodeEdgeSegmentIdIndexHeader(summary, order_digest, &final_header);
            try file.writePositionalAll(self.io, &final_header, 0);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
            try renameReplace(self, tmp_path, path);
            return .{
                .edge_id_order_digest = order_digest,
                .edge_id_runs = final_runs,
            };
        }

        pub fn compareEdgeSegmentIdIndexRunHeapEntry(_: void, lhs: EdgeSegmentIdIndexRunHeapEntry, rhs: EdgeSegmentIdIndexRunHeapEntry) std.math.Order {
            const id_order = std.math.order(lhs.edge_id, rhs.edge_id);
            if (id_order != .eq) return id_order;
            return std.math.order(lhs.run_index, rhs.run_index);
        }

        pub fn writeEdgeSegmentIdIndexFromManifestEntries(
            self: Store,
            segment_dir_path: []const u8,
            entries: []const OwnedEdgeSegmentManifestEntry,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
        ) !EdgeSegmentIdSidecarSummary {
            if (entries.len == 0) return error.InvalidRecord;
            const manifest_runs = try edgeSegmentManifestIdRunSummary(self.allocator, entries);
            if (try edgeSegmentIdSidecarSummaryFromCompleteRuns(summary, manifest_runs)) |sidecar_summary| return sidecar_summary;

            const path = try edgeSegmentIdIndexPath(self, segment_dir_path);
            defer self.allocator.free(path);
            const tmp_path = try tmpPathFor(self, path);
            defer self.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

            var readers = std.ArrayList(EdgeSegmentIdIndexRunReader).empty;
            defer {
                for (readers.items) |*reader| reader.deinit(self.allocator, self.io);
                readers.deinit(self.allocator);
            }
            try readers.ensureTotalCapacityPrecise(self.allocator, entries.len);

            var queue = std.PriorityQueue(EdgeSegmentIdIndexRunHeapEntry, void, compareEdgeSegmentIdIndexRunHeapEntry).initContext({});
            defer queue.deinit(self.allocator);
            try queue.ensureTotalCapacityPrecise(self.allocator, entries.len);

            for (entries) |entry| {
                if (entry.edge_id_order_digest == 0) {
                    try validateTrustedRunSummary(entry);
                    const reader_index = readers.items.len;
                    readers.appendAssumeCapacity(try EdgeSegmentIdIndexRunReader.initSynthetic(entry.edge_id_runs, entry.edge_count));
                    const first = (try readers.items[reader_index].next(self)) orelse return error.InvalidRecord;
                    try queue.push(self.allocator, .{
                        .run_index = reader_index,
                        .edge_id = first,
                    });
                    continue;
                }

                const entry_path = try edgeSegmentIdIndexPath(self, entry.path);
                defer self.allocator.free(entry_path);
                var entry_file = try std.Io.Dir.cwd().openFile(self.io, entry_path, .{});
                errdefer entry_file.close(self.io);
                const header = try validateEdgeSegmentIdIndexHeader(self, entry_file, entry);
                const file_size = try edgeSegmentIdIndexFileSize(header.edge_count);
                var map = openReadOnlyMemoryMap(self.io, entry_file, file_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(self.io);
                const payload_size = std.math.mul(u64, header.edge_count, 8) catch return error.RecordTooLarge;
                var buffer: []u8 = &.{};
                errdefer self.allocator.free(buffer);
                if (map == null) {
                    buffer = try self.allocator.alloc(u8, try storageWriteBufferCapacity(payload_size));
                }
                const reader_index = readers.items.len;
                readers.appendAssumeCapacity(.{
                    .file = entry_file,
                    .map = map,
                    .base_offset = EdgeSegmentIdIndex.header_len,
                    .next_index = 0,
                    .count = header.edge_count,
                    .buffer = buffer,
                    .file_offset = EdgeSegmentIdIndex.header_len,
                });
                map = null;
                buffer = &.{};
                const first = (try readers.items[reader_index].next(self)) orelse return error.InvalidRecord;
                try queue.push(self.allocator, .{
                    .run_index = reader_index,
                    .edge_id = first,
                });
            }

            var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
            defer file.close(self.io);
            const expected_size = try edgeSegmentIdIndexFileSize(summary.count);
            var writer = try StorageBufferedWriter.init(self.allocator, self.io, file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();
            var placeholder_header: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            encodeEdgeSegmentIdIndexHeader(summary, 0, &placeholder_header);
            try writer.append(&placeholder_header);

            var written: u64 = 0;
            var digest: u64 = 0;
            var order_digest: u64 = 0;
            var run_builder = EdgeSegmentIdRunBuilder{};
            var previous: u64 = 0;
            var min_seen: u64 = std.math.maxInt(u64);
            var max_seen: u64 = 0;
            while (queue.pop()) |entry| {
                if (entry.edge_id == 0 or entry.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (written != 0 and entry.edge_id <= previous) return error.InvalidRecord;
                previous = entry.edge_id;
                min_seen = @min(min_seen, entry.edge_id);
                max_seen = @max(max_seen, entry.edge_id);
                digest ^= edgeSegmentIdDigest(entry.edge_id);
                run_builder.add(entry.edge_id);
                const order_index = std.math.cast(usize, written) orelse return error.RecordTooLarge;
                order_digest ^= edgeSegmentIdIndexOrderDigestAt(order_index, entry.edge_id);

                var id_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &id_bytes, entry.edge_id, .little);
                try writer.append(&id_bytes);
                written += 1;

                const reader = &readers.items[entry.run_index];
                if (try reader.next(self)) |next_id| {
                    try queue.push(self.allocator, .{
                        .run_index = entry.run_index,
                        .edge_id = next_id,
                    });
                }
            }

            if (written != summary.count) return error.InvalidRecord;
            if (min_seen != summary.range.min or max_seen != summary.range.max) return error.InvalidRecord;
            if (digest != summary.digest) return error.InvalidRecord;
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var final_header: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            encodeEdgeSegmentIdIndexHeader(summary, order_digest, &final_header);
            try file.writePositionalAll(self.io, &final_header, 0);
            if (selfOptionsNeedSync(self)) try file.sync(self.io);
            try renameReplace(self, tmp_path, path);
            return .{
                .edge_id_order_digest = order_digest,
                .edge_id_runs = run_builder.finish(),
            };
        }

        pub fn beginEdgeSegmentIdIndexFile(
            self: Store,
            file: std.Io.File,
            summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
            edge_id_order_digest: u64,
        ) !EdgeSegmentIdIndexWriter {
            var header: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            encodeEdgeSegmentIdIndexHeader(summary, edge_id_order_digest, &header);
            try file.writePositionalAll(self.io, &header, 0);
            return .{
                .file = file,
                .summary = summary,
                .edge_id_order_digest = edge_id_order_digest,
            };
        }

        pub fn edgeSegmentIdIndexContains(self: Store, entry: OwnedEdgeSegmentManifestEntry, edge_id: u64) !?bool {
            if (entry.edge_id_order_digest == 0) return null;
            const path = try edgeSegmentIdIndexPath(self, entry.path);
            defer self.allocator.free(path);
            var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(self.io);
            const header = try validateEdgeSegmentIdIndexHeader(self, file, entry);
            return try edgeSegmentIdIndexContainsInFile(self, file, header.edge_count, edge_id);
        }

        pub fn edgeSegmentIdIndexIntersects(self: Store, entry: OwnedEdgeSegmentManifestEntry, ids_by_id: []const u64) !?bool {
            if (entry.edge_id_order_digest == 0) return null;
            const path = try edgeSegmentIdIndexPath(self, entry.path);
            defer self.allocator.free(path);
            var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(self.io);
            const header = try validateEdgeSegmentIdIndexHeader(self, file, entry);
            return try edgeSegmentIdIndexIntersectsSortedInFile(self, file, header, ids_by_id, entry.edge_id_range);
        }

        pub fn trustedSingletonEdgeSegmentId(entry: OwnedEdgeSegmentManifestEntry) !?u64 {
            if (entry.edge_count != 1) return null;
            if (entry.edge_id_range.min == 0 or entry.edge_id_range.max == std.math.maxInt(u64)) return error.InvalidRecord;
            if (entry.edge_id_range.min != entry.edge_id_range.max) return error.InvalidRecord;
            const edge_id = entry.edge_id_range.min;
            if (entry.edge_id_digest == 0 and edgeSegmentManifestCanDeriveEdgeIdDigest(entry)) {
                try validateTrustedRunSummary(entry);
            } else if (entry.edge_id_digest != edgeSegmentIdDigest(edge_id)) return error.InvalidRecord;
            if (entry.edge_id_order_digest != 0 and entry.edge_id_order_digest != edgeSegmentIdIndexOrderDigestAt(0, edge_id)) {
                return error.InvalidRecord;
            }
            return edge_id;
        }

        pub fn trustedRunSummaryMayIntersect(entry: OwnedEdgeSegmentManifestEntry, ids_by_id: []const u64) !?bool {
            if (entry.edge_id_runs.run_count == 0) return null;
            if (entry.edge_id_runs.run_count > 2) return error.InvalidRecord;
            try validateTrustedRunSummary(entry);
            if (sortedSetIntersectsRange(ids_by_id, entry.edge_id_runs.first_min, entry.edge_id_runs.first_max)) return true;
            if (entry.edge_id_runs.run_count == 2 and sortedSetIntersectsRange(ids_by_id, entry.edge_id_runs.second_min, entry.edge_id_runs.second_max)) return true;
            return false;
        }

        pub fn validateTrustedRunSummary(entry: OwnedEdgeSegmentManifestEntry) !void {
            if (entry.edge_id_runs.run_count == 0) return;
            if (!edgeSegmentManifestRunsCoverEntry(entry.edge_count, entry.edge_id_range, entry.edge_id_runs)) return error.InvalidRecord;
        }

        pub fn validateEdgeSegmentIdIndexHeader(self: Store, file: std.Io.File, entry: OwnedEdgeSegmentManifestEntry) !EdgeSegmentIdIndexHeader {
            const file_size = try regularFileSize(self, file);
            if (file_size != try edgeSegmentIdIndexFileSize(entry.edge_count)) return error.InvalidRecord;
            var header_bytes: [EdgeSegmentIdIndex.header_len]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &header_bytes, 0);
            if (n != header_bytes.len) return error.InvalidRecord;
            const header = try decodeEdgeSegmentIdIndexHeader(&header_bytes);
            if (header.edge_count != entry.edge_count) return error.InvalidRecord;
            if (header.edge_id_min != entry.edge_id_range.min) return error.InvalidRecord;
            if (header.edge_id_max != entry.edge_id_range.max) return error.InvalidRecord;
            if (header.edge_id_digest != entry.edge_id_digest) return error.InvalidRecord;
            if (header.edge_id_order_digest != entry.edge_id_order_digest) return error.InvalidRecord;
            return header;
        }

        pub fn edgeSegmentIdIndexContainsInFile(self: Store, file: std.Io.File, edge_count: u64, edge_id: u64) !bool {
            const lo = try edgeSegmentIdIndexLowerBoundInFile(self, file, edge_count, edge_id);
            if (lo >= edge_count) return false;
            return try readEdgeSegmentIdIndexRecordAt(self, file, lo) == edge_id;
        }

        pub fn edgeSegmentIdIndexIntersectsSortedInFile(
            self: Store,
            file: std.Io.File,
            header: EdgeSegmentIdIndexHeader,
            ids_by_id: []const u64,
            range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
        ) !bool {
            var id_index = lowerBoundU64(ids_by_id, range.min);
            if (id_index >= ids_by_id.len or ids_by_id[id_index] > range.max) return false;

            if (header.edge_count <= edge_segment_id_index_stack_scan_max) {
                return try edgeSegmentIdIndexIntersectsSmallSortedInFile(self, file, header, ids_by_id[id_index..], range);
            }

            var side_index = try edgeSegmentIdIndexLowerBoundInFile(self, file, header.edge_count, ids_by_id[id_index]);
            while (id_index < ids_by_id.len and ids_by_id[id_index] <= range.max and side_index < header.edge_count) {
                const current = try readEdgeSegmentIdIndexRecordAt(self, file, side_index);
                const candidate = ids_by_id[id_index];
                if (current == candidate) return true;
                if (current < candidate) {
                    side_index = try edgeSegmentIdIndexLowerBoundInFileFrom(self, file, header.edge_count, candidate, side_index + 1);
                    continue;
                }

                id_index += 1;
                while (id_index < ids_by_id.len and ids_by_id[id_index] <= range.max and ids_by_id[id_index] < current) {
                    id_index += 1;
                }
                if (id_index >= ids_by_id.len or ids_by_id[id_index] > range.max) return false;
                if (ids_by_id[id_index] == current) return true;
                side_index = try edgeSegmentIdIndexLowerBoundInFileFrom(self, file, header.edge_count, ids_by_id[id_index], side_index);
            }
            return false;
        }

        pub fn edgeSegmentIdIndexIntersectsSmallSortedInFile(
            self: Store,
            file: std.Io.File,
            header: EdgeSegmentIdIndexHeader,
            ids_by_id: []const u64,
            range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
        ) !bool {
            if (header.edge_count == 0 or header.edge_count > edge_segment_id_index_stack_scan_max) return error.InvalidRecord;
            const edge_count = std.math.cast(usize, header.edge_count) orelse return error.RecordTooLarge;
            const byte_len = edge_count * 8;
            var bytes: [edge_segment_id_index_stack_scan_max * 8]u8 = undefined;
            const n = try file.readPositionalAll(self.io, bytes[0..byte_len], EdgeSegmentIdIndex.header_len);
            if (n != byte_len) return error.InvalidRecord;

            var id_index = lowerBoundU64(ids_by_id, range.min);
            var previous: u64 = 0;
            var digest: u64 = 0;
            var order_digest: u64 = 0;
            var found = false;
            for (0..edge_count) |index| {
                const offset = index * 8;
                const current = std.mem.readInt(u64, bytes[offset..][0..8], .little);
                if (current == 0 or current == std.math.maxInt(u64)) return error.InvalidRecord;
                if (index == 0) {
                    if (current != header.edge_id_min) return error.InvalidRecord;
                } else if (current <= previous) {
                    return error.InvalidRecord;
                }
                previous = current;
                digest ^= edgeSegmentIdDigest(current);
                order_digest ^= edgeSegmentIdIndexOrderDigestAt(index, current);

                while (id_index < ids_by_id.len and ids_by_id[id_index] < current) {
                    id_index += 1;
                }
                if (id_index < ids_by_id.len and ids_by_id[id_index] <= range.max and ids_by_id[id_index] == current) {
                    found = true;
                }
            }
            if (previous != header.edge_id_max) return error.InvalidRecord;
            if (digest != header.edge_id_digest or order_digest != header.edge_id_order_digest) return error.InvalidRecord;
            return found;
        }

        pub fn edgeSegmentIdIndexLowerBoundInFile(self: Store, file: std.Io.File, edge_count: u64, edge_id: u64) !u64 {
            return try edgeSegmentIdIndexLowerBoundInFileFrom(self, file, edge_count, edge_id, 0);
        }

        pub fn edgeSegmentIdIndexLowerBoundInFileFrom(self: Store, file: std.Io.File, edge_count: u64, edge_id: u64, start: u64) !u64 {
            if (start > edge_count) return error.InvalidRecord;
            var lo: u64 = start;
            var hi: u64 = edge_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const current = try readEdgeSegmentIdIndexRecordAt(self, file, mid);
                if (current < edge_id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn readEdgeSegmentIdIndexRecordAt(self: Store, file: std.Io.File, index: u64) !u64 {
            const byte_index = std.math.mul(u64, index, 8) catch return error.RecordTooLarge;
            const offset = std.math.add(u64, EdgeSegmentIdIndex.header_len, byte_index) catch return error.RecordTooLarge;
            var bytes: [8]u8 = undefined;
            const n = try file.readPositionalAll(self.io, &bytes, offset);
            if (n != bytes.len) return error.InvalidRecord;
            return std.mem.readInt(u64, &bytes, .little);
        }

        const Fixture = struct {
            tmp: std.testing.TmpDir,
            store_path: []u8,
            index_path: []u8,
            store: Store,

            fn init() !@This() {
                var tmp = std.testing.tmpDir(.{});
                errdefer tmp.cleanup();
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
                const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
                errdefer std.testing.allocator.free(store_path);
                var store = try Store.init(std.testing.allocator, std.testing.io, store_path);
                errdefer store.deinit();
                const index_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "owner-edge-ids.idx" });
                return .{ .tmp = tmp, .store_path = store_path, .index_path = index_path, .store = store };
            }

            fn deinit(self: *@This()) void {
                self.store.deinit();
                std.testing.allocator.free(self.index_path);
                std.testing.allocator.free(self.store_path);
                self.tmp.cleanup();
            }
        };

        const Helpers = struct {
            fn digest(ids: []const u64) u64 {
                var value: u64 = 0;
                for (ids) |edge_id| value ^= Ops.edgeSegmentIdDigest_dep(edge_id);
                return value;
            }

            fn orderDigest(ids: []const u64) u64 {
                var value: u64 = 0;
                for (ids, 0..) |edge_id, index| value ^= Ops.edgeSegmentIdIndexOrderDigestAt_dep(index, edge_id);
                return value;
            }

            fn entryFor(fixture: *Fixture, ids: []const u64) OwnedEdgeSegmentManifestEntry {
                return .{
                    .edge_count = @intCast(ids.len),
                    .edge_id_range = .{ .min = ids[0], .max = ids[ids.len - 1] },
                    .edge_id_digest = digest(ids),
                    .edge_id_order_digest = orderDigest(ids),
                    .src_node_range = .{ .min = 1, .max = 1 },
                    .dst_node_range = .{ .min = 2, .max = 2 },
                    .path = fixture.store_path,
                };
            }

            fn writeIndex(fixture: *Fixture, ids: []const u64) !std.Io.File {
                var file = try std.Io.Dir.cwd().createFile(std.testing.io, fixture.index_path, .{ .read = true, .truncate = true });
                errdefer file.close(std.testing.io);
                const summary = segment_mod.ImmutableAdjacencySegment.EdgeIdSummary{
                    .count = @intCast(ids.len),
                    .range = .{ .min = ids[0], .max = ids[ids.len - 1] },
                    .digest = digest(ids),
                };
                var writer = try beginEdgeSegmentIdIndexFile(fixture.store, file, summary, orderDigest(ids));
                for (ids, 0..) |edge_id, index| try writer.write(fixture.store, index, edge_id);
                try writer.finish(fixture.store);
                return file;
            }
        };

        test "edge segment id-index owner writes validates and queries sorted sidecar" {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const ids = [_]u64{ 2, 4, 9 };
            var file = try Helpers.writeIndex(&fixture, &ids);
            defer file.close(std.testing.io);
            const entry = Helpers.entryFor(&fixture, &ids);

            const header = try validateEdgeSegmentIdIndexHeader(fixture.store, file, entry);
            try std.testing.expectEqual(@as(u64, ids.len), header.edge_count);
            try std.testing.expect(try edgeSegmentIdIndexContainsInFile(fixture.store, file, header.edge_count, 4));
            try std.testing.expect(!try edgeSegmentIdIndexContainsInFile(fixture.store, file, header.edge_count, 5));
            try std.testing.expect(try edgeSegmentIdIndexIntersectsSortedInFile(
                fixture.store,
                file,
                header,
                &.{ 1, 4, 8 },
                entry.edge_id_range,
            ));
        }

        test "edge segment id-index owner rejects corrupt sorted sidecar digest" {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const ids = [_]u64{ 2, 4, 9 };
            var file = try Helpers.writeIndex(&fixture, &ids);
            defer file.close(std.testing.io);
            const entry = Helpers.entryFor(&fixture, &ids);
            const header = try validateEdgeSegmentIdIndexHeader(fixture.store, file, entry);

            var corrupt: [8]u8 = undefined;
            std.mem.writeInt(u64, &corrupt, 8, .little);
            try file.writePositionalAll(std.testing.io, &corrupt, Ops.EdgeSegmentIdIndex_dep.header_len + 8);
            try std.testing.expectError(
                error.InvalidRecord,
                edgeSegmentIdIndexIntersectsSmallSortedInFile(fixture.store, file, header, &.{8}, entry.edge_id_range),
            );
        }

        test "edge segment id-index owner validates trusted one and two-run summaries" {
            var path_buf = [_]u8{'x'};
            const ids = [_]u64{ 4, 5, 8, 9 };
            var entry = OwnedEdgeSegmentManifestEntry{
                .edge_count = ids.len,
                .edge_id_range = .{ .min = 4, .max = 9 },
                .edge_id_digest = Helpers.digest(&ids),
                .edge_id_runs = .{
                    .run_count = 2,
                    .first_min = 4,
                    .first_max = 5,
                    .second_min = 8,
                    .second_max = 9,
                },
                .src_node_range = .{ .min = 1, .max = 1 },
                .dst_node_range = .{ .min = 2, .max = 2 },
                .path = &path_buf,
            };

            try std.testing.expect((try trustedRunSummaryMayIntersect(entry, &.{ 1, 5, 7 })).?);
            try std.testing.expect(!(try trustedRunSummaryMayIntersect(entry, &.{ 1, 6, 7 })).?);
            entry.edge_count += 1;
            try std.testing.expectError(error.InvalidRecord, validateTrustedRunSummary(entry));
        }
    };
}
