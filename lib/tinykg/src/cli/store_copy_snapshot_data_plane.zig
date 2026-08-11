/// Backup/restore transaction ownership, canonical path exclusion and snapshot identity validation.
pub fn StoreCopySnapshotDataPlane(comptime Ops: type) type {
    return struct {
        const CliStoreLock = Ops.CliStoreLockValue;
        const ContentDigest = Ops.ContentDigestValue;
        const QueryOutputWriter = Ops.QueryOutputWriterValue;
        const anyPathExists = Ops.anyPathExistsValue;
        const backup_manifest_file = Ops.backup_manifest_fileValue;
        const backup_publish_lock_suffix = Ops.backup_publish_lock_suffixValue;
        const backup_staging_suffix = Ops.backup_staging_suffixValue;
        const backup_transaction_marker_file = Ops.backup_transaction_marker_fileValue;
        const backup_transaction_marker_format = Ops.backup_transaction_marker_formatValue;
        const backup_transaction_marker_legacy_format = Ops.backup_transaction_marker_legacy_formatValue;
        const builtin = Ops.builtinValue;
        const cli_store_lock_suffix = Ops.cli_store_lock_suffixValue;
        const core = Ops.coreValue;
        const existingTinyKgStorePath = Ops.existingTinyKgStorePathValue;
        const fileExists = Ops.fileExistsValue;
        const finalizeContentDigest = Ops.finalizeContentDigestValue;
        const import_transaction_marker_file = Ops.import_transaction_marker_fileValue;
        const markdownFileNameLessThan = Ops.markdownFileNameLessThanValue;
        const renamePath = Ops.renamePathValue;
        const restore_publish_lock_suffix = Ops.restore_publish_lock_suffixValue;
        const restore_staging_suffix = Ops.restore_staging_suffixValue;
        const restore_transaction_marker_file = Ops.restore_transaction_marker_fileValue;
        const restore_transaction_marker_format = Ops.restore_transaction_marker_formatValue;
        const restore_transaction_marker_legacy_format = Ops.restore_transaction_marker_legacy_formatValue;
        const schema = Ops.schemaValue;
        const schema_migration_transaction_marker_file = Ops.schema_migration_transaction_marker_fileValue;
        const std = Ops.stdValue;
        const storage = Ops.storageValue;
        const store_migration_transaction_marker_file = Ops.store_migration_transaction_marker_fileValue;
        const syncExportDirectoryTree = Ops.syncExportDirectoryTreeValue;
        const syncParentDirectory = Ops.syncParentDirectoryValue;
        const writeJsonString = Ops.writeJsonStringValue;
        const writeRecoverableTransactionMarker = Ops.writeRecoverableTransactionMarkerValue;

        pub const BackupStoreResult = struct {
            nodes: u64,
            edges: u64,
            source_store_bytes: u64,
            backup_store_bytes: u64,
            marker_cleanup_pending: bool = false,
        };

        pub const BackupTransactionExpectation = struct {
            canonical_source_path: []const u8,
            nodes: u64,
            edges: u64,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
            source_payload_bytes: u64,
            source_payload_digest: ContentDigest,
        };

        const BackupTransactionMarkerJson = struct {
            format: []const u8,
            canonical_source_path: []const u8,
            nodes: u64,
            edges: u64,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
            source_payload_bytes: u64,
            source_payload_digest: ContentDigest,
            complete: bool,
        };

        const BackupMarkerState = struct {
            complete: bool,
            legacy_format: bool,
        };

        pub fn backupStagingPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, backup_staging_suffix });
        }

        pub fn backupTransactionMarkerPath(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
            return try std.fs.path.join(allocator, &.{ dir_path, backup_transaction_marker_file });
        }

        pub fn writeBackupTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: BackupTransactionExpectation,
            complete: bool,
        ) !void {
            const marker_path = try backupTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
            defer allocator.free(tmp_path);
            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);
            try out.writeAll("{\"format\":");
            try writeJsonString(&out, backup_transaction_marker_format);
            try out.writeAll(",\"canonical_source_path\":");
            try writeJsonString(&out, expected.canonical_source_path);
            try out.print(
                ",\"nodes\":{},\"edges\":{},\"source_store_bytes\":{},\"source_store_digest\":[{},{},{},{}],\"source_payload_bytes\":{},\"source_payload_digest\":[{},{},{},{}],\"complete\":{}}}\n",
                .{
                    expected.nodes,
                    expected.edges,
                    expected.source_store_bytes,
                    expected.source_store_digest[0],
                    expected.source_store_digest[1],
                    expected.source_store_digest[2],
                    expected.source_store_digest[3],
                    expected.source_payload_bytes,
                    expected.source_payload_digest[0],
                    expected.source_payload_digest[1],
                    expected.source_payload_digest[2],
                    expected.source_payload_digest[3],
                    complete,
                },
            );
            writeRecoverableTransactionMarker(allocator, io, tmp_path, marker_path, out.buffer.items) catch |err| switch (err) {
                error.TransactionMarkerConflict => return error.BackupRecoveryConflict,
                else => |e| return e,
            };
        }

        fn readBackupTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: BackupTransactionExpectation,
        ) !?BackupMarkerState {
            const marker_path = try backupTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            return try readBackupTransactionMarkerAtPath(allocator, io, marker_path, expected);
        }

        fn readBackupTransactionMarkerAtPath(
            allocator: std.mem.Allocator,
            io: std.Io,
            marker_path: []const u8,
            expected: BackupTransactionExpectation,
        ) !?BackupMarkerState {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(16 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return null,
                error.StreamTooLong => return error.InvalidRecord,
                else => |e| return e,
            };
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(BackupTransactionMarkerJson, allocator, bytes, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            }) catch return error.InvalidRecord;
            defer parsed.deinit();
            const marker = parsed.value;
            const legacy_format = std.mem.eql(u8, marker.format, backup_transaction_marker_legacy_format);
            if ((!std.mem.eql(u8, marker.format, backup_transaction_marker_format) and !legacy_format) or
                !std.mem.eql(u8, marker.canonical_source_path, expected.canonical_source_path) or
                marker.nodes != expected.nodes or
                marker.edges != expected.edges or
                marker.source_store_bytes != expected.source_store_bytes or
                !std.meta.eql(marker.source_store_digest, expected.source_store_digest) or
                marker.source_payload_bytes != expected.source_payload_bytes or
                !std.meta.eql(marker.source_payload_digest, expected.source_payload_digest))
            {
                return error.BackupRecoveryConflict;
            }
            return .{ .complete = marker.complete, .legacy_format = legacy_format };
        }

        pub fn deleteBackupTransactionMarker(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
            const marker_path = try backupTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            try std.Io.Dir.cwd().deleteFile(io, marker_path);
            try syncParentDirectory(io, marker_path);
        }

        pub fn recoverBackupStaging(
            allocator: std.mem.Allocator,
            io: std.Io,
            staging_path: []const u8,
            expected: BackupTransactionExpectation,
        ) !void {
            if (!try anyPathExists(io, staging_path)) return;
            const stat = try std.Io.Dir.cwd().statFile(io, staging_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.BackupRecoveryConflict;
            var marker = try readBackupTransactionMarker(allocator, io, staging_path, expected);
            if (marker == null) {
                const marker_path = try backupTransactionMarkerPath(allocator, staging_path);
                defer allocator.free(marker_path);
                const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
                defer allocator.free(tmp_path);
                marker = try readBackupTransactionMarkerAtPath(allocator, io, tmp_path, expected);
            }
            _ = marker orelse return error.BackupRecoveryConflict;
            try std.Io.Dir.cwd().deleteTree(io, staging_path);
            try syncParentDirectory(io, staging_path);
        }

        fn backupManifestBytesAlloc(allocator: std.mem.Allocator, expected: BackupTransactionExpectation) ![]u8 {
            return try std.fmt.allocPrint(
                allocator,
                "format=tinykg-backup-v2\nsource={s}\nnodes={}\nedges={}\nsource_store_bytes={}\nsource_store_digest={},{},{},{}\nsource_payload_bytes={}\nsource_payload_digest={},{},{},{}\n",
                .{
                    expected.canonical_source_path,
                    expected.nodes,
                    expected.edges,
                    expected.source_store_bytes,
                    expected.source_store_digest[0],
                    expected.source_store_digest[1],
                    expected.source_store_digest[2],
                    expected.source_store_digest[3],
                    expected.source_payload_bytes,
                    expected.source_payload_digest[0],
                    expected.source_payload_digest[1],
                    expected.source_payload_digest[2],
                    expected.source_payload_digest[3],
                },
            );
        }

        fn validateBackupStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
            expected: BackupTransactionExpectation,
        ) !BackupStoreResult {
            if (!try existingTinyKgStorePath(allocator, io, target_path)) return error.InvalidRecord;
            var backup = try storage.Store.open(allocator, io, target_path);
            defer backup.deinit();
            const backup_stats = try backup.stats();
            if (backup_stats.nodes != expected.nodes or backup_stats.edges != expected.edges) return error.InvalidRecord;
            const manifest_path = try std.fs.path.join(allocator, &.{ target_path, backup_manifest_file });
            defer allocator.free(manifest_path);
            const actual_manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024));
            defer allocator.free(actual_manifest);
            const expected_manifest = try backupManifestBytesAlloc(allocator, expected);
            defer allocator.free(expected_manifest);
            if (!std.mem.eql(u8, actual_manifest, expected_manifest)) return error.BackupRecoveryConflict;
            const payload_identity = try backupPayloadContentIdentity(allocator, io, target_path);
            if (payload_identity.bytes != expected.source_payload_bytes or
                !std.meta.eql(payload_identity.digest, expected.source_payload_digest))
            {
                return error.BackupRecoveryConflict;
            }
            return .{
                .nodes = expected.nodes,
                .edges = expected.edges,
                .source_store_bytes = expected.source_store_bytes,
                .backup_store_bytes = std.math.add(u64, payload_identity.bytes, actual_manifest.len) catch return error.RecordTooLarge,
            };
        }

        fn recoverCompletedBackup(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
            expected: BackupTransactionExpectation,
        ) !?BackupStoreResult {
            if (!try anyPathExists(io, target_path)) return null;
            const stat = try std.Io.Dir.cwd().statFile(io, target_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.AlreadyExists;
            const marker = (try readBackupTransactionMarker(allocator, io, target_path, expected)) orelse
                return null;
            if (!marker.complete) return error.InvalidRecord;
            // The adjacent publication lock protects the target pathname, but an
            // already-published backup is also an ordinary TinyKG store. Coordinate
            // with normal CLI writers, then reread the receipt under that lock before
            // hashing any payload.
            const target_lock = try CliStoreLock.acquire(allocator, io, target_path);
            defer target_lock.deinit();
            const locked_marker = (try readBackupTransactionMarker(allocator, io, target_path, expected)) orelse
                return error.BackupRecoveryConflict;
            if (!locked_marker.complete) return error.InvalidRecord;
            var result = try validateBackupStore(allocator, io, target_path, expected);
            if (locked_marker.legacy_format) {
                try writeBackupTransactionMarker(allocator, io, target_path, expected, true);
            }
            try syncParentDirectory(io, target_path);
            // A complete marker is retained as the request-bound commit receipt; it
            // is excluded from payload identity and future store copies.
            result.marker_cleanup_pending = false;
            return result;
        }

        pub fn backupExpectationForSource(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            canonical_source_path: []const u8,
        ) !BackupTransactionExpectation {
            var store = try storage.Store.open(allocator, io, db_path);
            defer store.deinit();
            const stats_out = try store.stats();
            const source_identity = try storeContentIdentity(allocator, io, db_path);
            const source_manifest_path = try std.fs.path.join(allocator, &.{ db_path, backup_manifest_file });
            defer allocator.free(source_manifest_path);
            const payload_identity = if (try fileExists(io, source_manifest_path))
                try backupPayloadContentIdentity(allocator, io, db_path)
            else
                source_identity;
            return .{
                .canonical_source_path = canonical_source_path,
                .nodes = stats_out.nodes,
                .edges = stats_out.edges,
                .source_store_bytes = source_identity.bytes,
                .source_store_digest = source_identity.digest,
                .source_payload_bytes = payload_identity.bytes,
                .source_payload_digest = payload_identity.digest,
            };
        }

        pub fn validateExistingBackupForSource(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            target_path: []const u8,
        ) !BackupStoreResult {
            const canonical_source_path = try canonicalProspectivePath(allocator, io, db_path);
            defer allocator.free(canonical_source_path);
            const expected = try backupExpectationForSource(allocator, io, db_path, canonical_source_path);
            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, target_path, backup_publish_lock_suffix);
            defer publish_lock.deinit();
            if (try recoverCompletedBackup(allocator, io, target_path, expected)) |recovered| return recovered;
            return try validateBackupStore(allocator, io, target_path, expected);
        }

        pub fn backupStore(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, target_path: []const u8) !BackupStoreResult {
            if (target_path.len == 0) return error.InvalidFileName;
            if (try pathsOverlapForCopyTarget(allocator, io, db_path, target_path)) return error.InvalidFileName;
            const canonical_source_path = try canonicalProspectivePath(allocator, io, db_path);
            defer allocator.free(canonical_source_path);
            const expected = try backupExpectationForSource(allocator, io, db_path, canonical_source_path);
            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, target_path, backup_publish_lock_suffix);
            defer publish_lock.deinit();
            const staging_path = try backupStagingPath(allocator, target_path);
            defer allocator.free(staging_path);
            try recoverBackupStaging(allocator, io, staging_path, expected);
            if (try recoverCompletedBackup(allocator, io, target_path, expected)) |recovered| return recovered;
            if (try anyPathExists(io, target_path)) return error.AlreadyExists;

            try createOwnedDirectory(io, staging_path);
            var staging_owned = true;
            defer if (staging_owned) std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeBackupTransactionMarker(allocator, io, staging_path, expected, false);
            try syncExportDirectoryTree(allocator, io, staging_path);
            try copyDirectoryTreeContents(allocator, io, db_path, staging_path);
            const copied_identity = try storeContentIdentity(allocator, io, staging_path);
            if (copied_identity.bytes != expected.source_store_bytes or
                !std.meta.eql(copied_identity.digest, expected.source_store_digest))
            {
                return error.BackupSourceChanged;
            }
            try writeBackupManifest(allocator, io, staging_path, expected);

            var result = try validateBackupStore(allocator, io, staging_path, expected);
            const source_after_copy = try backupExpectationForSource(allocator, io, db_path, canonical_source_path);
            if (source_after_copy.nodes != expected.nodes or
                source_after_copy.edges != expected.edges or
                source_after_copy.source_store_bytes != expected.source_store_bytes or
                !std.meta.eql(source_after_copy.source_store_digest, expected.source_store_digest) or
                source_after_copy.source_payload_bytes != expected.source_payload_bytes or
                !std.meta.eql(source_after_copy.source_payload_digest, expected.source_payload_digest))
            {
                return error.BackupSourceChanged;
            }
            try writeBackupTransactionMarker(allocator, io, staging_path, expected, true);
            try syncExportDirectoryTree(allocator, io, staging_path);
            if (try anyPathExists(io, target_path)) return error.AlreadyExists;
            try renamePath(io, staging_path, target_path);
            staging_owned = false;
            try syncParentDirectory(io, target_path);
            // Keep the complete receipt so a lost CLI acknowledgment can be retried
            // without mistaking the committed backup for a foreign directory.
            result.marker_cleanup_pending = false;
            return result;
        }

        pub const RestoreTransactionExpectation = struct {
            canonical_source_path: []const u8,
            nodes: u64,
            edges: u64,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
        };

        const RestoreTransactionMarkerJson = struct {
            format: []const u8,
            canonical_source_path: []const u8,
            nodes: u64,
            edges: u64,
            source_store_bytes: u64,
            source_store_digest: ContentDigest,
            complete: bool,
        };

        const RestoreMarkerState = struct {
            complete: bool,
            legacy_format: bool,
        };

        const RestoreStoreLocks = struct {
            first: CliStoreLock,
            second: CliStoreLock,

            fn deinit(self: RestoreStoreLocks) void {
                self.second.deinit();
                self.first.deinit();
            }
        };

        pub fn restoreStagingPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, restore_staging_suffix });
        }

        pub fn restoreTransactionMarkerPath(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
            return try std.fs.path.join(allocator, &.{ dir_path, restore_transaction_marker_file });
        }

        pub fn writeRestoreTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: RestoreTransactionExpectation,
            complete: bool,
        ) !void {
            const marker_path = try restoreTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
            defer allocator.free(tmp_path);
            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);
            try out.writeAll("{\"format\":");
            try writeJsonString(&out, restore_transaction_marker_format);
            try out.writeAll(",\"canonical_source_path\":");
            try writeJsonString(&out, expected.canonical_source_path);
            try out.print(
                ",\"nodes\":{},\"edges\":{},\"source_store_bytes\":{},\"source_store_digest\":[{},{},{},{}],\"complete\":{}}}\n",
                .{
                    expected.nodes,
                    expected.edges,
                    expected.source_store_bytes,
                    expected.source_store_digest[0],
                    expected.source_store_digest[1],
                    expected.source_store_digest[2],
                    expected.source_store_digest[3],
                    complete,
                },
            );
            writeRecoverableTransactionMarker(allocator, io, tmp_path, marker_path, out.buffer.items) catch |err| switch (err) {
                error.TransactionMarkerConflict => return error.RestoreRecoveryConflict,
                else => |e| return e,
            };
        }

        fn readRestoreTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: RestoreTransactionExpectation,
        ) !?RestoreMarkerState {
            const marker_path = try restoreTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            return try readRestoreTransactionMarkerAtPath(allocator, io, marker_path, expected);
        }

        fn readRestoreTransactionMarkerAtPath(
            allocator: std.mem.Allocator,
            io: std.Io,
            marker_path: []const u8,
            expected: RestoreTransactionExpectation,
        ) !?RestoreMarkerState {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(16 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return null,
                error.StreamTooLong => return error.InvalidRecord,
                else => |e| return e,
            };
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(RestoreTransactionMarkerJson, allocator, bytes, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            }) catch return error.InvalidRecord;
            defer parsed.deinit();
            const marker = parsed.value;
            const legacy_format = std.mem.eql(u8, marker.format, restore_transaction_marker_legacy_format);
            if ((!std.mem.eql(u8, marker.format, restore_transaction_marker_format) and !legacy_format) or
                !std.mem.eql(u8, marker.canonical_source_path, expected.canonical_source_path) or
                marker.nodes != expected.nodes or
                marker.edges != expected.edges or
                marker.source_store_bytes != expected.source_store_bytes or
                !std.meta.eql(marker.source_store_digest, expected.source_store_digest))
            {
                return error.RestoreRecoveryConflict;
            }
            return .{ .complete = marker.complete, .legacy_format = legacy_format };
        }

        fn restoreMarkerPresent(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !bool {
            const marker_path = try restoreTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const stat = std.Io.Dir.cwd().statFile(io, marker_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return false,
                else => |e| return e,
            };
            if (stat.kind != .file) return error.RestoreRecoveryConflict;
            return true;
        }

        pub fn restoreExpectationForSource(
            allocator: std.mem.Allocator,
            io: std.Io,
            source_path: []const u8,
            canonical_source_path: []const u8,
        ) !RestoreTransactionExpectation {
            var source = try storage.Store.open(allocator, io, source_path);
            defer source.deinit();
            const stats_out = try source.stats();
            const identity = try storeContentIdentity(allocator, io, source_path);
            return .{
                .canonical_source_path = canonical_source_path,
                .nodes = stats_out.nodes,
                .edges = stats_out.edges,
                .source_store_bytes = identity.bytes,
                .source_store_digest = identity.digest,
            };
        }

        fn restoreExpectationsEqual(a: RestoreTransactionExpectation, b: RestoreTransactionExpectation) bool {
            return std.mem.eql(u8, a.canonical_source_path, b.canonical_source_path) and
                a.nodes == b.nodes and
                a.edges == b.edges and
                a.source_store_bytes == b.source_store_bytes and
                std.meta.eql(a.source_store_digest, b.source_store_digest);
        }

        fn acquireRestoreStoreLocks(
            allocator: std.mem.Allocator,
            io: std.Io,
            canonical_source_path: []const u8,
            canonical_target_path: []const u8,
        ) !RestoreStoreLocks {
            const source_first = std.mem.lessThan(u8, canonical_source_path, canonical_target_path);
            const first_path = if (source_first) canonical_source_path else canonical_target_path;
            const second_path = if (source_first) canonical_target_path else canonical_source_path;
            const first = try CliStoreLock.acquire(allocator, io, first_path);
            errdefer first.deinit();
            const second = try CliStoreLock.acquire(allocator, io, second_path);
            return .{ .first = first, .second = second };
        }

        pub fn recoverRestoreStaging(
            allocator: std.mem.Allocator,
            io: std.Io,
            staging_path: []const u8,
            expected: RestoreTransactionExpectation,
        ) !void {
            if (!try anyPathExists(io, staging_path)) return;
            const stat = try std.Io.Dir.cwd().statFile(io, staging_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.RestoreRecoveryConflict;
            var marker = try readRestoreTransactionMarker(allocator, io, staging_path, expected);
            if (marker == null) {
                const marker_path = try restoreTransactionMarkerPath(allocator, staging_path);
                defer allocator.free(marker_path);
                const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
                defer allocator.free(tmp_path);
                marker = try readRestoreTransactionMarkerAtPath(allocator, io, tmp_path, expected);
            }
            _ = marker orelse return error.RestoreRecoveryConflict;
            try std.Io.Dir.cwd().deleteTree(io, staging_path);
            try syncParentDirectory(io, staging_path);
        }

        fn validateRestoredStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
            expected: RestoreTransactionExpectation,
        ) !BackupStoreResult {
            const identity = try storeContentIdentity(allocator, io, target_path);
            if (identity.bytes != expected.source_store_bytes or
                !std.meta.eql(identity.digest, expected.source_store_digest))
            {
                return error.RestoreRecoveryConflict;
            }
            if (!try existingTinyKgStorePath(allocator, io, target_path)) return error.InvalidRecord;
            var restored = try storage.Store.open(allocator, io, target_path);
            defer restored.deinit();
            const restored_stats = try restored.stats();
            if (restored_stats.nodes != expected.nodes or restored_stats.edges != expected.edges) return error.InvalidRecord;
            return .{
                .nodes = expected.nodes,
                .edges = expected.edges,
                .source_store_bytes = expected.source_store_bytes,
                .backup_store_bytes = identity.bytes,
            };
        }

        fn recoverCompletedRestore(
            allocator: std.mem.Allocator,
            io: std.Io,
            source_path: []const u8,
            target_path: []const u8,
            canonical_source_path: []const u8,
            canonical_target_path: []const u8,
        ) !BackupStoreResult {
            if (!try restoreMarkerPresent(allocator, io, target_path)) return error.AlreadyExists;
            const store_locks = try acquireRestoreStoreLocks(allocator, io, canonical_source_path, canonical_target_path);
            defer store_locks.deinit();
            const expected = try restoreExpectationForSource(allocator, io, source_path, canonical_source_path);
            const marker = (try readRestoreTransactionMarker(allocator, io, target_path, expected)) orelse
                return error.RestoreRecoveryConflict;
            if (!marker.complete) return error.InvalidRecord;
            var result = try validateRestoredStore(allocator, io, target_path, expected);
            if (marker.legacy_format) {
                try writeRestoreTransactionMarker(allocator, io, target_path, expected, true);
            }
            try syncParentDirectory(io, target_path);
            // Retain the complete marker as an authenticated commit receipt.
            result.marker_cleanup_pending = false;
            return result;
        }

        pub fn restoreBackup(allocator: std.mem.Allocator, io: std.Io, backup_path: []const u8, target_path: []const u8) !BackupStoreResult {
            if (backup_path.len == 0 or target_path.len == 0) return error.InvalidFileName;
            if (try pathsOverlapForCopyTarget(allocator, io, backup_path, target_path)) return error.InvalidFileName;
            const canonical_source_path = try canonicalProspectivePath(allocator, io, backup_path);
            defer allocator.free(canonical_source_path);
            const canonical_target_path = try canonicalProspectivePath(allocator, io, target_path);
            defer allocator.free(canonical_target_path);
            const publish_lock = try CliStoreLock.acquireAdjacent(allocator, io, canonical_target_path, restore_publish_lock_suffix);
            defer publish_lock.deinit();
            if (try anyPathExists(io, canonical_target_path)) {
                const stat = try std.Io.Dir.cwd().statFile(io, canonical_target_path, .{ .follow_symlinks = false });
                if (stat.kind != .directory) return error.AlreadyExists;
                return try recoverCompletedRestore(
                    allocator,
                    io,
                    canonical_source_path,
                    canonical_target_path,
                    canonical_source_path,
                    canonical_target_path,
                );
            }

            const source_lock = try CliStoreLock.acquire(allocator, io, canonical_source_path);
            defer source_lock.deinit();
            const expected = try restoreExpectationForSource(allocator, io, canonical_source_path, canonical_source_path);
            const staging_path = try restoreStagingPath(allocator, canonical_target_path);
            defer allocator.free(staging_path);
            try recoverRestoreStaging(allocator, io, staging_path, expected);
            if (try anyPathExists(io, canonical_target_path)) return error.AlreadyExists;

            try createOwnedDirectory(io, staging_path);
            var staging_owned = true;
            defer if (staging_owned) std.Io.Dir.cwd().deleteTree(io, staging_path) catch {};
            try writeRestoreTransactionMarker(allocator, io, staging_path, expected, false);
            try syncExportDirectoryTree(allocator, io, staging_path);
            try copyDirectoryTreeContents(allocator, io, canonical_source_path, staging_path);
            var result = try validateRestoredStore(allocator, io, staging_path, expected);
            const source_after_copy = try restoreExpectationForSource(allocator, io, canonical_source_path, canonical_source_path);
            if (!restoreExpectationsEqual(source_after_copy, expected)) return error.RestoreSourceChanged;
            try writeRestoreTransactionMarker(allocator, io, staging_path, expected, true);
            try syncExportDirectoryTree(allocator, io, staging_path);
            if (try anyPathExists(io, canonical_target_path)) return error.AlreadyExists;
            try renamePath(io, staging_path, canonical_target_path);
            staging_owned = false;
            try syncParentDirectory(io, canonical_target_path);
            // Receipt retention closes the rename-committed / stdout-lost retry gap.
            result.marker_cleanup_pending = false;
            return result;
        }

        /// Canonicalize a path that may not exist yet. `realPathFileAlloc` resolves
        /// symlinks in the nearest existing ancestor; the remaining suffix is then
        /// normalized lexically. This closes `./`, `..`, and symlink-parent aliases
        /// before copy/migration code creates a directory or installs an errdefer that
        /// could recursively delete the wrong tree.
        pub fn canonicalProspectivePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
            if (path.len == 0) return error.InvalidFileName;
            var probe = path;
            while (true) {
                const canonical_ancestor = std.Io.Dir.cwd().realPathFileAlloc(io, probe, allocator) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => null,
                    else => |e| return e,
                };
                if (canonical_ancestor) |ancestor| {
                    defer allocator.free(ancestor);
                    if (probe.len == path.len) return try allocator.dupe(u8, ancestor);
                    const raw_suffix = if (std.mem.eql(u8, probe, ".")) path else path[probe.len..];
                    var suffix_start: usize = 0;
                    while (suffix_start < raw_suffix.len and (raw_suffix[suffix_start] == '/' or raw_suffix[suffix_start] == '\\')) : (suffix_start += 1) {}
                    const suffix = raw_suffix[suffix_start..];
                    return try std.fs.path.resolve(allocator, &.{ ancestor, suffix });
                }
                probe = std.fs.path.dirname(probe) orelse ".";
            }
        }

        pub fn canonicalPathsEqual(a: []const u8, b: []const u8) bool {
            const normalized_a = trimTrailingPathSeparators(a);
            const normalized_b = trimTrailingPathSeparators(b);
            return if (builtin.os.tag == .windows)
                std.ascii.eqlIgnoreCase(normalized_a, normalized_b)
            else
                std.mem.eql(u8, normalized_a, normalized_b);
        }

        fn trimTrailingPathSeparators(path: []const u8) []const u8 {
            var end = path.len;
            while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) {
                if (builtin.os.tag == .windows and end == 3 and path[1] == ':') break;
                end -= 1;
            }
            return path[0..end];
        }

        pub fn canonicalPathContains(parent: []const u8, child: []const u8) bool {
            if (child.len <= parent.len) return false;
            const prefix_matches = if (builtin.os.tag == .windows)
                std.ascii.eqlIgnoreCase(parent, child[0..parent.len])
            else
                std.mem.eql(u8, parent, child[0..parent.len]);
            if (!prefix_matches) return false;
            // Canonical filesystem roots already end in a separator (`/`, `C:\\`,
            // or a UNC share root). Requiring another separator after that prefix
            // would incorrectly claim that the root contains no descendants.
            if (parent[parent.len - 1] == '/' or parent[parent.len - 1] == '\\') return true;
            return child[parent.len] == '/' or child[parent.len] == '\\';
        }

        pub fn pathsOverlap(allocator: std.mem.Allocator, io: std.Io, a: []const u8, b: []const u8) !bool {
            const canonical_a = try canonicalProspectivePath(allocator, io, a);
            defer allocator.free(canonical_a);
            const canonical_b = try canonicalProspectivePath(allocator, io, b);
            defer allocator.free(canonical_b);
            return canonicalPathsEqual(canonical_a, canonical_b) or
                canonicalPathContains(canonical_a, canonical_b) or
                canonicalPathContains(canonical_b, canonical_a);
        }

        pub fn pathsOverlapForCopyTarget(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, target_path: []const u8) !bool {
            return try pathsOverlap(allocator, io, source_path, target_path);
        }

        pub fn createOwnedDirectory(io: std.Io, path: []const u8) !void {
            if (path.len == 0) return error.InvalidFileName;
            const status = try std.Io.Dir.cwd().createDirPathStatus(io, path, .default_dir);
            if (status == .existed) return error.AlreadyExists;
        }

        /// Root-level transaction controls are not logical store payload.  Complete
        /// markers may persist as commit receipts; incomplete markers and temporary
        /// files remain recovery state.  Neither class participates in content
        /// identity, backup payloads, recursive copies, or user-visible store bytes.
        fn isStoreControlEntry(name: []const u8) bool {
            return std.mem.eql(u8, name, cli_store_lock_suffix) or
                std.mem.eql(u8, name, backup_transaction_marker_file) or
                std.mem.eql(u8, name, import_transaction_marker_file) or
                std.mem.eql(u8, name, restore_transaction_marker_file) or
                std.mem.eql(u8, name, store_migration_transaction_marker_file) or
                std.mem.eql(u8, name, schema_migration_transaction_marker_file) or
                std.mem.eql(u8, name, backup_transaction_marker_file ++ ".tmp") or
                std.mem.eql(u8, name, import_transaction_marker_file ++ ".tmp") or
                std.mem.eql(u8, name, restore_transaction_marker_file ++ ".tmp") or
                std.mem.eql(u8, name, store_migration_transaction_marker_file ++ ".tmp") or
                std.mem.eql(u8, name, schema_migration_transaction_marker_file ++ ".tmp");
        }

        fn copyDirectoryTreeContentsAtDepth(
            allocator: std.mem.Allocator,
            io: std.Io,
            source_path: []const u8,
            target_path: []const u8,
            is_root: bool,
        ) !void {
            var source_dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
            defer source_dir.close(io);
            var iter = source_dir.iterate();
            while (try iter.next(io)) |entry| {
                if (is_root and isStoreControlEntry(entry.name)) continue;
                const child_source_path = try std.fs.path.join(allocator, &.{ source_path, entry.name });
                defer allocator.free(child_source_path);
                const child_target_path = try std.fs.path.join(allocator, &.{ target_path, entry.name });
                defer allocator.free(child_target_path);
                switch (entry.kind) {
                    .file => try std.Io.Dir.copyFile(std.Io.Dir.cwd(), child_source_path, std.Io.Dir.cwd(), child_target_path, io, .{
                        .replace = false,
                        .make_path = true,
                    }),
                    .directory => {
                        try createOwnedDirectory(io, child_target_path);
                        errdefer std.Io.Dir.cwd().deleteTree(io, child_target_path) catch {};
                        try copyDirectoryTreeContentsAtDepth(allocator, io, child_source_path, child_target_path, false);
                    },
                    else => return core.Error.Unsupported,
                }
            }
        }

        pub fn copyDirectoryTreeContents(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, target_path: []const u8) !void {
            return copyDirectoryTreeContentsAtDepth(allocator, io, source_path, target_path, true);
        }

        pub fn copyDirectoryTree(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, target_path: []const u8) !void {
            // Every recursive destination is claimed exclusively. In particular, a
            // target appearing after backup/restore preflight is never treated as our
            // partial copy and therefore never removed by this function's cleanup.
            try createOwnedDirectory(io, target_path);
            errdefer std.Io.Dir.cwd().deleteTree(io, target_path) catch {};
            try copyDirectoryTreeContents(allocator, io, source_path, target_path);
        }

        fn writeBackupManifest(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
            expected: BackupTransactionExpectation,
        ) !void {
            const manifest_path = try std.fs.path.join(allocator, &.{ target_path, backup_manifest_file });
            defer allocator.free(manifest_path);
            const manifest = try backupManifestBytesAlloc(allocator, expected);
            defer allocator.free(manifest);
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = manifest_path,
                .data = manifest,
                .flags = .{ .truncate = true },
            });
        }

        pub const SchemaEdgeEndpointCheck = struct {
            src_kind: core.NodeKind,
            dst_kind: core.NodeKind,
            violates: bool,
        };

        pub fn validateSchemaEdgeEndpoints(store: storage.Store, registry: schema.Registry, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !void {
            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            const check = try schemaEdgeEndpointCheck(&node_view, registry, src, rel, dst);
            if (check.violates) return error.SchemaEndpointViolation;
        }

        pub fn schemaEdgeEndpointCheck(
            node_view: *storage.Store.NodeRecordView,
            registry: schema.Registry,
            src: core.NodeId,
            rel: core.RelKind,
            dst: core.NodeId,
        ) !SchemaEdgeEndpointCheck {
            const rule = registry.relationEndpointRuleById(@intFromEnum(rel)) orelse return error.UnknownRelationKind;
            const src_ref = (try node_view.readNodeRefById(src)) orelse return core.Error.NotFound;
            const dst_ref = (try node_view.readNodeRefById(dst)) orelse return core.Error.NotFound;
            if (!registry.hasNodeTypeId(@intFromEnum(src_ref.kind))) return error.UnknownNodeKind;
            if (!registry.hasNodeTypeId(@intFromEnum(dst_ref.kind))) return error.UnknownNodeKind;
            const bad_src = if (rule.src) |src_set| !src_set.containsNodeKind(src_ref.kind) else false;
            const bad_dst = if (rule.dst) |dst_set| !dst_set.containsNodeKind(dst_ref.kind) else false;
            return .{
                .src_kind = src_ref.kind,
                .dst_kind = dst_ref.kind,
                .violates = bad_src or bad_dst,
            };
        }

        pub const StoreContentIdentity = struct {
            bytes: u64 = 0,
            digest: ContentDigest,
        };

        pub fn hashLengthPrefixed(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
            var len_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_bytes, bytes.len, .little);
            hasher.update(&len_bytes);
            hasher.update(bytes);
        }

        pub fn hashStoreFile(
            io: std.Io,
            file_path: []const u8,
            relative_path: []const u8,
            size: u64,
            hasher: *std.crypto.hash.sha2.Sha256,
        ) !void {
            hasher.update("file\x00");
            hashLengthPrefixed(hasher, relative_path);
            var size_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &size_bytes, size, .little);
            hasher.update(&size_bytes);
            var file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .allow_directory = false });
            defer file.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < size) {
                const remaining = size - offset;
                const take: usize = @intCast(@min(remaining, buffer.len));
                if (try file.readPositionalAll(io, buffer[0..take], offset) != take) return error.InvalidRecord;
                hasher.update(buffer[0..take]);
                offset += @intCast(take);
            }
        }

        const StoreContentIdentityView = enum {
            complete,
            backup_payload,
        };

        fn skipStoreContentIdentityEntry(view: StoreContentIdentityView, relative_path: []const u8, name: []const u8) bool {
            if (relative_path.len == 0 and isStoreControlEntry(name)) return true;
            return view == .backup_payload and relative_path.len == 0 and std.mem.eql(u8, name, backup_manifest_file);
        }

        fn hashStoreDirectory(
            allocator: std.mem.Allocator,
            io: std.Io,
            root_path: []const u8,
            relative_path: []const u8,
            hasher: *std.crypto.hash.sha2.Sha256,
            total_bytes: *u64,
            view: StoreContentIdentityView,
        ) !void {
            const dir_path = if (relative_path.len == 0)
                try allocator.dupe(u8, root_path)
            else
                try std.fs.path.join(allocator, &.{ root_path, relative_path });
            defer allocator.free(dir_path);
            var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            var names = std.ArrayList([]u8).empty;
            defer {
                for (names.items) |name| allocator.free(name);
                names.deinit(allocator);
            }
            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (skipStoreContentIdentityEntry(view, relative_path, entry.name)) continue;
                const owned_name = try allocator.dupe(u8, entry.name);
                errdefer allocator.free(owned_name);
                try names.append(allocator, owned_name);
            }
            std.mem.sort([]u8, names.items, {}, markdownFileNameLessThan);
            for (names.items) |name| {
                const child_relative = if (relative_path.len == 0)
                    try allocator.dupe(u8, name)
                else
                    try std.fs.path.join(allocator, &.{ relative_path, name });
                defer allocator.free(child_relative);
                const child_path = try std.fs.path.join(allocator, &.{ root_path, child_relative });
                defer allocator.free(child_path);
                const stat = try std.Io.Dir.cwd().statFile(io, child_path, .{ .follow_symlinks = false });
                switch (stat.kind) {
                    .file => {
                        total_bytes.* = std.math.add(u64, total_bytes.*, stat.size) catch return error.RecordTooLarge;
                        try hashStoreFile(io, child_path, child_relative, stat.size, hasher);
                    },
                    .directory => {
                        hasher.update("dir\x00");
                        hashLengthPrefixed(hasher, child_relative);
                        try hashStoreDirectory(allocator, io, root_path, child_relative, hasher, total_bytes, view);
                    },
                    else => return core.Error.Unsupported,
                }
            }
        }

        pub fn storeContentIdentity(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !StoreContentIdentity {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var total_bytes: u64 = 0;
            try hashStoreDirectory(allocator, io, db_path, "", &hasher, &total_bytes, .complete);
            return .{ .bytes = total_bytes, .digest = finalizeContentDigest(&hasher) };
        }

        fn backupPayloadContentIdentity(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !StoreContentIdentity {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var total_bytes: u64 = 0;
            try hashStoreDirectory(allocator, io, db_path, "", &hasher, &total_bytes, .backup_payload);
            return .{ .bytes = total_bytes, .digest = finalizeContentDigest(&hasher) };
        }

        fn storeDirBytesAtDepth(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, is_root: bool) !u64 {
            var dir = try std.Io.Dir.cwd().openDir(io, db_path, .{ .iterate = true });
            defer dir.close(io);
            var iter = dir.iterate();
            var total: u64 = 0;
            while (try iter.next(io)) |entry| {
                if (is_root and isStoreControlEntry(entry.name)) continue;
                const full_path = try std.fs.path.join(allocator, &.{ db_path, entry.name });
                defer allocator.free(full_path);
                switch (entry.kind) {
                    .file => {
                        const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{});
                        total = std.math.add(u64, total, stat.size) catch return error.RecordTooLarge;
                    },
                    .directory => {
                        const child_total = try storeDirBytesAtDepth(allocator, io, full_path, false);
                        total = std.math.add(u64, total, child_total) catch return error.RecordTooLarge;
                    },
                    else => {},
                }
            }
            return total;
        }

        pub fn storeDirBytes(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !u64 {
            return storeDirBytesAtDepth(allocator, io, db_path, true);
        }

        test "store dir bytes recursively includes segment subdirectories" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
            defer std.testing.allocator.free(db_path);
            const segments_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "edge_segments", "0001" });
            defer std.testing.allocator.free(segments_path);
            const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "manifest.json" });
            defer std.testing.allocator.free(manifest_path);
            const csr_path = try std.fs.path.join(std.testing.allocator, &.{ segments_path, "edge_fwd.csr" });
            defer std.testing.allocator.free(csr_path);

            try std.Io.Dir.cwd().createDirPath(std.testing.io, segments_path);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = "12345" });
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = csr_path, .data = "1234567" });
            try std.testing.expectEqual(@as(u64, 12), try storeDirBytes(std.testing.allocator, std.testing.io, db_path));
        }

        fn peakRssBytes() !u64 {
            if (!builtin.link_libc) return 0;
            return switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos => peakRssFromGetrusage(.bytes),
                .linux, .freebsd, .openbsd, .netbsd, .dragonfly => peakRssFromGetrusage(.kib),
                else => 0,
            };
        }

        fn currentRssBytes() !u64 {
            if (!builtin.link_libc) return 0;
            return switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos => currentRssFromDarwinTaskInfo(),
                .linux => currentRssFromLinuxStatm(),
                else => 0,
            };
        }

        fn currentFootprintBytes() !u64 {
            return switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos => currentFootprintFromDarwinTaskInfo(),
                else => 0,
            };
        }

        const RssUnit = enum { bytes, kib };

        fn peakRssFromGetrusage(unit: RssUnit) !u64 {
            var usage: std.c.rusage = undefined;
            if (std.c.getrusage(0, &usage) != 0) return error.SystemResourceUnavailable;
            if (usage.maxrss <= 0) return 0;
            const maxrss: u64 = @intCast(usage.maxrss);
            return switch (unit) {
                .bytes => maxrss,
                .kib => std.math.mul(u64, maxrss, 1024) catch return error.RecordTooLarge,
            };
        }

        fn currentRssFromDarwinTaskInfo() !u64 {
            const task_port = std.c.mach_task_self();
            if (task_port == std.c.TASK.NULL) return 0;
            var info_count = std.c.TASK.VM.INFO_COUNT;
            var vm_info: std.c.task_vm_info_data_t = undefined;
            const rc = std.c.task_info(
                task_port,
                std.c.TASK.VM.INFO,
                @as(std.c.task_info_t, @ptrCast(&vm_info)),
                &info_count,
            );
            if (rc != 0) return error.SystemResourceUnavailable;
            return @intCast(vm_info.resident_size);
        }

        fn currentFootprintFromDarwinTaskInfo() !u64 {
            const task_port = std.c.mach_task_self();
            if (task_port == std.c.TASK.NULL) return 0;
            var info_count = std.c.TASK.VM.INFO_COUNT;
            var vm_info: std.c.task_vm_info_data_t = undefined;
            const rc = std.c.task_info(
                task_port,
                std.c.TASK.VM.INFO,
                @as(std.c.task_info_t, @ptrCast(&vm_info)),
                &info_count,
            );
            if (rc != 0) return error.SystemResourceUnavailable;
            return @intCast(vm_info.phys_footprint);
        }

        fn currentRssFromLinuxStatm() !u64 {
            const file = std.c.fopen("/proc/self/statm", "rb") orelse return 0;
            defer _ = std.c.fclose(file);

            var buf: [128]u8 = undefined;
            const n = std.c.fread(buf[0..].ptr, 1, buf.len, file);
            var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
            _ = it.next() orelse return error.InvalidRecord;
            const resident_pages_text = it.next() orelse return error.InvalidRecord;
            const resident_pages = std.fmt.parseInt(u64, resident_pages_text, 10) catch return error.InvalidRecord;
            return std.math.mul(u64, resident_pages, std.heap.pageSize()) catch return error.RecordTooLarge;
        }

        test "store copy snapshot canonical paths reject sibling prefix overlap" {
            const child = try std.fmt.allocPrint(std.testing.allocator, "kg{c}child", .{std.fs.path.sep});
            defer std.testing.allocator.free(child);
            const trailing = try std.fmt.allocPrint(std.testing.allocator, "kg{c}", .{std.fs.path.sep});
            defer std.testing.allocator.free(trailing);
            try std.testing.expect(canonicalPathContains("kg", child));
            try std.testing.expect(!canonicalPathContains("kg", "kg-other"));
            try std.testing.expect(canonicalPathsEqual(trailing, "kg"));
        }

        test "store copy snapshot identity excludes only owned control entries" {
            try std.testing.expect(skipStoreContentIdentityEntry(.complete, "", cli_store_lock_suffix));
            try std.testing.expect(skipStoreContentIdentityEntry(.backup_payload, "", backup_transaction_marker_file));
            try std.testing.expect(!skipStoreContentIdentityEntry(.complete, "nested", "events.bin"));
        }
    };
}
