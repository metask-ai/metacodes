/// Metaknow deferred-sidecar validation, recovery and replay-store materialization.
pub fn MetaknowReplayInterchangeDataPlane(comptime Ops: type) type {
    return struct {
        const BenchMetaknowReplay = Ops.BenchMetaknowReplayValue;
        const BenchMetaknowReplayEdgeStats = Ops.BenchMetaknowReplayEdgeStatsValue;
        const BenchNodeLoadTimings = Ops.BenchNodeLoadTimingsValue;
        const BenchTextDensityStats = Ops.BenchTextDensityStatsValue;
        const CliStoreLock = Ops.CliStoreLockValue;
        const ImportPublicationResult = Ops.ImportPublicationResultValue;
        const ImportTransactionExpectation = Ops.ImportTransactionExpectationValue;
        const MetaknowReplayImportResult = Ops.MetaknowReplayImportResultValue;
        const QueryOutputWriter = Ops.QueryOutputWriterValue;
        const StoreContentIdentity = Ops.StoreContentIdentityValue;
        const agent = Ops.agentValue;
        const anyPathExists = Ops.anyPathExistsValue;
        const builtin = Ops.builtinValue;
        const canonicalProspectivePath = Ops.canonicalProspectivePathValue;
        const core = Ops.coreValue;
        const createOwnedDirectory = Ops.createOwnedDirectoryValue;
        const dag = Ops.dagValue;
        const fileExists = Ops.fileExistsValue;
        const finalizeContentDigest = Ops.finalizeContentDigestValue;
        const graph = Ops.graphValue;
        const hashLengthPrefixed = Ops.hashLengthPrefixedValue;
        const hashStoreFile = Ops.hashStoreFileValue;
        const importPublicationMatchesSource = Ops.importPublicationMatchesSourceValue;
        const importStagingPath = Ops.importStagingPathValue;
        const importTransactionMarkerPath = Ops.importTransactionMarkerPathValue;
        const import_publish_lock_suffix = Ops.import_publish_lock_suffixValue;
        const import_transaction_marker_format = Ops.import_transaction_marker_formatValue;
        const import_transaction_marker_legacy_format = Ops.import_transaction_marker_legacy_formatValue;
        const loadBenchMetaknowReplay = Ops.loadBenchMetaknowReplayValue;
        const metaknow_replay_workload = Ops.metaknow_replay_workloadValue;
        const pathsOverlap = Ops.pathsOverlapValue;
        const publishImportedStore = Ops.publishImportedStoreValue;
        const query = Ops.queryValue;
        const recoverCompletedImport = Ops.recoverCompletedImportValue;
        const recoverImportStaging = Ops.recoverImportStagingValue;
        const rewriteTransactionMarkerFormatForTest = Ops.rewriteTransactionMarkerFormatForTestValue;
        const run = Ops.runValue;
        const schema = Ops.schemaValue;
        const std = Ops.stdValue;
        const storage = Ops.storageValue;
        const storeContentIdentity = Ops.storeContentIdentityValue;
        const syncExportDirectoryTree = Ops.syncExportDirectoryTreeValue;
        const syncParentDirectory = Ops.syncParentDirectoryValue;
        const task = Ops.taskValue;
        const text_search = Ops.text_searchValue;
        const transactionMarkerHasFormatForTest = Ops.transactionMarkerHasFormatForTestValue;
        const writeImportTransactionMarker = Ops.writeImportTransactionMarkerValue;
        const writeStoreManifest = Ops.writeStoreManifestValue;

        const metaknow_deferred_based_on_file = query.metaknow_deferred_based_on_file;
        const metaknow_deferred_based_on_magic = query.metaknow_deferred_based_on_magic;
        pub const metaknow_deferred_based_on_header_len = query.metaknow_deferred_based_on_header_len;
        const metaknow_deferred_based_on_index_record_len = query.metaknow_deferred_based_on_index_record_len;
        const metaknow_deferred_based_on_target_record_len = query.metaknow_deferred_based_on_target_record_len;
        const metaknow_deferred_based_on_edge_id_base = query.metaknow_deferred_based_on_edge_id_base;

        const MetaknowDeferredBasedOnBuildStats = struct {
            sources: usize = 0,
            links: usize = 0,
            bytes: u64 = 0,
        };

        const MetaknowDeferredBasedOnPair = struct {
            src: u64,
            dst: u64,
        };

        pub const MetaknowDeferredBasedOnSidecarPairs = struct {
            present: bool = false,
            pairs: std.ArrayList(MetaknowDeferredBasedOnPair) = .empty,

            pub fn deinit(self: *MetaknowDeferredBasedOnSidecarPairs, allocator: std.mem.Allocator) void {
                self.pairs.deinit(allocator);
                self.* = .{};
            }
        };

        pub fn normalizeMetaknowDeferredBasedOnPairs(snapshot: *MetaknowDeferredBasedOnSidecarPairs) void {
            std.mem.sort(MetaknowDeferredBasedOnPair, snapshot.pairs.items, {}, struct {
                fn lessThan(_: void, a: MetaknowDeferredBasedOnPair, b: MetaknowDeferredBasedOnPair) bool {
                    if (a.src != b.src) return a.src < b.src;
                    return a.dst < b.dst;
                }
            }.lessThan);
            var write_index: usize = 0;
            var previous: ?MetaknowDeferredBasedOnPair = null;
            for (snapshot.pairs.items) |pair| {
                if (previous) |last| {
                    if (last.src == pair.src and last.dst == pair.dst) continue;
                }
                snapshot.pairs.items[write_index] = pair;
                write_index += 1;
                previous = pair;
            }
            snapshot.pairs.shrinkRetainingCapacity(write_index);
        }

        pub fn metaknowDeferredBasedOnPath(allocator: std.mem.Allocator, store: storage.Store) ![]u8 {
            return query.metaknowDeferredBasedOnPath(allocator, store);
        }

        pub fn metaknowDeferredBasedOnPathForDb(allocator: std.mem.Allocator, db_path: []const u8) ![]u8 {
            return std.fs.path.join(allocator, &.{ db_path, metaknow_deferred_based_on_file });
        }

        const MigrationSidecarRecordStream = struct {
            file: *std.Io.File,
            io: std.Io,
            record_len: usize,
            remaining: u64,
            file_offset: u64,
            buffer: []u8,
            cursor: usize = 0,
            len: usize = 0,

            fn next(self: *MigrationSidecarRecordStream) !?[]const u8 {
                if (self.remaining == 0) return null;
                if (self.cursor == self.len) {
                    const capacity_records = self.buffer.len / self.record_len;
                    if (capacity_records == 0) return error.InvalidRecord;
                    const take_records: usize = @intCast(@min(self.remaining, capacity_records));
                    const byte_len = std.math.mul(usize, take_records, self.record_len) catch return error.InvalidRecord;
                    const n = try self.file.readPositionalAll(self.io, self.buffer[0..byte_len], self.file_offset);
                    if (n != byte_len) return error.InvalidRecord;
                    self.file_offset = std.math.add(u64, self.file_offset, byte_len) catch return error.InvalidRecord;
                    self.cursor = 0;
                    self.len = byte_len;
                }
                const record = self.buffer[self.cursor..][0..self.record_len];
                self.cursor += self.record_len;
                self.remaining -= 1;
                return record;
            }
        };

        const MigrationDeferredPairDigest = struct {
            xor_a: u64 = 0,
            xor_b: u64 = 0,

            fn add(self: *MigrationDeferredPairDigest, src: u64, dst: u64) void {
                var bytes: [16]u8 = undefined;
                std.mem.writeInt(u64, bytes[0..8], src, .little);
                std.mem.writeInt(u64, bytes[8..16], dst, .little);
                self.xor_a ^= std.hash.Wyhash.hash(0x544B_4446, &bytes);
                self.xor_b ^= std.hash.Wyhash.hash(0x544B_4452, &bytes);
            }
        };

        fn validateMetaknowDeferredBasedOnDirection(
            file: *std.Io.File,
            io: std.Io,
            index_offset: u64,
            target_offset: u64,
            source_count: u64,
            link_count: u64,
            reverse: bool,
        ) !MigrationDeferredPairDigest {
            var index_buffer: [metaknow_deferred_based_on_index_record_len * 4096]u8 = undefined;
            var target_buffer: [metaknow_deferred_based_on_target_record_len * 8192]u8 = undefined;
            var indexes = MigrationSidecarRecordStream{
                .file = file,
                .io = io,
                .record_len = metaknow_deferred_based_on_index_record_len,
                .remaining = source_count,
                .file_offset = index_offset,
                .buffer = &index_buffer,
            };
            var targets = MigrationSidecarRecordStream{
                .file = file,
                .io = io,
                .record_len = metaknow_deferred_based_on_target_record_len,
                .remaining = link_count,
                .file_offset = target_offset,
                .buffer = &target_buffer,
            };
            var digest = MigrationDeferredPairDigest{};
            var previous_source: u64 = 0;
            var consumed_links: u64 = 0;
            var source_index: u64 = 0;
            while (source_index < source_count) : (source_index += 1) {
                const record = (try indexes.next()) orelse return error.InvalidRecord;
                const source: u64 = std.mem.readInt(u32, record[0..4], .little);
                const target_start: u64 = std.mem.readInt(u32, record[4..8], .little);
                const count: u64 = std.mem.readInt(u32, record[8..12], .little);
                if (source == 0 or (source_index != 0 and source <= previous_source)) return error.InvalidRecord;
                if (target_start != consumed_links or count == 0 or count > link_count - consumed_links) return error.InvalidRecord;
                var previous_target: u64 = 0;
                var target_index: u64 = 0;
                while (target_index < count) : (target_index += 1) {
                    const target_record = (try targets.next()) orelse return error.InvalidRecord;
                    const target: u64 = std.mem.readInt(u32, target_record[0..4], .little);
                    if (target == 0 or (target_index != 0 and target <= previous_target)) return error.InvalidRecord;
                    if (reverse) {
                        digest.add(target, source);
                    } else {
                        digest.add(source, target);
                    }
                    previous_target = target;
                }
                consumed_links = std.math.add(u64, consumed_links, count) catch return error.InvalidRecord;
                previous_source = source;
            }
            if (consumed_links != link_count or try indexes.next() != null or try targets.next() != null) return error.InvalidRecord;
            return digest;
        }

        fn validateMetaknowDeferredBasedOnSidecarForMigration(file: *std.Io.File, io: std.Io, file_size: u64) !void {
            var header: [metaknow_deferred_based_on_header_len]u8 = undefined;
            if (try file.readPositionalAll(io, &header, 0) != header.len) return error.InvalidRecord;
            if (!std.mem.eql(u8, header[0..8], &metaknow_deferred_based_on_magic) or
                !std.mem.allEqual(u8, header[72..80], 0)) return error.InvalidRecord;

            const forward_source_count = std.mem.readInt(u64, header[8..16], .little);
            const forward_link_count = std.mem.readInt(u64, header[16..24], .little);
            const forward_target_offset = std.mem.readInt(u64, header[24..32], .little);
            const edge_id_base = std.mem.readInt(u64, header[32..40], .little);
            const reverse_source_count = std.mem.readInt(u64, header[48..56], .little);
            const reverse_link_count = std.mem.readInt(u64, header[56..64], .little);
            const reverse_target_offset = std.mem.readInt(u64, header[64..72], .little);
            if (forward_link_count != reverse_link_count or
                forward_source_count > std.math.maxInt(u32) or
                reverse_source_count > std.math.maxInt(u32) or
                forward_link_count > std.math.maxInt(u32) or
                edge_id_base != metaknow_deferred_based_on_edge_id_base) return error.InvalidRecord;
            if ((forward_source_count == 0) != (forward_link_count == 0) or
                (reverse_source_count == 0) != (reverse_link_count == 0)) return error.InvalidRecord;

            const forward_index_bytes = std.math.mul(u64, forward_source_count, metaknow_deferred_based_on_index_record_len) catch return error.InvalidRecord;
            const forward_target_bytes = std.math.mul(u64, forward_link_count, metaknow_deferred_based_on_target_record_len) catch return error.InvalidRecord;
            const reverse_index_bytes = std.math.mul(u64, reverse_source_count, metaknow_deferred_based_on_index_record_len) catch return error.InvalidRecord;
            const reverse_target_bytes = std.math.mul(u64, reverse_link_count, metaknow_deferred_based_on_target_record_len) catch return error.InvalidRecord;
            const expected_forward_target_offset = std.math.add(u64, metaknow_deferred_based_on_header_len, forward_index_bytes) catch return error.InvalidRecord;
            const reverse_index_offset = std.math.add(u64, expected_forward_target_offset, forward_target_bytes) catch return error.InvalidRecord;
            const expected_reverse_target_offset = std.math.add(u64, reverse_index_offset, reverse_index_bytes) catch return error.InvalidRecord;
            const expected_size = std.math.add(u64, expected_reverse_target_offset, reverse_target_bytes) catch return error.InvalidRecord;
            if (forward_target_offset != expected_forward_target_offset or
                reverse_target_offset != expected_reverse_target_offset or
                file_size != expected_size) return error.InvalidRecord;

            const forward_digest = try validateMetaknowDeferredBasedOnDirection(
                file,
                io,
                metaknow_deferred_based_on_header_len,
                forward_target_offset,
                forward_source_count,
                forward_link_count,
                false,
            );
            const reverse_digest = try validateMetaknowDeferredBasedOnDirection(
                file,
                io,
                reverse_index_offset,
                reverse_target_offset,
                reverse_source_count,
                reverse_link_count,
                true,
            );
            if (forward_digest.xor_a != reverse_digest.xor_a or forward_digest.xor_b != reverse_digest.xor_b) return error.InvalidRecord;
        }

        /// Schema and store-v2 migrations preserve node ids, so the deferred
        /// `based_on` sidecar can be copied byte-for-byte.  Do not expand its complete
        /// pair set into memory merely to rewrite the same representation: large
        /// knowledge stores deliberately keep these edges deferred for density.
        pub fn copyMetaknowDeferredBasedOnSidecarForMigration(
            allocator: std.mem.Allocator,
            io: std.Io,
            source_db_path: []const u8,
            target_db_path: []const u8,
        ) !bool {
            const source_path = try metaknowDeferredBasedOnPathForDb(allocator, source_db_path);
            defer allocator.free(source_path);
            const source_stat = std.Io.Dir.cwd().statFile(io, source_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            if (source_stat.kind != .file or source_stat.size < metaknow_deferred_based_on_header_len) return error.InvalidRecord;

            const target_path = try metaknowDeferredBasedOnPathForDb(allocator, target_db_path);
            defer allocator.free(target_path);
            if (try anyPathExists(io, target_path)) return error.AlreadyExists;
            try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source_path, std.Io.Dir.cwd(), target_path, io, .{ .replace = false });
            errdefer std.Io.Dir.cwd().deleteFile(io, target_path) catch {};

            const copied_stat = try std.Io.Dir.cwd().statFile(io, target_path, .{ .follow_symlinks = false });
            if (copied_stat.kind != .file or copied_stat.size != source_stat.size) return error.InvalidRecord;
            var copied_file = try std.Io.Dir.cwd().openFile(io, target_path, .{ .allow_directory = false });
            defer copied_file.close(io);
            try validateMetaknowDeferredBasedOnSidecarForMigration(&copied_file, io, copied_stat.size);
            if (builtin.os.tag != .windows) {
                try copied_file.sync(io);
                try syncParentDirectory(io, target_path);
            }
            return true;
        }

        pub fn writeMetaknowDeferredBasedOnForwardPairsSidecar(
            allocator: std.mem.Allocator,
            store: storage.Store,
            forward_pairs: []const MetaknowDeferredBasedOnPair,
            node_count: usize,
        ) !MetaknowDeferredBasedOnBuildStats {
            if (forward_pairs.len == 0) return .{};
            var pairs = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
            defer pairs.deinit(allocator);
            try pairs.ensureTotalCapacity(allocator, forward_pairs.len);
            pairs.appendSliceAssumeCapacity(forward_pairs);

            std.mem.sort(MetaknowDeferredBasedOnPair, pairs.items, {}, struct {
                fn lessThan(_: void, a: MetaknowDeferredBasedOnPair, b: MetaknowDeferredBasedOnPair) bool {
                    if (a.src != b.src) return a.src < b.src;
                    return a.dst < b.dst;
                }
            }.lessThan);

            var deduped = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
            defer deduped.deinit(allocator);
            try deduped.ensureTotalCapacity(allocator, pairs.items.len);
            var previous: ?MetaknowDeferredBasedOnPair = null;
            for (pairs.items) |pair| {
                if (previous) |last| {
                    if (last.src == pair.src and last.dst == pair.dst) continue;
                }
                try deduped.append(allocator, pair);
                previous = pair;
            }

            var reverse_pairs = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
            defer reverse_pairs.deinit(allocator);
            try reverse_pairs.ensureTotalCapacity(allocator, deduped.items.len);
            for (deduped.items) |pair| {
                reverse_pairs.appendAssumeCapacity(.{ .src = pair.dst, .dst = pair.src });
            }
            std.mem.sort(MetaknowDeferredBasedOnPair, reverse_pairs.items, {}, struct {
                fn lessThan(_: void, a: MetaknowDeferredBasedOnPair, b: MetaknowDeferredBasedOnPair) bool {
                    if (a.src != b.src) return a.src < b.src;
                    return a.dst < b.dst;
                }
            }.lessThan);

            const forward_source_count = metaknowDeferredBasedOnGroupCount(deduped.items);
            const reverse_source_count = metaknowDeferredBasedOnGroupCount(reverse_pairs.items);
            try ensureMetaknowDeferredBasedOnU32Sized(deduped.items, forward_source_count);
            try ensureMetaknowDeferredBasedOnU32Sized(reverse_pairs.items, reverse_source_count);

            const forward_index_bytes = try std.math.mul(usize, forward_source_count, metaknow_deferred_based_on_index_record_len);
            const forward_target_bytes = try std.math.mul(usize, deduped.items.len, metaknow_deferred_based_on_target_record_len);
            const reverse_index_bytes = try std.math.mul(usize, reverse_source_count, metaknow_deferred_based_on_index_record_len);
            const reverse_target_bytes = try std.math.mul(usize, reverse_pairs.items.len, metaknow_deferred_based_on_target_record_len);
            const forward_target_offset = metaknow_deferred_based_on_header_len + forward_index_bytes;
            const reverse_index_offset = forward_target_offset + forward_target_bytes;
            const reverse_target_offset = reverse_index_offset + reverse_index_bytes;
            const total_bytes = try std.math.add(usize, reverse_target_offset, reverse_target_bytes);
            var bytes = try allocator.alloc(u8, total_bytes);
            defer allocator.free(bytes);
            @memset(bytes, 0);
            @memcpy(bytes[0..8], &metaknow_deferred_based_on_magic);
            std.mem.writeInt(u64, bytes[8..16], @intCast(forward_source_count), .little);
            std.mem.writeInt(u64, bytes[16..24], @intCast(deduped.items.len), .little);
            std.mem.writeInt(u64, bytes[24..32], @intCast(forward_target_offset), .little);
            std.mem.writeInt(u64, bytes[32..40], metaknow_deferred_based_on_edge_id_base, .little);
            std.mem.writeInt(u64, bytes[40..48], @intCast(node_count), .little);
            std.mem.writeInt(u64, bytes[48..56], @intCast(reverse_source_count), .little);
            std.mem.writeInt(u64, bytes[56..64], @intCast(reverse_pairs.items.len), .little);
            std.mem.writeInt(u64, bytes[64..72], @intCast(reverse_target_offset), .little);

            writeMetaknowDeferredBasedOnGroups(bytes, deduped.items, metaknow_deferred_based_on_header_len, forward_target_offset);
            writeMetaknowDeferredBasedOnGroups(bytes, reverse_pairs.items, reverse_index_offset, reverse_target_offset);

            const path = try metaknowDeferredBasedOnPath(allocator, store);
            defer allocator.free(path);
            var file = try std.Io.Dir.cwd().createFile(store.io, path, .{ .truncate = true });
            defer file.close(store.io);
            try file.writePositionalAll(store.io, bytes, 0);
            try file.setLength(store.io, @intCast(bytes.len));

            return .{
                .sources = forward_source_count,
                .links = deduped.items.len,
                .bytes = @intCast(bytes.len),
            };
        }

        pub fn readMetaknowDeferredBasedOnSidecarForwardPairs(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
        ) !MetaknowDeferredBasedOnSidecarPairs {
            const path = try metaknowDeferredBasedOnPathForDb(allocator, db_path);
            defer allocator.free(path);
            const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return .{},
                else => |e| return e,
            };
            if (stat.kind != .file or stat.size < metaknow_deferred_based_on_header_len) return error.InvalidRecord;

            var file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);

            var header: [metaknow_deferred_based_on_header_len]u8 = undefined;
            if (try file.readPositionalAll(io, &header, 0) != header.len) return error.InvalidRecord;
            if (!std.mem.eql(u8, header[0..8], &metaknow_deferred_based_on_magic)) return error.InvalidRecord;

            const forward_source_count = std.mem.readInt(u64, header[8..16], .little);
            const forward_link_count = std.mem.readInt(u64, header[16..24], .little);
            const forward_target_offset = std.mem.readInt(u64, header[24..32], .little);
            const reverse_source_count = std.mem.readInt(u64, header[48..56], .little);
            const reverse_link_count = std.mem.readInt(u64, header[56..64], .little);
            const reverse_target_offset = std.mem.readInt(u64, header[64..72], .little);

            const forward_index_bytes = try std.math.mul(u64, forward_source_count, metaknow_deferred_based_on_index_record_len);
            const forward_target_bytes = try std.math.mul(u64, forward_link_count, metaknow_deferred_based_on_target_record_len);
            const reverse_index_bytes = try std.math.mul(u64, reverse_source_count, metaknow_deferred_based_on_index_record_len);
            const reverse_target_bytes = try std.math.mul(u64, reverse_link_count, metaknow_deferred_based_on_target_record_len);
            const expected_forward_target_offset = try std.math.add(u64, metaknow_deferred_based_on_header_len, forward_index_bytes);
            if (forward_target_offset != expected_forward_target_offset) return error.InvalidRecord;
            const reverse_index_offset = try std.math.add(u64, forward_target_offset, forward_target_bytes);
            const expected_reverse_target_offset = try std.math.add(u64, reverse_index_offset, reverse_index_bytes);
            if (reverse_target_offset != expected_reverse_target_offset) return error.InvalidRecord;
            const expected_size = try std.math.add(u64, reverse_target_offset, reverse_target_bytes);
            if (stat.size != expected_size) return error.InvalidRecord;
            if (forward_link_count > std.math.maxInt(usize) or forward_index_bytes > std.math.maxInt(usize) or forward_target_bytes > std.math.maxInt(usize)) return error.RecordTooLarge;

            const index_len: usize = @intCast(forward_index_bytes);
            const target_len: usize = @intCast(forward_target_bytes);
            const index_bytes = try allocator.alloc(u8, index_len);
            defer allocator.free(index_bytes);
            const target_bytes = try allocator.alloc(u8, target_len);
            defer allocator.free(target_bytes);
            if (index_len != 0 and try file.readPositionalAll(io, index_bytes, metaknow_deferred_based_on_header_len) != index_len) return error.InvalidRecord;
            if (target_len != 0 and try file.readPositionalAll(io, target_bytes, forward_target_offset) != target_len) return error.InvalidRecord;

            var snapshot = MetaknowDeferredBasedOnSidecarPairs{ .present = true };
            errdefer snapshot.deinit(allocator);
            try snapshot.pairs.ensureTotalCapacity(allocator, @intCast(forward_link_count));
            var previous_src: u64 = 0;
            var previous_start: u64 = 0;
            for (0..@intCast(forward_source_count)) |index_pos| {
                const record_offset = index_pos * metaknow_deferred_based_on_index_record_len;
                const src: u64 = std.mem.readInt(u32, index_bytes[record_offset..][0..4], .little);
                const target_start: u64 = std.mem.readInt(u32, index_bytes[record_offset + 4 ..][0..4], .little);
                const count: u64 = std.mem.readInt(u32, index_bytes[record_offset + 8 ..][0..4], .little);
                if (index_pos != 0 and src <= previous_src) return error.InvalidRecord;
                if (index_pos != 0 and target_start < previous_start) return error.InvalidRecord;
                if (target_start > forward_link_count or count > forward_link_count - target_start) return error.InvalidRecord;
                previous_src = src;
                previous_start = target_start;
                for (0..@intCast(count)) |target_index| {
                    const target_record_offset = (@as(usize, @intCast(target_start)) + target_index) * metaknow_deferred_based_on_target_record_len;
                    const dst: u64 = std.mem.readInt(u32, target_bytes[target_record_offset..][0..4], .little);
                    try snapshot.pairs.append(allocator, .{ .src = src, .dst = dst });
                }
            }
            return snapshot;
        }

        pub fn pruneMetaknowDeferredBasedOnPairsForNode(snapshot: *MetaknowDeferredBasedOnSidecarPairs, node_id: core.NodeId) void {
            const deleted = node_id.toInt();
            var write_index: usize = 0;
            for (snapshot.pairs.items) |pair| {
                if (pair.src == deleted or pair.dst == deleted) continue;
                snapshot.pairs.items[write_index] = pair;
                write_index += 1;
            }
            snapshot.pairs.shrinkRetainingCapacity(write_index);
        }

        pub fn restoreMetaknowDeferredBasedOnSidecar(
            allocator: std.mem.Allocator,
            store: storage.Store,
            snapshot: *const MetaknowDeferredBasedOnSidecarPairs,
        ) !void {
            if (!snapshot.present) return;
            const path = try metaknowDeferredBasedOnPath(allocator, store);
            defer allocator.free(path);
            if (snapshot.pairs.items.len == 0) {
                std.Io.Dir.cwd().deleteFile(store.io, path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |e| return e,
                };
                return;
            }
            const meta = try store.readIndexMeta();
            _ = try writeMetaknowDeferredBasedOnForwardPairsSidecar(allocator, store, snapshot.pairs.items, @intCast(meta.nodes));
        }

        fn metaknowDeferredBasedOnGroupCount(pairs: []const MetaknowDeferredBasedOnPair) usize {
            var count: usize = 0;
            var last_src: u64 = 0;
            for (pairs, 0..) |pair, index| {
                if (index == 0 or pair.src != last_src) {
                    count += 1;
                    last_src = pair.src;
                }
            }
            return count;
        }

        fn writeMetaknowDeferredBasedOnGroups(
            bytes: []u8,
            pairs: []const MetaknowDeferredBasedOnPair,
            index_offset: usize,
            target_offset: usize,
        ) void {
            var index_cursor: usize = index_offset;
            var target_cursor: usize = target_offset;
            var pair_index: usize = 0;
            while (pair_index < pairs.len) {
                const src = pairs[pair_index].src;
                const start = pair_index;
                while (pair_index < pairs.len and pairs[pair_index].src == src) : (pair_index += 1) {
                    std.mem.writeInt(u32, bytes[target_cursor..][0..4], @intCast(pairs[pair_index].dst), .little);
                    target_cursor += metaknow_deferred_based_on_target_record_len;
                }
                std.mem.writeInt(u32, bytes[index_cursor..][0..4], @intCast(src), .little);
                std.mem.writeInt(u32, bytes[index_cursor + 4 ..][0..4], @intCast(start), .little);
                std.mem.writeInt(u32, bytes[index_cursor + 8 ..][0..4], @intCast(pair_index - start), .little);
                index_cursor += metaknow_deferred_based_on_index_record_len;
            }
        }

        fn ensureMetaknowDeferredBasedOnU32Sized(pairs: []const MetaknowDeferredBasedOnPair, source_count: usize) !void {
            if (pairs.len > std.math.maxInt(u32)) return error.RecordTooLarge;
            if (source_count > std.math.maxInt(u32)) return error.RecordTooLarge;
            for (pairs) |pair| {
                if (pair.src > std.math.maxInt(u32) or pair.dst > std.math.maxInt(u32)) return error.RecordTooLarge;
            }
        }

        fn metaknowReplayCorpusIdentity(
            allocator: std.mem.Allocator,
            io: std.Io,
            corpus_dir_path: []const u8,
        ) !StoreContentIdentity {
            const input_names = [_][]const u8{
                "nodes.jsonl",
                "edges.jsonl",
                "manifest.json",
                "deferred_based_on.jsonl",
            };
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var total_bytes: u64 = 0;
            for (input_names) |name| {
                const path = try std.fs.path.join(allocator, &.{ corpus_dir_path, name });
                defer allocator.free(path);
                const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => {
                        hasher.update("missing\x00");
                        hashLengthPrefixed(&hasher, name);
                        continue;
                    },
                    else => |e| return e,
                };
                if (stat.kind != .file) return error.InvalidRecord;
                total_bytes = std.math.add(u64, total_bytes, stat.size) catch return error.RecordTooLarge;
                try hashStoreFile(io, path, name, stat.size, &hasher);
            }
            return .{ .bytes = total_bytes, .digest = finalizeContentDigest(&hasher) };
        }

        fn writeBenchMetaknowDeferredBasedOnSidecar(
            allocator: std.mem.Allocator,
            store: storage.Store,
            replay: *const BenchMetaknowReplay,
            node_count: usize,
        ) !MetaknowDeferredBasedOnBuildStats {
            if (replay.deferred_based_on.len == 0) return .{};
            var id_map = try metaknow_replay_workload.buildNodeIdMap(allocator, replay);
            defer id_map.deinit();

            var pairs = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
            defer pairs.deinit(allocator);
            for (replay.deferred_based_on) |row| {
                const fragment_id = id_map.get(row.fragment_original_id) orelse continue;
                for (row.dst_original_ids) |dst_original_id| {
                    const source_id = id_map.get(dst_original_id) orelse continue;
                    try pairs.append(allocator, .{ .src = source_id, .dst = fragment_id });
                }
            }
            return try writeMetaknowDeferredBasedOnForwardPairsSidecar(allocator, store, pairs.items, node_count);
        }

        const MetaknowReplayTaskStatusStream = struct {
            replay: *const BenchMetaknowReplay,
            next_node_index: usize = 0,

            fn next(raw_context: *anyopaque) anyerror!?storage.SortedPropertyPayloadEntry {
                const self: *MetaknowReplayTaskStatusStream = @ptrCast(@alignCast(raw_context));
                while (self.next_node_index < self.replay.nodes.len) {
                    const node_index = self.next_node_index;
                    self.next_node_index += 1;
                    if (self.replay.nodes[node_index].kind != .task) continue;
                    return .{
                        .owner = .{ .node = .fromInt(@intCast(node_index + 1)) },
                        .key_hash = storage.propertyKeyHashForLookup(task.status_property),
                        .value = .{ .string = @tagName(task.Status.open) },
                    };
                }
                return null;
            }
        };

        /// A replay import creates schema-v3 tasks, so every imported task needs the
        /// canonical durable `status=open` marker.  Feed the already-sorted node ids
        /// directly into the empty property base: repeated point writes would rebuild
        /// the complete COW payload once per task and turn a dense import into O(N²).
        fn materializeMetaknowReplayTaskStatuses(store: storage.Store, replay: *const BenchMetaknowReplay) !void {
            var task_count: u64 = 0;
            for (replay.nodes) |node| {
                if (node.kind == .task) task_count = std.math.add(u64, task_count, 1) catch return error.RecordTooLarge;
            }
            var stream = MetaknowReplayTaskStatusStream{ .replay = replay };
            try store.replaceEmptyPropertyPayloadFromSortedStream(task_count, &stream, MetaknowReplayTaskStatusStream.next);
        }

        pub fn importMetaknowReplayCorpus(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            corpus_dir_path: []const u8,
            chunk_size: usize,
            warm_text: bool,
        ) !MetaknowReplayImportResult {
            if (try pathsOverlap(allocator, io, db_path, corpus_dir_path)) return error.InvalidFileName;
            const corpus_identity_before = try metaknowReplayCorpusIdentity(allocator, io, corpus_dir_path);
            const replay = try metaknow_replay_workload.load(allocator, io, corpus_dir_path);
            defer replay.deinit(allocator);
            const corpus_identity = try metaknowReplayCorpusIdentity(allocator, io, corpus_dir_path);
            if (corpus_identity.bytes != corpus_identity_before.bytes or
                !std.meta.eql(corpus_identity.digest, corpus_identity_before.digest))
            {
                return error.ImportSourceChanged;
            }
            const canonical_source_path = try canonicalProspectivePath(allocator, io, corpus_dir_path);
            defer allocator.free(canonical_source_path);
            const planned_edges = try metaknow_replay_workload.planEdges(allocator, &replay);
            const expected_publication_result = ImportPublicationResult{
                .nodes_loaded = @intCast(replay.nodes.len),
                .nodes_imported = @intCast(replay.nodes.len),
                .edges_loaded = @intCast(replay.edges.len),
                .edges_imported = @intCast(planned_edges.edges_used),
                .edges_skipped_missing_endpoint = @intCast(planned_edges.edges_skipped_missing_endpoint),
                .source_bytes = corpus_identity.bytes,
                .text_warmed = warm_text,
            };
            const import_expectation = ImportTransactionExpectation{
                .format = "metaknow-replay",
                .canonical_source_path = canonical_source_path,
                .source_digest = corpus_identity.digest,
                .warm_text = warm_text,
                .chunk_size = @intCast(chunk_size),
            };
            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, db_path, import_publish_lock_suffix);
            defer publish_lock.deinit();
            const staging_path = try importStagingPath(allocator, db_path);
            defer allocator.free(staging_path);
            try recoverImportStaging(allocator, io, staging_path, import_expectation, expected_publication_result);
            if (try recoverCompletedImport(allocator, io, db_path, import_expectation, expected_publication_result)) |recovered| {
                return .{
                    .nodes_loaded = std.math.cast(usize, recovered.nodes_loaded) orelse return error.InvalidRecord,
                    .nodes_imported = std.math.cast(usize, recovered.nodes_imported) orelse return error.InvalidRecord,
                    .edges_loaded = std.math.cast(usize, recovered.edges_loaded) orelse return error.InvalidRecord,
                    .edges_imported = std.math.cast(usize, recovered.edges_imported) orelse return error.InvalidRecord,
                    .edges_skipped_missing_endpoint = std.math.cast(usize, recovered.edges_skipped_missing_endpoint) orelse return error.InvalidRecord,
                    .corpus_bytes = recovered.source_bytes,
                    .text_warmed = recovered.text_warmed,
                    .marker_cleanup_pending = recovered.marker_cleanup_pending,
                };
            }
            if (try anyPathExists(io, db_path)) return error.AlreadyExists;
            try createOwnedDirectory(io, staging_path);
            var staging_owned = true;
            defer if (staging_owned) std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeImportTransactionMarker(allocator, io, staging_path, import_expectation, null);
            try syncExportDirectoryTree(allocator, io, staging_path);

            var store = try storage.Store.initWithOptions(allocator, io, staging_path, .{
                .primary_text_write_mode = .bulk_ingest,
            });
            var store_open = true;
            defer if (store_open) store.deinit();
            try store.createEmpty();

            var text_density = BenchTextDensityStats{};
            var node_timings = BenchNodeLoadTimings{};
            try metaknow_replay_workload.appendNodesChunked(allocator, store, &replay, replay.nodes.len, chunk_size, false, &text_density, &node_timings);
            try store.finalizePrimaryTextStorage();
            try materializeMetaknowReplayTaskStatuses(store, &replay);
            const edge_stats = try metaknow_replay_workload.appendEdgesChunked(allocator, store, &replay, replay.nodes.len, replay.edges.len, chunk_size, false);
            const deferred_stats = try writeBenchMetaknowDeferredBasedOnSidecar(allocator, store, &replay, replay.nodes.len);
            var import_edge_stats = edge_stats;
            import_edge_stats.deferred_based_on_binary_sources = deferred_stats.sources;
            import_edge_stats.deferred_based_on_binary_links = deferred_stats.links;
            import_edge_stats.deferred_based_on_binary_bytes = deferred_stats.bytes;
            if (warm_text) {
                _ = try text_search.rebuildPersistentTextCatalog(allocator, store);
            }
            try writeStoreManifest(allocator, io, staging_path, .{
                .profiles = "",
                .migration_name = "import-metaknow-replay",
            });
            var result = MetaknowReplayImportResult{
                .nodes_loaded = replay.nodes.len,
                .nodes_imported = replay.nodes.len,
                .edges_loaded = replay.edges.len,
                .edges_imported = import_edge_stats.edges_used,
                .edges_skipped_missing_endpoint = import_edge_stats.edges_skipped_missing_endpoint,
                .corpus_bytes = corpus_identity.bytes,
                .text_warmed = warm_text,
            };
            store.deinit();
            store_open = false;
            var publication_result = ImportPublicationResult{
                .nodes_loaded = @intCast(result.nodes_loaded),
                .nodes_imported = @intCast(result.nodes_imported),
                .edges_loaded = @intCast(result.edges_loaded),
                .edges_imported = @intCast(result.edges_imported),
                .edges_skipped_missing_endpoint = @intCast(result.edges_skipped_missing_endpoint),
                .source_bytes = result.corpus_bytes,
                .text_warmed = result.text_warmed,
            };
            if (!importPublicationMatchesSource(publication_result, expected_publication_result)) return error.InvalidRecord;
            try publishImportedStore(allocator, io, staging_path, db_path, import_expectation, &publication_result);
            staging_owned = false;
            result.marker_cleanup_pending = publication_result.marker_cleanup_pending;
            return result;
        }

        test "metaknow replay fixture parsing maps ids kinds relations and preserves text" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "nodes.jsonl",
                .data =
                \\{"id":"node-c","kind":"note","title":"Third note","summary":"summary C","fragment":"raw quoted text and 中文 fragment","properties":"priority=high"}
                \\{"id":"node-a","kind":"task","title":"First task","description":"description A","text":"agent observation one"}
                \\{"id":"node-b","kind":"fragment","name":"Second fragment","summary":"summary B","text":"agent observation two"}
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "edges.jsonl",
                .data =
                \\{"src":"node-c","dst":"node-b","rel":"contains"}
                \\{"src":"node-c","dst":"node-a","rel":"supports"}
                \\{"src":"node-a","dst":"node-b","relation":"depends"}
                \\{"src":"node-missing","dst":"node-b","rel":"blocks"}
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "manifest.json",
                .data =
                \\{"based_on_materialize_threshold":32,"based_on_materialized_edges":15381,"based_on_deferred_edges":9777,"based_on_deferred_fragment_count":222,"based_on_document_container_skipped_edges":158,"deferred_based_on_rows":1,"deferred_based_on_bytes":123}
                ,
                .flags = .{ .truncate = true },
            });
            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "deferred_based_on.jsonl",
                .data =
                \\{"fragment_id":"node-b","dst_ids":["node-a"]}
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir_path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const dir_path = path_buf[0..dir_path_len];
            const replay = try loadBenchMetaknowReplay(std.testing.allocator, std.testing.io, dir_path);
            defer replay.deinit(std.testing.allocator);

            try std.testing.expectEqual(@as(usize, 3), replay.nodes.len);
            try std.testing.expectEqualStrings("node-c", replay.nodes[0].original_id);
            try std.testing.expectEqualStrings("node-a", replay.nodes[1].original_id);
            try std.testing.expectEqual(core.NodeKind.observation, replay.nodes[0].kind);
            try std.testing.expectEqual(core.NodeKind.task, replay.nodes[1].kind);
            try std.testing.expectEqual(core.NodeKind.document_section, replay.nodes[2].kind);
            try std.testing.expect(std.mem.indexOf(u8, replay.nodes[0].text, "raw quoted text and 中文 fragment") != null);
            try std.testing.expect(std.mem.indexOf(u8, replay.nodes[0].text, "properties=\"priority=high\"") != null);

            var id_map = try metaknow_replay_workload.buildNodeIdMap(std.testing.allocator, &replay);
            defer id_map.deinit();
            try std.testing.expectEqual(@as(u64, 1), id_map.get("node-c").?);
            try std.testing.expectEqual(@as(u64, 2), id_map.get("node-a").?);
            try std.testing.expectEqual(@as(u64, 3), id_map.get("node-b").?);
            try std.testing.expectEqual(@as(usize, 4), replay.edges.len);
            try std.testing.expectEqual(core.RelKind.contains, replay.edges[0].rel);
            try std.testing.expectEqual(core.RelKind.evidences, replay.edges[1].rel);
            try std.testing.expectEqual(core.RelKind.depends_on, replay.edges[2].rel);
            try std.testing.expectEqual(core.RelKind.blocks, replay.edges[3].rel);
            try std.testing.expectEqual(@as(usize, 32), replay.manifest.based_on_materialize_threshold);
            try std.testing.expectEqual(@as(usize, 15381), replay.manifest.based_on_materialized_edges);
            try std.testing.expectEqual(@as(usize, 9777), replay.manifest.based_on_deferred_edges);
            try std.testing.expectEqual(@as(usize, 222), replay.manifest.based_on_deferred_fragment_count);
            try std.testing.expectEqual(@as(usize, 158), replay.manifest.based_on_document_container_skipped_edges);
            try std.testing.expectEqual(@as(usize, 1), replay.manifest.deferred_based_on_rows);
            try std.testing.expectEqual(@as(usize, 123), replay.manifest.deferred_based_on_bytes);
            try std.testing.expectEqual(@as(usize, 1), replay.deferred_based_on.len);
            try std.testing.expectEqualStrings("node-b", replay.deferred_based_on[0].fragment_original_id);
            try std.testing.expectEqualStrings("node-a", replay.deferred_based_on[0].dst_original_ids[0]);
        }

        test "metaknow replay manifest is required" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "nodes.jsonl",
                .data =
                \\{"id":"node-a","kind":"concept","title":"A"}
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "edges.jsonl",
                .data =
                \\{"src":"node-a","dst":"node-a","rel":"related_to"}
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir_path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const dir_path = path_buf[0..dir_path_len];
            try std.testing.expectError(error.FileNotFound, loadBenchMetaknowReplay(std.testing.allocator, std.testing.io, dir_path));
        }

        test "metaknow replay loader accepts native jsonl skill export shape" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "nodes.jsonl",
                .data =
                \\{"id":1,"kind":"task","text":"kind=\"task\" title=\"Native task\" summary=\"skill store export text\""}
                \\{"id":2,"kind":"evidence","text":"kind=\"evidence\" title=\"Native evidence\" summary=\"exported from user skill store\""}
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "edges.jsonl",
                .data =
                \\{"id":7,"src":1,"rel":"based_on","dst":2}
                \\{"id":8,"src":2,"rel":"references","dst":1}
                \\
                ,
                .flags = .{ .truncate = true },
            });
            try tmp.dir.writeFile(std.testing.io, .{
                .sub_path = "deferred_based_on.jsonl",
                .data =
                \\{"src":1,"dst":2}
                \\{"src":1,"dst":2}
                \\
                ,
                .flags = .{ .truncate = true },
            });

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir_path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const dir_path = path_buf[0..dir_path_len];
            const replay = try loadBenchMetaknowReplay(std.testing.allocator, std.testing.io, dir_path);
            defer replay.deinit(std.testing.allocator);

            try std.testing.expectEqual(@as(usize, 2), replay.nodes.len);
            try std.testing.expectEqualStrings("1", replay.nodes[0].original_id);
            try std.testing.expectEqualStrings("2", replay.nodes[1].original_id);
            try std.testing.expectEqual(core.NodeKind.task, replay.nodes[0].kind);
            try std.testing.expectEqual(core.NodeKind.evidence, replay.nodes[1].kind);
            try std.testing.expect(std.mem.indexOf(u8, replay.nodes[0].text, "Native task") != null);
            try std.testing.expectEqual(@as(usize, 2), replay.edges.len);
            try std.testing.expectEqualStrings("1", replay.edges[0].src_original_id);
            try std.testing.expectEqualStrings("2", replay.edges[0].dst_original_id);
            try std.testing.expectEqual(core.RelKind.based_on, replay.edges[0].rel);
            try std.testing.expectEqual(core.RelKind.references, replay.edges[1].rel);
            try std.testing.expectEqual(@as(usize, 2), replay.deferred_based_on.len);
            try std.testing.expectEqual(@as(usize, 2), replay.manifest.deferred_based_on_rows);
            try std.testing.expect(replay.manifest.deferred_based_on_bytes > 0);
        }

        test "metaknow replay edge stats count contains separately from other" {
            var stats = BenchMetaknowReplayEdgeStats{};
            stats.recordRelation(.contains);
            stats.recordRelation(.related_to);
            stats.recordRelation(.based_on);
            stats.recordRelation(.references);
            stats.recordRelation(.precedes);
            stats.recordRelation(.defines);

            try std.testing.expectEqual(@as(usize, 1), stats.relation_contains);
            try std.testing.expectEqual(@as(usize, 1), stats.relation_related_to);
            try std.testing.expectEqual(@as(usize, 1), stats.relation_based_on);
            try std.testing.expectEqual(@as(usize, 1), stats.relation_references);
            try std.testing.expectEqual(@as(usize, 1), stats.relation_precedes);
            try std.testing.expectEqual(@as(usize, 1), stats.relation_other);
        }

        fn writeMetaknowReplayImportFixture(allocator: std.mem.Allocator, io: std.Io, corpus_path: []const u8) !void {
            try createOwnedDirectory(io, corpus_path);
            const files = [_]struct {
                name: []const u8,
                data: []const u8,
            }{
                .{
                    .name = "nodes.jsonl",
                    .data =
                    \\{"id":"node-a","kind":"task","title":"Replay task A","summary":"agent observation alpha durable memory"}
                    \\{"id":"node-b","kind":"file","title":"src/replay.zig","fragment":"BM25 import command fixture keeps original text"}
                    \\{"id":"node-c","kind":"concept","title":"Replay governance","description":"missing endpoint edges are skipped, not fabricated"}
                    \\
                    ,
                },
                .{
                    .name = "edges.jsonl",
                    .data =
                    \\{"src":"node-a","dst":"node-b","rel":"supports"}
                    \\{"src":"node-b","dst":"node-c","relation":"depends"}
                    \\{"src":"node-missing","dst":"node-c","rel":"blocks"}
                    \\
                    ,
                },
                .{
                    .name = "manifest.json",
                    .data =
                    \\{"based_on_materialize_threshold":32,"based_on_materialized_edges":1,"based_on_deferred_edges":1,"based_on_deferred_fragment_count":1,"based_on_document_container_skipped_edges":0,"deferred_based_on_rows":1,"deferred_based_on_bytes":64}
                    ,
                },
                .{
                    .name = "deferred_based_on.jsonl",
                    .data =
                    \\{"fragment_id":"node-b","dst_ids":["node-a"]}
                    \\
                    ,
                },
            };
            for (files) |file| {
                const path = try std.fs.path.join(allocator, &.{ corpus_path, file.name });
                defer allocator.free(path);
                try std.Io.Dir.cwd().writeFile(io, .{
                    .sub_path = path,
                    .data = file.data,
                    .flags = .{ .truncate = true },
                });
            }
        }

        test "metaknow replay import command creates searchable store" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const corpus_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "corpus" });
            defer std.testing.allocator.free(corpus_path);
            try writeMetaknowReplayImportFixture(std.testing.allocator, std.testing.io, corpus_path);

            const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
            defer std.testing.allocator.free(db_path);

            var import_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer import_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "import-metaknow-replay", db_path, corpus_path, "--chunk", "2", "--warm-text" }, &import_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_loaded=3") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "nodes_imported=3") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_loaded=3") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_imported=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "edges_skipped_missing_endpoint=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "text_warmed=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "corpus_bytes=") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "marker_cleanup_pending=0") != null);
            try std.testing.expect(std.mem.indexOf(u8, import_out.buffer.items, "elapsed_ns=") != null);

            const external_id_index_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "external_ids.tsv" });
            defer std.testing.allocator.free(external_id_index_path);
            try std.testing.expect(!try fileExists(std.testing.io, external_id_index_path));
            const external_id_by_id_index_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "external_ids_by_id.idx" });
            defer std.testing.allocator.free(external_id_by_id_index_path);
            try std.testing.expect(!try fileExists(std.testing.io, external_id_by_id_index_path));
            const text_terms_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "text_terms.idx" });
            defer std.testing.allocator.free(text_terms_path);
            try std.testing.expect(try fileExists(std.testing.io, text_terms_path));
            const text_docs_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "text_docs.idx" });
            defer std.testing.allocator.free(text_docs_path);
            try std.testing.expect(try fileExists(std.testing.io, text_docs_path));
            const text_postings_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "text_postings.dat" });
            defer std.testing.allocator.free(text_postings_path);
            try std.testing.expect(try fileExists(std.testing.io, text_postings_path));
            const deferred_based_on_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, metaknow_deferred_based_on_file });
            defer std.testing.allocator.free(deferred_based_on_path);
            try std.testing.expect(try fileExists(std.testing.io, deferred_based_on_path));

            var stats_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer stats_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "stats", db_path }, &stats_out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("nodes=3 edges=2\n", stats_out.buffer.items);
            {
                var imported_store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
                defer imported_store.deinit();
                const raw_status = (try imported_store.getNodeStringProperty(std.testing.allocator, .fromInt(1), task.status_property)).?;
                defer std.testing.allocator.free(raw_status);
                try std.testing.expectEqualStrings("open", raw_status);
            }

            var store_info_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer store_info_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "store-info", db_path }, &store_info_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, store_info_out.buffer.items, "nodes=3\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_out.buffer.items, "edges=2\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_out.buffer.items, "text_warm=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_out.buffer.items, "external_id_index") == null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_out.buffer.items, "text_postings_exists=1\n") != null);

            var governance_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer governance_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "governance", db_path, "--profile", "agent-dag" }, &governance_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "nodes=3\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "edges=2\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "isolated_nodes=0\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count task=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count file=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "node_kind_count concept=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "traversable_relation_count depends_on=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "traversable_relation_count evidences=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "traversable_relation_count based_on=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, governance_out.buffer.items, "schema_missing_required_node_properties=0\n") != null);

            var search_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer search_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "search", db_path, "agent", "observation", "--limit", "2" }, &search_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, search_out.buffer.items, "Replay task A") != null);

            var get_internal_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer get_internal_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "get", db_path, "2" }, &get_internal_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, get_internal_out.buffer.items, "2\tfile\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, get_internal_out.buffer.items, "src/replay.zig") != null);

            var get_node_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer get_node_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "node", db_path, "2" }, &get_node_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, get_node_out.buffer.items, "2\tfile\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, get_node_out.buffer.items, "src/replay.zig") != null);

            var get_external_default_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer get_external_default_out.buffer.deinit(std.testing.allocator);
            try std.testing.expectError(
                error.InvalidNodeId,
                run(&.{ "tinykg", "get", db_path, "node-b" }, &get_external_default_out, std.testing.allocator, std.testing.io),
            );

            var tinyql_text_budget_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer tinyql_text_budget_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "query", db_path, "MATCH TEXT \"agent observation\" AS n RETURN n LIMIT 2", "--max-postings", "10000000", "--timeout-ms", "60000" }, &tinyql_text_budget_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, tinyql_text_budget_out.buffer.items, "Replay task A") != null);

            var add_warm_node_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer add_warm_node_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "add-node", db_path, "verification", "Replay newly added warm searchable sentinel" }, &add_warm_node_out, std.testing.allocator, std.testing.io);
            try std.testing.expectEqualStrings("node 4\n", add_warm_node_out.buffer.items);

            var store_info_after_add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer store_info_after_add_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "store-info", db_path }, &store_info_after_add_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, store_info_after_add_out.buffer.items, "text_warm=0\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_after_add_out.buffer.items, "text_files_present=1\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_after_add_out.buffer.items, "text_stale=1\n") != null);

            var search_after_add_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer search_after_add_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "search", db_path, "warm searchable sentinel", "--limit", "2" }, &search_after_add_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, search_after_add_out.buffer.items, "Replay newly added warm searchable sentinel") != null);

            var neighbors_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer neighbors_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "neighbors", db_path, "1", "evidences" }, &neighbors_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, neighbors_out.buffer.items, "evidences\t2\t") != null);

            var incoming_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer incoming_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "incoming", db_path, "2", "evidences" }, &incoming_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, incoming_out.buffer.items, "evidences\t1\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, incoming_out.buffer.items, "Replay task A") != null);

            var deferred_neighbors_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer deferred_neighbors_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "neighbors", db_path, "1", "based_on" }, &deferred_neighbors_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, deferred_neighbors_out.buffer.items, "based_on\t2\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, deferred_neighbors_out.buffer.items, "src/replay.zig") != null);

            var deferred_incoming_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer deferred_incoming_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "incoming", db_path, "2", "based_on" }, &deferred_incoming_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, deferred_incoming_out.buffer.items, "based_on\t1\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, deferred_incoming_out.buffer.items, "Replay task A") != null);

            var tinyql_deferred_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer tinyql_deferred_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "query", db_path, "MATCH (n:task)-[:based_on]->(e:file) RETURN e.text LIMIT 5" }, &tinyql_deferred_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, tinyql_deferred_out.buffer.items, "src/replay.zig") != null);

            var tinyql_deferred_incoming_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer tinyql_deferred_incoming_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "query", db_path, "MATCH (e:file)<-[:based_on]-(n:task) RETURN n.text LIMIT 5" }, &tinyql_deferred_incoming_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, tinyql_deferred_incoming_out.buffer.items, "Replay task A") != null);

            var update_preserve_sidecar_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer update_preserve_sidecar_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "update-node", db_path, "1", "task", "Replay task A revised agent memory" }, &update_preserve_sidecar_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, update_preserve_sidecar_out.buffer.items, "updated node=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, update_preserve_sidecar_out.buffer.items, "text_rewarmed=0 text_index_current=0") != null);

            var store_info_after_update_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer store_info_after_update_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "store-info", db_path }, &store_info_after_update_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, store_info_after_update_out.buffer.items, "text_warm=0\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_after_update_out.buffer.items, "text_stale=1\n") != null);

            var search_after_update_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer search_after_update_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "search", db_path, "revised agent memory", "--limit", "2" }, &search_after_update_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, search_after_update_out.buffer.items, "Replay task A revised") != null);

            var deferred_after_update_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer deferred_after_update_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "neighbors", db_path, "1", "based_on" }, &deferred_after_update_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, deferred_after_update_out.buffer.items, "based_on\t2\t") != null);

            var deferred_incoming_after_update_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer deferred_incoming_after_update_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "incoming", db_path, "2", "based_on" }, &deferred_incoming_after_update_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, deferred_incoming_after_update_out.buffer.items, "based_on\t1\t") != null);
            try std.testing.expect(std.mem.indexOf(u8, deferred_incoming_after_update_out.buffer.items, "Replay task A revised") != null);

            var delete_prune_sidecar_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer delete_prune_sidecar_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "delete-node", db_path, "1" }, &delete_prune_sidecar_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, delete_prune_sidecar_out.buffer.items, "deleted node=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, delete_prune_sidecar_out.buffer.items, "text_rewarmed=0 text_index_current=0") != null);

            var store_info_after_delete_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer store_info_after_delete_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "store-info", db_path }, &store_info_after_delete_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, store_info_after_delete_out.buffer.items, "text_warm=0\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, store_info_after_delete_out.buffer.items, "text_stale=1\n") != null);

            var deferred_after_delete_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer deferred_after_delete_out.buffer.deinit(std.testing.allocator);
            try run(&.{ "tinykg", "incoming", db_path, "2", "based_on" }, &deferred_after_delete_out, std.testing.allocator, std.testing.io);
            try std.testing.expect(std.mem.indexOf(u8, deferred_after_delete_out.buffer.items, "based_on\t1\t") == null);

            var duplicate_out = QueryOutputWriter{ .allocator = std.testing.allocator };
            defer duplicate_out.buffer.deinit(std.testing.allocator);
            try std.testing.expectError(
                error.AlreadyExists,
                run(&.{ "tinykg", "import-metaknow-replay", db_path, corpus_path }, &duplicate_out, std.testing.allocator, std.testing.io),
            );
        }

        test "metaknow replay import recovers only matching owned publications" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const corpus_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "corpus" });
            defer std.testing.allocator.free(corpus_path);
            try writeMetaknowReplayImportFixture(std.testing.allocator, std.testing.io, corpus_path);
            const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "recovered.kg" });
            defer std.testing.allocator.free(target_path);
            const staging_path = try importStagingPath(std.testing.allocator, target_path);
            defer std.testing.allocator.free(staging_path);

            const corpus_identity = try metaknowReplayCorpusIdentity(std.testing.allocator, std.testing.io, corpus_path);
            const canonical_corpus_path = try canonicalProspectivePath(std.testing.allocator, std.testing.io, corpus_path);
            defer std.testing.allocator.free(canonical_corpus_path);
            const expectation = ImportTransactionExpectation{
                .format = "metaknow-replay",
                .canonical_source_path = canonical_corpus_path,
                .source_digest = corpus_identity.digest,
                .warm_text = false,
                .chunk_size = 2,
            };
            const expected_result = ImportPublicationResult{
                .nodes_loaded = 3,
                .nodes_imported = 3,
                .edges_loaded = 3,
                .edges_imported = 2,
                .edges_skipped_missing_endpoint = 1,
                .source_bytes = corpus_identity.bytes,
                .text_warmed = false,
            };

            // A request-marked partial staging tree belongs to this exact retry and
            // may be discarded. The importer must rebuild it from the stable source.
            try createOwnedDirectory(std.testing.io, staging_path);
            try writeImportTransactionMarker(std.testing.allocator, std.testing.io, staging_path, expectation, null);
            const partial_path = try std.fs.path.join(std.testing.allocator, &.{ staging_path, "partial" });
            defer std.testing.allocator.free(partial_path);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = partial_path,
                .data = "interrupted",
                .flags = .{ .truncate = true },
            });
            const first = try importMetaknowReplayCorpus(std.testing.allocator, std.testing.io, target_path, corpus_path, 2, false);
            try std.testing.expectEqual(@as(usize, 3), first.nodes_imported);
            try std.testing.expectEqual(@as(usize, 2), first.edges_imported);
            try std.testing.expectEqual(@as(usize, 1), first.edges_skipped_missing_endpoint);
            try std.testing.expect(!first.marker_cleanup_pending);
            try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));

            // A legacy complete marker is an exact prior publication receipt. The
            // retry validates it and rewrites it to the persistent receipt format.
            var completed_result = expected_result;
            const marker_path = try importTransactionMarkerPath(std.testing.allocator, target_path);
            defer std.testing.allocator.free(marker_path);
            try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
            try rewriteTransactionMarkerFormatForTest(
                std.testing.io,
                marker_path,
                import_transaction_marker_format,
                import_transaction_marker_legacy_format,
            );
            const recovered = try importMetaknowReplayCorpus(std.testing.allocator, std.testing.io, target_path, corpus_path, 2, false);
            try std.testing.expectEqual(@as(usize, 3), recovered.nodes_imported);
            try std.testing.expectEqual(@as(usize, 1), recovered.edges_skipped_missing_endpoint);
            try std.testing.expect(!recovered.marker_cleanup_pending);
            try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
            try std.testing.expect(try transactionMarkerHasFormatForTest(std.testing.io, marker_path, import_transaction_marker_format));

            // Chunk size is part of request identity even though it should not change
            // graph semantics: a retry with different execution parameters must not
            // claim or erase a marker produced by another invocation.
            const current_identity = try storeContentIdentity(std.testing.allocator, std.testing.io, target_path);
            completed_result.published_store_bytes = current_identity.bytes;
            completed_result.published_store_digest = current_identity.digest;
            try writeImportTransactionMarker(std.testing.allocator, std.testing.io, target_path, expectation, completed_result);
            try std.testing.expectError(error.ImportRecoveryConflict, importMetaknowReplayCorpus(
                std.testing.allocator,
                std.testing.io,
                target_path,
                corpus_path,
                3,
                false,
            ));
            try std.testing.expect(try anyPathExists(std.testing.io, marker_path));

            // Same-size source mutations are content changes, not resumable retries.
            const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ corpus_path, "manifest.json" });
            defer std.testing.allocator.free(manifest_path);
            const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .limited(4096));
            defer std.testing.allocator.free(manifest);
            const value_offset = std.mem.indexOf(u8, manifest, "\"deferred_based_on_bytes\":64") orelse return error.InvalidRecord;
            manifest[value_offset + "\"deferred_based_on_bytes\":6".len] = '5';
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = manifest_path,
                .data = manifest,
                .flags = .{ .truncate = true },
            });
            try std.testing.expectError(error.ImportRecoveryConflict, importMetaknowReplayCorpus(
                std.testing.allocator,
                std.testing.io,
                target_path,
                corpus_path,
                2,
                false,
            ));
            try std.testing.expect(try anyPathExists(std.testing.io, marker_path));
        }

        test "metaknow replay import preserves foreign paths and rejects overlap" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const corpus_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "corpus" });
            defer std.testing.allocator.free(corpus_path);
            try writeMetaknowReplayImportFixture(std.testing.allocator, std.testing.io, corpus_path);

            const nested_target = try std.fs.path.join(std.testing.allocator, &.{ corpus_path, "nested.kg" });
            defer std.testing.allocator.free(nested_target);
            try std.testing.expectError(error.InvalidFileName, importMetaknowReplayCorpus(
                std.testing.allocator,
                std.testing.io,
                nested_target,
                corpus_path,
                2,
                false,
            ));
            try std.testing.expect(!try anyPathExists(std.testing.io, nested_target));

            const staging_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "staging-target.kg" });
            defer std.testing.allocator.free(staging_target);
            const foreign_staging = try importStagingPath(std.testing.allocator, staging_target);
            defer std.testing.allocator.free(foreign_staging);
            try createOwnedDirectory(std.testing.io, foreign_staging);
            const staging_sentinel = try std.fs.path.join(std.testing.allocator, &.{ foreign_staging, "foreign" });
            defer std.testing.allocator.free(staging_sentinel);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = staging_sentinel,
                .data = "not-owned-by-importer",
                .flags = .{ .truncate = true },
            });
            try std.testing.expectError(error.ImportRecoveryConflict, importMetaknowReplayCorpus(
                std.testing.allocator,
                std.testing.io,
                staging_target,
                corpus_path,
                2,
                false,
            ));
            try std.testing.expect(try fileExists(std.testing.io, staging_sentinel));
            try std.testing.expect(!try anyPathExists(std.testing.io, staging_target));

            const foreign_target = try std.fs.path.join(std.testing.allocator, &.{ root_path, "foreign-target.kg" });
            defer std.testing.allocator.free(foreign_target);
            try createOwnedDirectory(std.testing.io, foreign_target);
            const target_sentinel = try std.fs.path.join(std.testing.allocator, &.{ foreign_target, "foreign" });
            defer std.testing.allocator.free(target_sentinel);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = target_sentinel,
                .data = "not-owned-by-importer",
                .flags = .{ .truncate = true },
            });
            try std.testing.expectError(error.AlreadyExists, importMetaknowReplayCorpus(
                std.testing.allocator,
                std.testing.io,
                foreign_target,
                corpus_path,
                2,
                false,
            ));
            try std.testing.expect(try fileExists(std.testing.io, target_sentinel));
        }

        test "metaknow replay import cleans staging after allocation failure" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root_path = path_buf[0..root_len];
            const corpus_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "corpus" });
            defer std.testing.allocator.free(corpus_path);
            try writeMetaknowReplayImportFixture(std.testing.allocator, std.testing.io, corpus_path);

            var saw_allocation_failure = false;
            var reached_success = false;
            for (0..2048) |fail_index| {
                const target_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/oom-replay-{}.kg", .{ root_path, fail_index });
                defer std.testing.allocator.free(target_path);
                const staging_path = try importStagingPath(std.testing.allocator, target_path);
                defer std.testing.allocator.free(staging_path);
                var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
                _ = importMetaknowReplayCorpus(failing.allocator(), std.testing.io, target_path, corpus_path, 2, true) catch |err| switch (err) {
                    error.OutOfMemory => {
                        saw_allocation_failure = true;
                        try std.testing.expect(!try anyPathExists(std.testing.io, target_path));
                        try std.testing.expect(!try anyPathExists(std.testing.io, staging_path));
                        continue;
                    },
                    else => return err,
                };
                reached_success = true;
                try std.Io.Dir.cwd().deleteTree(std.testing.io, target_path);
                break;
            }
            try std.testing.expect(saw_allocation_failure);
            try std.testing.expect(reached_success);
        }
    };
}
