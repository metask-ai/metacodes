const std = @import("std");

/// Owns edge-segment manifest-rooted mark and sweep. `Ops` keeps manifest
/// decoding and validation in the storage façade, while this controller owns
/// the safety order: validate every CURRENT/pinned root before deleting any
/// segment directory, then remove only strictly recognized unprotected epoch
/// manifests. Process leases are already represented in `pinned_paths`.
pub fn EdgeSegmentGc(comptime Ops: type) type {
    return struct {
        const Self = @This();

        pub const Result = struct {
            deleted_segments: u64 = 0,
            deleted_manifests: u64 = 0,
        };

        pub fn collect(context: anytype, pinned_paths: []const []const u8) !Result {
            const allocator = Ops.allocator(context);
            const current_path = try Ops.currentManifestPath(context, allocator);
            defer if (current_path) |path| allocator.free(path);

            var live_segment_paths = std.StringHashMap(void).init(allocator);
            defer live_segment_paths.deinit();

            var protected_manifest_paths = std.StringHashMap(void).init(allocator);
            defer protected_manifest_paths.deinit();
            try protected_manifest_paths.ensureTotalCapacity(@intCast(pinned_paths.len + 1));
            if (current_path) |path| try protected_manifest_paths.put(path, {});
            for (pinned_paths) |path| try protected_manifest_paths.put(path, {});

            // Keep decoded manifests alive because live path keys may borrow
            // their entry storage. All roots are loaded and validated before
            // the first filesystem mutation.
            var manifests = std.ArrayList(Ops.Manifest).empty;
            defer {
                for (manifests.items) |*manifest| Ops.deinitManifest(context, manifest);
                manifests.deinit(allocator);
            }

            if (current_path) |path| {
                try markManifest(context, path, true, &live_segment_paths, &manifests);
            }
            for (pinned_paths) |path| {
                if (current_path) |current| {
                    if (std.mem.eql(u8, path, current)) continue;
                }
                try markManifest(context, path, false, &live_segment_paths, &manifests);
            }

            return .{
                .deleted_segments = try sweepSegmentDirectories(context, &live_segment_paths),
                .deleted_manifests = try sweepManifestEpochs(context, &protected_manifest_paths),
            };
        }

        fn markManifest(
            context: anytype,
            path: []const u8,
            is_current: bool,
            live_segment_paths: *std.StringHashMap(void),
            manifests: *std.ArrayList(Ops.Manifest),
        ) !void {
            var manifest = Ops.readManifest(context, path) catch |err| switch (err) {
                error.FileNotFound => if (is_current) return error.InvalidRecord else return error.FileNotFound,
                else => |other| return other,
            };
            errdefer Ops.deinitManifest(context, &manifest);
            try Ops.validateManifest(context, path, &manifest);
            try Ops.markLiveSegmentPaths(context, &manifest, live_segment_paths);
            try manifests.append(Ops.allocator(context), manifest);
        }

        fn sweepSegmentDirectories(
            context: anytype,
            live_segment_paths: *const std.StringHashMap(void),
        ) !u64 {
            const allocator = Ops.allocator(context);
            const io = Ops.io(context);
            const segments_dir_path = try std.fs.path.join(allocator, &.{ Ops.storeDirPath(context), "edge_segments" });
            defer allocator.free(segments_dir_path);
            var dir = std.Io.Dir.cwd().openDir(io, segments_dir_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return 0,
                else => |other| return other,
            };
            defer dir.close(io);

            var deleted: u64 = 0;
            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                const full_path = try std.fs.path.join(allocator, &.{ segments_dir_path, entry.name });
                defer allocator.free(full_path);
                if (live_segment_paths.contains(full_path)) continue;
                try std.Io.Dir.cwd().deleteTree(io, full_path);
                deleted = std.math.add(u64, deleted, 1) catch return error.RecordTooLarge;
            }
            return deleted;
        }

        fn sweepManifestEpochs(
            context: anytype,
            protected_manifest_paths: *const std.StringHashMap(void),
        ) !u64 {
            const allocator = Ops.allocator(context);
            const io = Ops.io(context);
            const manifest_leaf = std.fs.path.basename(Ops.manifestPath(context));
            const epoch_prefix = try std.fmt.allocPrint(allocator, "{s}.", .{manifest_leaf});
            defer allocator.free(epoch_prefix);

            var store_dir = try std.Io.Dir.cwd().openDir(io, Ops.storeDirPath(context), .{ .iterate = true });
            defer store_dir.close(io);

            var deleted: u64 = 0;
            var iter = store_dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!isManifestEpochLeaf(entry.name, epoch_prefix)) continue;
                const full_path = try std.fs.path.join(allocator, &.{ Ops.storeDirPath(context), entry.name });
                defer allocator.free(full_path);
                if (protected_manifest_paths.contains(full_path)) continue;
                try std.Io.Dir.cwd().deleteFile(io, full_path);
                deleted = std.math.add(u64, deleted, 1) catch return error.RecordTooLarge;
            }
            return deleted;
        }

        fn isManifestEpochLeaf(name: []const u8, prefix: []const u8) bool {
            if (!std.mem.startsWith(u8, name, prefix)) return false;
            const rest = name[prefix.len..];
            const dot_index = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
            if (dot_index == 0 or dot_index + 1 >= rest.len) return false;
            if (std.mem.indexOfScalar(u8, rest[dot_index + 1 ..], '.') != null) return false;
            _ = std.fmt.parseUnsigned(u64, rest[0..dot_index], 10) catch return false;
            _ = std.fmt.parseUnsigned(u64, rest[dot_index + 1 ..], 16) catch return false;
            return true;
        }
    };
}

const TestManifestRecord = struct {
    path: []const u8,
    segment_paths: []const []const u8,
    valid: bool = true,
};

const TestManifest = struct {
    segment_paths: []const []const u8,
    valid: bool,
};

const TestContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store_dir_path: []const u8,
    manifest_path: []const u8,
    current_path: ?[]const u8 = null,
    manifests: []const TestManifestRecord = &.{},
};

const TestOps = struct {
    pub const Manifest = TestManifest;

    pub fn allocator(context: *TestContext) std.mem.Allocator {
        return context.allocator;
    }

    pub fn io(context: *TestContext) std.Io {
        return context.io;
    }

    pub fn storeDirPath(context: *TestContext) []const u8 {
        return context.store_dir_path;
    }

    pub fn manifestPath(context: *TestContext) []const u8 {
        return context.manifest_path;
    }

    pub fn currentManifestPath(context: *TestContext, allocator_arg: std.mem.Allocator) !?[]u8 {
        const path = context.current_path orelse return null;
        return try allocator_arg.dupe(u8, path);
    }

    pub fn readManifest(context: *TestContext, path: []const u8) !Manifest {
        for (context.manifests) |record| {
            if (!std.mem.eql(u8, record.path, path)) continue;
            return .{ .segment_paths = record.segment_paths, .valid = record.valid };
        }
        return error.FileNotFound;
    }

    pub fn validateManifest(context: *TestContext, path: []const u8, manifest: *const Manifest) !void {
        _ = context;
        _ = path;
        if (!manifest.valid) return error.InvalidRecord;
    }

    pub fn markLiveSegmentPaths(
        context: *TestContext,
        manifest: *const Manifest,
        live_paths: *std.StringHashMap(void),
    ) !void {
        _ = context;
        try live_paths.ensureUnusedCapacity(@intCast(manifest.segment_paths.len));
        for (manifest.segment_paths) |path| live_paths.putAssumeCapacity(path, {});
    }

    pub fn deinitManifest(context: *TestContext, manifest: *Manifest) void {
        _ = context;
        _ = manifest;
    }
};

const test_gc = EdgeSegmentGc(TestOps);

const TestLayout = struct {
    root: []const u8,
    manifest_path: []u8,
    segments_path: []u8,

    fn init(tmp: *std.testing.TmpDir, path_buf: []u8) !TestLayout {
        const root_len = try tmp.dir.realPath(std.testing.io, path_buf);
        const root = path_buf[0..root_len];
        return .{
            .root = root,
            .manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "edge_segment.manifest" }),
            .segments_path = try std.fs.path.join(std.testing.allocator, &.{ root, "edge_segments" }),
        };
    }

    fn deinit(self: *TestLayout) void {
        std.testing.allocator.free(self.manifest_path);
        std.testing.allocator.free(self.segments_path);
    }

    fn path(self: TestLayout, leaf: []const u8) ![]u8 {
        return try std.fs.path.join(std.testing.allocator, &.{ self.root, leaf });
    }

    fn segment(self: TestLayout, leaf: []const u8) ![]u8 {
        return try std.fs.path.join(std.testing.allocator, &.{ self.segments_path, leaf });
    }
};

fn createFile(path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "fixture",
        .flags = .{ .truncate = true },
    });
}

fn pathExists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    return true;
}

test "edge segment gc protects current and pinned roots before sweeping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, layout.segments_path);

    const current_segment = try layout.segment("current");
    defer std.testing.allocator.free(current_segment);
    const pinned_segment = try layout.segment("pinned");
    defer std.testing.allocator.free(pinned_segment);
    const orphan_segment = try layout.segment("orphan");
    defer std.testing.allocator.free(orphan_segment);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, current_segment);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pinned_segment);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, orphan_segment);
    const loose_file = try layout.segment("loose-file");
    defer std.testing.allocator.free(loose_file);
    try createFile(loose_file);

    const current_manifest = try layout.path("edge_segment.manifest.1.a");
    defer std.testing.allocator.free(current_manifest);
    const pinned_manifest = try layout.path("edge_segment.manifest.2.b");
    defer std.testing.allocator.free(pinned_manifest);
    const stale_manifest = try layout.path("edge_segment.manifest.3.c");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(current_manifest);
    try createFile(pinned_manifest);
    try createFile(stale_manifest);

    const records = [_]TestManifestRecord{
        .{ .path = current_manifest, .segment_paths = &.{current_segment} },
        .{ .path = pinned_manifest, .segment_paths = &.{pinned_segment} },
    };
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
        .current_path = current_manifest,
        .manifests = &records,
    };

    const result = try test_gc.collect(&context, &.{pinned_manifest});
    try std.testing.expectEqual(@as(u64, 1), result.deleted_segments);
    try std.testing.expectEqual(@as(u64, 1), result.deleted_manifests);
    try std.testing.expect(try pathExists(current_segment));
    try std.testing.expect(try pathExists(pinned_segment));
    try std.testing.expect(!try pathExists(orphan_segment));
    try std.testing.expect(try pathExists(loose_file));
    try std.testing.expect(try pathExists(current_manifest));
    try std.testing.expect(try pathExists(pinned_manifest));
    try std.testing.expect(!try pathExists(stale_manifest));
}

test "edge segment gc tolerates a missing segment directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    const stale_manifest = try layout.path("edge_segment.manifest.4.d");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(stale_manifest);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
    };

    const result = try test_gc.collect(&context, &.{});
    try std.testing.expectEqual(@as(u64, 0), result.deleted_segments);
    try std.testing.expectEqual(@as(u64, 1), result.deleted_manifests);
    try std.testing.expect(!try pathExists(stale_manifest));
}

test "edge segment gc missing current manifest fails before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    const current_manifest = try layout.path("edge_segment.manifest.5.e");
    defer std.testing.allocator.free(current_manifest);
    const stale_manifest = try layout.path("edge_segment.manifest.6.f");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(stale_manifest);
    const orphan_segment = try layout.segment("orphan");
    defer std.testing.allocator.free(orphan_segment);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, orphan_segment);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
        .current_path = current_manifest,
    };

    try std.testing.expectError(error.InvalidRecord, test_gc.collect(&context, &.{}));
    try std.testing.expect(try pathExists(orphan_segment));
    try std.testing.expect(try pathExists(stale_manifest));
}

test "edge segment gc invalid pinned manifest fails before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    const current_manifest = try layout.path("edge_segment.manifest.7.10");
    defer std.testing.allocator.free(current_manifest);
    const pinned_manifest = try layout.path("edge_segment.manifest.8.11");
    defer std.testing.allocator.free(pinned_manifest);
    const stale_manifest = try layout.path("edge_segment.manifest.9.12");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(current_manifest);
    try createFile(pinned_manifest);
    try createFile(stale_manifest);
    const current_segment = try layout.segment("current");
    defer std.testing.allocator.free(current_segment);
    const orphan_segment = try layout.segment("orphan");
    defer std.testing.allocator.free(orphan_segment);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, current_segment);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, orphan_segment);
    const records = [_]TestManifestRecord{
        .{ .path = current_manifest, .segment_paths = &.{current_segment} },
        .{ .path = pinned_manifest, .segment_paths = &.{}, .valid = false },
    };
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
        .current_path = current_manifest,
        .manifests = &records,
    };

    try std.testing.expectError(error.InvalidRecord, test_gc.collect(&context, &.{pinned_manifest}));
    try std.testing.expect(try pathExists(orphan_segment));
    try std.testing.expect(try pathExists(stale_manifest));
}

test "edge segment gc preserves non-epoch manifest lookalikes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    const epoch = try layout.path("edge_segment.manifest.10.1f");
    defer std.testing.allocator.free(epoch);
    const missing_decimal = try layout.path("edge_segment.manifest.bad.1f");
    defer std.testing.allocator.free(missing_decimal);
    const missing_hex = try layout.path("edge_segment.manifest.10.nope");
    defer std.testing.allocator.free(missing_hex);
    const extra_suffix = try layout.path("edge_segment.manifest.10.1f.extra");
    defer std.testing.allocator.free(extra_suffix);
    const legacy_base = try layout.path("edge_segment.manifest");
    defer std.testing.allocator.free(legacy_base);
    try createFile(epoch);
    try createFile(missing_decimal);
    try createFile(missing_hex);
    try createFile(extra_suffix);
    try createFile(legacy_base);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
    };

    const result = try test_gc.collect(&context, &.{});
    try std.testing.expectEqual(@as(u64, 1), result.deleted_manifests);
    try std.testing.expect(!try pathExists(epoch));
    try std.testing.expect(try pathExists(missing_decimal));
    try std.testing.expect(try pathExists(missing_hex));
    try std.testing.expect(try pathExists(extra_suffix));
    try std.testing.expect(try pathExists(legacy_base));
}
