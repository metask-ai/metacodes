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
//! allowed, and `--upgrade` replaces another version of this product's install
//! (and nothing else). Replacing a version removes the files the previous
//! unit's manifest listed and the new one does not; the state root is never
//! touched. Install logic lives here, once, for every platform:
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
    /// Replace another version of this product's install. Unlike `force` it
    /// never overrides foreign files or someone else's launcher, so an
    /// unattended installer (`curl … | sh`) can pass it on every run.
    upgrade: bool = false,
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
    state_root: []const u8 = "",
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
    if (!in_place) try checkPrefix(arena, io, options.prefix, version, options.force or options.upgrade, options.force);
    // What the install being replaced shipped, to remove what this one drops.
    const previous: ?UnitManifest = if (in_place) null else readUnitManifest(arena, io, options.prefix) catch null;
    // Refuse a bad SDK before anything is written.
    const sdk_manifest: ?SdkManifest = if (options.sdk) |sdk| try readSdkManifest(arena, io, sdk) else null;

    // Everything below names the prefix by its physical path: the installed
    // executable derives its prefix from its own real path, so `/tmp/x` on
    // macOS is `/private/tmp/x` to it, and its doctor must report the same root.
    // An existing prefix may itself be a symlink to a directory, which
    // createDirPath refuses; open it first (following links).
    var created_prefix = false;
    if (cwd.openDir(io, options.prefix, .{})) |opened| {
        var dir = opened;
        dir.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {
            try cwd.createDirPath(io, options.prefix);
            created_prefix = true;
        },
        else => return err,
    }
    const prefix = try realPathAlloc(arena, io, options.prefix);
    const executable = try std.fs.path.join(arena, &.{ prefix, "bin", if (is_windows) "metacodes.exe" else "metacodes" });

    // A launcher name that is taken is refused before any file is written,
    // like a bad SDK: a refusal must not leave a half-replaced install.
    const launcher: ?Launcher = if (options.link_dir) |dir|
        planLauncher(arena, io, dir, options.link_name, executable, options.force) catch |err| {
            if (created_prefix) cwd.deleteDir(io, prefix) catch {};
            return err;
        }
    else
        null;

    // The record first: a copy that fails half way leaves a prefix that the
    // same version may retry without --force.
    // A reinstall or upgrade keeps the root the install already records unless
    // --state-dir names another: rerunning the installer must never re-point
    // an install at an empty state root.
    const kept_root: ?[]const u8 = if (options.state_dir == null) try previousStateRoot(arena, io, prefix) else null;
    const recorded_root = options.state_dir orelse kept_root orelse "state";
    const resolved_root = if (std.fs.path.isAbsolute(recorded_root)) recorded_root else try std.fs.path.join(arena, &.{ prefix, recorded_root });
    try util_fs.mkdirParents(resolved_root);
    const record = try std.json.Stringify.valueAlloc(arena, .{
        .schema_version = state_root.manifest_schema,
        .version = version,
        .state_root = recorded_root,
    }, .{ .whitespace = .indent_2 });
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ prefix, "etc", "metacodes" }));
    try cwd.writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ prefix, install_manifest_rel }),
        .data = try std.fmt.allocPrint(arena, "{s}\n", .{record}),
    });

    // The unit's files, each re-hashed where it landed.
    for (manifest.files) |file| {
        try checkRelative(file.path);
        const destination = try std.fs.path.join(arena, &.{ prefix, file.path });
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
            try std.fs.path.join(arena, &.{ prefix, "manifest.json" }),
            io,
            .{},
        );
    }
    if (previous) |old| try removeDropped(arena, io, prefix, old, manifest, log);
    try log.print("installed metacodes {s}: {d} files verified under {s}\n", .{ version, manifest.files.len, prefix });
    try log.print("state root: {s}{s}\n", .{ resolved_root, if (kept_root != null) " (kept from the install record)" else "" });

    var outcome: Outcome = .{
        .version = version,
        .prefix = prefix,
        .executable = executable,
        .state_root = resolved_root,
        .files = manifest.files.len,
        .in_place = in_place,
    };

    if (sdk_manifest) |sdk| outcome.sdk = try installSdk(arena, io, options.sdk.?, sdk, prefix, log);
    if (launcher) |plan| outcome.launcher = try writeLauncher(arena, io, plan, log);
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
/// version; another version needs `--upgrade` (or `--force`), anything else
/// `--force`.
fn checkPrefix(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, version: []const u8, replace_version: bool, force: bool) !void {
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
    if (!std.mem.eql(u8, record.version, version) and !replace_version) return error.DifferentVersionInstalled;
}

/// The state root this prefix's install record names, when it holds a valid
/// record of this product: absolute, or a relative path that stays inside the
/// prefix. Anything else is no root to keep.
fn previousStateRoot(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) !?[]const u8 {
    const record_path = try std.fs.path.join(arena, &.{ prefix, install_manifest_rel });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, record_path, arena, .limited(64 << 10)) catch return null;
    const record = std.json.parseFromSliceLeaky(InstallRecord, arena, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.eql(u8, record.schema_version, state_root.manifest_schema) or record.state_root.len == 0) return null;
    if (std.fs.path.isAbsolute(record.state_root)) return record.state_root;
    checkRelative(record.state_root) catch return null;
    return record.state_root;
}

/// Files the replaced unit listed and this one does not: a renamed or dropped
/// asset must not linger beside the new executable. Only manifest paths, each
/// held inside the prefix, are ever removed.
fn removeDropped(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, old: UnitManifest, new: UnitManifest, log: *std.Io.Writer) !void {
    const cwd = std.Io.Dir.cwd();
    outer: for (old.files) |file| {
        checkRelative(file.path) catch continue;
        for (new.files) |kept| if (std.mem.eql(u8, kept.path, file.path)) continue :outer;
        const path = try std.fs.path.join(arena, &.{ prefix, file.path });
        cwd.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try log.print("removed {s} (not part of this version)\n", .{file.path});
    }
}

fn readSdkManifest(arena: std.mem.Allocator, io: std.Io, bundle: []const u8) !SdkManifest {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ bundle, "manifest.json" }), arena, .limited(4 << 20)) catch
        return error.InvalidSdkBundle;
    const manifest = std.json.parseFromSliceLeaky(SdkManifest, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidSdkBundle;
    if (!std.mem.eql(u8, manifest.name, sdk_name)) return error.InvalidSdkBundle;
    for (manifest.files) |file| checkRelative(file.path) catch return error.InvalidSdkBundle;
    return manifest;
}

fn installSdk(arena: std.mem.Allocator, io: std.Io, bundle: []const u8, manifest: SdkManifest, prefix: []const u8, log: *std.Io.Writer) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const destination_root = try std.fs.path.join(arena, &.{ prefix, "sdk", "agentcore" });
    // Replace a previous SDK wholesale: a stale header beside a new library is
    // worse than none.
    cwd.deleteTree(io, destination_root) catch {};
    for (manifest.files) |file| {
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

const Launcher = struct {
    dir: []const u8,
    path: []const u8,
    body: []const u8,
    /// A symlink sits at `path` and `--force` allows replacing it.
    replace_symlink: bool,
};

/// A launcher, not a symlink: the executable finds its kernels, TinyKG and
/// install.json beside its own physical path either way, but a script keeps
/// working when the directory it sits in is copied or synced. Decides without
/// writing whether the name is free: absent, or this install's own launcher.
fn planLauncher(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, executable: []const u8, force: bool) !Launcher {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return error.LinkOccupied;
    const file_name = if (is_windows) try std.fmt.allocPrint(arena, "{s}.cmd", .{name}) else name;
    const path = try std.fs.path.join(arena, &.{ dir, file_name });
    const body = try launcherBody(arena, executable);
    const pfs = @import("platform").fs;
    const path_z = try arena.dupeZ(u8, path);
    // Never write through a symlink: `~/.local/bin/metacodes -> <a build>` is
    // common, and following it would overwrite that binary with this script.
    if (pfs.isSymlink(path_z.ptr)) {
        if (!force) return error.LinkOccupied;
        return .{ .dir = dir, .path = path, .body = body, .replace_symlink = true };
    }
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10))) |existing| {
        if (!std.mem.eql(u8, existing, body) and !force) return error.LinkOccupied;
    } else |err| switch (err) {
        error.FileNotFound => {},
        // Something large sits there (a binary, not a launcher).
        error.StreamTooLong => if (!force) return error.LinkOccupied,
        else => return err,
    }
    return .{ .dir = dir, .path = path, .body = body, .replace_symlink = false };
}

fn writeLauncher(arena: std.mem.Allocator, io: std.Io, plan: Launcher, log: *std.Io.Writer) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const pfs = @import("platform").fs;
    const path_z = try arena.dupeZ(u8, plan.path);
    if (plan.replace_symlink) pfs.unlinkPath(path_z.ptr) catch return error.LinkOccupied;
    try cwd.createDirPath(io, plan.dir);
    try cwd.writeFile(io, .{ .sub_path = plan.path, .data = plan.body });
    if (!is_windows) _ = pfs.chmod(path_z.ptr, 0o755);
    try log.print("launcher: {s}\n", .{plan.path});
    return plan.path;
}

/// The launcher script for `executable`, quoted so that no character of the
/// path is interpreted by the shell (POSIX) or by cmd's `%` expansion.
fn launcherBody(arena: std.mem.Allocator, executable: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    if (is_windows) {
        for (executable) |c| {
            if (c == '%') try quoted.append(arena, '%');
            try quoted.append(arena, c);
        }
        return std.fmt.allocPrint(arena, "@\"{s}\" %*\r\n", .{quoted.items});
    }
    try quoted.append(arena, '\'');
    for (executable) |c| {
        if (c == '\'') try quoted.appendSlice(arena, "'\\''") else try quoted.append(arena, c);
    }
    try quoted.append(arena, '\'');
    return std.fmt.allocPrint(arena, "#!/bin/sh\n# metacodes launcher written by `metacodes install`\nexec {s} \"$@\"\n", .{quoted.items});
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
    const reported = parseStateRootLine(captured.stdout) orelse return error.SelfCheckFailed;
    if (std.mem.eql(u8, reported.source, "install") and std.mem.eql(u8, reported.path, outcome.state_root)) return;
    // Windows always hands the child the caller's environment, so an exported
    // METACODES_HOME legitimately wins there; POSIX must read the record.
    if (is_windows and std.mem.eql(u8, reported.source, "env")) {
        try log.print("note: METACODES_HOME ({s}) overrides this install's state root while it is set\n", .{reported.path});
        return;
    }
    try log.print("the installed doctor resolved state_root {s} (source={s}), expected {s} from the install record\n", .{ reported.path, reported.source, outcome.state_root });
    return error.SelfCheckFailed;
}

const StateRootLine = struct { path: []const u8, source: []const u8 };

/// `state_root <path> source=<source> error=<error>` from `doctor` text output.
fn parseStateRootLine(text: []const u8) ?StateRootLine {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "state_root ")) continue;
        const rest = line["state_root ".len..];
        const source_at = std.mem.lastIndexOf(u8, rest, " source=") orelse return null;
        const after = rest[source_at + " source=".len ..];
        const source_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
        return .{ .path = rest[0..source_at], .source = after[0..source_end] };
    }
    return null;
}

fn realPathAlloc(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buffer);
    return arena.dupe(u8, buffer[0..len]);
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
    // --upgrade replaces another version but never foreign files.
    try fixture.tmp.dir.createDirPath(testing.io, "home-dir2");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "home-dir2/notes.txt", .data = "mine" });
    try testing.expectError(error.PrefixOccupied, run(arena, testing.io, newer, .{ .prefix = try fixture.path(arena, "home-dir2"), .upgrade = true, .self_check = false }, &log.writer));

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

test "a failed install of a version may be retried without --force; a bad SDK writes nothing" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const source = try fixture.unit(arena, "0.3.0", &unit_files);
    const prefix = try fixture.path(arena, "opt/mc");

    try testing.expectError(error.InvalidSdkBundle, run(arena, testing.io, source, .{ .prefix = prefix, .sdk = try fixture.path(arena, "no-sdk"), .self_check = false }, &log.writer));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, prefix, .{}));

    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "unit/vendor/tinykg/tinykgd", .data = "damaged" });
    try testing.expectError(error.DigestMismatch, run(arena, testing.io, source, .{ .prefix = prefix, .self_check = false }, &log.writer));
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "unit/vendor/tinykg/tinykgd", .data = "daemon" });
    _ = try run(arena, testing.io, source, .{ .prefix = prefix, .self_check = false }, &log.writer);
}

test "install names the prefix by its physical path" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const source = try fixture.unit(arena, "0.3.0", &unit_files);
    try fixture.tmp.dir.createDirPath(testing.io, "real/opt");
    try fixture.tmp.dir.symLink(testing.io, "real/opt", "alias", .{ .is_directory = true });
    const outcome = try run(arena, testing.io, source, .{ .prefix = try fixture.path(arena, "alias"), .self_check = false }, &log.writer);
    try testing.expectEqualStrings(try fixture.path(arena, "real/opt"), outcome.prefix);
    try testing.expectEqualStrings(try fixture.path(arena, "real/opt/state"), outcome.state_root);
    // What the installed executable resolves from its own real path.
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try state_root.resolveFrom(.{ .exe_path = outcome.executable }, &resolved_buf);
    try testing.expectEqualStrings(outcome.state_root, resolved.path);
}

test "the launcher never writes through a symlink and quotes its path" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const source = try fixture.unit(arena, "0.3.0", &unit_files);
    try fixture.tmp.dir.createDirPath(testing.io, "dev/zig-out/bin");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "dev/zig-out/bin/metacodes", .data = "developer build" });
    try fixture.tmp.dir.createDirPath(testing.io, "local/bin");
    const target = try fixture.path(arena, "dev/zig-out/bin/metacodes");
    try fixture.tmp.dir.symLink(testing.io, target, "local/bin/metacodes", .{});
    const bin_dir = try fixture.path(arena, "local/bin");
    const prefix = try fixture.path(arena, "it's $HOME `x`");

    try testing.expectError(error.LinkOccupied, run(arena, testing.io, source, .{ .prefix = prefix, .link_dir = bin_dir, .self_check = false }, &log.writer));
    // Refused before anything is written: not even the prefix it created.
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "it's $HOME `x`", .{}));
    const outcome = try run(arena, testing.io, source, .{ .prefix = prefix, .link_dir = bin_dir, .force = true, .self_check = false }, &log.writer);
    // A taken launcher name stops an upgrade before it replaces a single file.
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "local/bin/other", .data = "#!/bin/sh\necho other\n" });
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const newer = try fixture.unit(arena, "0.4.0", &.{.{ "bin/metacodes", "exe 0.4" }});
    try testing.expectError(error.LinkOccupied, run(arena, testing.io, newer, .{ .prefix = prefix, .link_dir = bin_dir, .link_name = "other", .upgrade = true, .self_check = false }, &log.writer));
    try testing.expectEqualStrings("exe", try read(arena, try std.fs.path.join(arena, &.{ prefix, "bin", "metacodes" })));
    try testing.expectEqualStrings("developer build", try read(arena, target)); // untouched
    const launcher = try read(arena, outcome.launcher.?);
    const expected_exec = try std.fmt.allocPrint(arena, "exec '{s}/it'\\''s $HOME `x`/bin/metacodes' \"$@\"\n", .{fixture.root});
    try testing.expect(std.mem.endsWith(u8, launcher, expected_exec));
}

test "upgrade replaces another version, drops its retired files and keeps the state root" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);

    const old_files = unit_files ++ [_][2][]const u8{.{ "share/doc/OLD.md", "retired" }};
    const prefix = try fixture.path(arena, "opt/mc");
    _ = try run(arena, testing.io, try fixture.unit(arena, "0.3.0", &old_files), .{ .prefix = prefix, .self_check = false }, &log.writer);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "opt/mc/state/config.json", .data = "{}" });
    try fixture.tmp.dir.deleteTree(testing.io, "unit");

    const newer = try fixture.unit(arena, "0.4.0", &unit_files);
    const outcome = try run(arena, testing.io, newer, .{ .prefix = prefix, .upgrade = true, .self_check = false }, &log.writer);
    try testing.expectEqualStrings("0.4.0", outcome.version);
    try testing.expect(std.mem.indexOf(u8, try read(arena, try fixture.path(arena, "opt/mc/etc/metacodes/install.json")), "0.4.0") != null);
    try testing.expectError(error.FileNotFound, read(arena, try fixture.path(arena, "opt/mc/share/doc/OLD.md")));
    try testing.expectEqualStrings("daemon", try read(arena, try fixture.path(arena, "opt/mc/vendor/tinykg/tinykgd")));
    try testing.expectEqualStrings("{}", try read(arena, try fixture.path(arena, "opt/mc/state/config.json")));
    // Reinstalling the same version removes nothing.
    _ = try run(arena, testing.io, newer, .{ .prefix = prefix, .upgrade = true, .self_check = false }, &log.writer);
    try testing.expectEqualStrings("exe", try read(arena, try fixture.path(arena, "opt/mc/bin/metacodes")));
}

test "a reinstall or upgrade keeps the recorded state root unless --state-dir names another" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);

    const prefix = try fixture.path(arena, "opt/mc");
    const shared = try fixture.path(arena, "home/.metacodes");
    const record_path = try fixture.path(arena, "opt/mc/etc/metacodes/install.json");
    _ = try run(arena, testing.io, try fixture.unit(arena, "0.3.0", &unit_files), .{ .prefix = prefix, .state_dir = shared, .self_check = false }, &log.writer);
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const newer = try fixture.unit(arena, "0.4.0", &unit_files);

    // No --state-dir on the upgrade: the absolute root stays.
    const upgraded = try run(arena, testing.io, newer, .{ .prefix = prefix, .upgrade = true, .self_check = false }, &log.writer);
    try testing.expectEqualStrings(shared, upgraded.state_root);
    try testing.expect(std.mem.indexOf(u8, try read(arena, record_path), shared) != null);
    // Same version again, still no --state-dir: unchanged.
    try testing.expectEqualStrings(shared, (try run(arena, testing.io, newer, .{ .prefix = prefix, .self_check = false }, &log.writer)).state_root);

    // An explicit --state-dir re-points it.
    const other = try fixture.path(arena, "elsewhere");
    try testing.expectEqualStrings(other, (try run(arena, testing.io, newer, .{ .prefix = prefix, .state_dir = other, .self_check = false }, &log.writer)).state_root);

    // A fresh install defaults to <prefix>/state, and keeps it relative.
    const fresh = try fixture.path(arena, "opt/fresh");
    const first = try run(arena, testing.io, newer, .{ .prefix = fresh, .self_check = false }, &log.writer);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ fresh, "state" }), first.state_root);
    try testing.expect(std.mem.indexOf(u8, try read(arena, try fixture.path(arena, "opt/fresh/etc/metacodes/install.json")), "\"state_root\": \"state\"") != null);
}

test "the doctor state_root line parses paths with spaces" {
    const line = parseStateRootLine("tinykg x\nstate_root /a b/state source=install error=-\n").?;
    try testing.expectEqualStrings("/a b/state", line.path);
    try testing.expectEqualStrings("install", line.source);
    try testing.expect(parseStateRootLine("ripgrep /x\n") == null);
}
