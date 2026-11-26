//! `skillOverrides`: per-Skill visibility overrides kept in the Claude Code
//! settings files, with Claude Code's semantics (2.1.278):
//!
//!   "on"                  listed to the model with its description (the default)
//!   "name-only"           listed without its description
//!   "user-invocable-only" hidden from the model; `/name` still runs it
//!   "off"                 hidden from both
//!
//! Layers are `~/.claude/settings.json` < `<project>/.claude/settings.json` <
//! `<project>/.claude/settings.local.json`; an absent entry is "on". `/skills`
//! writes the local layer, and drops an entry whose value equals what the
//! project and user layers already give.
//!
//! The App owns one `Overrides`. Background jobs read it through the Skill
//! Runtime while `/skills` may change it on the REPL thread, so every access
//! takes `mutex`.

const std = @import("std");
const pfs = @import("platform").fs;
const sync = @import("platform").sync;
const json_merge = @import("metacodes-base").util.json_merge;
const util_fs = @import("metacodes-base").util.fs;
const log = @import("metacodes-base").util.log;
const model_tool = @import("runtime/model_tool.zig");

pub const SETTINGS_KEY = "skillOverrides";

pub const State = enum {
    on,
    name_only,
    user_invocable_only,
    off,

    /// `/skills` cycle order (Enter / Space).
    pub const cycle = [_]State{ .on, .name_only, .user_invocable_only, .off };

    pub fn wireName(self: State) []const u8 {
        return switch (self) {
            .on => "on",
            .name_only => "name-only",
            .user_invocable_only => "user-invocable-only",
            .off => "off",
        };
    }

    pub fn parse(text: []const u8) ?State {
        inline for (cycle) |state| {
            if (std.mem.eql(u8, text, comptime state.wireName())) return state;
        }
        return null;
    }

    pub fn next(self: State) State {
        return cycle[(@as(usize, @intFromEnum(self)) + 1) % cycle.len];
    }

    /// How the model-facing listings show the Skill.
    pub fn listing(self: State) model_tool.Listing {
        return switch (self) {
            .on => .full,
            .name_only => .name_only,
            .user_invocable_only, .off => .hidden,
        };
    }

    /// Whether the Skill tool may activate it.
    pub fn modelInvocable(self: State) bool {
        return self == .on or self == .name_only;
    }

    /// Whether `/name` may run it.
    pub fn userInvocable(self: State) bool {
        return self != .off;
    }
};

pub const Layer = enum { user, project, local };

/// A `/skills` outcome: the state the user left `name` in.
pub const Change = struct {
    name: []const u8,
    state: State,
};

pub const CommitError = error{
    /// No project root, so there is no local settings file to write.
    NoProjectRoot,
    /// The local settings file exists but could not be read.
    SettingsUnreadable,
    /// The local settings file (or its `skillOverrides`) is not a JSON
    /// object: it is left untouched rather than overwritten.
    MalformedSettings,
    WriteFailed,
    PathTooLong,
    OutOfMemory,
};

const Map = std.StringArrayHashMapUnmanaged(State);

pub const Overrides = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    layers: [3]Map = .{ .empty, .empty, .empty },
    /// `<project root>/.claude/settings.local.json`; null without a project root.
    local_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Overrides {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Overrides) void {
        for (&self.layers) |*map| freeMap(self.allocator, map);
        if (self.local_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Read the three layers. An absent file contributes nothing; a file that
    /// cannot be read or parsed is logged and contributes nothing, as Claude
    /// Code ignores an invalid settings file.
    pub fn load(self: *Overrides, home: []const u8, project_root: ?[]const u8) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (home.len != 0) {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/.claude/settings.json", .{home});
            defer self.allocator.free(path);
            try self.loadLayerLocked(.user, path);
        }
        if (project_root) |root| {
            const shared = try std.fmt.allocPrint(self.allocator, "{s}/.claude/settings.json", .{root});
            defer self.allocator.free(shared);
            try self.loadLayerLocked(.project, shared);
            const local = try std.fmt.allocPrint(self.allocator, "{s}/.claude/settings.local.json", .{root});
            errdefer self.allocator.free(local);
            try self.loadLayerLocked(.local, local);
            if (self.local_path) |old| self.allocator.free(old);
            self.local_path = local;
        }
    }

    /// The effective state of `name`: local ?? project ?? user ?? on.
    pub fn stateOf(self: *Overrides, name: []const u8) State {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.layers[@intFromEnum(Layer.local)].get(name) orelse self.inheritedLocked(name);
    }

    /// Effective states for `names`, read under one lock so they are
    /// mutually consistent.
    pub fn statesOf(self: *Overrides, names: []const []const u8, out: []State) void {
        std.debug.assert(names.len == out.len);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (names, out) |name, *state| {
            state.* = self.layers[@intFromEnum(Layer.local)].get(name) orelse self.inheritedLocked(name);
        }
    }

    /// Record `changes` in the local settings file, then in memory.
    ///
    /// The file is read again here, so entries written since the Session
    /// started (by another Session, or by hand) and entries this version does
    /// not understand are kept. An entry whose state equals what the project
    /// and user layers give is removed rather than repeated.
    pub fn commit(self: *Overrides, changes: []const Change) CommitError!void {
        if (changes.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        const path = self.local_path orelse return error.NoProjectRoot;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const existing = readWhole(arena, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PathTooLong => return error.PathTooLong,
            error.Unreadable => return error.SettingsUnreadable,
        } orelse "";
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        const document = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            if (trimmed.len == 0) "{}" else trimmed,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedSettings,
        };
        if (document != .object) return error.MalformedSettings;
        var entries: std.json.ObjectMap = if (document.object.get(SETTINGS_KEY)) |value| switch (value) {
            .object => |object| object,
            else => return error.MalformedSettings,
        } else .empty;

        for (changes) |change| {
            if (change.state == self.inheritedLocked(change.name)) {
                _ = entries.orderedRemove(change.name);
            } else {
                try entries.put(arena, change.name, .{ .string = change.state.wireName() });
            }
        }

        const entries_json = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = entries }, .{});
        const merged = json_merge.mergeObjectFields(arena, existing, &.{
            .{ .key = SETTINGS_KEY, .json = entries_json },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedSettings,
        };
        const body = try std.mem.concat(arena, u8, &.{ merged, "\n" });
        try util_fs.mkdirParentsOf(path);
        try writeAtomic(path, body);

        var local: Map = .empty;
        errdefer freeMap(self.allocator, &local);
        try fillMap(self.allocator, &local, entries);
        freeMap(self.allocator, &self.layers[@intFromEnum(Layer.local)]);
        self.layers[@intFromEnum(Layer.local)] = local;
    }

    fn inheritedLocked(self: *const Overrides, name: []const u8) State {
        return self.layers[@intFromEnum(Layer.project)].get(name) orelse
            self.layers[@intFromEnum(Layer.user)].get(name) orelse .on;
    }

    fn loadLayerLocked(self: *Overrides, layer: Layer, path: []const u8) error{OutOfMemory}!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const map = &self.layers[@intFromEnum(layer)];
        freeMap(self.allocator, map);

        const text = readWhole(arena, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("skill", "{s}: unreadable, skillOverrides ignored", .{path});
                return;
            },
        } orelse return;
        const document = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("skill", "{s}: not valid JSON, skillOverrides ignored", .{path});
                return;
            },
        };
        if (document != .object) return;
        const value = document.object.get(SETTINGS_KEY) orelse return;
        if (value != .object) {
            log.warn("skill", "{s}: skillOverrides is not an object, ignored", .{path});
            return;
        }
        try fillMap(self.allocator, map, value.object);
    }
};

/// Copy the valid entries of a `skillOverrides` object into `map`. An entry
/// with an unknown value is skipped (and kept in the file by `commit`).
fn fillMap(allocator: std.mem.Allocator, map: *Map, object: std.json.ObjectMap) error{OutOfMemory}!void {
    var it = object.iterator();
    while (it.next()) |entry| {
        const state = switch (entry.value_ptr.*) {
            .string => |text| State.parse(text),
            else => null,
        } orelse {
            log.warn("skill", "skillOverrides.{s}: unknown value, ignored", .{entry.key_ptr.*});
            continue;
        };
        const gop = try map.getOrPut(allocator, entry.key_ptr.*);
        if (!gop.found_existing) {
            gop.key_ptr.* = allocator.dupe(u8, entry.key_ptr.*) catch |err| {
                map.swapRemoveAt(gop.index);
                return err;
            };
        }
        gop.value_ptr.* = state;
    }
}

fn freeMap(allocator: std.mem.Allocator, map: *Map) void {
    for (map.keys()) |key| allocator.free(key);
    map.deinit(allocator);
    map.* = .empty;
}

/// The whole file, or null when it does not exist. Any other failure is an
/// error: the caller writes back what it read, so reading a transient failure
/// as "empty" would erase the user's settings.
fn readWhole(allocator: std.mem.Allocator, path: []const u8) error{ OutOfMemory, PathTooLong, Unreadable }!?[]u8 {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) {
        if (pfs.lastErrnoIs(.NOENT)) return null;
        return error.Unreadable;
    }
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n == 0) break;
        if (n < 0) return error.Unreadable;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(allocator);
}

/// Write `<path>.tmp`, then rename it over `path`: a reader never sees a
/// half-written settings file.
fn writeAtomic(path: []const u8, body: []const u8) error{ PathTooLong, WriteFailed }!void {
    var tmp_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const tmp_z = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path}) catch return error.PathTooLong;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

    const fd = pfs.open(tmp_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.WriteFailed;
    var written: usize = 0;
    while (written < body.len) {
        const n = pfs.write(fd, body[written..]);
        if (n <= 0) {
            pfs.close(fd);
            pfs.unlinkPath(tmp_z.ptr) catch {};
            return error.WriteFailed;
        }
        written += @intCast(n);
    }
    pfs.fsync(fd);
    pfs.close(fd); // close before rename (Windows)
    if (pfs.renameReplace(tmp_z.ptr, path_z.ptr) != 0) {
        pfs.unlinkPath(tmp_z.ptr) catch {};
        return error.WriteFailed;
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    home: []u8,
    project: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..len]);
        errdefer testing.allocator.free(root);
        try tmp.dir.createDirPath(testing.io, "home/.claude");
        try tmp.dir.createDirPath(testing.io, "proj/.claude");
        const home = try std.fmt.allocPrint(testing.allocator, "{s}/home", .{root});
        errdefer testing.allocator.free(home);
        const project = try std.fmt.allocPrint(testing.allocator, "{s}/proj", .{root});
        return .{ .tmp = tmp, .root = root, .home = home, .project = project };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.project);
        testing.allocator.free(self.home);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn read(self: *Fixture, rel: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, rel, testing.allocator, .limited(1 << 20));
    }
};

test "State: wire names round-trip and the cycle wraps" {
    for (State.cycle) |state| try testing.expectEqual(state, State.parse(state.wireName()).?);
    try testing.expect(State.parse("ON") == null);
    try testing.expect(State.parse("user-only") == null);
    try testing.expectEqual(State.name_only, State.on.next());
    try testing.expectEqual(State.user_invocable_only, State.name_only.next());
    try testing.expectEqual(State.off, State.user_invocable_only.next());
    try testing.expectEqual(State.on, State.off.next());
}

test "State: who sees the Skill" {
    try testing.expectEqual(model_tool.Listing.full, State.on.listing());
    try testing.expectEqual(model_tool.Listing.name_only, State.name_only.listing());
    try testing.expectEqual(model_tool.Listing.hidden, State.user_invocable_only.listing());
    try testing.expectEqual(model_tool.Listing.hidden, State.off.listing());
    try testing.expect(State.name_only.modelInvocable());
    try testing.expect(!State.user_invocable_only.modelInvocable());
    try testing.expect(State.user_invocable_only.userInvocable());
    try testing.expect(!State.off.userInvocable());
}

test "load: local over project over user; absent is on" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("home/.claude/settings.json",
        \\{"skillOverrides":{"a":"off","b":"name-only","c":"name-only"}}
    );
    try fx.write("proj/.claude/settings.json",
        \\{"skillOverrides":{"b":"user-invocable-only"}}
    );
    try fx.write("proj/.claude/settings.local.json",
        \\{"permissions":{"allow":["Read"]},"skillOverrides":{"c":"on","d":"bogus"}}
    );
    var overrides = Overrides.init(testing.allocator);
    defer overrides.deinit();
    try overrides.load(fx.home, fx.project);
    try testing.expectEqual(State.off, overrides.stateOf("a"));
    try testing.expectEqual(State.user_invocable_only, overrides.stateOf("b"));
    try testing.expectEqual(State.on, overrides.stateOf("c"));
    try testing.expectEqual(State.on, overrides.stateOf("d"));
    try testing.expectEqual(State.on, overrides.stateOf("missing"));

    var states: [2]State = undefined;
    overrides.statesOf(&.{ "a", "b" }, &states);
    try testing.expectEqual(State.off, states[0]);
    try testing.expectEqual(State.user_invocable_only, states[1]);
}

test "load: a malformed file is ignored, the other layers still apply" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("home/.claude/settings.json",
        \\{"skillOverrides":{"a":"off"}}
    );
    try fx.write("proj/.claude/settings.local.json", "{not json");
    var overrides = Overrides.init(testing.allocator);
    defer overrides.deinit();
    try overrides.load(fx.home, fx.project);
    try testing.expectEqual(State.off, overrides.stateOf("a"));
}

test "commit: writes the local layer and keeps every other key" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("proj/.claude/settings.local.json",
        \\{"permissions":{"allow":["Read"]},"skillOverrides":{"keep":"off","odd":"later-value"}}
    );
    var overrides = Overrides.init(testing.allocator);
    defer overrides.deinit();
    try overrides.load(fx.home, fx.project);
    try overrides.commit(&.{
        .{ .name = "proj-skill", .state = .user_invocable_only },
        .{ .name = "demo-skill", .state = .off },
    });
    try testing.expectEqual(State.user_invocable_only, overrides.stateOf("proj-skill"));
    try testing.expectEqual(State.off, overrides.stateOf("demo-skill"));
    try testing.expectEqual(State.off, overrides.stateOf("keep"));

    const text = try fx.read("proj/.claude/settings.local.json");
    defer testing.allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("Read", parsed.value.object.get("permissions").?.object.get("allow").?.array.items[0].string);
    const entries = parsed.value.object.get(SETTINGS_KEY).?.object;
    try testing.expectEqualStrings("off", entries.get("keep").?.string);
    // A value this version does not know survives the rewrite.
    try testing.expectEqualStrings("later-value", entries.get("odd").?.string);
    try testing.expectEqualStrings("user-invocable-only", entries.get("proj-skill").?.string);
    try testing.expectEqualStrings("off", entries.get("demo-skill").?.string);
    try testing.expect(std.mem.endsWith(u8, text, "}\n"));
}

test "commit: a value equal to the inherited one drops the local entry" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write("proj/.claude/settings.json",
        \\{"skillOverrides":{"proj-skill":"name-only"}}
    );
    var overrides = Overrides.init(testing.allocator);
    defer overrides.deinit();
    try overrides.load(fx.home, fx.project);
    try testing.expectEqual(State.name_only, overrides.stateOf("proj-skill"));

    // Differs from the project layer: written.
    try overrides.commit(&.{.{ .name = "proj-skill", .state = .on }});
    try testing.expectEqual(State.on, overrides.stateOf("proj-skill"));
    {
        const text = try fx.read("proj/.claude/settings.local.json");
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "\"proj-skill\": \"on\"") != null);
    }
    // Back to the project value: the local entry goes, the object stays (Claude Code).
    try overrides.commit(&.{.{ .name = "proj-skill", .state = .name_only }});
    try testing.expectEqual(State.name_only, overrides.stateOf("proj-skill"));
    const text = try fx.read("proj/.claude/settings.local.json");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "proj-skill") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"skillOverrides\": {}") != null);

    // "on" with nothing inherited is the default: no entry is written.
    try overrides.commit(&.{.{ .name = "fresh", .state = .on }});
    const again = try fx.read("proj/.claude/settings.local.json");
    defer testing.allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "fresh") == null);
}

test "commit: creates .claude and the file when neither exists" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(testing.io, "bare");
    const bare = try std.fmt.allocPrint(testing.allocator, "{s}/bare", .{fx.root});
    defer testing.allocator.free(bare);
    var overrides = Overrides.init(testing.allocator);
    defer overrides.deinit();
    try overrides.load(fx.home, bare);
    try overrides.commit(&.{.{ .name = "x", .state = .off }});
    const text = try fx.read("bare/.claude/settings.local.json");
    defer testing.allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("off", parsed.value.object.get(SETTINGS_KEY).?.object.get("x").?.string);
}

test "commit: a malformed local file is left alone and nothing changes" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var overrides = Overrides.init(testing.allocator);
    defer overrides.deinit();
    try overrides.load(fx.home, fx.project);
    try fx.write("proj/.claude/settings.local.json", "{\"permissions\": [oops");
    try testing.expectError(error.MalformedSettings, overrides.commit(&.{.{ .name = "x", .state = .off }}));
    try testing.expectEqual(State.on, overrides.stateOf("x"));
    const text = try fx.read("proj/.claude/settings.local.json");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"permissions\": [oops", text);

    try fx.write("proj/.claude/settings.local.json", "{\"skillOverrides\": [\"x\"]}");
    try testing.expectError(error.MalformedSettings, overrides.commit(&.{.{ .name = "x", .state = .off }}));
}

test "commit: without a project root there is nowhere to write" {
    var overrides = Overrides.init(testing.allocator);
    defer overrides.deinit();
    try overrides.load("", null);
    try testing.expectError(error.NoProjectRoot, overrides.commit(&.{.{ .name = "x", .state = .off }}));
    try overrides.commit(&.{});
}
