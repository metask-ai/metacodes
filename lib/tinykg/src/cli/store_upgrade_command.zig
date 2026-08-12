const std = @import("std");

/// Stable command arguments for the automatic store upgrade control plane.
/// A target is optional only when the source already matches the current
/// binary. Supported legacy stores always publish to a distinct target.
pub const Arguments = struct {
    source_path: []const u8,
    target_path: ?[]const u8 = null,
    backup_path: ?[]const u8 = null,
    warm_text: bool = false,
    dry_run: bool = false,
};

fn parseArguments(args: []const []const u8) !Arguments {
    if (args.len < 3) return error.MissingArgument;
    var parsed = Arguments{ .source_path = args[2] };
    if (parsed.source_path.len == 0) return error.InvalidRecord;

    var pos: usize = 3;
    if (pos < args.len and !std.mem.startsWith(u8, args[pos], "--")) {
        if (args[pos].len == 0) return error.InvalidRecord;
        parsed.target_path = args[pos];
        pos += 1;
    }

    var warm_text_seen = false;
    var dry_run_seen = false;
    while (pos < args.len) {
        const option = args[pos];
        if (std.mem.eql(u8, option, "--backup")) {
            if (parsed.backup_path != null) return error.TooManyArguments;
            if (pos + 1 >= args.len) return error.MissingArgument;
            if (args[pos + 1].len == 0) return error.InvalidRecord;
            parsed.backup_path = args[pos + 1];
            pos += 2;
        } else if (std.mem.eql(u8, option, "--warm-text")) {
            if (warm_text_seen) return error.TooManyArguments;
            warm_text_seen = true;
            parsed.warm_text = true;
            pos += 1;
        } else if (std.mem.eql(u8, option, "--dry-run")) {
            if (dry_run_seen) return error.TooManyArguments;
            dry_run_seen = true;
            parsed.dry_run = true;
            pos += 1;
        } else if (std.mem.startsWith(u8, option, "--")) {
            return error.UnknownOption;
        } else {
            return error.TooManyArguments;
        }
    }
    if (parsed.backup_path != null and parsed.target_path == null) return error.MissingArgument;
    return parsed;
}

/// Version evidence read while the source store is locked and openable by the
/// current binary. A missing manifest is the one explicit legacy state; a
/// present manifest must contain non-zero numeric versions.
pub const DetectedVersion = union(enum) {
    legacy: struct {
        catalog_format_version: ?u16 = null,
    },
    manifest: struct {
        store_manifest_version: u32,
        storage_format_version: u32,
        schema_version: u32,
        catalog_format_version: ?u16,
        catalog_compatible: bool = true,
    },

    fn manifestLabel(self: DetectedVersion) []const u8 {
        return switch (self) {
            .legacy => "legacy",
            .manifest => "present",
        };
    }

    fn storageVersion(self: DetectedVersion) u32 {
        return switch (self) {
            .legacy => 0,
            .manifest => |value| value.storage_format_version,
        };
    }

    fn storeManifestVersion(self: DetectedVersion) u32 {
        return switch (self) {
            .legacy => 0,
            .manifest => |value| value.store_manifest_version,
        };
    }

    fn schemaVersion(self: DetectedVersion) u32 {
        return switch (self) {
            .legacy => 0,
            .manifest => |value| value.schema_version,
        };
    }

    fn catalogLabel(self: DetectedVersion) []const u8 {
        return if (self.catalogFormatVersion() == 0) "absent" else "present";
    }

    fn catalogFormatVersion(self: DetectedVersion) u16 {
        return switch (self) {
            .legacy => |value| value.catalog_format_version orelse 0,
            .manifest => |value| value.catalog_format_version orelse 0,
        };
    }
};

/// Every accepted source resolves to exactly one action. A future binary must
/// add a new explicit route before bumping its accepted store/schema versions;
/// otherwise the decision table fails closed with UpgradePathUnavailable.
pub const UpgradePlan = enum {
    current,
    migrate_store_v2_task_status_v1,
};

fn planUpgrade(
    detected: DetectedVersion,
    current_store_manifest_version: u32,
    current_storage_format_version: u32,
    current_schema_version: u32,
) !UpgradePlan {
    if (current_store_manifest_version == 0 or current_storage_format_version == 0 or current_schema_version == 0) {
        return error.UpgradePathUnavailable;
    }
    switch (detected) {
        .legacy => {
            if (current_storage_format_version != 2 or current_schema_version != 3) {
                return error.UpgradePathUnavailable;
            }
            return .migrate_store_v2_task_status_v1;
        },
        .manifest => |value| {
            if (value.store_manifest_version == 0 or value.storage_format_version == 0 or value.schema_version == 0) {
                return error.InvalidStoreManifest;
            }
            if (value.store_manifest_version > current_store_manifest_version) return error.NewerStoreManifest;
            if (value.store_manifest_version < current_store_manifest_version) return error.UpgradePathUnavailable;
            if (value.storage_format_version > current_storage_format_version) {
                return error.NewerStorageFormat;
            }
            if (value.schema_version > current_schema_version) {
                return error.NewerSchemaVersion;
            }
            if (value.storage_format_version == current_storage_format_version and
                value.schema_version == current_schema_version)
            {
                if (value.catalog_format_version == null) return error.MissingStoreCatalog;
                if (!value.catalog_compatible) return error.CatalogSchemaMismatch;
                return .current;
            }
            if (current_storage_format_version != 2 or current_schema_version != 3) {
                return error.UpgradePathUnavailable;
            }
            return .migrate_store_v2_task_status_v1;
        },
    }
}

/// Automatic version-probe and upgrade-route control plane.
///
/// Concrete Store/catalog/manifest types, locks, path canonicalization and the
/// proven Store-v2 migration data plane stay behind `Ops.Session`. The session
/// holds the source exclusion from probe through migration, so a concurrent
/// writer cannot change the version after route selection.
pub fn StoreUpgradeCommand(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseArguments(args);
            var session = try Ops.Session.init(allocator, io, parsed);
            defer session.deinit();

            const detected = try session.detect();
            const plan = try planUpgrade(
                detected,
                Ops.currentStoreManifestVersionValue,
                Ops.currentStorageFormatVersionValue,
                Ops.currentSchemaVersionValue,
            );
            switch (plan) {
                .current => try writer.print(
                    "upgrade result=current action=noop source={s} manifest={s} detected_manifest={} detected_storage={} detected_schema={} catalog={s} detected_catalog={} catalog_compatible=1 target_storage={} target_schema={} verified=1\n",
                    .{
                        parsed.source_path,
                        detected.manifestLabel(),
                        detected.storeManifestVersion(),
                        detected.storageVersion(),
                        detected.schemaVersion(),
                        detected.catalogLabel(),
                        detected.catalogFormatVersion(),
                        Ops.currentStorageFormatVersionValue,
                        Ops.currentSchemaVersionValue,
                    },
                ),
                .migrate_store_v2_task_status_v1 => {
                    const target_path = parsed.target_path orelse return error.MissingArgument;
                    const result = try session.migrate(.{
                        .verify = true,
                        .strict = true,
                        .task_status_v1 = true,
                    });
                    try writer.print(
                        "upgrade result={s} action=migrate-store-v2+task-status-v1 source={s} target={s} manifest={s} detected_manifest={} detected_storage={} detected_schema={} catalog={s} detected_catalog={} catalog_compatible={} target_storage={} target_schema={} verified={} nodes_scanned={} nodes_written={} edges_scanned={} edges_written={} backup={s} text_warmed={} marker_cleanup_pending={}\n",
                        .{
                            if (parsed.dry_run) "dry-run" else "upgraded",
                            parsed.source_path,
                            target_path,
                            detected.manifestLabel(),
                            detected.storeManifestVersion(),
                            detected.storageVersion(),
                            detected.schemaVersion(),
                            detected.catalogLabel(),
                            detected.catalogFormatVersion(),
                            @intFromBool(switch (detected) {
                                .legacy => true,
                                .manifest => |value| value.catalog_compatible,
                            }),
                            Ops.currentStorageFormatVersionValue,
                            Ops.currentSchemaVersionValue,
                            @intFromBool(result.verified),
                            result.nodes_scanned,
                            result.nodes_written,
                            result.edges_scanned,
                            result.edges_written,
                            parsed.backup_path orelse "",
                            @intFromBool(result.text_warmed),
                            @intFromBool(result.marker_cleanup_pending),
                        },
                    );
                },
            }
        }
    };
}

const TestWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestWriter) void {
        self.buffer.deinit(self.allocator);
    }

    fn print(self: *TestWriter, comptime format: []const u8, args: anytype) !void {
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    pub const currentStoreManifestVersionValue: u32 = 1;
    pub const currentStorageFormatVersionValue: u32 = 2;
    pub const currentSchemaVersionValue: u32 = 3;

    const Step = enum { init, detect, migrate, write, deinit };
    const Result = struct {
        verified: bool = true,
        nodes_scanned: u64 = 13,
        nodes_written: u64 = 11,
        edges_scanned: u64 = 17,
        edges_written: u64 = 15,
        text_warmed: bool = true,
        marker_cleanup_pending: bool = false,
    };

    var steps: [12]Step = undefined;
    var step_count: usize = 0;
    var detected: DetectedVersion = .{ .legacy = .{} };
    var detect_error: ?anyerror = null;
    var migrate_error: ?anyerror = null;

    fn reset() void {
        step_count = 0;
        detected = .{ .legacy = .{} };
        detect_error = null;
        migrate_error = null;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub const Session = struct {
        parsed: Arguments,

        pub fn init(_: std.mem.Allocator, _: std.Io, parsed: Arguments) !Session {
            TestOps.record(.init);
            return .{ .parsed = parsed };
        }

        pub fn deinit(_: *Session) void {
            TestOps.record(.deinit);
        }

        pub fn detect(_: *Session) !DetectedVersion {
            TestOps.record(.detect);
            if (TestOps.detect_error) |err| return err;
            return TestOps.detected;
        }

        pub fn migrate(self: *Session, options: anytype) !Result {
            TestOps.record(.migrate);
            try std.testing.expect(self.parsed.target_path != null);
            try std.testing.expect(options.verify);
            try std.testing.expect(options.strict);
            try std.testing.expect(options.task_status_v1);
            if (TestOps.migrate_error) |err| return err;
            return .{};
        }
    };
};

const store_upgrade_command = StoreUpgradeCommand(TestOps);

test "store upgrade arguments preserve safe defaults and explicit options" {
    const defaults = try parseArguments(&.{ "tinykg", "upgrade", "source.kg" });
    try std.testing.expectEqualStrings("source.kg", defaults.source_path);
    try std.testing.expectEqual(@as(?[]const u8, null), defaults.target_path);
    try std.testing.expectEqual(@as(?[]const u8, null), defaults.backup_path);
    try std.testing.expect(!defaults.warm_text);
    try std.testing.expect(!defaults.dry_run);

    const full = try parseArguments(&.{
        "tinykg",   "upgrade",   "source.kg",   "target.kg",
        "--backup", "backup.kg", "--warm-text", "--dry-run",
    });
    try std.testing.expectEqualStrings("target.kg", full.target_path.?);
    try std.testing.expectEqualStrings("backup.kg", full.backup_path.?);
    try std.testing.expect(full.warm_text);
    try std.testing.expect(full.dry_run);
}

test "store upgrade arguments reject missing duplicate unknown and ambiguous values" {
    try std.testing.expectError(error.MissingArgument, parseArguments(&.{ "tinykg", "upgrade" }));
    try std.testing.expectError(error.InvalidRecord, parseArguments(&.{ "tinykg", "upgrade", "" }));
    try std.testing.expectError(error.MissingArgument, parseArguments(&.{ "tinykg", "upgrade", "source.kg", "--backup", "backup.kg" }));
    try std.testing.expectError(error.MissingArgument, parseArguments(&.{ "tinykg", "upgrade", "source.kg", "target.kg", "--backup" }));
    try std.testing.expectError(error.TooManyArguments, parseArguments(&.{ "tinykg", "upgrade", "source.kg", "target.kg", "--backup", "a", "--backup", "b" }));
    try std.testing.expectError(error.TooManyArguments, parseArguments(&.{ "tinykg", "upgrade", "source.kg", "target.kg", "--warm-text", "--warm-text" }));
    try std.testing.expectError(error.UnknownOption, parseArguments(&.{ "tinykg", "upgrade", "source.kg", "--future" }));
    try std.testing.expectError(error.TooManyArguments, parseArguments(&.{ "tinykg", "upgrade", "source.kg", "target.kg", "extra" }));
}

test "store upgrade plan accepts current legacy and older supported stores" {
    try std.testing.expectEqual(UpgradePlan.migrate_store_v2_task_status_v1, try planUpgrade(.{ .legacy = .{} }, 1, 2, 3));
    try std.testing.expectEqual(UpgradePlan.migrate_store_v2_task_status_v1, try planUpgrade(.{ .manifest = .{
        .store_manifest_version = 1,
        .storage_format_version = 1,
        .schema_version = 2,
        .catalog_format_version = null,
    } }, 1, 2, 3));
    try std.testing.expectEqual(UpgradePlan.migrate_store_v2_task_status_v1, try planUpgrade(.{ .manifest = .{
        .store_manifest_version = 1,
        .storage_format_version = 2,
        .schema_version = 2,
        .catalog_format_version = 1,
    } }, 1, 2, 3));
    try std.testing.expectEqual(UpgradePlan.current, try planUpgrade(.{ .manifest = .{
        .store_manifest_version = 1,
        .storage_format_version = 2,
        .schema_version = 3,
        .catalog_format_version = 2,
    } }, 1, 2, 3));
}

test "store upgrade plan rejects malformed newer catalog mismatch and unavailable routes" {
    try std.testing.expectError(error.InvalidStoreManifest, planUpgrade(.{ .manifest = .{ .store_manifest_version = 0, .storage_format_version = 2, .schema_version = 3, .catalog_format_version = 2 } }, 1, 2, 3));
    try std.testing.expectError(error.InvalidStoreManifest, planUpgrade(.{ .manifest = .{ .store_manifest_version = 1, .storage_format_version = 0, .schema_version = 3, .catalog_format_version = 2 } }, 1, 2, 3));
    try std.testing.expectError(error.InvalidStoreManifest, planUpgrade(.{ .manifest = .{ .store_manifest_version = 1, .storage_format_version = 2, .schema_version = 0, .catalog_format_version = 2 } }, 1, 2, 3));
    try std.testing.expectError(error.NewerStoreManifest, planUpgrade(.{ .manifest = .{ .store_manifest_version = 2, .storage_format_version = 2, .schema_version = 3, .catalog_format_version = 2 } }, 1, 2, 3));
    try std.testing.expectError(error.NewerStorageFormat, planUpgrade(.{ .manifest = .{ .store_manifest_version = 1, .storage_format_version = 3, .schema_version = 3, .catalog_format_version = 2 } }, 1, 2, 3));
    try std.testing.expectError(error.NewerSchemaVersion, planUpgrade(.{ .manifest = .{ .store_manifest_version = 1, .storage_format_version = 2, .schema_version = 4, .catalog_format_version = 2 } }, 1, 2, 3));
    try std.testing.expectError(error.MissingStoreCatalog, planUpgrade(.{ .manifest = .{ .store_manifest_version = 1, .storage_format_version = 2, .schema_version = 3, .catalog_format_version = null } }, 1, 2, 3));
    try std.testing.expectError(error.CatalogSchemaMismatch, planUpgrade(.{ .manifest = .{ .store_manifest_version = 1, .storage_format_version = 2, .schema_version = 3, .catalog_format_version = 2, .catalog_compatible = false } }, 1, 2, 3));
    try std.testing.expectError(error.UpgradePathUnavailable, planUpgrade(.{ .legacy = .{} }, 1, 3, 4));
    try std.testing.expectError(error.UpgradePathUnavailable, planUpgrade(.{ .legacy = .{} }, 1, 0, 3));
}

test "store upgrade current store is a no-op without a target" {
    TestOps.reset();
    TestOps.detected = .{ .manifest = .{
        .store_manifest_version = 1,
        .storage_format_version = 2,
        .schema_version = 3,
        .catalog_format_version = 2,
    } };
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_upgrade_command.run(&.{ "tinykg", "upgrade", "source.kg" }, &writer, std.testing.allocator, std.testing.io);
    try TestOps.expectSteps(&.{ .init, .detect, .write, .deinit });
    try std.testing.expectEqualStrings(
        "upgrade result=current action=noop source=source.kg manifest=present detected_manifest=1 detected_storage=2 detected_schema=3 catalog=present detected_catalog=2 catalog_compatible=1 target_storage=2 target_schema=3 verified=1\n",
        writer.buffer.items,
    );
}

test "store upgrade legacy store requires a target after locked probe" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.MissingArgument,
        store_upgrade_command.run(&.{ "tinykg", "upgrade", "source.kg" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .init, .detect, .deinit });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "store upgrade forces strict verified task-status migration" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try store_upgrade_command.run(&.{
        "tinykg",   "upgrade",   "source.kg",   "target.kg",
        "--backup", "backup.kg", "--warm-text", "--dry-run",
    }, &writer, std.testing.allocator, std.testing.io);
    try TestOps.expectSteps(&.{ .init, .detect, .migrate, .write, .deinit });
    try std.testing.expectEqualStrings(
        "upgrade result=dry-run action=migrate-store-v2+task-status-v1 source=source.kg target=target.kg manifest=legacy detected_manifest=0 detected_storage=0 detected_schema=0 catalog=absent detected_catalog=0 catalog_compatible=1 target_storage=2 target_schema=3 verified=1 nodes_scanned=13 nodes_written=11 edges_scanned=17 edges_written=15 backup=backup.kg text_warmed=1 marker_cleanup_pending=0\n",
        writer.buffer.items,
    );
}

test "store upgrade closes probe state after migration or output failure" {
    TestOps.reset();
    TestOps.migrate_error = error.MigrationFailed;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.MigrationFailed,
        store_upgrade_command.run(&.{ "tinykg", "upgrade", "source.kg", "target.kg" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .init, .detect, .migrate, .deinit });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);

    TestOps.reset();
    TestOps.detected = .{ .manifest = .{
        .store_manifest_version = 1,
        .storage_format_version = 2,
        .schema_version = 3,
        .catalog_format_version = 2,
    } };
    var failing_writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        store_upgrade_command.run(&.{ "tinykg", "upgrade", "source.kg" }, &failing_writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .init, .detect, .write, .deinit });
}
