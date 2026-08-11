const std = @import("std");

/// Owns the cross-process manifest-reader acquisition and discovery protocol.
/// `Ops` keeps Store-specific CURRENT reads, path derivation, process liveness,
/// temporary naming, rename/fsync mechanics, and the retention handle type in
/// the storage façade. GC and compaction consume only the owned path list that
/// this controller returns; they do not participate in lease stabilization.
pub fn ManifestProcessLeaseManager(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const ProcessId = u64;
        const max_acquire_attempts: usize = 16;
        const max_lease_bytes: usize = 8192;

        var nonce: std.atomic.Value(u64) = .init(0);

        pub const Kind = enum {
            edge_segment,
            node_text_run,

            fn tag(self: Kind) []const u8 {
                return switch (self) {
                    .edge_segment => "edge-segment",
                    .node_text_run => "node-text-run",
                };
            }

            fn filePrefix(self: Kind) []const u8 {
                return switch (self) {
                    .edge_segment => "edge",
                    .node_text_run => "node-text",
                };
            }
        };

        pub const Acquired = struct {
            path_allocator: std.mem.Allocator,
            manifest_path: []u8,
            process_lease: Ops.Lease,
            path_owned: bool = true,
            lease_owned: bool = true,

            pub fn deinit(self: *Acquired) void {
                if (self.lease_owned) self.process_lease.deinit();
                if (self.path_owned) self.path_allocator.free(self.manifest_path);
                self.path_owned = false;
                self.lease_owned = false;
            }

            pub fn takeManifestPath(self: *Acquired) []u8 {
                std.debug.assert(self.path_owned);
                self.path_owned = false;
                return self.manifest_path;
            }

            pub fn takeProcessLease(self: *Acquired) Ops.Lease {
                std.debug.assert(self.lease_owned);
                self.lease_owned = false;
                return self.process_lease;
            }
        };

        const Parsed = struct {
            kind: Kind,
            pid: ProcessId,
            manifest_path: []const u8,
        };

        pub fn acquireCurrent(
            context: anytype,
            allocator: std.mem.Allocator,
            kind: Kind,
        ) !?Acquired {
            // Reading CURRENT and publishing the lease are not one atomic
            // action. Re-read CURRENT after the lease is visible: if a
            // publisher moved it in between, that publisher may already have
            // reclaimed the old epoch. A stable match means every later
            // reclaimer must observe this lease. Bound retries so a reader
            // cannot spin forever behind a changing writer.
            for (0..max_acquire_attempts) |_| {
                const candidate = (try Ops.currentManifestPath(context, allocator, kind)) orelse return null;
                if (try Self.acquireCandidate(context, allocator, kind, candidate)) |acquired| return acquired;
            }
            return error.WouldBlock;
        }

        /// Consumes `candidate` on every path. A lease that became visible for
        /// a stale pre-read candidate is removed before returning `null`.
        pub fn acquireCandidate(
            context: anytype,
            allocator: std.mem.Allocator,
            kind: Kind,
            candidate: []u8,
        ) !?Acquired {
            var candidate_owned = true;
            defer if (candidate_owned) allocator.free(candidate);

            var process_lease = try create(context, kind, candidate);
            var lease_owned = true;
            defer if (lease_owned) process_lease.deinit();

            const observed = try Ops.currentManifestPath(context, allocator, kind);
            defer if (observed) |path| allocator.free(path);
            if (observed == null or !std.mem.eql(u8, candidate, observed.?)) return null;

            candidate_owned = false;
            lease_owned = false;
            return .{
                .path_allocator = allocator,
                .manifest_path = candidate,
                .process_lease = process_lease,
            };
        }

        pub fn activePaths(
            context: anytype,
            kind: Kind,
            allocator: std.mem.Allocator,
        ) ![]const []const u8 {
            const internal_allocator = Ops.allocator(context);
            const io = Ops.io(context);
            const lease_dir_path = try Ops.leaseDirPath(context, internal_allocator);
            defer internal_allocator.free(lease_dir_path);

            var leases_dir = std.Io.Dir.cwd().openDir(io, lease_dir_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => {
                    var empty = std.ArrayList([]const u8).empty;
                    return try empty.toOwnedSlice(allocator);
                },
                else => |other| return other,
            };
            defer leases_dir.close(io);

            var paths = std.ArrayList([]const u8).empty;
            errdefer freeOwnedPathArrayList(allocator, &paths);
            var iter = leases_dir.iterate();
            while (try iter.next(io)) |entry| {
                if (entry.kind != .file) continue;
                const lease_path = try std.fs.path.join(internal_allocator, &.{ lease_dir_path, entry.name });
                defer internal_allocator.free(lease_path);
                const content = std.Io.Dir.cwd().readFileAlloc(
                    io,
                    lease_path,
                    internal_allocator,
                    .limited(max_lease_bytes),
                ) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    error.StreamTooLong => {
                        std.Io.Dir.cwd().deleteFile(io, lease_path) catch {};
                        continue;
                    },
                    else => |other| return other,
                };
                defer internal_allocator.free(content);
                const lease = parse(content) orelse {
                    std.Io.Dir.cwd().deleteFile(io, lease_path) catch {};
                    continue;
                };
                if (!Ops.processIdIsAlive(context, lease.pid)) {
                    std.Io.Dir.cwd().deleteFile(io, lease_path) catch {};
                    continue;
                }
                if (lease.kind != kind) continue;
                const owned_manifest_path = try allocator.dupe(u8, lease.manifest_path);
                errdefer allocator.free(owned_manifest_path);
                try paths.append(allocator, owned_manifest_path);
            }
            return try paths.toOwnedSlice(allocator);
        }

        pub fn pinnedPaths(
            context: anytype,
            kind: Kind,
            allocator: std.mem.Allocator,
            explicit_paths: []const []const u8,
        ) ![]const []const u8 {
            var protected_paths = std.ArrayList([]const u8).empty;
            errdefer freeOwnedPathArrayList(allocator, &protected_paths);

            try protected_paths.ensureTotalCapacity(allocator, explicit_paths.len);
            for (explicit_paths) |path| {
                const owned_path = try allocator.dupe(u8, path);
                protected_paths.appendAssumeCapacity(owned_path);
            }

            const process_paths = try Self.activePaths(context, kind, allocator);
            defer freeOwnedPaths(allocator, process_paths);
            try protected_paths.ensureUnusedCapacity(allocator, process_paths.len);
            for (process_paths) |path| {
                const owned_path = try allocator.dupe(u8, path);
                protected_paths.appendAssumeCapacity(owned_path);
            }
            return try protected_paths.toOwnedSlice(allocator);
        }

        fn create(context: anytype, kind: Kind, manifest_path: []const u8) !Ops.Lease {
            const allocator = Ops.allocator(context);
            const io = Ops.io(context);
            const lease_dir_path = try Ops.leaseDirPath(context, allocator);
            defer allocator.free(lease_dir_path);
            try std.Io.Dir.cwd().createDirPath(io, lease_dir_path);

            const pid = Ops.currentProcessId(context);
            const next_nonce = nonce.fetchAdd(1, .monotonic);
            const manifest_hash = std.hash.Wyhash.hash(0, manifest_path);
            const leaf = try std.fmt.allocPrint(
                allocator,
                "{s}-{d}-{x}-{x}.lease",
                .{ kind.filePrefix(), pid, manifest_hash, next_nonce },
            );
            defer allocator.free(leaf);
            const lease_path = try std.fs.path.join(allocator, &.{ lease_dir_path, leaf });
            errdefer allocator.free(lease_path);

            const content = try format(allocator, kind, pid, manifest_path);
            defer allocator.free(content);
            errdefer std.Io.Dir.cwd().deleteFile(io, lease_path) catch {};
            const lease_tmp_path = try Ops.tempPath(context, lease_path);
            defer allocator.free(lease_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, lease_tmp_path) catch {};
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = lease_tmp_path,
                .data = content,
                .flags = .{ .truncate = true },
            });
            try Ops.renameReplace(context, lease_tmp_path, lease_path);
            return Ops.makeLease(context, lease_path);
        }

        fn format(
            allocator: std.mem.Allocator,
            kind: Kind,
            pid: ProcessId,
            manifest_path: []const u8,
        ) ![]u8 {
            return try std.fmt.allocPrint(
                allocator,
                "tinykg-manifest-lease-v1\nkind={s}\npid={d}\nmanifest={s}\n",
                .{ kind.tag(), pid, manifest_path },
            );
        }

        fn parse(content: []const u8) ?Parsed {
            var lines = std.mem.splitScalar(u8, content, '\n');
            const magic = lines.next() orelse return null;
            if (!std.mem.eql(u8, magic, "tinykg-manifest-lease-v1")) return null;
            const kind_line = lines.next() orelse return null;
            const pid_line = lines.next() orelse return null;
            const manifest_line = lines.next() orelse return null;
            if (!std.mem.startsWith(u8, kind_line, "kind=")) return null;
            if (!std.mem.startsWith(u8, pid_line, "pid=")) return null;
            if (!std.mem.startsWith(u8, manifest_line, "manifest=")) return null;
            const kind_value = kind_line["kind=".len..];
            const kind: Kind = if (std.mem.eql(u8, kind_value, Kind.edge_segment.tag()))
                .edge_segment
            else if (std.mem.eql(u8, kind_value, Kind.node_text_run.tag()))
                .node_text_run
            else
                return null;
            const pid = std.fmt.parseInt(ProcessId, pid_line["pid=".len..], 10) catch return null;
            const manifest_path = manifest_line["manifest=".len..];
            if (manifest_path.len == 0) return null;
            return .{ .kind = kind, .pid = pid, .manifest_path = manifest_path };
        }

        fn freeOwnedPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
            for (paths) |path| allocator.free(path);
            allocator.free(paths);
        }

        fn freeOwnedPathArrayList(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
            for (paths.items) |path| allocator.free(path);
            paths.deinit(allocator);
        }
    };
}

const TestLease = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,

    fn deinit(self: *TestLease) void {
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        self.allocator.free(self.path);
        self.path = &.{};
    }
};

const CurrentMode = enum {
    absent,
    stable,
    alternating,
};

const TestContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lease_dir_path: []const u8,
    current_mode: CurrentMode = .absent,
    stable_path: []const u8 = "manifest-current",
    first_path: []const u8 = "manifest-old",
    second_path: []const u8 = "manifest-new",
    current_reads: usize = 0,
    tmp_nonce: usize = 0,
    current_pid: u64 = 41,
    alive_pid: u64 = 41,
};

const TestOps = struct {
    pub const Lease = TestLease;

    fn allocator(context: *TestContext) std.mem.Allocator {
        return context.allocator;
    }

    fn io(context: *TestContext) std.Io {
        return context.io;
    }

    fn leaseDirPath(context: *TestContext, allocator_arg: std.mem.Allocator) ![]u8 {
        return try allocator_arg.dupe(u8, context.lease_dir_path);
    }

    fn currentManifestPath(
        context: *TestContext,
        allocator_arg: std.mem.Allocator,
        kind: anytype,
    ) !?[]u8 {
        _ = kind;
        const read_index = context.current_reads;
        context.current_reads += 1;
        const path = switch (context.current_mode) {
            .absent => return null,
            .stable => context.stable_path,
            .alternating => if (read_index % 2 == 0) context.first_path else context.second_path,
        };
        return try allocator_arg.dupe(u8, path);
    }

    fn tempPath(context: *TestContext, path: []const u8) ![]u8 {
        const value = context.tmp_nonce;
        context.tmp_nonce += 1;
        return try std.fmt.allocPrint(context.allocator, "{s}.tmp-{d}", .{ path, value });
    }

    fn renameReplace(context: *TestContext, tmp_path: []const u8, final_path: []const u8) !void {
        try std.Io.Dir.renameAbsolute(tmp_path, final_path, context.io);
    }

    fn currentProcessId(context: *TestContext) u64 {
        return context.current_pid;
    }

    fn processIdIsAlive(context: *TestContext, pid: u64) bool {
        return pid == context.alive_pid;
    }

    fn makeLease(context: *TestContext, path: []u8) Lease {
        return .{ .allocator = context.allocator, .io = context.io, .path = path };
    }
};

const test_manager = ManifestProcessLeaseManager(TestOps);

fn testLeaseDir(tmp: *std.testing.TmpDir, path_buf: []u8) ![]const u8 {
    const root_len = try tmp.dir.realPath(std.testing.io, path_buf);
    return path_buf[0..root_len];
}

fn writeFixture(path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = content,
        .flags = .{ .truncate = true },
    });
}

fn fixturePath(allocator: std.mem.Allocator, dir_path: []const u8, leaf: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ dir_path, leaf });
}

fn fileExists(path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch return false;
    file.close(std.testing.io);
    return true;
}

fn countFiles(dir_path: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |other| return other,
    };
    defer dir.close(std.testing.io);
    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(std.testing.io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

fn freeTestPaths(paths: []const []const u8) void {
    for (paths) |path| std.testing.allocator.free(path);
    std.testing.allocator.free(paths);
}

test "manifest process lease format round trips and rejects malformed records" {
    const content = try test_manager.format(std.testing.allocator, .edge_segment, 42, "/tmp/epoch-7");
    defer std.testing.allocator.free(content);
    const parsed = test_manager.parse(content).?;
    try std.testing.expectEqual(test_manager.Kind.edge_segment, parsed.kind);
    try std.testing.expectEqual(@as(u64, 42), parsed.pid);
    try std.testing.expectEqualStrings("/tmp/epoch-7", parsed.manifest_path);

    try std.testing.expect(test_manager.parse("wrong\nkind=edge-segment\npid=42\nmanifest=x\n") == null);
    try std.testing.expect(test_manager.parse("tinykg-manifest-lease-v1\nkind=other\npid=42\nmanifest=x\n") == null);
    try std.testing.expect(test_manager.parse("tinykg-manifest-lease-v1\nkind=edge-segment\npid=x\nmanifest=x\n") == null);
    try std.testing.expect(test_manager.parse("tinykg-manifest-lease-v1\nkind=edge-segment\npid=42\nmanifest=\n") == null);
}

test "manifest process lease acquires a stable current and releases its file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try testLeaseDir(&tmp, &path_buf);
    const lease_dir_path = try fixturePath(std.testing.allocator, root_path, "leases");
    defer std.testing.allocator.free(lease_dir_path);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .lease_dir_path = lease_dir_path,
        .current_mode = .stable,
    };

    var acquired = (try test_manager.acquireCurrent(&context, std.testing.allocator, .edge_segment)).?;
    try std.testing.expectEqualStrings(context.stable_path, acquired.manifest_path);
    const lease_path = try std.testing.allocator.dupe(u8, acquired.process_lease.path);
    defer std.testing.allocator.free(lease_path);
    try std.testing.expect(fileExists(lease_path));
    acquired.deinit();
    try std.testing.expect(!fileExists(lease_path));
    try std.testing.expectEqual(@as(usize, 2), context.current_reads);
}

test "manifest process lease rejects a changed current candidate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try testLeaseDir(&tmp, &path_buf);
    const lease_dir_path = try fixturePath(std.testing.allocator, root_path, "leases");
    defer std.testing.allocator.free(lease_dir_path);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .lease_dir_path = lease_dir_path,
        .current_mode = .stable,
        .stable_path = "manifest-new",
    };
    const candidate = try std.testing.allocator.dupe(u8, "manifest-old");

    try std.testing.expect((try test_manager.acquireCandidate(
        &context,
        std.testing.allocator,
        .edge_segment,
        candidate,
    )) == null);
    try std.testing.expectEqual(@as(usize, 0), try countFiles(lease_dir_path));
}

test "manifest process lease bounds retries behind a changing current" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try testLeaseDir(&tmp, &path_buf);
    const lease_dir_path = try fixturePath(std.testing.allocator, root_path, "leases");
    defer std.testing.allocator.free(lease_dir_path);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .lease_dir_path = lease_dir_path,
        .current_mode = .alternating,
    };

    try std.testing.expectError(
        error.WouldBlock,
        test_manager.acquireCurrent(&context, std.testing.allocator, .node_text_run),
    );
    try std.testing.expectEqual(@as(usize, 32), context.current_reads);
    try std.testing.expectEqual(@as(usize, 0), try countFiles(lease_dir_path));
}

test "manifest process lease scan removes malformed dead and oversized files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try testLeaseDir(&tmp, &path_buf);
    const lease_dir_path = try fixturePath(std.testing.allocator, root_path, "leases");
    defer std.testing.allocator.free(lease_dir_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, lease_dir_path);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .lease_dir_path = lease_dir_path,
        .current_pid = 42,
        .alive_pid = 42,
    };

    const live_path = try fixturePath(std.testing.allocator, lease_dir_path, "live.lease");
    defer std.testing.allocator.free(live_path);
    const other_path = try fixturePath(std.testing.allocator, lease_dir_path, "other.lease");
    defer std.testing.allocator.free(other_path);
    const dead_path = try fixturePath(std.testing.allocator, lease_dir_path, "dead.lease");
    defer std.testing.allocator.free(dead_path);
    const malformed_path = try fixturePath(std.testing.allocator, lease_dir_path, "malformed.lease");
    defer std.testing.allocator.free(malformed_path);
    const oversized_path = try fixturePath(std.testing.allocator, lease_dir_path, "oversized.lease");
    defer std.testing.allocator.free(oversized_path);

    const live = try test_manager.format(std.testing.allocator, .edge_segment, 42, "edge-live");
    defer std.testing.allocator.free(live);
    const other = try test_manager.format(std.testing.allocator, .node_text_run, 42, "node-live");
    defer std.testing.allocator.free(other);
    const dead = try test_manager.format(std.testing.allocator, .edge_segment, 99, "edge-dead");
    defer std.testing.allocator.free(dead);
    try writeFixture(live_path, live);
    try writeFixture(other_path, other);
    try writeFixture(dead_path, dead);
    try writeFixture(malformed_path, "not-a-lease");
    var oversized: [8193]u8 = undefined;
    @memset(&oversized, 'x');
    try writeFixture(oversized_path, &oversized);

    const paths = try test_manager.activePaths(&context, .edge_segment, std.testing.allocator);
    defer freeTestPaths(paths);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("edge-live", paths[0]);
    try std.testing.expect(fileExists(live_path));
    try std.testing.expect(fileExists(other_path));
    try std.testing.expect(!fileExists(dead_path));
    try std.testing.expect(!fileExists(malformed_path));
    try std.testing.expect(!fileExists(oversized_path));
}

test "manifest process lease merges explicit and live process pins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try testLeaseDir(&tmp, &path_buf);
    const lease_dir_path = try fixturePath(std.testing.allocator, root_path, "leases");
    defer std.testing.allocator.free(lease_dir_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, lease_dir_path);
    var context = TestContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .lease_dir_path = lease_dir_path,
        .current_pid = 42,
        .alive_pid = 42,
    };
    const lease_path = try fixturePath(std.testing.allocator, lease_dir_path, "live.lease");
    defer std.testing.allocator.free(lease_path);
    const live = try test_manager.format(std.testing.allocator, .edge_segment, 42, "process-pin");
    defer std.testing.allocator.free(live);
    try writeFixture(lease_path, live);

    const paths = try test_manager.pinnedPaths(
        &context,
        .edge_segment,
        std.testing.allocator,
        &.{ "explicit-a", "explicit-b" },
    );
    defer freeTestPaths(paths);
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings("explicit-a", paths[0]);
    try std.testing.expectEqualStrings("explicit-b", paths[1]);
    try std.testing.expectEqualStrings("process-pin", paths[2]);
}
