//! Immutable per-event evidence bundles for formal-control research data.
//!
//! The bundle is authoritative: every artifact is created with O_EXCL and a
//! hash manifest is written last. A directory without a fully parseable and
//! hash-valid `manifest.json` is an interrupted negative trace, never a
//! completed event. The adjacent JSONL
//! file is only a bounded discovery index; it may be rebuilt by scanning
//! manifests and is deliberately not part of the checker admission decision.

const std = @import("std");
const pfs = @import("platform").fs;
const process = @import("platform").process;
const util_fs = @import("../util/fs.zig");
const log = @import("../util/log.zig");
const time = @import("../util/time.zig");

pub const BUNDLE_SCHEMA = "metacodes-formal-artifact-bundle-v1";
pub const INDEX_SCHEMA = "metacodes-formal-event-index-v1";
pub const ARTIFACT_DIR_NAME = "artifacts-v1";
const MAX_INDEX_BYTES: u64 = 512 * 1024 * 1024;
const MAX_INDEX_LINE_BYTES: usize = 4096;
const MAX_ARTIFACT_BYTES: usize = 8 * 1024 * 1024;
const MAX_FILES: usize = 10;

var event_counter = std.atomic.Value(u64).init(0);

pub const Artifacts = struct {
    snapshot_source: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    proposal: ?[]const u8 = null,
    request: ?[]const u8 = null,
    verdict: ?[]const u8 = null,
    checker_stdout: ?[]const u8 = null,
    checker_stderr: ?[]const u8 = null,
    checker_provenance: ?[]const u8 = null,
    checker_build_receipt: ?[]const u8 = null,
};

pub const IndexMetadata = struct {
    started_wall_ns: i128,
    request_id: ?[]const u8,
    snapshot_revision: ?[]const u8,
    pipeline_admitted: bool,
    failure_kind: []const u8,
};

pub const PersistResult = struct {
    manifest_sha256: [64]u8,
    receipt_sha256: [64]u8,
    index_persisted: bool,
};

pub const VerifiedBundle = struct {
    event_id: [64]u8,
    manifest_sha256: [64]u8,
    receipt_sha256: [64]u8,
    files_verified: usize,
};

const FileRecord = struct {
    name: []const u8,
    bytes: usize,
    sha256: [64]u8,
};

const ManifestFile = struct {
    name: []const u8,
    bytes: usize,
    sha256: []const u8,
};

const Manifest = struct {
    schema_version: []const u8,
    event_id: []const u8,
    completion_marker: bool,
    write_policy: []const u8,
    durability: []const u8,
    integrity_model: []const u8,
    storage_threat_model: []const u8,
    pre_manifest_persistence_elapsed_ns: u64,
    persistence_latency_boundary: []const u8,
    files: []ManifestFile,
};

/// Unique event identity, not a content identity. Re-running an unchanged
/// request therefore produces a second trajectory sample instead of
/// overwriting the first. The request id remains separately queryable.
pub fn newEventId(
    started_wall_ns: i128,
    started_monotonic_ns: i128,
    request_id: ?[]const u8,
) [64]u8 {
    const sequence = event_counter.fetchAdd(1, .monotonic);
    var seed: [160]u8 = undefined;
    const encoded = std.fmt.bufPrint(&seed, "formal-event-v1|{d}|{d}|{d}|{d}|", .{
        started_wall_ns,
        started_monotonic_ns,
        process.currentPid(),
        sequence,
    }) catch unreachable;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(encoded);
    if (request_id) |id| hash.update(id);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Persist one complete immutable bundle. `manifest.json` is the completion
/// marker and is written only after every payload file has been flushed.
/// JSONL index failure is reported but does not invalidate the authoritative
/// bundle; callers can rebuild the cache by scanning manifests.
pub fn persist(
    allocator: std.mem.Allocator,
    index_path: []const u8,
    event_id: [64]u8,
    receipt: []const u8,
    artifacts: Artifacts,
    metadata: IndexMetadata,
) !PersistResult {
    const persistence_started = time.nowNs();
    if (!std.fs.path.isAbsolute(index_path) or receipt.len == 0 or
        receipt.len > MAX_ARTIFACT_BYTES)
        return error.InvalidArtifactTarget;

    const parent = std.fs.path.dirname(index_path) orelse return error.InvalidArtifactTarget;
    const artifact_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, ARTIFACT_DIR_NAME });
    defer allocator.free(artifact_root);
    try util_fs.mkdirParents(artifact_root);
    try rejectSymlink(allocator, artifact_root);

    const event_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ artifact_root, event_id[0..] });
    defer allocator.free(event_dir);
    try createExclusiveDirectory(allocator, event_dir);

    var records: std.ArrayList(FileRecord) = .empty;
    defer records.deinit(allocator);
    try maybeWrite(allocator, event_dir, &records, "snapshot-source.bin", artifacts.snapshot_source);
    try maybeWrite(allocator, event_dir, &records, "snapshot.json", artifacts.snapshot);
    try maybeWrite(allocator, event_dir, &records, "proposal.json", artifacts.proposal);
    try maybeWrite(allocator, event_dir, &records, "request.json", artifacts.request);
    try maybeWrite(allocator, event_dir, &records, "verdict.json", artifacts.verdict);
    try maybeWrite(allocator, event_dir, &records, "checker-stdout.bin", artifacts.checker_stdout);
    try maybeWrite(allocator, event_dir, &records, "checker-stderr.bin", artifacts.checker_stderr);
    try maybeWrite(allocator, event_dir, &records, "checker-provenance.json", artifacts.checker_provenance);
    try maybeWrite(allocator, event_dir, &records, "checker-build-receipt.json", artifacts.checker_build_receipt);
    try writeArtifact(allocator, event_dir, &records, "receipt.json", receipt);

    const pre_manifest_persistence_elapsed_ns = elapsedSince(persistence_started);
    const manifest = try renderManifest(
        allocator,
        event_id,
        records.items,
        pre_manifest_persistence_elapsed_ns,
    );
    defer allocator.free(manifest);
    // Completion marker: readers must parse it and verify every listed hash;
    // mere filename existence is insufficient after a crash/short write.
    try writeExclusiveFile(allocator, event_dir, "manifest.json", manifest);

    const receipt_sha256 = sha256Hex(receipt);
    const manifest_sha256 = sha256Hex(manifest);
    // Nothing after manifest publication may turn the authoritative bundle
    // into a failed admission. Index rendering/appending is a rebuildable
    // cache and therefore fully best-effort, including allocator pressure.
    const index_persisted = if (renderIndex(
        allocator,
        event_id,
        receipt_sha256,
        manifest_sha256,
        metadata,
    )) |index_line| blk: {
        defer allocator.free(index_line);
        break :blk appendIndex(allocator, index_path, index_line) catch |err| {
            log.warn("formal", "artifact bundle {s} persisted but discovery index append failed: {s}", .{
                event_id[0..],
                @errorName(err),
            });
            break :blk false;
        };
    } else |err| blk: {
        log.warn("formal", "artifact bundle {s} persisted but discovery index render failed: {s}", .{
            event_id[0..],
            @errorName(err),
        });
        break :blk false;
    };
    return .{
        .manifest_sha256 = manifest_sha256,
        .receipt_sha256 = receipt_sha256,
        .index_persisted = index_persisted,
    };
}

/// Verify the authoritative manifest and every listed artifact. Discovery
/// index lines are intentionally excluded: they are rebuildable hints, not
/// evidence. Unknown/duplicate filenames, symlinks, size drift, and hash drift
/// all fail closed.
pub fn verifyBundle(allocator: std.mem.Allocator, event_dir: []const u8) !VerifiedBundle {
    if (!std.fs.path.isAbsolute(event_dir)) return error.InvalidArtifactTarget;
    try rejectSymlink(allocator, event_dir);
    if (std.fs.path.dirname(event_dir)) |parent| try rejectSymlink(allocator, parent);
    const basename = std.fs.path.basename(event_dir);
    const event_id = parseLowerHex64(basename) orelse return error.InvalidEventId;
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{event_dir});
    defer allocator.free(manifest_path);
    const manifest_bytes = try readVerifiedFile(allocator, manifest_path, MAX_ARTIFACT_BYTES);
    defer allocator.free(manifest_bytes);
    var parsed = std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    defer parsed.deinit();
    const manifest = parsed.value;
    if (!std.mem.eql(u8, manifest.schema_version, BUNDLE_SCHEMA) or
        !std.mem.eql(u8, manifest.event_id, basename) or
        !manifest.completion_marker or
        !std.mem.eql(u8, manifest.write_policy, "exclusive_create_manifest_last") or
        !std.mem.eql(u8, manifest.durability, "file_fsync_attempted_directory_entry_sync_not_guaranteed") or
        !std.mem.eql(u8, manifest.integrity_model, "hash_linked_not_signed") or
        !std.mem.eql(u8, manifest.storage_threat_model, "same_user_storage_not_adversarial") or
        !std.mem.eql(u8, manifest.persistence_latency_boundary, "directory_create_through_receipt_fsync_before_manifest") or
        manifest.files.len == 0 or manifest.files.len > MAX_FILES)
        return error.InvalidManifest;

    var receipt_sha256: ?[64]u8 = null;
    for (manifest.files, 0..) |entry, index| {
        if (!validArtifactName(entry.name) or entry.bytes > MAX_ARTIFACT_BYTES)
            return error.InvalidManifest;
        for (manifest.files[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, entry.name)) return error.InvalidManifest;
        }
        const expected_hash = parseLowerHex64(entry.sha256) orelse return error.InvalidManifest;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ event_dir, entry.name });
        defer allocator.free(path);
        const payload = try readVerifiedFile(allocator, path, MAX_ARTIFACT_BYTES);
        defer allocator.free(payload);
        const actual_hash = sha256Hex(payload);
        if (payload.len != entry.bytes or !std.mem.eql(u8, &actual_hash, &expected_hash))
            return error.ArtifactHashMismatch;
        if (std.mem.eql(u8, entry.name, "receipt.json")) receipt_sha256 = actual_hash;
    }
    const verified_receipt_sha256 = receipt_sha256 orelse return error.InvalidManifest;
    return .{
        .event_id = event_id,
        .manifest_sha256 = sha256Hex(manifest_bytes),
        .receipt_sha256 = verified_receipt_sha256,
        .files_verified = manifest.files.len,
    };
}

fn validArtifactName(name: []const u8) bool {
    const names = [_][]const u8{
        "snapshot-source.bin",        "snapshot.json",      "proposal.json",      "request.json",
        "verdict.json",               "checker-stdout.bin", "checker-stderr.bin", "checker-provenance.json",
        "checker-build-receipt.json", "receipt.json",
    };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn readVerifiedFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!before.is_regular or before.size > max_bytes) return error.ArtifactTooLarge;
    const size: usize = @intCast(before.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.readZ(fd, bytes[offset..]) catch return error.ArtifactReadFailed;
        if (count == 0) return error.ArtifactChangedDuringRead;
        offset += count;
    }
    var probe: [1]u8 = undefined;
    if ((pfs.readZ(fd, &probe) catch return error.ArtifactReadFailed) != 0)
        return error.ArtifactChangedDuringRead;
    const after = pfs.fileInfo(fd) catch return error.ArtifactChangedDuringRead;
    if (!after.is_regular or after.size != before.size) return error.ArtifactChangedDuringRead;
    return bytes;
}

fn parseLowerHex64(raw: []const u8) ?[64]u8 {
    if (raw.len != 64) return null;
    var result: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn rejectSymlink(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (pfs.isSymlink(path_z.ptr)) return error.ArtifactRootSymlink;
}

fn createExclusiveDirectory(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    // EEXIST is an identity collision and must never become overwrite.
    if (std.c.mkdir(path_z.ptr, 0o700) != 0) return error.EventDirectoryCreateFailed;
}

fn maybeWrite(
    allocator: std.mem.Allocator,
    event_dir: []const u8,
    records: *std.ArrayList(FileRecord),
    name: []const u8,
    bytes: ?[]const u8,
) !void {
    if (bytes) |payload| try writeArtifact(allocator, event_dir, records, name, payload);
}

fn writeArtifact(
    allocator: std.mem.Allocator,
    event_dir: []const u8,
    records: *std.ArrayList(FileRecord),
    name: []const u8,
    bytes: []const u8,
) !void {
    if (records.items.len >= MAX_FILES or bytes.len > MAX_ARTIFACT_BYTES)
        return error.ArtifactTooLarge;
    try writeExclusiveFile(allocator, event_dir, name, bytes);
    try records.append(allocator, .{
        .name = name,
        .bytes = bytes.len,
        .sha256 = sha256Hex(bytes),
    });
}

fn writeExclusiveFile(
    allocator: std.mem.Allocator,
    event_dir: []const u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ event_dir, name });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    pfs.makeCloseOnExec(fd) catch return error.ArtifactOpenFailed;
    try writeAll(fd, bytes);
    pfs.fsync(fd);
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = pfs.write(fd, bytes[offset..]);
        if (written <= 0) return error.ArtifactWriteFailed;
        const count: usize = @intCast(written);
        if (count > bytes.len - offset) return error.ArtifactWriteFailed;
        offset += count;
    }
}

fn renderManifest(
    allocator: std.mem.Allocator,
    event_id: [64]u8,
    records: []const FileRecord,
    pre_manifest_persistence_elapsed_ns: u64,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "{{\"schema_version\":\"{s}\",\"event_id\":\"{s}\",\"completion_marker\":true,\"write_policy\":\"exclusive_create_manifest_last\",\"durability\":\"file_fsync_attempted_directory_entry_sync_not_guaranteed\",\"integrity_model\":\"hash_linked_not_signed\",\"storage_threat_model\":\"same_user_storage_not_adversarial\",\"pre_manifest_persistence_elapsed_ns\":{d},\"persistence_latency_boundary\":\"directory_create_through_receipt_fsync_before_manifest\",\"files\":[",
        .{ BUNDLE_SCHEMA, event_id[0..], pre_manifest_persistence_elapsed_ns },
    );
    for (records, 0..) |record, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print(
            "{{\"name\":\"{s}\",\"bytes\":{d},\"sha256\":\"{s}\"}}",
            .{ record.name, record.bytes, record.sha256[0..] },
        );
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderIndex(
    allocator: std.mem.Allocator,
    event_id: [64]u8,
    receipt_sha256: [64]u8,
    manifest_sha256: [64]u8,
    metadata: IndexMetadata,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "{{\"schema_version\":\"{s}\",\"event_id\":\"{s}\",\"bundle_rel\":\"{s}/{s}\",\"bundle_schema\":\"{s}\",\"manifest_sha256\":\"{s}\",\"receipt_sha256\":\"{s}\",\"started_wall_ns\":{d},\"request_id\":",
        .{ INDEX_SCHEMA, event_id[0..], ARTIFACT_DIR_NAME, event_id[0..], BUNDLE_SCHEMA, manifest_sha256[0..], receipt_sha256[0..], metadata.started_wall_ns },
    );
    try writeOptionalString(writer, metadata.request_id);
    try writer.writeAll(",\"snapshot_revision\":");
    try writeOptionalString(writer, metadata.snapshot_revision);
    try writer.print(
        ",\"pipeline_admitted\":{s},\"failure_kind\":",
        .{if (metadata.pipeline_admitted) "true" else "false"},
    );
    try std.json.Stringify.encodeJsonString(metadata.failure_kind, .{}, writer);
    try writer.writeAll("}\n");
    const owned = try out.toOwnedSlice();
    if (owned.len > MAX_INDEX_LINE_BYTES) {
        allocator.free(owned);
        return error.IndexLineTooLarge;
    }
    return owned;
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text|
        try std.json.Stringify.encodeJsonString(text, .{}, writer)
    else
        try writer.writeAll("null");
}

fn appendIndex(allocator: std.mem.Allocator, path: []const u8, line: []const u8) !bool {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidArtifactTarget;
    try util_fs.mkdirParents(parent);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.IndexOpenFailed;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return error.IndexStatFailed;
    if (!info.is_regular) return error.IndexNotRegular;
    if (info.size > MAX_INDEX_BYTES or line.len > MAX_INDEX_BYTES - info.size)
        return error.IndexFull;
    // One bounded O_APPEND write prevents record interleaving. A disk-full
    // short write can leave only the final line incomplete; bundle manifests
    // remain authoritative and allow deterministic index repair.
    const written = pfs.write(fd, line);
    if (written != @as(isize, @intCast(line.len))) return error.IndexWriteFailed;
    pfs.fsync(fd);
    return true;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn elapsedSince(started: i128) u64 {
    const finished = time.nowNs();
    if (started <= 0 or finished <= started) return 0;
    return @intCast(@min(finished - started, std.math.maxInt(u64)));
}

test "formal artifact event ids are unique and path-safe" {
    const first = newEventId(1, 2, null);
    const second = newEventId(1, 2, null);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    for (first) |byte| try std.testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
}

test "formal artifact bundle never overwrites an existing event identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const index_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/events-v1.jsonl", .{root});
    defer std.testing.allocator.free(index_path);
    const event_id: [64]u8 = .{'a'} ** 64;
    const metadata = IndexMetadata{
        .started_wall_ns = 1,
        .request_id = null,
        .snapshot_revision = null,
        .pipeline_admitted = false,
        .failure_kind = "config_missing",
    };
    const first = try persist(
        std.testing.allocator,
        index_path,
        event_id,
        "{\"receipt\":1}",
        .{ .snapshot_source = "raw" },
        metadata,
    );
    try std.testing.expect(first.index_persisted);
    const event_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/{s}",
        .{ root, ARTIFACT_DIR_NAME, event_id[0..] },
    );
    defer std.testing.allocator.free(event_dir);
    const verified = try verifyBundle(std.testing.allocator, event_dir);
    try std.testing.expectEqual(@as(usize, 2), verified.files_verified);
    try std.testing.expectEqualStrings(first.manifest_sha256[0..], verified.manifest_sha256[0..]);
    try std.testing.expectError(
        error.EventDirectoryCreateFailed,
        persist(
            std.testing.allocator,
            index_path,
            event_id,
            "{\"receipt\":2}",
            .{ .snapshot_source = "replacement" },
            metadata,
        ),
    );

    const receipt_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/{s}/receipt.json",
        .{ root, ARTIFACT_DIR_NAME, event_id[0..] },
    );
    defer std.testing.allocator.free(receipt_path);
    const stored = try readTestFile(std.testing.allocator, receipt_path);
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings("{\"receipt\":1}", stored);

    const snapshot_source_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/snapshot-source.bin",
        .{event_dir},
    );
    defer std.testing.allocator.free(snapshot_source_path);
    try overwriteTestFile(std.testing.allocator, snapshot_source_path, "tampered");
    try std.testing.expectError(
        error.ArtifactHashMismatch,
        verifyBundle(std.testing.allocator, event_dir),
    );
}

test "formal artifact bundle remains authoritative when discovery index append fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const index_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/events-v1.jsonl", .{root});
    defer std.testing.allocator.free(index_path);
    // A directory at the index path forces the rebuildable cache append to
    // fail after manifest publication without interfering with bundle writes.
    const index_path_z = try std.testing.allocator.dupeZ(u8, index_path);
    defer std.testing.allocator.free(index_path_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(index_path_z.ptr, 0o700));

    const event_id: [64]u8 = .{'b'} ** 64;
    const persisted = try persist(
        std.testing.allocator,
        index_path,
        event_id,
        "{\"receipt\":true}",
        .{ .snapshot_source = "raw" },
        .{
            .started_wall_ns = 1,
            .request_id = null,
            .snapshot_revision = null,
            .pipeline_admitted = true,
            .failure_kind = "none",
        },
    );
    try std.testing.expect(!persisted.index_persisted);

    const manifest_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/{s}/manifest.json",
        .{ root, ARTIFACT_DIR_NAME, event_id[0..] },
    );
    defer std.testing.allocator.free(manifest_path);
    const manifest = try readTestFile(std.testing.allocator, manifest_path);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"completion_marker\":true") != null);
}

fn readTestFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try pfs.readZ(fd, &buffer);
        if (count == 0) break;
        if (out.items.len + count > MAX_ARTIFACT_BYTES) return error.FileTooLarge;
        try out.appendSlice(allocator, buffer[0..count]);
    }
    return out.toOwnedSlice(allocator);
}

fn overwriteTestFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    try writeAll(fd, bytes);
}
