/// Store manifests, external migration spools and crash-safe import/export publication primitives.
pub fn StoreMigrationFoundation(comptime Ops: type) type {
    return struct {
        const BackupTransactionExpectation = Ops.BackupTransactionExpectationValue;
        const CliStoreLock = Ops.CliStoreLockValue;
        const MigrationPropertyBatch = Ops.MigrationPropertyBatchValue;
        const MigrationPropertyLookup = Ops.MigrationPropertyLookupValue;
        const ParsedSchemaMigrateArgs = Ops.ParsedSchemaMigrateArgsValue;
        const QueryOutputWriter = Ops.QueryOutputWriterValue;
        const RestoreTransactionExpectation = Ops.RestoreTransactionExpectationValue;
        const SchemaFileJson = Ops.SchemaFileJsonValue;
        const SchemaMigrationTransactionExpectation = Ops.SchemaMigrationTransactionExpectationValue;
        const StoreMigrationV2TransactionExpectation = Ops.StoreMigrationV2TransactionExpectationValue;
        const agent = Ops.agentValue;
        const anyPathExists = Ops.anyPathExistsValue;
        const backupTransactionMarkerPath = Ops.backupTransactionMarkerPathValue;
        const builtin = Ops.builtinValue;
        const catalog_mod = Ops.catalog_modValue;
        const core = Ops.coreValue;
        const createOwnedDirectory = Ops.createOwnedDirectoryValue;
        const dag = Ops.dagValue;
        const existingTinyKgStorePath = Ops.existingTinyKgStorePathValue;
        const export_backup_suffix = Ops.export_backup_suffixValue;
        const export_temp_nonce = Ops.export_temp_nonceValue;
        const export_transaction_marker_file = Ops.export_transaction_marker_fileValue;
        const export_transaction_marker_magic = Ops.export_transaction_marker_magicValue;
        const import_staging_suffix = Ops.import_staging_suffixValue;
        const import_transaction_marker_file = Ops.import_transaction_marker_fileValue;
        const import_transaction_marker_format = Ops.import_transaction_marker_formatValue;
        const import_transaction_marker_legacy_format = Ops.import_transaction_marker_legacy_formatValue;
        const parseSchemaFileDocument = Ops.parseSchemaFileDocumentValue;
        const pathsOverlapForCopyTarget = Ops.pathsOverlapForCopyTargetValue;
        const persistentNowNs = Ops.persistentNowNsValue;
        const recoverBackupStaging = Ops.recoverBackupStagingValue;
        const recoverRestoreStaging = Ops.recoverRestoreStagingValue;
        const recoverSchemaMigrationStaging = Ops.recoverSchemaMigrationStagingValue;
        const recoverStoreMigrationV2Staging = Ops.recoverStoreMigrationV2StagingValue;
        const restoreTransactionMarkerPath = Ops.restoreTransactionMarkerPathValue;
        const run = Ops.runValue;
        const schema = Ops.schemaValue;
        const schemaMigrationTransactionMarkerPath = Ops.schemaMigrationTransactionMarkerPathValue;
        const std = Ops.stdValue;
        const storage = Ops.storageValue;
        const storeContentIdentity = Ops.storeContentIdentityValue;
        const storeMigrationV2TransactionMarkerPath = Ops.storeMigrationV2TransactionMarkerPathValue;
        const task = Ops.taskValue;
        const text_search = Ops.text_searchValue;
        const version = Ops.versionValue;
        const writeBackupTransactionMarker = Ops.writeBackupTransactionMarkerValue;
        const writeJsonString = Ops.writeJsonStringValue;
        const writeRestoreTransactionMarker = Ops.writeRestoreTransactionMarkerValue;
        const writeSchemaMigrationTransactionMarker = Ops.writeSchemaMigrationTransactionMarkerValue;
        const writeStoreMigrationV2TransactionMarker = Ops.writeStoreMigrationV2TransactionMarkerValue;

        const store_manifest_dir = ".tinykg";
        const store_manifest_file = "store-manifest.json";
        const current_storage_format_version = version.storage_format_version;
        pub const current_schema_version = version.schema_version;
        pub const current_store_manifest_version = 1;

        const StoreManifestWriteOptions = struct {
            profiles: []const u8 = "",
            migration_name: []const u8 = "",
            source_path: []const u8 = "",
            schema_version: u32 = current_schema_version,
        };

        pub const StoreManifestSummary = struct {
            status: []const u8,
            store_manifest_version: []const u8 = "",
            storage_format_version: []const u8,
            schema_version: []const u8,
            enabled_profiles: []const u8,
            migration_name: []const u8,
            migration_source: []const u8,
            owned_store_manifest_version: ?[]u8 = null,
            owned_storage_format_version: ?[]u8 = null,
            owned_schema_version: ?[]u8 = null,
            owned_enabled_profiles: ?[]u8 = null,
            owned_migration_name: ?[]u8 = null,
            owned_migration_source: ?[]u8 = null,

            pub fn deinit(self: StoreManifestSummary, allocator: std.mem.Allocator) void {
                if (self.owned_store_manifest_version) |value| allocator.free(value);
                if (self.owned_storage_format_version) |value| allocator.free(value);
                if (self.owned_schema_version) |value| allocator.free(value);
                if (self.owned_enabled_profiles) |value| allocator.free(value);
                if (self.owned_migration_name) |value| allocator.free(value);
                if (self.owned_migration_source) |value| allocator.free(value);
            }
        };

        const StoreManifestJson = struct {
            store_manifest_version: ?u32 = null,
            storage_format_version: ?u32 = null,
            schema: ?struct {
                schema_version: ?u32 = null,
                enabled_profiles: ?[]const []const u8 = null,
            } = null,
            migration: ?struct {
                name: ?[]const u8 = null,
                source: ?[]const u8 = null,
            } = null,
        };

        pub fn storeManifestPath(allocator: std.mem.Allocator, db_path: []const u8) ![]u8 {
            return try std.fs.path.join(allocator, &.{ db_path, store_manifest_dir, store_manifest_file });
        }

        pub fn writeStoreManifest(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, options: StoreManifestWriteOptions) !void {
            const manifest_dir_path = try std.fs.path.join(allocator, &.{ db_path, store_manifest_dir });
            defer allocator.free(manifest_dir_path);
            try std.Io.Dir.cwd().createDirPath(io, manifest_dir_path);

            const manifest_path = try storeManifestPath(allocator, db_path);
            defer allocator.free(manifest_path);

            var out = QueryOutputWriter{ .allocator = allocator, .max_bytes = 64 * 1024 };
            defer out.buffer.deinit(allocator);
            try out.writeAll("{\n");
            try out.print("  \"store_manifest_version\": {},\n", .{current_store_manifest_version});
            try out.print("  \"storage_format_version\": {},\n", .{current_storage_format_version});
            try out.writeAll("  \"created_by\": \"tinykg\",\n");
            try out.writeAll("  \"schema\": {\n");
            try out.print("    \"schema_version\": {},\n", .{options.schema_version});
            try out.writeAll("    \"kernel_version\": 1,\n");
            try out.writeAll("    \"enabled_profiles\": [");
            var profile_it = std.mem.splitScalar(u8, options.profiles, ',');
            var first = true;
            while (profile_it.next()) |raw_profile| {
                const profile = std.mem.trim(u8, raw_profile, " \t\r\n");
                if (profile.len == 0) continue;
                if (!first) try out.writeAll(", ");
                try writeJsonString(&out, profile);
                first = false;
            }
            try out.writeAll("]\n  },\n");
            try out.writeAll("  \"migration\": {\n");
            try out.writeAll("    \"name\": ");
            try writeJsonString(&out, options.migration_name);
            try out.writeAll(",\n    \"source\": ");
            try writeJsonString(&out, options.source_path);
            try out.print(",\n    \"recorded_ns\": {}\n", .{persistentNowNs(io)});
            try out.writeAll("  }\n}\n");

            const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{manifest_path});
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(io);
                try file.writePositionalAll(io, out.buffer.items, 0);
                try file.sync(io);
            }
            if (std.fs.path.isAbsolute(tmp_path) or std.fs.path.isAbsolute(manifest_path)) {
                try std.Io.Dir.renameAbsolute(tmp_path, manifest_path, io);
            } else {
                try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), manifest_path, io);
            }
            if (builtin.os.tag != .windows) {
                const parent = std.fs.path.dirname(manifest_path) orelse ".";
                var dir_file = if (std.fs.path.isAbsolute(parent))
                    try std.Io.Dir.openFileAbsolute(io, parent, .{ .allow_directory = true })
                else
                    try std.Io.Dir.cwd().openFile(io, parent, .{ .allow_directory = true });
                defer dir_file.close(io);
                try dir_file.sync(io);
            }
        }

        pub fn readStoreManifestSummary(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !StoreManifestSummary {
            const manifest_path = try storeManifestPath(allocator, db_path);
            defer allocator.free(manifest_path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return .{
                    .status = "legacy",
                    .store_manifest_version = "legacy",
                    .storage_format_version = "legacy",
                    .schema_version = "legacy",
                    .enabled_profiles = "",
                    .migration_name = "",
                    .migration_source = "",
                },
                else => |e| return e,
            };
            defer allocator.free(bytes);

            var parsed = try std.json.parseFromSlice(StoreManifestJson, allocator, bytes, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            defer parsed.deinit();

            const manifest_version = try std.fmt.allocPrint(allocator, "{}", .{parsed.value.store_manifest_version orelse 0});
            errdefer allocator.free(manifest_version);
            const storage_version = try std.fmt.allocPrint(allocator, "{}", .{parsed.value.storage_format_version orelse 0});
            errdefer allocator.free(storage_version);
            const schema_version = try std.fmt.allocPrint(allocator, "{}", .{if (parsed.value.schema) |schema_value| schema_value.schema_version orelse 0 else 0});
            errdefer allocator.free(schema_version);

            var profiles_out = std.ArrayList(u8).empty;
            errdefer profiles_out.deinit(allocator);
            if (parsed.value.schema) |schema_value| {
                if (schema_value.enabled_profiles) |profiles| {
                    for (profiles, 0..) |profile, index| {
                        if (index != 0) try profiles_out.append(allocator, ',');
                        try profiles_out.appendSlice(allocator, profile);
                    }
                }
            }
            const profiles = try profiles_out.toOwnedSlice(allocator);
            errdefer allocator.free(profiles);
            const migration_name = try allocator.dupe(u8, if (parsed.value.migration) |migration| migration.name orelse "" else "");
            errdefer allocator.free(migration_name);
            const migration_source = try allocator.dupe(u8, if (parsed.value.migration) |migration| migration.source orelse "" else "");
            return .{
                .status = "present",
                .store_manifest_version = manifest_version,
                .storage_format_version = storage_version,
                .schema_version = schema_version,
                .enabled_profiles = profiles,
                .migration_name = migration_name,
                .migration_source = migration_source,
                .owned_store_manifest_version = manifest_version,
                .owned_storage_format_version = storage_version,
                .owned_schema_version = schema_version,
                .owned_enabled_profiles = profiles,
                .owned_migration_name = migration_name,
                .owned_migration_source = migration_source,
            };
        }

        const migrate_node_string_property_keys = [_][]const u8{
            "name",
            "status",
            "claimed_by",
            "summary",
            "retrieval_hints",
            "schema_type",
            "external_key",
            "content_hash",
            "task_event_type",
            "dependency_relation",
        };

        const migrate_node_uint_property_keys = [_][]const u8{
            "generation",
            "created_at",
            "updated_at",
            "byte_start",
            "byte_end",
            "line_start",
            "line_end",
            "tombstone_generation",
            "task_recorded_ns",
            "task_created_ns",
            "task_completed_ns",
            "claim_expires_ns",
            "task_event_ns",
            "task_root_id",
            "task_id",
        };

        const migrate_edge_string_property_keys = [_][]const u8{
            "markdown_attr",
            "render_flags",
            "source_span",
            "confidence",
            "created_by",
            "projection_edge_id",
            "fact_edge_id",
        };

        const migrate_edge_uint_property_keys = [_][]const u8{
            "order_key",
            "generation",
            "created_at",
            "updated_at",
            "byte_start",
            "byte_end",
            "line_start",
            "line_end",
            "tombstone_generation",
        };

        const MigrationPropertyDomain = enum { node, edge };

        pub const MigrationPropertyKeys = struct {
            allocator: std.mem.Allocator,
            items: std.ArrayList([]const u8) = .empty,
            by_hash: std.AutoHashMap(u64, []const u8),

            pub fn init(
                allocator: std.mem.Allocator,
                source_registry: schema.Registry,
                target_registry: schema.Registry,
                domain: MigrationPropertyDomain,
            ) !MigrationPropertyKeys {
                var out = MigrationPropertyKeys{
                    .allocator = allocator,
                    .by_hash = std.AutoHashMap(u64, []const u8).init(allocator),
                };
                errdefer out.deinit();
                switch (domain) {
                    .node => {
                        for (migrate_node_string_property_keys) |key| try out.add(key);
                        for (migrate_node_uint_property_keys) |key| try out.add(key);
                    },
                    .edge => {
                        for (migrate_edge_string_property_keys) |key| try out.add(key);
                        for (migrate_edge_uint_property_keys) |key| try out.add(key);
                    },
                }
                try out.addRegistry(source_registry, domain);
                try out.addRegistry(target_registry, domain);
                return out;
            }

            pub fn deinit(self: *MigrationPropertyKeys) void {
                self.items.deinit(self.allocator);
                self.by_hash.deinit();
                self.* = undefined;
            }

            fn add(self: *MigrationPropertyKeys, key: []const u8) !void {
                const hash = storage.propertyKeyHashForLookup(key);
                const entry = try self.by_hash.getOrPut(hash);
                if (entry.found_existing) {
                    if (!std.mem.eql(u8, entry.value_ptr.*, key)) return error.InvalidRecord;
                    return;
                }
                errdefer _ = self.by_hash.remove(hash);
                entry.value_ptr.* = key;
                try self.items.append(self.allocator, key);
            }

            fn addRegistry(self: *MigrationPropertyKeys, registry: schema.Registry, domain: MigrationPropertyDomain) !void {
                const max_types: usize = switch (domain) {
                    .node => schema.max_node_types,
                    .edge => schema.max_relation_types,
                };
                for (0..max_types) |raw_id| {
                    const type_id: u16 = @intCast(raw_id);
                    const present = switch (domain) {
                        .node => registry.hasNodeTypeId(type_id),
                        .edge => registry.hasRelationTypeId(type_id),
                    };
                    if (!present) continue;
                    var property_index: usize = 0;
                    while (true) : (property_index += 1) {
                        const property = switch (domain) {
                            .node => registry.nodePropertyInfo(type_id, property_index),
                            .edge => registry.relationPropertyInfo(type_id, property_index),
                        } orelse break;
                        if (domain == .node and std.mem.eql(u8, property.name, "text")) continue;
                        try self.add(property.name);
                    }
                }
            }
        };

        const migration_property_run_chunk_records: usize = 256 * 1024;
        const migration_property_max_runs: usize = 512;
        pub const migration_property_merge_fan_in: usize = 64;
        pub const migration_property_spool_record_len: usize = 56;
        const migration_property_reader_buffer_bytes: usize = migration_property_spool_record_len * 256;
        const migration_property_run_write_buffer_bytes: usize = 1024 * 1024;
        const migration_property_value_buffer_bytes: usize = 1024 * 1024;

        pub const MigrationPropertySpoolRecord = struct {
            owner_kind: u8,
            value_kind: storage.PropertySnapshotValueKind,
            owner_id: u64,
            key_hash: u64,
            version: u64,
            value_offset: u64 = 0,
            uint_value: u64 = 0,
            value_len: u32 = 0,

            pub fn encode(self: MigrationPropertySpoolRecord, out: *[migration_property_spool_record_len]u8) !void {
                @memset(out, 0);
                if ((self.owner_kind != 1 and self.owner_kind != 2) or self.owner_id == 0 or self.owner_id == std.math.maxInt(u64)) return error.InvalidRecord;
                out[0] = self.owner_kind;
                out[1] = @intFromEnum(self.value_kind);
                std.mem.writeInt(u64, out[8..16], self.owner_id, .little);
                std.mem.writeInt(u64, out[16..24], self.key_hash, .little);
                std.mem.writeInt(u64, out[24..32], self.version, .little);
                std.mem.writeInt(u64, out[32..40], self.value_offset, .little);
                std.mem.writeInt(u64, out[40..48], self.uint_value, .little);
                std.mem.writeInt(u32, out[48..52], self.value_len, .little);
                switch (self.value_kind) {
                    .string => if (self.value_len == 0 or self.uint_value != 0) return error.InvalidRecord,
                    .uint => if (self.value_len != 0 or self.value_offset != 0) return error.InvalidRecord,
                }
            }

            fn decode(bytes: *const [migration_property_spool_record_len]u8) !MigrationPropertySpoolRecord {
                if (!std.mem.allEqual(u8, bytes[2..8], 0) or !std.mem.allEqual(u8, bytes[52..56], 0)) return error.InvalidRecord;
                const raw_kind = bytes[1];
                const value_kind: storage.PropertySnapshotValueKind = switch (raw_kind) {
                    @intFromEnum(storage.PropertySnapshotValueKind.string) => .string,
                    @intFromEnum(storage.PropertySnapshotValueKind.uint) => .uint,
                    else => return error.InvalidRecord,
                };
                const record = MigrationPropertySpoolRecord{
                    .owner_kind = bytes[0],
                    .value_kind = value_kind,
                    .owner_id = std.mem.readInt(u64, bytes[8..16], .little),
                    .key_hash = std.mem.readInt(u64, bytes[16..24], .little),
                    .version = std.mem.readInt(u64, bytes[24..32], .little),
                    .value_offset = std.mem.readInt(u64, bytes[32..40], .little),
                    .uint_value = std.mem.readInt(u64, bytes[40..48], .little),
                    .value_len = std.mem.readInt(u32, bytes[48..52], .little),
                };
                var canonical: [migration_property_spool_record_len]u8 = undefined;
                try record.encode(&canonical);
                if (!std.mem.eql(u8, &canonical, bytes)) return error.InvalidRecord;
                return record;
            }
        };

        const MigrationPropertySortOrder = enum { effective_owner, canonical_payload };

        fn migrationPropertySpoolRecordLessThan(order: MigrationPropertySortOrder, lhs: MigrationPropertySpoolRecord, rhs: MigrationPropertySpoolRecord) bool {
            return switch (order) {
                .effective_owner => blk: {
                    if (lhs.owner_kind != rhs.owner_kind) break :blk lhs.owner_kind < rhs.owner_kind;
                    if (lhs.owner_id != rhs.owner_id) break :blk lhs.owner_id < rhs.owner_id;
                    if (lhs.key_hash != rhs.key_hash) break :blk lhs.key_hash < rhs.key_hash;
                    break :blk lhs.version < rhs.version;
                },
                .canonical_payload => blk: {
                    if (lhs.key_hash != rhs.key_hash) break :blk lhs.key_hash < rhs.key_hash;
                    if (lhs.value_kind != rhs.value_kind) break :blk @intFromEnum(lhs.value_kind) < @intFromEnum(rhs.value_kind);
                    // Target-spool records store the canonical value_hash in version.
                    if (lhs.version != rhs.version) break :blk lhs.version < rhs.version;
                    if (lhs.owner_kind != rhs.owner_kind) break :blk lhs.owner_kind < rhs.owner_kind;
                    break :blk lhs.owner_id < rhs.owner_id;
                },
            };
        }

        const MigrationPropertySpoolBuilder = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            scratch_dir: []const u8,
            nonce: u64,
            node_keys: *const MigrationPropertyKeys,
            edge_keys: *const MigrationPropertyKeys,
            filter_keys: bool = true,
            sort_order: MigrationPropertySortOrder,
            values_path: []u8,
            values_file: std.Io.File,
            values_offset: u64 = 0,
            record_count: u64 = 0,
            values_buffer: std.ArrayList(u8) = .empty,
            records: std.ArrayList(MigrationPropertySpoolRecord) = .empty,
            run_paths: std.ArrayList([]u8) = .empty,

            fn deinit(self: *MigrationPropertySpoolBuilder, keep_files: bool) void {
                self.values_file.close(self.io);
                self.values_buffer.deinit(self.allocator);
                self.records.deinit(self.allocator);
                if (!keep_files) {
                    for (self.run_paths.items) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                    std.Io.Dir.cwd().deleteFile(self.io, self.values_path) catch {};
                }
                for (self.run_paths.items) |path| self.allocator.free(path);
                self.run_paths.deinit(self.allocator);
                self.allocator.free(self.values_path);
                self.* = undefined;
            }

            fn flushValues(self: *MigrationPropertySpoolBuilder) !void {
                if (self.values_buffer.items.len == 0) return;
                const buffered_len: u64 = @intCast(self.values_buffer.items.len);
                if (buffered_len > self.values_offset) return error.InvalidRecord;
                try self.values_file.writePositionalAll(
                    self.io,
                    self.values_buffer.items,
                    self.values_offset - buffered_len,
                );
                self.values_buffer.clearRetainingCapacity();
            }

            fn appendStringValue(self: *MigrationPropertySpoolBuilder, value: []const u8) !u64 {
                const offset = self.values_offset;
                const next_offset = std.math.add(u64, offset, value.len) catch return error.RecordTooLarge;
                if (value.len > migration_property_value_buffer_bytes) {
                    try self.flushValues();
                    try self.values_file.writePositionalAll(self.io, value, offset);
                } else {
                    if (value.len > migration_property_value_buffer_bytes - self.values_buffer.items.len) try self.flushValues();
                    try self.values_buffer.appendSlice(self.allocator, value);
                }
                self.values_offset = next_offset;
                return offset;
            }

            fn appendLayer(context: *anyopaque, entry: storage.PropertySnapshotLayerEntry) anyerror!void {
                const self: *MigrationPropertySpoolBuilder = @ptrCast(@alignCast(context));
                const domain_keys: *const MigrationPropertyKeys = switch (entry.owner) {
                    .node => self.node_keys,
                    .edge => self.edge_keys,
                };
                if (self.filter_keys and !domain_keys.by_hash.contains(entry.key_hash)) return;
                const owner_id: u64 = switch (entry.owner) {
                    .node => |id| id.toInt(),
                    .edge => |id| id.toInt(),
                };
                const owner_kind: u8 = switch (entry.owner) {
                    .node => 1,
                    .edge => 2,
                };
                var record = MigrationPropertySpoolRecord{
                    .owner_kind = owner_kind,
                    .value_kind = entry.value_kind,
                    .owner_id = owner_id,
                    .key_hash = entry.key_hash,
                    .version = entry.version,
                    .uint_value = entry.uint_value,
                };
                if (entry.value_kind == .string) {
                    record.value_len = std.math.cast(u32, entry.string_value.len) orelse return error.RecordTooLarge;
                    record.value_offset = try self.appendStringValue(entry.string_value);
                }
                try self.records.append(self.allocator, record);
                self.record_count = std.math.add(u64, self.record_count, 1) catch return error.RecordTooLarge;
                if (self.records.items.len >= migration_property_run_chunk_records) try self.flushRun();
            }

            fn flushRun(self: *MigrationPropertySpoolBuilder) !void {
                if (self.records.items.len == 0) return;
                if (self.run_paths.items.len >= migration_property_max_runs) return error.SchemaMigrationPropertyRunLimitExceeded;
                std.mem.sort(MigrationPropertySpoolRecord, self.records.items, self.sort_order, migrationPropertySpoolRecordLessThan);
                const run_path = try std.fmt.allocPrint(self.allocator, "{s}/.schema-property-{d}-{d}.run.tmp", .{ self.scratch_dir, self.nonce, self.run_paths.items.len });
                errdefer self.allocator.free(run_path);
                errdefer std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
                const byte_len = std.math.mul(usize, self.records.items.len, migration_property_spool_record_len) catch return error.RecordTooLarge;
                const bytes = try self.allocator.alloc(u8, byte_len);
                defer self.allocator.free(bytes);
                for (self.records.items, 0..) |record, index| {
                    const start = index * migration_property_spool_record_len;
                    try record.encode(bytes[start..][0..migration_property_spool_record_len]);
                }
                var file = try std.Io.Dir.cwd().createFile(self.io, run_path, .{ .read = true, .truncate = true });
                defer file.close(self.io);
                try file.writePositionalAll(self.io, bytes, 0);
                try self.run_paths.append(self.allocator, run_path);
                self.records.clearRetainingCapacity();
            }
        };

        pub const MigrationPropertySpool = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            values_path: []u8,
            run_paths: [][]u8,
            sort_order: MigrationPropertySortOrder,
            record_count: u64,

            pub fn build(
                allocator: std.mem.Allocator,
                io: std.Io,
                scratch_dir: []const u8,
                source: storage.Store,
                node_keys: *const MigrationPropertyKeys,
                edge_keys: *const MigrationPropertyKeys,
            ) !MigrationPropertySpool {
                return buildFiltered(allocator, io, scratch_dir, source, node_keys, edge_keys, true);
            }

            pub fn buildAll(
                allocator: std.mem.Allocator,
                io: std.Io,
                scratch_dir: []const u8,
                source: storage.Store,
                node_keys: *const MigrationPropertyKeys,
                edge_keys: *const MigrationPropertyKeys,
            ) !MigrationPropertySpool {
                return buildFiltered(allocator, io, scratch_dir, source, node_keys, edge_keys, false);
            }

            fn buildFiltered(
                allocator: std.mem.Allocator,
                io: std.Io,
                scratch_dir: []const u8,
                source: storage.Store,
                node_keys: *const MigrationPropertyKeys,
                edge_keys: *const MigrationPropertyKeys,
                filter_keys: bool,
            ) !MigrationPropertySpool {
                const nonce = export_temp_nonce.fetchAdd(1, .monotonic);
                const values_path = try std.fmt.allocPrint(allocator, "{s}/.schema-property-{d}.values.tmp", .{ scratch_dir, nonce });
                var path_owned_by_builder = false;
                errdefer if (!path_owned_by_builder) allocator.free(values_path);
                var values_file = try std.Io.Dir.cwd().createFile(io, values_path, .{ .read = true, .truncate = true });
                var builder = MigrationPropertySpoolBuilder{
                    .allocator = allocator,
                    .io = io,
                    .scratch_dir = scratch_dir,
                    .nonce = nonce,
                    .node_keys = node_keys,
                    .edge_keys = edge_keys,
                    .filter_keys = filter_keys,
                    .sort_order = .effective_owner,
                    .values_path = values_path,
                    .values_file = values_file,
                };
                path_owned_by_builder = true;
                values_file = undefined;
                var keep_files = false;
                defer builder.deinit(keep_files);
                try builder.values_buffer.ensureTotalCapacityPrecise(allocator, migration_property_value_buffer_bytes);
                try builder.records.ensureTotalCapacityPrecise(allocator, migration_property_run_chunk_records);
                try source.scanPropertySnapshotLayers(allocator, &builder, MigrationPropertySpoolBuilder.appendLayer);
                const OrderLayerContext = struct {
                    builder: *MigrationPropertySpoolBuilder,

                    fn visit(raw_context: *anyopaque, record: storage.EdgeOrderRecord) anyerror!void {
                        const context: *@This() = @ptrCast(@alignCast(raw_context));
                        try MigrationPropertySpoolBuilder.appendLayer(context.builder, .{
                            .owner = .{ .edge = .fromInt(record.edge_id) },
                            .key_hash = storage.propertyKeyHashForLookup("order_key"),
                            // edge_order.idx is the authoritative ordered-composition
                            // sidecar, so it wins over every historical property layer.
                            .version = std.math.maxInt(u64),
                            .value_kind = .uint,
                            .uint_value = record.order_key,
                        });
                    }
                };
                var order_layer_context = OrderLayerContext{ .builder = &builder };
                _ = try source.scanEdgeOrderRecords(&order_layer_context, OrderLayerContext.visit);
                try builder.flushValues();
                try builder.flushRun();
                try coalesceMigrationPropertyRuns(allocator, io, scratch_dir, nonce, builder.sort_order, &builder.run_paths);
                const empty_values_path = try allocator.dupe(u8, "");
                errdefer allocator.free(empty_values_path);
                const run_paths = try builder.run_paths.toOwnedSlice(allocator);
                builder.run_paths = .empty;
                const owned_values_path = builder.values_path;
                builder.values_path = empty_values_path;
                keep_files = true;
                return .{
                    .allocator = allocator,
                    .io = io,
                    .values_path = owned_values_path,
                    .run_paths = run_paths,
                    .sort_order = builder.sort_order,
                    .record_count = builder.record_count,
                };
            }

            pub fn deinit(self: *MigrationPropertySpool) void {
                for (self.run_paths) |path| {
                    std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                    self.allocator.free(path);
                }
                self.allocator.free(self.run_paths);
                std.Io.Dir.cwd().deleteFile(self.io, self.values_path) catch {};
                self.allocator.free(self.values_path);
                self.* = undefined;
            }
        };

        pub const migration_edge_spool_record_len: usize = 32;
        const migration_edge_run_chunk_records: usize = 256 * 1024;
        const migration_edge_max_runs: usize = 512;
        pub const migration_edge_merge_fan_in: usize = 64;
        const migration_edge_reader_buffer_bytes: usize = migration_edge_spool_record_len * 256;
        const migration_edge_run_write_buffer_bytes: usize = 1024 * 1024;

        fn migrationEdgeRecordLessThan(_: void, lhs: storage.EdgeIndexRecord, rhs: storage.EdgeIndexRecord) bool {
            if (lhs.edge_id != rhs.edge_id) return lhs.edge_id < rhs.edge_id;
            if (lhs.src != rhs.src) return lhs.src < rhs.src;
            if (lhs.rel != rhs.rel) return lhs.rel < rhs.rel;
            return lhs.dst < rhs.dst;
        }

        pub fn encodeMigrationEdgeRecord(record: storage.EdgeIndexRecord, out: *[migration_edge_spool_record_len]u8) !void {
            if (record.src == 0 or record.dst == 0 or record.edge_id == 0 or
                record.src == std.math.maxInt(u64) or record.dst == std.math.maxInt(u64) or record.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            _ = try record.relKind();
            @memset(out, 0);
            std.mem.writeInt(u64, out[0..8], record.src, .little);
            std.mem.writeInt(u64, out[8..16], record.dst, .little);
            std.mem.writeInt(u64, out[16..24], record.edge_id, .little);
            std.mem.writeInt(u16, out[24..26], record.rel, .little);
        }

        fn decodeMigrationEdgeRecord(bytes: *const [migration_edge_spool_record_len]u8) !storage.EdgeIndexRecord {
            if (!std.mem.allEqual(u8, bytes[26..], 0)) return error.InvalidRecord;
            const record = storage.EdgeIndexRecord{
                .src = std.mem.readInt(u64, bytes[0..8], .little),
                .dst = std.mem.readInt(u64, bytes[8..16], .little),
                .edge_id = std.mem.readInt(u64, bytes[16..24], .little),
                .rel = std.mem.readInt(u16, bytes[24..26], .little),
            };
            var canonical: [migration_edge_spool_record_len]u8 = undefined;
            try encodeMigrationEdgeRecord(record, &canonical);
            if (!std.mem.eql(u8, &canonical, bytes)) return error.InvalidRecord;
            return record;
        }

        const MigrationEdgeRunWriter = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            file: std.Io.File,
            offset: u64 = 0,
            buffer: std.ArrayList(u8) = .empty,

            fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !MigrationEdgeRunWriter {
                var out = MigrationEdgeRunWriter{ .allocator = allocator, .io = io, .file = file };
                errdefer out.buffer.deinit(allocator);
                try out.buffer.ensureTotalCapacityPrecise(allocator, migration_edge_run_write_buffer_bytes);
                return out;
            }

            fn deinit(self: *MigrationEdgeRunWriter) void {
                self.buffer.deinit(self.allocator);
                self.* = undefined;
            }

            fn append(self: *MigrationEdgeRunWriter, record: storage.EdgeIndexRecord) !void {
                if (migration_edge_spool_record_len > migration_edge_run_write_buffer_bytes - self.buffer.items.len) try self.flush();
                var bytes: [migration_edge_spool_record_len]u8 = undefined;
                try encodeMigrationEdgeRecord(record, &bytes);
                try self.buffer.appendSlice(self.allocator, &bytes);
            }

            fn flush(self: *MigrationEdgeRunWriter) !void {
                if (self.buffer.items.len == 0) return;
                try self.file.writePositionalAll(self.io, self.buffer.items, self.offset);
                self.offset = std.math.add(u64, self.offset, self.buffer.items.len) catch return error.RecordTooLarge;
                self.buffer.clearRetainingCapacity();
            }
        };

        const MigrationEdgeRunReader = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            file: std.Io.File,
            remaining: u64,
            file_offset: u64 = 0,
            buffer: []u8,
            cursor: usize = 0,
            len: usize = 0,

            fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !MigrationEdgeRunReader {
                var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
                errdefer file.close(io);
                const stat = try file.stat(io);
                if (stat.kind != .file or stat.size == 0 or stat.size % migration_edge_spool_record_len != 0) return error.InvalidRecord;
                const buffer = try allocator.alloc(u8, migration_edge_reader_buffer_bytes);
                errdefer allocator.free(buffer);
                return .{
                    .allocator = allocator,
                    .io = io,
                    .file = file,
                    .remaining = stat.size / migration_edge_spool_record_len,
                    .buffer = buffer,
                };
            }

            fn deinit(self: *MigrationEdgeRunReader) void {
                self.allocator.free(self.buffer);
                self.file.close(self.io);
                self.* = undefined;
            }

            fn refill(self: *MigrationEdgeRunReader) !void {
                const n = try self.file.readPositionalAll(self.io, self.buffer, self.file_offset);
                if (n == 0 or n % migration_edge_spool_record_len != 0) return error.InvalidRecord;
                self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
                self.cursor = 0;
                self.len = n;
            }

            fn next(self: *MigrationEdgeRunReader) !?storage.EdgeIndexRecord {
                if (self.remaining == 0) return null;
                if (self.cursor == self.len) try self.refill();
                if (self.len - self.cursor < migration_edge_spool_record_len) return error.InvalidRecord;
                const bytes = self.buffer[self.cursor..][0..migration_edge_spool_record_len];
                self.cursor += migration_edge_spool_record_len;
                self.remaining -= 1;
                return try decodeMigrationEdgeRecord(bytes);
            }
        };

        const MigrationEdgeQueueEntry = struct {
            run_index: usize,
            record: storage.EdgeIndexRecord,
        };

        fn compareMigrationEdgeQueueEntry(_: void, lhs: MigrationEdgeQueueEntry, rhs: MigrationEdgeQueueEntry) std.math.Order {
            if (migrationEdgeRecordLessThan({}, lhs.record, rhs.record)) return .lt;
            if (migrationEdgeRecordLessThan({}, rhs.record, lhs.record)) return .gt;
            return std.math.order(lhs.run_index, rhs.run_index);
        }

        fn mergeMigrationEdgeRunGroup(
            allocator: std.mem.Allocator,
            io: std.Io,
            input_paths: []const []u8,
            output_path: []const u8,
        ) !void {
            if (input_paths.len == 0 or input_paths.len > migration_edge_merge_fan_in) return error.InvalidRecord;
            var readers = std.ArrayList(MigrationEdgeRunReader).empty;
            defer {
                for (readers.items) |*reader| reader.deinit();
                readers.deinit(allocator);
            }
            var queue = std.PriorityQueue(MigrationEdgeQueueEntry, void, compareMigrationEdgeQueueEntry).initContext({});
            defer queue.deinit(allocator);
            try readers.ensureTotalCapacityPrecise(allocator, input_paths.len);
            try queue.ensureTotalCapacityPrecise(allocator, input_paths.len);
            for (input_paths) |path| {
                const run_index = readers.items.len;
                readers.appendAssumeCapacity(try MigrationEdgeRunReader.init(allocator, io, path));
                const first = (try readers.items[run_index].next()) orelse return error.InvalidRecord;
                try queue.push(allocator, .{ .run_index = run_index, .record = first });
            }

            var output_file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .read = true, .truncate = true, .exclusive = true });
            defer output_file.close(io);
            var writer = try MigrationEdgeRunWriter.init(allocator, io, output_file);
            defer writer.deinit();
            var previous_edge_id: u64 = 0;
            while (queue.pop()) |entry| {
                if (entry.record.edge_id <= previous_edge_id) return error.InvalidRecord;
                previous_edge_id = entry.record.edge_id;
                try writer.append(entry.record);
                if (try readers.items[entry.run_index].next()) |next_record| {
                    try queue.push(allocator, .{ .run_index = entry.run_index, .record = next_record });
                }
            }
            try writer.flush();
        }

        pub fn coalesceMigrationEdgeRuns(
            allocator: std.mem.Allocator,
            io: std.Io,
            scratch_dir: []const u8,
            nonce: u64,
            run_paths: *std.ArrayList([]u8),
        ) !void {
            var pass: usize = 0;
            while (run_paths.items.len > migration_edge_merge_fan_in) : (pass += 1) {
                var merged_paths = std.ArrayList([]u8).empty;
                errdefer {
                    for (merged_paths.items) |path| {
                        std.Io.Dir.cwd().deleteFile(io, path) catch {};
                        allocator.free(path);
                    }
                    merged_paths.deinit(allocator);
                }
                const output_count = std.math.divCeil(usize, run_paths.items.len, migration_edge_merge_fan_in) catch return error.InvalidRecord;
                try merged_paths.ensureTotalCapacityPrecise(allocator, output_count);
                var start: usize = 0;
                while (start < run_paths.items.len) {
                    const end = start + @min(migration_edge_merge_fan_in, run_paths.items.len - start);
                    var output_path: ?[]u8 = try std.fmt.allocPrint(
                        allocator,
                        "{s}/.schema-edge-{d}-merge-{d}-{d}.run.tmp",
                        .{ scratch_dir, nonce, pass, merged_paths.items.len },
                    );
                    defer if (output_path) |path| {
                        std.Io.Dir.cwd().deleteFile(io, path) catch {};
                        allocator.free(path);
                    };
                    try mergeMigrationEdgeRunGroup(allocator, io, run_paths.items[start..end], output_path.?);
                    merged_paths.appendAssumeCapacity(output_path.?);
                    output_path = null;
                    start = end;
                }
                for (run_paths.items) |path| {
                    std.Io.Dir.cwd().deleteFile(io, path) catch {};
                    allocator.free(path);
                }
                run_paths.deinit(allocator);
                run_paths.* = merged_paths;
            }
        }

        pub const MigrationEdgeSpool = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            run_paths: [][]u8,
            record_count: u64,

            pub fn deinit(self: *MigrationEdgeSpool) void {
                for (self.run_paths) |path| {
                    std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                    self.allocator.free(path);
                }
                self.allocator.free(self.run_paths);
                self.* = undefined;
            }
        };

        pub const MigrationEdgeSpoolBuilder = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            scratch_dir: []const u8,
            nonce: u64,
            records: std.ArrayList(storage.EdgeIndexRecord) = .empty,
            run_paths: std.ArrayList([]u8) = .empty,
            record_count: u64 = 0,
            active: bool = true,

            pub fn init(allocator: std.mem.Allocator, io: std.Io, scratch_dir: []const u8) !MigrationEdgeSpoolBuilder {
                var out = MigrationEdgeSpoolBuilder{
                    .allocator = allocator,
                    .io = io,
                    .scratch_dir = scratch_dir,
                    .nonce = export_temp_nonce.fetchAdd(1, .monotonic),
                };
                errdefer out.deinit();
                try out.records.ensureTotalCapacityPrecise(allocator, migration_edge_run_chunk_records);
                return out;
            }

            pub fn deinit(self: *MigrationEdgeSpoolBuilder) void {
                self.records.deinit(self.allocator);
                if (self.active) {
                    for (self.run_paths.items) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                }
                for (self.run_paths.items) |path| self.allocator.free(path);
                self.run_paths.deinit(self.allocator);
                self.* = undefined;
            }

            pub fn append(self: *MigrationEdgeSpoolBuilder, record: storage.EdgeIndexRecord) !void {
                if (!self.active) return error.InvalidRecord;
                try self.records.append(self.allocator, record);
                self.record_count = std.math.add(u64, self.record_count, 1) catch return error.RecordTooLarge;
                if (self.records.items.len >= migration_edge_run_chunk_records) try self.flushRun();
            }

            fn flushRun(self: *MigrationEdgeSpoolBuilder) !void {
                if (self.records.items.len == 0) return;
                if (self.run_paths.items.len >= migration_edge_max_runs) return error.SchemaMigrationEdgeRunLimitExceeded;
                std.mem.sort(storage.EdgeIndexRecord, self.records.items, {}, migrationEdgeRecordLessThan);
                var previous_edge_id: u64 = 0;
                for (self.records.items) |record| {
                    if (record.edge_id <= previous_edge_id) return error.InvalidRecord;
                    previous_edge_id = record.edge_id;
                }
                const run_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/.schema-edge-{d}-{d}.run.tmp",
                    .{ self.scratch_dir, self.nonce, self.run_paths.items.len },
                );
                var keep_path = false;
                errdefer if (!keep_path) {
                    std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
                    self.allocator.free(run_path);
                };
                var file = try std.Io.Dir.cwd().createFile(self.io, run_path, .{ .read = true, .truncate = true, .exclusive = true });
                defer file.close(self.io);
                var writer = try MigrationEdgeRunWriter.init(self.allocator, self.io, file);
                defer writer.deinit();
                for (self.records.items) |record| try writer.append(record);
                try writer.flush();
                try self.run_paths.append(self.allocator, run_path);
                keep_path = true;
                self.records.clearRetainingCapacity();
            }

            pub fn finish(self: *MigrationEdgeSpoolBuilder) !MigrationEdgeSpool {
                if (!self.active) return error.InvalidRecord;
                try self.flushRun();
                try coalesceMigrationEdgeRuns(self.allocator, self.io, self.scratch_dir, self.nonce, &self.run_paths);
                const run_paths = try self.run_paths.toOwnedSlice(self.allocator);
                self.run_paths = .empty;
                self.active = false;
                return .{
                    .allocator = self.allocator,
                    .io = self.io,
                    .run_paths = run_paths,
                    .record_count = self.record_count,
                };
            }
        };

        pub const MigrationEdgeStream = struct {
            allocator: std.mem.Allocator,
            readers: std.ArrayList(MigrationEdgeRunReader) = .empty,
            queue: std.PriorityQueue(MigrationEdgeQueueEntry, void, compareMigrationEdgeQueueEntry),
            expected_count: u64,
            seen: u64 = 0,
            previous_edge_id: u64 = 0,

            pub fn init(spool: *const MigrationEdgeSpool) !MigrationEdgeStream {
                if (spool.run_paths.len > migration_edge_merge_fan_in) return error.InvalidRecord;
                var out = MigrationEdgeStream{
                    .allocator = spool.allocator,
                    .queue = std.PriorityQueue(MigrationEdgeQueueEntry, void, compareMigrationEdgeQueueEntry).initContext({}),
                    .expected_count = spool.record_count,
                };
                errdefer out.deinit();
                try out.readers.ensureTotalCapacityPrecise(out.allocator, spool.run_paths.len);
                try out.queue.ensureTotalCapacityPrecise(out.allocator, spool.run_paths.len);
                for (spool.run_paths) |path| {
                    const run_index = out.readers.items.len;
                    out.readers.appendAssumeCapacity(try MigrationEdgeRunReader.init(out.allocator, spool.io, path));
                    const first = (try out.readers.items[run_index].next()) orelse return error.InvalidRecord;
                    try out.queue.push(out.allocator, .{ .run_index = run_index, .record = first });
                }
                if ((spool.record_count == 0) != (spool.run_paths.len == 0)) return error.InvalidRecord;
                return out;
            }

            pub fn deinit(self: *MigrationEdgeStream) void {
                for (self.readers.items) |*reader| reader.deinit();
                self.readers.deinit(self.allocator);
                self.queue.deinit(self.allocator);
                self.* = undefined;
            }

            pub fn next(self: *MigrationEdgeStream) !?storage.EdgeIndexRecord {
                const entry = self.queue.pop() orelse {
                    if (self.seen != self.expected_count) return error.InvalidRecord;
                    return null;
                };
                if (entry.record.edge_id <= self.previous_edge_id) return error.InvalidRecord;
                self.previous_edge_id = entry.record.edge_id;
                self.seen = std.math.add(u64, self.seen, 1) catch return error.RecordTooLarge;
                if (self.seen > self.expected_count) return error.InvalidRecord;
                if (try self.readers.items[entry.run_index].next()) |next_record| {
                    try self.queue.push(self.allocator, .{ .run_index = entry.run_index, .record = next_record });
                }
                return entry.record;
            }
        };

        pub const MigrationTargetPropertySpoolBuilder = struct {
            inner: MigrationPropertySpoolBuilder,
            nonce: u64,
            current_owner_kind: u8 = 0,
            current_owner_id: u64 = 0,
            current_owner_keys: std.AutoHashMap(u64, void),
            active: bool = true,

            pub fn init(
                allocator: std.mem.Allocator,
                io: std.Io,
                scratch_dir: []const u8,
                node_keys: *const MigrationPropertyKeys,
                edge_keys: *const MigrationPropertyKeys,
            ) !MigrationTargetPropertySpoolBuilder {
                const nonce = export_temp_nonce.fetchAdd(1, .monotonic);
                const values_path = try std.fmt.allocPrint(allocator, "{s}/.schema-target-property-{d}.values.tmp", .{ scratch_dir, nonce });
                var path_owned_by_out = false;
                errdefer if (!path_owned_by_out) allocator.free(values_path);
                var values_file = try std.Io.Dir.cwd().createFile(io, values_path, .{ .read = true, .truncate = true, .exclusive = true });
                var file_owned_by_out = false;
                errdefer if (!file_owned_by_out) values_file.close(io);
                var out = MigrationTargetPropertySpoolBuilder{
                    .inner = .{
                        .allocator = allocator,
                        .io = io,
                        .scratch_dir = scratch_dir,
                        .nonce = nonce,
                        .node_keys = node_keys,
                        .edge_keys = edge_keys,
                        // Target writes have already been selected and validated by
                        // the migrator.  Do not silently discard a legal historical
                        // key merely because it is absent from the current catalog.
                        .filter_keys = false,
                        .sort_order = .canonical_payload,
                        .values_path = values_path,
                        .values_file = values_file,
                    },
                    .nonce = nonce,
                    .current_owner_keys = std.AutoHashMap(u64, void).init(allocator),
                };
                path_owned_by_out = true;
                file_owned_by_out = true;
                errdefer out.deinit();
                try out.inner.values_buffer.ensureTotalCapacityPrecise(allocator, migration_property_value_buffer_bytes);
                try out.inner.records.ensureTotalCapacityPrecise(allocator, migration_property_run_chunk_records);
                return out;
            }

            pub fn deinit(self: *MigrationTargetPropertySpoolBuilder) void {
                if (self.active) self.inner.deinit(false);
                self.current_owner_keys.deinit();
                self.* = undefined;
            }

            pub fn appendBatch(self: *MigrationTargetPropertySpoolBuilder, writes: []const storage.PropertyPayloadWrite) !void {
                for (writes) |write| {
                    const key_hash = storage.propertyKeyHashForLookup(write.key);
                    if (!migrationPropertyKeyValid(write.key)) return error.InvalidRecord;
                    try self.appendValue(write.owner, key_hash, write.value);
                }
            }

            fn appendValue(
                self: *MigrationTargetPropertySpoolBuilder,
                owner: storage.PropertyOwner,
                key_hash: u64,
                value: storage.PropertyPayloadValue,
            ) !void {
                const owner_kind: u8 = switch (owner) {
                    .node => 1,
                    .edge => 2,
                };
                const owner_id: u64 = switch (owner) {
                    .node => |id| id.toInt(),
                    .edge => |id| id.toInt(),
                };
                if (owner_kind != self.current_owner_kind or owner_id != self.current_owner_id) {
                    if (self.current_owner_kind != 0 and
                        (owner_kind < self.current_owner_kind or
                            (owner_kind == self.current_owner_kind and owner_id <= self.current_owner_id))) return error.InvalidRecord;
                    self.current_owner_kind = owner_kind;
                    self.current_owner_id = owner_id;
                    self.current_owner_keys.clearRetainingCapacity();
                }
                const key_entry = try self.current_owner_keys.getOrPut(key_hash);
                if (key_entry.found_existing) return error.InvalidRecord;
                const layer_entry: storage.PropertySnapshotLayerEntry = switch (value) {
                    .string => |string_value| .{
                        .owner = owner,
                        .key_hash = key_hash,
                        .version = storage.propertyValueHashForStorage(string_value),
                        .value_kind = .string,
                        .string_value = string_value,
                    },
                    .uint => |uint_value| .{
                        .owner = owner,
                        .key_hash = key_hash,
                        .version = uint_value,
                        .value_kind = .uint,
                        .uint_value = uint_value,
                    },
                };
                try MigrationPropertySpoolBuilder.appendLayer(&self.inner, layer_entry);
            }

            pub fn finish(self: *MigrationTargetPropertySpoolBuilder) !MigrationPropertySpool {
                if (!self.active) return error.InvalidRecord;
                try self.inner.flushValues();
                try self.inner.flushRun();
                try coalesceMigrationPropertyRuns(
                    self.inner.allocator,
                    self.inner.io,
                    self.inner.scratch_dir,
                    self.nonce,
                    self.inner.sort_order,
                    &self.inner.run_paths,
                );
                const empty_values_path = try self.inner.allocator.dupe(u8, "");
                errdefer self.inner.allocator.free(empty_values_path);
                const run_paths = try self.inner.run_paths.toOwnedSlice(self.inner.allocator);
                self.inner.run_paths = .empty;
                const values_path = self.inner.values_path;
                self.inner.values_path = empty_values_path;
                const result = MigrationPropertySpool{
                    .allocator = self.inner.allocator,
                    .io = self.inner.io,
                    .values_path = values_path,
                    .run_paths = run_paths,
                    .sort_order = self.inner.sort_order,
                    .record_count = self.inner.record_count,
                };
                self.inner.deinit(true);
                self.active = false;
                return result;
            }
        };

        const MigrationPropertyRunReader = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            file: std.Io.File,
            remaining: u64,
            file_offset: u64 = 0,
            buffer: []u8,
            cursor: usize = 0,
            len: usize = 0,

            fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !MigrationPropertyRunReader {
                var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
                errdefer file.close(io);
                const stat = try file.stat(io);
                if (stat.kind != .file or stat.size % migration_property_spool_record_len != 0) return error.InvalidRecord;
                const buffer = try allocator.alloc(u8, migration_property_reader_buffer_bytes);
                errdefer allocator.free(buffer);
                return .{
                    .allocator = allocator,
                    .io = io,
                    .file = file,
                    .remaining = stat.size / migration_property_spool_record_len,
                    .buffer = buffer,
                };
            }

            fn deinit(self: *MigrationPropertyRunReader) void {
                self.allocator.free(self.buffer);
                self.file.close(self.io);
                self.* = undefined;
            }

            fn refill(self: *MigrationPropertyRunReader) !void {
                const n = try self.file.readPositionalAll(self.io, self.buffer, self.file_offset);
                if (n == 0 or n % migration_property_spool_record_len != 0) return error.InvalidRecord;
                self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
                self.cursor = 0;
                self.len = n;
            }

            fn next(self: *MigrationPropertyRunReader) !?MigrationPropertySpoolRecord {
                if (self.remaining == 0) return null;
                if (self.cursor == self.len) try self.refill();
                if (self.len - self.cursor < migration_property_spool_record_len) return error.InvalidRecord;
                const bytes = self.buffer[self.cursor..][0..migration_property_spool_record_len];
                self.cursor += migration_property_spool_record_len;
                self.remaining -= 1;
                return try MigrationPropertySpoolRecord.decode(bytes);
            }
        };

        const MigrationPropertyQueueEntry = struct {
            run_index: usize,
            record: MigrationPropertySpoolRecord,
        };

        fn compareMigrationPropertyQueueEntry(order: MigrationPropertySortOrder, lhs: MigrationPropertyQueueEntry, rhs: MigrationPropertyQueueEntry) std.math.Order {
            if (migrationPropertySpoolRecordLessThan(order, lhs.record, rhs.record)) return .lt;
            if (migrationPropertySpoolRecordLessThan(order, rhs.record, lhs.record)) return .gt;
            return std.math.order(lhs.run_index, rhs.run_index);
        }

        const MigrationPropertyRunWriter = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            file: std.Io.File,
            offset: u64 = 0,
            buffer: std.ArrayList(u8) = .empty,

            fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !MigrationPropertyRunWriter {
                var out = MigrationPropertyRunWriter{ .allocator = allocator, .io = io, .file = file };
                errdefer out.buffer.deinit(allocator);
                try out.buffer.ensureTotalCapacityPrecise(allocator, migration_property_run_write_buffer_bytes);
                return out;
            }

            fn deinit(self: *MigrationPropertyRunWriter) void {
                self.buffer.deinit(self.allocator);
                self.* = undefined;
            }

            fn append(self: *MigrationPropertyRunWriter, record: MigrationPropertySpoolRecord) !void {
                if (migration_property_spool_record_len > migration_property_run_write_buffer_bytes - self.buffer.items.len) try self.flush();
                var bytes: [migration_property_spool_record_len]u8 = undefined;
                try record.encode(&bytes);
                try self.buffer.appendSlice(self.allocator, &bytes);
            }

            fn flush(self: *MigrationPropertyRunWriter) !void {
                if (self.buffer.items.len == 0) return;
                try self.file.writePositionalAll(self.io, self.buffer.items, self.offset);
                self.offset = std.math.add(u64, self.offset, self.buffer.items.len) catch return error.RecordTooLarge;
                self.buffer.clearRetainingCapacity();
            }
        };

        fn mergeMigrationPropertyRunGroup(
            allocator: std.mem.Allocator,
            io: std.Io,
            input_paths: []const []u8,
            output_path: []const u8,
            sort_order: MigrationPropertySortOrder,
        ) !void {
            if (input_paths.len == 0 or input_paths.len > migration_property_merge_fan_in) return error.InvalidRecord;
            var readers = std.ArrayList(MigrationPropertyRunReader).empty;
            defer {
                for (readers.items) |*reader| reader.deinit();
                readers.deinit(allocator);
            }
            var queue = std.PriorityQueue(MigrationPropertyQueueEntry, MigrationPropertySortOrder, compareMigrationPropertyQueueEntry).initContext(sort_order);
            defer queue.deinit(allocator);
            try readers.ensureTotalCapacityPrecise(allocator, input_paths.len);
            try queue.ensureTotalCapacityPrecise(allocator, input_paths.len);
            for (input_paths) |path| {
                const run_index = readers.items.len;
                readers.appendAssumeCapacity(try MigrationPropertyRunReader.init(allocator, io, path));
                if (try readers.items[run_index].next()) |record| {
                    try queue.push(allocator, .{ .run_index = run_index, .record = record });
                }
            }

            var output_file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .read = true, .truncate = true, .exclusive = true });
            defer output_file.close(io);
            var writer = try MigrationPropertyRunWriter.init(allocator, io, output_file);
            defer writer.deinit();
            var previous: ?MigrationPropertySpoolRecord = null;
            while (queue.pop()) |entry| {
                if (previous) |prior| {
                    if (migrationPropertySpoolRecordLessThan(sort_order, entry.record, prior)) return error.InvalidRecord;
                }
                try writer.append(entry.record);
                previous = entry.record;
                if (try readers.items[entry.run_index].next()) |next_record| {
                    try queue.push(allocator, .{ .run_index = entry.run_index, .record = next_record });
                }
            }
            try writer.flush();
        }

        pub fn coalesceMigrationPropertyRuns(
            allocator: std.mem.Allocator,
            io: std.Io,
            scratch_dir: []const u8,
            nonce: u64,
            sort_order: MigrationPropertySortOrder,
            run_paths: *std.ArrayList([]u8),
        ) !void {
            var pass: usize = 0;
            while (run_paths.items.len > migration_property_merge_fan_in) : (pass += 1) {
                var merged_paths = std.ArrayList([]u8).empty;
                errdefer {
                    for (merged_paths.items) |path| {
                        std.Io.Dir.cwd().deleteFile(io, path) catch {};
                        allocator.free(path);
                    }
                    merged_paths.deinit(allocator);
                }
                const output_count = std.math.divCeil(usize, run_paths.items.len, migration_property_merge_fan_in) catch return error.InvalidRecord;
                try merged_paths.ensureTotalCapacityPrecise(allocator, output_count);
                var start: usize = 0;
                while (start < run_paths.items.len) {
                    const end = start + @min(migration_property_merge_fan_in, run_paths.items.len - start);
                    var output_path: ?[]u8 = try std.fmt.allocPrint(
                        allocator,
                        "{s}/.schema-property-{d}-merge-{d}-{d}.run.tmp",
                        .{ scratch_dir, nonce, pass, merged_paths.items.len },
                    );
                    defer if (output_path) |path| {
                        std.Io.Dir.cwd().deleteFile(io, path) catch {};
                        allocator.free(path);
                    };
                    try mergeMigrationPropertyRunGroup(allocator, io, run_paths.items[start..end], output_path.?, sort_order);
                    merged_paths.appendAssumeCapacity(output_path.?);
                    output_path = null;
                    start = end;
                }
                for (run_paths.items) |path| {
                    std.Io.Dir.cwd().deleteFile(io, path) catch {};
                    allocator.free(path);
                }
                run_paths.deinit(allocator);
                run_paths.* = merged_paths;
            }
        }

        fn sortedU64Contains(values: []const u64, target: u64) bool {
            var low: usize = 0;
            var high: usize = values.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (values[mid] < target) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            return low < values.len and values[low] == target;
        }

        const MigrationEffectiveProperty = struct {
            owner_kind: u8,
            owner_id: u64,
            key_hash: u64,
            value_kind: storage.PropertySnapshotValueKind,
            string_value: []const u8 = &.{},
            uint_value: u64 = 0,

            pub fn deinit(self: *MigrationEffectiveProperty, allocator: std.mem.Allocator) void {
                if (self.value_kind == .string) allocator.free(self.string_value);
                self.* = undefined;
            }
        };

        pub const MigrationPropertyStream = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            values_file: std.Io.File,
            values_size: u64,
            readers: std.ArrayList(MigrationPropertyRunReader) = .empty,
            sort_order: MigrationPropertySortOrder,
            queue: std.PriorityQueue(MigrationPropertyQueueEntry, MigrationPropertySortOrder, compareMigrationPropertyQueueEntry),
            physical_pending: ?MigrationPropertySpoolRecord = null,
            effective_pending: ?MigrationEffectiveProperty = null,
            canonical_borrowed: ?MigrationEffectiveProperty = null,

            pub fn init(spool: *const MigrationPropertySpool) !MigrationPropertyStream {
                var values_file = try std.Io.Dir.cwd().openFile(spool.io, spool.values_path, .{ .allow_directory = false });
                var values_file_owned = true;
                errdefer if (values_file_owned) values_file.close(spool.io);
                const values_stat = try values_file.stat(spool.io);
                if (values_stat.kind != .file) return error.InvalidRecord;
                var out = MigrationPropertyStream{
                    .allocator = spool.allocator,
                    .io = spool.io,
                    .values_file = values_file,
                    .values_size = values_stat.size,
                    .sort_order = spool.sort_order,
                    .queue = std.PriorityQueue(MigrationPropertyQueueEntry, MigrationPropertySortOrder, compareMigrationPropertyQueueEntry).initContext(spool.sort_order),
                };
                values_file_owned = false;
                errdefer out.deinit();
                try out.readers.ensureTotalCapacityPrecise(out.allocator, spool.run_paths.len);
                try out.queue.ensureTotalCapacityPrecise(out.allocator, spool.run_paths.len);
                for (spool.run_paths) |path| {
                    const run_index = out.readers.items.len;
                    out.readers.appendAssumeCapacity(try MigrationPropertyRunReader.init(out.allocator, out.io, path));
                    if (try out.readers.items[run_index].next()) |record| {
                        try out.queue.push(out.allocator, .{ .run_index = run_index, .record = record });
                    }
                }
                return out;
            }

            pub fn deinit(self: *MigrationPropertyStream) void {
                if (self.effective_pending) |*entry| entry.deinit(self.allocator);
                if (self.canonical_borrowed) |*entry| entry.deinit(self.allocator);
                for (self.readers.items) |*reader| reader.deinit();
                self.readers.deinit(self.allocator);
                self.queue.deinit(self.allocator);
                self.values_file.close(self.io);
                self.* = undefined;
            }

            fn nextPhysical(self: *MigrationPropertyStream) !?MigrationPropertySpoolRecord {
                if (self.physical_pending) |record| {
                    self.physical_pending = null;
                    return record;
                }
                const entry = self.queue.pop() orelse return null;
                if (try self.readers.items[entry.run_index].next()) |next_record| {
                    try self.queue.push(self.allocator, .{ .run_index = entry.run_index, .record = next_record });
                }
                return entry.record;
            }

            fn readEffectiveValue(self: *MigrationPropertyStream, record: MigrationPropertySpoolRecord) !MigrationEffectiveProperty {
                var out = MigrationEffectiveProperty{
                    .owner_kind = record.owner_kind,
                    .owner_id = record.owner_id,
                    .key_hash = record.key_hash,
                    .value_kind = record.value_kind,
                    .uint_value = record.uint_value,
                };
                if (record.value_kind == .string) {
                    const end = std.math.add(u64, record.value_offset, record.value_len) catch return error.InvalidRecord;
                    if (end > self.values_size) return error.InvalidRecord;
                    const value = try self.allocator.alloc(u8, record.value_len);
                    errdefer self.allocator.free(value);
                    const n = try self.values_file.readPositionalAll(self.io, value, record.value_offset);
                    if (n != value.len) return error.InvalidRecord;
                    out.string_value = value;
                }
                return out;
            }

            pub fn nextEffectiveUncached(self: *MigrationPropertyStream) !?MigrationEffectiveProperty {
                var latest = (try self.nextPhysical()) orelse return null;
                while (try self.nextPhysical()) |candidate| {
                    const same_key = candidate.owner_kind == latest.owner_kind and
                        candidate.owner_id == latest.owner_id and
                        candidate.key_hash == latest.key_hash;
                    if (!same_key) {
                        self.physical_pending = candidate;
                        break;
                    }
                    if (candidate.version == latest.version) return error.InvalidRecord;
                    if (candidate.version < latest.version) return error.InvalidRecord;
                    latest = candidate;
                }
                return try self.readEffectiveValue(latest);
            }

            pub fn nextSortedPayload(raw_context: *anyopaque) anyerror!?storage.SortedPropertyPayloadEntry {
                const self: *MigrationPropertyStream = @ptrCast(@alignCast(raw_context));
                if (self.sort_order != .canonical_payload) return error.InvalidRecord;
                if (self.canonical_borrowed) |*previous| previous.deinit(self.allocator);
                self.canonical_borrowed = null;
                const record = (try self.nextPhysical()) orelse return null;
                var value = try self.readEffectiveValue(record);
                errdefer value.deinit(self.allocator);
                switch (value.value_kind) {
                    .string => if (storage.propertyValueHashForStorage(value.string_value) != record.version) return error.InvalidRecord,
                    .uint => if (value.uint_value != record.version) return error.InvalidRecord,
                }
                self.canonical_borrowed = value;
                return .{
                    .owner = if (value.owner_kind == 1)
                        .{ .node = .fromInt(value.owner_id) }
                    else if (value.owner_kind == 2)
                        .{ .edge = .fromInt(value.owner_id) }
                    else
                        return error.InvalidRecord,
                    .key_hash = value.key_hash,
                    .value = switch (value.value_kind) {
                        .string => .{ .string = value.string_value },
                        .uint => .{ .uint = value.uint_value },
                    },
                };
            }

            fn ensureEffectivePending(self: *MigrationPropertyStream) !void {
                if (self.effective_pending == null) self.effective_pending = try self.nextEffectiveUncached();
            }

            pub fn snapshotForOwners(self: *MigrationPropertyStream, owner_kind: u8, owner_ids: []const u64) !storage.PropertySnapshot {
                if (self.sort_order != .effective_owner) return error.InvalidRecord;
                var out = std.ArrayList(storage.PropertySnapshotEntry).empty;
                errdefer {
                    for (out.items) |entry| if (entry.value_kind == .string) self.allocator.free(entry.string_value);
                    out.deinit(self.allocator);
                }
                if (owner_ids.len == 0) return .{ .entries = try out.toOwnedSlice(self.allocator) };
                for (owner_ids, 0..) |owner_id, index| {
                    if (owner_id == 0 or owner_id == std.math.maxInt(u64) or (index != 0 and owner_ids[index - 1] >= owner_id)) return error.InvalidRecord;
                }
                while (true) {
                    try self.ensureEffectivePending();
                    if (self.effective_pending == null) break;
                    const entry = &self.effective_pending.?;
                    if (entry.owner_kind > owner_kind or
                        (entry.owner_kind == owner_kind and entry.owner_id > owner_ids[owner_ids.len - 1])) break;
                    var keep = false;
                    if (entry.owner_kind == owner_kind) {
                        keep = sortedU64Contains(owner_ids, entry.owner_id);
                    }
                    var owned = entry.*;
                    self.effective_pending = null;
                    if (!keep) {
                        owned.deinit(self.allocator);
                        continue;
                    }
                    try out.append(self.allocator, .{
                        .owner = if (owner_kind == 1) .{ .node = .fromInt(owned.owner_id) } else .{ .edge = .fromInt(owned.owner_id) },
                        .key_hash = owned.key_hash,
                        .value_kind = owned.value_kind,
                        .string_len = if (owned.value_kind == .string) @intCast(owned.string_value.len) else 0,
                        .string_value = owned.string_value,
                        .uint_value = owned.uint_value,
                    });
                    if (owned.value_kind == .string) owned.string_value = &.{};
                }
                return .{ .entries = try out.toOwnedSlice(self.allocator) };
            }

            pub fn finish(self: *MigrationPropertyStream) !void {
                while (true) {
                    try self.ensureEffectivePending();
                    if (self.effective_pending == null) return;
                    var entry = self.effective_pending.?;
                    self.effective_pending = null;
                    entry.deinit(self.allocator);
                }
            }
        };

        pub fn appendCatalogProfileLabel(allocator: std.mem.Allocator, cat: *catalog_mod.Catalog, label: []const u8) !void {
            for (cat.profiles.items) |existing| {
                if (std.mem.eql(u8, existing, label)) return;
            }
            const owned = try allocator.dupe(u8, label);
            errdefer allocator.free(owned);
            try cat.profiles.append(allocator, owned);
        }

        pub fn appendSchemaFileProfilesToCatalog(
            allocator: std.mem.Allocator,
            io: std.Io,
            schema_path: []const u8,
            cat: *catalog_mod.Catalog,
        ) !void {
            var parsed = try parseSchemaFileDocument(allocator, io, schema_path);
            defer parsed.deinit();
            try appendSchemaDocumentProfilesToCatalog(allocator, parsed.value, cat);
        }

        pub fn appendSchemaDocumentProfilesToCatalog(
            allocator: std.mem.Allocator,
            document: SchemaFileJson,
            cat: *catalog_mod.Catalog,
        ) !void {
            const profiles = document.profiles orelse return;
            for (profiles) |raw_label| {
                const profile = schema.BuiltinProfile.fromLabel(raw_label) orelse return error.InvalidRecord;
                try appendCatalogProfileLabel(allocator, cat, profile.label());
            }
        }

        pub fn catalogProfilesMatchCsv(cat: catalog_mod.Catalog, profiles: []const u8) bool {
            var requested_count: usize = 0;
            var profile_it = std.mem.tokenizeScalar(u8, profiles, ',');
            while (profile_it.next()) |raw| {
                const label = std.mem.trim(u8, raw, " \t\r\n");
                const profile = schema.BuiltinProfile.fromLabel(label) orelse return false;
                var found = false;
                for (cat.profiles.items) |existing| {
                    if (std.mem.eql(u8, existing, profile.label())) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
                requested_count += 1;
            }
            return requested_count == cat.profiles.items.len;
        }

        pub fn catalogProfilesCsvAlloc(allocator: std.mem.Allocator, cat: catalog_mod.Catalog) ![]u8 {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            for (cat.profiles.items, 0..) |profile, index| {
                if (index != 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, profile);
            }
            return try out.toOwnedSlice(allocator);
        }

        pub fn validateSchemaMigratePathRelationship(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedSchemaMigrateArgs) !void {
            if (!try existingTinyKgStorePath(allocator, io, parsed.old_db_path)) return error.FileNotFound;
            if (try pathsOverlapForCopyTarget(allocator, io, parsed.old_db_path, parsed.new_db_path)) return error.InvalidFileName;
        }

        pub fn validateSchemaMigratePaths(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedSchemaMigrateArgs) !void {
            try validateSchemaMigratePathRelationship(allocator, io, parsed);
            // Any pre-existing path is foreign state.  Looking only for a TinyKG
            // marker allowed an empty/non-store directory to be opened and then
            // recursively deleted by migration cleanup.
            if (try anyPathExists(io, parsed.new_db_path)) return error.AlreadyExists;
        }

        pub fn migrationPropertyKeyValid(key: []const u8) bool {
            if (key.len == 0 or key.len > 128) return false;
            for (key) |byte| {
                const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == ':' or byte == '.';
                if (!ok) return false;
            }
            return true;
        }

        pub fn migrationPropertySuppressedByTaskStatusV1(key: []const u8, materialize_status: bool, force_task_schema: bool) bool {
            return (materialize_status and
                (std.mem.eql(u8, key, task.status_property) or
                    std.mem.eql(u8, key, task.claim_expires_ns_property) or
                    std.mem.eql(u8, key, "task_completed_ns"))) or
                (force_task_schema and std.mem.eql(u8, key, "schema_type"));
        }

        fn appendMigrationSnapshotProperty(
            source_properties: *const MigrationPropertyLookup,
            owner: storage.PropertyOwner,
            key: []const u8,
            target_property: ?schema.PropertyMeta,
            batch: *MigrationPropertyBatch,
        ) !u64 {
            const entry = source_properties.get(owner, key) orelse return 0;
            if (target_property) |property| {
                switch (property.value_type) {
                    .string, .json => if (entry.value_kind != .string) return error.SchemaPropertyValueMismatch,
                    .@"enum" => {
                        if (entry.value_kind != .string or !property.enumAllows(entry.string_value)) return error.SchemaPropertyValueMismatch;
                    },
                    .uint => if (entry.value_kind != .uint) return error.SchemaPropertyValueMismatch,
                    // The current persistent property payload has no signed/bool
                    // value variant.  A catalog may describe those types for future
                    // evolution, but schema migration must not reinterpret an
                    // existing string/uint payload as one of them.
                    .int, .bool => return error.SchemaPropertyValueMismatch,
                }
            }
            switch (entry.value_kind) {
                .string => try batch.appendString(owner, key, entry.string_value),
                .uint => try batch.appendUint(owner, key, entry.uint_value),
            }
            return 1;
        }

        pub fn ensureDeclaredNodePropertiesRetained(
            source_properties: *const MigrationPropertyLookup,
            source_registry: schema.Registry,
            source_type_id: u16,
            target_registry: schema.Registry,
            target_type_id: u16,
            node_id: core.NodeId,
        ) !void {
            var property_index: usize = 0;
            while (source_registry.nodePropertyInfo(source_type_id, property_index)) |property| : (property_index += 1) {
                if (source_properties.get(.{ .node = node_id }, property.name) == null) continue;
                if (target_registry.nodePropertyByTypeId(target_type_id, property.name) == null) return error.SchemaOrphanedPropertyInUse;
            }
        }

        pub fn ensureDeclaredEdgePropertiesRetained(
            source_properties: *const MigrationPropertyLookup,
            source_registry: schema.Registry,
            source_type_id: u16,
            target_registry: schema.Registry,
            target_type_id: u16,
            edge_id: core.EdgeId,
        ) !void {
            var property_index: usize = 0;
            while (source_registry.relationPropertyInfo(source_type_id, property_index)) |property| : (property_index += 1) {
                if (source_properties.get(.{ .edge = edge_id }, property.name) == null) continue;
                if (target_registry.relationPropertyByTypeId(target_type_id, property.name) == null) return error.SchemaOrphanedPropertyInUse;
            }
        }

        pub fn collectKnownNodeProperties(
            source_properties: *const MigrationPropertyLookup,
            registry: schema.Registry,
            target_type_id: u16,
            node_id: core.NodeId,
            batch: *MigrationPropertyBatch,
            materialize_status: bool,
            force_task_schema: bool,
        ) !u64 {
            var count: u64 = 0;
            const owner: storage.PropertyOwner = .{ .node = node_id };
            var seen = std.AutoHashMap(u64, void).init(batch.allocator);
            defer seen.deinit();
            for (migrate_node_string_property_keys) |key| {
                if (migrationPropertySuppressedByTaskStatusV1(key, materialize_status, force_task_schema)) continue;
                try seen.put(storage.propertyKeyHashForLookup(key), {});
                const target_property = registry.nodePropertyByTypeId(target_type_id, key);
                const copied = try appendMigrationSnapshotProperty(source_properties, owner, key, target_property, batch);
                if (copied == 0 and target_property != null and target_property.?.required and !std.mem.eql(u8, key, "text")) return error.SchemaRequiredPropertyMissing;
                count += copied;
            }
            for (migrate_node_uint_property_keys) |key| {
                if (migrationPropertySuppressedByTaskStatusV1(key, materialize_status, force_task_schema)) continue;
                const key_hash = storage.propertyKeyHashForLookup(key);
                const seen_entry = try seen.getOrPut(key_hash);
                if (seen_entry.found_existing) continue;
                const target_property = registry.nodePropertyByTypeId(target_type_id, key);
                const copied = try appendMigrationSnapshotProperty(source_properties, owner, key, target_property, batch);
                if (copied == 0 and target_property != null and target_property.?.required) return error.SchemaRequiredPropertyMissing;
                count += copied;
            }
            var property_index: usize = 0;
            while (registry.nodePropertyInfo(target_type_id, property_index)) |property| : (property_index += 1) {
                if (migrationPropertySuppressedByTaskStatusV1(property.name, materialize_status, force_task_schema)) continue;
                const seen_entry = try seen.getOrPut(storage.propertyKeyHashForLookup(property.name));
                if (seen_entry.found_existing) continue;
                const copied = try appendMigrationSnapshotProperty(source_properties, owner, property.name, property, batch);
                if (copied == 0 and property.required and !std.mem.eql(u8, property.name, "text")) return error.SchemaRequiredPropertyMissing;
                count += copied;
            }
            return count;
        }

        pub fn collectKnownEdgeProperties(
            source_properties: *const MigrationPropertyLookup,
            registry: schema.Registry,
            target_type_id: u16,
            edge_id: core.EdgeId,
            source_edge_order_map: ?*const std.AutoHashMap(u64, u64),
            batch: *MigrationPropertyBatch,
        ) !u64 {
            var count: u64 = 0;
            const owner: storage.PropertyOwner = .{ .edge = edge_id };
            var seen = std.AutoHashMap(u64, void).init(batch.allocator);
            defer seen.deinit();
            for (migrate_edge_string_property_keys) |key| {
                try seen.put(storage.propertyKeyHashForLookup(key), {});
                const target_property = registry.relationPropertyByTypeId(target_type_id, key);
                const copied = try appendMigrationSnapshotProperty(source_properties, owner, key, target_property, batch);
                if (copied == 0 and target_property != null and target_property.?.required) return error.SchemaRequiredPropertyMissing;
                count += copied;
            }
            for (migrate_edge_uint_property_keys) |key| {
                if (std.mem.eql(u8, key, "order_key") and source_edge_order_map != null and source_edge_order_map.?.contains(edge_id.toInt())) continue;
                const seen_entry = try seen.getOrPut(storage.propertyKeyHashForLookup(key));
                if (seen_entry.found_existing) continue;
                const target_property = registry.relationPropertyByTypeId(target_type_id, key);
                const copied = try appendMigrationSnapshotProperty(source_properties, owner, key, target_property, batch);
                if (copied == 0 and target_property != null and target_property.?.required) return error.SchemaRequiredPropertyMissing;
                count += copied;
            }
            var property_index: usize = 0;
            while (registry.relationPropertyInfo(target_type_id, property_index)) |property| : (property_index += 1) {
                if (std.mem.eql(u8, property.name, "order_key") and source_edge_order_map != null and source_edge_order_map.?.contains(edge_id.toInt())) continue;
                const seen_entry = try seen.getOrPut(storage.propertyKeyHashForLookup(property.name));
                if (seen_entry.found_existing) continue;
                const copied = try appendMigrationSnapshotProperty(source_properties, owner, property.name, property, batch);
                if (copied == 0 and property.required) return error.SchemaRequiredPropertyMissing;
                count += copied;
            }
            return count;
        }

        pub fn exportTemporaryPath(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, suffix: []const u8) ![]u8 {
            const nonce = export_temp_nonce.fetchAdd(1, .monotonic);
            return try std.fmt.allocPrint(
                allocator,
                "{s}.tinykg-export-{d}-{d}.{s}",
                .{ dir_path, persistentNowNs(io), nonce, suffix },
            );
        }

        pub fn renamePath(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
            if (std.fs.path.isAbsolute(old_path) or std.fs.path.isAbsolute(new_path)) {
                try std.Io.Dir.renameAbsolute(old_path, new_path, io);
            } else {
                try std.Io.Dir.rename(.cwd(), old_path, .cwd(), new_path, io);
            }
        }

        pub fn writeAtomicReplacementFile(io: std.Io, tmp_path: []const u8, final_path: []const u8, bytes: []const u8) !void {
            var tmp_owned = false;
            errdefer if (tmp_owned) std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true, .exclusive = true });
                tmp_owned = true;
                defer file.close(io);
                try file.writePositionalAll(io, bytes, 0);
                try file.sync(io);
            }
            try renamePath(io, tmp_path, final_path);
            tmp_owned = false;
            try syncParentDirectory(io, final_path);
        }

        /// Complete a marker publication interrupted after its fixed temp file was
        /// written. Callers hold the transaction's stable publication lock (or own a
        /// newly-created private staging directory), so an existing exact byte match
        /// is a request-bound recovery artifact rather than a concurrent writer.
        /// Unknown or partial temp content is never removed or overwritten.
        pub fn writeRecoverableTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            tmp_path: []const u8,
            final_path: []const u8,
            bytes: []const u8,
        ) !void {
            const stat = std.Io.Dir.cwd().statFile(io, tmp_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return writeAtomicReplacementFile(io, tmp_path, final_path, bytes) catch |write_err| switch (write_err) {
                    error.PathAlreadyExists => error.TransactionMarkerConflict,
                    else => |e| e,
                },
                else => |e| return e,
            };
            if (stat.kind != .file) return error.TransactionMarkerConflict;
            const read_limit = std.math.add(usize, bytes.len, 1) catch return error.TransactionMarkerConflict;
            const existing = std.Io.Dir.cwd().readFileAlloc(io, tmp_path, allocator, .limited(read_limit)) catch |err| switch (err) {
                error.StreamTooLong, error.FileNotFound, error.NotDir, error.IsDir => return error.TransactionMarkerConflict,
                else => |e| return e,
            };
            defer allocator.free(existing);
            if (!std.mem.eql(u8, existing, bytes)) return error.TransactionMarkerConflict;

            // The former writer may have died before fsync returned. Re-sync the
            // validated inode ourselves before making its name authoritative.
            {
                var file = std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_write, .allow_directory = false }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.IsDir => return error.TransactionMarkerConflict,
                    else => |e| return e,
                };
                defer file.close(io);
                try file.sync(io);
            }
            try renamePath(io, tmp_path, final_path);
            try syncParentDirectory(io, final_path);
        }

        test "atomic replacement never deletes an unowned temp file" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const tmp_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "marker.tmp" });
            defer std.testing.allocator.free(tmp_path);
            const final_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "marker" });
            defer std.testing.allocator.free(final_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = tmp_path,
                .data = "foreign temp contents",
                .flags = .{ .truncate = true },
            });
            try std.testing.expectError(error.PathAlreadyExists, writeAtomicReplacementFile(std.testing.io, tmp_path, final_path, "ours"));
            const preserved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, tmp_path, std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(preserved);
            try std.testing.expectEqualStrings("foreign temp contents", preserved);
            try std.testing.expect(!try anyPathExists(std.testing.io, final_path));
        }

        test "recoverable transaction marker promotes only exact temp content" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const tmp_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "marker.tmp" });
            defer std.testing.allocator.free(tmp_path);
            const final_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "marker" });
            defer std.testing.allocator.free(final_path);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = tmp_path,
                .data = "complete request-bound marker",
                .flags = .{ .truncate = true },
            });
            try writeRecoverableTransactionMarker(
                std.testing.allocator,
                std.testing.io,
                tmp_path,
                final_path,
                "complete request-bound marker",
            );
            try std.testing.expect(!try anyPathExists(std.testing.io, tmp_path));
            const published = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, final_path, std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(published);
            try std.testing.expectEqualStrings("complete request-bound marker", published);

            try std.Io.Dir.cwd().writeFile(std.testing.io, .{
                .sub_path = tmp_path,
                .data = "foreign marker",
                .flags = .{ .truncate = true },
            });
            try std.testing.expectError(
                error.TransactionMarkerConflict,
                writeRecoverableTransactionMarker(std.testing.allocator, std.testing.io, tmp_path, final_path, "new marker"),
            );
            const preserved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, tmp_path, std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(preserved);
            try std.testing.expectEqualStrings("foreign marker", preserved);
            const final_preserved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, final_path, std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(final_preserved);
            try std.testing.expectEqualStrings("complete request-bound marker", final_preserved);
        }

        fn moveTransactionMarkerToTmpForTest(allocator: std.mem.Allocator, io: std.Io, marker_path: []const u8) !void {
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
            defer allocator.free(tmp_path);
            try renamePath(io, marker_path, tmp_path);
            try syncParentDirectory(io, tmp_path);
        }

        test "transaction staging recovery accepts validated marker temp files" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const root = path_buf[0..root_len];

            const migrate_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "migrate-staging" });
            defer std.testing.allocator.free(migrate_dir);
            try createOwnedDirectory(std.testing.io, migrate_dir);
            const migrate_expected = StoreMigrationV2TransactionExpectation{
                .canonical_source_path = "/source",
                .canonical_backup_path = "/backup",
                .source_store_bytes = 11,
                .source_store_digest = .{ 1, 2, 3, 4 },
                .target_profiles = "agent-dag",
                .target_catalog_revision = 2,
                .target_schema_version = 3,
                .strict = true,
                .warm_text = false,
                .verify = true,
                .task_status_v1 = true,
            };
            try writeStoreMigrationV2TransactionMarker(std.testing.allocator, std.testing.io, migrate_dir, migrate_expected, null);
            const migrate_marker = try storeMigrationV2TransactionMarkerPath(std.testing.allocator, migrate_dir);
            defer std.testing.allocator.free(migrate_marker);
            try moveTransactionMarkerToTmpForTest(std.testing.allocator, std.testing.io, migrate_marker);
            try recoverStoreMigrationV2Staging(std.testing.allocator, std.testing.io, migrate_dir, migrate_expected);
            try std.testing.expect(!try anyPathExists(std.testing.io, migrate_dir));

            const import_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "import-staging" });
            defer std.testing.allocator.free(import_dir);
            try createOwnedDirectory(std.testing.io, import_dir);
            const import_expected = ImportTransactionExpectation{
                .format = "jsonl",
                .canonical_source_path = "/source.jsonl",
                .source_digest = .{ 5, 6, 7, 8 },
                .warm_text = false,
            };
            try writeImportTransactionMarker(std.testing.allocator, std.testing.io, import_dir, import_expected, null);
            const import_marker = try importTransactionMarkerPath(std.testing.allocator, import_dir);
            defer std.testing.allocator.free(import_marker);
            try moveTransactionMarkerToTmpForTest(std.testing.allocator, std.testing.io, import_marker);
            try recoverImportStaging(std.testing.allocator, std.testing.io, import_dir, import_expected, .{});
            try std.testing.expect(!try anyPathExists(std.testing.io, import_dir));

            const schema_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "schema-staging" });
            defer std.testing.allocator.free(schema_dir);
            try createOwnedDirectory(std.testing.io, schema_dir);
            const schema_expected = SchemaMigrationTransactionExpectation{
                .canonical_source_path = "/schema-source",
                .source_store_bytes = 12,
                .source_store_digest = .{ 9, 10, 11, 12 },
                .source_registry_digest = .{ 13, 14, 15, 16 },
                .target_catalog_digest = .{ 17, 18, 19, 20 },
                .target_profiles = "agent-dag",
                .target_schema_version = 3,
                .target_kind_remaps = 0,
            };
            try writeSchemaMigrationTransactionMarker(std.testing.allocator, std.testing.io, schema_dir, schema_expected, null);
            const schema_marker = try schemaMigrationTransactionMarkerPath(std.testing.allocator, schema_dir);
            defer std.testing.allocator.free(schema_marker);
            try moveTransactionMarkerToTmpForTest(std.testing.allocator, std.testing.io, schema_marker);
            try recoverSchemaMigrationStaging(std.testing.allocator, std.testing.io, schema_dir, schema_expected);
            try std.testing.expect(!try anyPathExists(std.testing.io, schema_dir));

            const backup_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "backup-staging" });
            defer std.testing.allocator.free(backup_dir);
            try createOwnedDirectory(std.testing.io, backup_dir);
            const backup_expected = BackupTransactionExpectation{
                .canonical_source_path = "/backup-source",
                .nodes = 1,
                .edges = 2,
                .source_store_bytes = 13,
                .source_store_digest = .{ 21, 22, 23, 24 },
                .source_payload_bytes = 14,
                .source_payload_digest = .{ 25, 26, 27, 28 },
            };
            try writeBackupTransactionMarker(std.testing.allocator, std.testing.io, backup_dir, backup_expected, false);
            const backup_marker = try backupTransactionMarkerPath(std.testing.allocator, backup_dir);
            defer std.testing.allocator.free(backup_marker);
            try moveTransactionMarkerToTmpForTest(std.testing.allocator, std.testing.io, backup_marker);
            try recoverBackupStaging(std.testing.allocator, std.testing.io, backup_dir, backup_expected);
            try std.testing.expect(!try anyPathExists(std.testing.io, backup_dir));

            const restore_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "restore-staging" });
            defer std.testing.allocator.free(restore_dir);
            try createOwnedDirectory(std.testing.io, restore_dir);
            const restore_expected = RestoreTransactionExpectation{
                .canonical_source_path = "/restore-source",
                .nodes = 3,
                .edges = 4,
                .source_store_bytes = 15,
                .source_store_digest = .{ 29, 30, 31, 32 },
            };
            try writeRestoreTransactionMarker(std.testing.allocator, std.testing.io, restore_dir, restore_expected, false);
            const restore_marker = try restoreTransactionMarkerPath(std.testing.allocator, restore_dir);
            defer std.testing.allocator.free(restore_marker);
            try moveTransactionMarkerToTmpForTest(std.testing.allocator, std.testing.io, restore_marker);
            try recoverRestoreStaging(std.testing.allocator, std.testing.io, restore_dir, restore_expected);
            try std.testing.expect(!try anyPathExists(std.testing.io, restore_dir));
        }

        pub fn syncParentDirectory(io: std.Io, path: []const u8) !void {
            if (builtin.os.tag == .windows) return;
            const parent = std.fs.path.dirname(path) orelse ".";
            var dir_file = if (std.fs.path.isAbsolute(parent))
                try std.Io.Dir.openFileAbsolute(io, parent, .{ .allow_directory = true })
            else
                try std.Io.Dir.cwd().openFile(io, parent, .{ .allow_directory = true });
            defer dir_file.close(io);
            try dir_file.sync(io);
        }

        pub fn syncExportDirectoryTree(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
            if (builtin.os.tag == .windows) return;
            var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(child_path);
                switch (entry.kind) {
                    .file => {
                        var file = try std.Io.Dir.cwd().openFile(io, child_path, .{});
                        defer file.close(io);
                        try file.sync(io);
                    },
                    .directory => try syncExportDirectoryTree(allocator, io, child_path),
                    else => return core.Error.Unsupported,
                }
            }
            var dir_file = if (std.fs.path.isAbsolute(dir_path))
                try std.Io.Dir.openFileAbsolute(io, dir_path, .{ .allow_directory = true })
            else
                try std.Io.Dir.cwd().openFile(io, dir_path, .{ .allow_directory = true });
            defer dir_file.close(io);
            try dir_file.sync(io);
        }

        pub fn exportBackupPath(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_path, export_backup_suffix });
        }

        fn exportTransactionMarkerPath(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
            return try std.fs.path.join(allocator, &.{ dir_path, export_transaction_marker_file });
        }

        pub fn writeExportTransactionMarker(allocator: std.mem.Allocator, io: std.Io, staging_path: []const u8) !void {
            const marker_path = try exportTransactionMarkerPath(allocator, staging_path);
            defer allocator.free(marker_path);
            if (try anyPathExists(io, marker_path)) return error.AlreadyExists;
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = marker_path,
                .data = export_transaction_marker_magic,
                .flags = .{ .truncate = false },
            });
        }

        pub fn exportTransactionMarkerPresent(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !bool {
            const marker_path = try exportTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const content = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(128)) catch |err| switch (err) {
                error.FileNotFound => return false,
                error.StreamTooLong => return error.InvalidRecord,
                else => |e| return e,
            };
            defer allocator.free(content);
            if (!std.mem.eql(u8, content, export_transaction_marker_magic)) return error.InvalidRecord;
            return true;
        }

        fn deleteExportTransactionMarker(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
            const marker_path = try exportTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            try std.Io.Dir.cwd().deleteFile(io, marker_path);
            try syncParentDirectory(io, marker_path);
        }

        pub const ExportPublicationRecovery = enum {
            none,
            recovered,
            recovered_cleanup_pending,
        };

        /// The new export becomes committed once its directory rename and the parent
        /// directory sync both succeed. Backup and marker deletion happen strictly
        /// after that point: report incomplete garbage collection as state instead of
        /// turning a committed export into a false failure.
        pub fn cleanupExportPublicationAfterCommit(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            backup_path: ?[]const u8,
        ) bool {
            return cleanupExportPublicationAfterCommitWithDeleteTree(allocator, io, dir_path, backup_path, deleteExportTree);
        }

        fn deleteExportTree(io: std.Io, path: []const u8) !void {
            try std.Io.Dir.cwd().deleteTree(io, path);
        }

        pub fn cleanupExportPublicationAfterCommitWithDeleteTree(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            backup_path: ?[]const u8,
            delete_tree: anytype,
        ) bool {
            if (backup_path) |path| {
                delete_tree(io, path) catch return false;
                syncParentDirectory(io, path) catch return false;
            }
            deleteExportTransactionMarker(allocator, io, dir_path) catch return false;
            return true;
        }

        /// Finish or roll back a publication interrupted while holding the stable
        /// adjacent export lock.  A promoted staging tree carries the private marker;
        /// a destination without it is treated as foreign and never overwrites or
        /// destroys the retained backup.
        pub fn recoverExportPublication(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, backup_path: []const u8) !ExportPublicationRecovery {
            const backup_exists = try anyPathExists(io, backup_path);
            const destination_exists = try anyPathExists(io, dir_path);
            if (backup_exists) {
                const backup_stat = try std.Io.Dir.cwd().statFile(io, backup_path, .{ .follow_symlinks = false });
                if (backup_stat.kind != .directory) return error.InvalidFileName;
                if (!destination_exists) {
                    try renamePath(io, backup_path, dir_path);
                    try syncParentDirectory(io, dir_path);
                    return .none;
                }
                const destination_stat = try std.Io.Dir.cwd().statFile(io, dir_path, .{ .follow_symlinks = false });
                if (destination_stat.kind != .directory) return error.ExportRestoreConflict;
                if (!try exportTransactionMarkerPresent(allocator, io, dir_path)) return error.ExportRestoreConflict;
                return if (cleanupExportPublicationAfterCommit(allocator, io, dir_path, backup_path))
                    .recovered
                else
                    .recovered_cleanup_pending;
            }
            if (destination_exists and try exportTransactionMarkerPresent(allocator, io, dir_path)) {
                return if (cleanupExportPublicationAfterCommit(allocator, io, dir_path, null))
                    .recovered
                else
                    .recovered_cleanup_pending;
            }
            return .none;
        }

        pub fn publishExportDirectory(allocator: std.mem.Allocator, io: std.Io, staging_path: []const u8, dir_path: []const u8, backup_path: []const u8) !bool {
            const destination_exists = try anyPathExists(io, dir_path);
            if (destination_exists) {
                const stat = try std.Io.Dir.cwd().statFile(io, dir_path, .{ .follow_symlinks = false });
                if (stat.kind != .directory) return error.InvalidFileName;
                try renamePath(io, dir_path, backup_path);
                try syncParentDirectory(io, dir_path);
                renamePath(io, staging_path, dir_path) catch |publish_err| {
                    // Never overwrite a destination concurrently created by an
                    // external writer.  If that prevents restoring the old export,
                    // surface a distinct error and retain the recognizable .bak tree
                    // for manual recovery instead of silently swallowing data loss.
                    renamePath(io, backup_path, dir_path) catch return error.ExportRestoreConflict;
                    try syncParentDirectory(io, dir_path);
                    return publish_err;
                };
                try syncParentDirectory(io, dir_path);
                return !cleanupExportPublicationAfterCommit(allocator, io, dir_path, backup_path);
            }
            try renamePath(io, staging_path, dir_path);
            try syncParentDirectory(io, dir_path);
            return !cleanupExportPublicationAfterCommit(allocator, io, dir_path, null);
        }

        pub const ImportTransactionExpectation = struct {
            format: []const u8,
            canonical_source_path: []const u8,
            source_digest: ContentDigest,
            warm_text: bool,
            chunk_size: u64 = 0,
        };

        pub const ContentDigest = [4]u64;

        pub const ImportPublicationResult = struct {
            nodes_loaded: u64 = 0,
            nodes_imported: u64 = 0,
            edges_loaded: u64 = 0,
            edges_imported: u64 = 0,
            edges_skipped_missing_endpoint: u64 = 0,
            deferred_based_on_loaded: u64 = 0,
            deferred_based_on_imported: u64 = 0,
            source_bytes: u64 = 0,
            text_warmed: bool = false,
            published_store_bytes: u64 = 0,
            published_store_digest: ContentDigest = .{ 0, 0, 0, 0 },
            marker_cleanup_pending: bool = false,
        };

        const ImportTransactionMarkerJson = struct {
            marker_format: []const u8,
            import_format: []const u8,
            canonical_source_path: []const u8,
            source_digest: ContentDigest,
            warm_text: bool,
            chunk_size: u64 = 0,
            complete: bool,
            result: ?ImportPublicationResult = null,
        };

        const ImportMarkerState = struct {
            complete: bool,
            result: ?ImportPublicationResult,
            legacy_format: bool,
        };

        pub fn importStagingPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ target_path, import_staging_suffix });
        }

        pub fn importTransactionMarkerPath(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
            return try std.fs.path.join(allocator, &.{ dir_path, import_transaction_marker_file });
        }

        fn appendImportPublicationResultJson(out: *QueryOutputWriter, result: ImportPublicationResult) !void {
            try out.print(
                "{{\"nodes_loaded\":{},\"nodes_imported\":{},\"edges_loaded\":{},\"edges_imported\":{},\"edges_skipped_missing_endpoint\":{},\"deferred_based_on_loaded\":{},\"deferred_based_on_imported\":{},\"source_bytes\":{},\"text_warmed\":{},\"published_store_bytes\":{},\"published_store_digest\":[{},{},{},{}],\"marker_cleanup_pending\":{}}}",
                .{
                    result.nodes_loaded,
                    result.nodes_imported,
                    result.edges_loaded,
                    result.edges_imported,
                    result.edges_skipped_missing_endpoint,
                    result.deferred_based_on_loaded,
                    result.deferred_based_on_imported,
                    result.source_bytes,
                    result.text_warmed,
                    result.published_store_bytes,
                    result.published_store_digest[0],
                    result.published_store_digest[1],
                    result.published_store_digest[2],
                    result.published_store_digest[3],
                    result.marker_cleanup_pending,
                },
            );
        }

        fn contentDigestFromSha256(bytes: [32]u8) ContentDigest {
            return .{
                std.mem.readInt(u64, bytes[0..8], .little),
                std.mem.readInt(u64, bytes[8..16], .little),
                std.mem.readInt(u64, bytes[16..24], .little),
                std.mem.readInt(u64, bytes[24..32], .little),
            };
        }

        pub fn finalizeContentDigest(hasher: *std.crypto.hash.sha2.Sha256) ContentDigest {
            var bytes: [32]u8 = undefined;
            hasher.final(&bytes);
            return contentDigestFromSha256(bytes);
        }

        pub fn contentDigestForBytes(bytes: []const u8) ContentDigest {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(bytes);
            return finalizeContentDigest(&hasher);
        }

        pub fn importPublicationMatchesSource(actual: ImportPublicationResult, expected: ImportPublicationResult) bool {
            return actual.nodes_loaded == expected.nodes_loaded and
                actual.nodes_imported == expected.nodes_imported and
                actual.edges_loaded == expected.edges_loaded and
                actual.edges_imported == expected.edges_imported and
                actual.edges_skipped_missing_endpoint == expected.edges_skipped_missing_endpoint and
                actual.deferred_based_on_loaded == expected.deferred_based_on_loaded and
                actual.deferred_based_on_imported == expected.deferred_based_on_imported and
                actual.source_bytes == expected.source_bytes and
                actual.text_warmed == expected.text_warmed;
        }

        pub fn writeImportTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: ImportTransactionExpectation,
            result: ?ImportPublicationResult,
        ) !void {
            const marker_path = try importTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
            defer allocator.free(tmp_path);
            var out = QueryOutputWriter{ .allocator = allocator };
            defer out.buffer.deinit(allocator);
            try out.writeAll("{\"marker_format\":");
            try writeJsonString(&out, import_transaction_marker_format);
            try out.writeAll(",\"import_format\":");
            try writeJsonString(&out, expected.format);
            try out.writeAll(",\"canonical_source_path\":");
            try writeJsonString(&out, expected.canonical_source_path);
            try out.print(
                ",\"source_digest\":[{},{},{},{}],\"warm_text\":{},\"chunk_size\":{},\"complete\":{},\"result\":",
                .{
                    expected.source_digest[0],
                    expected.source_digest[1],
                    expected.source_digest[2],
                    expected.source_digest[3],
                    expected.warm_text,
                    expected.chunk_size,
                    result != null,
                },
            );
            if (result) |value| {
                try appendImportPublicationResultJson(&out, value);
            } else {
                try out.writeAll("null");
            }
            try out.writeAll("}\n");
            writeRecoverableTransactionMarker(allocator, io, tmp_path, marker_path, out.buffer.items) catch |err| switch (err) {
                error.TransactionMarkerConflict => return error.ImportRecoveryConflict,
                else => |e| return e,
            };
        }

        fn readImportTransactionMarker(
            allocator: std.mem.Allocator,
            io: std.Io,
            dir_path: []const u8,
            expected: ImportTransactionExpectation,
        ) !?ImportMarkerState {
            const marker_path = try importTransactionMarkerPath(allocator, dir_path);
            defer allocator.free(marker_path);
            return try readImportTransactionMarkerAtPath(allocator, io, marker_path, expected);
        }

        fn readImportTransactionMarkerAtPath(
            allocator: std.mem.Allocator,
            io: std.Io,
            marker_path: []const u8,
            expected: ImportTransactionExpectation,
        ) !?ImportMarkerState {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(32 * 1024)) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return null,
                error.StreamTooLong => return error.InvalidRecord,
                else => |e| return e,
            };
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(ImportTransactionMarkerJson, allocator, bytes, .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
            }) catch return error.InvalidRecord;
            defer parsed.deinit();
            const marker = parsed.value;
            const legacy_format = std.mem.eql(u8, marker.marker_format, import_transaction_marker_legacy_format);
            if ((!std.mem.eql(u8, marker.marker_format, import_transaction_marker_format) and !legacy_format) or
                !std.mem.eql(u8, marker.import_format, expected.format) or
                !std.mem.eql(u8, marker.canonical_source_path, expected.canonical_source_path) or
                !std.meta.eql(marker.source_digest, expected.source_digest) or
                marker.warm_text != expected.warm_text or
                marker.chunk_size != expected.chunk_size)
            {
                return error.ImportRecoveryConflict;
            }
            if (marker.complete != (marker.result != null)) return error.InvalidRecord;
            if (marker.result) |result| {
                if (result.marker_cleanup_pending or
                    result.text_warmed != expected.warm_text or
                    result.published_store_bytes == 0 or
                    std.meta.eql(result.published_store_digest, ContentDigest{ 0, 0, 0, 0 }) or
                    result.nodes_imported > result.nodes_loaded or
                    result.edges_imported > result.edges_loaded or
                    result.edges_skipped_missing_endpoint > result.edges_loaded or
                    result.deferred_based_on_imported > result.deferred_based_on_loaded)
                {
                    return error.InvalidRecord;
                }
            }
            return .{ .complete = marker.complete, .result = marker.result, .legacy_format = legacy_format };
        }

        pub fn recoverImportStaging(
            allocator: std.mem.Allocator,
            io: std.Io,
            staging_path: []const u8,
            expected: ImportTransactionExpectation,
            expected_result: ImportPublicationResult,
        ) !void {
            if (!try anyPathExists(io, staging_path)) return;
            const stat = try std.Io.Dir.cwd().statFile(io, staging_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.ImportRecoveryConflict;
            var marker = try readImportTransactionMarker(allocator, io, staging_path, expected);
            if (marker == null) {
                const marker_path = try importTransactionMarkerPath(allocator, staging_path);
                defer allocator.free(marker_path);
                const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{marker_path});
                defer allocator.free(tmp_path);
                marker = try readImportTransactionMarkerAtPath(allocator, io, tmp_path, expected);
            }
            const owned_marker = marker orelse return error.ImportRecoveryConflict;
            if (owned_marker.result) |result| {
                if (!importPublicationMatchesSource(result, expected_result)) return error.ImportRecoveryConflict;
            }
            try std.Io.Dir.cwd().deleteTree(io, staging_path);
            try syncParentDirectory(io, staging_path);
        }

        fn importManifestName(import_format: []const u8) ![]const u8 {
            if (std.mem.eql(u8, import_format, "jsonl")) return "import-jsonl";
            if (std.mem.eql(u8, import_format, "markdown")) return "import-markdown";
            if (std.mem.eql(u8, import_format, "metaknow-replay")) return "import-metaknow-replay";
            return error.InvalidRecord;
        }

        pub fn recoverCompletedImport(
            allocator: std.mem.Allocator,
            io: std.Io,
            target_path: []const u8,
            expected: ImportTransactionExpectation,
            expected_result: ImportPublicationResult,
        ) !?ImportPublicationResult {
            if (!try anyPathExists(io, target_path)) return null;
            const stat = try std.Io.Dir.cwd().statFile(io, target_path, .{ .follow_symlinks = false });
            if (stat.kind != .directory) return error.AlreadyExists;
            const marker = (try readImportTransactionMarker(allocator, io, target_path, expected)) orelse
                return error.AlreadyExists;
            if (!marker.complete) return error.InvalidRecord;
            var result = marker.result orelse return error.InvalidRecord;
            if (!importPublicationMatchesSource(result, expected_result)) return error.ImportRecoveryConflict;
            const store_lock = try CliStoreLock.acquire(allocator, io, target_path);
            defer store_lock.deinit();
            const locked_marker = (try readImportTransactionMarker(allocator, io, target_path, expected)) orelse
                return error.ImportRecoveryConflict;
            if (!locked_marker.complete) return error.InvalidRecord;
            result = locked_marker.result orelse return error.InvalidRecord;
            if (!importPublicationMatchesSource(result, expected_result)) return error.ImportRecoveryConflict;
            const identity = try storeContentIdentity(allocator, io, target_path);
            if (identity.bytes != result.published_store_bytes or
                !std.meta.eql(identity.digest, result.published_store_digest))
            {
                return error.ImportRecoveryConflict;
            }
            if (!try existingTinyKgStorePath(allocator, io, target_path)) return error.InvalidRecord;
            var store = try storage.Store.open(allocator, io, target_path);
            defer store.deinit();
            const stats_out = try store.stats();
            if (stats_out.nodes != result.nodes_imported or stats_out.edges != result.edges_imported) return error.InvalidRecord;
            const manifest = try readStoreManifestSummary(allocator, io, target_path);
            defer manifest.deinit(allocator);
            if (!std.mem.eql(u8, manifest.status, "present") or
                !std.mem.eql(u8, manifest.storage_format_version, "2") or
                !std.mem.eql(u8, manifest.schema_version, "3") or
                manifest.enabled_profiles.len != 0 or
                !std.mem.eql(u8, manifest.migration_name, try importManifestName(expected.format)) or
                manifest.migration_source.len != 0)
            {
                return error.ImportRecoveryConflict;
            }
            if (expected.warm_text and try text_search.persistentTextCatalogQuickStale(allocator, store)) return error.InvalidRecord;
            if (locked_marker.legacy_format) {
                try writeImportTransactionMarker(allocator, io, target_path, expected, result);
            }
            try syncParentDirectory(io, target_path);
            // Retain the complete request-bound marker as a commit receipt.  Import
            // results are otherwise indistinguishable from a foreign store once the
            // caller's success response is lost.
            result.marker_cleanup_pending = false;
            return result;
        }

        pub fn updateImportDigest(hasher: *std.crypto.hash.sha2.Sha256, label: []const u8, bytes: []const u8) void {
            var length_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &length_bytes, label.len, .little);
            hasher.update(&length_bytes);
            hasher.update(label);
            std.mem.writeInt(u64, &length_bytes, bytes.len, .little);
            hasher.update(&length_bytes);
            hasher.update(bytes);
        }

        pub fn publishImportedStore(
            allocator: std.mem.Allocator,
            io: std.Io,
            staging_path: []const u8,
            target_path: []const u8,
            expected: ImportTransactionExpectation,
            result: *ImportPublicationResult,
        ) !void {
            const identity = try storeContentIdentity(allocator, io, staging_path);
            result.published_store_bytes = identity.bytes;
            result.published_store_digest = identity.digest;
            try writeImportTransactionMarker(allocator, io, staging_path, expected, result.*);
            try syncExportDirectoryTree(allocator, io, staging_path);
            if (try anyPathExists(io, target_path)) return error.AlreadyExists;
            try renamePath(io, staging_path, target_path);
            try syncParentDirectory(io, target_path);
            // Receipt retention makes the publication idempotently acknowledgeable
            // even if stdout fails after the atomic target rename.
            result.marker_cleanup_pending = false;
        }

        pub fn initOwnedBulkImportStore(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !storage.Store {
            try createOwnedDirectory(io, db_path);
            errdefer std.Io.Dir.cwd().deleteTree(io, db_path) catch {};
            return try storage.Store.initWithOptions(allocator, io, db_path, .{
                .primary_text_write_mode = .bulk_ingest,
            });
        }

        fn listMarkdownFilesSorted(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !std.ArrayList([]u8) {
            var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
            defer dir.close(io);
            var texts = std.ArrayList([]u8).empty;
            errdefer {
                for (texts.items) |name| allocator.free(name);
                texts.deinit(allocator);
            }
            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                try texts.append(allocator, try allocator.dupe(u8, entry.name));
            }
            std.mem.sort([]u8, texts.items, {}, markdownFileNameLessThan);
            return texts;
        }

        pub fn markdownFileNameLessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }

        pub fn listMarkdownFilesRecursiveSorted(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !std.ArrayList([]u8) {
            var texts = std.ArrayList([]u8).empty;
            errdefer {
                for (texts.items) |name| allocator.free(name);
                texts.deinit(allocator);
            }
            try appendMarkdownFilesRecursive(allocator, io, dir_path, "", &texts);
            std.mem.sort([]u8, texts.items, {}, markdownFileNameLessThan);
            return texts;
        }

        fn appendMarkdownFilesRecursive(
            allocator: std.mem.Allocator,
            io: std.Io,
            root_path: []const u8,
            relative_path: []const u8,
            texts: *std.ArrayList([]u8),
        ) !void {
            const dir_path = if (relative_path.len == 0)
                try allocator.dupe(u8, root_path)
            else
                try std.fs.path.join(allocator, &.{ root_path, relative_path });
            defer allocator.free(dir_path);

            var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
            defer dir.close(io);
            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind == .directory) {
                    const child_relative = if (relative_path.len == 0)
                        try allocator.dupe(u8, entry.name)
                    else
                        try std.fs.path.join(allocator, &.{ relative_path, entry.name });
                    defer allocator.free(child_relative);
                    try appendMarkdownFilesRecursive(allocator, io, root_path, child_relative, texts);
                    continue;
                }
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                const file_relative = if (relative_path.len == 0)
                    try allocator.dupe(u8, entry.name)
                else
                    try std.fs.path.join(allocator, &.{ relative_path, entry.name });
                try texts.append(allocator, file_relative);
            }
        }
    };
}
