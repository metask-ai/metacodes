const std = @import("std");

/// Owns node-text-run manifest-rooted mark and sweep. `Ops` keeps manifest
/// decoding, run-path extraction, CURRENT resolution, and Store paths in the
/// storage facade. This controller owns the safety order: materialize every
/// live run path from CURRENT and pinned roots before the first filesystem
/// mutation, remove only unreferenced run files, then remove unprotected
/// canonical node-text-run manifest epochs.
///
/// Process leases are already represented in `pinned_paths`. Epoch filenames
/// are accepted only in the exact producer form `<base>.<decimal>.<lower-hex>`;
/// lookalike files and directories are never reclamation candidates.
pub fn NodeTextRunGc(comptime Ops: type) type {
    return struct {
        pub const Result = struct {
            deleted_runs: u64 = 0,
            deleted_manifests: u64 = 0,
        };

        pub fn collect(context: anytype, pinned_paths: []const []const u8) !Result {
            const allocator = Ops.allocator(context);
            const current_path = try Ops.currentManifestPath(context, allocator);
            defer if (current_path) |path| allocator.free(path);

            // Values own the same allocation used as their map key. This lets
            // the facade release each decoded manifest immediately while the
            // complete live set remains valid for the later sweep.
            var live_run_paths = std.StringHashMap([]u8).init(allocator);
            defer freeOwnedPaths(allocator, &live_run_paths);

            var protected_manifest_paths = std.StringHashMap(void).init(allocator);
            defer protected_manifest_paths.deinit();
            try protected_manifest_paths.ensureTotalCapacity(@intCast(pinned_paths.len + 1));

            if (current_path) |path| {
                try protected_manifest_paths.put(path, {});
                try Ops.markManifestLiveRunPaths(context, path, &live_run_paths);
            }
            for (pinned_paths) |path| {
                try protected_manifest_paths.put(path, {});
                try Ops.markManifestLiveRunPaths(context, path, &live_run_paths);
            }

            return .{
                .deleted_runs = try sweepRunFiles(context, &live_run_paths),
                .deleted_manifests = try sweepManifestEpochs(context, &protected_manifest_paths),
            };
        }

        /// Matches the canonical filename emitted by the storage façade:
        /// `<manifest_leaf>.<total_nodes_decimal>.<digest_lower_hex>`.
        /// Numeric fields use their shortest spelling, so leading zeroes and
        /// uppercase hex are rejected along with malformed or extra fields.
        pub fn isManifestEpochLeaf(name: []const u8, manifest_leaf: []const u8) bool {
            if (name.len <= manifest_leaf.len + 1) return false;
            if (!std.mem.eql(u8, name[0..manifest_leaf.len], manifest_leaf)) return false;
            if (name[manifest_leaf.len] != '.') return false;

            const rest = name[manifest_leaf.len + 1 ..];
            const separator = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
            if (separator == 0 or separator + 1 >= rest.len) return false;
            if (std.mem.indexOfScalar(u8, rest[separator + 1 ..], '.') != null) return false;

            const count_text = rest[0..separator];
            const digest_text = rest[separator + 1 ..];
            if (!isCanonicalDecimal(count_text) or !isCanonicalLowerHex(digest_text)) return false;
            _ = std.fmt.parseUnsigned(u64, count_text, 10) catch return false;
            _ = std.fmt.parseUnsigned(u64, digest_text, 16) catch return false;
            return true;
        }

        fn isCanonicalDecimal(text: []const u8) bool {
            if (text.len == 0 or (text.len > 1 and text[0] == '0')) return false;
            for (text) |byte| if (byte < '0' or byte > '9') return false;
            return true;
        }

        fn isCanonicalLowerHex(text: []const u8) bool {
            if (text.len == 0 or (text.len > 1 and text[0] == '0')) return false;
            for (text) |byte| {
                if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
            }
            return true;
        }

        fn freeOwnedPaths(allocator: std.mem.Allocator, paths: *std.StringHashMap([]u8)) void {
            var iter = paths.valueIterator();
            while (iter.next()) |path| allocator.free(path.*);
            paths.deinit();
        }

        fn sweepRunFiles(
            context: anytype,
            live_run_paths: *const std.StringHashMap([]u8),
        ) !u64 {
            const allocator = Ops.allocator(context);
            const io = Ops.io(context);
            const runs_dir_path = try std.fs.path.join(allocator, &.{ Ops.storeDirPath(context), "node_text_runs" });
            defer allocator.free(runs_dir_path);

            var runs_dir = std.Io.Dir.cwd().openDir(io, runs_dir_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return 0,
                else => |other| return other,
            };
            defer runs_dir.close(io);

            var deleted: u64 = 0;
            var iter = runs_dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .file) continue;
                const full_path = try std.fs.path.join(allocator, &.{ runs_dir_path, entry.name });
                defer allocator.free(full_path);
                if (live_run_paths.contains(full_path)) continue;
                try std.Io.Dir.cwd().deleteFile(io, full_path);
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

            var store_dir = try std.Io.Dir.cwd().openDir(io, Ops.storeDirPath(context), .{ .iterate = true });
            defer store_dir.close(io);

            var deleted: u64 = 0;
            var iter = store_dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!isManifestEpochLeaf(entry.name, manifest_leaf)) continue;
                const full_path = try std.fs.path.join(allocator, &.{ Ops.storeDirPath(context), entry.name });
                defer allocator.free(full_path);
                if (protected_manifest_paths.contains(full_path)) continue;
                try std.Io.Dir.cwd().deleteFile(io, full_path);
                deleted = std.math.add(u64, deleted, 1) catch return error.RecordTooLarge;
            }
            return deleted;
        }
    };
}

const TestManifestRecord = struct {
    path: []const u8,
    run_paths: []const []const u8,
    valid: bool = true,
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

    pub fn markManifestLiveRunPaths(
        context: *TestContext,
        path: []const u8,
        live_paths: *std.StringHashMap([]u8),
    ) !void {
        for (context.manifests) |manifest| {
            if (!std.mem.eql(u8, manifest.path, path)) continue;
            if (!manifest.valid) return error.InvalidRecord;
            try live_paths.ensureUnusedCapacity(@intCast(manifest.run_paths.len));
            for (manifest.run_paths) |run_path| {
                if (live_paths.contains(run_path)) continue;
                const owned_path = try context.allocator.dupe(u8, run_path);
                live_paths.putAssumeCapacityNoClobber(owned_path, owned_path);
            }
            return;
        }
        return error.FileNotFound;
    }
};

const test_gc = NodeTextRunGc(TestOps);

const TestLayout = struct {
    root: []const u8,
    manifest_path: []u8,
    runs_path: []u8,

    fn init(tmp: *std.testing.TmpDir, path_buf: []u8) !TestLayout {
        const root_len = try tmp.dir.realPath(std.testing.io, path_buf);
        const root = path_buf[0..root_len];
        return .{
            .root = root,
            .manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "node_text_runs.manifest" }),
            .runs_path = try std.fs.path.join(std.testing.allocator, &.{ root, "node_text_runs" }),
        };
    }

    fn deinit(self: *TestLayout) void {
        std.testing.allocator.free(self.manifest_path);
        std.testing.allocator.free(self.runs_path);
    }

    fn path(self: TestLayout, leaf: []const u8) ![]u8 {
        return try std.fs.path.join(std.testing.allocator, &.{ self.root, leaf });
    }

    fn run(self: TestLayout, leaf: []const u8) ![]u8 {
        return try std.fs.path.join(std.testing.allocator, &.{ self.runs_path, leaf });
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

test "node text run gc protects current and pinned roots before sweeping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, layout.runs_path);

    const current_run = try layout.run("current");
    defer std.testing.allocator.free(current_run);
    const pinned_run = try layout.run("pinned");
    defer std.testing.allocator.free(pinned_run);
    const orphan_run = try layout.run("orphan");
    defer std.testing.allocator.free(orphan_run);
    try createFile(current_run);
    try createFile(pinned_run);
    try createFile(orphan_run);

    const current_manifest = try layout.path("node_text_runs.manifest.1.a");
    defer std.testing.allocator.free(current_manifest);
    const pinned_manifest = try layout.path("node_text_runs.manifest.2.b");
    defer std.testing.allocator.free(pinned_manifest);
    const stale_manifest = try layout.path("node_text_runs.manifest.3.c");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(current_manifest);
    try createFile(pinned_manifest);
    try createFile(stale_manifest);

    const records = [_]TestManifestRecord{
        .{ .path = current_manifest, .run_paths = &.{current_run} },
        .{ .path = pinned_manifest, .run_paths = &.{pinned_run} },
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
    try std.testing.expectEqual(@as(u64, 1), result.deleted_runs);
    try std.testing.expectEqual(@as(u64, 1), result.deleted_manifests);
    try std.testing.expect(try pathExists(current_run));
    try std.testing.expect(try pathExists(pinned_run));
    try std.testing.expect(!try pathExists(orphan_run));
    try std.testing.expect(try pathExists(current_manifest));
    try std.testing.expect(try pathExists(pinned_manifest));
    try std.testing.expect(!try pathExists(stale_manifest));
}

test "node text run gc sweeps files only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    const orphan_dir = try layout.run("orphan-dir");
    defer std.testing.allocator.free(orphan_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, orphan_dir);

    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
    };
    const result = try test_gc.collect(&context, &.{});
    try std.testing.expectEqual(@as(u64, 0), result.deleted_runs);
    try std.testing.expect(try pathExists(orphan_dir));
}

test "node text run gc missing run directory still sweeps manifests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    const stale_manifest = try layout.path("node_text_runs.manifest.4.d");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(stale_manifest);

    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
    };
    const result = try test_gc.collect(&context, &.{});
    try std.testing.expectEqual(@as(u64, 0), result.deleted_runs);
    try std.testing.expectEqual(@as(u64, 1), result.deleted_manifests);
    try std.testing.expect(!try pathExists(stale_manifest));
}

test "node text run gc missing current manifest fails before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, layout.runs_path);
    const orphan_run = try layout.run("orphan");
    defer std.testing.allocator.free(orphan_run);
    try createFile(orphan_run);
    const missing_current = try layout.path("node_text_runs.manifest.5.e");
    defer std.testing.allocator.free(missing_current);
    const stale_manifest = try layout.path("node_text_runs.manifest.6.f");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(stale_manifest);

    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
        .current_path = missing_current,
    };
    try std.testing.expectError(error.FileNotFound, test_gc.collect(&context, &.{}));
    try std.testing.expect(try pathExists(orphan_run));
    try std.testing.expect(try pathExists(stale_manifest));
}

test "node text run gc invalid pinned manifest fails before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, layout.runs_path);
    const current_run = try layout.run("current");
    defer std.testing.allocator.free(current_run);
    const orphan_run = try layout.run("orphan");
    defer std.testing.allocator.free(orphan_run);
    try createFile(current_run);
    try createFile(orphan_run);
    const current_manifest = try layout.path("node_text_runs.manifest.7.10");
    defer std.testing.allocator.free(current_manifest);
    const pinned_manifest = try layout.path("node_text_runs.manifest.8.11");
    defer std.testing.allocator.free(pinned_manifest);
    const stale_manifest = try layout.path("node_text_runs.manifest.9.12");
    defer std.testing.allocator.free(stale_manifest);
    try createFile(current_manifest);
    try createFile(pinned_manifest);
    try createFile(stale_manifest);
    const records = [_]TestManifestRecord{
        .{ .path = current_manifest, .run_paths = &.{current_run} },
        .{ .path = pinned_manifest, .run_paths = &.{}, .valid = false },
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
    try std.testing.expect(try pathExists(orphan_run));
    try std.testing.expect(try pathExists(stale_manifest));
}

test "node text run gc deletes canonical epochs and preserves lookalikes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buf);
    defer layout.deinit();
    const canonical = try layout.path("node_text_runs.manifest.10.1f");
    defer std.testing.allocator.free(canonical);
    const malformed_decimal = try layout.path("node_text_runs.manifest.bad.1f");
    defer std.testing.allocator.free(malformed_decimal);
    const malformed_hex = try layout.path("node_text_runs.manifest.10.nope");
    defer std.testing.allocator.free(malformed_hex);
    const extra_suffix = try layout.path("node_text_runs.manifest.10.1f.extra");
    defer std.testing.allocator.free(extra_suffix);
    const leading_decimal_zero = try layout.path("node_text_runs.manifest.010.1f");
    defer std.testing.allocator.free(leading_decimal_zero);
    const leading_hex_zero = try layout.path("node_text_runs.manifest.10.01f");
    defer std.testing.allocator.free(leading_hex_zero);
    const unrelated = try layout.path("node_text_runs.manifest-backup.10.1f");
    defer std.testing.allocator.free(unrelated);
    const base = try layout.path("node_text_runs.manifest");
    defer std.testing.allocator.free(base);
    const lookalike_dir = try layout.path("node_text_runs.manifest.11.20");
    defer std.testing.allocator.free(lookalike_dir);
    try createFile(canonical);
    try createFile(malformed_decimal);
    try createFile(malformed_hex);
    try createFile(extra_suffix);
    try createFile(leading_decimal_zero);
    try createFile(leading_hex_zero);
    try createFile(unrelated);
    try createFile(base);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, lookalike_dir);

    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .store_dir_path = layout.root,
        .manifest_path = layout.manifest_path,
    };
    const result = try test_gc.collect(&context, &.{});
    try std.testing.expectEqual(@as(u64, 1), result.deleted_manifests);
    try std.testing.expect(!try pathExists(canonical));
    try std.testing.expect(try pathExists(malformed_decimal));
    try std.testing.expect(try pathExists(malformed_hex));
    try std.testing.expect(try pathExists(extra_suffix));
    try std.testing.expect(try pathExists(leading_decimal_zero));
    try std.testing.expect(try pathExists(leading_hex_zero));
    try std.testing.expect(try pathExists(unrelated));
    try std.testing.expect(try pathExists(base));
    try std.testing.expect(try pathExists(lookalike_dir));
    try std.testing.expect(!test_gc.isManifestEpochLeaf("node_text_runs.manifest.10.1F", "node_text_runs.manifest"));
}
