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
    transferred: bool = false,
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
        // Close *and* unlink: the file exists from the moment `open` with
        // CREAT succeeds, so a failure in any of the three checks below used to
        // leave `stream-*.tmp` behind. That was survivable while such a failure
        // aborted the tool; now that a publication failure degrades to inline
        // and execution continues, a repeating cause would accumulate orphans.
        errdefer {
            _ = pfs.close(fd);
            pfs.unlinkPath(temp_path.ptr) catch {};
        }
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
        var sealed = try self.seal();
        const completed = sealed.publishWithMode(mode) catch |err| {
            // A failed publication leaves the private file to `Spool.deinit`,
            // exactly as before the seal/publish split (#45): a caller that
            // inspects the temp path after a failure still finds it there.
            self.reclaim(&sealed);
            return err;
        };
        sealed.deinit();
        self.published = true;
        return completed;
    }

    /// Take the buffers back from a sealed handle whose publication failed, so
    /// this Spool owns the private file again and `deinit` removes it. The
    /// handle is consumed.
    fn reclaim(self: *Spool, sealed: *SealedSpool) void {
        self.session_root = sealed.session_root;
        self.directory = sealed.directory;
        self.temp_path = sealed.temp_path;
        self.transferred = false;
        sealed.* = undefined;
    }

    /// Close and validate the private stream without publishing it. The sealed
    /// file remains in the spool directory (which `directoryBytes` never scans)
    /// until publication or discard, keeping quota admission atomic with the
    /// eventual conversation reference (#45).
    pub fn seal(self: *Spool) !SealedSpool {
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
        self.transferred = true;
        return .{
            .allocator = self.allocator,
            .session_root = self.session_root,
            .directory = self.directory,
            .temp_path = self.temp_path,
            .snapshot = snapshot,
            .preview = self.preview,
            .temp_identity = temp_identity,
        };
    }

    pub fn deinit(self: *Spool) void {
        if (self.transferred) {
            self.* = undefined;
            return;
        }
        if (self.fd_open) _ = pfs.close(self.fd);
        if (!self.published) pfs.unlinkPath(self.temp_path.ptr) catch {};
        self.allocator.free(self.temp_path);
        self.allocator.free(self.directory);
        self.allocator.free(self.session_root);
        self.* = undefined;
    }
};

/// A validated, unpublished spool. Its temporary file is outside the scanned
/// CAS quota; ownership transfers from `Spool` until publish/discard (#45).
pub const SealedSpool = struct {
    allocator: std.mem.Allocator,
    session_root: []u8,
    directory: []u8,
    temp_path: [:0]u8,
    snapshot: FileSnapshot,
    preview: Preview,
    temp_identity: pfs.FileInfo,
    state: enum { sealed, published, discarded } = .sealed,

    pub fn receipt(self: *const SealedSpool) Receipt {
        return receiptFor(self.snapshot);
    }

    /// Re-home this sealed handle into `allocator` so it can escape a dispatch
    /// arena with the other `.done` fields. The source strings are released and
    /// the source must not be used afterwards; the on-disk temp file is untouched.
    pub fn adopt(self: *SealedSpool, allocator: std.mem.Allocator) !SealedSpool {
        const root = try allocator.dupe(u8, self.session_root);
        errdefer allocator.free(root);
        const directory = try allocator.dupe(u8, self.directory);
        errdefer allocator.free(directory);
        const temp = try allocator.dupeZ(u8, self.temp_path);
        errdefer allocator.free(temp);
        const source_allocator = self.allocator;
        source_allocator.free(self.session_root);
        source_allocator.free(self.directory);
        source_allocator.free(self.temp_path);
        const snapshot = self.snapshot;
        const preview = self.preview;
        const temp_identity = self.temp_identity;
        const state = self.state;
        self.* = undefined;
        return .{
            .allocator = allocator,
            .session_root = root,
            .directory = directory,
            .temp_path = temp,
            .snapshot = snapshot,
            .preview = preview,
            .temp_identity = temp_identity,
            .state = state,
        };
    }
    pub fn readAllAlloc(self: *const SealedSpool, allocator: std.mem.Allocator) ![]u8 {
        if (self.state != .sealed) return error.ArtifactSpoolClosed;
        const path_z = try allocator.dupeZ(u8, self.temp_path);
        defer allocator.free(path_z);
        const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
        if (fd < 0) return error.ArtifactSourceOpenFailed;
        defer _ = pfs.close(fd);
        const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
        if (!sameFile(info, self.temp_identity) or info.size != self.snapshot.bytes) return error.ArtifactSourceChanged;
        const out = try allocator.alloc(u8, @intCast(self.snapshot.bytes));
        errdefer allocator.free(out);
        var off: usize = 0;
        while (off < out.len) {
            const n = pfs.readZ(fd, out[off..]) catch return error.ArtifactReadFailed;
            if (n == 0) return error.ArtifactSourceChanged;
            off += n;
        }
        return out;
    }
    pub fn previewValue(self: *const SealedSpool) Preview {
        return self.preview;
    }
    pub fn publish(self: *SealedSpool) !CompletedSpool {
        return self.publishWithMode(.normal);
    }
    fn publishWithMode(self: *SealedSpool, mode: Spool.PublishMode) !CompletedSpool {
        if (self.state != .sealed) return error.ArtifactSpoolClosed;
        const artifact_directory = try artifactDirectory(self.allocator, self.session_root);
        defer self.allocator.free(artifact_directory);
        try ensureSecureDirectory(self.allocator, self.session_root, artifact_directory);

        persist_mutex.lock();
        defer persist_mutex.unlock();

        const final_path = try artifactPath(self.allocator, artifact_directory, self.snapshot.sha256);
        defer self.allocator.free(final_path);
        if (try verifyExisting(self.allocator, final_path, self.snapshot.sha256, @intCast(self.snapshot.bytes))) {
            pfs.unlinkPath(self.temp_path.ptr) catch return error.ArtifactSpoolCleanupFailed;
            try fsyncDirectory(self.allocator, self.directory);
            self.state = .published;
            return .{ .receipt = self.receipt(), .preview = self.preview };
        }
        try reserveQuota(self.allocator, artifact_directory, self.snapshot.bytes);

        try publishPreparedFile(
            self.allocator,
            self.temp_path,
            final_path,
            artifact_directory,
            self.directory,
            self.snapshot,
            self.temp_identity,
            mode,
        );
        commitQuota(artifact_directory, self.snapshot.bytes);
        self.state = .published;
        return .{ .receipt = self.receipt(), .preview = self.preview };
    }

    pub fn discard(self: *SealedSpool) void {
        if (self.state != .sealed) return;
        pfs.unlinkPath(self.temp_path.ptr) catch {};
        self.state = .discarded;
    }
    pub fn deinit(self: *SealedSpool) void {
        if (self.state == .sealed) pfs.unlinkPath(self.temp_path.ptr) catch {};
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
    try reserveQuota(allocator, directory, expected.bytes);

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
    // Every rollback path above has been passed: the bytes are durable, so the
    // gauge may finally count them.
    commitQuota(directory, expected.bytes);
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

/// Stable, model-visible reason a publish failed. Lives here rather than in
/// the projection layer because both envelope families need the same names:
/// a Bash channel that could not publish used to report `recoverable:false`
/// with no reason at all, so an operator could not tell a full disk from a
/// session whose 1GiB quota is permanently exhausted.
pub fn storageErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ArtifactRootUnavailable => "artifact_store_unavailable",
        error.ArtifactTooLarge => "artifact_too_large",
        error.SessionQuotaExceeded => "artifact_session_quota_exceeded",
        error.ArtifactPathSymlink,
        error.ArtifactDirectoryUnsafe,
        error.ArtifactUnsafeFile,
        error.ArtifactDirectoryUntrusted,
        => "artifact_store_unsafe",
        else => "artifact_persist_failed",
    };
}

/// Last observed session usage, kept only so approaching the quota is
/// visible. It is **not** an admission cache.
///
/// A cached total would make the quota check O(1) instead of O(artifacts),
/// but it can only ever be a lower bound: a session root is shared with
/// subagents and out-of-process swarm teammates, and their publishes are
/// invisible here. Trusting it would let a session grow past the quota
/// exactly when another writer is active. The scan it would replace is a few
/// thousand syscalls in the worst realistic session — noise beside the model
/// round trip that produced the result — so the check stays exact and the
/// cache stays telemetry.
const QuotaCache = struct {
    /// Which store the figure belongs to. A process publishes into more than
    /// one session root - subagents and swarm teammates each have their own -
    /// so a reading without an identity is a number that silently belongs to
    /// somebody else.
    key: u64 = 0,
    used: u64 = 0,
    valid: bool = false,
};

fn usageKey(directory: []const u8) u64 {
    return std.hash.Wyhash.hash(0, directory);
}

/// Guarded by `persist_mutex`, which every quota check already holds.
var quota_cache: QuotaCache = .{};

pub const SessionUsage = struct {
    used_bytes: u64,
    limit_bytes: u64,
    /// False when nothing has been published in this process yet, so a caller
    /// reports "unknown" instead of a confident zero.
    observed: bool,
};

/// Last observed usage for `session_root`. Cheap: never scans; reports the
/// total measured by the most recent publish **into that store**, and reports
/// `observed = false` for any other one rather than handing back a subagent's
/// figure as this session's. Telemetry only, never an admission decision.
pub fn sessionUsage(session_root: []const u8) SessionUsage {
    const unobserved: SessionUsage = .{ .used_bytes = 0, .limit_bytes = MAX_SESSION_BYTES, .observed = false };
    if (session_root.len == 0) return unobserved;
    var buffer: [std.fs.max_path_bytes + ARTIFACT_SUBDIR.len + 1]u8 = undefined;
    const directory = artifactDirectoryBuf(&buffer, session_root) catch return unobserved;
    persist_mutex.lock();
    defer persist_mutex.unlock();
    if (!quota_cache.valid or quota_cache.key != usageKey(directory)) return unobserved;
    return .{
        .used_bytes = quota_cache.used,
        .limit_bytes = MAX_SESSION_BYTES,
        .observed = true,
    };
}

/// Admission check for `incoming` bytes into `directory`, and the one place
/// session usage is observed. Caller holds `persist_mutex`.
///
/// Records only what the scan actually measured. Counting `incoming` here as
/// well would be optimistic: publishing can still fail afterwards - the source
/// open, the copy, the rename, the directory fsync - and the file is then
/// rolled back while the gauge keeps reporting bytes that do not exist, until
/// the next successful publish happens to correct it. `commitQuota` adds them
/// once the bytes are really on disk.
fn reserveQuota(allocator: std.mem.Allocator, directory: []const u8, incoming: u64) !void {
    const key = usageKey(directory);
    const used = try directoryBytes(allocator, directory);
    if (incoming > MAX_SESSION_BYTES -| used) {
        quota_cache = .{ .key = key, .used = used, .valid = true };
        return error.SessionQuotaExceeded;
    }
    quota_cache = .{ .key = key, .used = used, .valid = true };
}

/// Account `incoming` bytes that a publish has just made durable. Caller holds
/// `persist_mutex`, and must call this only after the file is in place.
fn commitQuota(directory: []const u8, incoming: u64) void {
    const key = usageKey(directory);
    if (!quota_cache.valid or quota_cache.key != key) return;
    quota_cache.used +|= incoming;
}

/// Resolve a published artifact to its on-disk blob so a search tool can run
/// over it in place.
///
/// `ReadArtifact` can only hand back byte ranges, which makes recovering a
/// large result O(size / MAX_READ_BYTES) round trips and cannot answer a
/// question about the content at all. The blob is an ordinary file, so a
/// search tool can answer in one call - but the path must never reach the
/// model: it names the kernel-private store, and exposing it would let any
/// file tool read blobs outside the bounded recovery contract. Callers pass
/// this straight to a child process and keep it out of the result.
pub fn resolveSearchPath(
    allocator: std.mem.Allocator,
    session_root: []const u8,
    artifact_id: []const u8,
) ![]u8 {
    if (session_root.len == 0) return error.ArtifactRootUnavailable;
    const digest = parseArtifactId(artifact_id) orelse return error.InvalidArtifactId;
    const directory = try artifactDirectory(allocator, session_root);
    defer allocator.free(directory);
    try validateSecureDirectory(allocator, session_root, directory);
    const path = try artifactPath(allocator, directory, digest);
    errdefer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactNotFound;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!safeArtifactInfo(info)) return error.ArtifactUnsafeFile;
    return path;
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

const ARTIFACT_SUBDIR = "/tool-results/sha256";

fn artifactDirectory(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}" ++ ARTIFACT_SUBDIR, .{root});
}

/// The same path without an allocation, for callers on a cheap path. Both go
/// through `ARTIFACT_SUBDIR` so a layout change cannot move only one of them.
fn artifactDirectoryBuf(buffer: []u8, root: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}" ++ ARTIFACT_SUBDIR, .{root});
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

/// Test-only: entries in `directory` other than `.`/`..`; a directory that does
/// not exist counts as empty, which is what "nothing left behind" means.
fn testCountEntries(allocator: std.mem.Allocator, directory: []const u8) !usize {
    const directory_z = try allocator.dupeZ(u8, directory);
    defer allocator.free(directory_z);
    var iterator = pdir.open(directory_z.ptr) orelse return 0;
    defer pdir.close(&iterator);
    var count: usize = 0;
    while (pdir.next(&iterator)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

const SealedTestRoot = struct {
    tmp: std.testing.TmpDir,
    buffer: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init() !SealedTestRoot {
        var self = SealedTestRoot{ .tmp = std.testing.tmpDir(.{}) };
        errdefer self.tmp.cleanup();
        self.len = try self.tmp.dir.realPath(std.testing.io, &self.buffer);
        return self;
    }

    fn root(self: *const SealedTestRoot) []const u8 {
        return self.buffer[0..self.len];
    }

    fn expectNothingLeftBehind(self: *const SealedTestRoot, allocator: std.mem.Allocator, expected_blobs: usize) !void {
        const spool_dir = try spoolDirectory(allocator, self.root());
        defer allocator.free(spool_dir);
        const artifact_dir = try artifactDirectory(allocator, self.root());
        defer allocator.free(artifact_dir);
        try std.testing.expectEqual(@as(usize, 0), try testCountEntries(allocator, spool_dir));
        try std.testing.expectEqual(expected_blobs, try testCountEntries(allocator, artifact_dir));
    }

    fn deinit(self: *SealedTestRoot) void {
        self.tmp.cleanup();
    }
};

test "sealed spool: seal then publish equals finish" {
    const a = std.testing.allocator;
    var fixture = try SealedTestRoot.init();
    defer fixture.deinit();
    const payload = "sealed-equals-finished";

    var finished = try Spool.begin(a, fixture.root());
    defer finished.deinit();
    try finished.write(payload);
    const via_finish = try finished.finish();

    var spool = try Spool.begin(a, fixture.root());
    defer spool.deinit();
    try spool.write(payload);
    var sealed = try spool.seal();
    defer sealed.deinit();
    const via_seal = try sealed.publish();

    try std.testing.expectEqualStrings(via_finish.receipt.id(), via_seal.receipt.id());
    try std.testing.expectEqual(via_finish.receipt.bytes, via_seal.receipt.bytes);
    var chunk = try readChunk(a, fixture.root(), via_seal.receipt.id(), 0, payload.len);
    defer chunk.deinit();
    try std.testing.expectEqualStrings(payload, chunk.bytes);
    // Same bytes, same id: one blob, and no private files left in the spool.
    try fixture.expectNothingLeftBehind(a, 1);
}

test "sealed spool: seal then discard leaves nothing behind" {
    const a = std.testing.allocator;
    var fixture = try SealedTestRoot.init();
    defer fixture.deinit();
    var spool = try Spool.begin(a, fixture.root());
    defer spool.deinit();
    try spool.write("discarded");
    var sealed = try spool.seal();
    defer sealed.deinit();
    sealed.discard();
    try fixture.expectNothingLeftBehind(a, 0);
}

test "sealed spool: deinit without publish discards" {
    const a = std.testing.allocator;
    var fixture = try SealedTestRoot.init();
    defer fixture.deinit();
    var spool = try Spool.begin(a, fixture.root());
    defer spool.deinit();
    try spool.write("dropped on the floor");
    var sealed = try spool.seal();
    sealed.deinit();
    try fixture.expectNothingLeftBehind(a, 0);
}

test "sealed spool: receipt is known before publication" {
    const a = std.testing.allocator;
    var fixture = try SealedTestRoot.init();
    defer fixture.deinit();
    const payload = "receipt-before-publish";
    var spool = try Spool.begin(a, fixture.root());
    defer spool.deinit();
    try spool.write(payload);
    var sealed = try spool.seal();
    defer sealed.deinit();
    const before = sealed.receipt();
    const expected_hex = sha256Hex(payload);
    try std.testing.expectEqualStrings(ID_PREFIX ++ expected_hex, before.id());
    try std.testing.expectEqual(@as(u64, payload.len), before.bytes);
    const published = try sealed.publish();
    try std.testing.expectEqualStrings(before.id(), published.receipt.id());
    try std.testing.expectEqual(before.bytes, published.receipt.bytes);
}

test "sealed spool: identical bytes dedup to one blob" {
    const a = std.testing.allocator;
    var fixture = try SealedTestRoot.init();
    defer fixture.deinit();
    const payload = "twins";
    var first = try Spool.begin(a, fixture.root());
    defer first.deinit();
    try first.write(payload);
    var second = try Spool.begin(a, fixture.root());
    defer second.deinit();
    try second.write(payload);
    var first_sealed = try first.seal();
    defer first_sealed.deinit();
    var second_sealed = try second.seal();
    defer second_sealed.deinit();
    const first_done = try first_sealed.publish();
    const second_done = try second_sealed.publish();
    try std.testing.expectEqualStrings(first_done.receipt.id(), second_done.receipt.id());
    try fixture.expectNothingLeftBehind(a, 1);
}

test "sealed spool: publish after discard or after publish fails closed" {
    const a = std.testing.allocator;
    var fixture = try SealedTestRoot.init();
    defer fixture.deinit();

    var discarded_source = try Spool.begin(a, fixture.root());
    defer discarded_source.deinit();
    try discarded_source.write("discard me");
    var discarded = try discarded_source.seal();
    defer discarded.deinit();
    discarded.discard();
    try std.testing.expectError(error.ArtifactSpoolClosed, discarded.publish());

    var published_source = try Spool.begin(a, fixture.root());
    defer published_source.deinit();
    try published_source.write("publish me once");
    var published = try published_source.seal();
    defer published.deinit();
    _ = try published.publish();
    try std.testing.expectError(error.ArtifactSpoolClosed, published.publish());
    try fixture.expectNothingLeftBehind(a, 1);
}

test "sealed spool: readAllAlloc returns the sealed bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &b);
    var s = try Spool.begin(std.testing.allocator, b[0..n]);
    try s.write("sealed-bytes");
    var sealed = try s.seal();
    defer sealed.deinit();
    const bytes = try sealed.readAllAlloc(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("sealed-bytes", bytes);
    sealed.discard();
    try std.testing.expectError(error.ArtifactSpoolClosed, sealed.readAllAlloc(std.testing.allocator));
}

test "sealed spool: adopt re-homes the handle into another allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &b);
    var source = try Spool.begin(arena.allocator(), b[0..n]);
    try source.write("adopted");
    var sealed = try source.seal();
    source.deinit();
    var adopted = try sealed.adopt(std.testing.allocator);
    defer adopted.deinit();
    const completed = try adopted.publish();
    var chunk = try readChunk(std.testing.allocator, b[0..n], completed.receipt.id(), 0, 7);
    defer chunk.deinit();
    try std.testing.expectEqualStrings("adopted", chunk.bytes);
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

test "session usage is observable without a second scan" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var payload: [4096]u8 = undefined;
    @memset(&payload, 'Q');
    const first = try persist(allocator, root, &payload);
    const after_first = sessionUsage(root);
    try std.testing.expect(after_first.observed);
    try std.testing.expectEqual(MAX_SESSION_BYTES, after_first.limit_bytes);
    try std.testing.expectEqual(first.bytes, after_first.used_bytes);

    // A second, different artifact accumulates.
    payload[0] = 'R';
    const second = try persist(allocator, root, &payload);
    const after_second = sessionUsage(root);
    try std.testing.expectEqual(after_first.used_bytes + second.bytes, after_second.used_bytes);

    // Re-publishing identical content is deduplicated by the CAS and must not
    // double-count.
    _ = try persist(allocator, root, &payload);
    try std.testing.expectEqual(after_second.used_bytes, sessionUsage(root).used_bytes);
}

test "session usage belongs to the store it was measured in" {
    // One process publishes into several session roots - every subagent and
    // swarm teammate has its own. A single global figure reported as "this
    // session's" is whichever store happened to publish last, so the gauge is
    // keyed and a root it has not measured reads as unknown, not as zero and
    // not as somebody else's total.
    const allocator = std.testing.allocator;
    var mine = std.testing.tmpDir(.{});
    defer mine.cleanup();
    var theirs = std.testing.tmpDir(.{});
    defer theirs.cleanup();
    var mine_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var theirs_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const mine_root = mine_buffer[0..try mine.dir.realPath(std.testing.io, &mine_buffer)];
    const theirs_root = theirs_buffer[0..try theirs.dir.realPath(std.testing.io, &theirs_buffer)];

    var payload: [2048]u8 = undefined;
    @memset(&payload, 'M');
    _ = try persist(allocator, mine_root, &payload);
    try std.testing.expect(sessionUsage(mine_root).observed);
    try std.testing.expect(!sessionUsage(theirs_root).observed);

    @memset(&payload, 'T');
    const theirs_receipt = try persist(allocator, theirs_root, &payload);
    try std.testing.expect(!sessionUsage(mine_root).observed);
    const after = sessionUsage(theirs_root);
    try std.testing.expect(after.observed);
    try std.testing.expectEqual(theirs_receipt.bytes, after.used_bytes);

    // No root at all is unknown too, never a confident zero.
    try std.testing.expect(!sessionUsage("").observed);
}

test "a store grown by another writer is still observed by the quota check" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    // Seed the in-process cache with a small, honest total.
    var payload: [1024]u8 = undefined;
    @memset(&payload, 'S');
    _ = try persist(allocator, root, &payload);

    // Now grow the store behind this process's back, the way a subagent or an
    // out-of-process swarm teammate sharing the session root would. The check
    // must observe the real directory rather than its own arithmetic — which
    // is why the usage cache is telemetry only.
    const directory = try artifactDirectory(allocator, root);
    defer allocator.free(directory);
    const filler = try std.fmt.allocPrintSentinel(allocator, "{s}/quota-fixture.blob", .{directory}, 0);
    defer allocator.free(filler);
    const fd = pfs.open(filler.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    if (fd < 0) return error.OpenFailed;
    try pfs.setSize(fd, MAX_SESSION_BYTES);
    _ = pfs.close(fd);

    payload[0] = 'T';
    try std.testing.expectError(error.SessionQuotaExceeded, persist(allocator, root, &payload));
}

test "a publish that rolls back does not leave its bytes in the usage gauge" {
    // The gauge used to be credited at admission time, before the source open,
    // the copy, the rename and the directory fsync had all succeeded. Any of
    // those can still fail and roll the file back, and the gauge then reported
    // bytes that do not exist on disk until some later publish happened to
    // correct it - a "how close am I to the quota" number that overstates.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    var settled: [4096]u8 = undefined;
    @memset(&settled, 'K');
    const first = try persist(allocator, root, &settled);
    const after_success = sessionUsage(root);
    try std.testing.expect(after_success.observed);
    try std.testing.expectEqual(first.bytes, after_success.used_bytes);

    // A publish that gets all the way to the CAS and is then rolled back.
    var spool = try ExternalSpool.begin(allocator, root);
    defer spool.deinit();
    const payload = "rolled-back-bytes-must-not-be-counted";
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

    // The rolled-back bytes are gone from disk, so they must be gone from the
    // gauge too - it reports what the last scan actually measured.
    const after_rollback = sessionUsage(root);
    try std.testing.expect(after_rollback.observed);
    try std.testing.expectEqual(first.bytes, after_rollback.used_bytes);
    try std.testing.expect(after_rollback.used_bytes < first.bytes + payload.len);
}
