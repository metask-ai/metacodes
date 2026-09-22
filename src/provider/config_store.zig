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
const util_fs = @import("../util/fs.zig");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const fs_util = @import("../util/fs.zig");
const file_lock = @import("../util/file_lock.zig");
const config_doc = @import("config_doc.zig");
const ids = @import("ids.zig");

pub const Document = config_doc.Document;
pub const ConfigRevision = ids.ConfigRevision;

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

        const bytes = try document.merge(original);
        defer self.allocator.free(bytes);
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
            const errno: std.c.E = @enumFromInt(std.c._errno().*);
            if (errno != .NOENT) return error.OpenFailed;
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

test "the home store resolves either the override or the home path" {
    const a = std.testing.allocator;
    // `initHome` is the production entry point. Assert the branch this
    // environment actually takes rather than mutating the process environment,
    // which would leak into every other test in the shard.
    var store = Store.initHome(a) catch |err| {
        try std.testing.expectEqual(StoreError.NoHome, err);
        return;
    };
    defer store.deinit();
    if (std.c.getenv(CONFIG_PATH_ENV)) |raw| {
        try std.testing.expectEqualStrings(std.mem.span(raw), store.path);
    } else {
        try std.testing.expect(std.mem.endsWith(u8, store.path, "/.metacodes/config.json"));
    }
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
            _ = std.c.rmdir(dir_z.ptr);
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
