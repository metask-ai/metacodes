//! Session-scoped, content-addressed storage for model-visible tool results.
//!
//! This is deliberately separate from `formal/artifact_store.zig`: formal
//! bundles are research/governance evidence, while this store is a recoverable
//! context projection owned by one Conversation/transcript lifetime.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const sync = @import("platform").sync;
const util_fs = @import("../util/fs.zig");

// A Session can have parallel tool workers, subagents, and in-process swarm
// teammates. Serialize quota-check + publish in this process so each writer
// observes every prior committed artifact before authorizing another one.
var persist_mutex: sync.Mutex = .{};

pub const ID_PREFIX = "sha256:";
pub const ID_HEX_BYTES: usize = 64;
pub const ID_BYTES: usize = ID_PREFIX.len + ID_HEX_BYTES;
pub const MAX_ARTIFACT_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_SESSION_BYTES: u64 = 1024 * 1024 * 1024;
pub const MAX_READ_BYTES: usize = 32 * 1024;

pub const Receipt = struct {
    artifact_id: [ID_BYTES]u8,
    sha256: [ID_HEX_BYTES]u8,
    bytes: u64,
    capture_complete: bool = true,

    pub fn id(self: *const Receipt) []const u8 {
        return self.artifact_id[0..];
    }
};

pub const Chunk = struct {
    bytes: []u8,
    offset: u64,
    total_bytes: u64,
    next_offset: ?u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Chunk) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const FileSnapshot = struct {
    sha256: [ID_HEX_BYTES]u8,
    bytes: u64,
};

pub fn persist(allocator: std.mem.Allocator, session_root: []const u8, bytes: []const u8) !Receipt {
    if (session_root.len == 0) return error.ArtifactRootUnavailable;
    if (bytes.len > MAX_ARTIFACT_BYTES) return error.ArtifactTooLarge;
    const digest = sha256Hex(bytes);
    var artifact_id: [ID_BYTES]u8 = undefined;
    @memcpy(artifact_id[0..ID_PREFIX.len], ID_PREFIX);
    @memcpy(artifact_id[ID_PREFIX.len..], digest[0..]);

    const directory = try artifactDirectory(allocator, session_root);
    defer allocator.free(directory);
    try ensureSecureDirectory(allocator, session_root, directory);

    persist_mutex.lock();
    defer persist_mutex.unlock();

    const final_path = try artifactPath(allocator, directory, digest);
    defer allocator.free(final_path);
    if (try verifyExisting(allocator, final_path, digest, bytes.len)) {
        return .{ .artifact_id = artifact_id, .sha256 = digest, .bytes = bytes.len };
    }

    const used = try directoryBytes(allocator, directory);
    if (@as(u64, @intCast(bytes.len)) > MAX_SESSION_BYTES -| used)
        return error.SessionQuotaExceeded;

    var nonce: [8]u8 = undefined;
    if (!@import("platform").rng.randomBytes(&nonce)) return error.RandomFailed;
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.{s}.{s}.tmp",
        .{ directory, digest[0..], nonce_hex[0..] },
    );
    defer allocator.free(temp_path);
    const temp_z = try allocator.dupeZ(u8, temp_path);
    defer allocator.free(temp_z);
    errdefer pfs.unlinkPath(temp_z.ptr) catch {};

    {
        const fd = pfs.open(temp_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
        }, 0o600);
        if (fd < 0) return error.ArtifactTempOpenFailed;
        defer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);
        const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
        if (!info.is_regular or info.link_count != 1 or (builtin.os.tag != .windows and (info.mode & 0o077) != 0))
            return error.ArtifactUnsafeFile;
        try writeAll(fd, bytes);
        try pfs.fsyncChecked(fd);
    }

    const final_z = try allocator.dupeZ(u8, final_path);
    defer allocator.free(final_z);
    if (pfs.renameReplace(temp_z.ptr, final_z.ptr) != 0) return error.ArtifactPublishFailed;
    try fsyncDirectory(allocator, directory);
    if (!(try verifyExisting(allocator, final_path, digest, bytes.len)))
        return error.ArtifactPublishVerificationFailed;
    return .{ .artifact_id = artifact_id, .sha256 = digest, .bytes = bytes.len };
}

/// Import a private regular file into the same content-addressed namespace.
/// The source is hashed before authorization and again while copying; a
/// concurrent source mutation therefore fails closed rather than publishing a
/// receipt for different bytes. This is the byte-0 spool path used by Bash.
pub fn persistFile(allocator: std.mem.Allocator, session_root: []const u8, source_path: []const u8) !Receipt {
    if (session_root.len == 0) return error.ArtifactRootUnavailable;
    const expected = try inspectFile(allocator, source_path);
    return persistInspectedFile(allocator, session_root, source_path, expected);
}

/// Persist a source whose exact size/digest was already observed by
/// `inspectFile`. The copy is hashed again and compared with the snapshot, so
/// this avoids a redundant pre-copy hash without weakening source-CAS.
pub fn persistInspectedFile(
    allocator: std.mem.Allocator,
    session_root: []const u8,
    source_path: []const u8,
    expected: FileSnapshot,
) !Receipt {
    if (session_root.len == 0) return error.ArtifactRootUnavailable;
    if (expected.bytes > MAX_ARTIFACT_BYTES) return error.ArtifactTooLarge;
    const directory = try artifactDirectory(allocator, session_root);
    defer allocator.free(directory);
    try ensureSecureDirectory(allocator, session_root, directory);

    persist_mutex.lock();
    defer persist_mutex.unlock();

    const final_path = try artifactPath(allocator, directory, expected.sha256);
    defer allocator.free(final_path);
    if (try verifyExisting(allocator, final_path, expected.sha256, @intCast(expected.bytes)))
        return receiptFor(expected);
    const used = try directoryBytes(allocator, directory);
    if (expected.bytes > MAX_SESSION_BYTES -| used) return error.SessionQuotaExceeded;

    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const source_fd = pfs.open(source_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (source_fd < 0) return error.ArtifactSourceOpenFailed;
    defer _ = pfs.close(source_fd);
    const source_before = pfs.fileInfo(source_fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(source_before) or source_before.size != expected.bytes)
        return error.ArtifactSourceChanged;

    var nonce: [8]u8 = undefined;
    if (!@import("platform").rng.randomBytes(&nonce)) return error.RandomFailed;
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/.import.{s}.tmp", .{ directory, nonce_hex[0..] });
    defer allocator.free(temp_path);
    const temp_z = try allocator.dupeZ(u8, temp_path);
    defer allocator.free(temp_z);
    errdefer pfs.unlinkPath(temp_z.ptr) catch {};

    const temp_fd = pfs.open(temp_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    if (temp_fd < 0) return error.ArtifactTempOpenFailed;
    var temp_open = true;
    defer {
        if (temp_open) _ = pfs.close(temp_fd);
    }
    try pfs.makeCloseOnExec(temp_fd);
    const temp_info = pfs.fileInfo(temp_fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(temp_info)) return error.ArtifactUnsafeFile;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var copied: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(source_fd, &buffer) catch return error.ArtifactReadFailed;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        try writeAll(temp_fd, buffer[0..count]);
        copied +|= count;
    }
    const source_after = pfs.fileInfo(source_fd) catch return error.ArtifactSourceChanged;
    if (!sameFile(source_before, source_after) or copied != expected.bytes)
        return error.ArtifactSourceChanged;
    var digest_bytes: [32]u8 = undefined;
    hasher.final(&digest_bytes);
    const copied_digest = std.fmt.bytesToHex(digest_bytes, .lower);
    if (!std.mem.eql(u8, copied_digest[0..], expected.sha256[0..]))
        return error.ArtifactSourceChanged;
    try pfs.fsyncChecked(temp_fd);
    _ = pfs.close(temp_fd);
    temp_open = false;

    const final_z = try allocator.dupeZ(u8, final_path);
    defer allocator.free(final_z);
    if (pfs.renameReplace(temp_z.ptr, final_z.ptr) != 0) return error.ArtifactPublishFailed;
    try fsyncDirectory(allocator, directory);
    if (!(try verifyExisting(allocator, final_path, expected.sha256, @intCast(expected.bytes))))
        return error.ArtifactPublishVerificationFailed;
    return receiptFor(expected);
}

pub fn inspectFile(allocator: std.mem.Allocator, source_path: []const u8) !FileSnapshot {
    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const fd = pfs.open(source_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactSourceOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(before)) return error.ArtifactUnsafeFile;
    if (before.size > MAX_ARTIFACT_BYTES) return error.ArtifactTooLarge;
    const digest = try hashFd(fd);
    const after = pfs.fileInfo(fd) catch return error.ArtifactSourceChanged;
    if (!sameFile(before, after)) return error.ArtifactSourceChanged;
    return .{ .sha256 = digest, .bytes = before.size };
}

/// Observe the size of a private regular spool without applying the artifact
/// size limit or hashing it. This lets a rejected over-limit Bash capture be
/// reported honestly while keeping it explicitly incomplete and uncommitted.
pub fn observeFileBytes(allocator: std.mem.Allocator, source_path: []const u8) !u64 {
    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const fd = pfs.open(source_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactSourceOpenFailed;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
    return info.size;
}

fn receiptFor(snapshot: FileSnapshot) Receipt {
    var artifact_id: [ID_BYTES]u8 = undefined;
    @memcpy(artifact_id[0..ID_PREFIX.len], ID_PREFIX);
    @memcpy(artifact_id[ID_PREFIX.len..], snapshot.sha256[0..]);
    return .{ .artifact_id = artifact_id, .sha256 = snapshot.sha256, .bytes = snapshot.bytes };
}

pub fn readChunk(
    allocator: std.mem.Allocator,
    session_root: []const u8,
    artifact_id: []const u8,
    offset: u64,
    limit: usize,
) !Chunk {
    if (session_root.len == 0) return error.ArtifactRootUnavailable;
    if (limit == 0 or limit > MAX_READ_BYTES) return error.InvalidReadLimit;
    const digest = parseArtifactId(artifact_id) orelse return error.InvalidArtifactId;
    const directory = try artifactDirectory(allocator, session_root);
    defer allocator.free(directory);
    try validateSecureDirectory(allocator, session_root, directory);
    const path = try artifactPath(allocator, directory, digest);
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactNotFound;
    defer _ = pfs.close(fd);
    try pfs.makeCloseOnExec(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(before)) return error.ArtifactUnsafeFile;
    if (before.size > MAX_ARTIFACT_BYTES) return error.ArtifactTooLarge;
    if (offset > before.size) return error.InvalidReadOffset;

    const wanted: usize = @intCast(@min(@as(u64, limit), before.size - offset));
    const out = try allocator.alloc(u8, wanted);
    errdefer allocator.free(out);
    const actual = try hashAndReadChunk(fd, offset, out, before.size);
    if (!std.mem.eql(u8, actual[0..], digest[0..])) return error.ArtifactHashMismatch;
    const after = pfs.fileInfo(fd) catch return error.ArtifactChangedDuringRead;
    if (!sameFile(before, after)) return error.ArtifactChangedDuringRead;
    const next = offset + out.len;
    return .{
        .bytes = out,
        .offset = offset,
        .total_bytes = before.size,
        .next_offset = if (next < before.size) next else null,
        .allocator = allocator,
    };
}

fn hashAndReadChunk(fd: pfs.Fd, offset: u64, out: []u8, expected_bytes: u64) ![ID_HEX_BYTES]u8 {
    if (pfs.lseek(fd, 0, .set) < 0) return error.ArtifactSeekFailed;
    const chunk_end = offset + out.len;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var cursor: u64 = 0;
    var copied: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(fd, &buffer) catch return error.ArtifactReadFailed;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        const block_end = cursor + count;
        const overlap_start = @max(cursor, offset);
        const overlap_end = @min(block_end, chunk_end);
        if (overlap_start < overlap_end) {
            const source_start: usize = @intCast(overlap_start - cursor);
            const copy_len: usize = @intCast(overlap_end - overlap_start);
            @memcpy(out[copied .. copied + copy_len], buffer[source_start .. source_start + copy_len]);
            copied += copy_len;
        }
        cursor = block_end;
    }
    if (cursor != expected_bytes or copied != out.len) return error.ArtifactChangedDuringRead;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn sha256Hex(bytes: []const u8) [ID_HEX_BYTES]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn artifactDirectory(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/tool-results/sha256", .{root});
}

fn artifactPath(allocator: std.mem.Allocator, directory: []const u8, digest: [ID_HEX_BYTES]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.blob", .{ directory, digest[0..] });
}

fn ensureSecureDirectory(allocator: std.mem.Allocator, root: []const u8, directory: []const u8) !void {
    try rejectSymlink(allocator, root);
    try util_fs.mkdirParents(directory);
    try validateSecureDirectory(allocator, root, directory);
}

fn validateSecureDirectory(allocator: std.mem.Allocator, root: []const u8, directory: []const u8) !void {
    try rejectSymlink(allocator, root);
    const tool_results = try std.fmt.allocPrint(allocator, "{s}/tool-results", .{root});
    defer allocator.free(tool_results);
    try rejectSymlink(allocator, tool_results);
    try rejectSymlink(allocator, directory);
    if (builtin.os.tag != .windows) {
        try requireTrustedDirectory(allocator, root);
        try requirePrivateDirectory(allocator, tool_results);
        try requirePrivateDirectory(allocator, directory);
    }
}

fn requireTrustedDirectory(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const mode = pfs.statMode(path_z.ptr, false) orelse return error.ArtifactDirectoryStatFailed;
    if ((mode & 0o170000) != 0o040000 or (mode & 0o022) != 0)
        return error.ArtifactDirectoryUnsafe;
}

fn rejectSymlink(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (pfs.isSymlink(path_z.ptr)) return error.ArtifactPathSymlink;
}

fn requirePrivateDirectory(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const mode = pfs.statMode(path_z.ptr, false) orelse return error.ArtifactDirectoryStatFailed;
    if ((mode & 0o170000) != 0o040000 or (mode & 0o077) != 0)
        return error.ArtifactDirectoryUnsafe;
}

fn directoryBytes(allocator: std.mem.Allocator, directory: []const u8) !u64 {
    const directory_z = try allocator.dupeZ(u8, directory);
    defer allocator.free(directory_z);
    var iterator = pdir.open(directory_z.ptr) orelse return error.ArtifactDirectoryOpenFailed;
    defer pdir.close(&iterator);
    var total: u64 = 0;
    while (pdir.next(&iterator)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, entry.name });
        defer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
        if (fd < 0) return error.ArtifactDirectoryUntrusted;
        defer _ = pfs.close(fd);
        const info = pfs.fileInfo(fd) catch return error.ArtifactDirectoryUntrusted;
        if (!info.is_regular or info.link_count != 1) return error.ArtifactDirectoryUntrusted;
        total +|= info.size;
    }
    return total;
}

fn verifyExisting(allocator: std.mem.Allocator, path: []const u8, digest: [ID_HEX_BYTES]u8, expected_bytes: usize) !bool {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (!pfs.exists(path_z.ptr)) return false;
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactExistingOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(before) or before.size != expected_bytes) return error.ArtifactExistingMismatch;
    const actual = try hashFd(fd);
    const after = pfs.fileInfo(fd) catch return error.ArtifactChangedDuringRead;
    if (!sameFile(before, after)) return error.ArtifactChangedDuringRead;
    if (!std.mem.eql(u8, actual[0..], digest[0..])) return error.ArtifactExistingMismatch;
    return true;
}

fn safeArtifactInfo(info: pfs.FileInfo) bool {
    return info.is_regular and info.link_count == 1 and
        (builtin.os.tag == .windows or (info.mode & 0o077) == 0);
}

fn sameFile(before: pfs.FileInfo, after: pfs.FileInfo) bool {
    return safeArtifactInfo(after) and before.size == after.size and
        before.device == after.device and before.inode == after.inode;
}

fn hashFd(fd: pfs.Fd) ![ID_HEX_BYTES]u8 {
    if (pfs.lseek(fd, 0, .set) < 0) return error.ArtifactSeekFailed;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(fd, &buffer) catch return error.ArtifactReadFailed;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactWriteFailed;
        const written: usize = @intCast(count);
        if (written > bytes.len - offset) return error.ArtifactWriteFailed;
        offset += written;
    }
}

fn fsyncDirectory(allocator: std.mem.Allocator, directory: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const path_z = try allocator.dupeZ(u8, directory);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactDirectoryOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.fsyncChecked(fd);
}

fn parseArtifactId(raw: []const u8) ?[ID_HEX_BYTES]u8 {
    if (raw.len != ID_BYTES or !std.mem.startsWith(u8, raw, ID_PREFIX)) return null;
    var out: [ID_HEX_BYTES]u8 = undefined;
    for (raw[ID_PREFIX.len..], 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        out[index] = byte;
    }
    return out;
}

test "content-addressed artifact persists, deduplicates, and pages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const payload = "alpha-中文-omega";
    const first = try persist(allocator, root, payload);
    const second = try persist(allocator, root, payload);
    try std.testing.expectEqualStrings(first.id(), second.id());
    try std.testing.expectEqual(@as(u64, payload.len), first.bytes);
    var chunk = try readChunk(allocator, root, first.id(), 6, 6);
    defer chunk.deinit();
    try std.testing.expectEqualStrings(payload[6..12], chunk.bytes);
    try std.testing.expectEqual(@as(?u64, 12), chunk.next_offset);
}

test "file import hashes and preserves the complete byte-zero spool" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const source = try std.fmt.allocPrintSentinel(allocator, "{s}/source.log", .{root}, 0);
    defer allocator.free(source);
    const fd = pfs.open(source.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    if (fd < 0) return error.ArtifactTempOpenFailed;
    const prefix = [_]u8{'p'} ** (80 * 1024);
    try writeAll(fd, &prefix);
    try writeAll(fd, "FILE_TAIL_SENTINEL");
    try pfs.fsyncChecked(fd);
    _ = pfs.close(fd);

    const receipt = try persistFile(allocator, root, source);
    try std.testing.expectEqual(@as(u64, prefix.len + "FILE_TAIL_SENTINEL".len), receipt.bytes);
    var tail = try readChunk(allocator, root, receipt.id(), receipt.bytes - 32, 32);
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "FILE_TAIL_SENTINEL") != null);
}

test "artifact reader rejects traversal, hardlinks, and tampering" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    try std.testing.expectError(error.InvalidArtifactId, readChunk(allocator, root, "sha256:../x", 0, 1));
    const receipt = try persist(allocator, root, "trusted");
    const directory = try artifactDirectory(allocator, root);
    defer allocator.free(directory);
    const path = try artifactPath(allocator, directory, receipt.sha256);
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const link = try std.fmt.allocPrintSentinel(allocator, "{s}.link", .{path}, 0);
    defer allocator.free(link);
    if (std.c.link(path_z.ptr, link.ptr) != 0) return error.SkipZigTest;
    try std.testing.expectError(error.ArtifactUnsafeFile, readChunk(allocator, root, receipt.id(), 0, 4));
    try pfs.unlinkPath(link.ptr);

    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.SkipZigTest;
    try writeAll(fd, "altered"); // same length as "trusted": hash, not size, detects it
    _ = pfs.close(fd);
    try std.testing.expectError(error.ArtifactHashMismatch, readChunk(allocator, root, receipt.id(), 0, 4));
}

test "artifact reader rejects unsafe roots and invalid ranges" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const receipt = try persist(allocator, root, "bounded");
    try std.testing.expectError(error.InvalidReadLimit, readChunk(allocator, root, receipt.id(), 0, 0));
    try std.testing.expectError(error.InvalidReadLimit, readChunk(allocator, root, receipt.id(), 0, MAX_READ_BYTES + 1));
    try std.testing.expectError(error.InvalidReadOffset, readChunk(allocator, root, receipt.id(), receipt.bytes + 1, 1));

    const link_root = try std.fmt.allocPrintSentinel(allocator, "{s}.symlink", .{root}, 0);
    defer allocator.free(link_root);
    const root_z = try allocator.dupeZ(u8, root);
    defer allocator.free(root_z);
    if (std.c.symlink(root_z.ptr, link_root.ptr) != 0) return error.SkipZigTest;
    defer pfs.unlinkPath(link_root.ptr) catch {};
    try std.testing.expectError(error.ArtifactPathSymlink, readChunk(allocator, link_root, receipt.id(), 0, 1));
}
