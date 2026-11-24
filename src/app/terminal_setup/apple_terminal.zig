//! Apple Terminal (macOS): Shift+Return in a profile's key map
//! (`Window Settings.<profile>.keyMapBoundKeys`, key `$000D`: `$` is Shift,
//! 000D is Return; the value is the text to send).
//!
//! Measured on macOS 15.7 and 26.6 (GitHub runners, Terminal.app driven with
//! System Events, the bytes read from the tty; metacodes#386):
//! - A profile without `keyMapBoundKeys` uses Terminal's built-in map,
//!   `Terminal.app/Contents/Resources/keyMappings.plist`. A `keyMapBoundKeys`
//!   replaces that map as a whole: one holding only `$000D` (or nothing) drops
//!   F1–F20, Shift+arrows and Option+arrows. Such a profile therefore gets a
//!   copy of the built-in map plus `$000D`, and restore takes the copy away.
//! - Terminal reads its profiles at launch. A running Terminal keeps sending a
//!   plain Return in its old and new windows alike until it is quit and
//!   reopened, and quitting it does not write the profiles back over the change.
//! - The tools: `defaults export|import` go through cfprefsd, so there is no
//!   stale cache to flush. `plutil` keypaths escape `.` as `\.` and cannot
//!   spell a backslash; macOS 15's plutil aborts (SIGABRT) on a component
//!   that starts with `@`, which 26's accepts. PlistBuddy is not used: it
//!   crashes on quoted profile names and exits 0 when one of several commands
//!   fails.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("platform").process;
const process_scan = @import("platform").process_scan;
const log = @import("metacodes-internal").util.log;
const files = @import("files.zig");
const setup = @import("setup.zig");

pub const default_domain = "com.apple.Terminal";
pub const default_app = "/System/Applications/Utilities/Terminal.app";
const plutil = "/usr/bin/plutil";
const defaults = "/usr/bin/defaults";

/// Shift+Return in `keyMapBoundKeys`.
pub const shift_return = "$000D";

/// Where the preferences and the built-in key map come from. Tests point both
/// at temporary files; the real ones are the defaults.
pub const Store = struct {
    /// A `defaults` domain: `com.apple.Terminal`, or an absolute path.
    domain: []const u8 = default_domain,
    /// The Terminal.app bundle, whose `keyMappings.plist` is the built-in map.
    app: []const u8 = default_app,
};

pub const Error = error{ OutOfMemory, ToolFailed, NoBuiltInMap };

const Ran = struct { ok: bool, code: i32, out: []const u8, err: []const u8 };

fn run(arena: std.mem.Allocator, argv: []const []const u8) Error!Ran {
    const z = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |arg, i| z[i] = (try arena.dupeZ(u8, arg)).ptr;
    z[argv.len] = null;
    const captured = process.capture(z, arena, .{ .timeout_ms = 30_000, .inherit_env = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ToolFailed,
    };
    return .{ .ok = captured.exit_code == 0 and captured.capture_complete, .code = captured.exit_code, .out = captured.stdout, .err = captured.stderr };
}

/// `run` for a step that has to succeed. A failure is logged with the command
/// and what the tool said on stderr, and kept for `lastFailure`, so a report
/// (and a failing CI run) shows why instead of only that it failed. Probes
/// whose failure is an answer ("no such key") use `run`.
fn must(arena: std.mem.Allocator, argv: []const []const u8) Error!Ran {
    const r = run(arena, argv) catch |err| {
        if (err == error.ToolFailed) noteFailure(argv, "could not run it", "");
        return err;
    };
    if (!r.ok) {
        var code_buf: [24]u8 = undefined;
        // plutil reports some errors on stdout.
        const said = if (std.mem.trim(u8, r.err, " \t\r\n").len > 0) r.err else r.out;
        noteFailure(argv, std.fmt.bufPrint(&code_buf, "exit {d}", .{r.code}) catch "failed", said);
    }
    return r;
}

var last_failure_buf: [1024]u8 = undefined;
var last_failure_len: usize = 0;

/// The last step that had to succeed and did not: its command, how it ended
/// and its stderr. Empty after `clearFailure` until the next one.
pub fn lastFailure() []const u8 {
    return last_failure_buf[0..last_failure_len];
}

pub fn clearFailure() void {
    last_failure_len = 0;
}

fn noteFailure(argv: []const []const u8, how: []const u8, stderr: []const u8) void {
    var w: std.Io.Writer = .fixed(&last_failure_buf);
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch {};
        // The seed map is kilobytes of JSON, the mapping's value control bytes.
        if (arg.len > 80) {
            w.print("<{d} bytes>", .{arg.len}) catch {};
            continue;
        }
        for (arg) |c| w.writeByte(if (c < 0x20 or c == 0x7f) '?' else c) catch {};
    }
    w.print(" ({s}): {s}", .{ how, std.mem.trim(u8, stderr, " \t\r\n") }) catch {};
    last_failure_len = w.end;
    log.err("terminal_setup", "{s}", .{lastFailure()});
}

/// `name` as one plutil keypath component (`.` escaped), or null when it holds
/// a backslash, which a keypath cannot spell, or starts with `@`, on which
/// macOS 15's plutil aborts.
pub fn keypathComponent(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return null;
    if (name.len > 0 and name[0] == '@') return null;
    return try std.mem.replaceOwned(u8, arena, name, ".", "\\.");
}

/// One snapshot of the preferences: `defaults export` into `path`, read and
/// edited with plutil, written back whole with `defaults import`.
pub const Prefs = struct {
    arena: std.mem.Allocator,
    store: Store,
    path: []const u8,

    pub fn exportTo(arena: std.mem.Allocator, store: Store, path: []const u8) Error!Prefs {
        // A domain with no settings exports as an empty dictionary.
        if (!(try must(arena, &.{ defaults, "export", store.domain, path })).ok) return error.ToolFailed;
        return .{ .arena = arena, .store = store, .path = path };
    }

    pub fn importBack(self: *const Prefs) Error!void {
        if (!(try must(self.arena, &.{ defaults, "import", self.store.domain, self.path })).ok) return error.ToolFailed;
    }

    /// plutil's name for the value's type ("dictionary", "string", …), or null.
    fn typeOf(self: *const Prefs, keypath: []const u8) Error!?[]const u8 {
        const r = try run(self.arena, &.{ plutil, "-type", keypath, self.path });
        return if (r.ok) std.mem.trimEnd(u8, r.out, "\n") else null;
    }

    /// A string value as stored, or null when there is none.
    fn string(self: *const Prefs, keypath: []const u8) Error!?[]const u8 {
        const kind = try self.typeOf(keypath) orelse return null;
        if (!std.mem.eql(u8, kind, "string")) return null;
        const r = try must(self.arena, &.{ plutil, "-extract", keypath, "raw", "-o", "-", self.path });
        if (!r.ok) return error.ToolFailed;
        // `raw` ends the value with one line break of its own.
        return if (std.mem.endsWith(u8, r.out, "\n")) r.out[0 .. r.out.len - 1] else r.out;
    }

    /// A dictionary of strings as JSON, or null when there is none. Two steps:
    /// macOS 15's `plutil -extract … json` refuses when anything anywhere in
    /// the file has no JSON form (Terminal's colours and fonts are data), so
    /// the value is extracted as XML into a file of its own and converted there.
    fn json(self: *const Prefs, keypath: []const u8) Error!?[]const u8 {
        const part = try std.fmt.allocPrint(self.arena, "{s}.part.plist", .{self.path});
        defer files.remove(part);
        if (!(try run(self.arena, &.{ plutil, "-extract", keypath, "xml1", "-o", part, self.path })).ok) return null;
        const r = try must(self.arena, &.{ plutil, "-convert", "json", "-o", "-", part });
        return if (r.ok) r.out else null;
    }

    fn edit(self: *const Prefs, argv: []const []const u8) Error!void {
        if (!(try must(self.arena, argv)).ok) return error.ToolFailed;
    }
};

fn profileKeypath(arena: std.mem.Allocator, profile: []const u8, tail: []const u8) error{OutOfMemory}!?[]const u8 {
    const component = try keypathComponent(arena, profile) orelse return null;
    return try std.fmt.allocPrint(arena, "Window Settings.{s}{s}", .{ component, tail });
}

/// Terminal's built-in key map as JSON (every value is a string).
pub fn builtInMap(arena: std.mem.Allocator, store: Store) Error![]const u8 {
    const path = try std.fs.path.join(arena, &.{ store.app, "Contents", "Resources", "keyMappings.plist" });
    const r = try must(arena, &.{ plutil, "-convert", "json", "-o", "-", path });
    if (!r.ok) return error.NoBuiltInMap;
    const object = parseMap(arena, r.out) orelse return error.NoBuiltInMap;
    if (object.count() == 0 or object.get(shift_return) != null) return error.NoBuiltInMap;
    return r.out;
}

/// A key map as JSON: an object of strings, or null.
fn parseMap(arena: std.mem.Allocator, text: []const u8) ?std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    if (v != .object) return null;
    var it = v.object.iterator();
    while (it.next()) |entry| if (entry.value_ptr.* != .string) return null;
    return v.object;
}

/// `map` without `$000D` is exactly `base`.
fn isBasePlusShiftReturn(map: std.json.ObjectMap, base: std.json.ObjectMap) bool {
    if (map.count() != base.count() + 1) return false;
    var it = base.iterator();
    while (it.next()) |entry| {
        const v = map.get(entry.key_ptr.*) orelse return false;
        if (v != .string or !std.mem.eql(u8, v.string, entry.value_ptr.string)) return false;
    }
    return map.get(shift_return) != null;
}

/// The profiles new windows open with: `Default Window Settings` and
/// `Startup Window Settings` (usually the same one).
fn targetProfiles(arena: std.mem.Allocator, prefs: *const Prefs) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "Default Window Settings", "Startup Window Settings" }) |key| {
        const name = try prefs.string(key) orelse continue;
        if (name.len == 0) continue;
        for (names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try names.append(arena, name);
    }
    return names.items;
}

pub const Step = struct {
    profile: []const u8,
    /// The profile has no key map of its own: it gets the built-in one plus
    /// Shift+Return, so its other keys keep working.
    seed: bool,
};

pub const Plan = union(enum) {
    /// `steps` change; the profiles in `already` send the newline sequence for
    /// Shift+Return as they are.
    ready: struct { steps: []const Step, already: []const []const u8 },
    /// Shift+Return in `profile` sends something else (`value`): left alone.
    conflict: struct { profile: []const u8, value: []const u8 },
    /// No saved profiles yet: Terminal writes them once it has run.
    not_saved,
    /// A profile name plutil cannot address (`keypathComponent`).
    unaddressable: []const u8,
    /// The settings name a profile that is not among the saved ones.
    missing_profile: []const u8,
};

pub fn plan(prefs: *const Prefs) Error!Plan {
    const arena = prefs.arena;
    const kind = try prefs.typeOf("Window Settings");
    if (kind == null or !std.mem.eql(u8, kind.?, "dictionary")) return .not_saved;
    const names = try targetProfiles(arena, prefs);
    if (names.len == 0) return .not_saved;
    var steps: std.ArrayList(Step) = .empty;
    var already: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        const base = try profileKeypath(arena, name, "") orelse return .{ .unaddressable = name };
        const profile_kind = try prefs.typeOf(base);
        if (profile_kind == null or !std.mem.eql(u8, profile_kind.?, "dictionary")) return .{ .missing_profile = name };
        const map = try profileKeypath(arena, name, ".keyMapBoundKeys") orelse unreachable;
        const map_kind = try prefs.typeOf(map) orelse {
            try steps.append(arena, .{ .profile = name, .seed = true });
            continue;
        };
        if (!std.mem.eql(u8, map_kind, "dictionary")) return .{ .conflict = .{ .profile = name, .value = map_kind } };
        const key = try profileKeypath(arena, name, ".keyMapBoundKeys." ++ shift_return) orelse unreachable;
        const key_kind = try prefs.typeOf(key) orelse {
            try steps.append(arena, .{ .profile = name, .seed = false });
            continue;
        };
        const value = try prefs.string(key) orelse return .{ .conflict = .{ .profile = name, .value = key_kind } };
        if (std.mem.eql(u8, value, setup.newline_sequence)) {
            try already.append(arena, name);
        } else return .{ .conflict = .{ .profile = name, .value = value } };
    }
    return .{ .ready = .{ .steps = steps.items, .already = already.items } };
}

/// Makes `steps` in the snapshot and imports it. The caller has backed the
/// snapshot up first.
pub fn apply(prefs: *const Prefs, steps: []const Step) Error!void {
    const arena = prefs.arena;
    var seed: ?[]const u8 = null;
    for (steps) |step| {
        if (step.seed) {
            if (seed == null) seed = try builtInMap(arena, prefs.store);
            const map = (try profileKeypath(arena, step.profile, ".keyMapBoundKeys")).?;
            try prefs.edit(&.{ plutil, "-insert", map, "-json", seed.?, prefs.path });
        }
        const key = (try profileKeypath(arena, step.profile, ".keyMapBoundKeys." ++ shift_return)).?;
        try prefs.edit(&.{ plutil, "-insert", key, "-string", setup.newline_sequence, prefs.path });
    }
    try prefs.importBack();
}

/// Whether every one of `profiles` now sends the newline sequence for
/// Shift+Return, read back through a fresh export into `path`.
pub fn verify(arena: std.mem.Allocator, store: Store, path: []const u8, profiles: []const []const u8) Error!bool {
    const prefs = try Prefs.exportTo(arena, store, path);
    for (profiles) |name| {
        const key = try profileKeypath(arena, name, ".keyMapBoundKeys." ++ shift_return) orelse return false;
        const value = try prefs.string(key) orelse return false;
        if (!std.mem.eql(u8, value, setup.newline_sequence)) return false;
    }
    return true;
}

/// A profile `apply` changed, as the install record keeps it.
pub const Installed = struct {
    profile: []const u8,
    seeded: bool,
};

pub const Undo = enum {
    /// The copy of the built-in map came out: the profile is as it was.
    removed_map,
    /// Shift+Return came out of the profile's own map.
    removed_key,
    /// Shift+Return sends something else now: left alone.
    changed_since,
    /// No Shift+Return mapping (or no such profile) any more: nothing to undo.
    gone,
};

/// Undoes what `apply` did to `installed` in the snapshot and imports it when
/// anything changed. A seeded map whose other entries were edited since keeps
/// them and loses only Shift+Return. One `Undo` per profile, in order.
pub fn restore(prefs: *const Prefs, installed: []const Installed) Error![]const Undo {
    const arena = prefs.arena;
    const undone = try arena.alloc(Undo, installed.len);
    var changed = false;
    var base_map: ?std.json.ObjectMap = null;
    for (installed, undone) |p, *u| {
        const key = try profileKeypath(arena, p.profile, ".keyMapBoundKeys." ++ shift_return) orelse {
            u.* = .gone;
            continue;
        };
        const value = try prefs.string(key) orelse {
            u.* = .gone;
            continue;
        };
        if (!std.mem.eql(u8, value, setup.newline_sequence)) {
            u.* = .changed_since;
            continue;
        }
        const map = (try profileKeypath(arena, p.profile, ".keyMapBoundKeys")).?;
        u.* = .removed_key;
        if (p.seeded) {
            if (base_map == null) base_map = parseMap(arena, try builtInMap(arena, prefs.store));
            if (try prefs.json(map)) |text| if (parseMap(arena, text)) |current| {
                if (isBasePlusShiftReturn(current, base_map.?)) u.* = .removed_map;
            };
        }
        try prefs.edit(&.{ plutil, "-remove", if (u.* == .removed_map) map else key, prefs.path });
        changed = true;
    }
    if (changed) try prefs.importBack();
    return undone;
}

/// Whether Shift+Return in one of `profiles` sends the newline sequence,
/// read straight from a preferences file (one plutil run per profile, until
/// one does). For the footer hint, which cannot afford an export.
pub fn mapped(arena: std.mem.Allocator, prefs_file: []const u8, profiles: []const []const u8) bool {
    const prefs: Prefs = .{ .arena = arena, .store = .{}, .path = prefs_file };
    for (profiles) |name| {
        const key = (profileKeypath(arena, name, ".keyMapBoundKeys." ++ shift_return) catch return false) orelse continue;
        const r = run(arena, &.{ plutil, "-extract", key, "raw", "-o", "-", prefs.path }) catch return false;
        if (r.ok and std.mem.eql(u8, std.mem.trimEnd(u8, r.out, "\n"), setup.newline_sequence)) return true;
    }
    return false;
}

// ── The Terminal process ───────────────────────────────────────────────────

/// `struct proc_bsdshortinfo` (sys/proc_info.h). Its flavor answers for any
/// process, so the walk passes the root-owned `login` between Terminal and the
/// shell (PROC_PIDTBSDINFO does not; measured on the runners).
const ShortBsdInfo = extern struct {
    pid: u32,
    ppid: u32,
    pgid: u32,
    status: u32,
    comm: [16]u8,
    flags: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu: u32,
};
comptime {
    std.debug.assert(@sizeOf(ShortBsdInfo) == 64);
}
const PROC_PIDT_SHORTBSDINFO: c_int = 13;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn shortInfo(pid: c_int) ?ShortBsdInfo {
    var info: ShortBsdInfo = undefined;
    if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, @sizeOf(ShortBsdInfo)) != @sizeOf(ShortBsdInfo)) return null;
    return info;
}

/// The Terminal.app process running now for this user, or null when none is:
/// the one this process runs under, else any (setup run from iTerm2 with
/// `--terminal apple-terminal`). Recorded at install: that Terminal keeps the
/// profiles it read at launch, a later one has the mapping.
pub fn runningTerminalPid(arena: std.mem.Allocator, io: std.Io) ?i32 {
    if (builtin.os.tag != .macos) return null;
    if (terminalPid()) |pid| return pid;
    const procs = process_scan.listUnder(arena, io, default_app) catch return null;
    const uid = std.c.getuid();
    for (procs) |p| {
        if (!std.mem.endsWith(u8, p.exe, "/Contents/MacOS/Terminal")) continue;
        const info = shortInfo(@intCast(p.pid)) orelse continue;
        if (info.uid == uid) return @intCast(p.pid);
    }
    return null;
}

/// The pid of the Terminal.app process this one runs under, or null (not
/// macOS, not in Terminal, or the walk could not read an ancestor). Terminal
/// gets a new pid when it is reopened, so a pid that differs from the one
/// recorded at install says the mapping is loaded.
pub fn terminalPid() ?i32 {
    if (builtin.os.tag != .macos) return null;
    var pid: c_int = process.currentPid();
    for (0..64) |_| {
        const info = shortInfo(pid) orelse return null;
        if (std.mem.eql(u8, std.mem.sliceTo(&info.comm, 0), "Terminal")) return pid;
        if (info.ppid <= 1) return null;
        pid = @intCast(info.ppid);
    }
    return null;
}

// ── Tests: real plutil and defaults on a temporary domain (macOS) ─────────

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,
    store: Store,
    n: usize = 0,

    fn init() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = undefined, .store = undefined };
        const arena = f.arena_state.allocator();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        f.root = try arena.dupe(u8, buf[0..try f.tmp.dir.realPath(testing.io, &buf)]);
        // A path domain under the temporary directory: never the runner's own
        // com.apple.Terminal. The built-in map is the real one, read only.
        f.store = .{ .domain = try std.fs.path.join(arena, &.{ f.root, "domain", "terminal" }), .app = default_app };
        try f.tmp.dir.createDirPath(testing.io, "domain");
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena_state.deinit();
        testing.allocator.destroy(f);
    }

    fn path(f: *Fixture, name: []const u8) ![]const u8 {
        f.n += 1;
        return std.fmt.allocPrint(f.arena_state.allocator(), "{s}/{d}-{s}", .{ f.root, f.n, name });
    }

    /// Seeds the domain from JSON, plus a data value the way Terminal keeps
    /// colours and fonts: a document JSON cannot represent as a whole.
    fn seed(f: *Fixture, body: []const u8) !void {
        const arena = f.arena_state.allocator();
        const json_path = try f.path("seed.json");
        const plist_path = try f.path("seed.plist");
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = std.fs.path.basename(json_path), .data = body });
        try testing.expect((try run(arena, &.{ plutil, "-convert", "binary1", "-o", plist_path, json_path })).ok);
        try testing.expect((try run(arena, &.{ plutil, "-insert", "NSWindow Data", "-data", "AAEC", plist_path })).ok);
        try testing.expect((try run(arena, &.{ defaults, "import", f.store.domain, plist_path })).ok);
    }

    fn snapshot(f: *Fixture) !Prefs {
        return Prefs.exportTo(f.arena_state.allocator(), f.store, try f.path("export.plist"));
    }

    /// The domain's `Window Settings`, as JSON for comparison.
    fn windowSettings(f: *Fixture) !std.json.Value {
        const arena = f.arena_state.allocator();
        const prefs = try f.snapshot();
        const text = (try prefs.json("Window Settings")).?;
        return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    }

    fn shiftReturn(f: *Fixture, profile: []const u8) !?[]const u8 {
        const prefs = try f.snapshot();
        return prefs.string((try profileKeypath(f.arena_state.allocator(), profile, ".keyMapBoundKeys." ++ shift_return)).?);
    }
};

fn expectSameJson(a: std.json.Value, b: std.json.Value) !void {
    const sa = try std.json.Stringify.valueAlloc(testing.allocator, a, .{});
    defer testing.allocator.free(sa);
    const sb = try std.json.Stringify.valueAlloc(testing.allocator, b, .{});
    defer testing.allocator.free(sb);
    // Key order out of plutil follows the dictionary, not insertion; compare parsed maps.
    var pa = try std.json.parseFromSlice(std.json.Value, testing.allocator, sa, .{});
    defer pa.deinit();
    var pb = try std.json.parseFromSlice(std.json.Value, testing.allocator, sb, .{});
    defer pb.deinit();
    try testing.expect(jsonEqual(pa.value, pb.value));
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .object => |o| blk: {
            if (o.count() != b.object.count()) break :blk false;
            var it = o.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        .array => |arr| blk: {
            if (arr.items.len != b.array.items.len) break :blk false;
            for (arr.items, b.array.items) |x, y| if (!jsonEqual(x, y)) break :blk false;
            break :blk true;
        },
        .string => |s| std.mem.eql(u8, s, b.string),
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .null => true,
        else => false,
    };
}

const fresh_profiles =
    \\{"Default Window Settings":"Basic","Startup Window Settings":"Basic",
    \\ "Window Settings":{"Basic":{"name":"Basic","type":"Window Settings","columnCount":80},
    \\                   "Pro":{"name":"Pro","type":"Window Settings"}}}
;

test "apple terminal: a profile without a key map gets the built-in one plus Shift+Return, and restore takes it away" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    const arena = f.arena_state.allocator();
    try f.seed(fresh_profiles);
    const before = try f.windowSettings();

    const prefs = try f.snapshot();
    const p = try plan(&prefs);
    try testing.expectEqual(@as(usize, 1), p.ready.steps.len);
    try testing.expectEqualStrings("Basic", p.ready.steps[0].profile);
    try testing.expect(p.ready.steps[0].seed);
    try apply(&prefs, p.ready.steps);
    try testing.expect(try verify(arena, f.store, try f.path("verify.plist"), &.{"Basic"}));

    // Every built-in entry is there (F5, Shift+Right, Option+Left, …), plus ours.
    const after = try f.windowSettings();
    const map = after.object.get("Basic").?.object.get("keyMapBoundKeys").?.object;
    const base = parseMap(arena, try builtInMap(arena, f.store)).?;
    try testing.expect(base.count() > 20);
    try testing.expect(isBasePlusShiftReturn(map, base));
    try testing.expectEqualStrings("\x1b\r", map.get(shift_return).?.string);
    try testing.expect(after.object.get("Pro").?.object.get("keyMapBoundKeys") == null);

    // Planning again finds it installed.
    const again = try f.snapshot();
    const p2 = try plan(&again);
    try testing.expectEqual(@as(usize, 0), p2.ready.steps.len);
    try testing.expectEqualStrings("Basic", p2.ready.already[0]);

    const undo = try restore(&again, &.{.{ .profile = "Basic", .seeded = true }});
    try testing.expectEqual(Undo.removed_map, undo[0]);
    try expectSameJson(before, try f.windowSettings());
}

test "apple terminal: a profile's own key map gains only Shift+Return and loses only it" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    // Two target profiles, with names a keypath must escape.
    try f.seed(
        \\{"Default Window Settings":"Bob's Profile.v2","Startup Window Settings":"Pro",
        \\ "Window Settings":{"Bob's Profile.v2":{"name":"Bob's Profile.v2","keyMapBoundKeys":{"F708":"\u001b[15~"}},
        \\                   "Pro":{"name":"Pro"}}}
    );
    const before = try f.windowSettings();
    const prefs = try f.snapshot();
    const p = try plan(&prefs);
    try testing.expectEqual(@as(usize, 2), p.ready.steps.len);
    try testing.expect(!p.ready.steps[0].seed);
    try testing.expect(p.ready.steps[1].seed);
    try apply(&prefs, p.ready.steps);
    try testing.expectEqualStrings("\x1b\r", (try f.shiftReturn("Bob's Profile.v2")).?);
    try testing.expectEqualStrings("\x1b\r", (try f.shiftReturn("Pro")).?);
    const after = try f.windowSettings();
    try testing.expectEqual(@as(usize, 2), after.object.get("Bob's Profile.v2").?.object.get("keyMapBoundKeys").?.object.count());

    const undo = try restore(&(try f.snapshot()), &.{ .{ .profile = "Bob's Profile.v2", .seeded = false }, .{ .profile = "Pro", .seeded = true } });
    try testing.expectEqual(Undo.removed_key, undo[0]);
    try testing.expectEqual(Undo.removed_map, undo[1]);
    try expectSameJson(before, try f.windowSettings());
}

test "apple terminal: a seeded map the user edited since keeps the edit on restore" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    const arena = f.arena_state.allocator();
    try f.seed(fresh_profiles);
    const prefs = try f.snapshot();
    try apply(&prefs, (try plan(&prefs)).ready.steps);
    // The user adds a mapping of their own in Terminal's settings: a key the
    // built-in map does not have, checked here rather than assumed for every
    // macOS. No `@` (Command): macOS 15's plutil refuses it in a keypath.
    const base = parseMap(arena, try builtInMap(arena, f.store)).?;
    const own = for ([_][]const u8{ "^~F70C", "^$F70C", "$~F70C", "^~F70D" }) |key| {
        if (base.get(key) == null) break key;
    } else return error.TestUnexpectedResult;
    const own_keypath = try std.fmt.allocPrint(arena, "Window Settings.Basic.keyMapBoundKeys.{s}", .{own});
    const edited = try f.snapshot();
    try edited.edit(&.{ plutil, "-insert", own_keypath, "-string", "mine", edited.path });
    try edited.importBack();

    const undo = try restore(&(try f.snapshot()), &.{.{ .profile = "Basic", .seeded = true }});
    try testing.expectEqual(Undo.removed_key, undo[0]);
    const map = (try f.windowSettings()).object.get("Basic").?.object.get("keyMapBoundKeys").?.object;
    try testing.expect(map.get(shift_return) == null);
    try testing.expectEqualStrings("mine", map.get(own).?.string);
}

test "apple terminal: a step that has to succeed reports the tool's stderr" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    try f.seed(fresh_profiles);
    const prefs = try f.snapshot();
    clearFailure();
    // Inserting a key that exists already fails in plutil.
    try testing.expectError(error.ToolFailed, prefs.edit(&.{ plutil, "-insert", "Window Settings.Basic.name", "-string", "x", prefs.path }));
    const why = lastFailure();
    try testing.expect(std.mem.startsWith(u8, why, plutil ++ " -insert Window Settings.Basic.name -string x "));
    try testing.expect(std.mem.indexOf(u8, why, "(exit ") != null);
    // plutil says what went wrong; the exact wording is the system's.
    try testing.expect(why.len > std.mem.indexOf(u8, why, "): ").? + 3);
}

test "apple terminal: what is left alone — another Shift+Return mapping, unsaved settings, odd names" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();

    // Terminal has never saved its settings: the export is an empty dictionary.
    try testing.expect((try plan(&(try f.snapshot()))) == .not_saved);

    try f.seed(
        \\{"Default Window Settings":"Basic","Window Settings":{"Basic":{"keyMapBoundKeys":{"$000D":"\u001b[13;2u"}}}}
    );
    const before = try f.windowSettings();
    const p = try plan(&(try f.snapshot()));
    try testing.expectEqualStrings("Basic", p.conflict.profile);
    try testing.expectEqualStrings("\x1b[13;2u", p.conflict.value);
    try expectSameJson(before, try f.windowSettings());

    try f.seed(
        \\{"Default Window Settings":"a\\b","Window Settings":{"a\\b":{}}}
    );
    try testing.expectEqualStrings("a\\b", (try plan(&(try f.snapshot()))).unaddressable);
    try f.seed(
        \\{"Default Window Settings":"@work","Window Settings":{"@work":{}}}
    );
    try testing.expectEqualStrings("@work", (try plan(&(try f.snapshot()))).unaddressable);
    try f.seed(
        \\{"Default Window Settings":"Gone","Window Settings":{"Basic":{}}}
    );
    try testing.expectEqualStrings("Gone", (try plan(&(try f.snapshot()))).missing_profile);

    // Restore leaves a mapping that changed since alone, and knows a vanished one.
    try f.seed(
        \\{"Default Window Settings":"Basic","Window Settings":{"Basic":{"keyMapBoundKeys":{"$000D":"x"}},"Pro":{}}}
    );
    const undo = try restore(&(try f.snapshot()), &.{ .{ .profile = "Basic", .seeded = false }, .{ .profile = "Pro", .seeded = true } });
    try testing.expectEqual(Undo.changed_since, undo[0]);
    try testing.expectEqual(Undo.gone, undo[1]);
    try testing.expectEqualStrings("x", (try f.shiftReturn("Basic")).?);
}

test "apple terminal: mapped reads a preferences file directly" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    const arena = f.arena_state.allocator();
    try f.seed(fresh_profiles);
    const prefs = try f.snapshot();
    try testing.expect(!mapped(arena, prefs.path, &.{ "Basic", "Pro" }));
    try apply(&prefs, (try plan(&prefs)).ready.steps);
    const file = (try f.snapshot()).path;
    try testing.expect(mapped(arena, file, &.{ "Pro", "Basic" }));
    try testing.expect(!mapped(arena, file, &.{"Pro"}));
}

test "apple terminal: terminalPid walks the real process tree" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // This process's own record matches what the kernel says about it.
    const self = shortInfo(process.currentPid()).?;
    try testing.expectEqual(@as(u32, @intCast(process.currentPid())), self.pid);
    try testing.expectEqual(@as(u32, @intCast(std.c.getppid())), self.ppid);
    // The test runner is not under Terminal.app on CI; under it, the pid found
    // is an ancestor named Terminal.
    if (terminalPid()) |pid| try testing.expectEqualStrings("Terminal", std.mem.sliceTo(&shortInfo(pid).?.comm, 0));
    // runningTerminalPid also finds a Terminal that is not an ancestor; whatever
    // it finds is a Terminal of this user.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    if (runningTerminalPid(arena_state.allocator(), testing.io)) |pid| {
        const info = shortInfo(pid).?;
        try testing.expectEqualStrings("Terminal", std.mem.sliceTo(&info.comm, 0));
        try testing.expectEqual(@as(u32, std.c.getuid()), info.uid);
    }
}

test "keypathComponent escapes dots and refuses backslashes and a leading @" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("Bob's Profile\\.v2", (try keypathComponent(arena, "Bob's Profile.v2")).?);
    try testing.expectEqualStrings("Man Page", (try keypathComponent(arena, "Man Page")).?);
    try testing.expectEqualStrings("me@work", (try keypathComponent(arena, "me@work")).?);
    try testing.expect((try keypathComponent(arena, "a\\b")) == null);
    try testing.expect((try keypathComponent(arena, "@work")) == null);
}
