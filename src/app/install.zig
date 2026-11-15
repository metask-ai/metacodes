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
//! Writes happen only under `--prefix`, the state root (where only the
//! `.env.example` template is written, never `.env`), and the `--link`
//! directory. A prefix that holds anything but this product's own install is
//! refused unless `--force`; reinstalling the same version over itself is
//! allowed, and `--upgrade` replaces another version of this product's install
//! (and nothing else) — never with an older one unless `--allow-downgrade`, so
//! an installer that fetches "the latest release" cannot move an install
//! backwards when that label points at an older version. A launcher name held
//! by another metacodes install is reported with that install's prefix and
//! version. Replacing a version removes the files the previous
//! unit's manifest listed and the new one does not; in the state root only
//! the template is rewritten. Install logic lives here, once, for every platform:
//! scripts/install.sh and scripts/install.ps1 only unpack an archive and call
//! this.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const state_root = @import("../util/state_root.zig");
const util_fs = @import("../util/fs.zig");
const release_source = @import("release_source.zig");
pub const UpdateSource = release_source.UpdateSource;

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
    /// Let `upgrade` replace a newer version with an older one. Off by default:
    /// the unattended "latest release" path must never downgrade an install.
    allow_downgrade: bool = false,
    /// An unpacked AgentCore SDK bundle (its `manifest.json` names `agentcore`).
    sdk: ?[]const u8 = null,
    /// Directory on PATH that receives a launcher for this install.
    link_dir: ?[]const u8 = null,
    /// Launcher name (`metacodes` by default; several installs need several names).
    link_name: []const u8 = "metacodes",
    /// What the record names as this install's update source
    /// (doc/UPDATE_DESIGN.md §3).
    update_source: SourceChoice = .keep,
    /// Run the installed executable's `doctor --strict` (tests switch it off).
    self_check: bool = true,
    /// The text of `<state root>/.env.example`, the local-configuration
    /// template (#486; `state_env.renderExample`). Written on every install
    /// and upgrade, so it lists the providers of the version installed;
    /// `.env` itself is never created or touched. Null writes none.
    local_config_template: ?[]const u8 = null,
};

pub const SourceChoice = union(enum) {
    /// The previous record's source (`--release-base` and `--checkout` both
    /// absent): an archive installed by hand over a mirrored or development
    /// install keeps updating from where it did. A fresh install gets the
    /// default.
    keep,
    /// `--release-base` (`release_source.parseBase`) or `--checkout`
    /// (`release_source.parseCheckout`).
    set: UpdateSource,
};

pub const Error = error{
    NotAReleaseUnit,
    UnsupportedManifest,
    PrefixNotAbsolute,
    StateDirNotAbsolute,
    PrefixOccupied,
    DifferentVersionInstalled,
    NewerVersionInstalled,
    DigestMismatch,
    InvalidSdkBundle,
    LinkOccupied,
    LinkOwnedByAnotherInstall,
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
    update_source: UpdateSource = .default_release,
};

const unit_name = "metacodes-cli";
const unit_schema: u32 = 2;
const sdk_name = "agentcore";
const install_manifest_rel = state_root.manifest_relative_path;
/// `state_env.example_file_name`, beside the `.env` it documents.
const local_config_example = ".env.example";
const max_artifact_bytes = 256 << 20;

pub const FileEntry = struct { path: []const u8, sha256: []const u8 };

/// The members of a unit's `manifest.json` (release/manifest.schema.json)
/// that installing and updating read. A release manifest always carries
/// them all; the defaults only let the unit tests write small ones.
pub const UnitManifest = struct {
    schema_version: u32,
    name: []const u8,
    release: struct { version: []const u8, channel: []const u8 = "" },
    source: struct { commit: []const u8 = "", dirty: bool = false } = .{},
    target: struct { id: []const u8 = "" } = .{},
    files: []const FileEntry,
};

pub const SdkManifest = struct {
    name: []const u8,
    files: []const FileEntry,
};

const InstallRecord = struct {
    schema_version: []const u8,
    version: []const u8 = "",
    state_root: []const u8 = "",
};

/// The record's `update_source`, parsed on its own: a malformed member must
/// never make the rest of the record unreadable, or a reinstall would forget
/// the state root it names.
const RecordSource = struct {
    update_source: ?release_source.Json = null,
};

/// What the installer writes.
const RecordOut = struct {
    schema_version: []const u8,
    version: []const u8,
    state_root: []const u8,
    update_source: ?release_source.Json,
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
    if (!in_place) try checkPrefix(arena, io, options.prefix, version, .{
        .replace_version = options.force or options.upgrade,
        .allow_downgrade = options.allow_downgrade,
        .force = options.force,
    }, log);
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
        planLauncher(arena, io, dir, options.link_name, executable, options.force, log) catch |err| {
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
    const update_source: UpdateSource = switch (options.update_source) {
        .set => |chosen| chosen,
        .keep => try previousUpdateSource(arena, io, prefix, log),
    };
    const record = try std.json.Stringify.valueAlloc(arena, RecordOut{
        .schema_version = state_root.manifest_schema,
        .version = version,
        .state_root = recorded_root,
        .update_source = release_source.Json.from(update_source),
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
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
    if (options.local_config_template) |template| {
        const example = try std.fs.path.join(arena, &.{ resolved_root, local_config_example });
        try cwd.writeFile(io, .{ .sub_path = example, .data = template });
        try log.print("local configuration: {s}{c}.env (template: {s})\n", .{ resolved_root, std.fs.path.sep, example });
    }
    switch (update_source) {
        .default_release => try log.print("updates from: {s}\n", .{release_source.default_release_base}),
        .mirror => |base| try log.print("updates from: {s} (a mirror)\n", .{base}),
        .checkout => |path| try log.print("updates from: the checkout {s}\n", .{path}),
    }

    var outcome: Outcome = .{
        .version = version,
        .prefix = prefix,
        .executable = executable,
        .state_root = resolved_root,
        .files = manifest.files.len,
        .in_place = in_place,
        .update_source = update_source,
    };

    if (sdk_manifest) |sdk| outcome.sdk = try installSdk(arena, io, options.sdk.?, sdk, prefix, log);
    if (launcher) |plan| outcome.launcher = try writeLauncher(arena, io, plan, log);
    if (options.self_check) try selfCheck(arena, outcome, log);
    return outcome;
}

/// The release manifest of the unit (or install) at `root`.
pub fn readUnitManifest(arena: std.mem.Allocator, io: std.Io, root: []const u8) !UnitManifest {
    const path = try std.fs.path.join(arena, &.{ root, "manifest.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20));
    const manifest = std.json.parseFromSliceLeaky(UnitManifest, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return error.UnsupportedManifest;
    if (!std.mem.eql(u8, manifest.name, unit_name) or manifest.schema_version != unit_schema) return error.UnsupportedManifest;
    return manifest;
}

const Replace = struct { replace_version: bool, allow_downgrade: bool, force: bool };

/// A destination is empty, absent, or this product's install of the same
/// version; another version needs `--upgrade` (or `--force`), an older one
/// than installed also `--allow-downgrade` (or `--force`), anything else
/// `--force`.
fn checkPrefix(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, version: []const u8, replace: Replace, log: *std.Io.Writer) !void {
    const force = replace.force;
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
    if (std.mem.eql(u8, record.version, version)) return;
    if (!replace.replace_version) return error.DifferentVersionInstalled;
    if (!isOlder(version, record.version)) return;
    if (!force and !replace.allow_downgrade) {
        try log.print("{s} holds metacodes {s}, newer than {s}\n", .{ prefix, record.version, version });
        return error.NewerVersionInstalled;
    }
    try log.print("replacing metacodes {s} with the older {s}\n", .{ record.version, version });
}

/// `candidate` precedes `installed` in semantic-version order (pre-releases
/// before their release, build metadata ignored). Versions that do not parse
/// have no order, and nothing is called a downgrade.
pub fn isOlder(candidate: []const u8, installed: []const u8) bool {
    const a = std.SemanticVersion.parse(candidate) catch return false;
    const b = std.SemanticVersion.parse(installed) catch return false;
    return a.order(b) == .lt;
}

/// The version an install's record names, or null without a readable record.
fn recordedVersion(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) ?[]const u8 {
    const record_path = std.fs.path.join(arena, &.{ prefix, install_manifest_rel }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, record_path, arena, .limited(64 << 10)) catch return null;
    const record = std.json.parseFromSliceLeaky(InstallRecord, arena, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.eql(u8, record.schema_version, state_root.manifest_schema) or record.version.len == 0) return null;
    return record.version;
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

/// The update source the prefix's record names (doc/UPDATE_DESIGN.md §3): the
/// default without a record or without the member; a member that is not a
/// valid source is dropped with a note rather than carried forward.
fn previousUpdateSource(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, log: *std.Io.Writer) !UpdateSource {
    const record_path = try std.fs.path.join(arena, &.{ prefix, install_manifest_rel });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, record_path, arena, .limited(64 << 10)) catch return .default_release;
    return switch (try parseRecordSource(arena, bytes)) {
        .valid => |source| source,
        .invalid => {
            try log.print("ignoring the install record's update_source, which is not a valid source\n", .{});
            return .default_release;
        },
    };
}

const ParsedSource = union(enum) { valid: UpdateSource, invalid };

fn parseRecordSource(arena: std.mem.Allocator, bytes: []const u8) !ParsedSource {
    const parsed = std.json.parseFromSliceLeaky(RecordSource, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return .invalid,
    };
    const member = parsed.update_source orelse return .{ .valid = .default_release };
    const source = (try member.toSource(arena)) orelse return .invalid;
    return .{ .valid = source };
}

/// An install record as `metacodes update` reads it.
pub const Record = struct {
    version: []const u8,
    state_root: []const u8,
    update_source: UpdateSource,
    /// The record carries an `update_source` member that is not a valid one.
    invalid_update_source: bool = false,
};

/// The record at `<prefix>/etc/metacodes/install.json`.
pub fn readRecord(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) error{ NoInstallRecord, InvalidInstallRecord, OutOfMemory }!Record {
    const record_path = try std.fs.path.join(arena, &.{ prefix, install_manifest_rel });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, record_path, arena, .limited(64 << 10)) catch |err| switch (err) {
        error.FileNotFound => return error.NoInstallRecord,
        error.OutOfMemory => |e| return e,
        else => return error.InvalidInstallRecord,
    };
    const core = std.json.parseFromSliceLeaky(InstallRecord, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.InvalidInstallRecord,
    };
    if (!std.mem.eql(u8, core.schema_version, state_root.manifest_schema) or core.version.len == 0)
        return error.InvalidInstallRecord;
    return switch (try parseRecordSource(arena, bytes)) {
        .valid => |source| .{ .version = core.version, .state_root = core.state_root, .update_source = source },
        .invalid => .{ .version = core.version, .state_root = core.state_root, .update_source = .default_release, .invalid_update_source = true },
    };
}

/// An install as found, before anything changes it (doc/UPDATE_DESIGN.md §4.1
/// step 3).
pub const Measurement = struct {
    record: Record,
    /// Null when `manifest.json` is missing or unreadable, as after an
    /// install that failed before copying it.
    manifest: ?UnitManifest,
    /// The SDK bundle's manifest, when `sdk/agentcore/manifest.json` exists.
    sdk: ?SdkManifest,
    /// The first thing that is not as the record and manifests say; null when
    /// the install is intact: the record names the manifest's version and
    /// every file either manifest lists is present with its digest.
    problem: ?[]const u8,

    pub fn intact(self: Measurement) bool {
        return self.problem == null;
    }

    /// The version to compare against: for an install that is not intact the
    /// higher of the record's and the manifest's, so a half-finished upgrade
    /// is completed rather than undone.
    pub fn installedVersion(self: Measurement) []const u8 {
        const manifest = self.manifest orelse return self.record.version;
        if (isOlder(self.record.version, manifest.release.version)) return manifest.release.version;
        return self.record.version;
    }
};

pub fn measure(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) !Measurement {
    const record = try readRecord(arena, io, prefix);
    var result: Measurement = .{ .record = record, .manifest = null, .sdk = null, .problem = null };
    result.manifest = readUnitManifest(arena, io, prefix) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => null,
    };
    const sdk_root = try std.fs.path.join(arena, &.{ prefix, "sdk", "agentcore" });
    const sdk_manifest_path = try std.fs.path.join(arena, &.{ sdk_root, "manifest.json" });
    if (std.Io.Dir.cwd().access(io, sdk_manifest_path, .{})) |_| {
        result.sdk = readSdkManifest(arena, io, sdk_root) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => blk: {
                result.problem = "sdk/agentcore/manifest.json is not an AgentCore bundle manifest";
                break :blk null;
            },
        };
    } else |_| {}
    const manifest = result.manifest orelse {
        result.problem = "manifest.json is missing or not a metacodes-cli schema 2 manifest";
        return result;
    };
    if (!std.mem.eql(u8, manifest.release.version, record.version)) {
        result.problem = try std.fmt.allocPrint(arena, "the record names {s} but manifest.json {s}", .{ record.version, manifest.release.version });
        return result;
    }
    if (result.problem != null) return result;
    if (try firstMismatch(arena, io, prefix, manifest.files)) |path| {
        result.problem = try std.fmt.allocPrint(arena, "{s} is missing or does not match the manifest", .{path});
        return result;
    }
    if (result.sdk) |sdk| if (try firstMismatch(arena, io, sdk_root, sdk.files)) |path| {
        result.problem = try std.fmt.allocPrint(arena, "sdk/agentcore/{s} is missing or does not match the SDK manifest", .{path});
    };
    return result;
}

/// The first listed file under `root` that is absent, unreadable or not the
/// listed digest.
pub fn firstMismatch(arena: std.mem.Allocator, io: std.Io, root: []const u8, files: []const FileEntry) !?[]const u8 {
    for (files) |file| {
        checkRelative(file.path) catch return file.path;
        const path = try std.fs.path.join(arena, &.{ root, file.path });
        const digest = fileDigest(io, path) catch return file.path;
        if (!std.mem.eql(u8, &digest, file.sha256)) return file.path;
    }
    return null;
}

/// The lowercase hex SHA-256 of a file, streamed rather than read whole.
pub fn fileDigest(io: std.Io, path: []const u8) ![64]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var hash_buffer: [64]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&hash_buffer);
    _ = reader.interface.streamRemaining(&hashing.writer) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => unreachable, // hashing never fails to write
    };
    try hashing.writer.flush();
    return std.fmt.bytesToHex(hashing.hasher.finalResult(), .lower);
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

/// The manifest of an unpacked AgentCore SDK bundle.
pub fn readSdkManifest(arena: std.mem.Allocator, io: std.Io, bundle: []const u8) !SdkManifest {
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
/// writing whether the name is free: absent, or this install's own launcher
/// (byte for byte, or one `metacodes install` wrote for this executable in
/// another form). Another metacodes install's launcher is named in `log`.
fn planLauncher(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, executable: []const u8, force: bool, log: *std.Io.Writer) !Launcher {
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
        if (!std.mem.eql(u8, existing, body) and !force) {
            const target = (try launcherTarget(arena, existing)) orelse return error.LinkOccupied;
            const target_bin = std.fs.path.dirname(target) orelse return error.LinkOccupied;
            const own_bin = std.fs.path.dirname(executable) orelse return error.LinkOccupied;
            // This install's own launcher, written in another form: replace it.
            if (!samePath(io, target_bin, own_bin)) {
                const other_prefix = std.fs.path.dirname(target_bin) orelse target_bin;
                if (recordedVersion(arena, io, other_prefix)) |other_version| {
                    try log.print("{s} runs the metacodes {s} install at {s}\n", .{ path, other_version, other_prefix });
                } else {
                    try log.print("{s} runs {s}, which has no metacodes install record (removed?)\n", .{ path, target });
                }
                return error.LinkOwnedByAnotherInstall;
            }
        }
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

/// The executable a launcher written by `launcherBody` runs, or null when
/// `body` is anything else (another script, a binary). Any form
/// `launcherBody` has written reads back: the marker line and the `exec`
/// line are all it looks at.
pub fn launcherTarget(arena: std.mem.Allocator, body: []const u8) !?[]const u8 {
    var target: std.ArrayList(u8) = .empty;
    if (is_windows) {
        if (!std.mem.startsWith(u8, body, "@\"")) return null;
        const end = std.mem.lastIndexOf(u8, body, "\" %*") orelse return null;
        if (end < 2) return null;
        var i: usize = 2;
        while (i < end) : (i += 1) {
            try target.append(arena, body[i]);
            if (body[i] == '%' and i + 1 < end and body[i + 1] == '%') i += 1;
        }
        return target.items;
    }
    if (std.mem.indexOf(u8, body, "\n# metacodes launcher written by `metacodes install`\n") == null) return null;
    const start = (std.mem.indexOf(u8, body, "\nexec '") orelse return null) + "\nexec '".len;
    var i = start;
    while (true) {
        const close = std.mem.indexOfScalarPos(u8, body, i, '\'') orelse return null;
        try target.appendSlice(arena, body[i..close]);
        // `'\''` is a closed quote, an escaped quote, and a reopened one.
        if (std.mem.startsWith(u8, body[close..], "'\\''")) {
            try target.append(arena, '\'');
            i = close + 4;
            continue;
        }
        break;
    }
    return target.items;
}

/// The launcher script for `executable`, quoted so that no character of the
/// path is interpreted by the shell (POSIX) or by cmd's `%` expansion.
///
/// The POSIX script exports its own path (`$0`) as `METACODES_LAUNCHER`
/// first: `exec` hands the executable its own path as argv[0], the same for
/// every install, so this is how a run learns that the user typed
/// `metacodes-dev` and names that command in its messages
/// (app/invocation.zig, #482). Argv[0] itself is left alone, so `ps` still
/// shows the install's path, which `install.sh --uninstall` looks for.
pub fn launcherBody(arena: std.mem.Allocator, executable: []const u8) ![]const u8 {
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
    return std.fmt.allocPrint(
        arena,
        "#!/bin/sh\n# metacodes launcher written by `metacodes install`\nexport {s}=\"$0\"\nexec {s} \"$@\"\n",
        .{ @import("platform").paths.launcher_env_name, quoted.items },
    );
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

test "install and upgrade rewrite the .env.example template and never create or touch .env (#486)" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const prefix = try fixture.path(arena, "opt/mc");
    const example = try fixture.path(arena, "opt/mc/state/.env.example");
    const env = try fixture.path(arena, "opt/mc/state/.env");

    _ = try run(arena, testing.io, try fixture.unit(arena, "0.3.0", &unit_files), .{
        .prefix = prefix,
        .self_check = false,
        .local_config_template = "# template 0.3.0\n",
    }, &log.writer);
    try testing.expectEqualStrings("# template 0.3.0\n", try read(arena, example));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, env, .{}));

    // The user's file survives an upgrade byte for byte; the template follows
    // the version installed.
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "opt/mc/state/.env", .data = "DEEPSEEK_API_KEY=mine\n" });
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    _ = try run(arena, testing.io, try fixture.unit(arena, "0.4.0", &unit_files), .{
        .prefix = prefix,
        .upgrade = true,
        .self_check = false,
        .local_config_template = "# template 0.4.0\n",
    }, &log.writer);
    try testing.expectEqualStrings("# template 0.4.0\n", try read(arena, example));
    try testing.expectEqualStrings("DEEPSEEK_API_KEY=mine\n", try read(arena, env));
}

test "the record names its update source: set, kept across reinstalls, replaced and cleared" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const prefix = try fixture.path(arena, "opt/mc");
    const unit = try fixture.unit(arena, "0.3.0", &unit_files);

    // A fresh install without either option: the default, and no member.
    const fresh = try run(arena, testing.io, unit, .{ .prefix = prefix, .self_check = false }, &log.writer);
    try testing.expect(fresh.update_source == .default_release);
    try testing.expect(std.mem.indexOf(u8, try read(arena, try fixture.path(arena, "opt/mc/etc/metacodes/install.json")), "update_source") == null);
    try testing.expect((try readRecord(arena, testing.io, prefix)).update_source == .default_release);

    // --release-base records the mirror, and a reinstall without it keeps it.
    const mirror = try release_source.parseBase(arena, "https://mirror.example/metacodes/releases/");
    _ = try run(arena, testing.io, unit, .{ .prefix = prefix, .update_source = .{ .set = mirror }, .self_check = false }, &log.writer);
    try testing.expect((try readRecord(arena, testing.io, prefix)).update_source.eql(mirror));
    const kept = try run(arena, testing.io, unit, .{ .prefix = prefix, .self_check = false }, &log.writer);
    try testing.expect(kept.update_source.eql(mirror));
    try testing.expect((try readRecord(arena, testing.io, prefix)).update_source.eql(mirror));
    // An upgrade keeps it too.
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const newer = try fixture.unit(arena, "0.4.0", &unit_files);
    _ = try run(arena, testing.io, newer, .{ .prefix = prefix, .upgrade = true, .self_check = false }, &log.writer);
    try testing.expect((try readRecord(arena, testing.io, prefix)).update_source.eql(mirror));

    // A checkout replaces it; naming the default base clears any source.
    const checkout = try release_source.parseCheckout(arena, "/home/me/src/metacodes");
    _ = try run(arena, testing.io, newer, .{ .prefix = prefix, .update_source = .{ .set = checkout }, .self_check = false }, &log.writer);
    try testing.expect((try readRecord(arena, testing.io, prefix)).update_source.eql(checkout));
    _ = try run(arena, testing.io, newer, .{ .prefix = prefix, .update_source = .{ .set = try release_source.parseBase(arena, release_source.default_release_base) }, .self_check = false }, &log.writer);
    try testing.expect((try readRecord(arena, testing.io, prefix)).update_source == .default_release);
    try testing.expect(std.mem.indexOf(u8, try read(arena, try fixture.path(arena, "opt/mc/etc/metacodes/install.json")), "update_source") == null);
}

test "a malformed update_source is dropped with a note and never costs the state root" {
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
    const unit = try fixture.unit(arena, "0.3.0", &unit_files);
    _ = try run(arena, testing.io, unit, .{ .prefix = prefix, .state_dir = shared, .self_check = false }, &log.writer);

    for ([_][]const u8{
        "\"update_source\": \"https://mirror.example/r\"",
        "\"update_source\": {\"kind\": \"release\", \"base\": \"http://mirror.example/r\"}",
        "\"update_source\": {\"kind\": \"checkout\", \"path\": \"relative\"}",
    }) |member| {
        const record = try std.fmt.allocPrint(arena, "{{\"schema_version\": \"{s}\", \"version\": \"0.3.0\", \"state_root\": \"{s}\", {s}}}\n", .{ state_root.manifest_schema, shared, member });
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "opt/mc/etc/metacodes/install.json", .data = record });
        const read_back = try readRecord(arena, testing.io, prefix);
        try testing.expect(read_back.invalid_update_source);
        try testing.expectEqualStrings(shared, read_back.state_root);

        log.clearRetainingCapacity();
        const outcome = try run(arena, testing.io, unit, .{ .prefix = prefix, .self_check = false }, &log.writer);
        try testing.expectEqualStrings(shared, outcome.state_root);
        try testing.expect(outcome.update_source == .default_release);
        try testing.expect(std.mem.indexOf(u8, log.written(), "ignoring the install record's update_source") != null);
    }
}

test "measuring an install for update: intact, a missing or altered file, a half-written record, a damaged SDK" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const prefix = try fixture.path(arena, "opt/mc");
    try testing.expectError(error.NoInstallRecord, measure(arena, testing.io, prefix));

    const sdk_dir = try fixture.path(arena, "sdk");
    try fixture.tmp.dir.createDirPath(testing.io, "sdk/lib");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "sdk/lib/libagentcore.a", .data = "lib" });
    const lib_hex = std.fmt.bytesToHex(blk: {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("lib", &d, .{});
        break :blk d;
    }, .lower);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "sdk/manifest.json", .data = try std.fmt.allocPrint(arena, "{{\"name\":\"agentcore\",\"files\":[{{\"path\":\"lib/libagentcore.a\",\"sha256\":\"{s}\"}}]}}", .{&lib_hex}) });
    _ = try run(arena, testing.io, try fixture.unit(arena, "0.3.0", &unit_files), .{ .prefix = prefix, .sdk = sdk_dir, .self_check = false }, &log.writer);

    const intact = try measure(arena, testing.io, prefix);
    try testing.expect(intact.intact());
    try testing.expectEqualStrings("0.3.0", intact.installedVersion());
    try testing.expect(intact.sdk != null);

    // An altered file.
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "opt/mc/vendor/tinykg/tinykgd", .data = "tampered" });
    try testing.expect(std.mem.indexOf(u8, (try measure(arena, testing.io, prefix)).problem.?, "vendor/tinykg/tinykgd") != null);
    // A missing one.
    try fixture.tmp.dir.deleteFile(testing.io, "opt/mc/vendor/tinykg/tinykgd");
    try testing.expect(std.mem.indexOf(u8, (try measure(arena, testing.io, prefix)).problem.?, "vendor/tinykg/tinykgd") != null);
    _ = try run(arena, testing.io, try fixture.path(arena, "unit"), .{ .prefix = prefix, .self_check = false }, &log.writer);
    try testing.expect((try measure(arena, testing.io, prefix)).intact());

    // A damaged SDK file.
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "opt/mc/sdk/agentcore/lib/libagentcore.a", .data = "x" });
    try testing.expect(std.mem.indexOf(u8, (try measure(arena, testing.io, prefix)).problem.?, "sdk/agentcore/lib/libagentcore.a") != null);
    _ = try run(arena, testing.io, try fixture.path(arena, "unit"), .{ .prefix = prefix, .sdk = sdk_dir, .self_check = false }, &log.writer);

    // The record already names the next version, the manifest is still the
    // old one: not intact, and the higher version is the installed one.
    const record = try std.fmt.allocPrint(arena, "{{\"schema_version\": \"{s}\", \"version\": \"0.4.0\", \"state_root\": \"state\"}}\n", .{state_root.manifest_schema});
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "opt/mc/etc/metacodes/install.json", .data = record });
    const half = try measure(arena, testing.io, prefix);
    try testing.expect(!half.intact());
    try testing.expectEqualStrings("0.4.0", half.installedVersion());
    // Without manifest.json at all.
    try fixture.tmp.dir.deleteFile(testing.io, "opt/mc/manifest.json");
    const bare = try measure(arena, testing.io, prefix);
    try testing.expect(bare.manifest == null and !bare.intact());
    try testing.expectEqualStrings("0.4.0", bare.installedVersion());
}

test "the doctor state_root line parses paths with spaces" {
    const line = parseStateRootLine("tinykg x\nstate_root /a b/state source=install error=-\n").?;
    try testing.expectEqualStrings("/a b/state", line.path);
    try testing.expectEqualStrings("install", line.source);
    try testing.expect(parseStateRootLine("ripgrep /x\n") == null);
}

test "upgrade never moves an install to an older version unless asked" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const prefix = try fixture.path(arena, "opt/mc");
    _ = try run(arena, testing.io, try fixture.unit(arena, "0.4.0", &unit_files), .{ .prefix = prefix, .self_check = false }, &log.writer);
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const older = try fixture.unit(arena, "0.3.9", &.{.{ "bin/metacodes", "exe 0.3.9" }});

    // What an unattended "latest release" rerun does: refused, nothing replaced.
    log.clearRetainingCapacity();
    try testing.expectError(error.NewerVersionInstalled, run(arena, testing.io, older, .{ .prefix = prefix, .upgrade = true, .self_check = false }, &log.writer));
    try testing.expect(std.mem.indexOf(u8, log.written(), "holds metacodes 0.4.0, newer than 0.3.9") != null);
    try testing.expectEqualStrings("exe", try read(arena, try std.fs.path.join(arena, &.{ prefix, "bin", "metacodes" })));
    try testing.expect(std.mem.indexOf(u8, try read(arena, try fixture.path(arena, "opt/mc/etc/metacodes/install.json")), "0.4.0") != null);

    // Asked for: replaced, and said so.
    log.clearRetainingCapacity();
    const outcome = try run(arena, testing.io, older, .{ .prefix = prefix, .upgrade = true, .allow_downgrade = true, .self_check = false }, &log.writer);
    try testing.expectEqualStrings("0.3.9", outcome.version);
    try testing.expect(std.mem.indexOf(u8, log.written(), "replacing metacodes 0.4.0 with the older 0.3.9") != null);
    try testing.expectEqualStrings("exe 0.3.9", try read(arena, try std.fs.path.join(arena, &.{ prefix, "bin", "metacodes" })));

    // A newer version upgrades without asking; --force replaces either way.
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const newer = try fixture.unit(arena, "0.4.1", &unit_files);
    _ = try run(arena, testing.io, newer, .{ .prefix = prefix, .upgrade = true, .self_check = false }, &log.writer);
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    _ = try run(arena, testing.io, try fixture.unit(arena, "0.3.9", &unit_files), .{ .prefix = prefix, .force = true, .self_check = false }, &log.writer);
}

/// `isOlder` over one table: install.sh `version_older` and install.ps1
/// `Test-OlderVersion` copy the order, and scripts/tests/test_install_scripts.py
/// holds both to these rows (it reads them between the markers).
/// { candidate, installed, candidate precedes installed }
const version_order_cases = [_]struct { []const u8, []const u8, bool }{
    // BEGIN version order cases
    // The project's own versions: a release, the development builds around it, build metadata.
    .{ "0.3.1", "0.3.2-dev+5d9bef266f95", true },
    .{ "0.3.2-dev+5d9bef266f95", "0.3.2", true },
    .{ "0.2.2-dev+210d57de39ab.dirty", "0.3.1", true },
    .{ "0.3.2-dev+aaaa", "0.2.2-dev+210d57de39ab.dirty", false },
    .{ "0.5.0", "0.5.1-dev+fde6a685bb3d", true },
    // Builds of one version differ only in metadata: no order, no downgrade.
    .{ "0.3.2-dev+aaaa", "0.3.2-dev+bbbb.dirty", false },
    .{ "0.3.1", "0.3.1", false },
    .{ "1.0.0+build.1", "1.0.0", false },
    // Numbers compare as numbers at any length, past a double's precision too.
    .{ "0.9.0", "0.10.0", true },
    .{ "2.0.0", "10.0.0", true },
    .{ "9007199254740993.0.0", "9007199254740994.0.0", true },
    .{ "18446744073709551614.0.0", "18446744073709551615.0.0", true },
    // Pre-release identifiers: numbers numerically, before alphanumerics, which compare in ASCII order.
    .{ "1.0.0-2", "1.0.0-10", true },
    .{ "1.0.0-10", "1.0.0-2", false },
    .{ "1.0.0-1", "1.0.0-a", true },
    .{ "1.0.0-a", "1.0.0-1", false },
    .{ "1.0.0-B", "1.0.0-a", true },
    .{ "1.0.0-a", "1.0.0-B", false },
    .{ "1.0.0-alpha-1", "1.0.0-alpha-2", true },
    // The semver.org precedence chain, each neighbour both ways.
    .{ "1.0.0-alpha", "1.0.0-alpha.1", true },
    .{ "1.0.0-alpha.1", "1.0.0-alpha", false },
    .{ "1.0.0-alpha.1", "1.0.0-alpha.beta", true },
    .{ "1.0.0-alpha.beta", "1.0.0-alpha.1", false },
    .{ "1.0.0-alpha.beta", "1.0.0-beta", true },
    .{ "1.0.0-beta", "1.0.0-alpha.beta", false },
    .{ "1.0.0-beta", "1.0.0-beta.2", true },
    .{ "1.0.0-beta.2", "1.0.0-beta", false },
    .{ "1.0.0-beta.2", "1.0.0-beta.11", true },
    .{ "1.0.0-beta.11", "1.0.0-beta.2", false },
    .{ "1.0.0-beta.11", "1.0.0-rc.1", true },
    .{ "1.0.0-rc.1", "1.0.0-beta.11", false },
    .{ "1.0.0-rc.1", "1.0.0", true },
    .{ "1.0.0", "1.0.0-rc.1", false },
    // A version that does not parse is never older, on either side.
    .{ "nightly", "0.3.1", false },
    .{ "0.3.1", "nightly", false },
    .{ "01.0.0", "2.0.0", false },
    .{ "1.0", "2.0.0", false },
    .{ "1.0.0.0", "2.0.0", false },
    .{ "1.0.0-", "2.0.0", false },
    .{ "1.0.0+", "2.0.0", false },
    .{ "1.0.0-a..b", "2.0.0", false },
    .{ "1.0.0-a.", "2.0.0", false },
    .{ "1.0.0-01", "2.0.0", false },
    .{ "1.0.0-a_b", "2.0.0", false },
    .{ "1.0.0+a_b", "2.0.0", false },
    .{ "1.0.0", "18446744073709551616.0.0", false },
    // END version order cases
};

test "version order: pre-releases, build metadata and unparseable versions" {
    for (version_order_cases) |case| {
        if (isOlder(case[0], case[1]) != case[2]) {
            std.debug.print("isOlder(\"{s}\", \"{s}\") != {}\n", .{ case[0], case[1], case[2] });
            return error.TestUnexpectedResult;
        }
    }
}

test "launcherTarget reads back what launcherBody writes, and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths: []const []const u8 = if (is_windows)
        &.{ "C:\\Users\\a b\\opt\\mc\\bin\\metacodes.exe", "C:\\100%\\done%%\\bin\\metacodes.exe" }
    else
        &.{ "/opt/mc/bin/metacodes", "/home/u/it's $HOME `x`/bin/metacodes", "/a''b/bin/metacodes" };
    for (paths) |path| {
        const body = try launcherBody(arena, path);
        try testing.expectEqualStrings(path, (try launcherTarget(arena, body)).?);
    }
    try testing.expect(try launcherTarget(arena, "#!/bin/sh\nexec /elsewhere/bin/metacodes \"$@\"\n") == null);
    try testing.expect(try launcherTarget(arena, "\x7fELF\x02\x01\x01") == null);
    try testing.expect(try launcherTarget(arena, "") == null);
}

test "the launcher passes its own path on as METACODES_LAUNCHER; the form before that still reads back (#482)" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "#!/bin/sh\n# metacodes launcher written by `metacodes install`\nexport METACODES_LAUNCHER=\"$0\"\nexec '/opt/mc/bin/metacodes' \"$@\"\n",
        try launcherBody(arena, "/opt/mc/bin/metacodes"),
    );
    // Every launcher written before #482: still this install's own, so a
    // rerun replaces it without --force.
    const before = "#!/bin/sh\n# metacodes launcher written by `metacodes install`\nexec '/opt/mc/bin/metacodes' \"$@\"\n";
    try testing.expectEqualStrings("/opt/mc/bin/metacodes", (try launcherTarget(arena, before)).?);
}

test "a launcher held by another metacodes install is named; this install's own in another form is replaced" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture: Fixture = .{ .tmp = undefined };
    try fixture.init();
    defer fixture.tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const bin_dir = try fixture.path(arena, "local/bin");
    const dev_prefix = try fixture.path(arena, "opt/metacodes-dev");
    const release_prefix = try fixture.path(arena, "opt/metacodes");

    // A development install owns the `metacodes` launcher (the layout a
    // `--dev --link-name metacodes` install leaves).
    const dev = try run(arena, testing.io, try fixture.unit(arena, "0.2.2-dev+210d57de39ab", &unit_files), .{ .prefix = dev_prefix, .link_dir = bin_dir, .self_check = false }, &log.writer);
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const release = try fixture.unit(arena, "0.3.1", &unit_files);

    log.clearRetainingCapacity();
    try testing.expectError(error.LinkOwnedByAnotherInstall, run(arena, testing.io, release, .{ .prefix = release_prefix, .link_dir = bin_dir, .upgrade = true, .self_check = false }, &log.writer));
    const expected = try std.fmt.allocPrint(arena, "{s} runs the metacodes 0.2.2-dev+210d57de39ab install at {s}\n", .{ dev.launcher.?, dev.prefix });
    try testing.expect(std.mem.indexOf(u8, log.written(), expected) != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, release_prefix, .{}));
    // Side by side under another name works.
    _ = try run(arena, testing.io, release, .{ .prefix = release_prefix, .link_dir = bin_dir, .link_name = "metacodes-release", .self_check = false }, &log.writer);

    // The dev install's own launcher, written in an older form, is not "taken".
    const older_form = try std.fmt.allocPrint(arena, "#!/bin/sh\n# metacodes launcher written by `metacodes install`\n# (an older form)\nexec '{s}' \"$@\"\n", .{dev.executable});
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "local/bin/metacodes", .data = older_form });
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const dev_again = try run(arena, testing.io, try fixture.unit(arena, "0.3.2-dev+aaaa", &unit_files), .{ .prefix = dev_prefix, .link_dir = bin_dir, .upgrade = true, .self_check = false }, &log.writer);
    try testing.expectEqualStrings(try launcherBody(arena, dev_again.executable), try read(arena, dev_again.launcher.?));

    // A launcher whose install is gone is still not overwritten silently.
    try std.Io.Dir.cwd().deleteTree(testing.io, dev_prefix);
    try fixture.tmp.dir.deleteTree(testing.io, "unit");
    const release_again = try fixture.unit(arena, "0.3.1", &unit_files);
    log.clearRetainingCapacity();
    try testing.expectError(error.LinkOwnedByAnotherInstall, run(arena, testing.io, release_again, .{ .prefix = release_prefix, .link_dir = bin_dir, .self_check = false }, &log.writer));
    try testing.expect(std.mem.indexOf(u8, log.written(), "has no metacodes install record") != null);
    _ = try run(arena, testing.io, release_again, .{ .prefix = release_prefix, .link_dir = bin_dir, .force = true, .self_check = false }, &log.writer);
}
