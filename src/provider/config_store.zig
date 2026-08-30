//! Atomic, revisioned writer for control-plane documents (issue #16, "Write
//! and crash-safety contract").
//!
//! One writer owns `~/.metacodes/config.json`'s control-plane keys and any
//! durable per-session `runtime-selection.json`. Every commit:
//!
//! 1. takes the cross-process lock for that path;
//! 2. re-reads the document (read-modify-write — never a blind overwrite);
//! 3. replays idempotently when the operation id matches the last commit;
//! 4. rejects a stale `expected_config_revision` with a deterministic conflict;
//! 5. applies the mutation, bumps the revision, and merges only the keys this
//!    module owns;
//! 6. writes a same-directory temporary file, fsyncs it, renames it over the
//!    target, then fsyncs the parent directory.
//!
//! A crash therefore leaves either the previous complete document or the next
//! complete one — never a half-merged provider/model/control selection. The
//! `crash_after` hook exists so that claim is a test, not a comment.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const fs_util = @import("../util/fs.zig");
const file_lock = @import("../swarm/file_lock.zig");
const config_doc = @import("config_doc.zig");
const ids = @import("ids.zig");

pub const Document = config_doc.Document;
pub const ConfigRevision = ids.ConfigRevision;

pub const CONFIG_PATH_ENV = "METACODES_CONFIG_FILE";

/// Fault-injection point, used only by crash-safety tests.
pub const CrashPoint = enum {
    /// After the temporary file is written but before it is fsynced.
    after_temp_write,
    /// After the temporary file is durable but before the rename.
    before_rename,
};

pub const StoreError = error{
    RevisionConflict,
    NoHome,
    PathTooLong,
    LockBusy,
    OpenFailed,
    WriteFailed,
    SyncFailed,
    RenameFailed,
    CrashInjected,
    MutationFailed,
} || config_doc.DocumentError;

pub const Mutation = struct {
    ctx: *anyopaque,
    applyFn: *const fn (ctx: *anyopaque, document: *Document) anyerror!void,

    pub fn apply(self: Mutation, document: *Document) anyerror!void {
        return self.applyFn(self.ctx, document);
    }
};

pub const CommitRequest = struct {
    /// Optimistic concurrency. Null skips the check, which is only correct for
    /// a first write or a caller that has just loaded the document.
    expected_config_revision: ?ConfigRevision = null,
    /// Idempotency key. A retry with the same key returns the existing revision
    /// instead of applying the mutation twice.
    operation_id: ?[]const u8 = null,
    mutation: Mutation,
};

pub const CommitResult = struct {
    config_revision: ConfigRevision,
    /// True when the commit was recognized as a retry and nothing was written.
    idempotent_replay: bool = false,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    /// Test-only fault injection.
    crash_after: ?CrashPoint = null,

    pub fn initPath(allocator: std.mem.Allocator, path: []const u8) StoreError!Store {
        return .{ .allocator = allocator, .path = try allocator.dupe(u8, path) };
    }

    /// `~/.metacodes/config.json`, or `METACODES_CONFIG_FILE` when set.
    pub fn initHome(allocator: std.mem.Allocator) StoreError!Store {
        if (std.c.getenv(CONFIG_PATH_ENV)) |raw| {
            return initPath(allocator, std.mem.span(raw));
        }
        const home = @import("platform").paths.homeDir() orelse return error.NoHome;
        const path = std.fmt.allocPrint(allocator, "{s}/.metacodes/config.json", .{home}) catch
            return error.OutOfMemory;
        return .{ .allocator = allocator, .path = path };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Read the current document. A missing file is an empty document, not an
    /// error: a fresh installation has no control-plane state yet.
    pub fn load(self: *const Store) StoreError!Document {
        const text = try self.readAll();
        defer self.allocator.free(text);
        return config_doc.parse(self.allocator, text);
    }

    pub fn commit(self: *const Store, request: CommitRequest) StoreError!CommitResult {
        var lock = file_lock.acquire(self.path, .{}) catch |err| switch (err) {
            error.LockBusy => return error.LockBusy,
            error.PathTooLong => return error.PathTooLong,
            // A missing parent directory is created below, then retried once.
            error.NoParentDir => blk: {
                try self.ensureParent();
                break :blk file_lock.acquire(self.path, .{}) catch return error.LockBusy;
            },
        };
        defer lock.release();

        const original = try self.readAll();
        defer self.allocator.free(original);

        var document = try config_doc.parse(self.allocator, original);
        defer document.deinit();

        if (request.operation_id) |operation_id| {
            if (document.last_operation_id) |previous| {
                if (previous.eqlText(operation_id)) {
                    return .{ .config_revision = document.config_revision, .idempotent_replay = true };
                }
            }
        }

        if (request.expected_config_revision) |expected| {
            if (expected.value() != document.config_revision.value()) return error.RevisionConflict;
        }

        request.mutation.apply(&document) catch return error.MutationFailed;

        document.config_revision = document.config_revision.next();
        document.last_operation_id = if (request.operation_id) |operation_id|
            try config_doc.OperationId.parse(operation_id)
        else
            null;

        const bytes = try document.merge(original);
        defer self.allocator.free(bytes);
        try self.writeAtomic(bytes);

        return .{ .config_revision = document.config_revision };
    }

    fn readAll(self: *const Store) StoreError![]u8 {
        const path_z = self.allocator.dupeZ(u8, self.path) catch return error.OutOfMemory;
        defer self.allocator.free(path_z);
        const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
        if (fd < 0) return self.allocator.dupe(u8, "") catch error.OutOfMemory;
        defer pfs.close(fd);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const read = pfs.read(fd, &buffer);
            if (read < 0) return error.OpenFailed;
            if (read == 0) break;
            out.appendSlice(self.allocator, buffer[0..@intCast(read)]) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice(self.allocator) catch error.OutOfMemory;
    }

    fn ensureParent(self: *const Store) StoreError!void {
        const parent = std.fs.path.dirname(self.path) orelse return;
        fs_util.mkdirParents(parent) catch return error.OpenFailed;
    }

    fn writeAtomic(self: *const Store, bytes: []const u8) StoreError!void {
        try self.ensureParent();

        // Same directory, so the rename stays within one filesystem and is
        // therefore atomic.
        const temp_path = std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}.tmp",
            .{self.path},
            0,
        ) catch return error.OutOfMemory;
        defer self.allocator.free(temp_path);
        const final_path = self.allocator.dupeZ(u8, self.path) catch return error.OutOfMemory;
        defer self.allocator.free(final_path);

        {
            const fd = pfs.open(
                temp_path,
                .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                @as(c_uint, 0o600),
            );
            if (fd < 0) return error.OpenFailed;
            defer pfs.close(fd);
            const written = pfs.write(fd, bytes);
            if (written < 0 or @as(usize, @intCast(written)) != bytes.len) return error.WriteFailed;
            if (self.crash_after == .after_temp_write) return error.CrashInjected;
            pfs.fsyncChecked(fd) catch return error.SyncFailed;
        }

        if (self.crash_after == .before_rename) return error.CrashInjected;

        if (pfs.renameReplace(temp_path, final_path) != 0) return error.RenameFailed;

        // Without a parent-directory fsync the rename itself can be lost on a
        // power failure even though the file contents are durable.
        try self.syncParent();
    }

    fn syncParent(self: *const Store) StoreError!void {
        if (builtin.os.tag == .windows) return; // Directories are not fsyncable there.
        const parent = std.fs.path.dirname(self.path) orelse return;
        const parent_z = self.allocator.dupeZ(u8, parent) catch return error.OutOfMemory;
        defer self.allocator.free(parent_z);
        const fd = pfs.open(parent_z, .{ .ACCMODE = .RDONLY }, 0);
        if (fd < 0) return; // Best effort: the file itself is already durable.
        defer pfs.close(fd);
        pfs.fsyncChecked(fd) catch return error.SyncFailed;
    }
};

/// Convenience wrapper for the common "replace the global selection" mutation.
pub fn setGlobalSelection(
    store: *const Store,
    selection: config_doc.RuntimeSelection,
    expected: ?ConfigRevision,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        value: config_doc.RuntimeSelection,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            document.global_selection = self.value;
        }
    };
    var apply = Apply{ .value = selection };
    return store.commit(.{
        .expected_config_revision = expected,
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
}
