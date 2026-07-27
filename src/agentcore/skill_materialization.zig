//! Per-activation working trees built only from an immutable Skill snapshot.
//!
//! The Runtime owns one private root and an aggregate byte reservation. Each
//! admitted activation gets an unpredictable exclusive child, which is fully
//! written and verified before its path is returned.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("platform").sync;
const rng = @import("platform").rng;
const paths = @import("platform").paths;
const core = @import("metacodes-core");
const catalog = @import("skill_catalog.zig");

const Dir = std.Io.Dir;
const File = std.Io.File;
const AbortSignal = core.util_abort.AbortSignal;

pub const MAX_ACTIVE_BYTES: usize = 256 * 1024 * 1024;
const MAX_NAME_ATTEMPTS: usize = 8;
/// Conservative inode/directory/block charge. The aggregate cap must not be
/// bypassable by a snapshot containing thousands of zero-byte entries.
const ENTRY_ACCOUNT_BYTES: usize = 4096;

pub const Error = error{
    OutOfMemory,
    RandomUnavailable,
    ResourceLimit,
    Aborted,
    CoreError,
    Busy,
    Unavailable,
};

pub const TestFault = enum {
    after_reserve,
    after_create,
    after_write,
    before_verify,
    corrupt_before_verify,
    abort_after_create,
};

const State = enum {
    available,
    poisoned,
    destroying,
};

const NameSource = struct {
    ctx: ?*anyopaque = null,
    fill_fn: *const fn (?*anyopaque, []u8) bool = systemFill,

    fn fill(self: NameSource, bytes: []u8) bool {
        return self.fill_fn(self.ctx, bytes);
    }

    fn systemFill(_: ?*anyopaque, bytes: []u8) bool {
        return rng.randomBytes(bytes);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owned_io_runtime: ?*std.Io.Threaded,
    root_path: []u8,
    root_dir: Dir,
    root_open: bool = true,
    name_source: NameSource,
    mutex: sync.Mutex = .{},
    state: State = .available,
    active_count: usize = 0,
    active_bytes: usize = 0,
    max_active_bytes: usize = MAX_ACTIVE_BYTES,
    test_fault: if (builtin.is_test) ?TestFault else void = if (builtin.is_test) null else {},

    pub fn init(allocator: std.mem.Allocator) Error!Manager {
        const io_runtime = allocator.create(std.Io.Threaded) catch
            return error.OutOfMemory;
        errdefer allocator.destroy(io_runtime);
        io_runtime.* = std.Io.Threaded.init(allocator, .{});
        errdefer io_runtime.deinit();
        return initWithIo(
            allocator,
            io_runtime.io(),
            io_runtime,
            paths.tempDir(),
            .{},
            MAX_ACTIVE_BYTES,
        );
    }

    fn initBorrowed(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_path: []const u8,
        name_source: NameSource,
        max_active_bytes: usize,
    ) Error!Manager {
        if (comptime !builtin.is_test)
            @compileError("borrowed materializer I/O is test-only");
        return initWithIo(
            allocator,
            io,
            null,
            base_path,
            name_source,
            max_active_bytes,
        );
    }

    fn initWithIo(
        allocator: std.mem.Allocator,
        io: std.Io,
        owned_io_runtime: ?*std.Io.Threaded,
        base_path: []const u8,
        name_source: NameSource,
        max_active_bytes: usize,
    ) Error!Manager {
        var attempts: usize = 0;
        while (attempts < MAX_NAME_ATTEMPTS) : (attempts += 1) {
            const created = try createPrivateRoot(
                allocator,
                io,
                base_path,
                name_source,
            ) orelse continue;
            return .{
                .allocator = allocator,
                .io = io,
                .owned_io_runtime = owned_io_runtime,
                .root_path = created.path,
                .root_dir = created.dir,
                .name_source = name_source,
                .max_active_bytes = max_active_bytes,
            };
        }
        return error.CoreError;
    }

    pub fn deinit(self: *Manager) Error!void {
        self.mutex.lock();
        if (self.state == .destroying) {
            self.mutex.unlock();
            return error.Unavailable;
        }
        if (self.active_count != 0) {
            self.mutex.unlock();
            return error.Busy;
        }
        self.state = .destroying;
        self.mutex.unlock();

        if (self.root_open) {
            self.root_dir.close(self.io);
            self.root_open = false;
        }
        Dir.cwd().deleteTree(self.io, self.root_path) catch {
            self.mutex.lock();
            self.state = .poisoned;
            self.mutex.unlock();
            return error.CoreError;
        };
        const allocator = self.allocator;
        const io_runtime = self.owned_io_runtime;
        allocator.free(self.root_path);
        if (io_runtime) |runtime| {
            runtime.deinit();
            allocator.destroy(runtime);
        }
        self.* = undefined;
    }

    pub fn materialize(
        self: *Manager,
        record: *const catalog.SkillRecord,
        abort: *const AbortSignal,
    ) Error!WorkingTree {
        const faults: Faults = if (comptime builtin.is_test)
            testFaults(self.test_fault)
        else
            .{};
        return self.materializeWithFaults(record, abort, faults);
    }

    pub fn setTestFault(self: *Manager, fault: ?TestFault) void {
        if (comptime !builtin.is_test)
            @compileError("materialization fault injection is test-only");
        self.test_fault = fault;
    }

    fn materializeWithFaults(
        self: *Manager,
        record: *const catalog.SkillRecord,
        abort: *const AbortSignal,
        faults: Faults,
    ) Error!WorkingTree {
        const cost = materializationCost(record) catch return error.ResourceLimit;
        try self.reserve(cost);
        var reserved = true;
        errdefer if (reserved) self.release(cost);

        try checkpoint(abort, faults, .after_reserve);
        const name = try randomName(self.allocator, self.name_source, "activation-");
        errdefer self.allocator.free(name);
        const full_path = std.fs.path.join(self.allocator, &.{ self.root_path, name }) catch
            return error.OutOfMemory;
        errdefer self.allocator.free(full_path);

        self.root_dir.createDir(self.io, name, privateDirPermissions()) catch
            return error.CoreError;
        checkpoint(abort, faults, .after_create) catch |err| {
            if (!self.cleanupCreated(name)) return error.CoreError;
            return err;
        };

        var tree_dir = self.root_dir.openDir(self.io, name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch {
            if (!self.cleanupCreated(name)) return error.CoreError;
            return error.CoreError;
        };
        const populated = populateAndVerify(self, tree_dir, record, abort, faults);
        tree_dir.close(self.io);
        populated catch |err| {
            if (!self.cleanupCreated(name)) return error.CoreError;
            return err;
        };

        reserved = false;
        return .{
            .manager = self,
            .name = name,
            .path = full_path,
            .reserved_bytes = cost,
        };
    }

    fn reserve(self: *Manager, bytes: usize) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .available) return error.Unavailable;
        const next = std.math.add(usize, self.active_bytes, bytes) catch
            return error.ResourceLimit;
        if (next > self.max_active_bytes) return error.ResourceLimit;
        self.active_count = std.math.add(usize, self.active_count, 1) catch
            return error.ResourceLimit;
        self.active_bytes = next;
    }

    fn release(self: *Manager, bytes: usize) void {
        self.mutex.lock();
        std.debug.assert(self.active_count > 0);
        std.debug.assert(self.active_bytes >= bytes);
        self.active_count -= 1;
        self.active_bytes -= bytes;
        self.mutex.unlock();
    }

    fn markPoisoned(self: *Manager) void {
        self.mutex.lock();
        if (self.state == .available) self.state = .poisoned;
        self.mutex.unlock();
    }

    fn cleanupCreated(self: *Manager, name: []const u8) bool {
        self.root_dir.deleteTree(self.io, name) catch {
            self.markPoisoned();
            return false;
        };
        return true;
    }
};

pub const WorkingTree = struct {
    manager: *Manager,
    name: []u8,
    path: []u8,
    reserved_bytes: usize,

    /// Destroys the tree exactly once. A cleanup failure poisons the Manager so
    /// no new disk state is admitted; Runtime teardown still removes the
    /// private root.
    pub fn deinit(self: *WorkingTree) Error!void {
        const manager = self.manager;
        const allocator = manager.allocator;
        const cleanup_failed = blk: {
            manager.root_dir.deleteTree(manager.io, self.name) catch
                break :blk true;
            break :blk false;
        };
        manager.release(self.reserved_bytes);
        allocator.free(self.path);
        allocator.free(self.name);
        self.* = undefined;
        if (cleanup_failed) {
            manager.markPoisoned();
            return error.CoreError;
        }
    }
};

const Stage = enum {
    after_reserve,
    after_create,
    after_write,
    before_verify,
};

const Faults = struct {
    fail_at: ?Stage = null,
    abort_at: ?Stage = null,
    corrupt_before_verify: bool = false,
};

fn testFaults(fault: ?TestFault) Faults {
    return switch (fault orelse return .{}) {
        .after_reserve => .{ .fail_at = .after_reserve },
        .after_create => .{ .fail_at = .after_create },
        .after_write => .{ .fail_at = .after_write },
        .before_verify => .{ .fail_at = .before_verify },
        .corrupt_before_verify => .{ .corrupt_before_verify = true },
        .abort_after_create => .{ .abort_at = .after_create },
    };
}

fn populateAndVerify(
    manager: *Manager,
    tree_dir: Dir,
    record: *const catalog.SkillRecord,
    abort: *const AbortSignal,
    faults: Faults,
) Error!void {
    for (record.directories) |relative_path| {
        try abort.throwIfAborted();
        tree_dir.createDir(manager.io, relative_path, privateDirPermissions()) catch
            return error.CoreError;
    }
    for (record.files) |file_record| {
        try abort.throwIfAborted();
        var file = tree_dir.createFile(manager.io, file_record.relative_path, .{
            .exclusive = true,
            .permissions = filePermissions(file_record.executable),
            .resolve_beneath = true,
        }) catch return error.CoreError;
        defer file.close(manager.io);
        file.writeStreamingAll(manager.io, file_record.bytes) catch
            return error.CoreError;
        file.setPermissions(manager.io, filePermissions(file_record.executable)) catch
            return error.CoreError;
    }
    try checkpoint(abort, faults, .after_write);
    if (faults.corrupt_before_verify) {
        tree_dir.writeFile(manager.io, .{
            .sub_path = "unexpected",
            .data = "tampered",
            .flags = .{ .exclusive = true, .resolve_beneath = true },
        }) catch return error.CoreError;
    }
    try checkpoint(abort, faults, .before_verify);
    verifyTree(manager.allocator, manager.io, tree_dir, record, abort) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Aborted => return error.Aborted,
        else => return error.CoreError,
    };
    try abort.throwIfAborted();
}

fn checkpoint(
    abort: *const AbortSignal,
    faults: Faults,
    stage: Stage,
) Error!void {
    try abort.throwIfAborted();
    if (faults.abort_at == stage) return error.Aborted;
    if (faults.fail_at == stage) return error.CoreError;
}

const CreatedRoot = struct {
    path: []u8,
    dir: Dir,
};

fn createPrivateRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    name_source: NameSource,
) Error!?CreatedRoot {
    const name = try randomName(allocator, name_source, "metask-agentcore-");
    defer allocator.free(name);
    const root_path = std.fs.path.join(allocator, &.{ base_path, name }) catch
        return error.OutOfMemory;
    errdefer allocator.free(root_path);
    Dir.createDirAbsolute(io, root_path, privateDirPermissions()) catch |err| switch (err) {
        error.PathAlreadyExists => {
            allocator.free(root_path);
            return null;
        },
        else => return error.CoreError,
    };
    errdefer Dir.cwd().deleteTree(io, root_path) catch {};
    const root_dir = Dir.openDirAbsolute(io, root_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.CoreError;
    return .{ .path = root_path, .dir = root_dir };
}

fn materializationCost(record: *const catalog.SkillRecord) error{ResourceLimit}!usize {
    var total: usize = ENTRY_ACCOUNT_BYTES; // activation root
    for (record.directories) |directory| {
        total = std.math.add(usize, total, ENTRY_ACCOUNT_BYTES) catch
            return error.ResourceLimit;
        total = std.math.add(usize, total, directory.len) catch
            return error.ResourceLimit;
    }
    for (record.files) |file| {
        total = std.math.add(usize, total, ENTRY_ACCOUNT_BYTES) catch
            return error.ResourceLimit;
        total = std.math.add(usize, total, file.relative_path.len) catch
            return error.ResourceLimit;
        total = std.math.add(usize, total, file.bytes.len) catch
            return error.ResourceLimit;
    }
    return total;
}

fn randomName(
    allocator: std.mem.Allocator,
    source: NameSource,
    prefix: []const u8,
) Error![]u8 {
    var random: [16]u8 = undefined;
    if (!source.fill(&random)) return error.RandomUnavailable;
    const encoded = std.fmt.bytesToHex(random, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, &encoded }) catch
        error.OutOfMemory;
}

fn verifyTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: Dir,
    record: *const catalog.SkillRecord,
    abort: *const AbortSignal,
) VerifyError!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var counts = VerifyCounts{};
    try verifyDirectory(
        scratch.allocator(),
        io,
        root,
        "",
        record,
        abort,
        &counts,
    );
    if (counts.directories != record.directories.len or counts.files != record.files.len)
        return error.TreeMismatch;
}

const VerifyCounts = struct {
    directories: usize = 0,
    files: usize = 0,
};

const VerifyError = error{
    OutOfMemory,
    Aborted,
    TreeMismatch,
    Overflow,
} || Dir.StatError ||
    Dir.Iterator.Error ||
    Dir.StatFileError ||
    Dir.OpenError ||
    File.OpenError ||
    File.StatError ||
    File.ReadPositionalError;

fn verifyDirectory(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: Dir,
    prefix: []const u8,
    record: *const catalog.SkillRecord,
    abort: *const AbortSignal,
    counts: *VerifyCounts,
) VerifyError!void {
    try abort.throwIfAborted();
    const before = try dir.stat(io);
    if (before.kind != .directory) return error.TreeMismatch;

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        try abort.throwIfAborted();
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, ".."))
            continue;
        const relative_path = if (prefix.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try verifyChildDirectory(
                arena,
                io,
                dir,
                entry.name,
                relative_path,
                record,
                abort,
                counts,
            ),
            .file => try verifyFile(io, dir, entry.name, relative_path, record, abort, counts),
            .sym_link => return error.TreeMismatch,
            .unknown => {
                const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
                switch (stat.kind) {
                    .directory => try verifyChildDirectory(
                        arena,
                        io,
                        dir,
                        entry.name,
                        relative_path,
                        record,
                        abort,
                        counts,
                    ),
                    .file => try verifyFile(io, dir, entry.name, relative_path, record, abort, counts),
                    else => return error.TreeMismatch,
                }
            },
            else => return error.TreeMismatch,
        }
    }
    const after = try dir.stat(io);
    if (!sameDirectoryState(before, after)) return error.TreeMismatch;
}

fn verifyChildDirectory(
    arena: std.mem.Allocator,
    io: std.Io,
    parent: Dir,
    name: []const u8,
    relative_path: []const u8,
    record: *const catalog.SkillRecord,
    abort: *const AbortSignal,
    counts: *VerifyCounts,
) VerifyError!void {
    if (!containsString(record.directories, relative_path)) return error.TreeMismatch;
    counts.directories = try std.math.add(usize, counts.directories, 1);
    var child = try parent.openDir(io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer child.close(io);
    try verifyDirectory(arena, io, child, relative_path, record, abort, counts);
}

fn verifyFile(
    io: std.Io,
    parent: Dir,
    name: []const u8,
    relative_path: []const u8,
    record: *const catalog.SkillRecord,
    abort: *const AbortSignal,
    counts: *VerifyCounts,
) VerifyError!void {
    const expected = findFile(record.files, relative_path) orelse
        return error.TreeMismatch;
    counts.files = try std.math.add(usize, counts.files, 1);
    var file = try parent.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    const before = try file.stat(io);
    if (before.kind != .file or before.size != expected.bytes.len)
        return error.TreeMismatch;
    if (File.Permissions.has_executable_bit and
        executableBit(before.permissions) != expected.executable)
        return error.TreeMismatch;

    var offset: usize = 0;
    while (offset < expected.bytes.len) {
        try abort.throwIfAborted();
        const end = @min(offset + 8192, expected.bytes.len);
        var buffer: [8192]u8 = undefined;
        const read = try file.readPositionalAll(io, buffer[0 .. end - offset], offset);
        if (read != end - offset or
            !std.mem.eql(u8, buffer[0..read], expected.bytes[offset..end]))
            return error.TreeMismatch;
        offset = end;
    }
    const after = try file.stat(io);
    if (after.size != before.size or
        after.mtime.nanoseconds != before.mtime.nanoseconds or
        after.ctime.nanoseconds != before.ctime.nanoseconds)
        return error.TreeMismatch;
}

fn containsString(sorted: []const []const u8, needle: []const u8) bool {
    var low: usize = 0;
    var high = sorted.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, sorted[mid], needle)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return true,
        }
    }
    return false;
}

fn findFile(
    sorted: []const catalog.FileRecord,
    needle: []const u8,
) ?*const catalog.FileRecord {
    var low: usize = 0;
    var high = sorted.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, sorted[mid].relative_path, needle)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &sorted[mid],
        }
    }
    return null;
}

fn sameDirectoryState(lhs: File.Stat, rhs: File.Stat) bool {
    return lhs.kind == rhs.kind and
        lhs.inode == rhs.inode and
        lhs.mtime.nanoseconds == rhs.mtime.nanoseconds and
        lhs.ctime.nanoseconds == rhs.ctime.nanoseconds;
}

fn executableBit(permissions: File.Permissions) bool {
    if (!File.Permissions.has_executable_bit) return false;
    return (@intFromEnum(permissions) & 0o111) != 0;
}

fn privateDirPermissions() File.Permissions {
    return if (File.Permissions.has_executable_bit)
        .fromMode(0o700)
    else
        .default_dir;
}

fn filePermissions(executable: bool) File.Permissions {
    if (!File.Permissions.has_executable_bit) return .default_file;
    return .fromMode(if (executable) 0o700 else 0o600);
}

const DeterministicNames = struct {
    next: u8 = 1,
    fail: bool = false,

    fn fill(raw: ?*anyopaque, bytes: []u8) bool {
        const self: *DeterministicNames = @ptrCast(@alignCast(raw.?));
        if (self.fail) return false;
        @memset(bytes, self.next);
        self.next +%= 1;
        return true;
    }

    fn source(self: *DeterministicNames) NameSource {
        return .{ .ctx = self, .fill_fn = fill };
    }
};

const test_files = [_]catalog.FileRecord{
    .{ .relative_path = "SKILL.md", .bytes = "body", .executable = false },
    .{ .relative_path = "nested/run.sh", .bytes = "#!/bin/sh\nexit 0\n", .executable = true },
};
const test_directories = [_][]const u8{ "empty", "nested" };

fn testRecord() catalog.SkillRecord {
    return .{
        .skill_id = [_]u8{'a'} ** 64,
        .invocation_name = "review",
        .definition = undefined,
        .directories = &test_directories,
        .files = &test_files,
    };
}

fn testManager(
    tmp: *std.testing.TmpDir,
    names: *DeterministicNames,
    cap: usize,
) !Manager {
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    return Manager.initBorrowed(
        std.testing.allocator,
        std.testing.io,
        root_buffer[0..root_len],
        names.source(),
        cap,
    );
}

fn expectRootEmpty(manager: *Manager) !void {
    var iterator = manager.root_dir.iterate();
    try std.testing.expect(try iterator.next(manager.io) == null);
}

test "materialization preserves exact tree and isolates mutable scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var names = DeterministicNames{};
    var manager = try testManager(&tmp, &names, MAX_ACTIVE_BYTES);
    defer manager.deinit() catch unreachable;
    const record = testRecord();
    var abort = AbortSignal.init();

    var tree = try manager.materialize(&record, &abort);
    try std.testing.expect(std.fs.path.isAbsolute(tree.path));
    var tree_dir = try Dir.openDirAbsolute(std.testing.io, tree.path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer tree_dir.close(std.testing.io);
    const empty = try tree_dir.statFile(std.testing.io, "empty", .{ .follow_symlinks = false });
    try std.testing.expectEqual(File.Kind.directory, empty.kind);
    try tree_dir.writeFile(std.testing.io, .{
        .sub_path = "SKILL.md",
        .data = "changed",
    });
    try std.testing.expectEqualStrings("body", record.files[0].bytes);
    try tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), manager.active_count);
    try std.testing.expectEqual(@as(usize, 0), manager.active_bytes);
}

test "aggregate reservation is concurrent-live and released exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var names = DeterministicNames{};
    const record = testRecord();
    const cost = try materializationCost(&record);
    var manager = try testManager(&tmp, &names, cost);
    defer manager.deinit() catch unreachable;
    var abort = AbortSignal.init();

    var first = try manager.materialize(&record, &abort);
    try std.testing.expectError(error.Busy, manager.deinit());
    try std.testing.expectError(error.ResourceLimit, manager.materialize(&record, &abort));
    try first.deinit();
    var second = try manager.materialize(&record, &abort);
    try second.deinit();
}

test "empty payload entries still consume aggregate materialization budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var names = DeterministicNames{};
    const empty_files = [_]catalog.FileRecord{
        .{ .relative_path = "empty", .bytes = "", .executable = false },
    };
    const record = catalog.SkillRecord{
        .skill_id = [_]u8{'a'} ** 64,
        .invocation_name = "empty",
        .definition = undefined,
        .directories = &.{},
        .files = &empty_files,
    };
    const cost = try materializationCost(&record);
    try std.testing.expect(cost >= 2 * ENTRY_ACCOUNT_BYTES);
    var manager = try testManager(&tmp, &names, cost - 1);
    defer manager.deinit() catch unreachable;
    var abort = AbortSignal.init();
    try std.testing.expectError(error.ResourceLimit, manager.materialize(&record, &abort));
}

test "every materialization phase failure cleans tree and reservation" {
    const stages = [_]Stage{ .after_reserve, .after_create, .after_write, .before_verify };
    for (stages) |stage| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var names = DeterministicNames{};
        var manager = try testManager(&tmp, &names, MAX_ACTIVE_BYTES);
        defer manager.deinit() catch unreachable;
        const record = testRecord();
        var abort = AbortSignal.init();

        try std.testing.expectError(error.CoreError, manager.materializeWithFaults(
            &record,
            &abort,
            .{ .fail_at = stage },
        ));
        try std.testing.expectEqual(@as(usize, 0), manager.active_count);
        try std.testing.expectEqual(@as(usize, 0), manager.active_bytes);
        try expectRootEmpty(&manager);
    }
}

test "final verification rejects extra state and abort is typed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var names = DeterministicNames{};
    var manager = try testManager(&tmp, &names, MAX_ACTIVE_BYTES);
    defer manager.deinit() catch unreachable;
    const record = testRecord();
    var abort = AbortSignal.init();

    try std.testing.expectError(error.CoreError, manager.materializeWithFaults(
        &record,
        &abort,
        .{ .corrupt_before_verify = true },
    ));
    try std.testing.expectEqual(@as(usize, 0), manager.active_count);
    try expectRootEmpty(&manager);

    abort = AbortSignal.init();
    try std.testing.expectError(error.Aborted, manager.materializeWithFaults(
        &record,
        &abort,
        .{ .abort_at = .after_create },
    ));
    try std.testing.expectEqual(@as(usize, 0), manager.active_count);
    try expectRootEmpty(&manager);

    abort = AbortSignal.init();
    abort.abort(.timeout);
    try std.testing.expectError(error.Aborted, manager.materialize(&record, &abort));
    try std.testing.expectEqual(@as(usize, 0), manager.active_count);
    try expectRootEmpty(&manager);
}

test "entropy failure does not create a Runtime private root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var names = DeterministicNames{ .fail = true };
    try std.testing.expectError(
        error.RandomUnavailable,
        testManager(&tmp, &names, MAX_ACTIVE_BYTES),
    );
}

test "production Manager owns a concurrent I/O runtime and removes its private root" {
    var manager = try Manager.init(std.testing.allocator);
    const root = try std.testing.allocator.dupe(u8, manager.root_path);
    defer std.testing.allocator.free(root);
    try manager.deinit();
    try std.testing.expectError(
        error.FileNotFound,
        Dir.openDirAbsolute(std.testing.io, root, .{}),
    );
}

test "Runtime private root retries a random-name collision without leaking allocations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const collision = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/metask-agentcore-{s}",
        .{ root_buffer[0..root_len], "01" ** 16 },
    );
    defer std.testing.allocator.free(collision);
    try Dir.createDirAbsolute(std.testing.io, collision, privateDirPermissions());

    var names = DeterministicNames{};
    var manager = try testManager(&tmp, &names, MAX_ACTIVE_BYTES);
    try std.testing.expect(!std.mem.eql(u8, manager.root_path, collision));
    try manager.deinit();
}
