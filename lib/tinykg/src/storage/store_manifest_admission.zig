const std = @import("std");

/// Owns fail-closed Store-format admission. A manifest, when present, is
/// validated before any recovery routine can mutate durable files. Marker-only
/// legacy Stores remain readable so the COW upgrade command can preserve its
/// existing compatibility surface.
pub fn StoreManifestAdmission(comptime Ops: type) type {
    return struct {
        pub const Result = enum { legacy, older, current };

        pub fn admit(store: Ops.StoreType) !Result {
            const allocator = Ops.allocator(store);
            const manifest_path = try std.fs.path.join(allocator, &.{ Ops.storeDirPath(store), ".tinykg", "store-manifest.json" });
            defer allocator.free(manifest_path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(
                Ops.io(store),
                manifest_path,
                allocator,
                .limited(Ops.maximumManifestBytes),
            ) catch |err| switch (err) {
                error.FileNotFound => return .legacy,
                else => |other| return other,
            };
            defer allocator.free(bytes);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
                // Admission participates in backup/migration operations that
                // deliberately exercise allocation failure.  Resource failure
                // is not evidence that durable bytes are malformed.
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStoreManifest,
            };
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidStoreManifest;
            const root = parsed.value.object;
            const manifest_version = try requiredVersion(root, "store_manifest_version");
            const storage_version = try requiredVersion(root, "storage_format_version");
            const schema_value = root.get("schema") orelse return error.InvalidStoreManifest;
            if (schema_value != .object) return error.InvalidStoreManifest;
            const schema_version = try requiredVersion(schema_value.object, "schema_version");

            if (manifest_version != Ops.currentStoreManifestVersion) return error.UnsupportedStoreManifestVersion;
            if (storage_version > Ops.currentStorageFormatVersion) return error.UnsupportedStorageFormatVersion;
            if (schema_version > Ops.currentSchemaVersion) return error.UnsupportedSchemaVersion;
            // Storage compatibility is exact because recovery and data-plane
            // code can mutate physical records.  An older schema carried by
            // the current physical format is different: the embedded catalog
            // remains authoritative and schema-migrate/upgrade must be able to
            // open that Store normally in order to advance it.  Future schemas
            // still fail closed above.
            return if (storage_version < Ops.currentStorageFormatVersion)
                .older
            else
                .current;
        }

        fn requiredVersion(object: std.json.ObjectMap, name: []const u8) !u64 {
            const value = object.get(name) orelse return error.InvalidStoreManifest;
            return switch (value) {
                .integer => |number| std.math.cast(u64, number) orelse error.InvalidStoreManifest,
                else => error.InvalidStoreManifest,
            };
        }
    };
}

const TestStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
};

const TestOps = struct {
    pub const StoreType = TestStore;
    pub const maximumManifestBytes: usize = 64 * 1024;
    pub const currentStoreManifestVersion: u64 = 1;
    pub const currentStorageFormatVersion: u64 = 3;
    pub const currentSchemaVersion: u64 = 3;

    pub fn allocator(store: StoreType) std.mem.Allocator {
        return store.allocator;
    }

    pub fn io(store: StoreType) std.Io {
        return store.io;
    }

    pub fn storeDirPath(store: StoreType) []const u8 {
        return store.path;
    }
};

const test_admission = StoreManifestAdmission(TestOps);

const PreviousTestOps = struct {
    pub const StoreType = TestStore;
    pub const maximumManifestBytes: usize = TestOps.maximumManifestBytes;
    pub const currentStoreManifestVersion: u64 = TestOps.currentStoreManifestVersion;
    pub const currentStorageFormatVersion: u64 = 2;
    pub const currentSchemaVersion: u64 = TestOps.currentSchemaVersion;

    pub const allocator = TestOps.allocator;
    pub const io = TestOps.io;
    pub const storeDirPath = TestOps.storeDirPath;
};

const previous_test_admission = StoreManifestAdmission(PreviousTestOps);

fn writeTestManifest(root: []const u8, manifest: []const u8) !void {
    const metadata = try std.fs.path.join(std.testing.allocator, &.{ root, ".tinykg" });
    defer std.testing.allocator.free(metadata);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, metadata);
    const path = try std.fs.path.join(std.testing.allocator, &.{ metadata, "store-manifest.json" });
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = manifest });
}

test "store manifest admission keeps marker-only legacy compatibility" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store = TestStore{ .allocator = std.testing.allocator, .io = std.testing.io, .path = root };
    try std.testing.expectEqual(test_admission.Result.legacy, try test_admission.admit(store));
}

test "store manifest admission accepts only the exact current contract" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try writeTestManifest(root,
        \\{"store_manifest_version":1,"storage_format_version":3,"schema":{"schema_version":3}}
    );
    const store = TestStore{ .allocator = std.testing.allocator, .io = std.testing.io, .path = root };
    try std.testing.expectEqual(test_admission.Result.current, try test_admission.admit(store));
}

test "store manifest admission accepts current storage with an older supported schema" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try writeTestManifest(root,
        \\{"store_manifest_version":1,"storage_format_version":3,"schema":{"schema_version":2}}
    );
    const store = TestStore{ .allocator = std.testing.allocator, .io = std.testing.io, .path = root };
    try std.testing.expectEqual(test_admission.Result.current, try test_admission.admit(store));
}

test "store manifest admission classifies older formats and rejects future or malformed formats" {
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        try writeTestManifest(root,
            \\{"store_manifest_version":1,"storage_format_version":2,"schema":{"schema_version":3}}
        );
        const store = TestStore{ .allocator = std.testing.allocator, .io = std.testing.io, .path = root };
        try std.testing.expectEqual(test_admission.Result.older, try test_admission.admit(store));
    }
    const Case = struct { manifest: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .manifest =
        \\{"store_manifest_version":2,"storage_format_version":3,"schema":{"schema_version":3}}
        , .expected = error.UnsupportedStoreManifestVersion },
        .{ .manifest =
        \\{"store_manifest_version":1,"storage_format_version":4,"schema":{"schema_version":3}}
        , .expected = error.UnsupportedStorageFormatVersion },
        .{ .manifest =
        \\{"store_manifest_version":1,"storage_format_version":3,"schema":{"schema_version":4}}
        , .expected = error.UnsupportedSchemaVersion },
        .{ .manifest = "{}", .expected = error.InvalidStoreManifest },
        .{ .manifest = "not-json", .expected = error.InvalidStoreManifest },
    };
    for (cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        try writeTestManifest(root, case.manifest);
        const store = TestStore{ .allocator = std.testing.allocator, .io = std.testing.io, .path = root };
        try std.testing.expectError(case.expected, test_admission.admit(store));
    }
}

test "previous v2 reader rejects a current v3 store before recovery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try writeTestManifest(root,
        \\{"store_manifest_version":1,"storage_format_version":3,"schema":{"schema_version":3}}
    );
    const store = TestStore{ .allocator = std.testing.allocator, .io = std.testing.io, .path = root };
    try std.testing.expectError(error.UnsupportedStorageFormatVersion, previous_test_admission.admit(store));
}
