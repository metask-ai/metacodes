const std = @import("std");
const checkpoint_store = @import("store.zig");
const checkpoint_mutation = @import("mutation.zig");
const format = @import("format.zig");
const checkpoint_wal = @import("wal.zig");

pub const current_leaf = "CURRENT";
pub const checkpoint_prefix = "CHECKPOINT-";
const current_magic = "TKGCUR1\n";
const current_version: u16 = 1;
const current_encoded_len: usize = 64;
const max_current_bytes: u64 = current_encoded_len;

pub const Current = struct {
    generation: u64,
    checkpoint_bytes: u64,
    checkpoint_digest: [32]u8,
};

pub const Loaded = struct {
    generation: u64,
    checkpoint: checkpoint_store.DecodedCheckpoint,
    wal: checkpoint_wal.ReplayPlan,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        self.checkpoint.snapshot.deinitOwned(allocator);
        self.wal.deinit();
        self.* = undefined;
    }
};

pub const Collection = struct {
    deleted_checkpoint_files: u64 = 0,
    deleted_wal_files: u64 = 0,
    deleted_temporary_files: u64 = 0,
    deleted_bytes: u64 = 0,
};

/// Complete on-disk accounting for one compact repository. The total includes
/// every recursively discovered regular file; recognized categories are only
/// an attribution aid and never remove bytes from the compression claim.
pub const Footprint = struct {
    logical_content_bytes: u64,
    current_checkpoint_bytes: u64,
    current_wal_bytes: u64,
    current_pointer_bytes: u64,
    obsolete_checkpoint_bytes: u64,
    obsolete_wal_bytes: u64,
    temporary_bytes: u64,
    derived_disk_cache_bytes: u64,
    unknown_regular_bytes: u64,
    total_operational_bytes: u64,
    regular_files: u64,

    pub fn canonicalOperationalBytes(self: Footprint) u64 {
        return self.current_checkpoint_bytes + self.current_wal_bytes + self.current_pointer_bytes;
    }

    pub fn otherOperationalBytes(self: Footprint) u64 {
        return self.obsolete_checkpoint_bytes + self.obsolete_wal_bytes + self.temporary_bytes + self.unknown_regular_bytes;
    }

    pub fn canonicalRatio(self: Footprint) f64 {
        return @as(f64, @floatFromInt(self.canonicalOperationalBytes())) /
            @as(f64, @floatFromInt(self.logical_content_bytes));
    }

    pub fn globalOperationalRatio(self: Footprint) f64 {
        return @as(f64, @floatFromInt(self.total_operational_bytes)) /
            @as(f64, @floatFromInt(self.logical_content_bytes));
    }

    pub fn underTwentyPercent(self: Footprint) bool {
        if (self.logical_content_bytes == 0 or self.total_operational_bytes > std.math.maxInt(u64) / 5) return false;
        return self.total_operational_bytes * 5 < self.logical_content_bytes;
    }
};

/// Durable generation owner for canonical checkpoint files. Publication is a
/// two-stage commit: first fsync and rename the immutable CHECKPOINT-n file,
/// then fsync and rename CURRENT. Previous generations remain available until
/// an explicit garbage-collection policy removes them.
pub const Repository = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []u8,
    durable: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        durable: bool,
    ) !Repository {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        return .{
            .allocator = allocator,
            .io = io,
            .dir_path = try allocator.dupe(u8, dir_path),
            .durable = durable,
        };
    }

    pub fn deinit(self: *Repository) void {
        self.allocator.free(self.dir_path);
        self.* = undefined;
    }

    pub fn readCurrent(self: Repository) !?Current {
        const path = try std.fs.path.join(self.allocator, &.{ self.dir_path, current_leaf });
        defer self.allocator.free(path);
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{ .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |other| return other,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size != max_current_bytes) return error.InvalidRecord;
        var bytes: [current_encoded_len]u8 = undefined;
        if (try file.readPositionalAll(self.io, &bytes, 0) != bytes.len) return error.InvalidRecord;
        return try decodeCurrent(&bytes);
    }

    pub fn publishSnapshot(self: Repository, snapshot: checkpoint_store.Snapshot) !Current {
        const encoded = try checkpoint_store.encodeAlloc(self.allocator, snapshot);
        defer encoded.deinit(self.allocator);
        return self.publishEncoded(encoded.bytes);
    }

    pub fn publishEncoded(self: Repository, checkpoint_bytes: []const u8) !Current {
        // Fully decode before any publication side effect. This prevents a
        // caller from publishing bytes that only happen to carry a valid file
        // prefix or header.
        const decoded_value = try checkpoint_store.decodeAlloc(self.allocator, checkpoint_bytes);
        var decoded = decoded_value.snapshot;
        decoded.deinitOwned(self.allocator);

        const generation = std.math.add(u64, try self.maxPublishedGeneration(), 1) catch return error.RecordTooLarge;
        const current = Current{
            .generation = generation,
            .checkpoint_bytes = @intCast(checkpoint_bytes.len),
            .checkpoint_digest = digest(checkpoint_bytes),
        };
        try self.writeCheckpointGeneration(current, checkpoint_bytes);
        var wal = try checkpoint_wal.Wal.createGeneration(self.allocator, self.io, self.dir_path, generation, self.durable);
        wal.deinit();
        try self.writeCurrent(current);
        return current;
    }

    pub fn loadCurrent(self: Repository) !?Loaded {
        const current = (try self.readCurrent()) orelse return null;
        return try self.loadGenerationVerified(current);
    }

    pub fn loadGeneration(self: Repository, generation: u64) !Loaded {
        if (generation == 0) return error.InvalidRecord;
        const bytes = try self.readGenerationBytes(generation, null);
        defer self.allocator.free(bytes);
        var checkpoint = try checkpoint_store.decodeAlloc(self.allocator, bytes);
        errdefer checkpoint.snapshot.deinitOwned(self.allocator);
        var wal = try checkpoint_wal.Wal.openGeneration(self.allocator, self.io, self.dir_path, generation, self.durable);
        defer wal.deinit();
        var replay = try wal.replay();
        errdefer replay.deinit();
        try applyReplay(self.allocator, &checkpoint, replay);
        return .{ .generation = generation, .checkpoint = checkpoint, .wal = replay };
    }

    /// Decode only the immutable checkpoint selected by `expected`, without
    /// replaying its WAL. Runtime WAL compaction uses this as the stable base
    /// for a minimal semantic delta while keeping the normal resident state at
    /// one decoded snapshot.
    pub fn loadCheckpointBase(
        self: Repository,
        expected: Current,
    ) !checkpoint_store.DecodedCheckpoint {
        const current = (try self.readCurrent()) orelse return error.FileNotFound;
        if (!currentEqual(current, expected)) return error.StaleGeneration;
        const bytes = try self.readGenerationBytes(current.generation, current);
        defer self.allocator.free(bytes);
        return checkpoint_store.decodeAlloc(self.allocator, bytes);
    }

    /// Point CURRENT at an already durable, verified generation. The target is
    /// decoded before CURRENT changes; rollback therefore fails closed when an
    /// old file was removed or corrupted.
    pub fn rollbackTo(self: Repository, generation: u64) !Current {
        if (generation == 0) return error.InvalidRecord;
        const bytes = try self.readGenerationBytes(generation, null);
        defer self.allocator.free(bytes);
        var wal = try checkpoint_wal.Wal.openGeneration(self.allocator, self.io, self.dir_path, generation, self.durable);
        defer wal.deinit();
        _ = try wal.recoverCrashTail();
        var loaded = try self.loadGeneration(generation);
        loaded.deinit(self.allocator);
        const current = Current{
            .generation = generation,
            .checkpoint_bytes = @intCast(bytes.len),
            .checkpoint_digest = digest(bytes),
        };
        try self.writeCurrent(current);
        return current;
    }

    /// Verify CURRENT, its checkpoint and its generation-bound WAL before
    /// deleting any other generation. This is the post-publication commit
    /// cleanup that returns the repository to the single-generation <20%
    /// steady state. Unknown files are retained and charged by accounting.
    pub fn collectObsolete(self: Repository) !Collection {
        const current = (try self.readCurrent()) orelse return error.FileNotFound;
        var wal = try checkpoint_wal.Wal.openGeneration(self.allocator, self.io, self.dir_path, current.generation, self.durable);
        defer wal.deinit();
        _ = try wal.recoverCrashTail();
        var loaded = (try self.loadCurrent()).?;
        loaded.deinit(self.allocator);

        return self.collectObsoleteAfterVerifiedCurrent(current);
    }

    /// Complete post-commit cleanup when the caller has already decoded and
    /// semantically admitted `expected`. CURRENT is reread as a cheap race
    /// guard, but the checkpoint and WAL are not decoded a second time.
    /// Callers must retain exclusive writer ownership between validation and
    /// this operation; a changed pointer fails closed before any deletion.
    pub fn collectObsoleteAfterVerifiedCurrent(
        self: Repository,
        expected: Current,
    ) !Collection {
        const current = (try self.readCurrent()) orelse return error.FileNotFound;
        if (!currentEqual(current, expected)) return error.StaleGeneration;

        var result: Collection = .{};
        var directory = try std.Io.Dir.cwd().openDir(self.io, self.dir_path, .{ .iterate = true });
        defer directory.close(self.io);
        var delete_names = std.ArrayList([]u8).empty;
        defer {
            for (delete_names.items) |name| self.allocator.free(name);
            delete_names.deinit(self.allocator);
        }
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const checkpoint_generation = parseGenerationLeaf(entry.name);
            const wal_generation = checkpoint_wal.parseGenerationLeaf(entry.name);
            const temporary = isRepositoryTemporary(entry.name);
            if ((checkpoint_generation != null and checkpoint_generation.? != current.generation) or
                (wal_generation != null and wal_generation.? != current.generation) or temporary)
            {
                try delete_names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }
        for (delete_names.items) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ self.dir_path, name });
            defer self.allocator.free(path);
            const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });
            try std.Io.Dir.cwd().deleteFile(self.io, path);
            result.deleted_bytes = try std.math.add(u64, result.deleted_bytes, stat.size);
            if (parseGenerationLeaf(name) != null) result.deleted_checkpoint_files += 1 else if (checkpoint_wal.parseGenerationLeaf(name) != null) result.deleted_wal_files += 1 else result.deleted_temporary_files += 1;
        }
        try self.syncDirectory();
        return result;
    }

    /// Audit the complete recursive physical footprint after verifying the
    /// CURRENT/checkpoint/WAL binding. Unknown files remain visible and are
    /// charged to `total_operational_bytes` so callers cannot accidentally
    /// claim a ratio from an incomplete allow-list.
    pub fn measureFootprint(self: Repository) !Footprint {
        const current = (try self.readCurrent()) orelse return error.FileNotFound;
        var loaded = (try self.loadCurrent()).?;
        defer loaded.deinit(self.allocator);
        if (loaded.wal.truncated_tail_bytes != 0) return error.RecoveryRequired;

        return self.measureFootprintAfterVerifiedCurrent(
            current,
            try format.logicalContentBytes(loaded.checkpoint.snapshot),
        );
    }

    /// Account every regular file after a caller has already admitted the
    /// selected checkpoint/WAL pair. This avoids decoding a multi-megabyte
    /// checkpoint again merely to refresh the byte ledger. CURRENT is still
    /// reread and matched exactly before any cached logical denominator is
    /// trusted.
    pub fn measureFootprintAfterVerifiedCurrent(
        self: Repository,
        expected: Current,
        logical_content_bytes: u64,
    ) !Footprint {
        if (logical_content_bytes == 0) return error.InvalidRecord;
        const current = (try self.readCurrent()) orelse return error.FileNotFound;
        if (!currentEqual(current, expected)) return error.StaleGeneration;

        var footprint: Footprint = .{
            .logical_content_bytes = logical_content_bytes,
            .current_checkpoint_bytes = 0,
            .current_wal_bytes = 0,
            .current_pointer_bytes = 0,
            .obsolete_checkpoint_bytes = 0,
            .obsolete_wal_bytes = 0,
            .temporary_bytes = 0,
            .derived_disk_cache_bytes = 0,
            .unknown_regular_bytes = 0,
            .total_operational_bytes = 0,
            .regular_files = 0,
        };
        try scanFootprint(self.allocator, self.io, self.dir_path, true, expected.generation, &footprint);
        if (footprint.current_checkpoint_bytes != current.checkpoint_bytes or
            footprint.current_wal_bytes < checkpoint_wal.file_header_len or
            footprint.current_pointer_bytes != max_current_bytes)
        {
            return error.InvalidRecord;
        }
        return footprint;
    }

    fn loadGenerationVerified(self: Repository, current: Current) !Loaded {
        const bytes = try self.readGenerationBytes(current.generation, current);
        defer self.allocator.free(bytes);
        var checkpoint = try checkpoint_store.decodeAlloc(self.allocator, bytes);
        errdefer checkpoint.snapshot.deinitOwned(self.allocator);
        var wal = try checkpoint_wal.Wal.openGeneration(self.allocator, self.io, self.dir_path, current.generation, self.durable);
        defer wal.deinit();
        var replay = try wal.replay();
        errdefer replay.deinit();
        try applyReplay(self.allocator, &checkpoint, replay);
        return .{ .generation = current.generation, .checkpoint = checkpoint, .wal = replay };
    }

    fn maxPublishedGeneration(self: Repository) !u64 {
        var directory = try std.Io.Dir.cwd().openDir(self.io, self.dir_path, .{ .iterate = true });
        defer directory.close(self.io);
        var maximum: u64 = 0;
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            maximum = @max(maximum, parseGenerationLeaf(entry.name) orelse continue);
        }
        return maximum;
    }

    fn readGenerationBytes(self: Repository, generation: u64, expected: ?Current) ![]u8 {
        const leaf = try generationLeaf(self.allocator, generation);
        defer self.allocator.free(leaf);
        const path = try std.fs.path.join(self.allocator, &.{ self.dir_path, leaf });
        defer self.allocator.free(path);
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .allow_directory = false });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size <= format.header_len or stat.size > format.header_len + format.max_payload_bytes) return error.InvalidRecord;
        if (expected) |value| if (stat.size != value.checkpoint_bytes) return error.InvalidRecord;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const bytes = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.InvalidRecord;
        if (expected) |value| if (!std.mem.eql(u8, &digest(bytes), &value.checkpoint_digest)) return error.DigestMismatch;
        return bytes;
    }

    fn writeCheckpointGeneration(self: Repository, current: Current, bytes: []const u8) !void {
        const leaf = try generationLeaf(self.allocator, current.generation);
        defer self.allocator.free(leaf);
        const final_path = try std.fs.path.join(self.allocator, &.{ self.dir_path, leaf });
        defer self.allocator.free(final_path);
        const temporary_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{final_path});
        defer self.allocator.free(temporary_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};

        // Generation files are immutable. A stale final path indicates either
        // external interference or a broken generation counter.
        if (std.Io.Dir.cwd().statFile(self.io, final_path, .{})) |_| {
            return error.PathAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        }
        std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        };
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, temporary_path, .{ .read = true, .truncate = true, .exclusive = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, bytes, 0);
            if (self.durable) try file.sync(self.io);
        }
        try rename(self.io, temporary_path, final_path);
        try self.syncDirectory();
    }

    fn writeCurrent(self: Repository, current: Current) !void {
        var bytes: [current_encoded_len]u8 = undefined;
        encodeCurrent(current, &bytes);
        const final_path = try std.fs.path.join(self.allocator, &.{ self.dir_path, current_leaf });
        defer self.allocator.free(final_path);
        const temporary_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{final_path});
        defer self.allocator.free(temporary_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, temporary_path, .{ .read = true, .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, &bytes, 0);
            if (self.durable) try file.sync(self.io);
        }
        try rename(self.io, temporary_path, final_path);
        try self.syncDirectory();
    }

    fn syncDirectory(self: Repository) !void {
        if (!self.durable or @import("builtin").os.tag == .windows) return;
        var directory = if (std.fs.path.isAbsolute(self.dir_path))
            try std.Io.Dir.openFileAbsolute(self.io, self.dir_path, .{ .allow_directory = true })
        else
            try std.Io.Dir.cwd().openFile(self.io, self.dir_path, .{ .allow_directory = true });
        defer directory.close(self.io);
        try directory.sync(self.io);
    }
};

fn applyReplay(
    allocator: std.mem.Allocator,
    checkpoint: *checkpoint_store.DecodedCheckpoint,
    replay: checkpoint_wal.ReplayPlan,
) !void {
    if (replay.truncated_tail_bytes != 0) return error.RecoveryRequired;
    for (replay.records) |record| {
        if (record.kind != .mutation) return error.InvalidRecord;
        const next = try checkpoint_mutation.applyEncodedAlloc(allocator, checkpoint.snapshot, record.payload);
        checkpoint.snapshot.deinitOwned(allocator);
        checkpoint.snapshot = next;
    }
}

fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

fn currentEqual(left: Current, right: Current) bool {
    return left.generation == right.generation and
        left.checkpoint_bytes == right.checkpoint_bytes and
        std.mem.eql(u8, &left.checkpoint_digest, &right.checkpoint_digest);
}

fn generationLeaf(allocator: std.mem.Allocator, generation: u64) ![]u8 {
    if (generation == 0) return error.InvalidRecord;
    return std.fmt.allocPrint(allocator, "{s}{d}", .{ checkpoint_prefix, generation });
}

fn parseGenerationLeaf(leaf: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, leaf, checkpoint_prefix)) return null;
    const raw = leaf[checkpoint_prefix.len..];
    if (raw.len == 0) return null;
    for (raw) |byte| if (byte < '0' or byte > '9') return null;
    const generation = std.fmt.parseUnsigned(u64, raw, 10) catch return null;
    return if (generation == 0) null else generation;
}

fn isRepositoryTemporary(leaf: []const u8) bool {
    if (std.mem.endsWith(u8, leaf, checkpoint_wal.rollback_suffix)) {
        return std.mem.startsWith(u8, leaf, checkpoint_wal.wal_prefix);
    }
    if (std.mem.endsWith(u8, leaf, ".tmp")) {
        return std.mem.eql(u8, leaf, current_leaf ++ ".tmp") or
            std.mem.startsWith(u8, leaf, checkpoint_prefix) or
            std.mem.startsWith(u8, leaf, checkpoint_wal.wal_prefix);
    }
    return false;
}

fn isDerivedCacheLeaf(leaf: []const u8) bool {
    return std.mem.startsWith(u8, leaf, "text_") or
        std.mem.startsWith(u8, leaf, "edge_") or
        std.mem.startsWith(u8, leaf, "node_by_") or
        std.mem.startsWith(u8, leaf, "node_text_") or
        std.mem.eql(u8, leaf, "index.meta");
}

fn addFootprintBytes(total: *u64, size: u64) !void {
    total.* = std.math.add(u64, total.*, size) catch return error.RecordTooLarge;
}

fn scanFootprint(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    root: bool,
    current_generation: u64,
    footprint: *Footprint,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => try scanFootprint(allocator, io, child, false, current_generation, footprint),
            .file => {
                const stat = try std.Io.Dir.cwd().statFile(io, child, .{ .follow_symlinks = false });
                try addFootprintBytes(&footprint.total_operational_bytes, stat.size);
                footprint.regular_files = std.math.add(u64, footprint.regular_files, 1) catch return error.RecordTooLarge;
                if (root and parseGenerationLeaf(entry.name) == current_generation) {
                    try addFootprintBytes(&footprint.current_checkpoint_bytes, stat.size);
                } else if (root and checkpoint_wal.parseGenerationLeaf(entry.name) == current_generation) {
                    try addFootprintBytes(&footprint.current_wal_bytes, stat.size);
                } else if (root and std.mem.eql(u8, entry.name, current_leaf)) {
                    try addFootprintBytes(&footprint.current_pointer_bytes, stat.size);
                } else if (root and parseGenerationLeaf(entry.name) != null) {
                    try addFootprintBytes(&footprint.obsolete_checkpoint_bytes, stat.size);
                } else if (root and checkpoint_wal.parseGenerationLeaf(entry.name) != null) {
                    try addFootprintBytes(&footprint.obsolete_wal_bytes, stat.size);
                } else if (root and isRepositoryTemporary(entry.name)) {
                    try addFootprintBytes(&footprint.temporary_bytes, stat.size);
                } else if (root and isDerivedCacheLeaf(entry.name)) {
                    try addFootprintBytes(&footprint.derived_disk_cache_bytes, stat.size);
                } else {
                    try addFootprintBytes(&footprint.unknown_regular_bytes, stat.size);
                }
            },
            else => {},
        }
    }
}

fn encodeCurrent(current: Current, out: *[current_encoded_len]u8) void {
    @memset(out, 0);
    @memcpy(out[0..8], current_magic);
    std.mem.writeInt(u16, out[8..10], current_version, .little);
    std.mem.writeInt(u16, out[10..12], current_encoded_len, .little);
    std.mem.writeInt(u64, out[16..24], current.generation, .little);
    std.mem.writeInt(u64, out[24..32], current.checkpoint_bytes, .little);
    @memcpy(out[32..64], &current.checkpoint_digest);
}

fn decodeCurrent(bytes: *const [current_encoded_len]u8) !Current {
    if (!std.mem.eql(u8, bytes[0..8], current_magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[8..10], .little) != current_version) return error.UnsupportedVersion;
    if (std.mem.readInt(u16, bytes[10..12], .little) != current_encoded_len) return error.InvalidRecord;
    for (bytes[12..16]) |byte| if (byte != 0) return error.InvalidRecord;
    const current = Current{
        .generation = std.mem.readInt(u64, bytes[16..24], .little),
        .checkpoint_bytes = std.mem.readInt(u64, bytes[24..32], .little),
        .checkpoint_digest = bytes[32..64].*,
    };
    if (current.generation == 0 or current.checkpoint_bytes <= format.header_len or current.checkpoint_bytes > format.header_len + format.max_payload_bytes) return error.InvalidRecord;
    return current;
}

fn rename(io: std.Io, source: []const u8, destination: []const u8) !void {
    if (std.fs.path.isAbsolute(destination)) {
        try std.Io.Dir.renameAbsolute(source, destination, io);
    } else {
        try std.Io.Dir.rename(.cwd(), source, .cwd(), destination, io);
    }
}

fn testSnapshot(text: []const u8) checkpoint_store.Snapshot {
    const Test = struct {
        var nodes = [_]format.Node{.{ .id = 1, .kind = 10, .text = "" }};
    };
    Test.nodes[0].text = text;
    return .{ .nodes = &Test.nodes, .edges = &.{}, .properties = &.{} };
}

test "checkpoint repository publishes generations and supports verified rollback" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var repository = try Repository.init(std.testing.allocator, std.testing.io, path_buffer[0..root_len], false);
    defer repository.deinit();

    const first = try repository.publishSnapshot(testSnapshot("one"));
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    const second = try repository.publishSnapshot(testSnapshot("two"));
    try std.testing.expectEqual(@as(u64, 2), second.generation);
    var loaded = (try repository.loadCurrent()).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), loaded.generation);
    try std.testing.expectEqualStrings("two", loaded.checkpoint.snapshot.nodes[0].text);

    _ = try repository.rollbackTo(1);
    var rolled_back = (try repository.loadCurrent()).?;
    defer rolled_back.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), rolled_back.generation);
    try std.testing.expectEqualStrings("one", rolled_back.checkpoint.snapshot.nodes[0].text);

    // Rollback does not overwrite or remove the newer immutable generation.
    var retained = try repository.loadGeneration(2);
    defer retained.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("two", retained.checkpoint.snapshot.nodes[0].text);

    const third = try repository.publishSnapshot(testSnapshot("three"));
    try std.testing.expectEqual(@as(u64, 3), third.generation);
    const gc = try repository.collectObsolete();
    try std.testing.expectEqual(@as(u64, 2), gc.deleted_checkpoint_files);
    try std.testing.expectEqual(@as(u64, 2), gc.deleted_wal_files);
    var current_after_gc = (try repository.loadCurrent()).?;
    defer current_after_gc.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("three", current_after_gc.checkpoint.snapshot.nodes[0].text);
}

test "checkpoint repository ignores stale temporary files and fails closed on corruption" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var repository = try Repository.init(std.testing.allocator, std.testing.io, root, false);
    defer repository.deinit();
    _ = try repository.publishSnapshot(testSnapshot("stable"));
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "CHECKPOINT-2.tmp", .data = "partial" });

    _ = try repository.publishSnapshot(testSnapshot("after crash"));
    var loaded = (try repository.loadCurrent()).?;
    try std.testing.expectEqualStrings("after crash", loaded.checkpoint.snapshot.nodes[0].text);
    loaded.deinit(std.testing.allocator);
    var checkpoint = try temporary.dir.openFile(std.testing.io, "CHECKPOINT-1", .{ .mode = .read_write });
    defer checkpoint.close(std.testing.io);
    var original: [1]u8 = undefined;
    // Corrupt the checkpoint header's payload digest while leaving the zstd
    // frame intact so the rejection is deterministic across zstd versions.
    if (try checkpoint.readPositionalAll(std.testing.io, &original, 88) != 1) return error.InvalidRecord;
    original[0] ^= 0x55;
    try checkpoint.writePositionalAll(std.testing.io, &original, 88);
    try std.testing.expectError(error.DigestMismatch, repository.rollbackTo(1));
}
