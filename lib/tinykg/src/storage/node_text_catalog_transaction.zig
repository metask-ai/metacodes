const std = @import("std");
const compaction_policy = @import("node_text_run_compaction_policy.zig");

const write_buffer_bytes: usize = 256 * 1024;

const BufferedWriter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    len: usize = 0,
    offset: u64 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !BufferedWriter {
        if (capacity == 0) return error.InvalidRecord;
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .buffer = try allocator.alloc(u8, capacity),
        };
    }

    fn initAtOffset(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize, offset: u64) !BufferedWriter {
        var writer = try init(allocator, io, file, capacity);
        writer.offset = offset;
        return writer;
    }

    fn deinit(self: *BufferedWriter) void {
        self.allocator.free(self.buffer);
    }

    fn append(self: *BufferedWriter, bytes: []const u8) !void {
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

    fn flush(self: *BufferedWriter) !void {
        if (self.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buffer[0..self.len], self.offset);
        self.offset = std.math.add(u64, self.offset, self.len) catch return error.InvalidRecord;
        self.len = 0;
    }

    fn position(self: *const BufferedWriter) u64 {
        return self.offset + self.len;
    }
};

/// Shared publication protocol for a prepared run.  The concrete publication
/// object owns validation evidence, staging bytes, manifest construction, and
/// ambiguous-commit cleanup; this sequencer owns their fail-stop order.
fn stageAndPublishPreparedRun(publication: anytype) !void {
    try publication.validateCatalog();
    errdefer publication.discardUnpublishedRun();
    try publication.stageRun();
    try publication.prepareManifest();
    publication.markManifestMayReferenceRun();
    try publication.publishRunManifest();
}

fn publishDeltaRun(publication: anytype) !void {
    try stageAndPublishPreparedRun(publication);
    try publication.clearDelta();
    try publication.publishMetadata();
}

fn publishRunWindow(publication: anytype) !u64 {
    try publication.publishRunManifest();
    try publication.publishMetadata();
    return try publication.collectGarbage();
}

fn publishCompactedBase(publication: anytype) !u64 {
    try publication.publishBase();
    try publication.clearDelta();
    const deleted_runs = try publication.clearRuns();
    try publication.publishMetadata();
    return deleted_runs;
}

fn publishMergedBase(publication: anytype) !void {
    try publication.publishBase();
    try publication.clearDelta();
    try publication.clearRunManifest();
    try publication.finishBase();
}

/// Owns the mutation side of the logical node-text catalog.  Base, delta,
/// run-manifest, and IndexMeta bytes are validated as one snapshot before any
/// staging starts; each path then publishes new data before its catalog pointer
/// and keeps metadata/garbage collection behind the corresponding commit
/// barrier.  Maintenance admission, primary text bytes, manifest encoding/GC,
/// and compact record-layout derivation remain behind the injected context.
pub fn NodeTextCatalogTransaction(comptime Context: type) type {
    return struct {
        const Meta = Context.MetaType;
        const Header = Context.HeaderType;
        const Record = Context.RecordType;
        const Manifest = Context.ManifestType;
        const OwnedEntry = Context.OwnedEntryType;
        const Entry = Context.EntryType;
        const Digest = Context.DigestType;
        const TextsView = Context.TextsViewType;
        const RunResult = Context.RunResultType;
        const GcResult = Context.GcResultType;

        const CatalogValidation = struct {
            run_count: u64,
        };

        const DeltaRunPublication = struct {
            context: Context,
            validation: CatalogValidation,
            base_header: Header,
            original_entries: []const OwnedEntry,
            records: []const Record,
            digest: Digest,
            run_path: []const u8,
            next_entries: *std.ArrayList(Entry),
            hash_filter: *?[]u8,
            run_unpublished: *bool,
            next_meta: *Meta,

            fn validateCatalog(self: *DeltaRunPublication) !void {
                _ = self.validation;
            }

            fn stageRun(self: *DeltaRunPublication) !void {
                try writeRunFile(
                    self.context,
                    self.run_path,
                    self.records,
                    self.digest.digest,
                    self.digest.order_digest,
                    .verify_by_id,
                );
            }

            fn prepareManifest(self: *DeltaRunPublication) !void {
                try self.next_entries.ensureTotalCapacityPrecise(
                    self.context.allocator,
                    self.original_entries.len + 1,
                );
                for (self.original_entries) |entry| self.next_entries.appendAssumeCapacity(copyEntry(entry));
                const filter = try self.context.buildRunHashFilterForRecords(self.records);
                self.hash_filter.* = filter;
                self.next_entries.appendAssumeCapacity(.{
                    .node_count = self.digest.count,
                    .node_digest = self.digest.digest,
                    .order_digest = self.digest.order_digest,
                    .min_node_id = self.digest.min_node_id,
                    .max_node_id = self.digest.max_node_id,
                    .min_hash = self.digest.min_hash,
                    .max_hash = self.digest.max_hash,
                    .path = self.run_path,
                    .hash_filter = filter,
                });
            }

            fn markManifestMayReferenceRun(self: *DeltaRunPublication) void {
                self.run_unpublished.* = false;
            }

            fn publishRunManifest(self: *DeltaRunPublication) !void {
                try self.context.writeRunManifestEntries(self.next_entries.items);
            }

            fn clearDelta(self: *DeltaRunPublication) !void {
                try self.context.writeEmptyDelta();
            }

            fn publishMetadata(self: *DeltaRunPublication) !void {
                self.next_meta.node_by_text_order_digest = Context.combinedOrderDigestEntries(
                    self.base_header,
                    .{ .node_count = 0 },
                    self.next_entries.items,
                );
                try self.context.writeIndexMeta(self.next_meta.*);
            }

            fn discardUnpublishedRun(self: *DeltaRunPublication) void {
                if (self.run_unpublished.*) {
                    std.Io.Dir.cwd().deleteFile(self.context.io, self.run_path) catch {};
                }
            }
        };

        const BatchRunPublication = struct {
            context: Context,
            validation: CatalogValidation,
            original_entries: []const OwnedEntry,
            records: []const Record,
            batch_digest: u64,
            batch_order_digest: u64,
            span_derive_mode: SpanDeriveMode,
            run_path: []const u8,
            next_entries: *std.ArrayList(Entry),
            hash_filter: *?[]u8,
            run_unpublished: *bool,

            fn validateCatalog(self: *BatchRunPublication) !void {
                _ = self.validation;
            }

            fn stageRun(self: *BatchRunPublication) !void {
                try writeRunFile(
                    self.context,
                    self.run_path,
                    self.records,
                    self.batch_digest,
                    self.batch_order_digest,
                    self.span_derive_mode,
                );
            }

            fn prepareManifest(self: *BatchRunPublication) !void {
                try self.next_entries.ensureTotalCapacity(
                    self.context.allocator,
                    self.original_entries.len + 1,
                );
                for (self.original_entries) |entry| self.next_entries.appendAssumeCapacity(copyEntry(entry));
                const batch_id_range = try Context.recordIdRange(self.records);
                const batch_hash_range = try Context.recordHashRange(self.records);
                const filter = try self.context.buildRunHashFilterForRecords(self.records);
                self.hash_filter.* = filter;
                self.next_entries.appendAssumeCapacity(.{
                    .node_count = @intCast(self.records.len),
                    .node_digest = self.batch_digest,
                    .order_digest = self.batch_order_digest,
                    .min_node_id = batch_id_range.min,
                    .max_node_id = batch_id_range.max,
                    .min_hash = batch_hash_range.min,
                    .max_hash = batch_hash_range.max,
                    .path = self.run_path,
                    .hash_filter = filter,
                });
            }

            fn markManifestMayReferenceRun(self: *BatchRunPublication) void {
                self.run_unpublished.* = false;
            }

            fn publishRunManifest(self: *BatchRunPublication) !void {
                try self.context.writeRunManifestEntries(self.next_entries.items);
            }

            fn discardUnpublishedRun(self: *BatchRunPublication) void {
                if (self.run_unpublished.*) {
                    std.Io.Dir.cwd().deleteFile(self.context.io, self.run_path) catch {};
                }
            }
        };

        const RunWindowPublication = struct {
            context: Context,
            next_entries: []const Entry,
            pinned_manifest_paths: []const []const u8,
            next_meta: Meta,
            original_entries: []const OwnedEntry,
            selected_start: usize,
            selected_end: usize,
            compacted_run_unpublished: *bool,

            fn publishRunManifest(self: *RunWindowPublication) !void {
                self.compacted_run_unpublished.* = false;
                try self.context.writeRunManifestEntriesExcept(
                    self.next_entries,
                    self.pinned_manifest_paths,
                );
            }

            fn publishMetadata(self: *RunWindowPublication) !void {
                try self.context.writeIndexMeta(self.next_meta);
            }

            fn collectGarbage(self: *RunWindowPublication) !u64 {
                var deleted_runs: u64 = 0;
                var delete_index = self.selected_start;
                var pinned_run_paths = try self.context.runPathsForPinnedManifests(self.pinned_manifest_paths);
                defer self.context.freeOwnedPathSet(&pinned_run_paths);
                while (delete_index < self.selected_end) : (delete_index += 1) {
                    if (pinned_run_paths.contains(self.original_entries[delete_index].path)) continue;
                    std.Io.Dir.cwd().deleteFile(self.context.io, self.original_entries[delete_index].path) catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => |other| return other,
                    };
                    deleted_runs += 1;
                }
                return deleted_runs;
            }
        };

        const OverlayBasePublication = struct {
            context: Context,
            tmp_path: []const u8,
            pinned_manifest_paths: []const []const u8,
            expected_count: u64,
            expected_digest: u64,
            expected_order_digest: u64,
            next_order_digest: u64,

            fn publishBase(self: *OverlayBasePublication) !void {
                try self.context.renameReplace(self.tmp_path, self.context.node_by_text_path);
            }

            fn clearDelta(self: *OverlayBasePublication) !void {
                try self.context.writeEmptyDelta();
            }

            fn clearRuns(self: *OverlayBasePublication) !u64 {
                const result: GcResult = try self.context.deleteRunManifestExcept(self.pinned_manifest_paths);
                return result.deleted_runs;
            }

            fn publishMetadata(self: *OverlayBasePublication) !void {
                var meta = try self.context.readIndexMeta();
                if (meta.nodes != self.expected_count) return error.InvalidRecord;
                if (meta.node_digest != self.expected_digest) return error.InvalidRecord;
                if (meta.node_by_text_order_digest != self.expected_order_digest) return error.InvalidRecord;
                meta.node_by_text_order_digest = self.next_order_digest;
                try self.context.writeIndexMeta(meta);
            }
        };

        const MergedBasePublication = struct {
            context: Context,
            tmp_path: ?[]const u8,
            ensure_hash_filter: bool,

            fn publishBase(self: *MergedBasePublication) !void {
                if (self.tmp_path) |path| {
                    try self.context.renameReplace(path, self.context.node_by_text_path);
                }
            }

            fn clearDelta(self: *MergedBasePublication) !void {
                try self.context.writeEmptyDelta();
            }

            fn clearRunManifest(self: *MergedBasePublication) !void {
                try self.context.deleteRunManifest();
            }

            fn finishBase(self: *MergedBasePublication) !void {
                if (self.ensure_hash_filter) try self.context.ensureCurrentBaseHashFilter();
            }
        };

        pub const SpanDeriveMode = enum {
            trusted_recent_by_id_append,
            verify_by_id,
        };

        pub const OverlayCompactionResult = struct {
            order_digest: u64,
            run_entries_before: usize,
            run_records_before: u64,
            delta_records_before: u64,
            gc_deleted_runs: u64,
        };

        pub const RunReader = struct {
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap,
            next_index: u64,
            count: u64,
            header: Header,
            digest: Digest = .{},
            previous: ?Record = null,

            pub fn deinit(self: *RunReader, io: std.Io) void {
                if (self.map) |*mapped| mapped.destroy(io);
                self.file.close(io);
            }
        };

        pub const RunHeapEntry = struct {
            run_index: usize,
            record: Record,
        };

        pub fn compareRunHeapEntry(_: void, lhs: RunHeapEntry, rhs: RunHeapEntry) std.math.Order {
            if (Context.recordLessThan(lhs.record, rhs.record)) return .lt;
            if (Context.recordLessThan(rhs.record, lhs.record)) return .gt;
            return std.math.order(lhs.run_index, rhs.run_index);
        }

        fn shouldSync(context: Context) bool {
            return context.shouldSync();
        }

        fn regularFileSize(context: Context, file: std.Io.File) !u64 {
            const stat = try file.stat(context.io);
            if (stat.kind != .file) return error.IsDir;
            return stat.size;
        }

        fn indexFileSizeForHeader(header: Header) !u64 {
            try header.validateShape();
            const max_records_size = std.math.maxInt(u64) - Header.encoded_len;
            if (header.node_count > max_records_size / header.record_len) return error.InvalidRecord;
            return Header.encoded_len + header.node_count * header.record_len;
        }

        fn recordOffsetForHeader(header: Header, index: u64) !u64 {
            try header.validateShape();
            const bytes = std.math.mul(u64, index, header.record_len) catch return error.InvalidRecord;
            return std.math.add(u64, Header.encoded_len, bytes) catch return error.InvalidRecord;
        }

        fn writeBufferCapacity(file_size: u64) !usize {
            const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
            return @max(@as(usize, 1), @min(write_buffer_bytes, size));
        }

        fn writeHeader(context: Context, file: std.Io.File, header: Header) !void {
            try header.validateShape();
            var bytes: [Header.encoded_len]u8 = undefined;
            header.encode(&bytes);
            try file.writePositionalAll(context.io, &bytes, 0);
        }

        fn writeRecord(writer: *BufferedWriter, header: Header, record: Record) !void {
            var bytes: [Record.encoded_len]u8 = undefined;
            const encoded = bytes[0..header.record_len];
            try record.encodeForHeader(header, encoded);
            try writer.append(encoded);
        }

        fn copyEntry(entry: OwnedEntry) Entry {
            return .{
                .node_count = entry.node_count,
                .node_digest = entry.node_digest,
                .order_digest = entry.order_digest,
                .min_node_id = entry.min_node_id,
                .max_node_id = entry.max_node_id,
                .min_hash = entry.min_hash,
                .max_hash = entry.max_hash,
                .path = entry.path,
                .hash_filter = entry.hash_filter,
            };
        }

        fn validateCatalog(
            context: Context,
            meta: Meta,
            base_header: Header,
            delta_header: Header,
            manifest_entries: []const OwnedEntry,
        ) !CatalogValidation {
            _ = context;
            const run_count = Context.manifestTotalNodesOwned(manifest_entries) orelse return error.InvalidRecord;
            const base_and_delta = std.math.add(u64, base_header.node_count, delta_header.node_count) catch return error.InvalidRecord;
            const logical_count = std.math.add(u64, base_and_delta, run_count) catch return error.InvalidRecord;
            if (logical_count != meta.nodes) return error.InvalidRecord;
            if ((base_header.node_digest ^ delta_header.node_digest ^ Context.manifestDigestOwned(manifest_entries)) != meta.node_digest) return error.InvalidRecord;
            if (Context.combinedOrderDigestOwned(base_header, delta_header, manifest_entries) != meta.node_by_text_order_digest) return error.InvalidRecord;
            return .{ .run_count = run_count };
        }

        pub fn publishDeltaAsRun(
            context: Context,
            meta: Meta,
            base_header: Header,
            delta_header: Header,
            manifest_entries: []const OwnedEntry,
        ) !?u64 {
            if (delta_header.node_count == 0) return null;
            if (delta_header.node_count > Context.run_max_records) return error.InvalidRecord;
            if (manifest_entries.len >= Context.manifest_max_entries) return null;
            var next_meta = try context.readIndexMeta();
            if (next_meta.nodes != meta.nodes) return error.InvalidRecord;
            if (next_meta.node_digest != meta.node_digest) return error.InvalidRecord;
            if (next_meta.node_by_text_order_digest != meta.node_by_text_order_digest) return error.InvalidRecord;
            const validation = try validateCatalog(context, meta, base_header, delta_header, manifest_entries);

            var texts = try context.openNodeTextsView();
            defer context.deinitNodeTextsView(&texts);
            var delta_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_delta_path, .{});
            defer delta_file.close(context.io);
            const expected_delta_size = try indexFileSizeForHeader(delta_header);
            if (try regularFileSize(context, delta_file) != expected_delta_size) return error.InvalidRecord;

            var delta_records = std.ArrayList(Record).empty;
            defer delta_records.deinit(context.allocator);
            try delta_records.ensureTotalCapacityPrecise(context.allocator, @intCast(delta_header.node_count));
            var delta_digest = Digest{};
            var previous: ?Record = null;
            var pos: u64 = 0;
            while (pos < delta_header.node_count) : (pos += 1) {
                const record = try context.readRecordWithTexts(delta_file, delta_header, pos, &texts);
                if (previous) |prev| {
                    if (!Context.recordLessThan(prev, record)) return error.InvalidRecord;
                    if (prev.id == record.id) return error.InvalidRecord;
                }
                delta_digest.add(record, try context.recordDigestWithTexts(&texts, record));
                delta_records.appendAssumeCapacity(record);
                previous = record;
            }
            if (delta_digest.count != delta_header.node_count) return error.InvalidRecord;
            if (delta_digest.digest != delta_header.node_digest) return error.InvalidRecord;
            if (delta_digest.order_digest != delta_header.order_digest) return error.InvalidRecord;

            const run_path = try runBatchPath(context, next_meta, next_meta, delta_header.node_count);
            defer context.allocator.free(run_path);
            if (try context.pathExists(run_path)) return error.AlreadyExists;
            var run_unpublished = true;
            var next_entries = std.ArrayList(Entry).empty;
            defer next_entries.deinit(context.allocator);
            var hash_filter: ?[]u8 = null;
            defer if (hash_filter) |filter| context.allocator.free(filter);
            var publication = DeltaRunPublication{
                .context = context,
                .validation = validation,
                .base_header = base_header,
                .original_entries = manifest_entries,
                .records = delta_records.items,
                .digest = delta_digest,
                .run_path = run_path,
                .next_entries = &next_entries,
                .hash_filter = &hash_filter,
                .run_unpublished = &run_unpublished,
                .next_meta = &next_meta,
            };
            try publishDeltaRun(&publication);
            return next_meta.node_by_text_order_digest;
        }

        pub fn compactDelta(context: Context, expected_count: u64, expected_digest: u64, expected_order_digest: u64) !u64 {
            var old_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_path, .{});
            defer old_file.close(context.io);
            const old_header = try context.readHeader(old_file);
            const expected_old_size = try indexFileSizeForHeader(old_header);
            if (try regularFileSize(context, old_file) != expected_old_size) return error.InvalidRecord;
            var old_map = if (old_header.hasDerivedTextSpan()) null else context.openReadOnlyMemoryMap(old_file, expected_old_size) catch null;
            defer if (old_map) |*mapped| mapped.destroy(context.io);

            const delta_header = try context.readDeltaHeader();
            var manifest = try context.readRunManifest();
            defer manifest.deinit(context.allocator);
            const run_count = manifest.totalNodeCount();
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;
            if (delta_header.node_count == 0) return Context.combinedOrderDigestOwned(old_header, delta_header, manifest.entries.items);
            const expected_meta = Meta{
                .nodes = expected_count,
                .node_digest = expected_digest,
                .node_by_text_order_digest = expected_order_digest,
            };
            _ = try validateCatalog(context, expected_meta, old_header, delta_header, manifest.entries.items);
            const next_base_count = old_header.node_count + delta_header.node_count;
            const next_base_digest = old_header.node_digest ^ delta_header.node_digest;

            var delta_records = std.ArrayList(Record).empty;
            defer delta_records.deinit(context.allocator);
            try delta_records.ensureTotalCapacity(context.allocator, @intCast(delta_header.node_count));
            var texts = try context.openNodeTextsView();
            defer context.deinitNodeTextsView(&texts);
            {
                var delta_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_delta_path, .{});
                defer delta_file.close(context.io);
                var delta_digest = Digest{};
                var delta_pos: u64 = 0;
                while (delta_pos < delta_header.node_count) : (delta_pos += 1) {
                    const record = try context.readRecordWithTexts(delta_file, delta_header, delta_pos, &texts);
                    delta_digest.add(record, try context.recordDigestWithTexts(&texts, record));
                    try delta_records.append(context.allocator, record);
                }
                if (delta_digest.count != delta_header.node_count) return error.InvalidRecord;
                if (delta_digest.digest != delta_header.node_digest) return error.InvalidRecord;
                if (delta_digest.order_digest != delta_header.order_digest) return error.InvalidRecord;
            }
            std.mem.sort(Record, delta_records.items, {}, Context.recordLessThanContext);

            const tmp_path = try context.tmpPathFor(context.node_by_text_path);
            defer context.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};
            var next_order = Digest{};
            {
                var new_file = try std.Io.Dir.cwd().createFile(context.io, tmp_path, .{ .read = true, .truncate = true });
                defer new_file.close(context.io);
                const output_header = Context.headerForTail(old_header, next_base_count, next_base_digest, 0, delta_records.items);
                var writer = try BufferedWriter.init(context.allocator, context.io, new_file, try writeBufferCapacity(try indexFileSizeForHeader(output_header)));
                defer writer.deinit();

                var header_bytes: [Header.encoded_len]u8 = undefined;
                output_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var delta_pos: usize = 0;
                var old_pos: u64 = 0;
                var previous: ?Record = null;
                while (old_pos < old_header.node_count) : (old_pos += 1) {
                    const current = if (old_map) |*mapped|
                        try context.readRecordFromMap(old_header, mapped, old_pos, &texts)
                    else
                        try context.readRecordWithTexts(old_file, old_header, old_pos, &texts);
                    if (previous) |prev| {
                        if (!Context.recordLessThan(prev, current)) return error.InvalidRecord;
                        if (prev.id == current.id) return error.InvalidRecord;
                    }
                    while (delta_pos < delta_records.items.len and Context.recordLessThan(delta_records.items[delta_pos], current)) : (delta_pos += 1) {
                        if (previous) |prev| if (prev.id == delta_records.items[delta_pos].id) return error.InvalidRecord;
                        next_order.add(delta_records.items[delta_pos], try context.recordDigestWithTexts(&texts, delta_records.items[delta_pos]));
                        try writeRecord(&writer, output_header, delta_records.items[delta_pos]);
                        previous = delta_records.items[delta_pos];
                    }
                    if (previous) |prev| if (prev.id == current.id) return error.InvalidRecord;
                    next_order.add(current, try context.recordDigestWithTexts(&texts, current));
                    try writeRecord(&writer, output_header, current);
                    previous = current;
                }
                while (delta_pos < delta_records.items.len) : (delta_pos += 1) {
                    if (previous) |prev| if (prev.id == delta_records.items[delta_pos].id) return error.InvalidRecord;
                    next_order.add(delta_records.items[delta_pos], try context.recordDigestWithTexts(&texts, delta_records.items[delta_pos]));
                    try writeRecord(&writer, output_header, delta_records.items[delta_pos]);
                    previous = delta_records.items[delta_pos];
                }
                if (next_order.count != next_base_count) return error.InvalidRecord;
                if (next_order.digest != next_base_digest) return error.InvalidRecord;
                try writer.flush();
                try writeHeader(context, new_file, .{
                    .node_count = next_base_count,
                    .node_digest = next_base_digest,
                    .order_digest = next_order.order_digest,
                    .flags = output_header.flags,
                    .record_len = output_header.record_len,
                    .uniform_kind = output_header.uniform_kind,
                });
                if (shouldSync(context)) try new_file.sync(context.io);
            }

            try context.renameReplace(tmp_path, context.node_by_text_path);
            try context.writeEmptyDelta();

            var meta = try context.readIndexMeta();
            if (meta.nodes != expected_count) return error.InvalidRecord;
            if (meta.node_digest != expected_digest) return error.InvalidRecord;
            if (meta.node_by_text_order_digest != expected_order_digest) return error.InvalidRecord;
            meta.node_by_text_order_digest = Context.combinedOrderDigestOwned(.{
                .node_count = next_base_count,
                .node_digest = next_base_digest,
                .order_digest = next_order.order_digest,
            }, .{ .node_count = 0 }, manifest.entries.items);
            try context.writeIndexMeta(meta);
            return meta.node_by_text_order_digest;
        }

        fn runBatchPath(context: Context, old_meta: Meta, next_meta: Meta, batch_count: u64) ![]u8 {
            const parent = try std.fs.path.join(context.allocator, &.{ context.dir_path, "node_text_runs" });
            defer context.allocator.free(parent);
            try std.Io.Dir.cwd().createDirPath(context.io, parent);
            const leaf = try std.fmt.allocPrint(context.allocator, "l0-{}-{}-{}-{}", .{ old_meta.nodes, next_meta.nodes, batch_count, next_meta.event_bytes });
            defer context.allocator.free(leaf);
            return try std.fs.path.join(context.allocator, &.{ parent, leaf });
        }

        fn windowPath(context: Context, meta: Meta, selected_start: usize, selected_entries: usize, selected_records: u64, order_digest: u64) ![]u8 {
            const parent = try std.fs.path.join(context.allocator, &.{ context.dir_path, "node_text_runs" });
            defer context.allocator.free(parent);
            try std.Io.Dir.cwd().createDirPath(context.io, parent);
            const leaf = try std.fmt.allocPrint(context.allocator, "lc-{}-{}-{}-{}-{x}", .{ meta.nodes, selected_start, selected_entries, selected_records, order_digest });
            defer context.allocator.free(leaf);
            return try std.fs.path.join(context.allocator, &.{ parent, leaf });
        }

        fn windowScratchPath(context: Context, meta: Meta, selected_start: usize, selected_entries: usize, selected_records: u64) ![]u8 {
            const parent = try std.fs.path.join(context.allocator, &.{ context.dir_path, "node_text_runs" });
            defer context.allocator.free(parent);
            try std.Io.Dir.cwd().createDirPath(context.io, parent);
            const leaf = try std.fmt.allocPrint(context.allocator, "lc-{}-{}-{}-{}-{}-{x}.tmp", .{ meta.nodes, selected_start, selected_entries, selected_records, Context.currentProcessId(), meta.event_bytes });
            defer context.allocator.free(leaf);
            return try std.fs.path.join(context.allocator, &.{ parent, leaf });
        }

        fn writeRunFile(
            context: Context,
            path: []const u8,
            records: []const Record,
            node_digest: u64,
            order_digest: u64,
            span_derive_mode: SpanDeriveMode,
        ) !void {
            const tmp_path = try context.tmpPathFor(path);
            defer context.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(context.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(context.io);
                const derive_text_span = try context.recordsCanDeriveSpans(records, span_derive_mode);
                var texts = try context.openNodeTextsView();
                defer context.deinitNodeTextsView(&texts);
                var header = Context.headerForRecordsWithDerivedSpan(records, node_digest, order_digest, derive_text_span);
                header.setTextHashUnique(try context.sortedRecordsHaveUniqueTextHashes(&texts, records));
                var writer = try BufferedWriter.init(context.allocator, context.io, file, try writeBufferCapacity(try indexFileSizeForHeader(header)));
                defer writer.deinit();
                var header_bytes: [Header.encoded_len]u8 = undefined;
                header.encode(&header_bytes);
                try writer.append(&header_bytes);
                for (records) |record| try writeRecord(&writer, header, record);
                try writer.flush();
                if (writer.position() != try indexFileSizeForHeader(header)) return error.InvalidRecord;
                if (!derive_text_span) {
                    var compact_header = header;
                    try context.compactDerivedRecords(file, &compact_header);
                }
                if (shouldSync(context)) try file.sync(context.io);
            }
            try context.renameReplace(tmp_path, path);
        }

        pub fn pushNextOverlayRecord(
            context: Context,
            readers: *std.ArrayList(RunReader),
            queue: *std.PriorityQueue(RunHeapEntry, void, compareRunHeapEntry),
            texts: *const TextsView,
            reader_index: usize,
        ) !void {
            const reader = &readers.items[reader_index];
            if (reader.next_index >= reader.count) return;
            const record = if (reader.map) |*map|
                try context.readRecordFromMap(reader.header, map, reader.next_index, texts)
            else
                try context.readRecordWithTexts(reader.file, reader.header, reader.next_index, texts);
            if (reader.previous) |prev| {
                if (!Context.recordLessThan(prev, record)) return error.InvalidRecord;
                if (prev.id == record.id) return error.InvalidRecord;
            }
            reader.previous = record;
            reader.digest.add(record, try context.recordDigestWithTexts(texts, record));
            reader.next_index += 1;
            try queue.push(context.allocator, .{ .run_index = reader_index, .record = record });
        }

        fn writeRunFileFromHeap(
            context: Context,
            path: []const u8,
            readers: *std.ArrayList(RunReader),
            queue: *std.PriorityQueue(RunHeapEntry, void, compareRunHeapEntry),
            texts: *const TextsView,
            expected_records: u64,
        ) !Digest {
            var file = try std.Io.Dir.cwd().createFile(context.io, path, .{ .read = true, .truncate = true });
            defer file.close(context.io);
            var compacted_digest = Digest{};
            var final_header = Header{ .node_count = expected_records };
            {
                const output_header = Header{ .node_count = expected_records };
                var writer = try BufferedWriter.init(context.allocator, context.io, file, try writeBufferCapacity(try indexFileSizeForHeader(output_header)));
                defer writer.deinit();

                var header_bytes: [Header.encoded_len]u8 = undefined;
                output_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var previous: ?Record = null;
                while (queue.pop()) |entry| {
                    try pushNextOverlayRecord(context, readers, queue, texts, entry.run_index);
                    const record = entry.record;
                    if (previous) |prev| {
                        if (!Context.recordLessThan(prev, record)) return error.InvalidRecord;
                        if (prev.id == record.id) return error.InvalidRecord;
                    }
                    compacted_digest.add(record, try context.recordDigestWithTexts(texts, record));
                    previous = record;
                    try writeRecord(&writer, output_header, record);
                }
                try writer.flush();
                final_header = .{
                    .node_count = compacted_digest.count,
                    .node_digest = compacted_digest.digest,
                    .order_digest = compacted_digest.order_digest,
                    .flags = output_header.flags,
                    .record_len = output_header.record_len,
                    .uniform_kind = output_header.uniform_kind,
                };
            }
            if (compacted_digest.count != expected_records) return error.InvalidRecord;
            for (readers.items) |reader| {
                if (reader.next_index != reader.count) return error.InvalidRecord;
                if (reader.digest.count != reader.header.node_count) return error.InvalidRecord;
                if (reader.digest.digest != reader.header.node_digest) return error.InvalidRecord;
                if (reader.digest.order_digest != reader.header.order_digest) return error.InvalidRecord;
            }

            try writeHeader(context, file, final_header);
            try context.compactDerivedRecords(file, &final_header);
            if (shouldSync(context)) try file.sync(context.io);
            if (try regularFileSize(context, file) != try indexFileSizeForHeader(final_header)) return error.InvalidRecord;
            return compacted_digest;
        }

        pub fn compactRunWindow(
            context: Context,
            meta: Meta,
            manifest_entries: []const OwnedEntry,
            delta_header: Header,
            max_run_records: u64,
            pinned_manifest_paths: []const []const u8,
        ) !?RunResult {
            if (manifest_entries.len < 2) return null;
            var base_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_path, .{});
            defer base_file.close(context.io);
            const base_header = try context.readHeader(base_file);
            const expected_base_size = try indexFileSizeForHeader(base_header);
            if (try regularFileSize(context, base_file) != expected_base_size) return error.InvalidRecord;

            const run_count = (try validateCatalog(context, meta, base_header, delta_header, manifest_entries)).run_count;
            const selected_limit = if (max_run_records == 0)
                Context.run_max_records
            else
                @min(max_run_records, Context.run_max_records);
            const selected = (try compaction_policy.select(context.allocator, manifest_entries, selected_limit)) orelse return null;
            const selected_end = std.math.add(usize, selected.start, selected.count) catch return error.RecordTooLarge;

            var texts = try context.openNodeTextsView();
            defer context.deinitNodeTextsView(&texts);

            var readers = std.ArrayList(RunReader).empty;
            var readers_closed = false;
            defer {
                if (!readers_closed) for (readers.items) |*reader| reader.deinit(context.io);
                readers.deinit(context.allocator);
            }
            try readers.ensureTotalCapacityPrecise(context.allocator, selected.count);

            var queue = std.PriorityQueue(RunHeapEntry, void, compareRunHeapEntry).initContext({});
            defer queue.deinit(context.allocator);
            try queue.ensureTotalCapacityPrecise(context.allocator, selected.count);

            var entry_index: usize = selected.start;
            while (entry_index < selected_end) : (entry_index += 1) {
                const entry = manifest_entries[entry_index];
                var run_file = try std.Io.Dir.cwd().openFile(context.io, entry.path, .{});
                var run_file_owned_by_readers = false;
                errdefer if (!run_file_owned_by_readers) run_file.close(context.io);
                const run_header = try context.readHeader(run_file);
                if (run_header.node_count != entry.node_count or
                    run_header.node_digest != entry.node_digest or
                    run_header.order_digest != entry.order_digest) return error.InvalidRecord;
                const expected_run_size = try indexFileSizeForHeader(run_header);
                if (try regularFileSize(context, run_file) != expected_run_size) return error.InvalidRecord;
                var map = if (run_header.hasDerivedTextSpan()) null else context.openReadOnlyMemoryMap(run_file, expected_run_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(context.io);
                const reader_index = readers.items.len;
                readers.appendAssumeCapacity(.{
                    .file = run_file,
                    .map = map,
                    .next_index = 0,
                    .count = run_header.node_count,
                    .header = run_header,
                });
                run_file_owned_by_readers = true;
                map = null;
                try pushNextOverlayRecord(context, &readers, &queue, &texts, reader_index);
            }

            const scratch_path = try windowScratchPath(context, meta, selected.start, selected.count, selected.records);
            defer context.allocator.free(scratch_path);
            errdefer std.Io.Dir.cwd().deleteFile(context.io, scratch_path) catch {};
            const compacted_digest = try writeRunFileFromHeap(context, scratch_path, &readers, &queue, &texts, selected.records);

            for (readers.items) |*reader| reader.deinit(context.io);
            readers_closed = true;

            const compacted_path = try windowPath(context, meta, selected.start, selected.count, selected.records, compacted_digest.order_digest);
            defer context.allocator.free(compacted_path);
            if (try context.pathExists(compacted_path)) return error.AlreadyExists;
            var compacted_run_unpublished = true;
            errdefer if (compacted_run_unpublished) std.Io.Dir.cwd().deleteFile(context.io, compacted_path) catch {};
            try context.renameReplace(scratch_path, compacted_path);

            var next_entries = std.ArrayList(Entry).empty;
            defer next_entries.deinit(context.allocator);
            try next_entries.ensureTotalCapacityPrecise(context.allocator, manifest_entries.len - selected.count + 1);
            var prefix_index: usize = 0;
            while (prefix_index < selected.start) : (prefix_index += 1) next_entries.appendAssumeCapacity(copyEntry(manifest_entries[prefix_index]));
            const compacted_hash_filter = try context.buildRunHashFilterFromFile(compacted_path, selected.records);
            defer context.allocator.free(compacted_hash_filter);
            next_entries.appendAssumeCapacity(.{
                .node_count = selected.records,
                .node_digest = compacted_digest.digest,
                .order_digest = compacted_digest.order_digest,
                .min_node_id = compacted_digest.min_node_id,
                .max_node_id = compacted_digest.max_node_id,
                .min_hash = compacted_digest.min_hash,
                .max_hash = compacted_digest.max_hash,
                .path = compacted_path,
                .hash_filter = compacted_hash_filter,
            });
            var remaining_index = selected_end;
            while (remaining_index < manifest_entries.len) : (remaining_index += 1) next_entries.appendAssumeCapacity(copyEntry(manifest_entries[remaining_index]));

            var next_meta = try context.readIndexMeta();
            if (next_meta.nodes != meta.nodes) return error.InvalidRecord;
            if (next_meta.node_digest != meta.node_digest) return error.InvalidRecord;
            if (next_meta.node_by_text_order_digest != meta.node_by_text_order_digest) return error.InvalidRecord;
            next_meta.node_by_text_order_digest = Context.combinedOrderDigestEntries(base_header, delta_header, next_entries.items);
            var publication = RunWindowPublication{
                .context = context,
                .next_entries = next_entries.items,
                .pinned_manifest_paths = pinned_manifest_paths,
                .next_meta = next_meta,
                .original_entries = manifest_entries,
                .selected_start = selected.start,
                .selected_end = selected_end,
                .compacted_run_unpublished = &compacted_run_unpublished,
            };
            const gc_deleted_runs = try publishRunWindow(&publication);

            return .{
                .compacted = true,
                .run_entries_before = manifest_entries.len,
                .run_entries_after = manifest_entries.len - selected.count + 1,
                .run_records_before = run_count,
                .run_records_after = run_count,
                .compacted_run_records = selected.records,
                .delta_records_before = delta_header.node_count,
                .delta_records_after = delta_header.node_count,
                .gc_deleted_runs = gc_deleted_runs,
            };
        }

        pub fn compactOverlays(
            context: Context,
            expected_count: u64,
            expected_digest: u64,
            expected_order_digest: u64,
            pinned_manifest_paths: []const []const u8,
        ) !OverlayCompactionResult {
            var old_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_path, .{});
            defer old_file.close(context.io);
            const old_header = try context.readHeader(old_file);
            const expected_old_size = try indexFileSizeForHeader(old_header);
            if (try regularFileSize(context, old_file) != expected_old_size) return error.InvalidRecord;
            var old_map = if (old_header.hasDerivedTextSpan()) null else context.openReadOnlyMemoryMap(old_file, expected_old_size) catch null;
            defer if (old_map) |*mapped| mapped.destroy(context.io);

            const delta_header = try context.readDeltaHeader();
            var manifest = try context.readRunManifest();
            defer manifest.deinit(context.allocator);
            const run_count = manifest.totalNodeCount();
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;
            if (delta_header.node_count == 0 and manifest.entries.items.len == 0) return .{
                .order_digest = Context.combinedOrderDigestOwned(old_header, delta_header, manifest.entries.items),
                .run_entries_before = 0,
                .run_records_before = 0,
                .delta_records_before = 0,
                .gc_deleted_runs = 0,
            };
            const expected_meta = Meta{
                .nodes = expected_count,
                .node_digest = expected_digest,
                .node_by_text_order_digest = expected_order_digest,
            };
            _ = try validateCatalog(context, expected_meta, old_header, delta_header, manifest.entries.items);

            var texts = try context.openNodeTextsView();
            defer context.deinitNodeTextsView(&texts);

            var readers = std.ArrayList(RunReader).empty;
            var readers_closed = false;
            defer {
                if (!readers_closed) for (readers.items) |*reader| reader.deinit(context.io);
                readers.deinit(context.allocator);
            }
            const overlay_run_fanin = manifest.entries.items.len + @as(usize, if (delta_header.node_count == 0) 0 else 1);
            try readers.ensureTotalCapacityPrecise(context.allocator, overlay_run_fanin);

            var queue = std.PriorityQueue(RunHeapEntry, void, compareRunHeapEntry).initContext({});
            defer queue.deinit(context.allocator);
            try queue.ensureTotalCapacityPrecise(context.allocator, overlay_run_fanin);

            var sorted_delta_run_path: ?[]u8 = null;
            defer if (sorted_delta_run_path) |path| {
                std.Io.Dir.cwd().deleteFile(context.io, path) catch {};
                context.allocator.free(path);
            };

            if (delta_header.node_count != 0) {
                var delta_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_delta_path, .{});
                defer delta_file.close(context.io);
                const expected_delta_size = try indexFileSizeForHeader(delta_header);
                if (try regularFileSize(context, delta_file) != expected_delta_size) return error.InvalidRecord;
                var delta_records = std.ArrayList(Record).empty;
                defer delta_records.deinit(context.allocator);
                try delta_records.ensureTotalCapacityPrecise(context.allocator, @intCast(delta_header.node_count));
                var original_delta_digest = Digest{};
                var delta_pos: u64 = 0;
                while (delta_pos < delta_header.node_count) : (delta_pos += 1) {
                    const record = try context.readRecordWithTexts(delta_file, delta_header, delta_pos, &texts);
                    original_delta_digest.add(record, try context.recordDigestWithTexts(&texts, record));
                    delta_records.appendAssumeCapacity(record);
                }
                if (original_delta_digest.count != delta_header.node_count) return error.InvalidRecord;
                if (original_delta_digest.digest != delta_header.node_digest) return error.InvalidRecord;
                if (original_delta_digest.order_digest != delta_header.order_digest) return error.InvalidRecord;

                std.mem.sort(Record, delta_records.items, {}, Context.recordLessThanContext);
                var sorted_delta_digest = Digest{};
                var previous_delta: ?Record = null;
                for (delta_records.items) |record| {
                    if (previous_delta) |prev| {
                        if (!Context.recordLessThan(prev, record)) return error.InvalidRecord;
                        if (prev.id == record.id) return error.InvalidRecord;
                    }
                    sorted_delta_digest.add(record, try context.recordDigestWithTexts(&texts, record));
                    previous_delta = record;
                }
                if (sorted_delta_digest.count != delta_header.node_count) return error.InvalidRecord;
                if (sorted_delta_digest.digest != delta_header.node_digest) return error.InvalidRecord;

                const delta_run_path = try context.tmpPathFor(context.node_by_text_delta_path);
                sorted_delta_run_path = delta_run_path;
                try writeRunFile(context, delta_run_path, delta_records.items, sorted_delta_digest.digest, sorted_delta_digest.order_digest, .verify_by_id);
                var sorted_delta_file = try std.Io.Dir.cwd().openFile(context.io, delta_run_path, .{});
                var sorted_delta_file_owned_by_readers = false;
                errdefer if (!sorted_delta_file_owned_by_readers) sorted_delta_file.close(context.io);
                const sorted_delta_header = try context.readHeader(sorted_delta_file);
                if (sorted_delta_header.node_count != sorted_delta_digest.count or
                    sorted_delta_header.node_digest != sorted_delta_digest.digest or
                    sorted_delta_header.order_digest != sorted_delta_digest.order_digest) return error.InvalidRecord;
                const sorted_delta_size = try indexFileSizeForHeader(sorted_delta_header);
                var sorted_delta_map = if (sorted_delta_header.hasDerivedTextSpan()) null else context.openReadOnlyMemoryMap(sorted_delta_file, sorted_delta_size) catch null;
                errdefer if (sorted_delta_map) |*mapped| mapped.destroy(context.io);
                const reader_index = readers.items.len;
                readers.appendAssumeCapacity(.{
                    .file = sorted_delta_file,
                    .map = sorted_delta_map,
                    .next_index = 0,
                    .count = sorted_delta_header.node_count,
                    .header = sorted_delta_header,
                });
                sorted_delta_file_owned_by_readers = true;
                sorted_delta_map = null;
                try pushNextOverlayRecord(context, &readers, &queue, &texts, reader_index);
            }

            for (manifest.entries.items) |entry| {
                var run_file = try std.Io.Dir.cwd().openFile(context.io, entry.path, .{});
                var run_file_owned_by_readers = false;
                errdefer if (!run_file_owned_by_readers) run_file.close(context.io);
                const run_header = try context.readHeader(run_file);
                if (run_header.node_count != entry.node_count or
                    run_header.node_digest != entry.node_digest or
                    run_header.order_digest != entry.order_digest) return error.InvalidRecord;
                const expected_run_size = try indexFileSizeForHeader(run_header);
                if (try regularFileSize(context, run_file) != expected_run_size) return error.InvalidRecord;
                var map = if (run_header.hasDerivedTextSpan()) null else context.openReadOnlyMemoryMap(run_file, expected_run_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(context.io);
                const reader_index = readers.items.len;
                readers.appendAssumeCapacity(.{
                    .file = run_file,
                    .map = map,
                    .next_index = 0,
                    .count = run_header.node_count,
                    .header = run_header,
                });
                run_file_owned_by_readers = true;
                map = null;
                try pushNextOverlayRecord(context, &readers, &queue, &texts, reader_index);
            }

            const tmp_path = try context.tmpPathFor(context.node_by_text_path);
            defer context.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};
            var next_order = Digest{};
            {
                var new_file = try std.Io.Dir.cwd().createFile(context.io, tmp_path, .{ .read = true, .truncate = true });
                defer new_file.close(context.io);
                const output_header = Header{ .node_count = expected_count, .node_digest = expected_digest };
                var writer = try BufferedWriter.init(context.allocator, context.io, new_file, try writeBufferCapacity(try indexFileSizeForHeader(output_header)));
                defer writer.deinit();

                var header_bytes: [Header.encoded_len]u8 = undefined;
                output_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var old_digest = Digest{};
                var old_pos: u64 = 0;
                var old_pending: ?Record = null;
                var overlay_pending: ?RunHeapEntry = null;
                var previous: ?Record = null;
                while (old_pos < old_header.node_count or old_pending != null or overlay_pending != null or queue.count() != 0) {
                    if (old_pending == null and old_pos < old_header.node_count) {
                        const record = if (old_map) |*mapped|
                            try context.readRecordFromMap(old_header, mapped, old_pos, &texts)
                        else
                            try context.readRecordWithTexts(old_file, old_header, old_pos, &texts);
                        old_pos += 1;
                        old_pending = record;
                    }
                    if (overlay_pending == null) overlay_pending = queue.pop();

                    const take_old = if (old_pending) |old_record|
                        if (overlay_pending) |overlay_record| Context.recordLessThan(old_record, overlay_record.record) else true
                    else
                        false;

                    const record = if (take_old) blk: {
                        const current = old_pending.?;
                        old_pending = null;
                        old_digest.add(current, try context.recordDigestWithTexts(&texts, current));
                        break :blk current;
                    } else blk: {
                        const current = overlay_pending orelse return error.InvalidRecord;
                        overlay_pending = null;
                        try pushNextOverlayRecord(context, &readers, &queue, &texts, current.run_index);
                        break :blk current.record;
                    };

                    if (previous) |prev| {
                        if (!Context.recordLessThan(prev, record)) return error.InvalidRecord;
                        if (prev.id == record.id) return error.InvalidRecord;
                    }
                    previous = record;
                    next_order.add(record, try context.recordDigestWithTexts(&texts, record));
                    try writeRecord(&writer, output_header, record);
                }
                if (old_digest.count != old_header.node_count) return error.InvalidRecord;
                if (old_digest.digest != old_header.node_digest) return error.InvalidRecord;
                if (old_digest.order_digest != old_header.order_digest) return error.InvalidRecord;
                for (readers.items) |reader| {
                    if (reader.next_index != reader.count) return error.InvalidRecord;
                    if (reader.digest.count != reader.header.node_count) return error.InvalidRecord;
                    if (reader.digest.digest != reader.header.node_digest) return error.InvalidRecord;
                    if (reader.digest.order_digest != reader.header.order_digest) return error.InvalidRecord;
                }
                if (next_order.count != expected_count) return error.InvalidRecord;
                if (next_order.digest != expected_digest) return error.InvalidRecord;
                try writer.flush();
                try writeHeader(context, new_file, .{
                    .node_count = expected_count,
                    .node_digest = expected_digest,
                    .order_digest = next_order.order_digest,
                    .flags = output_header.flags,
                    .record_len = output_header.record_len,
                    .uniform_kind = output_header.uniform_kind,
                });
                if (shouldSync(context)) try new_file.sync(context.io);
            }

            for (readers.items) |*reader| reader.deinit(context.io);
            readers_closed = true;

            var publication = OverlayBasePublication{
                .context = context,
                .tmp_path = tmp_path,
                .pinned_manifest_paths = pinned_manifest_paths,
                .expected_count = expected_count,
                .expected_digest = expected_digest,
                .expected_order_digest = expected_order_digest,
                .next_order_digest = next_order.order_digest,
            };
            const gc_deleted_runs = try publishCompactedBase(&publication);
            return .{
                .order_digest = next_order.order_digest,
                .run_entries_before = manifest.entries.items.len,
                .run_records_before = run_count,
                .delta_records_before = delta_header.node_count,
                .gc_deleted_runs = gc_deleted_runs,
            };
        }

        fn appendSortedBatchTail(
            context: Context,
            file: std.Io.File,
            old_header: Header,
            batch_records: []const Record,
            next_count: u64,
            next_digest: u64,
            texts: *const TextsView,
        ) !bool {
            if (batch_records.len == 0) return true;
            var text_hash_unique = old_header.hasTextHashUnique();
            var previous_for_hash: ?Record = null;
            if (old_header.node_count != 0) {
                const last = try context.readRecordWithTexts(file, old_header, old_header.node_count - 1, texts);
                if (Context.recordLessThan(batch_records[0], last)) return false;
                if (text_hash_unique) previous_for_hash = last;
            }

            var next_order = old_header.order_digest;
            var batch_digest: u64 = 0;
            var position = old_header.node_count;
            for (batch_records) |record| {
                if (text_hash_unique) {
                    if (previous_for_hash) |prev| {
                        if (prev.hash == record.hash) text_hash_unique = false;
                    }
                    previous_for_hash = record;
                }
                if (!try context.recordFitsStoredHeader(old_header, record)) return false;
                const record_digest = try context.recordDigestWithTexts(texts, record);
                batch_digest ^= record_digest;
                next_order = Context.orderDigestStep(next_order, position, record);
                position = std.math.add(u64, position, 1) catch return error.RecordTooLarge;
            }
            if (position != next_count) return error.InvalidRecord;
            if ((old_header.node_digest ^ batch_digest) != next_digest) return error.InvalidRecord;
            var new_header = Context.headerForTail(old_header, next_count, next_digest, next_order, batch_records);
            new_header.setTextHashUnique(text_hash_unique);
            if (new_header.record_len != old_header.record_len or
                new_header.flags != old_header.flags or
                new_header.uniform_kind != old_header.uniform_kind) return false;

            var writer = try BufferedWriter.initAtOffset(
                context.allocator,
                context.io,
                file,
                write_buffer_bytes,
                try recordOffsetForHeader(old_header, old_header.node_count),
            );
            defer writer.deinit();
            for (batch_records) |record| try writeRecord(&writer, old_header, record);
            try writer.flush();

            var header_bytes: [Header.encoded_len]u8 = undefined;
            new_header.encode(&header_bytes);
            try file.writePositionalAll(context.io, &header_bytes, 0);
            if (shouldSync(context)) try file.sync(context.io);
            return true;
        }

        pub fn writeMergedBatch(
            context: Context,
            old_meta: Meta,
            batch_records: []Record,
            batch_digest: u64,
            next_digest: u64,
            span_derive_mode: SpanDeriveMode,
        ) !void {
            if (batch_records.len == 0) return;
            std.mem.sort(Record, batch_records, {}, Context.recordLessThanContext);
            const next_count = std.math.add(u64, old_meta.nodes, @intCast(batch_records.len)) catch return error.RecordTooLarge;

            var old_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_path, .{ .mode = .read_write, .allow_directory = false });
            defer old_file.close(context.io);
            const old_header = try context.readHeader(old_file);
            if (old_header.node_count != old_meta.nodes) return error.InvalidRecord;
            if (old_header.node_digest != old_meta.node_digest) return error.InvalidRecord;
            if (old_header.order_digest != old_meta.node_by_text_order_digest) return error.InvalidRecord;
            const expected_old_size = try indexFileSizeForHeader(old_header);
            if (try regularFileSize(context, old_file) != expected_old_size) return error.InvalidRecord;
            if (old_header.node_count == 0) {
                if (old_meta.node_digest != 0) return error.InvalidRecord;
                if (batch_digest != next_digest) return error.InvalidRecord;
                const batch_order_digest = try Context.sortedBatchOrderDigest(batch_records);
                const tmp_path = try context.tmpPathFor(context.node_by_text_path);
                defer context.allocator.free(tmp_path);
                errdefer std.Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};
                {
                    var new_file = try std.Io.Dir.cwd().createFile(context.io, tmp_path, .{ .read = true, .truncate = true });
                    defer new_file.close(context.io);
                    const derive_text_span = try context.recordsCanDeriveSpans(batch_records, span_derive_mode);
                    const header = Context.headerForRecordsWithDerivedSpan(batch_records, next_digest, batch_order_digest, derive_text_span);
                    var writer = try BufferedWriter.init(context.allocator, context.io, new_file, try writeBufferCapacity(try indexFileSizeForHeader(header)));
                    defer writer.deinit();
                    var header_bytes: [Header.encoded_len]u8 = undefined;
                    header.encode(&header_bytes);
                    try writer.append(&header_bytes);
                    for (batch_records) |record| try writeRecord(&writer, header, record);
                    try writer.flush();
                    if (writer.position() != try indexFileSizeForHeader(header)) return error.InvalidRecord;
                    if (shouldSync(context)) try new_file.sync(context.io);
                }
                var publication = MergedBasePublication{
                    .context = context,
                    .tmp_path = tmp_path,
                    .ensure_hash_filter = true,
                };
                try publishMergedBase(&publication);
                return;
            }
            var texts = try context.openNodeTextsView();
            defer context.deinitNodeTextsView(&texts);
            if (try appendSortedBatchTail(context, old_file, old_header, batch_records, next_count, next_digest, &texts)) {
                var publication = MergedBasePublication{
                    .context = context,
                    .tmp_path = null,
                    .ensure_hash_filter = false,
                };
                try publishMergedBase(&publication);
                return;
            }
            var old_map = if (old_header.hasDerivedTextSpan()) null else context.openReadOnlyMemoryMap(old_file, expected_old_size) catch null;
            defer if (old_map) |*mapped| mapped.destroy(context.io);

            const tmp_path = try context.tmpPathFor(context.node_by_text_path);
            defer context.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};
            {
                var new_file = try std.Io.Dir.cwd().createFile(context.io, tmp_path, .{ .read = true, .truncate = true });
                defer new_file.close(context.io);
                const output_header = Context.headerForTail(old_header, next_count, next_digest, 0, batch_records);
                var writer = try BufferedWriter.init(context.allocator, context.io, new_file, try writeBufferCapacity(try indexFileSizeForHeader(output_header)));
                defer writer.deinit();
                var header_bytes: [Header.encoded_len]u8 = undefined;
                output_header.encode(&header_bytes);
                try writer.append(&header_bytes);

                var batch_pos: usize = 0;
                var old_digest = Digest{};
                var next_order = Digest{};
                var prev_old: ?Record = null;
                var old_pos: u64 = 0;
                while (old_pos < old_header.node_count) : (old_pos += 1) {
                    const current = if (old_map) |*mapped|
                        try context.readRecordFromMap(old_header, mapped, old_pos, &texts)
                    else
                        try context.readRecordWithTexts(old_file, old_header, old_pos, &texts);
                    if (prev_old) |prev| if (!Context.recordLessThan(prev, current)) return error.InvalidRecord;
                    prev_old = current;
                    const current_digest = try context.recordDigestWithTexts(&texts, current);
                    old_digest.add(current, current_digest);
                    while (batch_pos < batch_records.len and Context.recordLessThan(batch_records[batch_pos], current)) : (batch_pos += 1) {
                        next_order.add(batch_records[batch_pos], try context.recordDigestWithTexts(&texts, batch_records[batch_pos]));
                        try writeRecord(&writer, output_header, batch_records[batch_pos]);
                    }
                    next_order.add(current, current_digest);
                    try writeRecord(&writer, output_header, current);
                }
                if (old_digest.digest != old_meta.node_digest) return error.InvalidRecord;
                if (old_digest.order_digest != old_meta.node_by_text_order_digest) return error.InvalidRecord;
                while (batch_pos < batch_records.len) : (batch_pos += 1) {
                    next_order.add(batch_records[batch_pos], try context.recordDigestWithTexts(&texts, batch_records[batch_pos]));
                    try writeRecord(&writer, output_header, batch_records[batch_pos]);
                }
                if (next_order.count != next_count) return error.InvalidRecord;
                if (next_order.digest != next_digest) return error.InvalidRecord;
                try writer.flush();
                try writeHeader(context, new_file, .{
                    .node_count = next_count,
                    .node_digest = next_digest,
                    .order_digest = next_order.order_digest,
                    .flags = output_header.flags,
                    .record_len = output_header.record_len,
                    .uniform_kind = output_header.uniform_kind,
                });
                if (shouldSync(context)) try new_file.sync(context.io);
            }
            var publication = MergedBasePublication{
                .context = context,
                .tmp_path = tmp_path,
                .ensure_hash_filter = true,
            };
            try publishMergedBase(&publication);
        }

        pub fn publishRunBatch(
            context: Context,
            old_meta: Meta,
            next_meta: Meta,
            batch_records: []Record,
            batch_digest: u64,
            span_derive_mode: SpanDeriveMode,
        ) !bool {
            if (batch_records.len == 0) return true;
            if (old_meta.nodes == 0) return false;
            const batch_count: u64 = @intCast(batch_records.len);
            if (batch_count > Context.run_max_records) return false;

            var old_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_path, .{ .allow_directory = false });
            defer old_file.close(context.io);
            const old_header = try context.readHeader(old_file);
            const delta_header = try context.readDeltaHeader();

            var manifest = try context.readRunManifest();
            defer manifest.deinit(context.allocator);
            if (manifest.entries.items.len >= Context.manifest_max_entries) return false;
            const validation = try validateCatalog(context, old_meta, old_header, delta_header, manifest.entries.items);
            const expected_old_size = try indexFileSizeForHeader(old_header);
            if (try regularFileSize(context, old_file) != expected_old_size) return error.InvalidRecord;
            try context.ensureBaseHashFilter(old_header);

            std.mem.sort(Record, batch_records, {}, Context.recordLessThanContext);
            const batch_order_digest = try Context.sortedBatchOrderDigest(batch_records);
            if ((old_meta.node_digest ^ batch_digest) != next_meta.node_digest) return error.InvalidRecord;

            const run_path = try runBatchPath(context, old_meta, next_meta, batch_count);
            defer context.allocator.free(run_path);
            if (try context.pathExists(run_path)) return error.AlreadyExists;
            var run_unpublished = true;
            var entries = std.ArrayList(Entry).empty;
            defer entries.deinit(context.allocator);
            var hash_filter: ?[]u8 = null;
            defer if (hash_filter) |filter| context.allocator.free(filter);
            var publication = BatchRunPublication{
                .context = context,
                .validation = validation,
                .original_entries = manifest.entries.items,
                .records = batch_records,
                .batch_digest = batch_digest,
                .batch_order_digest = batch_order_digest,
                .span_derive_mode = span_derive_mode,
                .run_path = run_path,
                .next_entries = &entries,
                .hash_filter = &hash_filter,
                .run_unpublished = &run_unpublished,
            };
            try stageAndPublishPreparedRun(&publication);
            return true;
        }

        pub fn writeDeltaBatch(
            context: Context,
            old_meta: Meta,
            batch_records: []Record,
            batch_digest: u64,
            next_digest: u64,
        ) !bool {
            if (batch_records.len == 0) return true;
            if (old_meta.nodes == 0) return false;
            const batch_count: u64 = @intCast(batch_records.len);
            if (batch_count > Context.delta_max_records) return false;

            var old_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_path, .{ .allow_directory = false });
            defer old_file.close(context.io);
            const old_header = try context.readHeader(old_file);
            const delta_header = try context.readDeltaHeader();
            var manifest = try context.readRunManifest();
            defer manifest.deinit(context.allocator);
            const run_count = manifest.totalNodeCount();
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;
            if (delta_header.node_count + batch_count > Context.delta_max_records) return false;
            _ = try validateCatalog(context, old_meta, old_header, delta_header, manifest.entries.items);
            const expected_old_size = try indexFileSizeForHeader(old_header);
            if (try regularFileSize(context, old_file) != expected_old_size) return error.InvalidRecord;
            try context.ensureBaseHashFilter(old_header);

            var texts = try context.openNodeTextsView();
            defer context.deinitNodeTextsView(&texts);
            std.mem.sort(Record, batch_records, {}, Context.recordLessThanContext);
            if (delta_header.node_count == 0) {
                const last = try context.readRecordWithTexts(old_file, old_header, old_header.node_count - 1, &texts);
                if (!Context.recordLessThan(batch_records[0], last)) return false;
            }
            if (delta_header.node_count == 0) {
                const batch_order_digest = try Context.sortedBatchOrderDigest(batch_records);
                if ((old_meta.node_digest ^ batch_digest) != next_digest) return error.InvalidRecord;
                const tmp_path = try context.tmpPathFor(context.node_by_text_delta_path);
                defer context.allocator.free(tmp_path);
                errdefer std.Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};
                var next_header = Header{ .node_count = 0 };
                {
                    var file = try std.Io.Dir.cwd().createFile(context.io, tmp_path, .{ .read = true, .truncate = true });
                    defer file.close(context.io);
                    next_header = Context.headerForSortedUniqueHashRecords(batch_records, batch_digest, batch_order_digest);
                    var writer = try BufferedWriter.init(context.allocator, context.io, file, try writeBufferCapacity(try indexFileSizeForHeader(next_header)));
                    defer writer.deinit();
                    var header_bytes: [Header.encoded_len]u8 = undefined;
                    next_header.encode(&header_bytes);
                    try writer.append(&header_bytes);
                    for (batch_records) |record| try writeRecord(&writer, next_header, record);
                    try writer.flush();
                    if (shouldSync(context)) try file.sync(context.io);
                }
                try context.renameReplace(tmp_path, context.node_by_text_delta_path);
                context.publishDeltaHeaderCache(next_header);
                return true;
            }

            var delta_records = std.ArrayList(Record).empty;
            defer delta_records.deinit(context.allocator);
            try delta_records.ensureTotalCapacity(context.allocator, @intCast(delta_header.node_count + batch_count));
            var old_delta_digest = Digest{};
            {
                var delta_file = try std.Io.Dir.cwd().openFile(context.io, context.node_by_text_delta_path, .{});
                defer delta_file.close(context.io);
                const expected_delta_size = try indexFileSizeForHeader(delta_header);
                if (try regularFileSize(context, delta_file) != expected_delta_size) return error.InvalidRecord;
                var pos: u64 = 0;
                while (pos < delta_header.node_count) : (pos += 1) {
                    const record = try context.readRecordWithTexts(delta_file, delta_header, pos, &texts);
                    old_delta_digest.add(record, try context.recordDigestWithTexts(&texts, record));
                    try delta_records.append(context.allocator, record);
                }
                if (old_delta_digest.count != delta_header.node_count) return error.InvalidRecord;
                if (old_delta_digest.digest != delta_header.node_digest) return error.InvalidRecord;
                if (old_delta_digest.order_digest != delta_header.order_digest) return error.InvalidRecord;
            }
            for (batch_records) |record| try delta_records.append(context.allocator, record);
            if ((old_meta.node_digest ^ batch_digest) != next_digest) return error.InvalidRecord;
            std.mem.sort(Record, delta_records.items, {}, Context.recordLessThanContext);
            var delta_digest = Digest{};
            var seen_ids = std.AutoHashMap(u64, void).init(context.allocator);
            defer seen_ids.deinit();
            try seen_ids.ensureTotalCapacity(@intCast(delta_records.items.len));
            var previous: ?Record = null;
            for (delta_records.items) |record| {
                if (previous) |prev| if (!Context.recordLessThan(prev, record)) return error.InvalidRecord;
                if ((try seen_ids.getOrPut(record.id)).found_existing) return error.InvalidRecord;
                delta_digest.add(record, try context.recordDigestWithTexts(&texts, record));
                previous = record;
            }
            if (delta_digest.count != delta_header.node_count + batch_count) return error.InvalidRecord;
            if ((old_header.node_digest ^ delta_digest.digest ^ manifest.nodeDigest()) != next_digest) return error.InvalidRecord;

            const tmp_path = try context.tmpPathFor(context.node_by_text_delta_path);
            defer context.allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(context.io, tmp_path) catch {};
            var next_header = Header{ .node_count = 0 };
            {
                var file = try std.Io.Dir.cwd().createFile(context.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(context.io);
                next_header = Context.headerForSortedUniqueHashRecords(delta_records.items, delta_digest.digest, delta_digest.order_digest);
                var writer = try BufferedWriter.init(context.allocator, context.io, file, try writeBufferCapacity(try indexFileSizeForHeader(next_header)));
                defer writer.deinit();
                var header_bytes: [Header.encoded_len]u8 = undefined;
                next_header.encode(&header_bytes);
                try writer.append(&header_bytes);
                for (delta_records.items) |record| try writeRecord(&writer, next_header, record);
                try writer.flush();
                if (shouldSync(context)) try file.sync(context.io);
            }
            try context.renameReplace(tmp_path, context.node_by_text_delta_path);
            context.publishDeltaHeaderCache(next_header);
            return true;
        }
    };
}

const TestPublicationPhase = enum {
    validate_catalog,
    stage_run,
    prepare_manifest,
    publish_manifest,
    clear_delta,
    publish_metadata,
    collect_garbage,
    publish_base,
    clear_runs,
    finish_base,
    discard_unpublished_run,
};

const TestPublication = struct {
    phases: [16]TestPublicationPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPublicationPhase = null,
    catalog_valid: bool = true,
    manifest_may_reference_run: bool = false,
    deleted_runs: u64 = 2,

    fn record(self: *TestPublication, phase: TestPublicationPhase) !void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
        if (self.fail_at == phase) return error.InjectedFailure;
    }

    fn recordCleanup(self: *TestPublication, phase: TestPublicationPhase) void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
    }

    fn recorded(self: *const TestPublication) []const TestPublicationPhase {
        return self.phases[0..self.phase_count];
    }

    fn validateCatalog(self: *TestPublication) !void {
        try self.record(.validate_catalog);
        if (!self.catalog_valid) return error.InvalidRecord;
    }

    fn stageRun(self: *TestPublication) !void {
        try self.record(.stage_run);
    }

    fn prepareManifest(self: *TestPublication) !void {
        try self.record(.prepare_manifest);
    }

    fn markManifestMayReferenceRun(self: *TestPublication) void {
        self.manifest_may_reference_run = true;
    }

    fn publishRunManifest(self: *TestPublication) !void {
        try self.record(.publish_manifest);
    }

    fn discardUnpublishedRun(self: *TestPublication) void {
        if (!self.manifest_may_reference_run) self.recordCleanup(.discard_unpublished_run);
    }

    fn clearDelta(self: *TestPublication) !void {
        try self.record(.clear_delta);
    }

    fn publishMetadata(self: *TestPublication) !void {
        try self.record(.publish_metadata);
    }

    fn collectGarbage(self: *TestPublication) !u64 {
        try self.record(.collect_garbage);
        return self.deleted_runs;
    }

    fn publishBase(self: *TestPublication) !void {
        try self.record(.publish_base);
    }

    fn clearRuns(self: *TestPublication) !u64 {
        try self.record(.clear_runs);
        return self.deleted_runs;
    }

    fn clearRunManifest(self: *TestPublication) !void {
        try self.record(.clear_runs);
    }

    fn finishBase(self: *TestPublication) !void {
        try self.record(.finish_base);
    }
};

test "node text catalog transaction validates catalog invariants before run staging" {
    var publication = TestPublication{ .catalog_valid = false };
    try std.testing.expectError(error.InvalidRecord, stageAndPublishPreparedRun(&publication));
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{.validate_catalog},
        publication.recorded(),
    );
}

test "node text catalog transaction publishes run manifest after run stage" {
    var publication = TestPublication{};
    try stageAndPublishPreparedRun(&publication);
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{ .validate_catalog, .stage_run, .prepare_manifest, .publish_manifest },
        publication.recorded(),
    );
}

test "node text catalog transaction keeps staged run unpublished after stage failure" {
    var publication = TestPublication{ .fail_at = .stage_run };
    try std.testing.expectError(error.InjectedFailure, stageAndPublishPreparedRun(&publication));
    try std.testing.expect(!publication.manifest_may_reference_run);
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{ .validate_catalog, .stage_run, .discard_unpublished_run },
        publication.recorded(),
    );
}

test "node text catalog transaction publishes delta run manifest before clearing delta" {
    var publication = TestPublication{};
    try publishDeltaRun(&publication);
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{
            .validate_catalog,
            .stage_run,
            .prepare_manifest,
            .publish_manifest,
            .clear_delta,
            .publish_metadata,
        },
        publication.recorded(),
    );
}

test "node text catalog transaction updates delta run metadata last" {
    var publication = TestPublication{};
    try publishDeltaRun(&publication);
    try std.testing.expectEqual(TestPublicationPhase.publish_metadata, publication.recorded()[publication.phase_count - 1]);
}

test "node text catalog transaction publishes window metadata before garbage collection" {
    var publication = TestPublication{};
    try std.testing.expectEqual(@as(u64, 2), try publishRunWindow(&publication));
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{ .publish_manifest, .publish_metadata, .collect_garbage },
        publication.recorded(),
    );
}

test "node text catalog transaction publishes compacted base before clearing overlays" {
    var publication = TestPublication{};
    try std.testing.expectEqual(@as(u64, 2), try publishCompactedBase(&publication));
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{ .publish_base, .clear_delta, .clear_runs, .publish_metadata },
        publication.recorded(),
    );
}

test "node text catalog transaction stops overlay cleanup after base publication failure" {
    var publication = TestPublication{ .fail_at = .publish_base };
    try std.testing.expectError(error.InjectedFailure, publishCompactedBase(&publication));
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{.publish_base},
        publication.recorded(),
    );
}

test "node text catalog transaction publishes merged base before overlay reset" {
    var publication = TestPublication{};
    try publishMergedBase(&publication);
    try std.testing.expectEqualSlices(
        TestPublicationPhase,
        &.{ .publish_base, .clear_delta, .clear_runs, .finish_base },
        publication.recorded(),
    );
}
