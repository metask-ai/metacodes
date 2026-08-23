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
pub const PREVIEW_HEAD_BYTES: usize = 1152;
pub const PREVIEW_TAIL_BYTES: usize = 384;

/// Fixed-size capture kept while a result is streamed to disk. It preserves
/// the same 1536-byte head/tail observability as the legacy post-hoc projector
/// without retaining the complete result in memory.
pub const Preview = struct {
    head: [PREVIEW_HEAD_BYTES]u8 = undefined,
    head_len: usize = 0,
    tail: [PREVIEW_TAIL_BYTES]u8 = undefined,
    tail_len: usize = 0,
    total_bytes: u64 = 0,

    pub fn headSlice(self: *const Preview) []const u8 {
        return self.head[0..self.head_len];
    }

    pub fn tailSlice(self: *const Preview) []const u8 {
        const non_overlapping: usize = @intCast(@min(
            @as(u64, self.tail_len),
            self.total_bytes -| self.head_len,
        ));
        return self.tail[self.tail_len - non_overlapping .. self.tail_len];
    }

    pub fn omittedBytes(self: *const Preview) u64 {
        return self.total_bytes -| self.headSlice().len -| self.tailSlice().len;
    }

    fn append(self: *Preview, bytes: []const u8) void {
        const head_remaining = PREVIEW_HEAD_BYTES - self.head_len;
        const head_count = @min(head_remaining, bytes.len);
        @memcpy(self.head[self.head_len .. self.head_len + head_count], bytes[0..head_count]);
        self.head_len += head_count;

        if (bytes.len >= PREVIEW_TAIL_BYTES) {
            @memcpy(self.tail[0..], bytes[bytes.len - PREVIEW_TAIL_BYTES ..]);
            self.tail_len = PREVIEW_TAIL_BYTES;
        } else if (bytes.len != 0) {
            const retained = @min(self.tail_len, PREVIEW_TAIL_BYTES - bytes.len);
            if (retained != 0) {
                const source_start = self.tail_len - retained;
                std.mem.copyForwards(u8, self.tail[0..retained], self.tail[source_start..self.tail_len]);
            }
            @memcpy(self.tail[retained .. retained + bytes.len], bytes);
            self.tail_len = retained + bytes.len;
        }
        self.total_bytes +|= bytes.len;
    }
};

pub const Receipt = struct {
    artifact_id: [ID_BYTES]u8,
    sha256: [ID_HEX_BYTES]u8,
    bytes: u64,
    capture_complete: bool = true,

    pub fn id(self: *const Receipt) []const u8 {
        return self.artifact_id[0..];
    }
};

pub const CompletedSpool = struct {
    receipt: Receipt,
    preview: Preview,
};

/// Kernel-private, unpublished capture used when a protocol frame must be
/// received from byte zero and validated before any subset is authorized for
/// the model-visible CAS. Unlike `Spool`, sealing this file never publishes
/// it. The caller may rewind/read it in bounded chunks and `deinit` always
/// removes it.
pub const Capture = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    temp_path: [:0]u8,
    fd: pfs.Fd,
    max_bytes: u64,
    bytes: u64 = 0,
    state: State = .writing,

    const State = enum { writing, sealed };

    pub fn begin(
        allocator: std.mem.Allocator,
        session_root: []const u8,
        max_bytes: u64,
    ) !Capture {
        if (session_root.len == 0) return error.ArtifactRootUnavailable;
        if (max_bytes == 0) return error.ArtifactTooLarge;
        const directory = try spoolDirectory(allocator, session_root);
        errdefer allocator.free(directory);
        try ensureSecureSpoolDirectory(allocator, session_root, directory);

        var nonce: [16]u8 = undefined;
        if (!@import("platform").rng.randomBytes(&nonce)) return error.RandomFailed;
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const temp_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/capture-{s}.tmp",
            .{ directory, nonce_hex[0..] },
            0,
        );
        errdefer allocator.free(temp_path);
        const fd = pfs.open(temp_path.ptr, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
        }, 0o600);
        if (fd < 0) return error.ArtifactTempOpenFailed;
        errdefer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);
        const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
        if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
        return .{
            .allocator = allocator,
            .directory = directory,
            .temp_path = temp_path,
            .fd = fd,
            .max_bytes = max_bytes,
        };
    }

    pub fn write(self: *Capture, chunk: []const u8) !void {
        if (self.state != .writing) return error.ArtifactSpoolClosed;
        if (chunk.len > self.max_bytes -| self.bytes) return error.ArtifactTooLarge;
        try writeAll(self.fd, chunk);
        self.bytes += chunk.len;
    }

    /// Borrow the already-open private descriptor for one trusted kernel
    /// adapter that redirects a child producer into this capture. The caller
    /// must wait for every inherited writer to close before `sealExternal`.
    /// Exposing only the descriptor (never the path) keeps path authority in
    /// the kernel and makes the writing -> sealed transition explicit.
    pub fn outputFd(self: *Capture) !pfs.Fd {
        if (self.state != .writing) return error.ArtifactSpoolClosed;
        return self.fd;
    }

    /// Observe bytes written through a descriptor borrowed from `outputFd`.
    /// This is used only for a bounded producer monitor; it does not advance
    /// the capture state or authorize publication.
    pub fn observedExternalBytes(self: *Capture) !u64 {
        if (self.state != .writing) return error.ArtifactSpoolClosed;
        const info = pfs.fileInfo(self.fd) catch return error.ArtifactStatFailed;
        if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
        return info.size;
    }

    /// Seal bytes written by a child through `outputFd`. Empty stderr is valid
    /// here (unlike an empty protocol frame). If a producer crossed the hard
    /// bound between monitor ticks, retain only the deterministic prefix and
    /// report `false`; callers propagate that as capture_complete=false.
    /// The child must already be reaped, otherwise sealing would race a live
    /// writer and fail the state contract.
    pub fn sealExternal(self: *Capture) !bool {
        if (self.state != .writing) return error.ArtifactSpoolClosed;
        const info = pfs.fileInfo(self.fd) catch return error.ArtifactStatFailed;
        if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
        const complete = info.size <= self.max_bytes;
        if (!complete) pfs.setSize(self.fd, self.max_bytes) catch
            return error.ArtifactResizeFailed;
        self.bytes = @min(info.size, self.max_bytes);
        try pfs.fsyncChecked(self.fd);
        self.state = .sealed;
        try self.rewind();
        return complete;
    }

    pub fn seal(self: *Capture) !void {
        if (self.state != .writing) return error.ArtifactSpoolClosed;
        if (self.bytes == 0) return error.ArtifactCaptureEmpty;
        try pfs.fsyncChecked(self.fd);
        self.state = .sealed;
        try self.rewind();
    }

    pub fn rewind(self: *Capture) !void {
        if (self.state != .sealed) return error.ArtifactCaptureNotSealed;
        if (pfs.lseek(self.fd, 0, .set) != 0) return error.ArtifactSeekFailed;
    }

    pub fn read(self: *Capture, out: []u8) !usize {
        if (self.state != .sealed) return error.ArtifactCaptureNotSealed;
        return pfs.readZ(self.fd, out) catch error.ArtifactReadFailed;
    }

    /// Copy one already-validated byte range into a final CAS spool without
    /// materializing the range. The destination owns hashing and preview.
    pub fn copyRangeTo(
        self: *Capture,
        destination: *Spool,
        offset: u64,
        length: u64,
    ) !void {
        if (self.state != .sealed) return error.ArtifactCaptureNotSealed;
        if (offset > self.bytes or length > self.bytes - offset)
            return error.InvalidReadOffset;
        if (offset > std.math.maxInt(i64)) return error.ArtifactSeekFailed;
        if (pfs.lseek(self.fd, @intCast(offset), .set) != @as(i64, @intCast(offset)))
            return error.ArtifactSeekFailed;
        var remaining = length;
        var buffer: [64 * 1024]u8 = undefined;
        while (remaining != 0) {
            const wanted: usize = @intCast(@min(remaining, buffer.len));
            const count = pfs.readZ(self.fd, buffer[0..wanted]) catch
                return error.ArtifactReadFailed;
            if (count == 0) return error.ArtifactSourceChanged;
            try destination.write(buffer[0..count]);
            remaining -= count;
        }
    }

    pub fn readRangeAlloc(
        self: *Capture,
        allocator: std.mem.Allocator,
        offset: u64,
        length: usize,
    ) ![]u8 {
        if (self.state != .sealed) return error.ArtifactCaptureNotSealed;
        if (offset > self.bytes or length > self.bytes - offset)
            return error.InvalidReadOffset;
        const out = try allocator.alloc(u8, length);
        errdefer allocator.free(out);
        if (offset > std.math.maxInt(i64)) return error.ArtifactSeekFailed;
        if (pfs.lseek(self.fd, @intCast(offset), .set) != @as(i64, @intCast(offset)))
            return error.ArtifactSeekFailed;
        var written: usize = 0;
        while (written != out.len) {
            const count = pfs.readZ(self.fd, out[written..]) catch
                return error.ArtifactReadFailed;
            if (count == 0) return error.ArtifactSourceChanged;
            written += count;
        }
        return out;
    }

    pub fn deinit(self: *Capture) void {
        _ = pfs.close(self.fd);
        pfs.unlinkPath(self.temp_path.ptr) catch {};
        self.allocator.free(self.temp_path);
        self.allocator.free(self.directory);
        self.* = undefined;
    }
};

/// Private, Session-scoped incremental writer. Callers can start this before
/// the producer emits byte zero, so memory usage is bounded by the producer's
/// own chunk plus this fixed preview. `deinit` aborts and removes unpublished
/// state on every error/cancellation path.
pub const Spool = struct {
    allocator: std.mem.Allocator,
    session_root: []u8,
    directory: []u8,
    temp_path: [:0]u8,
    fd: pfs.Fd,
    fd_open: bool = true,
    published: bool = false,
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    preview: Preview = .{},

    pub fn begin(allocator: std.mem.Allocator, session_root: []const u8) !Spool {
        if (session_root.len == 0) return error.ArtifactRootUnavailable;
        const directory = try spoolDirectory(allocator, session_root);
        errdefer allocator.free(directory);
        const root_owned = try allocator.dupe(u8, session_root);
        errdefer allocator.free(root_owned);
        try ensureSecureSpoolDirectory(allocator, session_root, directory);

        var nonce: [16]u8 = undefined;
        if (!@import("platform").rng.randomBytes(&nonce)) return error.RandomFailed;
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const temp_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/stream-{s}.tmp",
            .{ directory, nonce_hex[0..] },
            0,
        );
        errdefer allocator.free(temp_path);
        const fd = pfs.open(temp_path.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
        }, 0o600);
        if (fd < 0) return error.ArtifactTempOpenFailed;
        errdefer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);
        const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
        if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
        return .{
            .allocator = allocator,
            .session_root = root_owned,
            .directory = directory,
            .temp_path = temp_path,
            .fd = fd,
        };
    }

    pub fn write(self: *Spool, bytes: []const u8) !void {
        if (!self.fd_open or self.published) return error.ArtifactSpoolClosed;
        if (bytes.len > MAX_ARTIFACT_BYTES -| @as(usize, @intCast(self.preview.total_bytes)))
            return error.ArtifactTooLarge;
        try writeAll(self.fd, bytes);
        self.hasher.update(bytes);
        self.preview.append(bytes);
    }

    pub fn finish(self: *Spool) !CompletedSpool {
        return self.finishWithMode(.normal);
    }

    const PublishMode = enum {
        normal,
        inject_failure_after_install,
        inject_competing_destination,
    };

    fn finishWithMode(self: *Spool, mode: PublishMode) !CompletedSpool {
        if (!self.fd_open or self.published) return error.ArtifactSpoolClosed;
        try pfs.fsyncChecked(self.fd);
        const temp_identity = pfs.fileInfo(self.fd) catch return error.ArtifactStatFailed;
        if (!safeArtifactInfo(temp_identity) or temp_identity.size != self.preview.total_bytes)
            return error.ArtifactSourceChanged;
        _ = pfs.close(self.fd);
        self.fd_open = false;

        var digest_bytes: [32]u8 = undefined;
        self.hasher.final(&digest_bytes);
        const digest = std.fmt.bytesToHex(digest_bytes, .lower);
        const snapshot = FileSnapshot{ .sha256 = digest, .bytes = self.preview.total_bytes };

        const artifact_directory = try artifactDirectory(self.allocator, self.session_root);
        defer self.allocator.free(artifact_directory);
        try ensureSecureDirectory(self.allocator, self.session_root, artifact_directory);

        persist_mutex.lock();
        defer persist_mutex.unlock();

        const final_path = try artifactPath(self.allocator, artifact_directory, digest);
        defer self.allocator.free(final_path);
        if (try verifyExisting(self.allocator, final_path, digest, @intCast(snapshot.bytes))) {
            pfs.unlinkPath(self.temp_path.ptr) catch return error.ArtifactSpoolCleanupFailed;
            try fsyncDirectory(self.allocator, self.directory);
            self.published = true;
            return .{ .receipt = receiptFor(snapshot), .preview = self.preview };
        }
        const used = try directoryBytes(self.allocator, artifact_directory);
        if (snapshot.bytes > MAX_SESSION_BYTES -| used) return error.SessionQuotaExceeded;

        try publishPreparedFile(
            self.allocator,
            self.temp_path,
            final_path,
            artifact_directory,
            self.directory,
            snapshot,
            temp_identity,
            mode,
        );
        self.published = true;
        return .{ .receipt = receiptFor(snapshot), .preview = self.preview };
    }

    pub fn deinit(self: *Spool) void {
        if (self.fd_open) _ = pfs.close(self.fd);
        if (!self.published) pfs.unlinkPath(self.temp_path.ptr) catch {};
        self.allocator.free(self.temp_path);
        self.allocator.free(self.directory);
        self.allocator.free(self.session_root);
        self.* = undefined;
    }
};

/// Path-based byte-zero sink for out-of-process producers. The kernel creates
/// the private file before spawn and imports it only after the child exits;
/// no untrusted path or artifact ID is accepted from the plugin response.
pub const ExternalSpool = struct {
    allocator: std.mem.Allocator,
    session_root: []u8,
    path_z: [:0]u8,
    finished: bool = false,

    pub fn begin(allocator: std.mem.Allocator, session_root: []const u8) !ExternalSpool {
        if (session_root.len == 0) return error.ArtifactRootUnavailable;
        const directory = try spoolDirectory(allocator, session_root);
        defer allocator.free(directory);
        const root_owned = try allocator.dupe(u8, session_root);
        errdefer allocator.free(root_owned);
        try ensureSecureSpoolDirectory(allocator, session_root, directory);
        var nonce: [16]u8 = undefined;
        if (!@import("platform").rng.randomBytes(&nonce)) return error.RandomFailed;
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const path_z = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/external-{s}.tmp",
            .{ directory, nonce_hex[0..] },
            0,
        );
        errdefer allocator.free(path_z);
        const fd = pfs.open(path_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
        }, 0o600);
        if (fd < 0) return error.ArtifactTempOpenFailed;
        defer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);
        const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
        if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
        return .{ .allocator = allocator, .session_root = root_owned, .path_z = path_z };
    }

    pub fn path(self: *const ExternalSpool) []const u8 {
        return self.path_z[0..self.path_z.len];
    }

    pub fn finish(self: *ExternalSpool) !CompletedSpool {
        return self.finishWithMode(.normal);
    }

    const FinishMode = enum {
        normal,
        inject_failure_after_publish,
    };

    fn finishWithMode(self: *ExternalSpool, mode: FinishMode) !CompletedSpool {
        if (self.finished) return error.ArtifactSpoolClosed;
        const snapshot = try inspectFile(self.allocator, self.path());
        const completed = try persistExternalInspectedFile(
            self.allocator,
            self.session_root,
            self.path(),
            snapshot,
            mode,
        );
        self.finished = true;
        return completed;
    }

    pub fn deinit(self: *ExternalSpool) void {
        if (!self.finished) pfs.unlinkPath(self.path_z.ptr) catch {};
        self.allocator.free(self.path_z);
        self.allocator.free(self.session_root);
        self.* = undefined;
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

const ImportMode = enum {
    receipt_only,
    external_completed,
    external_inject_cleanup_failure,
};

const ImportResult = union(enum) {
    receipt: Receipt,
    completed: CompletedSpool,
};

pub fn persist(allocator: std.mem.Allocator, session_root: []const u8, bytes: []const u8) !Receipt {
    var spool = try Spool.begin(allocator, session_root);
    defer spool.deinit();
    try spool.write(bytes);
    return (try spool.finish()).receipt;
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
    return switch (try persistInspectedFileInternal(
        allocator,
        session_root,
        source_path,
        expected,
        .receipt_only,
    )) {
        .receipt => |receipt| receipt,
        .completed => unreachable,
    };
}

fn persistExternalInspectedFile(
    allocator: std.mem.Allocator,
    session_root: []const u8,
    source_path: []const u8,
    expected: FileSnapshot,
    mode: ExternalSpool.FinishMode,
) !CompletedSpool {
    return switch (try persistInspectedFileInternal(
        allocator,
        session_root,
        source_path,
        expected,
        if (mode == .inject_failure_after_publish)
            .external_inject_cleanup_failure
        else
            .external_completed,
    )) {
        .completed => |completed| completed,
        .receipt => unreachable,
    };
}

fn persistInspectedFileInternal(
    allocator: std.mem.Allocator,
    session_root: []const u8,
    source_path: []const u8,
    expected: FileSnapshot,
    mode: ImportMode,
) !ImportResult {
    if (session_root.len == 0) return error.ArtifactRootUnavailable;
    if (expected.bytes > MAX_ARTIFACT_BYTES) return error.ArtifactTooLarge;
    const directory = try artifactDirectory(allocator, session_root);
    defer allocator.free(directory);
    try ensureSecureDirectory(allocator, session_root, directory);

    persist_mutex.lock();
    defer persist_mutex.unlock();

    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const final_path = try artifactPath(allocator, directory, expected.sha256);
    defer allocator.free(final_path);
    if (try verifyExisting(allocator, final_path, expected.sha256, @intCast(expected.bytes))) {
        return switch (mode) {
            .receipt_only => .{ .receipt = receiptFor(expected) },
            .external_completed, .external_inject_cleanup_failure => blk: {
                const preview = try previewVerifiedFile(allocator, final_path, expected);
                pfs.unlinkPath(source_z.ptr) catch return error.ArtifactSpoolCleanupFailed;
                try fsyncParentDirectory(allocator, source_path);
                break :blk .{ .completed = .{
                    .receipt = receiptFor(expected),
                    .preview = preview,
                } };
            },
        };
    }
    const used = try directoryBytes(allocator, directory);
    if (expected.bytes > MAX_SESSION_BYTES -| used) return error.SessionQuotaExceeded;

    const source_fd = pfs.open(source_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (source_fd < 0) return error.ArtifactSourceOpenFailed;
    var source_open = true;
    defer {
        if (source_open) _ = pfs.close(source_fd);
    }
    try pfs.makeCloseOnExec(source_fd);
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
    var preview = Preview{};
    var copied: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(source_fd, &buffer) catch return error.ArtifactReadFailed;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        if (mode != .receipt_only) preview.append(buffer[0..count]);
        try writeAll(temp_fd, buffer[0..count]);
        copied +|= count;
    }
    const source_after = pfs.fileInfo(source_fd) catch return error.ArtifactSourceChanged;
    if (!sameFile(source_before, source_after) or copied != expected.bytes)
        return error.ArtifactSourceChanged;
    _ = pfs.close(source_fd);
    source_open = false;
    var digest_bytes: [32]u8 = undefined;
    hasher.final(&digest_bytes);
    const copied_digest = std.fmt.bytesToHex(digest_bytes, .lower);
    if (!std.mem.eql(u8, copied_digest[0..], expected.sha256[0..]))
        return error.ArtifactSourceChanged;
    try pfs.fsyncChecked(temp_fd);
    const temp_identity = pfs.fileInfo(temp_fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(temp_identity) or temp_identity.size != expected.bytes)
        return error.ArtifactSourceChanged;
    _ = pfs.close(temp_fd);
    temp_open = false;

    try publishPreparedFile(
        allocator,
        temp_z,
        final_path,
        directory,
        directory,
        expected,
        temp_identity,
        .normal,
    );
    if (mode != .receipt_only) {
        if (mode == .external_inject_cleanup_failure) {
            rollbackPublishedFile(allocator, final_path, directory, temp_identity) catch
                return error.ArtifactPublishRollbackFailed;
            return error.ArtifactSpoolCleanupInjectedFailure;
        }
        pfs.unlinkPath(source_z.ptr) catch {
            rollbackPublishedFile(allocator, final_path, directory, temp_identity) catch
                return error.ArtifactPublishRollbackFailed;
            return error.ArtifactSpoolCleanupFailed;
        };
        fsyncParentDirectory(allocator, source_path) catch |err| {
            rollbackPublishedFile(allocator, final_path, directory, temp_identity) catch
                return error.ArtifactPublishRollbackFailed;
            return err;
        };
    }
    return switch (mode) {
        .receipt_only => .{ .receipt = receiptFor(expected) },
        .external_completed, .external_inject_cleanup_failure => .{ .completed = .{
            .receipt = receiptFor(expected),
            .preview = preview,
        } },
    };
}

/// Install one completely written private file into the CAS and return only after
/// the directory entry is durable and the final pathname re-verifies. A
/// post-install failure must not leave an unreceipted object consuming Session
/// quota: rollback removes the final pathname only when it still names the
/// exact inode/file-id that this call moved there.
fn publishPreparedFile(
    allocator: std.mem.Allocator,
    temp_path: [:0]const u8,
    final_path: []const u8,
    directory: []const u8,
    source_directory: []const u8,
    expected: FileSnapshot,
    temp_identity: pfs.FileInfo,
    mode: Spool.PublishMode,
) !void {
    const final_z = try allocator.dupeZ(u8, final_path);
    defer allocator.free(final_z);
    if (mode == .inject_competing_destination) {
        {
            const competing_fd = pfs.open(final_z.ptr, .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .EXCL = true,
                .NOFOLLOW = true,
            }, 0o600);
            if (competing_fd < 0) return error.ArtifactPublishInjectedFailure;
            defer _ = pfs.close(competing_fd);
            try pfs.makeCloseOnExec(competing_fd);
            try writeAll(competing_fd, "competing-cas-object");
            try pfs.fsyncChecked(competing_fd);
        }
    }

    const installed = pfs.installNoReplace(temp_path.ptr, final_z.ptr) catch
        return error.ArtifactPublishFailed;
    switch (installed) {
        .already_exists => {
            if (!(try verifyExisting(
                allocator,
                final_path,
                expected.sha256,
                @intCast(expected.bytes),
            ))) return error.ArtifactPublishVerificationFailed;
            pfs.unlinkPath(temp_path.ptr) catch return error.ArtifactSpoolCleanupFailed;
            // Dedup has no new final directory entry, but removing the private
            // source must be durable before its successful receipt escapes.
            try fsyncDirectory(allocator, source_directory);
            return;
        },
        .linked => {
            pfs.unlinkPath(temp_path.ptr) catch {
                rollbackPublishedFile(allocator, final_path, directory, temp_identity) catch
                    return error.ArtifactPublishRollbackFailed;
                return error.ArtifactSpoolCleanupFailed;
            };
            // `link(2)` and unlink may touch different directories. The final
            // directory is synced by postPublishVerify below; sync the source
            // directory separately so a crash cannot resurrect the private
            // hardlink and invalidate the published object's link_count=1.
            if (!std.mem.eql(u8, source_directory, directory)) {
                fsyncDirectory(allocator, source_directory) catch |err| {
                    rollbackPublishedFile(allocator, final_path, directory, temp_identity) catch
                        return error.ArtifactPublishRollbackFailed;
                    return err;
                };
            }
        },
        .moved => {},
    }

    postPublishVerify(allocator, final_path, directory, expected, mode) catch |err| {
        rollbackPublishedFile(allocator, final_path, directory, temp_identity) catch
            return error.ArtifactPublishRollbackFailed;
        return err;
    };
}

fn postPublishVerify(
    allocator: std.mem.Allocator,
    final_path: []const u8,
    directory: []const u8,
    expected: FileSnapshot,
    mode: Spool.PublishMode,
) !void {
    if (mode == .inject_failure_after_install)
        return error.ArtifactPublishInjectedFailure;
    try fsyncDirectory(allocator, directory);
    if (!(try verifyExisting(allocator, final_path, expected.sha256, @intCast(expected.bytes))))
        return error.ArtifactPublishVerificationFailed;
}

fn rollbackPublishedFile(
    allocator: std.mem.Allocator,
    final_path: []const u8,
    directory: []const u8,
    expected_identity: pfs.FileInfo,
) !void {
    const final_z = try allocator.dupeZ(u8, final_path);
    defer allocator.free(final_z);
    if (!pfs.exists(final_z.ptr)) return;
    const fd = pfs.open(final_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactPublishRollbackFailed;
    pfs.makeCloseOnExec(fd) catch {
        _ = pfs.close(fd);
        return error.ArtifactPublishRollbackFailed;
    };
    const observed = pfs.fileInfo(fd) catch {
        _ = pfs.close(fd);
        return error.ArtifactPublishRollbackFailed;
    };
    _ = pfs.close(fd);
    if (!sameIdentity(expected_identity, observed)) return;
    pfs.unlinkPath(final_z.ptr) catch return error.ArtifactPublishRollbackFailed;
    fsyncDirectory(allocator, directory) catch return error.ArtifactPublishRollbackFailed;
}

pub fn inspectFile(allocator: std.mem.Allocator, source_path: []const u8) !FileSnapshot {
    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const fd = pfs.open(source_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactSourceOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.makeCloseOnExec(fd);
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
    try pfs.makeCloseOnExec(fd);
    const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
    return info.size;
}

/// Read the preview and digest in one stable descriptor pass. This is used for
/// deduplication: a path verified before this call is not enough because an
/// equal-size in-place rewrite between the hash and preview would otherwise
/// pair a stale receipt with unrelated model-visible head/tail bytes.
fn previewVerifiedFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    expected: FileSnapshot,
) !Preview {
    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const fd = pfs.open(source_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactSourceOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.makeCloseOnExec(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(before) or before.size != expected.bytes)
        return error.ArtifactUnsafeFile;
    var preview = Preview{};
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(fd, &buffer) catch return error.ArtifactReadFailed;
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        preview.append(buffer[0..count]);
    }
    const after = pfs.fileInfo(fd) catch return error.ArtifactSourceChanged;
    if (!sameFile(before, after) or preview.total_bytes != before.size)
        return error.ArtifactSourceChanged;
    var digest_bytes: [32]u8 = undefined;
    hasher.final(&digest_bytes);
    const digest = std.fmt.bytesToHex(digest_bytes, .lower);
    if (!std.mem.eql(u8, digest[0..], expected.sha256[0..]))
        return error.ArtifactSourceChanged;
    return preview;
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

fn spoolDirectory(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/tool-results/spool", .{root});
}

fn artifactPath(allocator: std.mem.Allocator, directory: []const u8, digest: [ID_HEX_BYTES]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.blob", .{ directory, digest[0..] });
}

fn ensureSecureDirectory(allocator: std.mem.Allocator, root: []const u8, directory: []const u8) !void {
    try rejectSymlink(allocator, root);
    try util_fs.mkdirParents(directory);
    try validateSecureDirectory(allocator, root, directory);
}

fn ensureSecureSpoolDirectory(allocator: std.mem.Allocator, root: []const u8, directory: []const u8) !void {
    try rejectSymlink(allocator, root);
    try util_fs.mkdirParents(directory);
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
        pfs.makeCloseOnExec(fd) catch return error.ArtifactDirectoryUntrusted;
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
    try pfs.makeCloseOnExec(fd);
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
        sameIdentity(before, after);
}

fn sameIdentity(before: pfs.FileInfo, after: pfs.FileInfo) bool {
    return after.is_regular and before.size == after.size and
        before.device == after.device and
        before.inode == after.inode;
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
    try pfs.makeCloseOnExec(fd);
    try pfs.fsyncChecked(fd);
}

fn fsyncParentDirectory(allocator: std.mem.Allocator, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.ArtifactDirectoryOpenFailed;
    try fsyncDirectory(allocator, parent);
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
    try pfs.makeCloseOnExec(fd);
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

test "incremental spool captures from byte zero with fixed head and tail memory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var spool = try Spool.begin(allocator, root);
    defer spool.deinit();
    try spool.write("HEAD_SENTINEL-");
    const middle = [_]u8{'m'} ** (96 * 1024);
    var offset: usize = 0;
    while (offset < middle.len) : (offset += 4096)
        try spool.write(middle[offset..@min(offset + 4096, middle.len)]);
    try spool.write("-TAIL_SENTINEL");
    const completed = try spool.finish();
    try std.testing.expectEqual(@as(u64, "HEAD_SENTINEL-".len + middle.len + "-TAIL_SENTINEL".len), completed.receipt.bytes);
    try std.testing.expect(std.mem.startsWith(u8, completed.preview.headSlice(), "HEAD_SENTINEL-"));
    try std.testing.expect(std.mem.endsWith(u8, completed.preview.tailSlice(), "-TAIL_SENTINEL"));
    try std.testing.expectEqual(@as(usize, PREVIEW_HEAD_BYTES), completed.preview.head_len);
    try std.testing.expectEqual(@as(usize, PREVIEW_TAIL_BYTES), completed.preview.tail_len);
    var tail = try readChunk(allocator, root, completed.receipt.id(), completed.receipt.bytes - 32, 32);
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "TAIL_SENTINEL") != null);
}

test "external spool imports only the kernel-created private path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var spool = try ExternalSpool.begin(allocator, root);
    defer spool.deinit();
    const fd = pfs.open(spool.path_z.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactTempOpenFailed;
    try pfs.makeCloseOnExec(fd);
    try writeAll(fd, "PLUGIN_HEAD-");
    const middle = [_]u8{'p'} ** (70 * 1024);
    try writeAll(fd, &middle);
    try writeAll(fd, "-PLUGIN_TAIL");
    try pfs.fsyncChecked(fd);
    _ = pfs.close(fd);
    const completed = try spool.finish();
    try std.testing.expect(std.mem.startsWith(u8, completed.preview.headSlice(), "PLUGIN_HEAD-"));
    try std.testing.expect(std.mem.endsWith(u8, completed.preview.tailSlice(), "-PLUGIN_TAIL"));
    var recovered = try readChunk(allocator, root, completed.receipt.id(), 0, 16);
    defer recovered.deinit();
    try std.testing.expect(std.mem.startsWith(u8, recovered.bytes, "PLUGIN_HEAD-"));
}

test "external spool dedup removes its private source only after verified preview" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const payload = "DEDUP_HEAD-body-DEDUP_TAIL";
    const existing = try persist(allocator, root, payload);
    var spool = try ExternalSpool.begin(allocator, root);
    const private_path = try allocator.dupeZ(u8, spool.path_z);
    defer allocator.free(private_path);
    const fd = pfs.open(spool.path_z.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactTempOpenFailed;
    try pfs.makeCloseOnExec(fd);
    try writeAll(fd, payload);
    try pfs.fsyncChecked(fd);
    _ = pfs.close(fd);

    const completed = try spool.finish();
    try std.testing.expectEqualStrings(existing.id(), completed.receipt.id());
    try std.testing.expectEqualStrings(payload, completed.preview.headSlice());
    try std.testing.expect(!pfs.exists(private_path.ptr));
    spool.deinit();
}

test "external spool post-publish failure rolls back CAS before withholding receipt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var spool = try ExternalSpool.begin(allocator, root);
    const private_path = try allocator.dupeZ(u8, spool.path_z);
    defer allocator.free(private_path);
    const payload = "external-transaction-rollback";
    const fd = pfs.open(spool.path_z.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactTempOpenFailed;
    try pfs.makeCloseOnExec(fd);
    try writeAll(fd, payload);
    try pfs.fsyncChecked(fd);
    _ = pfs.close(fd);

    try std.testing.expectError(
        error.ArtifactSpoolCleanupInjectedFailure,
        spool.finishWithMode(.inject_failure_after_publish),
    );
    const digest = sha256Hex(payload);
    const directory = try artifactDirectory(allocator, root);
    defer allocator.free(directory);
    const final_path = try artifactPath(allocator, directory, digest);
    defer allocator.free(final_path);
    const final_z = try allocator.dupeZ(u8, final_path);
    defer allocator.free(final_z);
    try std.testing.expect(!pfs.exists(final_z.ptr));
    try std.testing.expect(pfs.exists(private_path.ptr));
    spool.deinit();
    try std.testing.expect(!pfs.exists(private_path.ptr));
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
    try pfs.makeCloseOnExec(fd);
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

test "unfinished spool rollback removes private bytes before publication" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var spool = try Spool.begin(allocator, root);
    errdefer spool.deinit();
    const private_path = try allocator.dupeZ(u8, spool.temp_path);
    defer allocator.free(private_path);
    try spool.write("uncommitted-secret");
    try std.testing.expect(pfs.exists(private_path.ptr));
    spool.deinit();
    try std.testing.expect(!pfs.exists(private_path.ptr));
}

test "capture range reads require the sealed state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var capture = try Capture.begin(allocator, root_buffer[0..root_len], 1024);
    defer capture.deinit();
    try capture.write("still-writing");
    try std.testing.expectError(
        error.ArtifactCaptureNotSealed,
        capture.readRangeAlloc(allocator, 0, 1),
    );
    try capture.seal();
    const recovered = try capture.readRangeAlloc(allocator, 0, capture.bytes);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings("still-writing", recovered);
}

test "post-install publication failure removes the unreceipted CAS object" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var spool = try Spool.begin(allocator, root);
    defer spool.deinit();
    try spool.write("rollback-after-install");
    try std.testing.expectError(
        error.ArtifactPublishInjectedFailure,
        spool.finishWithMode(.inject_failure_after_install),
    );

    const digest = sha256Hex("rollback-after-install");
    const directory = try artifactDirectory(allocator, root);
    defer allocator.free(directory);
    const final_path = try artifactPath(allocator, directory, digest);
    defer allocator.free(final_path);
    const final_z = try allocator.dupeZ(u8, final_path);
    defer allocator.free(final_z);
    try std.testing.expect(!pfs.exists(final_z.ptr));
    try std.testing.expectEqual(@as(u64, 0), try directoryBytes(allocator, directory));
}

test "atomic CAS install never replaces a competing content address" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var spool = try Spool.begin(allocator, root);
    defer spool.deinit();
    const payload = "must-not-overwrite-racing-publisher";
    try spool.write(payload);
    try std.testing.expectError(
        error.ArtifactExistingMismatch,
        spool.finishWithMode(.inject_competing_destination),
    );

    const directory = try artifactDirectory(allocator, root);
    defer allocator.free(directory);
    const final_path = try artifactPath(allocator, directory, sha256Hex(payload));
    defer allocator.free(final_path);
    const final_z = try allocator.dupeZ(u8, final_path);
    defer allocator.free(final_z);
    const fd = pfs.open(final_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactSourceOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.makeCloseOnExec(fd);
    var observed: ["competing-cas-object".len]u8 = undefined;
    const count = try pfs.readZ(fd, &observed);
    try std.testing.expectEqual(observed.len, count);
    try std.testing.expectEqualStrings("competing-cas-object", &observed);
}

test "session quota rejects publication and rollback leaves no receipt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    _ = try persist(allocator, root, "seed");
    const directory = try artifactDirectory(allocator, root);
    defer allocator.free(directory);
    const quota_path = try std.fmt.allocPrintSentinel(allocator, "{s}/quota-fixture.blob", .{directory}, 0);
    defer allocator.free(quota_path);
    const fd = pfs.open(quota_path.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, 0o600);
    if (fd < 0) return error.ArtifactTempOpenFailed;
    try pfs.makeCloseOnExec(fd);
    try pfs.setSize(fd, MAX_SESSION_BYTES);
    _ = pfs.close(fd);

    var spool = try Spool.begin(allocator, root);
    errdefer spool.deinit();
    const private_path = try allocator.dupeZ(u8, spool.temp_path);
    defer allocator.free(private_path);
    try spool.write("must-not-publish");
    try std.testing.expectError(error.SessionQuotaExceeded, spool.finish());
    try std.testing.expect(pfs.exists(private_path.ptr));
    spool.deinit();
    try std.testing.expect(!pfs.exists(private_path.ptr));
}

test "parallel publishers converge on one verified content address" {
    const allocator = std.heap.c_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const Worker = struct {
        root: []const u8,
        receipt: ?Receipt = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.receipt = persist(std.heap.c_allocator, self.root, "parallel-identical-payload") catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| {
        worker.* = .{ .root = root };
        threads[index] = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (&threads) |*thread| thread.join();
    const expected = workers[0].receipt orelse return workers[0].failure orelse error.MissingReceipt;
    for (workers[1..]) |worker| {
        if (worker.failure) |failure| return failure;
        const receipt = worker.receipt orelse return error.MissingReceipt;
        try std.testing.expectEqualStrings(expected.id(), receipt.id());
        try std.testing.expectEqual(expected.bytes, receipt.bytes);
    }
    var recovered = try readChunk(allocator, root, expected.id(), 0, MAX_READ_BYTES);
    defer recovered.deinit();
    try std.testing.expectEqualStrings("parallel-identical-payload", recovered.bytes);
}
