//! `metacodes install`: put the release unit this executable belongs to at a
//! prefix of the user's choosing, as one self-contained, isolated install
//! (doc/INSTALL_DESIGN.md §4).
//!
//! The unit is the directory around the running executable (`<root>/bin/…`)
//! sealed by its `manifest.json` (release/LAYOUT.md, manifest v2). Every file
//! the manifest lists is copied and re-hashed at the destination; nothing else
//! is read from the source tree. The install then gets its own
//! `etc/metacodes/install.json` (util/state_root.zig) and state root, the
//! AgentCore SDK bundle when one is given (`sdk/agentcore/`), and optionally a
//! launcher in a directory on PATH. The installed executable checks itself
//! with `doctor --strict`.
//!
//! Writes happen only under `--prefix`, the state root, and the `--link`
//! directory. A prefix that holds anything but this product's own install is
//! refused unless `--force`; reinstalling the same version over itself is
//! allowed. Install logic lives here, once, for every platform:
//! scripts/install.sh and scripts/install.ps1 only unpack an archive and call
//! this.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const state_root = @import("../util/state_root.zig");
const util_fs = @import("../util/fs.zig");

pub const Options = struct {
    /// Absolute destination prefix.
    prefix: []const u8,
    /// Absolute state root; null keeps it beside the install (`<prefix>/state`).
    state_dir: ?[]const u8 = null,
    /// Replace a prefix holding a different version or foreign files.
    force: bool = false,
    /// An unpacked AgentCore SDK bundle (its `manifest.json` names `agentcore`).
    sdk: ?[]const u8 = null,
    /// Directory on PATH that receives a launcher for this install.
    link_dir: ?[]const u8 = null,
    /// Launcher name (`metacodes` by default; several installs need several names).
    link_name: []const u8 = "metacodes",
    /// Run the installed executable's `doctor --strict` (tests switch it off).
    self_check: bool = true,
};

pub const Error = error{
    NotAReleaseUnit,
    UnsupportedManifest,
    PrefixNotAbsolute,
    StateDirNotAbsolute,
    PrefixOccupied,
    DifferentVersionInstalled,
    DigestMismatch,
    InvalidSdkBundle,
    LinkOccupied,
    SelfCheckFailed,
    PathTooLong,
};

pub const Outcome = struct {
    version: []const u8,
    prefix: []const u8,
    executable: []const u8,
    state_root: []const u8,
    files: usize,
    sdk: ?[]const u8 = null,
    launcher: ?[]const u8 = null,
    in_place: bool = false,
};

const unit_name = "metacodes-cli";
const unit_schema: u32 = 2;
const sdk_name = "agentcore";
const install_manifest_rel = state_root.manifest_relative_path;
const max_artifact_bytes = 256 << 20;

const FileEntry = struct { path: []const u8, sha256: []const u8 };

const UnitManifest = struct {
    schema_version: u32,
    name: []const u8,
    release: struct { version: []const u8 },
    files: []const FileEntry,
};

const SdkManifest = struct {
    name: []const u8,
    files: []const FileEntry,
};

const InstallRecord = struct {
    schema_version: []const u8,
    version: []const u8 = "",
};

/// `source_root` is the unit the running executable belongs to. `arena`
/// owns every returned string.
pub fn run(arena: std.mem.Allocator, io: std.Io, source_root: []const u8, options: Options, log: *std.Io.Writer) !Outcome {
    if (!std.fs.path.isAbsolute(options.prefix)) return error.PrefixNotAbsolute;
    if (options.state_dir) |dir| if (!std.fs.path.isAbsolute(dir)) return error.StateDirNotAbsolute;

    const manifest = readUnitManifest(arena, io, source_root) catch |err| switch (err) {
        error.FileNotFound => return error.NotAReleaseUnit,
        else => return err,
    };
    const version = manifest.release.version;

    const cwd = std.Io.Dir.cwd();
    const in_place = samePath(io, source_root, options.prefix);
    if (!in_place) try checkPrefix(arena, io, options.prefix, version, options.force);

    // The unit's files, each re-hashed where it landed.
    for (manifest.files) |file| {
        try checkRelative(file.path);
        const destination = try std.fs.path.join(arena, &.{ options.prefix, file.path });
        if (!in_place) {
            const source = try std.fs.path.join(arena, &.{ source_root, file.path });
            try cwd.copyFile(source, cwd, destination, io, .{ .make_path = true });
        }
        try expectDigest(arena, io, destination, file.sha256);
    }
    if (!in_place) {
        try cwd.copyFile(
            try std.fs.path.join(arena, &.{ source_root, "manifest.json" }),
            cwd,
            try std.fs.path.join(arena, &.{ options.prefix, "manifest.json" }),
            io,
            .{},
        );
    }
    try log.print("installed metacodes {s}: {d} files verified under {s}\n", .{ version, manifest.files.len, options.prefix });

    var outcome: Outcome = .{
        .version = version,
        .prefix = options.prefix,
        .executable = try std.fs.path.join(arena, &.{ options.prefix, "bin", if (is_windows) "metacodes.exe" else "metacodes" }),
        .state_root = undefined,
        .files = manifest.files.len,
        .in_place = in_place,
    };

    if (options.sdk) |sdk| outcome.sdk = try installSdk(arena, io, sdk, options.prefix, log);

    // This install's own state, and the record that points the executable at it.
    const recorded_root = options.state_dir orelse "state";
    outcome.state_root = if (options.state_dir) |dir| dir else try std.fs.path.join(arena, &.{ options.prefix, "state" });
    try util_fs.mkdirParents(outcome.state_root);
    const record = try std.json.Stringify.valueAlloc(arena, .{
        .schema_version = state_root.manifest_schema,
        .version = version,
        .state_root = recorded_root,
    }, .{ .whitespace = .indent_2 });
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ options.prefix, "etc", "metacodes" }));
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ options.prefix, install_manifest_rel }),
        .data = try std.fmt.allocPrint(arena, "{s}\n", .{record}),
    });
    try log.print("state root: {s}\n", .{outcome.state_root});

    if (options.link_dir) |dir| outcome.launcher = try writeLauncher(arena, io, dir, options.link_name, outcome.executable, options.force, log);
    if (options.self_check) try selfCheck(arena, outcome, log);
    return outcome;
}

fn readUnitManifest(arena: std.mem.Allocator, io: std.Io, root: []const u8) !UnitManifest {
    const path = try std.fs.path.join(arena, &.{ root, "manifest.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20));
    const manifest = std.json.parseFromSliceLeaky(UnitManifest, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return error.UnsupportedManifest;
    if (!std.mem.eql(u8, manifest.name, unit_name) or manifest.schema_version != unit_schema) return error.UnsupportedManifest;
    return manifest;
}

/// A destination is empty, absent, or this product's install of the same
/// version; anything else needs `--force`.
fn checkPrefix(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, version: []const u8, force: bool) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, prefix, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    if (try iterator.next(io) == null) return;

    const record_path = try std.fs.path.join(arena, &.{ prefix, install_manifest_rel });
    const bytes = cwd.readFileAlloc(io, record_path, arena, .limited(64 << 10)) catch |err| switch (err) {
        error.FileNotFound => return if (force) {} else error.PrefixOccupied,
        else => return err,
    };
    const record = std.json.parseFromSliceLeaky(InstallRecord, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return if (force) {} else error.PrefixOccupied;
    if (!std.mem.eql(u8, record.schema_version, state_root.manifest_schema)) return if (force) {} else error.PrefixOccupied;
    if (!std.mem.eql(u8, record.version, version) and !force) return error.DifferentVersionInstalled;
}

fn installSdk(arena: std.mem.Allocator, io: std.Io, bundle: []const u8, prefix: []const u8, log: *std.Io.Writer) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ bundle, "manifest.json" }), arena, .limited(4 << 20)) catch
        return error.InvalidSdkBundle;
    const manifest = std.json.parseFromSliceLeaky(SdkManifest, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidSdkBundle;
    if (!std.mem.eql(u8, manifest.name, sdk_name)) return error.InvalidSdkBundle;
    const destination_root = try std.fs.path.join(arena, &.{ prefix, "sdk", "agentcore" });
    // Replace a previous SDK wholesale: a stale header beside a new library is
    // worse than none.
    cwd.deleteTree(io, destination_root) catch {};
    for (manifest.files) |file| {
        try checkRelative(file.path);
        const destination = try std.fs.path.join(arena, &.{ destination_root, file.path });
        try cwd.copyFile(try std.fs.path.join(arena, &.{ bundle, file.path }), cwd, destination, io, .{ .make_path = true });
        try expectDigest(arena, io, destination, file.sha256);
    }
    try cwd.copyFile(
        try std.fs.path.join(arena, &.{ bundle, "manifest.json" }),
        cwd,
        try std.fs.path.join(arena, &.{ destination_root, "manifest.json" }),
        io,
        .{ .make_path = true },
    );
    try log.print("AgentCore SDK: {s} ({d} files verified)\n", .{ destination_root, manifest.files.len });
    return destination_root;
}

/// A launcher, not a symlink: the executable finds its kernels, TinyKG and
/// install.json beside its own physical path either way, but a script keeps
/// working when the directory it sits in is copied or synced.
fn writeLauncher(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, executable: []const u8, force: bool, log: *std.Io.Writer) ![]const u8 {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return error.LinkOccupied;
    const file_name = if (is_windows) try std.fmt.allocPrint(arena, "{s}.cmd", .{name}) else name;
    const path = try std.fs.path.join(arena, &.{ dir, file_name });
    const body = if (is_windows)
        try std.fmt.allocPrint(arena, "@\"{s}\" %*\r\n", .{executable})
    else
        try std.fmt.allocPrint(arena, "#!/bin/sh\n# metacodes launcher written by `metacodes install`\nexec \"{s}\" \"$@\"\n", .{executable});
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, arena, .limited(64 << 10))) |existing| {
        if (!std.mem.eql(u8, existing, body) and !force) return error.LinkOccupied;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = path, .data = body });
    if (!is_windows) {
        const path_z = try arena.dupeZ(u8, path);
        _ = @import("platform").fs.chmod(path_z.ptr, 0o755);
    }
    try log.print("launcher: {s}\n", .{path});
    return path;
}

/// The installed executable vouches for itself: every runtime asset resolves
/// adjacent and matches, and the state root comes from this install's record.
fn selfCheck(arena: std.mem.Allocator, outcome: Outcome, log: *std.Io.Writer) !void {
    const process = @import("platform").process;
    const exe_z = try arena.dupeZ(u8, outcome.executable);
    const argv = [_]?[*:0]const u8{ exe_z.ptr, "doctor", "--strict", null };
    // An empty environment on POSIX: no HOME, no METACODES_HOME, no override
    // pair can stand in for what the install itself provides.
    const captured = process.capture(&argv, arena, .{ .timeout_ms = 120_000, .inherit_env = false }) catch
        return error.SelfCheckFailed;
    try log.writeAll(captured.stdout);
    if (captured.exit_code != 0) return error.SelfCheckFailed;
    const expected = try std.fmt.allocPrint(arena, "state_root {s} source=", .{outcome.state_root});
    const line = std.mem.indexOf(u8, captured.stdout, expected) orelse return error.SelfCheckFailed;
    const source = captured.stdout[line + expected.len ..];
    // Windows always hands the child the caller's environment, so an exported
    // METACODES_HOME may legitimately win there; POSIX must read the record.
    if (!is_windows and !std.mem.startsWith(u8, source, "install")) return error.SelfCheckFailed;
}

fn expectDigest(arena: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_artifact_bytes));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected)) return error.DigestMismatch;
}

/// A manifest path stays inside its root.
fn checkRelative(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.UnsupportedManifest;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.UnsupportedManifest;
}

fn samePath(io: std.Io, a: []const u8, b: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    var a_dir = cwd.openDir(io, a, .{}) catch return false;
    defer a_dir.close(io);
    var b_dir = cwd.openDir(io, b, .{}) catch return false;
    defer b_dir.close(io);
    var a_buf: [std.fs.max_path_bytes]u8 = undefined;
    var b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a_len = a_dir.realPath(io, &a_buf) catch return false;
    const b_len = b_dir.realPath(io, &b_buf) catch return false;
    return std.mem.eql(u8, a_buf[0..a_len], b_buf[0..b_len]);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        const len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..len];
    }

    fn path(self: *const Fixture, arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ self.root, rel });
    }

    /// A minimal v2 unit under `unit/` whose manifest lists `files`.
    fn unit(self: *Fixture, arena: std.mem.Allocator, version: []const u8, files: []const [2][]const u8) ![]const u8 {
        var entries: std.ArrayList(FileEntry) = .empty;
        for (files) |file| {
            const rel = try std.fs.path.join(arena, &.{ "unit", file[0] });
            if (std.fs.path.dirname(rel)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
            try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = file[1] });
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(file[1], &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            try entries.append(arena, .{ .path = file[0], .sha256 = try arena.dupe(u8, &hex) });
        }
        const manifest = try std.json.Stringify.valueAlloc(arena, .{
            .schema_version = unit_schema,
            .name = unit_name,
            .release = .{ .version = version },
            .files = entries.items,
        }, .{});
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "unit/manifest.json", .data = manifest });
        return self.path(arena, "unit");
    }
};

const unit_files = [_][2][]const u8{
    .{ "bin/metacodes", "exe" },
    .{ "libexec/metacodes/metacodes-formal-kernel", "kernel" },
    .{ "vendor/tinykg/tinykgd", "daemon" },
};

fn read(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));
}

test "install copies and verifies the unit, records its own state root" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    const source = try fixture.unit(arena, "0.3.0", &unit_files);
    const prefix = try fixture.path(arena, "opt/mc-a");
    var log: std.Io.Writer.Allocating = .init(arena);

    const outcome = try run(arena, testing.io, source, .{ .prefix = prefix, .self_check = false }, &log.writer);
    try testing.expectEqual(@as(usize, unit_files.len), outcome.files);
    try testing.expectEqualStrings("kernel", try read(arena, try std.fs.path.join(arena, &.{ prefix, "libexec/metacodes/metacodes-formal-kernel" })));
    try testing.expect((try read(arena, try std.fs.path.join(arena, &.{ prefix, "manifest.json" }))).len > 0);

    // The record util/state_root.zig reads: a prefix-relative root.
    const record = try read(arena, try std.fs.path.join(arena, &.{ prefix, install_manifest_rel }));
    try testing.expect(std.mem.indexOf(u8, record, "\"state_root\": \"state\"") != null);
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.path.join(arena, &.{ prefix, "bin", "metacodes" });
    const resolved = try state_root.resolveFrom(.{ .exe_path = exe, .home = "/home/u" }, &resolved_buf);
    try testing.expectEqual(state_root.Source.install, resolved.source);
    try testing.expectEqualStrings(outcome.state_root, resolved.path);
    try std.Io.Dir.cwd().access(testing.io, outcome.state_root, .{});

    // Reinstalling the same version over itself is allowed.
    _ = try run(arena, testing.io, source, .{ .prefix = prefix, .self_check = false }, &log.writer);
}

test "two installs on one machine keep separate state roots" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    const source = try fixture.unit(arena, "0.3.0", &unit_files);
    var log: std.Io.Writer.Allocating = .init(arena);
    const shared = try fixture.path(arena, "srv/shared-state");
    const a = try run(arena, testing.io, source, .{ .prefix = try fixture.path(arena, "a"), .self_check = false }, &log.writer);
    const b = try run(arena, testing.io, source, .{ .prefix = try fixture.path(arena, "b"), .self_check = false }, &log.writer);
    const c = try run(arena, testing.io, source, .{ .prefix = try fixture.path(arena, "c"), .state_dir = shared, .self_check = false }, &log.writer);
    try testing.expect(!std.mem.eql(u8, a.state_root, b.state_root));
    try testing.expectEqualStrings(shared, c.state_root);
    const record = try read(arena, try std.fs.path.join(arena, &.{ c.prefix, install_manifest_rel }));
    try testing.expect(std.mem.indexOf(u8, record, shared) != null);
}

test "install refuses a foreign or differently versioned prefix unless forced" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);

    try fixture.tmp.dir.createDirPath(testing.io, "home-dir");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "home-dir/notes.txt", .data = "mine" });
    const source = try fixture.unit(arena, "0.3.0", &unit_files);
    const foreign = try fixture.path(arena, "home-dir");
    try testing.expectError(error.PrefixOccupied, run(arena, testing.io, source, .{ .prefix = foreign, .self_check = false }, &log.writer));
    try testing.expectEqualStrings("mine", try read(arena, try std.fs.path.join(arena, &.{ foreign, "notes.txt" })));
    _ = try run(arena, testing.io, source, .{ .prefix = foreign, .force = true, .self_check = false }, &log.writer);

    const prefix = try fixture.path(arena, "opt/mc");
    _ = try run(arena, testing.io, source, .{ .prefix = prefix, .self_check = false }, &log.writer);
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const newer = try fixture.unit(arena, "0.4.0", &unit_files);
    try testing.expectError(error.DifferentVersionInstalled, run(arena, testing.io, newer, .{ .prefix = prefix, .self_check = false }, &log.writer));
    _ = try run(arena, testing.io, newer, .{ .prefix = prefix, .force = true, .self_check = false }, &log.writer);

    try testing.expectError(error.PrefixNotAbsolute, run(arena, testing.io, newer, .{ .prefix = "relative/prefix", .self_check = false }, &log.writer));
    try testing.expectError(error.StateDirNotAbsolute, run(arena, testing.io, newer, .{ .prefix = prefix, .state_dir = "state", .force = true, .self_check = false }, &log.writer));
}

test "install refuses a tampered unit and a tree that is not a release unit" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const source = try fixture.unit(arena, "0.3.0", &unit_files);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "unit/vendor/tinykg/tinykgd", .data = "swapped" });
    try testing.expectError(error.DigestMismatch, run(arena, testing.io, source, .{ .prefix = try fixture.path(arena, "p1"), .self_check = false }, &log.writer));

    try fixture.tmp.dir.createDirPath(testing.io, "dev/bin");
    try testing.expectError(error.NotAReleaseUnit, run(arena, testing.io, try fixture.path(arena, "dev"), .{ .prefix = try fixture.path(arena, "p2"), .self_check = false }, &log.writer));

    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "dev/manifest.json", .data = "{\"schema_version\":1,\"name\":\"metacodes-cli\",\"release\":{\"version\":\"0.1.0\"},\"files\":[]}" });
    try testing.expectError(error.UnsupportedManifest, run(arena, testing.io, try fixture.path(arena, "dev"), .{ .prefix = try fixture.path(arena, "p3"), .self_check = false }, &log.writer));
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "dev/manifest.json", .data = "{\"schema_version\":2,\"name\":\"metacodes-cli\",\"release\":{\"version\":\"0.1.0\"},\"files\":[{\"path\":\"../../etc/passwd\",\"sha256\":\"x\"}]}" });
    try testing.expectError(error.UnsupportedManifest, run(arena, testing.io, try fixture.path(arena, "dev"), .{ .prefix = try fixture.path(arena, "p4"), .self_check = false }, &log.writer));
}

test "install places the SDK bundle and a launcher" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const source = try fixture.unit(arena, "0.3.0", &unit_files);

    try fixture.tmp.dir.createDirPath(testing.io, "sdk-bundle/include/metask");
    const header = "/* agentcore */\n";
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "sdk-bundle/include/metask/agentcore.h", .data = header });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(header, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "sdk-bundle/manifest.json",
        .data = try std.fmt.allocPrint(arena, "{{\"schema_version\":1,\"name\":\"agentcore\",\"files\":[{{\"path\":\"include/metask/agentcore.h\",\"sha256\":\"{s}\"}}]}}", .{&hex}),
    });
    const prefix = try fixture.path(arena, "opt/mc");
    const bin_dir = try fixture.path(arena, "local/bin");
    const outcome = try run(arena, testing.io, source, .{
        .prefix = prefix,
        .sdk = try fixture.path(arena, "sdk-bundle"),
        .link_dir = bin_dir,
        .link_name = "mc-a",
        .self_check = false,
    }, &log.writer);
    try testing.expectEqualStrings(header, try read(arena, try std.fs.path.join(arena, &.{ outcome.sdk.?, "include/metask/agentcore.h" })));
    const launcher = try read(arena, outcome.launcher.?);
    try testing.expect(std.mem.indexOf(u8, launcher, outcome.executable) != null);

    // Another install's launcher of the same name is not overwritten silently.
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "local/bin/mc-b", .data = "#!/bin/sh\nexec /elsewhere/bin/metacodes \"$@\"\n" });
    try testing.expectError(error.LinkOccupied, run(arena, testing.io, source, .{ .prefix = prefix, .link_dir = bin_dir, .link_name = "mc-b", .self_check = false }, &log.writer));

    // A bundle of the wrong unit is not an SDK.
    try testing.expectError(error.InvalidSdkBundle, run(arena, testing.io, source, .{ .prefix = prefix, .sdk = source, .self_check = false }, &log.writer));
}
