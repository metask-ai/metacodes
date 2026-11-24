//! `metacodes update`: bring the install the running executable belongs to up
//! to date from where it came from (doc/UPDATE_DESIGN.md).
//!
//! - A release install (`update_source` absent or a mirror) moves to the
//!   release `<base>/latest` names, or `--version`: the archive is downloaded,
//!   checked against the release's SHA256SUMS, unpacked by the restricted
//!   extractor, verified against its own manifest, and then installed by
//!   *its own* `bin/metacodes install --upgrade`.
//! - A development install (`update_source.kind = checkout`) is rebuilt by the
//!   checkout's own `scripts/install.sh --dev`.
//!
//! Update orchestrates; it never copies a file of the install itself. The
//! installer of the version being installed is the one that knows its layout
//! (§4, "Why the source installs itself"). It writes only `<prefix>/.update/`
//! (staging and the lock), renames the running executable aside on Windows,
//! and, when the TinyKG binaries change, has the new executable repin the
//! TinyKG service (§6.3).

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const platform = @import("platform");
const process_scan = platform.process_scan;
const pprocess = platform.process;
const install = @import("install.zig");
const release_source = @import("release_source.zig");
const release_fetch = @import("release_fetch.zig");
const unit_archive = @import("unit_archive.zig");
const state_root = @import("metacodes-internal").util.state_root;
const time = @import("metacodes-internal").util.time;

pub const Pid = process_scan.Pid;

pub const Options = struct {
    /// The install to update: the physical prefix of the running executable.
    prefix: []const u8,
    check: bool = false,
    /// `--version X.Y.Z`.
    version: ?[]const u8 = null,
    /// `--release-base URL`, as given.
    release_base: ?[]const u8 = null,
    pull: bool = false,
    allow_downgrade: bool = false,
    no_sdk: bool = false,
    ignore_running: bool = false,
    /// A leading `--state-dir`: the TinyKG repin must look at the same root
    /// the user's sessions do.
    state_dir: ?[]const u8 = null,
    /// The environment the TinyKG repin resolves the state root and its
    /// overrides from (§6.3); null reads none. curl inherits the process
    /// environment, proxies included.
    environ: ?*const std.process.Environ.Map = null,
    hooks: Hooks = .{},
};

/// What tests replace.
pub const Hooks = struct {
    /// Excluded from the process scan; null is this process.
    self_pid: ?Pid = null,
    /// `curl`; null looks it up on PATH.
    curl: ?[]const u8 = null,
    /// How long a stopped TinyKG service may take to exit.
    stop_wait_ms: u64 = 10_000,
    /// `git`; null looks it up on PATH.
    git: ?[]const u8 = null,
    /// `sh` for the checkout's installer.
    shell: []const u8 = "/bin/sh",
};

pub const Action = enum {
    up_to_date,
    /// The install is newer than the latest published release.
    newer_installed,
    upgrade,
    downgrade,
    repair,
    rebuild,
    refused,
};

pub const SourceKind = enum { release, checkout };

pub const Outcome = struct {
    action: Action,
    source: SourceKind,
    from: []const u8,
    /// The version (release) or commit (checkout) the install has after the
    /// run, or would have (`--check`).
    to: []const u8,
    prefix: []const u8,
    /// The release base or checkout used.
    origin: []const u8,
    /// An SDK was installed with the update.
    sdk: bool = false,
    stopped_services: []const Pid = &.{},
    /// Sessions left running (`--ignore-running`).
    running_sessions: []const Pid = &.{},
    sessions: []const Pid = &.{},
    services: []const Pid = &.{},
    notes: []const []const u8 = &.{},
    /// `--check` only: nothing was changed.
    checked_only: bool = false,

    /// Whether this run changed, or (`--check`) would change, the install.
    pub fn changes(self: Outcome) bool {
        return switch (self.action) {
            .upgrade, .downgrade, .repair, .rebuild => true,
            .up_to_date, .newer_installed, .refused => false,
        };
    }

    pub fn writeJson(self: Outcome, w: *std.Io.Writer) !void {
        try std.json.Stringify.value(.{
            .action = @tagName(self.action),
            .source = @tagName(self.source),
            .from = self.from,
            .to = self.to,
            .prefix = self.prefix,
            .origin = self.origin,
            .sdk = self.sdk,
            .checked_only = self.checked_only,
            .stopped_services = self.stopped_services,
            .running_sessions = self.running_sessions,
            .sessions = self.sessions,
            .services = self.services,
            .notes = self.notes,
        }, .{}, w);
        try w.writeByte('\n');
    }
};

pub const Error = error{
    /// The executable is not inside an install (no record).
    NotAnInstall,
    InvalidInstallRecord,
    /// The record's `update_source` is not a valid source.
    InvalidUpdateSource,
    /// A development install that records no checkout.
    NoCheckoutRecorded,
    /// `--pull` on a release install, `--version`/`--release-base` on a
    /// development one.
    OptionNotForSource,
    /// `--check` changes nothing, so it cannot `--pull`.
    CheckWithPull,
    InvalidVersion,
    InvalidReleaseBase,
    UpdateInProgress,
    CheckoutMissing,
    CheckoutUnsupportedOnWindows,
    GitUnavailable,
    PullFailed,
    SessionsRunning,
    IgnoreRunningUnsupported,
    ServiceDidNotStop,
    /// `--version` names an older release, or the checkout carries an older
    /// version, and `--allow-downgrade` is absent.
    DowngradeRefused,
    /// The staged unit is not the release it was downloaded as.
    StagedUnitMismatch,
    InstallFailed,
    ProcessScanFailed,
};

// ── plans (pure) ─────────────────────────────────────────────────────────────

const Order = enum { older, same, newer };

/// `a` relative to `b` in the installer's semantic-version order. Versions
/// that do not parse are the same only when equal; otherwise `a` is newer,
/// so an unreadable record never blocks a repair.
fn order(a: []const u8, b: []const u8) Order {
    if (std.mem.eql(u8, a, b)) return .same;
    if (install.isOlder(a, b)) return .older;
    if (install.isOlder(b, a)) return .newer;
    const pa = std.SemanticVersion.parse(a) catch return .newer;
    const pb = std.SemanticVersion.parse(b) catch return .newer;
    return if (pa.order(pb) == .eq) .same else .newer;
}

pub const ReleasePlan = struct { action: Action, tag: []const u8 };

/// doc/UPDATE_DESIGN.md §4.2 step 3.
pub fn planRelease(installed: []const u8, intact: bool, target: []const u8, explicit: bool, allow_downgrade: bool) ReleasePlan {
    return switch (order(target, installed)) {
        .same => .{ .action = if (intact) .up_to_date else .repair, .tag = target },
        .newer => .{ .action = .upgrade, .tag = target },
        .older => if (explicit)
            .{ .action = if (allow_downgrade) .downgrade else .refused, .tag = target }
        else if (intact)
            .{ .action = .newer_installed, .tag = installed }
        else
            .{ .action = .repair, .tag = installed },
    };
}

pub const CheckoutState = struct {
    commit: []const u8,
    dirty: bool,
    version: []const u8,
};

/// doc/UPDATE_DESIGN.md §4.3 step 3.
pub fn planCheckout(installed: CheckoutState, intact: bool, head: CheckoutState, allow_downgrade: bool) Action {
    if (order(head.version, installed.version) == .older and !allow_downgrade) return .refused;
    if (std.mem.eql(u8, head.commit, installed.commit) and !head.dirty and !installed.dirty)
        return if (intact) .up_to_date else .repair;
    return .rebuild;
}

pub const Classified = struct {
    /// This install's TinyKG service: its `tinykgd` and their kgd parents.
    services: []const process_scan.Process,
    sessions: []const process_scan.Process,
};

/// doc/UPDATE_DESIGN.md §6.2: a process is the service when it is the
/// prefix's `tinykgd`, or the prefix's `metacodes` that is the parent of one.
pub fn classify(arena: std.mem.Allocator, processes: []const process_scan.Process, prefix: []const u8, self_pid: Pid) !Classified {
    const exe_suffix = if (is_windows) ".exe" else "";
    const daemon = try std.fs.path.join(arena, &.{ prefix, "vendor", "tinykg", "tinykgd" ++ exe_suffix });
    const cli = try std.fs.path.join(arena, &.{ prefix, "bin", "metacodes" ++ exe_suffix });
    var services: std.ArrayList(process_scan.Process) = .empty;
    var sessions: std.ArrayList(process_scan.Process) = .empty;
    for (processes) |process| {
        if (process.pid == self_pid) continue;
        if (samePath(process.exe, daemon)) {
            try services.append(arena, process);
            continue;
        }
        const is_kgd = samePath(process.exe, cli) and for (processes) |other| {
            if (other.ppid == process.pid and samePath(other.exe, daemon)) break true;
        } else false;
        if (is_kgd) try services.append(arena, process) else try sessions.append(arena, process);
    }
    return .{ .services = services.items, .sessions = sessions.items };
}

fn samePath(a: []const u8, b: []const u8) bool {
    return if (is_windows) std.ascii.eqlIgnoreCase(stripVerbatim(a), stripVerbatim(b)) else std.mem.eql(u8, a, b);
}

fn stripVerbatim(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "\\\\?\\")) path[4..] else path;
}

/// The release target id of the platform this executable was built for
/// (release/LAYOUT.md), used when the installed manifest cannot say.
pub fn hostTargetId() []const u8 {
    const arch = @tagName(builtin.cpu.arch);
    return switch (builtin.os.tag) {
        .macos => arch ++ "-macos",
        .windows => arch ++ "-windows-gnu",
        .linux => arch ++ "-linux-" ++ @tagName(builtin.abi),
        else => arch ++ "-" ++ @tagName(builtin.os.tag),
    };
}

// ── the run ──────────────────────────────────────────────────────────────────

const Log = struct {
    w: *std.Io.Writer,

    fn note(self: Log, comptime fmt: []const u8, args: anytype) void {
        self.w.print("update: " ++ fmt ++ "\n", args) catch {};
        self.w.flush() catch {};
    }
};

/// `arena` owns everything returned.
pub fn run(arena: std.mem.Allocator, io: std.Io, options: Options, out: *std.Io.Writer) !Outcome {
    const log: Log = .{ .w = out };
    const prefix = options.prefix;
    const measurement = install.measure(arena, io, prefix) catch |err| return switch (err) {
        error.NoInstallRecord => error.NotAnInstall,
        error.InvalidInstallRecord => error.InvalidInstallRecord,
        else => err,
    };
    if (measurement.record.invalid_update_source) return error.InvalidUpdateSource;

    const channel = if (measurement.manifest) |manifest| manifest.release.channel else "";
    switch (measurement.record.update_source) {
        .checkout => {
            if (options.version != null or options.release_base != null) return error.OptionNotForSource;
            if (is_windows) return error.CheckoutUnsupportedOnWindows;
        },
        .default_release, .mirror => {
            if (options.pull) return error.OptionNotForSource;
            // A development install from before `update_source` existed:
            // updating it from a release would replace the build it is.
            if (std.mem.eql(u8, channel, "pre") and measurement.record.update_source == .default_release and options.release_base == null)
                return error.NoCheckoutRecorded;
        },
    }
    if (options.ignore_running and is_windows) return error.IgnoreRunningUnsupported;
    if (options.check and options.pull) return error.CheckWithPull;
    if (options.version) |v| if (!release_fetch.isStableVersion(v)) return error.InvalidVersion;

    // One update of a prefix at a time. The lock is the OS's, so a crashed
    // run releases it.
    const update_dir = try std.fs.path.join(arena, &.{ prefix, ".update" });
    try std.Io.Dir.cwd().createDirPath(io, update_dir);
    var lock = std.Io.Dir.cwd().createFile(io, try std.fs.path.join(arena, &.{ update_dir, "lock" }), .{
        .lock = .exclusive,
        .lock_nonblocking = true,
        .truncate = false,
    }) catch |err| return switch (err) {
        error.WouldBlock => error.UpdateInProgress,
        else => err,
    };
    defer lock.close(io);
    removeLeftovers(arena, io, prefix, update_dir);

    const self_pid: Pid = options.hooks.self_pid orelse @intCast(pprocess.currentPid());
    return switch (measurement.record.update_source) {
        .checkout => |checkout| runCheckout(arena, io, options, measurement, checkout, update_dir, self_pid, log),
        .default_release, .mirror => runRelease(arena, io, options, measurement, update_dir, self_pid, log),
    };
}

/// Staging of runs that crashed, and (Windows) executables renamed aside by
/// earlier runs that have exited since.
fn removeLeftovers(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, update_dir: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, update_dir, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "run-")) dir.deleteTree(io, entry.name) catch {};
        }
    } else |_| {}
    if (!is_windows) return;
    const bin = std.fs.path.join(arena, &.{ prefix, "bin" }) catch return;
    var dir = cwd.openDir(io, bin, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "metacodes.exe.") and std.mem.endsWith(u8, entry.name, ".old"))
            dir.deleteFile(io, entry.name) catch {}; // still running: next time
    }
}

fn stagingDir(arena: std.mem.Allocator, io: std.Io, update_dir: []const u8) ![]const u8 {
    var raw: [8]u8 = undefined;
    if (!platform.rng.randomBytes(&raw)) return error.Unexpected;
    const hex = std.fmt.bytesToHex(raw, .lower);
    const dir = try std.fs.path.join(arena, &.{ update_dir, try std.fmt.allocPrint(arena, "run-{s}", .{&hex}) });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn runRelease(
    arena: std.mem.Allocator,
    io: std.Io,
    options: Options,
    measurement: install.Measurement,
    update_dir: []const u8,
    self_pid: Pid,
    log: Log,
) !Outcome {
    const prefix = options.prefix;
    const source: release_source.UpdateSource = if (options.release_base) |raw|
        release_source.parseBase(arena, raw) catch |err| return switch (err) {
            error.OutOfMemory => |e| e,
            else => error.InvalidReleaseBase,
        }
    else
        measurement.record.update_source;
    const base = source.releaseBase().?;
    const installed = measurement.installedVersion();
    var outcome: Outcome = .{ .action = .up_to_date, .source = .release, .from = installed, .to = installed, .prefix = prefix, .origin = base };

    const fetcher = try release_fetch.Fetcher.init(arena, base, user_agent, options.hooks.curl);
    var report: release_fetch.Report = .{};
    errdefer reportFetch(log, report);

    const target = if (options.version) |v| v else blk: {
        log.note("checking {s}/latest", .{base});
        break :blk try fetcher.latestTag(arena, base, &report);
    };
    const plan = planRelease(installed, measurement.intact(), target, options.version != null, options.allow_downgrade);
    outcome.action = plan.action;
    outcome.to = plan.tag;
    switch (plan.action) {
        .up_to_date => {
            log.note("metacodes {s} is up to date ({s})", .{ installed, base });
            return outcome;
        },
        .newer_installed => {
            log.note("metacodes {s} is newer than the latest published release {s}; nothing to do", .{ installed, target });
            outcome.to = installed;
            return outcome;
        },
        .refused => {
            log.note("{s} is older than the installed {s}; pass --allow-downgrade to install it", .{ target, installed });
            return error.DowngradeRefused;
        },
        .repair => log.note("{s}; reinstalling metacodes {s}", .{ measurement.problem orelse "the install is not intact", plan.tag }),
        .upgrade, .downgrade => log.note("metacodes {s} → {s}", .{ installed, plan.tag }),
        .rebuild => unreachable,
    }
    if (options.check) return checkedOnly(arena, io, prefix, self_pid, options.ignore_running, log, outcome);
    var running = try checkSessions(arena, io, prefix, self_pid, options.ignore_running, log);

    // Download, verify and unpack everything before anything changes.
    const sums_url = try std.fmt.allocPrint(arena, "{s}/download/{s}/metacodes-{s}-SHA256SUMS", .{ base, plan.tag, plan.tag });
    const sums = try release_fetch.parseSums(arena, try fetcher.getSmall(arena, sums_url, release_fetch.max_sums_bytes, &report));
    const target_id = if (measurement.manifest) |manifest| (if (manifest.target.id.len > 0) manifest.target.id else hostTargetId()) else hostTargetId();
    const want_sdk = measurement.sdk != null and !options.no_sdk;
    const assets = try release_fetch.selectAssets(arena, sums, plan.tag, target_id, want_sdk);
    if (assets.sdk_missing) log.note("release {s} carries no AgentCore SDK for {s}; the installed SDK stays", .{ plan.tag, target_id });

    const staging = try stagingDir(arena, io, update_dir);
    defer std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    const unit_root = try stageArchive(arena, &fetcher, io, base, plan.tag, assets.cli, staging, "cli", try std.fmt.allocPrint(arena, "metacodes-{s}-{s}", .{ plan.tag, target_id }), &report, log);
    const unit_manifest = try verifyStagedUnit(arena, io, unit_root, plan.tag, target_id, log);
    const sdk_root: ?[]const u8 = if (assets.sdk) |sdk| blk: {
        const root = try stageArchive(arena, &fetcher, io, base, plan.tag, sdk, staging, "sdk", null, &report, log);
        const sdk_manifest = install.readSdkManifest(arena, io, root) catch return error.StagedUnitMismatch;
        if (try install.firstMismatch(arena, io, root, sdk_manifest.files)) |path| {
            log.note("the SDK archive's {s} does not match its manifest", .{path});
            return error.StagedUnitMismatch;
        }
        break :blk root;
    } else null;

    const exe_name = if (is_windows) "metacodes.exe" else "metacodes";
    const unit_exe = try std.fs.path.join(arena, &.{ unit_root, "bin", exe_name });
    const help = try commandHelp(arena, unit_exe, &.{ "install", "--help" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ unit_exe, "install", "--prefix", prefix, "--upgrade" });
    if (sdk_root) |root| try argv.appendSlice(arena, &.{ "--sdk", root });
    if (std.mem.indexOf(u8, help, "--release-base") != null) {
        try argv.appendSlice(arena, &.{ "--release-base", base });
    } else if (source == .mirror) {
        log.note("metacodes {s} cannot record a mirror; the next update reads the default base unless --release-base is given", .{plan.tag});
    }
    if (plan.action == .downgrade and std.mem.indexOf(u8, help, "--allow-downgrade") != null) try argv.append(arena, "--allow-downgrade");
    if (plan.action == .downgrade and std.mem.indexOf(u8, try commandHelp(arena, unit_exe, &.{"--help"}), "  update") == null) {
        log.note("metacodes {s} has no `update`; coming back needs scripts/install.sh", .{plan.tag});
    }

    outcome.stopped_services = try stopServices(arena, io, prefix, self_pid, options.hooks.stop_wait_ms, log);
    // A session that started while the service stopped.
    running = try checkSessions(arena, io, prefix, self_pid, options.ignore_running, log);
    outcome.running_sessions = running;

    try delegate(arena, io, prefix, argv.items, log);
    outcome.sdk = sdk_root != null;
    try repinTinyKg(arena, io, options, measurement.manifest, unit_manifest, log, &outcome);
    log.note("metacodes {s} is installed at {s}; changes: {s}", .{ plan.tag, prefix, try std.fs.path.join(arena, &.{ prefix, "share", "doc", try std.fmt.allocPrint(arena, "CHANGELOG-{s}.md", .{plan.tag}) }) });
    if (running.len > 0) log.note("{d} session(s) still run the previous version; restart them", .{running.len});
    return outcome;
}

pub const user_agent = "metacodes-update/" ++ @import("metacodes-internal").version.semver;

fn reportFetch(log: Log, report: release_fetch.Report) void {
    if (report.url.len == 0 or report.curl_exit == 0) return;
    log.note("curl exited {d} for {s} (its message is above)", .{ report.curl_exit, report.url });
}

/// Download one asset into `<staging>/<sub>.<ext>`, check it, unpack it into
/// `<staging>/<sub>/`, and return the unpacked root.
fn stageArchive(
    arena: std.mem.Allocator,
    fetcher: *const release_fetch.Fetcher,
    io: std.Io,
    base: []const u8,
    tag: []const u8,
    asset: release_fetch.Asset,
    staging: []const u8,
    sub: []const u8,
    expected_root: ?[]const u8,
    report: *release_fetch.Report,
    log: Log,
) ![]const u8 {
    const format = unit_archive.Format.of(asset.name) orelse return error.StagedUnitMismatch;
    const archive = try std.fs.path.join(arena, &.{ staging, asset.name });
    const url = try std.fmt.allocPrint(arena, "{s}/download/{s}/{s}", .{ base, tag, asset.name });
    log.note("downloading {s}", .{asset.name});
    const bytes = try fetcher.download(arena, io, url, archive, release_fetch.max_archive_bytes, asset.sha256, report);
    log.note("{s}: {d} bytes, SHA-256 matches the release", .{ asset.name, bytes });
    const dest = try std.fs.path.join(arena, &.{ staging, sub });
    try std.Io.Dir.cwd().createDirPath(io, dest);
    var archive_report: unit_archive.Report = .{};
    const root = unit_archive.extract(arena, io, archive, format, dest, expected_root, .{}, &archive_report) catch |err| {
        log.note("{s} cannot be unpacked: {s}{s}{s}", .{ asset.name, @errorName(err), if (archive_report.member != null) " at " else "", archive_report.member orelse "" });
        return err;
    };
    return std.fs.path.join(arena, &.{ dest, root });
}

/// The staged unit is the release asked for, for this install's target, and
/// every file it lists is the one its manifest names.
fn verifyStagedUnit(arena: std.mem.Allocator, io: std.Io, unit_root: []const u8, tag: []const u8, target_id: []const u8, log: Log) !install.UnitManifest {
    const manifest = install.readUnitManifest(arena, io, unit_root) catch {
        log.note("the archive holds no metacodes-cli schema 2 manifest", .{});
        return error.StagedUnitMismatch;
    };
    if (!std.mem.eql(u8, manifest.release.version, tag) or !std.mem.eql(u8, manifest.release.channel, "stable") or !std.mem.eql(u8, manifest.target.id, target_id)) {
        log.note("the archive holds metacodes {s} ({s}, {s}), not {s} (stable, {s})", .{ manifest.release.version, manifest.release.channel, manifest.target.id, tag, target_id });
        return error.StagedUnitMismatch;
    }
    if (try install.firstMismatch(arena, io, unit_root, manifest.files)) |path| {
        log.note("the archive's {s} does not match its manifest", .{path});
        return error.StagedUnitMismatch;
    }
    return manifest;
}

/// A staged executable's help text (`install --help`, `--help`): which
/// options and commands it knows. Empty when it cannot say.
fn commandHelp(arena: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    try argv.appendSlice(arena, args);
    const captured = pprocess.capture(try zArgv(arena, argv.items), arena, .{ .timeout_ms = 60_000, .inherit_env = true }) catch return "";
    return captured.stdout;
}

/// Refuse while sessions run from the prefix, unless `ignore`; returns the
/// sessions that were ignored.
fn checkSessions(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, self_pid: Pid, ignore: bool, log: Log) ![]const Pid {
    const processes = process_scan.listUnder(arena, io, prefix) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.ProcessScanFailed,
    };
    const classes = try classify(arena, processes, prefix, self_pid);
    if (classes.sessions.len == 0) return &.{};
    var pids: std.ArrayList(Pid) = .empty;
    for (classes.sessions) |session| try pids.append(arena, session.pid);
    if (ignore) {
        log.note("{d} process(es) run from {s}; going ahead (--ignore-running)", .{ classes.sessions.len, prefix });
        return pids.items;
    }
    log.note("these processes run from {s}:", .{prefix});
    for (classes.sessions) |session| log.note("  pid {d}  {s}", .{ session.pid, session.exe });
    log.note("exit them first{s}", .{if (is_windows) "" else ", or pass --ignore-running (their next formal-kernel check then fails closed until they restart)"});
    return error.SessionsRunning;
}

fn checkedOnly(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, self_pid: Pid, ignore: bool, log: Log, plan: Outcome) !Outcome {
    var outcome = plan;
    outcome.checked_only = true;
    const processes = process_scan.listUnder(arena, io, prefix) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            try appendNote(arena, &outcome, try std.fmt.allocPrint(arena, "the processes that run from {s} could not be listed; a real run stops with ProcessScanFailed", .{prefix}));
            log.note("{s}", .{outcome.notes[outcome.notes.len - 1]});
            return outcome;
        },
    };
    const classes = try classify(arena, processes, prefix, self_pid);
    outcome.sessions = try pidsOf(arena, classes.sessions);
    outcome.services = try pidsOf(arena, try serviceRoots(arena, classes.services));
    if (classes.sessions.len > 0) {
        log.note("these processes run from {s}:", .{prefix});
        for (classes.sessions) |session| log.note("  pid {d}  {s}", .{ session.pid, session.exe });
        if (ignore)
            log.note("a real run goes ahead and leaves them running (--ignore-running)", .{})
        else
            log.note("the update would be refused until they exit{s}", .{if (is_windows) "" else ", or with --ignore-running"});
    }
    if (outcome.services.len > 0) log.note("a real run stops this install's TinyKG service (pid {any})", .{outcome.services});
    return outcome;
}

fn pidsOf(arena: std.mem.Allocator, processes: []const process_scan.Process) ![]const Pid {
    const pids = try arena.alloc(Pid, processes.len);
    for (processes, pids) |process, *pid| pid.* = process.pid;
    return pids;
}

fn serviceRoots(arena: std.mem.Allocator, services: []const process_scan.Process) ![]const process_scan.Process {
    var roots: std.ArrayList(process_scan.Process) = .empty;
    for (services) |service| {
        const has_parent_in_list = for (services) |other| {
            if (other.pid == service.ppid) break true;
        } else false;
        if (!has_parent_in_list) try roots.append(arena, service);
    }
    return roots.items;
}

/// Stop this install's TinyKG service and wait for both of its processes.
fn stopServices(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, self_pid: Pid, wait_ms: u64, log: Log) ![]const Pid {
    const processes = process_scan.listUnder(arena, io, prefix) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.ProcessScanFailed,
    };
    const classes = try classify(arena, processes, prefix, self_pid);
    if (classes.services.len == 0) return &.{};
    var stopped: std.ArrayList(Pid) = .empty;
    // The supervisor (a parent) is asked first; its tinykgd follows. An
    // orphaned tinykgd is asked directly.
    for (try serviceRoots(arena, classes.services)) |service| {
        // The pid must still be the same program: never signal a reused pid.
        const now = process_scan.exePath(arena, io, service.pid) orelse continue;
        if (!samePath(now, service.exe)) continue;
        process_scan.terminate(service.pid) catch {
            log.note("could not stop the TinyKG service (pid {d})", .{service.pid});
            return error.ServiceDidNotStop;
        };
        try stopped.append(arena, service.pid);
    }
    log.note("stopping this install's TinyKG service (pid {any}); the next session starts the new one", .{stopped.items});
    const deadline = time.nowMs() + @as(i64, @intCast(wait_ms));
    for (classes.services) |service| {
        while (process_scan.alive(service.pid)) {
            if (time.nowMs() > deadline) {
                log.note("the TinyKG service process {d} did not exit within {d} s", .{ service.pid, wait_ms / 1000 });
                return error.ServiceDidNotStop;
            }
            time.sleepMs(50);
        }
    }
    return stopped.items;
}

/// Run an installer with the console inherited. On Windows the running
/// executable is renamed aside first, and back if the installer failed
/// before replacing it.
fn delegate(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, argv: []const []const u8, log: Log) !void {
    var aside: ?[]const u8 = null;
    const exe = try std.fs.path.join(arena, &.{ prefix, "bin", if (is_windows) "metacodes.exe" else "metacodes" });
    if (is_windows) {
        const renamed = try std.fmt.allocPrint(arena, "{s}.{d}.old", .{ exe, pprocess.currentPid() });
        renameZ(arena, exe, renamed) catch |err| {
            log.note("cannot move the running {s} aside: {s}", .{ exe, @errorName(err) });
            return error.InstallFailed;
        };
        aside = renamed;
    }
    const argv_z = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| argv_z[i] = (try arena.dupeZ(u8, arg)).ptr;
    argv_z[argv.len] = null;
    const code = pprocess.runInherit(argv_z, true) catch |err| blk: {
        log.note("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
        break :blk -1;
    };
    if (code == 0) return;
    if (aside) |renamed| {
        if (std.Io.Dir.cwd().access(io, exe, .{})) |_| {} else |_| {
            renameZ(arena, renamed, exe) catch {};
        }
    }
    log.note("the installer exited with {d}; rerun `metacodes update` to finish", .{code});
    return error.InstallFailed;
}

fn renameZ(arena: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const from_z = try arena.dupeZ(u8, from);
    const to_z = try arena.dupeZ(u8, to);
    if (platform.fs.renameReplace(from_z.ptr, to_z.ptr) != 0) return error.RenameFailed;
}

/// doc/UPDATE_DESIGN.md §6.3: when the TinyKG binaries change, the new
/// executable rewrites the service pin (`kg install` keeps the key).
fn repinTinyKg(arena: std.mem.Allocator, io: std.Io, options: Options, old: ?install.UnitManifest, new: install.UnitManifest, log: Log, outcome: *Outcome) !void {
    if (old) |previous| if (!tinyKgChanged(previous, new)) return;
    for ([_][]const u8{ "METACODES_KG_CONFIG", "METACODES_KG_URL", "METACODES_KG_API_KEY", "METACODES_KG_EXPECTED_BUILD_ID" }) |name| {
        if (envSet(options.environ, name)) {
            try appendNote(arena, outcome, try std.fmt.allocPrint(arena, "the TinyKG binaries changed but {s} is set; repin that service yourself (`metacodes kg install`)", .{name}));
            log.note("{s}", .{outcome.notes[outcome.notes.len - 1]});
            return;
        }
    }
    const exe = try std.fs.path.join(arena, &.{ options.prefix, "bin", if (is_windows) "metacodes.exe" else "metacodes" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = state_root.resolveFrom(.{
        .flag = options.state_dir,
        .env = envValue(options.environ, state_root.env_variable),
        .exe_path = exe,
        .home = envValue(options.environ, if (is_windows) "USERPROFILE" else "HOME"),
    }, &root_buf) catch return;
    const daemon_config = try std.fmt.allocPrint(arena, "{s}/kg/daemon.json", .{resolved.path});
    std.Io.Dir.cwd().access(io, daemon_config, .{}) catch return; // never provisioned
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    if (options.state_dir) |dir| try argv.appendSlice(arena, &.{ "--state-dir", dir });
    try argv.appendSlice(arena, &.{ "kg", "install" });
    log.note("the TinyKG binaries changed; repinning the TinyKG service ({s})", .{daemon_config});
    const argv_z = try arena.alloc(?[*:0]const u8, argv.items.len + 1);
    for (argv.items, 0..) |arg, i| argv_z[i] = (try arena.dupeZ(u8, arg)).ptr;
    argv_z[argv.items.len] = null;
    const code = pprocess.runInherit(argv_z, true) catch -1;
    if (code != 0) {
        try appendNote(arena, outcome, "repinning the TinyKG service failed; run `metacodes kg install` before the next session");
        log.note("{s}", .{outcome.notes[outcome.notes.len - 1]});
    }
}

fn tinyKgChanged(old: install.UnitManifest, new: install.UnitManifest) bool {
    for ([_][]const u8{ "vendor/tinykg/tinykg", "vendor/tinykg/tinykgd", "vendor/tinykg/tinykg.exe", "vendor/tinykg/tinykgd.exe" }) |path| {
        const a = digestOf(old, path);
        const b = digestOf(new, path);
        if (a == null and b == null) continue;
        if (a == null or b == null or !std.mem.eql(u8, a.?, b.?)) return true;
    }
    return false;
}

fn digestOf(manifest: install.UnitManifest, path: []const u8) ?[]const u8 {
    for (manifest.files) |file| if (std.mem.eql(u8, file.path, path)) return file.sha256;
    return null;
}

fn appendNote(arena: std.mem.Allocator, outcome: *Outcome, note: []const u8) !void {
    var notes: std.ArrayList([]const u8) = .empty;
    try notes.appendSlice(arena, outcome.notes);
    try notes.append(arena, note);
    outcome.notes = notes.items;
}

fn envValue(environ: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const map = environ orelse return null;
    const value = map.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

fn envSet(environ: ?*const std.process.Environ.Map, name: []const u8) bool {
    return envValue(environ, name) != null;
}

fn runCheckout(
    arena: std.mem.Allocator,
    io: std.Io,
    options: Options,
    measurement: install.Measurement,
    checkout: []const u8,
    update_dir: []const u8,
    self_pid: Pid,
    log: Log,
) !Outcome {
    _ = update_dir;
    const prefix = options.prefix;
    const manifest_state: CheckoutState = if (measurement.manifest) |manifest|
        .{ .commit = manifest.source.commit, .dirty = manifest.source.dirty, .version = manifest.release.version }
    else
        .{ .commit = "", .dirty = true, .version = measurement.record.version };
    var outcome: Outcome = .{
        .action = .up_to_date,
        .source = .checkout,
        .from = manifest_state.commit,
        .to = manifest_state.commit,
        .prefix = prefix,
        .origin = checkout,
    };

    for ([_][]const u8{ "build.zig", "release/manifest_contract.zig", "scripts/kernel_pins.py", "scripts/install.sh" }) |rel| {
        std.Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ checkout, rel }), .{}) catch {
            log.note("{s} is no longer a metacodes checkout (no {s}); reinstall from a checkout with scripts/install.sh --dev", .{ checkout, rel });
            return error.CheckoutMissing;
        };
    }
    var git_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git = options.hooks.git orelse (platform.exe_lookup.lookup("git", &git_buf) orelse return error.GitUnavailable);

    if (options.pull) {
        log.note("git pull --ff-only in {s}", .{checkout});
        const argv = try zArgv(arena, &.{ git, "-C", checkout, "pull", "--ff-only" });
        const code = pprocess.runInherit(argv, true) catch -1;
        if (code != 0) return error.PullFailed;
    }
    const head_commit = std.mem.trim(u8, try gitOutput(arena, git, checkout, &.{ "rev-parse", "HEAD" }), " \r\n");
    const head_dirty = std.mem.trim(u8, try gitOutput(arena, git, checkout, &.{ "status", "--porcelain" }), " \r\n").len > 0;
    const head_version = try checkoutVersion(arena, io, checkout);
    const head: CheckoutState = .{ .commit = head_commit, .dirty = head_dirty, .version = head_version };
    const action = planCheckout(manifest_state, measurement.intact(), head, options.allow_downgrade);
    outcome.action = action;
    outcome.to = head_commit;
    switch (action) {
        .up_to_date => {
            log.note("the install is the build of {s} at {s}; nothing to do", .{ checkout, shortCommit(head_commit) });
            return outcome;
        },
        .refused => {
            log.note("{s} carries metacodes {s}, older than the installed {s}; pass --allow-downgrade to build it", .{ checkout, head_version, manifest_state.version });
            return error.DowngradeRefused;
        },
        .repair => log.note("{s}; rebuilding {s} at {s}", .{ measurement.problem orelse "the install is not intact", checkout, shortCommit(head_commit) }),
        .rebuild => log.note("rebuilding {s} at {s}{s} (installed: {s}{s})", .{ checkout, shortCommit(head_commit), if (head_dirty) " with local changes" else "", shortCommit(manifest_state.commit), if (manifest_state.dirty) " with local changes" else "" }),
        else => unreachable,
    }
    if (options.check) return checkedOnly(arena, io, prefix, self_pid, options.ignore_running, log, outcome);
    var running = try checkSessions(arena, io, prefix, self_pid, options.ignore_running, log);
    outcome.stopped_services = try stopServices(arena, io, prefix, self_pid, options.hooks.stop_wait_ms, log);
    running = try checkSessions(arena, io, prefix, self_pid, options.ignore_running, log);
    outcome.running_sessions = running;

    var argv: std.ArrayList([]const u8) = .empty;
    const script = try std.fs.path.join(arena, &.{ checkout, "scripts", "install.sh" });
    try argv.appendSlice(arena, &.{ options.hooks.shell, script, "--dev", "--source", checkout, "--prefix", prefix, "--no-link" });
    if (measurement.sdk == null or options.no_sdk) try argv.append(arena, "--no-sdk");
    if (options.allow_downgrade) try argv.append(arena, "--allow-downgrade");
    try delegate(arena, io, prefix, argv.items, log);
    outcome.sdk = measurement.sdk != null and !options.no_sdk;
    const new_manifest = install.readUnitManifest(arena, io, prefix) catch null;
    if (new_manifest) |manifest| try repinTinyKg(arena, io, options, measurement.manifest, manifest, log, &outcome);
    if (running.len > 0) log.note("{d} session(s) still run the previous build; restart them", .{running.len});
    return outcome;
}

fn shortCommit(commit: []const u8) []const u8 {
    return if (commit.len > 12) commit[0..12] else if (commit.len == 0) "?" else commit;
}

fn zArgv(arena: std.mem.Allocator, argv: []const []const u8) ![]const ?[*:0]const u8 {
    const out = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| out[i] = (try arena.dupeZ(u8, arg)).ptr;
    out[argv.len] = null;
    return out;
}

fn gitOutput(arena: std.mem.Allocator, git: []const u8, checkout: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ git, "-C", checkout });
    try argv.appendSlice(arena, args);
    const captured = pprocess.capture(try zArgv(arena, argv.items), arena, .{ .timeout_ms = 60_000, .inherit_env = true, .want_stderr = false }) catch
        return error.GitUnavailable;
    if (captured.exit_code != 0) return error.GitUnavailable;
    return captured.stdout;
}

/// `.version = "X"` from the checkout's `build.zig.zon`.
fn checkoutVersion(arena: std.mem.Allocator, io: std.Io, checkout: []const u8) ![]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ checkout, "build.zig.zon" }), arena, .limited(1 << 20)) catch return "";
    return zonVersion(bytes) orelse "";
}

fn zonVersion(bytes: []const u8) ?[]const u8 {
    const key = std.mem.indexOf(u8, bytes, ".version") orelse return null;
    const open = std.mem.indexOfScalarPos(u8, bytes, key, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, bytes, open + 1, '"') orelse return null;
    return bytes[open + 1 .. close];
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "update planRelease: up to date, repair, upgrade, newer installed, downgrade" {
    const t = struct {
        fn plan(installed: []const u8, intact: bool, target: []const u8, explicit: bool, allow: bool) ReleasePlan {
            return planRelease(installed, intact, target, explicit, allow);
        }
    };
    try testing.expectEqual(Action.up_to_date, t.plan("0.8.0", true, "0.8.0", false, false).action);
    try testing.expectEqual(Action.repair, t.plan("0.8.0", false, "0.8.0", false, false).action);
    try testing.expectEqual(Action.upgrade, t.plan("0.8.0", true, "0.9.0", false, false).action);
    try testing.expectEqual(Action.upgrade, t.plan("0.8.0", false, "0.10.0", false, false).action);
    // GitHub's Latest label behind the install.
    const behind = t.plan("0.9.1", true, "0.9.0", false, false);
    try testing.expectEqual(Action.newer_installed, behind.action);
    // A half-finished upgrade is completed, not undone by an older latest.
    const half = t.plan("0.9.1", false, "0.9.0", false, false);
    try testing.expectEqual(Action.repair, half.action);
    try testing.expectEqualStrings("0.9.1", half.tag);
    // An explicit older version needs --allow-downgrade.
    try testing.expectEqual(Action.refused, t.plan("0.9.1", true, "0.8.0", true, false).action);
    try testing.expectEqual(Action.downgrade, t.plan("0.9.1", true, "0.8.0", true, true).action);
    try testing.expectEqual(Action.up_to_date, t.plan("0.9.1", true, "0.9.1", true, false).action);
    // A pre-release install moves to its release.
    try testing.expectEqual(Action.upgrade, t.plan("0.9.0-dev+abc", true, "0.9.0", false, false).action);
    // An unreadable record never blocks the latest.
    try testing.expectEqual(Action.upgrade, t.plan("garbage", false, "0.9.0", false, false).action);
}

test "update planCheckout: the same clean commit, a dirty tree, another commit, an older branch" {
    const installed: CheckoutState = .{ .commit = "aaaa", .dirty = false, .version = "0.8.1-dev+aaaa" };
    try testing.expectEqual(Action.up_to_date, planCheckout(installed, true, .{ .commit = "aaaa", .dirty = false, .version = "0.8.1-dev" }, false));
    try testing.expectEqual(Action.repair, planCheckout(installed, false, .{ .commit = "aaaa", .dirty = false, .version = "0.8.1-dev" }, false));
    try testing.expectEqual(Action.rebuild, planCheckout(installed, true, .{ .commit = "aaaa", .dirty = true, .version = "0.8.1-dev" }, false));
    try testing.expectEqual(Action.rebuild, planCheckout(.{ .commit = "aaaa", .dirty = true, .version = "0.8.1-dev" }, true, .{ .commit = "aaaa", .dirty = false, .version = "0.8.1-dev" }, false));
    try testing.expectEqual(Action.rebuild, planCheckout(installed, true, .{ .commit = "bbbb", .dirty = false, .version = "0.8.1-dev" }, false));
    try testing.expectEqual(Action.refused, planCheckout(installed, true, .{ .commit = "cccc", .dirty = false, .version = "0.7.1-dev" }, false));
    try testing.expectEqual(Action.rebuild, planCheckout(installed, true, .{ .commit = "cccc", .dirty = false, .version = "0.7.1-dev" }, true));
}

test "update classify: the service is tinykgd and its parent, everything else a session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sep = std.fs.path.sep_str;
    const ext = if (is_windows) ".exe" else "";
    const prefix = if (is_windows) "C:\\mc" else "/opt/mc";
    const cli = prefix ++ sep ++ "bin" ++ sep ++ "metacodes" ++ ext;
    const daemon = prefix ++ sep ++ "vendor" ++ sep ++ "tinykg" ++ sep ++ "tinykgd" ++ ext;
    const kernel = prefix ++ sep ++ "libexec" ++ sep ++ "metacodes" ++ sep ++ "metacodes-formal-kernel" ++ ext;
    const processes = [_]process_scan.Process{
        .{ .pid = 10, .ppid = 1, .exe = cli }, // kgd
        .{ .pid = 11, .ppid = 10, .exe = daemon }, // its tinykgd
        .{ .pid = 20, .ppid = 5, .exe = cli }, // a REPL
        .{ .pid = 21, .ppid = 20, .exe = kernel }, // its kernel
        .{ .pid = 30, .ppid = 5, .exe = cli }, // this update
        .{ .pid = 40, .ppid = 1, .exe = daemon }, // an orphaned tinykgd
    };
    const classes = try classify(arena, &processes, prefix, 30);
    var service_pids: [8]Pid = undefined;
    for (classes.services, 0..) |s, i| service_pids[i] = s.pid;
    try testing.expectEqualSlices(Pid, &.{ 10, 11, 40 }, service_pids[0..classes.services.len]);
    var session_pids: [8]Pid = undefined;
    for (classes.sessions, 0..) |s, i| session_pids[i] = s.pid;
    try testing.expectEqualSlices(Pid, &.{ 20, 21 }, session_pids[0..classes.sessions.len]);
}

test "update zonVersion and hostTargetId" {
    try testing.expectEqualStrings("0.8.0-dev", zonVersion(".{\n    .name = .metacodes,\n    .version = \"0.8.0-dev\",\n}").?);
    try testing.expect(zonVersion(".{ .name = .x }") == null);
    const id = hostTargetId();
    try testing.expect(std.mem.indexOf(u8, id, @tagName(builtin.cpu.arch)) != null);
}
