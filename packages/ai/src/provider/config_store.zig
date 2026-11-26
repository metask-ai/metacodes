//! Atomic, revisioned writer for control-plane documents (issue #16, "Write
//! and crash-safety contract").
//!
//! One writer owns `<state root>/config.json`'s control-plane keys and any
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
const util_fs = @import("metacodes-base").util.fs;
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const fs_util = @import("metacodes-base").util.fs;
const file_lock = @import("metacodes-base").util.file_lock;
const json_merge = @import("metacodes-base").util.json_merge;
const config_doc = @import("config_doc.zig");
const ids = @import("ids.zig");

pub const Document = config_doc.Document;
pub const ConfigRevision = ids.ConfigRevision;
pub const MemberField = json_merge.MemberField;

/// The section `metacodes providers` writes one member of
/// (`custom_provider.zig` owns its schema).
pub const CUSTOM_PROVIDERS_KEY = "custom_providers";

pub const CONFIG_PATH_ENV = "METACODES_CONFIG_FILE";

/// Filename of the session-scoped selection document. It sits beside the
/// session's own transcript instead of inside `config.json` so two concurrent
/// sessions cannot overwrite each other's choice.
pub const SESSION_SELECTION_FILE = "runtime-selection.json";

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
    ReadFailed,
    WriteFailed,
    SyncFailed,
    RenameFailed,
    CrashInjected,
    MutationFailed,
    /// An empty idempotency key would be recorded and then match every other
    /// empty key, silently turning unrelated commits into replays.
    InvalidOperationId,
    /// The request's `validate` refused the document the commit would have
    /// written; nothing was written. The validator keeps its own reason.
    Rejected,
} || config_doc.DocumentError;

pub const Mutation = struct {
    ctx: *anyopaque,
    applyFn: *const fn (ctx: *anyopaque, document: *Document) anyerror!void,

    pub fn apply(self: Mutation, document: *Document) anyerror!void {
        return self.applyFn(self.ctx, document);
    }
};

/// A check of the complete document a commit is about to write.
pub const Validator = struct {
    ctx: *anyopaque,
    validateFn: *const fn (ctx: *anyopaque, document_text: []const u8) anyerror!void,

    pub fn check(self: Validator, document_text: []const u8) anyerror!void {
        return self.validateFn(self.ctx, document_text);
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
    /// Members of objects `Document` does not model, written in the same
    /// commit: `custom_providers.<id>` (`putCustomProvider`). Each replaces
    /// or deletes exactly its member; the object's other members, and every
    /// other key, keep their content and order.
    member_edits: []const MemberField = &.{},
    /// Runs on the complete document text that would be written, under the
    /// lock and after the re-read, so it judges exactly the bytes that land
    /// and no other writer can change them in between. An error leaves the
    /// file as it was (`error.Rejected`).
    validate: ?Validator = null,
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

    /// `METACODES_CONFIG_FILE` when set, else `<state_root>/config.json`; an
    /// empty root is `error.NoHome`.
    pub fn initHome(allocator: std.mem.Allocator, state_root: []const u8) StoreError!Store {
        if (std.c.getenv(CONFIG_PATH_ENV)) |raw| {
            return initPath(allocator, std.mem.span(raw));
        }
        if (state_root.len == 0) return error.NoHome;
        const path = std.fs.path.join(allocator, &.{ state_root, "config.json" }) catch return error.OutOfMemory;
        return .{ .allocator = allocator, .path = path };
    }

    /// `<session_dir>/runtime-selection.json`. The caller owns the session
    /// directory layout; this module only names the file inside it.
    pub fn initSessionFile(allocator: std.mem.Allocator, session_dir: []const u8) StoreError!Store {
        const path = std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ session_dir, SESSION_SELECTION_FILE },
        ) catch return error.OutOfMemory;
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
            if (operation_id.len == 0) return error.InvalidOperationId;
            if (document.hasOperation(operation_id)) {
                return .{ .config_revision = document.config_revision, .idempotent_replay = true };
            }
        }

        if (request.expected_config_revision) |expected| {
            if (expected.value() != document.config_revision.value()) return error.RevisionConflict;
        }

        request.mutation.apply(&document) catch return error.MutationFailed;

        document.config_revision = document.config_revision.next();
        // A commit without a key records nothing; it must not evict the keys
        // that make earlier retries recognizable.
        if (request.operation_id) |operation_id| try document.recordOperation(operation_id);

        const bytes = try document.mergeWith(original, request.member_edits);
        defer self.allocator.free(bytes);
        if (request.validate) |validator| validator.check(bytes) catch return error.Rejected;
        try self.writeAtomic(bytes);

        return .{ .config_revision = document.config_revision };
    }

    /// Raw document text. Callers that need a key this module does not model
    /// (the `custom_providers` section, for one) parse it themselves rather
    /// than forcing every such key through `Document`.
    pub fn readText(self: *const Store) StoreError![]u8 {
        return self.readAll();
    }

    fn readAll(self: *const Store) StoreError![]u8 {
        const path_z = self.allocator.dupeZ(u8, self.path) catch return error.OutOfMemory;
        defer self.allocator.free(path_z);
        const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
        if (fd < 0) {
            // Only a genuinely absent file is an empty document. Treating a
            // permission or I/O error the same way would make the next commit
            // overwrite a document it could not read.
            if (!pfs.lastErrnoIs(.NOENT)) return error.OpenFailed;
            return self.allocator.dupe(u8, "") catch error.OutOfMemory;
        }
        defer pfs.close(fd);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const read = pfs.read(fd, &buffer);
            if (read < 0) return error.ReadFailed;
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

        // Any failure after this point leaves a partial temporary behind; drop
        // it so the next commit cannot inherit half a document, and so a crash
        // test observes the same directory state a real crash would leave.
        errdefer pfs.unlinkPath(temp_path) catch {};

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

/// Enable or disable one provider instance.
///
/// Disabling preserves the instance's configuration and credential references,
/// which is the whole difference between "off for now" and "removed".
pub fn setProviderEnabled(
    store: *const Store,
    id: ids.Slug,
    enabled: bool,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        id: ids.Slug,
        enabled: bool,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (document.providers.items) |*entry| {
                if (!entry.id.eql(self.id)) continue;
                entry.enabled = self.enabled;
                return;
            }
            // Recording the state for a provider with no entry yet is what
            // makes "disable a built-in provider" expressible at all.
            try document.upsertProvider(.{ .id = self.id, .enabled = self.enabled });
        }
    };
    var apply = Apply{ .id = id, .enabled = enabled };
    return store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
}

/// Remove one provider instance's configuration entirely.
pub fn removeProvider(
    store: *const Store,
    id: ids.Slug,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        id: ids.Slug,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = document.removeProvider(self.id);
        }
    };
    var apply = Apply{ .id = id };
    return store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
}

/// Insert or replace one configured provider's definition,
/// `custom_providers.<id>`, with `entry_json` (an object
/// `custom_provider.parse` reads). The section's other members and every
/// other key keep their content and order. `validate` judges the whole
/// document first; a refusal writes nothing.
pub fn putCustomProvider(
    store: *const Store,
    id: ids.Slug,
    entry_json: []const u8,
    validate: ?Validator,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Noop = struct {
        fn run(_: *anyopaque, _: *Document) anyerror!void {}
    };
    var anchor: u8 = 0;
    const edits = [_]MemberField{.{ .object_key = CUSTOM_PROVIDERS_KEY, .member_key = id.slice(), .json = entry_json }};
    return store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&anchor), .applyFn = Noop.run },
        .member_edits = &edits,
        .validate = validate,
    });
}

/// What `removeCustomProvider` found to remove in the document it wrote.
pub const CustomRemoval = struct {
    /// `providers.<id>` was there (enable state, credential references).
    settings: bool = false,
    /// The global selection was `forget_default`'s and is gone.
    default_forgotten: bool = false,
    result: CommitResult,
};

/// Remove a configured provider in one write: its definition
/// (`custom_providers.<id>`), its settings (`providers.<id>`), and — when
/// the file still stores `forget_default`, the selection the caller found to
/// resolve to this provider (`config_doc.sameSelection`) — the stored
/// default, which would otherwise name a route the next start cannot find.
pub fn removeCustomProvider(
    store: *const Store,
    id: ids.Slug,
    forget_default: ?config_doc.RuntimeSelection,
    validate: ?Validator,
    operation_id: ?[]const u8,
) StoreError!CustomRemoval {
    const Apply = struct {
        id: ids.Slug,
        forget_default: ?config_doc.RuntimeSelection,
        settings: bool = false,
        default_forgotten: bool = false,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.settings = document.removeProvider(self.id);
            const observed = self.forget_default orelse return;
            const current = document.global_selection orelse return;
            // Changed since the caller resolved it: someone chose another
            // default in between, which is not this removal's to forget.
            if (!try config_doc.sameSelection(document.allocator, current, observed)) return;
            document.global_selection = null;
            self.default_forgotten = true;
        }
    };
    var apply = Apply{ .id = id, .forget_default = forget_default };
    const edits = [_]MemberField{.{ .object_key = CUSTOM_PROVIDERS_KEY, .member_key = id.slice(), .json = null }};
    const result = try store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
        .member_edits = &edits,
        .validate = validate,
    });
    return .{ .settings = apply.settings, .default_forgotten = apply.default_forgotten, .result = result };
}

/// Insert or replace one alias record.
pub fn setAlias(
    store: *const Store,
    entry: config_doc.AliasEntry,
    expected: ?ConfigRevision,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        value: config_doc.AliasEntry,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try document.upsertAlias(self.value);
        }
    };
    var apply = Apply{ .value = entry };
    return store.commit(.{
        .expected_config_revision = expected,
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
}

pub fn removeAlias(
    store: *const Store,
    name: []const u8,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        name: []const u8,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = document.removeAlias(self.name);
        }
    };
    var apply = Apply{ .name = name };
    return store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
}

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

/// Forget the global selection (#485): the next plain start resolves its
/// route from the sign-in or `.env` instead. No selection stored is not an
/// error; the result says whether one was.
pub fn clearGlobalSelection(
    store: *const Store,
    operation_id: ?[]const u8,
) StoreError!struct { cleared: bool, result: CommitResult } {
    const Apply = struct {
        cleared: bool = false,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.cleared = document.global_selection != null;
            document.global_selection = null;
        }
    };
    var apply = Apply{};
    const result = try store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
    return .{ .cleared = apply.cleared, .result = result };
}

/// Record a credential failure durably.
///
/// The learned state has to outlive the process, or every run rediscovers the
/// same rate limit by hitting it. Written through the same lock, revision, and
/// atomic-rename path as every other mutation, so a concurrent picker commit
/// cannot lose it.
pub fn noteCredentialFailure(
    store: *const Store,
    provider_id: ids.Slug,
    credential_id: ids.Slug,
    class: @import("credential.zig").FailureClass,
    now_seconds: i64,
    cooldown_seconds: i64,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        provider_id: ids.Slug,
        credential_id: ids.Slug,
        class: @import("credential.zig").FailureClass,
        now_seconds: i64,
        cooldown_seconds: i64,

        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (document.providers.items) |*entry| {
                if (!entry.id.eql(self.provider_id)) continue;
                for (entry.credentials.entries[0..entry.credentials.len]) |*credential| {
                    if (!credential.id.eql(self.credential_id)) continue;
                    switch (self.class) {
                        .rate_limited => credential.cooldown_until = self.now_seconds + self.cooldown_seconds,
                        .invalid => credential.invalid = true,
                        // A transient network failure is nobody's credential's
                        // fault; marking one would retire a working account.
                        .transient => {},
                    }
                    return;
                }
            }
        }
    };
    var apply = Apply{
        .provider_id = provider_id,
        .credential_id = credential_id,
        .class = class,
        .now_seconds = now_seconds,
        .cooldown_seconds = cooldown_seconds,
    };
    return store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
}

/// Convenience wrapper for the common "replace the session selection" mutation.
pub fn setSessionSelection(
    store: *const Store,
    selection: ?config_doc.RuntimeSelection,
    expected: ?ConfigRevision,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        value: ?config_doc.RuntimeSelection,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            document.session_selection = self.value;
        }
    };
    var apply = Apply{ .value = selection };
    return store.commit(.{
        .expected_config_revision = expected,
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
}

/// Insert or replace the preset `name` (#489). The directories that remember
/// it follow on their next start: they hold its name, not its selection. A
/// name `--preset` cannot take is `error.InvalidPresetName`.
pub fn setPreset(
    store: *const Store,
    name: []const u8,
    selection: config_doc.RuntimeSelection,
    expected: ?ConfigRevision,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        name: []const u8,
        value: config_doc.RuntimeSelection,
        failure: ?config_doc.DocumentError = null,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            document.upsertPreset(self.name, self.value) catch |err| {
                self.failure = err;
                return err;
            };
        }
    };
    var apply = Apply{ .name = name, .value = selection };
    return store.commit(.{
        .expected_config_revision = expected,
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    }) catch |err| return if (err == error.MutationFailed) apply.failure orelse err else err;
}

/// Remove the preset `name` (#489); says whether one was defined. A
/// directory that remembers it keeps its entry, and a start there says the
/// preset is gone instead of quietly using another route.
pub fn removePreset(
    store: *const Store,
    name: []const u8,
    operation_id: ?[]const u8,
) StoreError!struct { removed: bool, result: CommitResult } {
    const Apply = struct {
        name: []const u8,
        removed: bool = false,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.removed = document.removePreset(self.name);
        }
    };
    var apply = Apply{ .name = name };
    const result = try store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
    return .{ .removed = apply.removed, .result = result };
}

/// Make the directory `path` (absolute, the host's canonical key for it)
/// remember the preset `name` (#489), which must be defined:
/// `error.UnknownPreset` otherwise, `error.InvalidDirectoryPreset` for a path
/// that is not absolute.
pub fn setDirectoryPreset(
    store: *const Store,
    path: []const u8,
    name: []const u8,
    operation_id: ?[]const u8,
) StoreError!CommitResult {
    const Apply = struct {
        path: []const u8,
        name: []const u8,
        failure: ?config_doc.DocumentError = null,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            document.setDirectoryPreset(self.path, self.name) catch |err| {
                self.failure = err;
                return err;
            };
        }
    };
    var apply = Apply{ .path = path, .name = name };
    return store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    }) catch |err| return if (err == error.MutationFailed) apply.failure orelse err else err;
}

/// Forget what the directory `path` remembers (#489); says whether it
/// remembered a preset.
pub fn removeDirectoryPreset(
    store: *const Store,
    path: []const u8,
    operation_id: ?[]const u8,
) StoreError!struct { removed: bool, result: CommitResult } {
    const Apply = struct {
        path: []const u8,
        removed: bool = false,
        fn run(ctx: *anyopaque, document: *Document) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.removed = document.removeDirectoryPreset(self.path);
        }
    };
    var apply = Apply{ .path = path };
    const result = try store.commit(.{
        .operation_id = operation_id,
        .mutation = .{ .ctx = @ptrCast(&apply), .applyFn = Apply.run },
    });
    return .{ .removed = apply.removed, .result = result };
}

/// 测试 fixture 路径 `<tmpRoot>/cc-zig-provider-<name>-<pid>`(本子系统不得导入 tools/,
/// 走 util/fs.zig 的规则源;文件直接放在临时根下,不需要先建目录)。
fn testFixturePath(buf: []u8, name: []const u8) ![]const u8 {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pid = @import("platform").process.currentPid();
    return std.fmt.bufPrint(buf, "{s}/cc-zig-provider-{s}-{d}", .{ util_fs.testing.tmpRoot(&root_buf), name, pid });
}

test "an empty idempotency key is rejected rather than matching every other one" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "empty-op-test.json");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        const target = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    }
    defer for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        var cleanup: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fmt.bufPrintZ(&cleanup, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    };

    var store = try Store.initPath(a, path);
    defer store.deinit();

    const Noop = struct {
        fn run(_: *anyopaque, _: *Document) anyerror!void {}
    };
    var anchor: u8 = 0;
    try std.testing.expectError(error.InvalidOperationId, store.commit(.{
        .operation_id = "",
        .mutation = .{ .ctx = @ptrCast(&anchor), .applyFn = Noop.run },
    }));

    // A commit with no key at all remains legal.
    const anonymous = try store.commit(.{
        .mutation = .{ .ctx = @ptrCast(&anchor), .applyFn = Noop.run },
    });
    try std.testing.expect(!anonymous.idempotent_replay);
}

test "clearing the global selection removes the key and keeps the rest of the file" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "clear-global-test.json");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        const target = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    }
    defer for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        var cleanup: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fmt.bufPrintZ(&cleanup, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    };

    var store = try Store.initPath(a, path);
    defer store.deinit();
    // Nothing stored: nothing to clear, and that is no error.
    try std.testing.expect(!(try clearGlobalSelection(&store, null)).cleared);

    _ = try setGlobalSelection(&store, config_doc.RuntimeSelection.pinned(.{ .digest = @splat(0x33) }, 1, .global), null, null);
    var before = try store.load();
    defer before.deinit();
    try std.testing.expect(before.global_selection != null);

    try std.testing.expect((try clearGlobalSelection(&store, null)).cleared);
    var after = try store.load();
    defer after.deinit();
    try std.testing.expect(after.global_selection == null);
    const text = try store.readText();
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "global_selection") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "config_revision") != null);
}

test "the home store resolves either the override or <state_root>/config.json" {
    const a = std.testing.allocator;
    // `initHome` is the production entry point. Assert the branch this
    // environment actually takes rather than mutating the process environment,
    // which would leak into every other test in the shard.
    if (std.c.getenv(CONFIG_PATH_ENV)) |raw| {
        var store = try Store.initHome(a, "/state");
        defer store.deinit();
        try std.testing.expectEqualStrings(std.mem.span(raw), store.path);
        return;
    }
    var store = try Store.initHome(a, "/state");
    defer store.deinit();
    try std.testing.expectEqualStrings("/state" ++ std.fs.path.sep_str ++ "config.json", store.path);
    try std.testing.expectError(StoreError.NoHome, Store.initHome(a, ""));
}

test "two sessions keep separate selections and neither touches the other" {
    const a = std.testing.allocator;
    var dir_a_buf: [512]u8 = undefined;
    var dir_b_buf: [512]u8 = undefined;
    const dirs = [_][]const u8{
        try testFixturePath(&dir_a_buf, "session-a"),
        try testFixturePath(&dir_b_buf, "session-b"),
    };
    var paths: [dirs.len][]u8 = undefined;
    var made: usize = 0;
    defer {
        var index: usize = 0;
        while (index < made) : (index += 1) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
                const target = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ paths[index], suffix }) catch continue;
                pfs.unlinkPath(target) catch {};
            }
            const dir_z = std.fmt.bufPrintZ(&buffer, "{s}", .{dirs[index]}) catch continue;
            _ = pfs.rmdir(dir_z.ptr);
            a.free(paths[index]);
        }
    }

    var stores: [dirs.len]Store = undefined;
    for (dirs, 0..) |dir, index| {
        stores[index] = try Store.initSessionFile(a, dir);
        paths[index] = try a.dupe(u8, stores[index].path);
        made += 1;
    }
    defer for (&stores) |*store| store.deinit();

    try std.testing.expect(std.mem.endsWith(u8, stores[0].path, "/runtime-selection.json"));
    try std.testing.expect(!std.mem.eql(u8, stores[0].path, stores[1].path));

    const first = config_doc.RuntimeSelection.pinned(.{ .digest = @splat(0x11) }, 1, .session);
    const second = config_doc.RuntimeSelection.pinned(.{ .digest = @splat(0x22) }, 1, .session);
    _ = try setSessionSelection(&stores[0], first, null, "op-a");
    _ = try setSessionSelection(&stores[1], second, null, "op-b");

    var loaded_a = try stores[0].load();
    defer loaded_a.deinit();
    var loaded_b = try stores[1].load();
    defer loaded_b.deinit();

    // Session scope is only real if one session's commit is invisible to the
    // other. A shared key would make the second write win for both.
    try std.testing.expect(loaded_a.session_selection.?.target.pinned_offer.offer_id.eql(first.target.pinned_offer.offer_id));
    try std.testing.expect(loaded_b.session_selection.?.target.pinned_offer.offer_id.eql(second.target.pinned_offer.offer_id));
    try std.testing.expect(loaded_a.global_selection == null);

    // Clearing is an explicit null, not a missing key that reads as "unchanged".
    _ = try setSessionSelection(&stores[0], null, loaded_a.config_revision, "op-a-clear");
    var cleared = try stores[0].load();
    defer cleared.deinit();
    try std.testing.expect(cleared.session_selection == null);
}

test "a learned credential failure is durable and leaves the other members alone" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "credential-failure.json");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        const target = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    }
    defer for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        var cleanup: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fmt.bufPrintZ(&cleanup, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    };

    var store = try Store.initPath(a, path);
    defer store.deinit();

    const Seed = struct {
        fn run(_: *anyopaque, document: *Document) anyerror!void {
            var entry = config_doc.ProviderEntry{ .id = ids.Slug.lit("openai") };
            try entry.credentials.append(.{
                .id = ids.Slug.lit("work"),
                .env = try config_doc.AliasName.parse("OPENAI_API_KEY_WORK"),
                .kind = try @import("controls.zig").Bounded(32).parse("api_key"),
            });
            try entry.credentials.append(.{
                .id = ids.Slug.lit("personal"),
                .env = try config_doc.AliasName.parse("OPENAI_API_KEY_PERSONAL"),
                .kind = try @import("controls.zig").Bounded(32).parse("api_key"),
            });
            try document.upsertProvider(entry);
        }
    };
    var anchor: u8 = 0;
    _ = try store.commit(.{ .mutation = .{ .ctx = @ptrCast(&anchor), .applyFn = Seed.run } });

    _ = try noteCredentialFailure(
        &store,
        ids.Slug.lit("openai"),
        ids.Slug.lit("work"),
        .rate_limited,
        1_000,
        300,
        "limit-1",
    );
    _ = try noteCredentialFailure(
        &store,
        ids.Slug.lit("openai"),
        ids.Slug.lit("personal"),
        .invalid,
        1_000,
        300,
        "dead-1",
    );

    var reloaded = try store.load();
    defer reloaded.deinit();
    const entry = reloaded.provider(ids.Slug.lit("openai")).?;
    const members = entry.credentials.items();
    try std.testing.expectEqual(@as(?i64, 1_300), members[0].cooldown_until);
    try std.testing.expect(!members[0].invalid);
    // A dead key is invalidated rather than put on a timer: retrying it only
    // burns the account's error budget.
    try std.testing.expect(members[1].invalid);
    try std.testing.expectEqual(@as(?i64, null), members[1].cooldown_until);

    // A transient failure records nothing — it would retire a working account.
    _ = try noteCredentialFailure(
        &store,
        ids.Slug.lit("openai"),
        ids.Slug.lit("work"),
        .transient,
        9_000,
        300,
        "blip-1",
    );
    var after = try store.load();
    defer after.deinit();
    try std.testing.expectEqual(
        @as(?i64, 1_300),
        after.provider(ids.Slug.lit("openai")).?.credentials.items()[0].cooldown_until,
    );
}

test "presets and the directories that remember them persist through the store, typed errors included (#489)" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "presets-test.json");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        const target = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    }
    defer for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        var cleanup: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fmt.bufPrintZ(&cleanup, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    };

    var store = try Store.initPath(a, path);
    defer store.deinit();

    const first = try config_doc.RuntimeSelection.auto("relay-model", .{}, .session);
    _ = try setPreset(&store, "a", first, null, null);
    _ = try setPreset(&store, "b", try config_doc.RuntimeSelection.auto("other-model", .{}, .session), null, null);
    _ = try setDirectoryPreset(&store, "/work/x", "a", null);
    _ = try setDirectoryPreset(&store, "/work/y", "b", null);
    // The errors a caller can act on come back as themselves, and nothing
    // is written for them.
    try std.testing.expectError(error.UnknownPreset, setDirectoryPreset(&store, "/work/z", "c", null));
    try std.testing.expectError(error.InvalidDirectoryPreset, setDirectoryPreset(&store, "work/z", "a", null));
    try std.testing.expectError(error.InvalidPresetName, setPreset(&store, "a b", first, null, null));

    // Editing `a` is what `/work/x` uses from then on; its entry is untouched.
    var edited = try config_doc.RuntimeSelection.auto("relay-model-b", .{}, .session);
    try edited.controls.set("reasoning_effort", try @import("controls.zig").Value.fromText("high"));
    _ = try setPreset(&store, "a", edited, null, null);
    var loaded = try store.load();
    defer loaded.deinit();
    try std.testing.expect(loaded.directoryPreset("/work/x").?.preset.eqlText("a"));
    try std.testing.expect(loaded.preset("a").?.selection.target.auto_route.selector.eqlText("relay-model-b"));
    try std.testing.expect(loaded.preset("a").?.selection.controls.get("reasoning_effort").?.text.eqlText("high"));
    try std.testing.expect(loaded.directoryPreset("/work/z") == null);

    // Removing a preset keeps the directory that names it.
    try std.testing.expect((try removePreset(&store, "b", null)).removed);
    try std.testing.expect(!(try removePreset(&store, "b", null)).removed);
    try std.testing.expect((try removeDirectoryPreset(&store, "/work/x", null)).removed);
    try std.testing.expect(!(try removeDirectoryPreset(&store, "/work/x", null)).removed);
    var after = try store.load();
    defer after.deinit();
    try std.testing.expect(after.preset("b") == null);
    try std.testing.expect(after.directoryPreset("/work/y").?.preset.eqlText("b"));
    try std.testing.expect(after.directoryPreset("/work/x") == null);
}

/// Remove `<path>`, `<path>.lock` and `<path>.tmp`.
fn removeFixture(path: []const u8) void {
    for ([_][]const u8{ "", ".lock", ".tmp" }) |suffix| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    }
}

fn writeFixture(path: []const u8, text: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buffer, "{s}", .{path});
    const fd = pfs.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer pfs.close(fd);
    if (pfs.write(fd, text) != @as(isize, @intCast(text.len))) return error.WriteFailed;
}

fn expectKeys(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

const HAND_WRITTEN =
    \\{
    \\  "theme": "dark",
    \\  "mcp_servers": [{"name": "kg", "command": "kgd"}],
    \\  "custom_providers": {
    \\    "relay-a": {"display_name": "Relay A", "channels": [{"id": "c", "base_url": "https://a.example.com/v1", "protocol": "openai_chat"}],
    \\                "models": [{"request_model_id": "m", "price": {"currency": "USD", "input": 2.5}}]},
    \\    "relay-b": {"channels": [{"id": "c", "base_url": "https://b.example.com/v1", "protocol": "openai_chat"}], "models": [{"request_model_id": "n"}]}
    \\  },
    \\  "model_tiers": {"fast": "m"}
    \\}
;

test "a configured provider is written as one member; every other key and member keeps its content and order" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "custom-put.json");
    removeFixture(path);
    defer removeFixture(path);
    try writeFixture(path, HAND_WRITTEN);

    var store = try Store.initPath(a, path);
    defer store.deinit();
    const entry = "{\"display_name\":\"Relay C\",\"channels\":[{\"id\":\"openai\",\"base_url\":\"http://127.0.0.1:8000/v1\",\"protocol\":\"openai_chat\"}],\"models\":[{\"request_model_id\":\"qwen3\"}]}";
    var before = try store.load();
    const revision_before = before.config_revision.value();
    before.deinit();
    const first = try putCustomProvider(&store, ids.Slug.lit("relay-c"), entry, null, null);
    // A commit like any other: the revision moves.
    try std.testing.expectEqual(revision_before + 1, first.config_revision.value());

    const text = try store.readText();
    defer a.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    // The other writers' keys, in their order, with the control-plane keys
    // appended after them.
    try expectKeys(&.{ "theme", "mcp_servers", "custom_providers", "model_tiers" }, root.keys()[0..4]);
    try std.testing.expectEqualStrings("kgd", root.get("mcp_servers").?.array.items[0].object.get("command").?.string);
    const section = root.get("custom_providers").?.object;
    try expectKeys(&.{ "relay-a", "relay-b", "relay-c" }, section.keys());
    // A hand-written price is untouched by a write about another provider.
    try std.testing.expectEqual(@as(f64, 2.5), section.get("relay-a").?.object.get("models").?.array.items[0].object.get("price").?.object.get("input").?.float);
    try std.testing.expectEqualStrings("Relay C", section.get("relay-c").?.object.get("display_name").?.string);

    // Replacing keeps the member where it was.
    _ = try putCustomProvider(&store, ids.Slug.lit("relay-a"), "{\"display_name\":\"Relay A2\",\"channels\":[{\"id\":\"c\",\"base_url\":\"https://a.example.com/v1\",\"protocol\":\"openai_chat\"}],\"models\":[{\"request_model_id\":\"m\"}]}", null, null);
    const again = try store.readText();
    defer a.free(again);
    var reparsed = try std.json.parseFromSlice(std.json.Value, a, again, .{});
    defer reparsed.deinit();
    const replaced = reparsed.value.object.get("custom_providers").?.object;
    try expectKeys(&.{ "relay-a", "relay-b", "relay-c" }, replaced.keys());
    try std.testing.expectEqualStrings("Relay A2", replaced.get("relay-a").?.object.get("display_name").?.string);
}

test "a refused document is never written" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "custom-refused.json");
    removeFixture(path);
    defer removeFixture(path);
    try writeFixture(path, HAND_WRITTEN);

    var store = try Store.initPath(a, path);
    defer store.deinit();
    const Refuse = struct {
        seen: usize = 0,
        fn run(ctx: *anyopaque, text: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // It is shown the document as it would land, edit included.
            if (std.mem.indexOf(u8, text, "\"relay-c\"") != null) self.seen += 1;
            return error.NotThisOne;
        }
    };
    var refuse = Refuse{};
    try std.testing.expectError(error.Rejected, putCustomProvider(
        &store,
        ids.Slug.lit("relay-c"),
        "{\"channels\":[],\"models\":[]}",
        .{ .ctx = @ptrCast(&refuse), .validateFn = Refuse.run },
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), refuse.seen);
    const text = try store.readText();
    defer a.free(text);
    try std.testing.expectEqualStrings(HAND_WRITTEN, text);
}

test "removing a configured provider drops its definition, its settings and a default that is still its own" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "custom-remove.json");
    removeFixture(path);
    defer removeFixture(path);
    try writeFixture(path, HAND_WRITTEN);

    var store = try Store.initPath(a, path);
    defer store.deinit();
    _ = try setProviderEnabled(&store, ids.Slug.lit("relay-a"), false, null);
    const chosen = config_doc.RuntimeSelection.pinned(.{ .digest = @splat(0x5a) }, 1, .global);
    _ = try setGlobalSelection(&store, chosen, null, null);
    var loaded = try store.load();
    const observed = loaded.global_selection.?;
    loaded.deinit();

    // A default someone else chose meanwhile is not forgotten.
    const other = config_doc.RuntimeSelection.pinned(.{ .digest = @splat(0x11) }, 1, .global);
    const kept = try removeCustomProvider(&store, ids.Slug.lit("relay-b"), other, null, null);
    try std.testing.expect(!kept.settings and !kept.default_forgotten);

    const removed = try removeCustomProvider(&store, ids.Slug.lit("relay-a"), observed, null, null);
    try std.testing.expect(removed.settings);
    try std.testing.expect(removed.default_forgotten);

    var after = try store.load();
    defer after.deinit();
    try std.testing.expect(after.provider(ids.Slug.lit("relay-a")) == null);
    try std.testing.expect(after.global_selection == null);
    const text = try store.readText();
    defer a.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const section = parsed.value.object.get("custom_providers").?.object;
    try std.testing.expectEqual(@as(usize, 0), section.count());
    try std.testing.expect(parsed.value.object.get("theme") != null);
    try std.testing.expect(parsed.value.object.get("model_tiers") != null);
}

test "removing a configured provider forgets the default the file stores, whatever lies past its controls" {
    // The caller's copy of the default and the one read again under the lock
    // agree in what is written, not in the control slots past `len`, which
    // are undefined. Comparing those bytes kept a default that was this
    // provider's, and on a backend that checks union tags it panicked.
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = try testFixturePath(&path_buf, "custom-remove-slots.json");
    removeFixture(path);
    defer removeFixture(path);
    try writeFixture(path, HAND_WRITTEN);

    var store = try Store.initPath(a, path);
    defer store.deinit();
    var chosen = config_doc.RuntimeSelection.pinned(.{ .digest = @splat(0x5a) }, 1, .global);
    try chosen.controls.set("max_output_tokens", .{ .number = 8_000 });
    _ = try setGlobalSelection(&store, chosen, null, null);
    var loaded = try store.load();
    var observed = loaded.global_selection.?;
    loaded.deinit();
    // The same default, with a control left behind `len` the way
    // `ControlValues.remove` leaves one.
    try observed.controls.set("stale", .{ .boolean = true });
    try std.testing.expect(observed.controls.remove("stale"));

    const removed = try removeCustomProvider(&store, ids.Slug.lit("relay-a"), observed, null, null);
    try std.testing.expect(removed.default_forgotten);
    var after = try store.load();
    defer after.deinit();
    try std.testing.expect(after.global_selection == null);
}
