//! The state root: the one directory that holds this install's user state
//! (config, auth, kg store, projects/transcripts, teams, plans, history, ...).
//!
//! Several metacodes installs may coexist on one machine, each with its own
//! store and Lean rules, so the root belongs to the install, not to $HOME.
//! Resolution, first match wins:
//!
//!   1. `--state-dir <dir>` (`setFlagOverride`, made absolute by the CLI);
//!   2. `METACODES_HOME` (absolute; empty = unset);
//!   3. `<prefix>/etc/metacodes/install.json` beside the physical executable,
//!      written by scripts/install.sh: `{"schema_version":"metacodes-install-v1",
//!      "state_root":"state"}` — a relative root is relative to `<prefix>`, so
//!      an install directory can be moved as a whole;
//!   4. `$HOME/.metacodes` (development builds and installs predating this).
//!
//! `legacyDefault(home)` is the same `$HOME/.metacodes` for hosts that only
//! know a home directory (the AgentCore ABI's `workspace_home`).
//!
//! An install.json that exists but cannot be read or validated is an error,
//! never a fallback: silently using `$HOME/.metacodes` would merge an isolated
//! install's state into the default one.
//!
//! This policy belongs to the host. The CLI calls `resolve()` once at startup,
//! refuses to start on an error, and passes the result down explicitly (App,
//! ToolContext, swarm, KG, every subsystem constructor). `metacodes-core`
//! modules never call `resolve()`: an embedding application decides where its
//! sessions keep state (`WorkspaceConfig.state_root`), and two sessions in one
//! process may use different roots.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const platform = @import("platform");
const pfs = platform.fs;
const sync = platform.sync;

pub const env_variable = "METACODES_HOME";
pub const manifest_relative_path = "etc/metacodes/install.json";
pub const manifest_schema = "metacodes-install-v1";
const default_dir_name = ".metacodes";
const max_manifest_bytes = 16 * 1024;

pub const Source = enum {
    flag,
    env,
    install,
    home,

    pub fn label(source: Source) []const u8 {
        return switch (source) {
            .flag => "flag",
            .env => "env",
            .install => "install",
            .home => "home",
        };
    }
};

pub const Resolved = struct {
    path: []const u8,
    source: Source,
};

pub const Error = error{
    /// `--state-dir` / `METACODES_HOME` / a manifest root that is not absolute.
    StateRootNotAbsolute,
    /// install.json exists but cannot be read.
    InstallManifestUnreadable,
    /// install.json is not a `metacodes-install-v1` document with a non-empty `state_root`.
    InstallManifestInvalid,
    /// Nothing configured and no $HOME.
    NoStateRoot,
    PathTooLong,
};

pub const Inputs = struct {
    flag: ?[]const u8 = null,
    env: ?[]const u8 = null,
    /// Physical path of the running executable; its grandparent is the prefix.
    exe_path: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

/// Pure resolution over explicit inputs (the filesystem is consulted only for
/// install.json). The result's `path` lives in `buf`.
/// Trailing separators are dropped (`/x/` is `/x`), so every path built from
/// the root, and every prefix check against it, sees one spelling.
pub fn resolveFrom(inputs: Inputs, buf: []u8) Error!Resolved {
    const resolved = try resolveRaw(inputs, buf);
    return .{ .path = trimTrailingSeparators(resolved.path), .source = resolved.source };
}

fn resolveRaw(inputs: Inputs, buf: []u8) Error!Resolved {
    if (nonEmpty(inputs.flag)) |dir| return .{ .path = try absoluteInto(dir, buf), .source = .flag };
    if (nonEmpty(inputs.env)) |dir| return .{ .path = try absoluteInto(dir, buf), .source = .env };
    if (inputs.exe_path) |exe| if (prefixOf(exe)) |prefix| {
        if (try manifestRoot(prefix, buf)) |path| return .{ .path = path, .source = .install };
    };
    const home = nonEmpty(inputs.home) orelse return error.NoStateRoot;
    return .{ .path = try joinInto(buf, &.{ home, default_dir_name }), .source = .home };
}

/// `/x//` → `/x`; a filesystem root (`/`, `C:\`) is kept as is.
fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {
        if (end == 3 and path[1] == ':') break; // `C:\`
    }
    return path[0..end];
}

/// `<prefix>` of an executable installed at `<prefix>/bin/<exe>`.
pub fn prefixOf(exe_path: []const u8) ?[]const u8 {
    const bin_dir = std.fs.path.dirname(exe_path) orelse return null;
    return std.fs.path.dirname(bin_dir);
}

fn manifestRoot(prefix: []const u8, buf: []u8) Error!?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = try joinZ(&path_buf, &.{ prefix, manifest_relative_path });
    const fd = pfs.open(manifest_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) {
        if (!pfs.exists(manifest_path.ptr)) return null;
        return error.InstallManifestUnreadable;
    }
    defer pfs.close(fd);
    var bytes_buf: [max_manifest_bytes]u8 = undefined;
    var len: usize = 0;
    while (len < bytes_buf.len) {
        const n = pfs.read(fd, bytes_buf[len..]);
        if (n < 0) return error.InstallManifestUnreadable;
        if (n == 0) break;
        len += @intCast(n);
    }
    if (len == bytes_buf.len) return error.InstallManifestInvalid;

    var parse_buf: [max_manifest_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const Manifest = struct { schema_version: []const u8, state_root: []const u8 };
    const manifest = std.json.parseFromSliceLeaky(Manifest, fba.allocator(), bytes_buf[0..len], .{
        .ignore_unknown_fields = true,
    }) catch return error.InstallManifestInvalid;
    if (!std.mem.eql(u8, manifest.schema_version, manifest_schema)) return error.InstallManifestInvalid;
    if (manifest.state_root.len == 0) return error.InstallManifestInvalid;
    if (std.fs.path.isAbsolute(manifest.state_root)) return try copyInto(manifest.state_root, buf);
    return try joinInto(buf, &.{ prefix, manifest.state_root });
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

fn absoluteInto(dir: []const u8, buf: []u8) Error![]const u8 {
    if (!std.fs.path.isAbsolute(dir)) return error.StateRootNotAbsolute;
    return copyInto(dir, buf);
}

fn copyInto(text: []const u8, buf: []u8) Error![]const u8 {
    if (text.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

fn joinInto(buf: []u8, parts: []const []const u8) Error![]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    return std.fs.path.join(fba.allocator(), parts) catch error.PathTooLong;
}

fn joinZ(buf: []u8, parts: []const []const u8) Error![:0]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    return std.fs.path.joinZ(fba.allocator(), parts) catch error.PathTooLong;
}

// ── process-wide resolution ────────────────────────────────────────────────

var flag_override_buf: [std.fs.max_path_bytes]u8 = undefined;
var flag_override: ?[]const u8 = null;
var init_mutex: sync.Mutex = .{};
var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
var cached: ?(Error!Resolved) = null;

/// Records `--state-dir`. Must run before the first `resolve()`/`get()`;
/// `dir` must already be absolute (the CLI resolves it against the cwd).
pub fn setFlagOverride(dir: []const u8) Error!void {
    _ = init_mutex.lock();
    defer _ = init_mutex.unlock();
    std.debug.assert(cached == null);
    flag_override = try absoluteInto(dir, &flag_override_buf);
}

/// The process's state root, resolved once and cached (errors included).
/// Host entry points only (src/main.zig); see the module comment.
pub fn resolve() Error!Resolved {
    _ = init_mutex.lock();
    defer _ = init_mutex.unlock();
    if (cached) |result| return result;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = resolveFrom(.{
        .flag = flag_override,
        .env = envValue(),
        .exe_path = platform.paths.selfExeRealPath(&exe_buf),
        .home = platform.paths.homeDir(),
    }, &resolved_buf);
    cached = result;
    return result;
}

/// `<home>/.metacodes`, owned by the caller. For hosts that configure a home
/// but no state root.
pub fn legacyDefault(allocator: std.mem.Allocator, home: []const u8) error{OutOfMemory}![]u8 {
    return std.fs.path.join(allocator, &.{ home, default_dir_name });
}

fn envValue() ?[]const u8 {
    return platform.paths.metacodesHomeEnv();
}

// ── tests ──────────────────────────────────────────────────────────────────

const TestInstall = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    exe_buf: [std.fs.max_path_bytes]u8 = undefined,
    exe: []const u8 = "",

    fn init(self: *TestInstall) !void {
        self.tmp = std.testing.tmpDir(.{});
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buf);
        self.root = self.root_buf[0..len];
        try self.tmp.dir.createDirPath(std.testing.io, "bin");
        self.exe = try std.fmt.bufPrint(&self.exe_buf, "{s}/bin/metacodes", .{self.root});
    }

    fn writeManifest(self: *TestInstall, bytes: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, "etc/metacodes");
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_relative_path, .data = bytes });
    }
};

test "no manifest falls back to $HOME/.metacodes; no home is an error" {
    if (is_windows) return error.SkipZigTest;
    var install: TestInstall = .{ .tmp = undefined };
    try install.init();
    defer install.tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try resolveFrom(.{ .exe_path = install.exe, .home = "/home/u" }, &buf);
    try std.testing.expectEqualStrings("/home/u/.metacodes", resolved.path);
    try std.testing.expectEqual(Source.home, resolved.source);
    try std.testing.expectError(error.NoStateRoot, resolveFrom(.{ .exe_path = install.exe }, &buf));
    try std.testing.expectError(error.NoStateRoot, resolveFrom(.{ .exe_path = install.exe, .home = "" }, &buf));
}

test "install manifest roots state relative to the prefix or absolutely" {
    if (is_windows) return error.SkipZigTest;
    var install: TestInstall = .{ .tmp = undefined };
    try install.init();
    defer install.tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;

    try install.writeManifest("{\"schema_version\":\"metacodes-install-v1\",\"version\":\"x\",\"state_root\":\"state\"}");
    const relative = try resolveFrom(.{ .exe_path = install.exe, .home = "/home/u" }, &buf);
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_buf, "{s}/state", .{install.root}), relative.path);
    try std.testing.expectEqual(Source.install, relative.source);

    try install.writeManifest("{\"schema_version\":\"metacodes-install-v1\",\"state_root\":\"/srv/mc-a\"}");
    const absolute = try resolveFrom(.{ .exe_path = install.exe, .home = "/home/u" }, &buf);
    try std.testing.expectEqualStrings("/srv/mc-a", absolute.path);
}

test "a broken manifest fails closed instead of falling back to home" {
    if (is_windows) return error.SkipZigTest;
    var install: TestInstall = .{ .tmp = undefined };
    try install.init();
    defer install.tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const inputs: Inputs = .{ .exe_path = install.exe, .home = "/home/u" };
    for ([_][]const u8{
        "not json",
        "{\"schema_version\":\"metacodes-install-v2\",\"state_root\":\"state\"}",
        "{\"schema_version\":\"metacodes-install-v1\",\"state_root\":\"\"}",
        "{\"schema_version\":\"metacodes-install-v1\"}",
    }) |bytes| {
        try install.writeManifest(bytes);
        try std.testing.expectError(error.InstallManifestInvalid, resolveFrom(inputs, &buf));
    }
}

test "flag beats env beats install manifest; both must be absolute" {
    if (is_windows) return error.SkipZigTest;
    var install: TestInstall = .{ .tmp = undefined };
    try install.init();
    defer install.tmp.cleanup();
    try install.writeManifest("{\"schema_version\":\"metacodes-install-v1\",\"state_root\":\"state\"}");
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    const from_env = try resolveFrom(.{ .env = "/env/root", .exe_path = install.exe, .home = "/home/u" }, &buf);
    try std.testing.expectEqualStrings("/env/root", from_env.path);
    try std.testing.expectEqual(Source.env, from_env.source);

    const from_flag = try resolveFrom(.{ .flag = "/flag/root", .env = "/env/root", .exe_path = install.exe }, &buf);
    try std.testing.expectEqualStrings("/flag/root", from_flag.path);
    try std.testing.expectEqual(Source.flag, from_flag.source);

    // An empty variable is unset, not a root.
    const empty_env = try resolveFrom(.{ .env = "", .exe_path = install.exe, .home = "/home/u" }, &buf);
    try std.testing.expectEqual(Source.install, empty_env.source);

    try std.testing.expectError(error.StateRootNotAbsolute, resolveFrom(.{ .env = "rel/root" }, &buf));
    try std.testing.expectError(error.StateRootNotAbsolute, resolveFrom(.{ .flag = "rel/root" }, &buf));
}

test "the resolved root has one spelling: no trailing separator" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/x", (try resolveFrom(.{ .flag = "/x/" }, &buf)).path);
    try std.testing.expectEqualStrings("/x", (try resolveFrom(.{ .env = "/x//" }, &buf)).path);
    try std.testing.expectEqualStrings("/", (try resolveFrom(.{ .env = "/" }, &buf)).path);
    try std.testing.expectEqualStrings("/home/u/.metacodes", (try resolveFrom(.{ .home = "/home/u/" }, &buf)).path);
}

test "prefixOf is the executable's grandparent" {
    try std.testing.expectEqualStrings("/opt/mc", prefixOf("/opt/mc/bin/metacodes").?);
    try std.testing.expectEqual(@as(?[]const u8, null), prefixOf("metacodes"));
}
