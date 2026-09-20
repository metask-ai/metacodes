//! `metacodes kg install`: provision the local TinyKG runtime.
//!
//! Until now `~/.metacodes/kg/daemon.json` had to be written by hand, with a
//! build id copied from a running service, which is why every session on this
//! machine had been silently degraded. This creates the store, generates the
//! key, computes the build id from the staged executables, and writes the
//! configuration the client already knows how to read. It starts nothing: the
//! daemon runs under `metacodes kgd`.
//!
//! The configuration is also what tells `metacodes kgd` which Store to serve,
//! so `--store` is recorded rather than remembered by the operator. `--config`
//! writes somewhere else entirely, which is how one machine runs an isolated
//! second world (a scratch store on another port) without touching the default.

const std = @import("std");
const pfs = @import("platform").fs;
const rng = @import("platform").rng;
const util_fs = @import("../../util/fs.zig");
const common = @import("../../tools/common.zig");
const identity_mod = @import("identity.zig");
const KgClient = @import("../client.zig").KgClient;

pub const DEFAULT_PORT: u16 = 8799;
pub const STORE_NAME = "store.kg.v2";
const STORE_INIT_TIMEOUT_MS = 60_000;
const API_KEY_BYTES = 32;

pub const Error = error{
    NoHome,
    BinariesMissing,
    ConfigDirUnusable,
    ConfigUnsafe,
    StoreInitFailed,
    IdentityUnavailable,
    KeyGenerationFailed,
    ConfigWriteFailed,
    OutOfMemory,
};

pub const Options = struct {
    /// Defaults to `<home>/.metacodes/kg/daemon.json`, or `METACODES_KG_CONFIG`
    /// when that is set, so install and the sessions always agree.
    config_path: ?[]const u8 = null,
    /// Defaults to the store beside the configuration.
    store_path: ?[]const u8 = null,
    /// Null keeps the port an existing configuration already uses, so a
    /// reinstall does not silently move the service away from its clients.
    port: ?u16 = null,
};

pub const Outcome = struct {
    config_path: []u8,
    store_path: []u8,
    url: []u8,
    build_id: [71]u8,
    /// True when an existing configuration's key was kept, so sessions that
    /// already hold it keep working across a reinstall.
    reused_api_key: bool,
    created_store: bool,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.store_path);
        allocator.free(self.url);
    }
};

pub fn run(allocator: std.mem.Allocator, home: []const u8, options: Options) Error!Outcome {
    if (home.len == 0 and options.config_path == null) return Error.NoHome;

    var cli = (KgClient.resolveTinykgBinary(allocator, .{ .home = home, .domain = "" }) catch null) orelse
        return Error.BinariesMissing;
    defer cli.deinit(allocator);
    var daemon = (KgClient.resolveTinykgdBinary(allocator, .{ .home = home, .domain = "" }) catch null) orelse
        return Error.BinariesMissing;
    defer daemon.deinit(allocator);

    const config_path = if (options.config_path) |given|
        allocator.dupe(u8, given) catch return Error.OutOfMemory
    else
        KgClient.resolveDaemonConfigPath(allocator, home) catch return Error.OutOfMemory;
    errdefer allocator.free(config_path);
    const config_dir = std.fs.path.dirname(config_path) orelse return Error.ConfigDirUnusable;
    const dir_existed = directoryExists(allocator, config_dir);
    util_fs.mkdirParents(config_dir) catch return Error.ConfigDirUnusable;
    // Owner-only, but only for a directory this command created. `--config`
    // can name a path anywhere, and tightening a directory the operator
    // already had — `/tmp`, a home, a system path under root — is not this
    // command's business. The file itself is 0600 either way.
    if (!dir_existed) restrictDirectory(allocator, config_dir) catch return Error.ConfigDirUnusable;

    // An existing configuration is read exactly as a session reads it. A file
    // this service would refuse to serve from must not be a source of settings
    // either, and in particular its key must not be adopted.
    var existing: ?KgClient.ParsedDaemonFile = KgClient.loadDaemonConfig(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => null,
        error.ConfigUnsafe => return Error.ConfigUnsafe,
        else => null,
    };
    defer if (existing) |*parsed| parsed.deinit();

    const store_path = try resolveStorePath(allocator, config_dir, options, existing);
    errdefer allocator.free(store_path);
    const created_store = try ensureStore(allocator, cli.path, store_path);

    var identity = identity_mod.discover(allocator, cli.path, daemon.path) catch
        return Error.IdentityUnavailable;
    defer identity.deinit();

    var key_buffer: [API_KEY_BYTES * 2]u8 = undefined;
    const reused = reuseApiKey(existing, &key_buffer);
    if (!reused) try generateApiKey(&key_buffer);

    const port = options.port orelse portOfExisting(existing) orelse DEFAULT_PORT;
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}) catch
        return Error.OutOfMemory;
    errdefer allocator.free(url);

    try writeConfig(allocator, config_path, url, key_buffer[0..], identity.buildId(), store_path);
    return .{
        .config_path = config_path,
        .store_path = store_path,
        .url = url,
        .build_id = identity.build_id,
        .reused_api_key = reused,
        .created_store = created_store,
    };
}

/// Explicit flag, else what the configuration already serves, else beside it.
/// Always absolute: the recorded path is read back by a service started from
/// another working directory, where a relative path would name a different
/// store — silently, and with `tinykg init` ready to create it.
fn resolveStorePath(
    allocator: std.mem.Allocator,
    config_dir: []const u8,
    options: Options,
    existing: ?KgClient.ParsedDaemonFile,
) Error![]u8 {
    if (options.store_path) |given| return absolutize(allocator, config_dir, given);
    if (existing) |parsed| {
        if (parsed.value.store) |recorded| {
            if (recorded.len > 0) return absolutize(allocator, config_dir, recorded);
        }
    }
    // The default sits beside the configuration, and only then is made
    // absolute. Absolutizing the bare name instead would resolve it against
    // the working directory — a store in whatever folder the operator happened
    // to be standing in, which is not what "beside the configuration" means.
    const beside = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_dir, STORE_NAME }) catch
        return Error.OutOfMemory;
    defer allocator.free(beside);
    return absolutize(allocator, config_dir, beside);
}

/// A relative path is taken as relative to the working directory the operator
/// typed it in, which is what `--store build/scratch.kg` means to them. The
/// result is always absolute: a relative string in the file would be read back
/// by a service started from somewhere else, and `runtime` would then resolve
/// it against the configuration directory instead — two readings of one value.
fn absolutize(allocator: std.mem.Allocator, config_dir: []const u8, path: []const u8) Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path) catch Error.OutOfMemory;
    const cwd = @import("../../util/fs.zig").getCwd(allocator) catch {
        // No working directory to resolve against. The configuration directory
        // only helps if it is itself absolute; otherwise refuse rather than
        // record something whose meaning depends on where it is read.
        if (!std.fs.path.isAbsolute(config_dir)) return Error.StoreInitFailed;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_dir, path }) catch Error.OutOfMemory;
    };
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path }) catch Error.OutOfMemory;
}

fn directoryExists(allocator: std.mem.Allocator, path: []const u8) bool {
    const path_z = allocator.dupeZ(u8, path) catch return true; // fail safe: do not chmod
    defer allocator.free(path_z);
    return pfs.exists(path_z.ptr);
}

fn portOfExisting(existing: ?KgClient.ParsedDaemonFile) ?u16 {
    const parsed = existing orelse return null;
    const port = portOfUrl(parsed.value.url) orelse return null;
    // Zero is not a port the service can be started from, so preserving it
    // would turn one unusable configuration into another.
    return if (port == 0) null else port;
}

/// The port a configured URL names. Shared with the runtime's own parsing so a
/// reinstall cannot read the port differently from the service that binds it.
pub fn portOfUrl(url: []const u8) ?u16 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const authority_start = scheme_end + 3;
    if (authority_start >= url.len) return null;
    const rest = url[authority_start..];
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return null;
    return std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch null;
}

fn ensureStore(allocator: std.mem.Allocator, cli_path: []const u8, store_path: []const u8) Error!bool {
    const store_z = allocator.dupeZ(u8, store_path) catch return Error.OutOfMemory;
    defer allocator.free(store_z);
    if (pfs.exists(store_z.ptr)) return false;
    if (std.fs.path.dirname(store_path)) |parent| {
        util_fs.mkdirParents(parent) catch return Error.StoreInitFailed;
    }
    const cli_z = allocator.dupeZ(u8, cli_path) catch return Error.OutOfMemory;
    defer allocator.free(cli_z);
    const argv = [_]?[*:0]const u8{ cli_z.ptr, "init", store_z.ptr, null };
    const stdout = common.spawnCaptureStdoutAbortableTimed(&argv, allocator, null, STORE_INIT_TIMEOUT_MS) catch
        return Error.StoreInitFailed;
    allocator.free(stdout);
    if (!pfs.exists(store_z.ptr)) return Error.StoreInitFailed;
    return true;
}

/// Keeping the key across reinstalls is the difference between reconfiguring
/// and locking out every session that already read it.
fn reuseApiKey(existing: ?KgClient.ParsedDaemonFile, out: *[API_KEY_BYTES * 2]u8) bool {
    const parsed = existing orelse return false;
    const key = parsed.value.api_key;
    if (key.len != out.len) return false;
    for (key) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    @memcpy(out, key);
    return true;
}

fn generateApiKey(out: *[API_KEY_BYTES * 2]u8) Error!void {
    var raw: [API_KEY_BYTES]u8 = undefined;
    if (!rng.randomBytes(&raw)) return Error.KeyGenerationFailed;
    _ = std.fmt.bufPrint(out, "{x}", .{&raw}) catch return Error.KeyGenerationFailed;
}

/// Written through a private temporary so a reader never sees a half file, and
/// created 0600 from the start so the key is never briefly world-readable.
fn writeConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    url: []const u8,
    api_key: []const u8,
    build_id: []const u8,
    store_path: []const u8,
) Error!void {
    var document: std.Io.Writer.Allocating = .init(allocator);
    defer document.deinit();
    std.json.Stringify.value(.{
        .url = url,
        .api_key = api_key,
        .expected_build_id = build_id,
        .store = store_path,
    }, .{ .whitespace = .indent_2 }, &document.writer) catch return Error.OutOfMemory;
    document.writer.writeByte('\n') catch return Error.OutOfMemory;

    // `--config` can name a path in a shared directory, so the temporary must
    // be unguessable and must refuse to open anything that already exists:
    // a planted `<path>.tmp -> /somewhere/else` symlink would otherwise receive
    // this machine's API key, written with the privileges of whoever ran this.
    var suffix: [8]u8 = undefined;
    if (!rng.randomBytes(&suffix)) return Error.KeyGenerationFailed;
    var suffix_hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&suffix_hex, "{x}", .{&suffix}) catch return Error.ConfigWriteFailed;
    const temporary = std.fmt.allocPrintSentinel(allocator, "{s}.{s}.tmp", .{ config_path, suffix_hex }, 0) catch
        return Error.OutOfMemory;
    defer allocator.free(temporary);
    const fd = pfs.open(
        temporary.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true },
        0o600,
    );
    if (fd < 0) return Error.ConfigWriteFailed;
    // From here the temporary exists and holds the API key: every failure path
    // out of this function must take it with them, including the allocation
    // below, which is easy to forget precisely because it looks unrelated.
    errdefer _ = std.c.unlink(temporary.ptr);
    const body = document.written();
    var written: usize = 0;
    while (written < body.len) {
        const n = pfs.write(fd, body[written..]);
        if (n <= 0) {
            _ = pfs.close(fd);
            return Error.ConfigWriteFailed;
        }
        written += @intCast(n);
    }
    _ = pfs.close(fd);
    const final = allocator.dupeZ(u8, config_path) catch return Error.OutOfMemory;
    defer allocator.free(final);
    if (pfs.renameReplace(temporary.ptr, final.ptr) != 0) return Error.ConfigWriteFailed;
}

fn restrictDirectory(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (@import("builtin").os.tag == .windows) return;
    if (std.c.chmod(path_z.ptr, 0o700) != 0) return error.ChmodFailed;
}

const testing = std.testing;

test "KgdInstall: a generated key is 64 lowercase hex characters" {
    var key: [API_KEY_BYTES * 2]u8 = undefined;
    try generateApiKey(&key);
    try testing.expectEqual(@as(usize, 64), key.len);
    for (key) |byte| try testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));
    var again: [API_KEY_BYTES * 2]u8 = undefined;
    try generateApiKey(&again);
    try testing.expect(!std.mem.eql(u8, &key, &again));
}

test "KgdInstall: the configuration carries the store the service must serve" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const path = try std.fmt.allocPrint(a, "{s}/daemon.json", .{root});
    defer a.free(path);

    const key = "a" ** 64;
    try writeConfig(a, path, "http://127.0.0.1:8799", key, "sha256:" ++ ("b" ** 64), "/tmp/store-b");

    // The client parses with `ignore_unknown_fields = false`, so every field
    // written here must be one it declares, and no field may be missing.
    var parsed = try KgClient.loadDaemonConfig(a, path);
    defer parsed.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:8799", parsed.value.url);
    try testing.expectEqualStrings(key, parsed.value.api_key);
    try testing.expectEqualStrings("/tmp/store-b", parsed.value.store.?);
    try testing.expect(std.mem.startsWith(u8, parsed.value.expected_build_id.?, "sha256:"));

    // 0600: the file holds a credential, and the client refuses anything looser.
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    try testing.expect(fd >= 0);
    defer _ = pfs.close(fd);
    const info = try pfs.fileInfo(fd);
    try testing.expectEqual(@as(u32, 0), info.mode & 0o077);

    // A reinstall keeps the key, the port and the store, so it reconfigures
    // rather than moving the service away from the sessions that use it.
    var key_out: [64]u8 = undefined;
    try testing.expect(reuseApiKey(parsed, &key_out));
    try testing.expectEqualStrings(key, &key_out);
    try testing.expectEqual(@as(?u16, 8799), portOfExisting(parsed));
    const store = try resolveStorePath(a, root, .{}, parsed);
    defer a.free(store);
    try testing.expectEqualStrings("/tmp/store-b", store);
    // An explicit flag still wins over what the file records.
    const overridden = try resolveStorePath(a, root, .{ .store_path = "/tmp/other" }, parsed);
    defer a.free(overridden);
    try testing.expectEqualStrings("/tmp/other", overridden);
}

test "KgdInstall: a key from a configuration the client would refuse is not adopted" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const path = try std.fmt.allocPrint(a, "{s}/daemon.json", .{root});
    defer a.free(path);

    // World-readable: a local attacker could have planted both the file and the
    // key in it. `run` turns this into ConfigUnsafe rather than adopting it.
    try writeRaw(a, path, "{\"url\":\"http://127.0.0.1:8799\",\"api_key\":\"" ++ ("a" ** 64) ++ "\"}", 0o644);
    try testing.expectError(error.ConfigUnsafe, KgClient.loadDaemonConfig(a, path));

    // Malformed keys in an otherwise readable file are regenerated, not reused.
    var key: [64]u8 = undefined;
    const build = "\"expected_build_id\":\"sha256:" ++ ("b" ** 64) ++ "\"";
    for ([_][]const u8{
        "{\"url\":\"http://127.0.0.1:1\"," ++ build ++ ",\"api_key\":\"short\"}",
        "{\"url\":\"http://127.0.0.1:1\"," ++ build ++ ",\"api_key\":\"" ++ ("A" ** 64) ++ "\"}",
        "{\"url\":\"http://127.0.0.1:1\"," ++ build ++ ",\"api_key\":\"" ++ ("a" ** 63) ++ "\"}",
    }) |document| {
        try writeRaw(a, path, document, 0o600);
        var parsed = try KgClient.loadDaemonConfig(a, path);
        defer parsed.deinit();
        try testing.expect(!reuseApiKey(parsed, &key));
    }
}

test "KgdInstall: the temporary configuration cannot be a planted symlink" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const config = try std.fmt.allocPrint(a, "{s}/daemon.json", .{root});
    defer a.free(config);
    const victim = try std.fmt.allocPrint(a, "{s}/victim", .{root});
    defer a.free(victim);

    // The old name was `<config>.tmp`, which anyone with write access to the
    // directory could pre-create as a link to a file of their choosing.
    const guessed = try std.fmt.allocPrintSentinel(a, "{s}.tmp", .{config}, 0);
    defer a.free(guessed);
    const victim_z = try a.dupeZ(u8, victim);
    defer a.free(victim_z);
    try writeRaw(a, victim, "untouched", 0o600);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(victim_z.ptr, guessed.ptr));

    try writeConfig(a, config, "http://127.0.0.1:8799", "a" ** 64, "sha256:" ++ ("b" ** 64), "/tmp/s");

    // The key went to the configuration, and the planted link still points at
    // a file nobody wrote through.
    const written = @import("../../swarm/team.zig").readFileAlloc(a, victim).?;
    defer a.free(written);
    try testing.expectEqualStrings("untouched", written);
    var parsed = try KgClient.loadDaemonConfig(a, config);
    defer parsed.deinit();
    try testing.expectEqualStrings("a" ** 64, parsed.value.api_key);
}

test "KgdInstall: an unusable port is not preserved across a reinstall" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const path = try std.fmt.allocPrint(a, "{s}/daemon.json", .{root});
    defer a.free(path);
    // A configuration naming port 0 is one `kgd` refuses to start from;
    // carrying it forward would just produce a second unusable file.
    try writeRaw(a, path, "{\"url\":\"http://127.0.0.1:0\",\"expected_build_id\":\"sha256:" ++ ("b" ** 64) ++ "\",\"api_key\":\"" ++ ("a" ** 64) ++ "\"}", 0o600);
    var parsed = try KgClient.loadDaemonConfig(a, path);
    defer parsed.deinit();
    try testing.expect(portOfExisting(parsed) == null);
}

test "KgdInstall: every recorded store path is absolute" {
    const a = testing.allocator;
    // Relative here would be read back by a service started elsewhere, and
    // `runtime` would resolve it against the configuration directory a second
    // time — `cfg/cfg/store.kg.v2` for a relative `--config cfg/daemon.json`.
    const absolute = try resolveStorePath(a, "/home/x/.metacodes/kg", .{ .store_path = "/tmp/explicit" }, null);
    defer a.free(absolute);
    try testing.expectEqualStrings("/tmp/explicit", absolute);

    const relative_flag = try resolveStorePath(a, "/home/x/.metacodes/kg", .{ .store_path = "scratch.kg" }, null);
    defer a.free(relative_flag);
    try testing.expect(std.fs.path.isAbsolute(relative_flag));
    try testing.expect(std.mem.endsWith(u8, relative_flag, "/scratch.kg"));

    // The default, with a relative configuration directory: the case a first
    // `kg install --config cfg/daemon.json` takes.
    const defaulted = try resolveStorePath(a, "cfg", .{}, null);
    defer a.free(defaulted);
    try testing.expect(std.fs.path.isAbsolute(defaulted));
    try testing.expect(std.mem.endsWith(u8, defaulted, "/cfg/" ++ STORE_NAME));

    // And with an absolute one it stays beside the configuration rather than
    // landing in whatever directory the command was run from.
    const beside = try resolveStorePath(a, "/home/x/.metacodes/kg", .{}, null);
    defer a.free(beside);
    try testing.expectEqualStrings("/home/x/.metacodes/kg/" ++ STORE_NAME, beside);
}

test "KgdInstall: the port is read back the same way the service binds it" {
    try testing.expectEqual(@as(?u16, 8799), portOfUrl("http://127.0.0.1:8799"));
    try testing.expectEqual(@as(?u16, 8080), portOfUrl("http://127.0.0.1:8080/api/run"));
    try testing.expect(portOfUrl("http://127.0.0.1") == null);
    try testing.expect(portOfUrl("127.0.0.1:8799") == null);
    try testing.expect(portOfUrl("http://127.0.0.1:not-a-port") == null);
    try testing.expect(portOfUrl("") == null);
}

fn writeRaw(allocator: std.mem.Allocator, path: []const u8, body: []const u8, mode: u16) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.WriteFailed;
    if (pfs.write(fd, body) != @as(isize, @intCast(body.len))) {
        _ = pfs.close(fd);
        return error.WriteFailed;
    }
    _ = pfs.close(fd);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}
