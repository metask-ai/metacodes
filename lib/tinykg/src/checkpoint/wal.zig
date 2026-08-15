const std = @import("std");
const wal_codec = @import("wal_codec.zig");

pub const max_file_bytes: u64 = 64 * 1024;
pub const file_header_len: usize = 64;
pub const record_header_len: usize = 64;
const file_magic = "TKGWAL1\n";
const record_magic = "REC1";
const version: u16 = 1;
const adaptive_record_version: u16 = 2;
pub const wal_prefix = "WAL-";
pub const rollback_suffix = ".rollback";

pub const RecordKind = enum(u8) {
    /// One application-level mutation transaction. Its payload is interpreted
    /// by the canonical state adapter; WAL framing only owns durability,
    /// ordering, generation binding and crash-tail recovery.
    mutation = 1,
};

pub const Record = struct {
    sequence: u64,
    kind: RecordKind,
    payload: []u8,
};

pub const PayloadCodec = enum(u8) {
    raw = 0,
    zstd = 1,
};

/// Prepared physical payload for one WAL record. Runtime uses the exact stored
/// byte length for admission; replay always returns the logical bytes.
pub const EncodedPayload = struct {
    allocator: std.mem.Allocator,
    codec: PayloadCodec,
    bytes: []u8,
    logical_bytes: usize,

    pub fn deinit(self: *EncodedPayload) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn framedBytes(self: EncodedPayload) !u64 {
        return std.math.add(u64, record_header_len, self.bytes.len) catch error.RecordTooLarge;
    }
};

pub fn encodePayloadAlloc(allocator: std.mem.Allocator, payload: []const u8) !EncodedPayload {
    if (payload.len == 0) return error.InvalidRecord;
    if (payload.len > wal_codec.max_uncompressed_bytes) return error.RecordTooLarge;
    const compressed = try wal_codec.compressAlloc(allocator, payload);
    if (compressed.len < payload.len) {
        return .{
            .allocator = allocator,
            .codec = .zstd,
            .bytes = compressed,
            .logical_bytes = payload.len,
        };
    }
    allocator.free(compressed);
    return .{
        .allocator = allocator,
        .codec = .raw,
        .bytes = try allocator.dupe(u8, payload),
        .logical_bytes = payload.len,
    };
}

pub const ReplayPlan = struct {
    allocator: std.mem.Allocator,
    generation: u64,
    records: []Record,
    valid_bytes: u64,
    truncated_tail_bytes: u64,

    pub fn deinit(self: *ReplayPlan) void {
        for (self.records) |record| self.allocator.free(record.payload);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

pub const StagedReplacement = struct {
    wal: Wal,
    temporary_path: []u8,
    rollback_path: []u8,
    replacement_bytes: u64,
    replacement_digest: [32]u8,
    committed: bool = false,

    pub fn commit(self: *StagedReplacement) !void {
        if (self.committed) return error.InvalidRecord;
        if (std.Io.Dir.cwd().statFile(self.wal.io, self.rollback_path, .{})) |_| {
            return error.PathAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        }
        try rename(self.wal.io, self.wal.path, self.rollback_path);
        rename(self.wal.io, self.temporary_path, self.wal.path) catch |err| {
            // The live process still owns the writer lease. Restore the old
            // valid WAL if the second rename itself fails; a process crash in
            // this gap is repaired by openGeneration instead.
            rename(self.wal.io, self.rollback_path, self.wal.path) catch {};
            return err;
        };
        try syncDirectory(
            self.wal.io,
            std.fs.path.dirname(self.wal.path) orelse ".",
            self.wal.durable,
        );
        self.committed = true;
    }

    /// Allocation-free post-rename admission. The old WAL remains at the
    /// rollback path until the canonical name is proven byte-identical to the
    /// staged file that was replay-validated before commit.
    pub fn verifyCommitted(self: StagedReplacement) !void {
        if (!self.committed) return error.InvalidRecord;
        const observed = try fileDigest(
            self.wal.io,
            self.wal.path,
            self.replacement_bytes,
        );
        if (!std.mem.eql(u8, &observed, &self.replacement_digest)) return error.DigestMismatch;
    }

    pub fn deinit(self: *StagedReplacement) void {
        if (!self.committed) {
            std.Io.Dir.cwd().deleteFile(self.wal.io, self.temporary_path) catch {};
        }
        self.wal.allocator.free(self.temporary_path);
        self.wal.allocator.free(self.rollback_path);
        self.* = undefined;
    }
};

pub const Wal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    generation: u64,
    durable: bool,

    pub fn createGeneration(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: []const u8,
        generation: u64,
        durable: bool,
    ) !Wal {
        if (generation == 0) return error.InvalidRecord;
        const path = try generationPath(allocator, directory, generation);
        errdefer allocator.free(path);
        const temporary_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(temporary_path);
        errdefer std.Io.Dir.cwd().deleteFile(io, temporary_path) catch {};
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| {
            return error.PathAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        }
        std.Io.Dir.cwd().deleteFile(io, temporary_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        };
        var bytes: [file_header_len]u8 = undefined;
        encodeFileHeader(generation, &bytes);
        {
            var file = try std.Io.Dir.cwd().createFile(io, temporary_path, .{ .read = true, .truncate = true, .exclusive = true });
            defer file.close(io);
            try file.writePositionalAll(io, &bytes, 0);
            if (durable) try file.sync(io);
        }
        try rename(io, temporary_path, path);
        try syncDirectory(io, directory, durable);
        return .{ .allocator = allocator, .io = io, .path = path, .generation = generation, .durable = durable };
    }

    pub fn openGeneration(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: []const u8,
        generation: u64,
        durable: bool,
    ) !Wal {
        const path = try generationPath(allocator, directory, generation);
        errdefer allocator.free(path);
        var file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // Power loss may occur after the old WAL was moved aside but
                // before the staged replacement reached its canonical name.
                // Restore the old complete file; recognized tmp/rollback
                // artifacts are removed only after CURRENT and replay verify.
                const rollback_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, rollback_suffix });
                defer allocator.free(rollback_path);
                rename(io, rollback_path, path) catch |restore_err| switch (restore_err) {
                    error.FileNotFound => return err,
                    else => |other| return other,
                };
                try syncDirectory(io, directory, durable);
                break :blk try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
            },
            else => |other| return other,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size < file_header_len or stat.size > max_file_bytes) return error.InvalidRecord;
        var bytes: [file_header_len]u8 = undefined;
        if (try file.readPositionalAll(io, &bytes, 0) != bytes.len) return error.InvalidRecord;
        if (try decodeFileHeader(&bytes) != generation) return error.InvalidRecord;
        return .{ .allocator = allocator, .io = io, .path = path, .generation = generation, .durable = durable };
    }

    pub fn deinit(self: *Wal) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Fail-closed preflight: no byte is written unless the complete framed
    /// transaction fits inside the hard WAL bound.
    pub fn append(self: Wal, kind: RecordKind, payload: []const u8) !u64 {
        var encoded = try encodePayloadAlloc(self.allocator, payload);
        defer encoded.deinit();
        return self.appendEncoded(kind, encoded);
    }

    pub fn appendEncoded(self: Wal, kind: RecordKind, encoded: EncodedPayload) !u64 {
        const plan = try self.replay();
        defer {
            var mutable = plan;
            mutable.deinit();
        }
        if (plan.truncated_tail_bytes != 0) return error.RecoveryRequired;
        const record_bytes = try encoded.framedBytes();
        const next_size = std.math.add(u64, plan.valid_bytes, record_bytes) catch return error.RecordTooLarge;
        if (next_size > max_file_bytes) return error.CheckpointRequired;
        const sequence = std.math.add(u64, @as(u64, @intCast(plan.records.len)), 1) catch return error.RecordTooLarge;
        var header: [record_header_len]u8 = undefined;
        encodeRecordHeader(self.generation, sequence, kind, encoded, &header);
        var file = try std.Io.Dir.cwd().openFile(self.io, self.path, .{ .mode = .read_write, .allow_directory = false });
        defer file.close(self.io);
        try file.writePositionalAll(self.io, &header, plan.valid_bytes);
        try file.writePositionalAll(self.io, encoded.bytes, plan.valid_bytes + record_header_len);
        if (self.durable) try file.sync(self.io);
        return sequence;
    }

    /// Read-only admission check used before a mutation is accepted. It is
    /// intentionally identical to append's size and recovery preconditions.
    pub fn preflight(self: Wal, payload_len: usize) !void {
        if (payload_len == 0 or payload_len > wal_codec.max_uncompressed_bytes) return error.RecordTooLarge;
        // Length-only callers receive a conservative raw admission. Runtime
        // uses preflightEncoded so compressible records are not rejected.
        var plan = try self.replay();
        defer plan.deinit();
        if (plan.truncated_tail_bytes != 0) return error.RecoveryRequired;
        const record_bytes = std.math.add(u64, record_header_len, payload_len) catch return error.RecordTooLarge;
        const next_size = std.math.add(u64, plan.valid_bytes, record_bytes) catch return error.RecordTooLarge;
        if (next_size > max_file_bytes) return error.CheckpointRequired;
    }

    pub fn preflightEncoded(self: Wal, encoded: EncodedPayload) !void {
        var plan = try self.replay();
        defer plan.deinit();
        if (plan.truncated_tail_bytes != 0) return error.RecoveryRequired;
        const next_size = std.math.add(u64, plan.valid_bytes, try encoded.framedBytes()) catch return error.RecordTooLarge;
        if (next_size > max_file_bytes) return error.CheckpointRequired;
    }

    /// Physical bytes of a replacement WAL containing either no records or
    /// one canonical mutation record.
    pub fn replacementBytes(stored_payload_len: ?usize) !u64 {
        const payload = stored_payload_len orelse return file_header_len;
        const framed = std.math.add(u64, record_header_len, payload) catch return error.RecordTooLarge;
        const total = std.math.add(u64, file_header_len, framed) catch return error.RecordTooLarge;
        if (total > max_file_bytes) return error.CheckpointRequired;
        return total;
    }

    /// Atomically replace an append-only WAL with an equivalent zero/one-frame
    /// WAL for the same immutable checkpoint generation. The replacement is
    /// fsynced before rename, so a crash observes either the complete old WAL
    /// or the complete new WAL. Callers must account the temporary alongside
    /// the old WAL before invoking this method.
    pub fn stageReplacement(self: Wal, payload: ?[]const u8) !StagedReplacement {
        var encoded: ?EncodedPayload = if (payload) |bytes|
            try encodePayloadAlloc(self.allocator, bytes)
        else
            null;
        defer if (encoded) |*value| value.deinit();
        return self.stageReplacementEncoded(encoded);
    }

    pub fn stageReplacementEncoded(self: Wal, encoded: ?EncodedPayload) !StagedReplacement {
        var previous = try self.replay();
        defer previous.deinit();
        if (previous.truncated_tail_bytes != 0) return error.RecoveryRequired;
        const replacement_bytes = try replacementBytes(if (encoded) |value| value.bytes.len else null);

        const temporary_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        errdefer self.allocator.free(temporary_path);
        const rollback_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.path, rollback_suffix });
        errdefer self.allocator.free(rollback_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};
        std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |other| return other,
        };

        var file_bytes: [file_header_len]u8 = undefined;
        encodeFileHeader(self.generation, &file_bytes);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, temporary_path, .{
                .read = true,
                .truncate = true,
                .exclusive = true,
            });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, &file_bytes, 0);
            if (encoded) |value| {
                var record_bytes: [record_header_len]u8 = undefined;
                encodeRecordHeader(self.generation, 1, .mutation, value, &record_bytes);
                try file.writePositionalAll(self.io, &record_bytes, file_header_len);
                try file.writePositionalAll(self.io, value.bytes, file_header_len + record_header_len);
            }
            if (self.durable) try file.sync(self.io);
        }
        const stat = try std.Io.Dir.cwd().statFile(self.io, temporary_path, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.size != replacement_bytes) return error.InvalidRecord;
        var staged_wal = Wal{
            .allocator = self.allocator,
            .io = self.io,
            .path = try self.allocator.dupe(u8, temporary_path),
            .generation = self.generation,
            .durable = self.durable,
        };
        defer staged_wal.deinit();
        var staged_replay = try staged_wal.replay();
        defer staged_replay.deinit();
        if (staged_replay.truncated_tail_bytes != 0 or staged_replay.valid_bytes != replacement_bytes) {
            return error.InvalidRecord;
        }
        return .{
            .wal = self,
            .temporary_path = temporary_path,
            .rollback_path = rollback_path,
            .replacement_bytes = replacement_bytes,
            .replacement_digest = try fileDigest(self.io, temporary_path, replacement_bytes),
        };
    }

    pub fn replaceWithMutation(self: Wal, payload: ?[]const u8) !void {
        var staged = try self.stageReplacement(payload);
        defer staged.deinit();
        try staged.commit();
        try staged.verifyCommitted();
        try std.Io.Dir.cwd().deleteFile(self.io, staged.rollback_path);
        try syncDirectory(
            self.io,
            std.fs.path.dirname(self.path) orelse ".",
            self.durable,
        );
    }

    pub fn replay(self: Wal) !ReplayPlan {
        var file = try std.Io.Dir.cwd().openFile(self.io, self.path, .{ .allow_directory = false });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size < file_header_len or stat.size > max_file_bytes) return error.InvalidRecord;
        const size = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const bytes = try self.allocator.alloc(u8, size);
        defer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.InvalidRecord;
        if (try decodeFileHeader(bytes[0..file_header_len]) != self.generation) return error.InvalidRecord;

        var records = std.ArrayList(Record).empty;
        errdefer {
            for (records.items) |record| self.allocator.free(record.payload);
            records.deinit(self.allocator);
        }
        var offset: usize = file_header_len;
        var expected_sequence: u64 = 1;
        while (offset < bytes.len) {
            const remaining = bytes.len - offset;
            if (remaining < record_header_len) break;
            const header = try decodeRecordHeader(bytes[offset .. offset + record_header_len]);
            if (header.generation != self.generation or header.sequence != expected_sequence) return error.InvalidRecord;
            const record_len = std.math.add(usize, record_header_len, header.payload_len) catch return error.RecordTooLarge;
            if (record_len > remaining) break;
            const stored_payload = bytes[offset + record_header_len .. offset + record_len];
            const observed_digest = if (header.version == version)
                legacyRecordDigest(header.generation, header.sequence, header.kind, stored_payload)
            else
                recordDigest(
                    header.generation,
                    header.sequence,
                    header.kind,
                    header.codec,
                    header.logical_payload_len,
                    stored_payload,
                );
            if (!std.mem.eql(u8, &observed_digest, &header.digest)) return error.DigestMismatch;
            const logical_payload = switch (header.codec) {
                .raw => blk: {
                    if (header.logical_payload_len != stored_payload.len) return error.InvalidRecord;
                    break :blk try self.allocator.dupe(u8, stored_payload);
                },
                .zstd => try wal_codec.decompressAlloc(
                    self.allocator,
                    stored_payload,
                    header.logical_payload_len,
                ),
            };
            errdefer self.allocator.free(logical_payload);
            try records.append(self.allocator, .{
                .sequence = header.sequence,
                .kind = header.kind,
                .payload = logical_payload,
            });
            offset += record_len;
            expected_sequence += 1;
        }
        return .{
            .allocator = self.allocator,
            .generation = self.generation,
            .records = try records.toOwnedSlice(self.allocator),
            .valid_bytes = @intCast(offset),
            .truncated_tail_bytes = @intCast(bytes.len - offset),
        };
    }

    /// Drop only an incomplete final frame. Corruption inside a complete frame
    /// is rejected by `replay` and is never silently truncated.
    pub fn recoverCrashTail(self: Wal) !u64 {
        var plan = try self.replay();
        defer plan.deinit();
        if (plan.truncated_tail_bytes == 0) return 0;
        var file = try std.Io.Dir.cwd().openFile(self.io, self.path, .{ .mode = .read_write, .allow_directory = false });
        defer file.close(self.io);
        try file.setLength(self.io, plan.valid_bytes);
        if (self.durable) try file.sync(self.io);
        return plan.truncated_tail_bytes;
    }
};

const DecodedRecordHeader = struct {
    version: u16,
    generation: u64,
    sequence: u64,
    kind: RecordKind,
    codec: PayloadCodec,
    payload_len: usize,
    logical_payload_len: usize,
    digest: [32]u8,
};

fn encodeFileHeader(generation: u64, out: *[file_header_len]u8) void {
    @memset(out, 0);
    @memcpy(out[0..8], file_magic);
    std.mem.writeInt(u16, out[8..10], version, .little);
    std.mem.writeInt(u16, out[10..12], file_header_len, .little);
    std.mem.writeInt(u32, out[12..16], max_file_bytes, .little);
    std.mem.writeInt(u64, out[16..24], generation, .little);
    @memcpy(out[32..64], &digest(out[0..32]));
}

fn decodeFileHeader(bytes: *const [file_header_len]u8) !u64 {
    if (!std.mem.eql(u8, bytes[0..8], file_magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[8..10], .little) != version) return error.UnsupportedVersion;
    if (std.mem.readInt(u16, bytes[10..12], .little) != file_header_len) return error.InvalidRecord;
    if (std.mem.readInt(u32, bytes[12..16], .little) != max_file_bytes) return error.InvalidRecord;
    for (bytes[24..32]) |byte| if (byte != 0) return error.InvalidRecord;
    if (!std.mem.eql(u8, &digest(bytes[0..32]), bytes[32..64])) return error.DigestMismatch;
    const generation = std.mem.readInt(u64, bytes[16..24], .little);
    if (generation == 0) return error.InvalidRecord;
    return generation;
}

fn encodeRecordHeader(
    generation: u64,
    sequence: u64,
    kind: RecordKind,
    payload: EncodedPayload,
    out: *[record_header_len]u8,
) void {
    @memset(out, 0);
    @memcpy(out[0..4], record_magic);
    std.mem.writeInt(u16, out[4..6], adaptive_record_version, .little);
    out[6] = @intFromEnum(kind);
    out[7] = @intFromEnum(payload.codec);
    std.mem.writeInt(u32, out[8..12], @intCast(payload.bytes.len), .little);
    std.mem.writeInt(u32, out[12..16], @intCast(payload.logical_bytes), .little);
    std.mem.writeInt(u64, out[16..24], sequence, .little);
    std.mem.writeInt(u64, out[24..32], generation, .little);
    @memcpy(out[32..64], &recordDigest(
        generation,
        sequence,
        kind,
        payload.codec,
        payload.logical_bytes,
        payload.bytes,
    ));
}

fn decodeRecordHeader(bytes: []const u8) !DecodedRecordHeader {
    if (bytes.len != record_header_len) return error.InvalidRecord;
    if (!std.mem.eql(u8, bytes[0..4], record_magic)) return error.InvalidRecord;
    const record_version = std.mem.readInt(u16, bytes[4..6], .little);
    if (record_version != version and record_version != adaptive_record_version) return error.UnsupportedVersion;
    const kind: RecordKind = switch (bytes[6]) {
        @intFromEnum(RecordKind.mutation) => .mutation,
        else => return error.InvalidRecord,
    };
    const payload_len = std.mem.readInt(u32, bytes[8..12], .little);
    const codec: PayloadCodec = if (record_version == version) blk: {
        if (bytes[7] != 0) return error.InvalidRecord;
        for (bytes[12..16]) |byte| if (byte != 0) return error.InvalidRecord;
        break :blk .raw;
    } else switch (bytes[7]) {
        @intFromEnum(PayloadCodec.raw) => .raw,
        @intFromEnum(PayloadCodec.zstd) => .zstd,
        else => return error.InvalidRecord,
    };
    const logical_payload_len: usize = if (record_version == version)
        payload_len
    else
        std.mem.readInt(u32, bytes[12..16], .little);
    if (payload_len == 0 or logical_payload_len == 0 or logical_payload_len > wal_codec.max_uncompressed_bytes) {
        return error.InvalidRecord;
    }
    if (codec == .zstd and payload_len >= logical_payload_len) return error.InvalidRecord;
    return .{
        .version = record_version,
        .generation = std.mem.readInt(u64, bytes[24..32], .little),
        .sequence = std.mem.readInt(u64, bytes[16..24], .little),
        .kind = kind,
        .codec = codec,
        .payload_len = payload_len,
        .logical_payload_len = logical_payload_len,
        .digest = bytes[32..64].*,
    };
}

fn recordDigest(
    generation: u64,
    sequence: u64,
    kind: RecordKind,
    codec: PayloadCodec,
    logical_payload_len: usize,
    payload: []const u8,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var fixed: [26]u8 = undefined;
    std.mem.writeInt(u64, fixed[0..8], generation, .little);
    std.mem.writeInt(u64, fixed[8..16], sequence, .little);
    fixed[16] = @intFromEnum(kind);
    fixed[17] = @intFromEnum(codec);
    std.mem.writeInt(u64, fixed[18..26], @intCast(logical_payload_len), .little);
    hash.update(&fixed);
    hash.update(payload);
    var out: [32]u8 = undefined;
    hash.final(&out);
    return out;
}

fn legacyRecordDigest(generation: u64, sequence: u64, kind: RecordKind, payload: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var fixed: [17]u8 = undefined;
    std.mem.writeInt(u64, fixed[0..8], generation, .little);
    std.mem.writeInt(u64, fixed[8..16], sequence, .little);
    fixed[16] = @intFromEnum(kind);
    hash.update(&fixed);
    hash.update(payload);
    var out: [32]u8 = undefined;
    hash.final(&out);
    return out;
}

fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

fn fileDigest(io: std.Io, path: []const u8, expected_bytes: u64) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected_bytes) return error.InvalidRecord;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < expected_bytes) {
        const remaining = expected_bytes - offset;
        const want: usize = @intCast(@min(remaining, buffer.len));
        if (try file.readPositionalAll(io, buffer[0..want], offset) != want) return error.InvalidRecord;
        hash.update(buffer[0..want]);
        offset += want;
    }
    var out: [32]u8 = undefined;
    hash.final(&out);
    return out;
}

pub fn parseGenerationLeaf(leaf: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, leaf, wal_prefix)) return null;
    const raw = leaf[wal_prefix.len..];
    if (raw.len == 0) return null;
    for (raw) |byte| if (byte < '0' or byte > '9') return null;
    const generation = std.fmt.parseUnsigned(u64, raw, 10) catch return null;
    return if (generation == 0) null else generation;
}

fn generationPath(allocator: std.mem.Allocator, directory: []const u8, generation: u64) ![]u8 {
    if (generation == 0) return error.InvalidRecord;
    const leaf = try std.fmt.allocPrint(allocator, "{s}{d}", .{ wal_prefix, generation });
    defer allocator.free(leaf);
    return std.fs.path.join(allocator, &.{ directory, leaf });
}

fn rename(io: std.Io, source: []const u8, destination: []const u8) !void {
    if (std.fs.path.isAbsolute(destination)) {
        try std.Io.Dir.renameAbsolute(source, destination, io);
    } else {
        try std.Io.Dir.rename(.cwd(), source, .cwd(), destination, io);
    }
}

fn syncDirectory(io: std.Io, directory: []const u8, durable: bool) !void {
    if (!durable or @import("builtin").os.tag == .windows) return;
    var file = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openFileAbsolute(io, directory, .{ .allow_directory = true })
    else
        try std.Io.Dir.cwd().openFile(io, directory, .{ .allow_directory = true });
    defer file.close(io);
    try file.sync(io);
}

test "checkpoint WAL replays transactions and fails preflight without growth" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var wal = try Wal.createGeneration(std.testing.allocator, std.testing.io, path_buffer[0..root_len], 7, false);
    defer wal.deinit();
    try std.testing.expectEqual(@as(u64, 1), try wal.append(.mutation, "first"));
    try std.testing.expectEqual(@as(u64, 2), try wal.append(.mutation, "second"));
    var replay = try wal.replay();
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 2), replay.records.len);
    try std.testing.expectEqualStrings("second", replay.records[1].payload);
    const before = replay.valid_bytes;
    const too_large = try std.testing.allocator.alloc(u8, max_file_bytes);
    defer std.testing.allocator.free(too_large);
    var random = std.Random.DefaultPrng.init(0x544b_4757_414c_5632);
    random.fill(too_large);
    try std.testing.expectError(error.CheckpointRequired, wal.append(.mutation, too_large));
    var after = try wal.replay();
    defer after.deinit();
    try std.testing.expectEqual(before, after.valid_bytes);
}

test "checkpoint WAL v2 adaptively compresses and falls back to raw" {
    const allocator = std.testing.allocator;
    var raw = try encodePayloadAlloc(allocator, "small");
    defer raw.deinit();
    try std.testing.expectEqual(PayloadCodec.raw, raw.codec);
    try std.testing.expectEqual(@as(usize, 5), raw.logical_bytes);
    try std.testing.expectEqualStrings("small", raw.bytes);

    const logical = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(logical);
    const pattern = "owner=11965 status=claimed relation=verified_by\n";
    for (logical, 0..) |*byte, index| byte.* = pattern[index % pattern.len];
    var compressed = try encodePayloadAlloc(allocator, logical);
    defer compressed.deinit();
    try std.testing.expectEqual(PayloadCodec.zstd, compressed.codec);
    try std.testing.expectEqual(logical.len, compressed.logical_bytes);
    try std.testing.expect(compressed.bytes.len < logical.len / 8);
}

test "checkpoint WAL reads legacy v1 records as logical raw payloads" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var wal = try Wal.createGeneration(std.testing.allocator, std.testing.io, path_buffer[0..root_len], 12, false);
    defer wal.deinit();

    const payload = "legacy-v1-canonical-mutation";
    var header: [record_header_len]u8 = undefined;
    @memset(&header, 0);
    @memcpy(header[0..4], record_magic);
    std.mem.writeInt(u16, header[4..6], version, .little);
    header[6] = @intFromEnum(RecordKind.mutation);
    std.mem.writeInt(u32, header[8..12], payload.len, .little);
    std.mem.writeInt(u64, header[16..24], 1, .little);
    std.mem.writeInt(u64, header[24..32], 12, .little);
    @memcpy(header[32..64], &legacyRecordDigest(12, 1, .mutation, payload));
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, wal.path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &header, file_header_len);
    try file.writePositionalAll(std.testing.io, payload, file_header_len + record_header_len);

    var replay = try wal.replay();
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay.records.len);
    try std.testing.expectEqualStrings(payload, replay.records[0].payload);
}

test "checkpoint WAL v2 caps logical length and binds it into the digest" {
    const allocator = std.testing.allocator;
    const oversized = try allocator.alloc(u8, wal_codec.max_uncompressed_bytes + 1);
    defer allocator.free(oversized);
    try std.testing.expectError(error.RecordTooLarge, encodePayloadAlloc(allocator, oversized));

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var wal = try Wal.createGeneration(allocator, std.testing.io, path_buffer[0..root_len], 13, false);
    defer wal.deinit();
    const logical = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(logical);
    @memset(logical, 'x');
    _ = try wal.append(.mutation, logical);

    // Changing only the declared logical length must invalidate the complete
    // frame because v2 binds codec and logical length into its digest.
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, wal.path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    var logical_length: [4]u8 = undefined;
    if (try file.readPositionalAll(std.testing.io, &logical_length, file_header_len + 12) != logical_length.len) {
        return error.InvalidRecord;
    }
    const changed = std.mem.readInt(u32, &logical_length, .little) + 1;
    std.mem.writeInt(u32, &logical_length, changed, .little);
    try file.writePositionalAll(std.testing.io, &logical_length, file_header_len + 12);
    try std.testing.expectError(error.DigestMismatch, wal.replay());

    var oversized_header: [record_header_len]u8 = undefined;
    @memset(&oversized_header, 0);
    @memcpy(oversized_header[0..4], record_magic);
    std.mem.writeInt(u16, oversized_header[4..6], adaptive_record_version, .little);
    oversized_header[6] = @intFromEnum(RecordKind.mutation);
    oversized_header[7] = @intFromEnum(PayloadCodec.zstd);
    std.mem.writeInt(u32, oversized_header[8..12], 1, .little);
    std.mem.writeInt(u32, oversized_header[12..16], wal_codec.max_uncompressed_bytes + 1, .little);
    try std.testing.expectError(error.InvalidRecord, decodeRecordHeader(&oversized_header));
}

test "checkpoint WAL truncates only an incomplete crash tail" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var wal = try Wal.createGeneration(std.testing.allocator, std.testing.io, path_buffer[0..root_len], 3, false);
    defer wal.deinit();
    _ = try wal.append(.mutation, "committed");
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, wal.path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try file.writePositionalAll(std.testing.io, "REC1-partial", stat.size);
    var before = try wal.replay();
    try std.testing.expectEqual(@as(u64, 12), before.truncated_tail_bytes);
    before.deinit();
    try std.testing.expectEqual(@as(u64, 12), try wal.recoverCrashTail());
    var after = try wal.replay();
    defer after.deinit();
    try std.testing.expectEqual(@as(u64, 0), after.truncated_tail_bytes);
    try std.testing.expectEqual(@as(usize, 1), after.records.len);
}

test "checkpoint WAL atomically replaces many records with one equivalent frame" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var wal = try Wal.createGeneration(std.testing.allocator, std.testing.io, path_buffer[0..root_len], 9, false);
    defer wal.deinit();
    _ = try wal.append(.mutation, "first");
    _ = try wal.append(.mutation, "second");
    var staged = try wal.stageReplacement("collapsed");
    defer staged.deinit();
    try std.testing.expectEqual(try Wal.replacementBytes("collapsed".len), staged.replacement_bytes);
    var before_commit = try wal.replay();
    try std.testing.expectEqual(@as(usize, 2), before_commit.records.len);
    before_commit.deinit();
    try staged.commit();
    try std.testing.expect((try std.Io.Dir.cwd().statFile(std.testing.io, staged.rollback_path, .{})).kind == .file);
    var replay = try wal.replay();
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay.records.len);
    try std.testing.expectEqualStrings("collapsed", replay.records[0].payload);
    try std.testing.expectEqual(try Wal.replacementBytes("collapsed".len), replay.valid_bytes);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, staged.rollback_path);
    try wal.replaceWithMutation(null);
    var empty = try wal.replay();
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);
    try std.testing.expectEqual(@as(u64, file_header_len), empty.valid_bytes);
}

test "checkpoint WAL recovers the old file from the replacement rename gap" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var wal = try Wal.createGeneration(std.testing.allocator, std.testing.io, root, 10, false);
    _ = try wal.append(.mutation, "stable-old");
    const rollback_path = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ wal.path, rollback_suffix });
    defer std.testing.allocator.free(rollback_path);
    try rename(std.testing.io, wal.path, rollback_path);
    wal.deinit();

    var recovered = try Wal.openGeneration(std.testing.allocator, std.testing.io, root, 10, false);
    defer recovered.deinit();
    var replay = try recovered.replay();
    defer replay.deinit();
    try std.testing.expectEqual(@as(usize, 1), replay.records.len);
    try std.testing.expectEqualStrings("stable-old", replay.records[0].payload);
}
