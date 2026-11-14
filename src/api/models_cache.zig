//! The route's `/v1/models` answer kept between starts.
//!
//! The answer decides max_tokens, the context window and image input, so the
//! REPL cannot start without one, but waiting for it cost every interactive
//! start a round trip (~0.25 s on the Metask gateway, 2026-10-23). It changes
//! rarely. A start that finds a fresh copy for the same endpoint and
//! credential uses it and refreshes it in the background (`Refresh`); the REPL
//! takes the refreshed answer at its next idle point. A missing, unreadable,
//! foreign or expired copy is a miss: the caller fetches synchronously, as it
//! did before the cache existed, so a cold start sends exactly what it sent.
//!
//! One file per endpoint and credential, `<state root>/cache/models/<key>.json`:
//! `{"schema_version":1,"fetched_at":<unix s>,"base_url":"…","body":"<answer>"}`.
//! The key is a digest of the endpoint and the credential header; the
//! credential itself never reaches the file.

const std = @import("std");
const platform = @import("platform");
const pfs = platform.fs;
const fs_util = @import("../util/fs.zig");
const log = @import("../util/log.zig");
const time = @import("../util/time.zig");
const Catalog = @import("catalog.zig").Catalog;
const client_mod = @import("../client.zig");

pub const SCHEMA_VERSION: u32 = 1;

/// How long a stored answer may answer a start. Each warm start refreshes it,
/// so this bounds only a copy nobody has used for a day.
pub const TTL_SECONDS: i64 = 24 * std.time.s_per_hour;

/// Larger answers are neither read nor written (the probe itself reads at most
/// 1 MiB of body; the envelope escapes it).
pub const MAX_FILE_BYTES: usize = 4 * 1024 * 1024;

/// What a stored answer answers: the endpoint and the credential header the
/// request carried.
pub const Key = struct {
    digest: [16]u8,

    pub fn of(base_url: []const u8, auth: std.http.Header) Key {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(base_url);
        h.update(&.{0});
        h.update(auth.name);
        h.update(&.{0});
        h.update(auth.value);
        var full: [32]u8 = undefined;
        h.final(&full);
        return .{ .digest = full[0..16].* };
    }

    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, &a.digest, &b.digest);
    }
};

/// `<state_root>/cache/models/<hex key>.json`, owned by the caller.
pub fn pathFor(allocator: std.mem.Allocator, state_root: []const u8, key: Key) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/cache/models/{s}.json", .{ state_root, std.fmt.bytesToHex(key.digest, .lower) });
}

const Envelope = struct {
    schema_version: u32,
    fetched_at: i64,
    base_url: []const u8,
    body: []const u8,
};

/// The stored answer for `key`, owned by the caller, when it was fetched from
/// `base_url` at most `ttl` seconds before `now`. Null on any miss.
pub fn load(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    key: Key,
    base_url: []const u8,
    now: i64,
    ttl: i64,
) ?[]u8 {
    if (state_root.len == 0) return null;
    const path = pathFor(allocator, state_root, key) catch return null;
    defer allocator.free(path);
    const bytes = readFile(allocator, path) catch return null;
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Envelope, allocator, bytes, .{ .ignore_unknown_fields = true }) catch {
        log.debug("catalog", "models cache {s} unreadable; fetching", .{path});
        return null;
    };
    defer parsed.deinit();
    const env = parsed.value;
    if (env.schema_version != SCHEMA_VERSION) return null;
    if (!std.mem.eql(u8, env.base_url, base_url)) return null;
    const age = now - env.fetched_at;
    // A copy from the future (clock moved back) is as unknown as an old one.
    if (age < 0 or age > ttl) return null;
    return allocator.dupe(u8, env.body) catch null;
}

/// Store `body` as the answer for `key`. Written to a uniquely named temporary
/// and renamed over the file, so a reader (or another start writing the same
/// answer) never sees half of one.
pub fn store(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    key: Key,
    base_url: []const u8,
    body: []const u8,
    now: i64,
) !void {
    if (state_root.len == 0) return error.NoStateRoot;
    const path = try pathFor(allocator, state_root, key);
    defer allocator.free(path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, Envelope{
        .schema_version = SCHEMA_VERSION,
        .fetched_at = now,
        .base_url = base_url,
        .body = body,
    }, .{});
    defer allocator.free(bytes);
    if (bytes.len > MAX_FILE_BYTES) return error.TooLarge;

    try fs_util.mkdirParents(std.fs.path.dirname(path).?);
    var nonce: [8]u8 = undefined;
    if (!platform.rng.randomBytes(&nonce)) return error.NoRandom;
    const tmp = try std.fmt.allocPrintSentinel(allocator, "{s}.{s}.tmp", .{ path, std.fmt.bytesToHex(nonce, .lower) }, 0);
    defer allocator.free(tmp);
    const final = try allocator.dupeZ(u8, path);
    defer allocator.free(final);

    const fd = pfs.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.OpenFailed;
    var written: usize = 0;
    while (written < bytes.len) {
        const n = pfs.write(fd, bytes[written..]);
        if (n <= 0) {
            pfs.close(fd);
            pfs.unlinkPath(tmp) catch {};
            return error.WriteFailed;
        }
        written += @intCast(n);
    }
    pfs.close(fd); // before the rename (Windows)
    if (pfs.renameReplace(tmp, final) != 0) {
        pfs.unlinkPath(tmp) catch {};
        return error.RenameFailed;
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.NotFound;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n == 0) break;
        if (n < 0) return error.ReadFailed;
        if (out.items.len + @as(usize, @intCast(n)) > MAX_FILE_BYTES) return error.TooLarge;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

/// One background `/v1/models` fetch that replaces a stored answer a warm start
/// used. It runs detached, on copies it owns, `std.heap.c_allocator` and an I/O
/// runtime of its own: the session neither waits for it nor keeps the process
/// alive for it (a fetch stuck in connect must not hold up exit, and the
/// process's own I/O runtime and allocator are torn down when `main` returns).
/// The session and the thread each hold a reference; the last to let go frees it.
pub const Refresh = struct {
    refs: std.atomic.Value(u8) = .init(2),
    state: std.atomic.Value(State) = .init(.running),
    key: Key,
    /// The fetched answer. Written by the thread before it publishes
    /// `.fetched`; the session's from then on (`take`).
    body: ?[]u8 = null,
    messages_url: []u8,
    auth_name: []u8,
    auth_value: []u8,
    state_root: []u8,

    pub const State = enum(u8) { running, fetched, failed };

    const gpa = std.heap.c_allocator;

    /// Start refreshing the answer for `key`, fetched from `messages_url`'s
    /// `/v1/models` with `auth` and stored under `state_root`.
    pub fn start(key: Key, messages_url: []const u8, auth: std.http.Header, state_root: []const u8) !*Refresh {
        const self = try gpa.create(Refresh);
        errdefer gpa.destroy(self);
        self.* = .{
            .key = key,
            .messages_url = try gpa.dupe(u8, messages_url),
            .auth_name = undefined,
            .auth_value = undefined,
            .state_root = undefined,
        };
        errdefer gpa.free(self.messages_url);
        self.auth_name = try gpa.dupe(u8, auth.name);
        errdefer gpa.free(self.auth_name);
        self.auth_value = try gpa.dupe(u8, auth.value);
        errdefer secureFree(self.auth_value);
        self.state_root = try gpa.dupe(u8, state_root);
        errdefer gpa.free(self.state_root);
        const thread = try @import("platform").thread.spawn(.full, run, .{self});
        thread.detach();
        return self;
    }

    pub fn finished(self: *const Refresh) bool {
        return self.state.load(.acquire) != .running;
    }

    /// The fetched answer, owned by the caller (`std.heap.c_allocator`), once;
    /// null while the fetch runs, after it failed, or once taken.
    pub fn take(self: *Refresh) ?[]u8 {
        if (self.state.load(.acquire) != .fetched) return null;
        const body = self.body;
        self.body = null;
        return body;
    }

    /// The session's reference. The thread frees it if it is still running.
    pub fn release(self: *Refresh) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.body) |b| gpa.free(b);
        gpa.free(self.messages_url);
        gpa.free(self.auth_name);
        secureFree(self.auth_value);
        gpa.free(self.state_root);
        gpa.destroy(self);
    }

    fn run(self: *Refresh) void {
        defer self.release();
        const body = self.fetch() catch |err| {
            log.debug("catalog", "background /v1/models refresh failed: {s}", .{@errorName(err)});
            self.state.store(.failed, .release);
            return;
        };
        self.body = body;
        self.state.store(.fetched, .release);
    }

    fn fetch(self: *Refresh) ![]u8 {
        var threaded = platform.signal.threadedIo(gpa, .{});
        defer threaded.deinit();
        var http_client = std.http.Client{ .allocator = gpa, .io = threaded.io() };
        defer http_client.deinit();
        var status: u16 = 0;
        const body = try client_mod.getModelsList(gpa, &http_client, self.messages_url, .{ .header = .{ .name = self.auth_name, .value = self.auth_value } }, &status);
        errdefer gpa.free(body);
        // Only an answer the catalog accepts replaces the stored one.
        var check = Catalog.init(gpa);
        defer check.deinit();
        try check.loadFromModelsListJson(body);
        store(gpa, self.state_root, self.key, self.messages_url, body, time.nowUnix()) catch |err| {
            log.debug("catalog", "models cache not updated: {s}", .{@errorName(err)});
        };
        return body;
    }
};

fn secureFree(buf: []u8) void {
    std.crypto.secureZero(u8, buf);
    std.heap.c_allocator.free(buf);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpRoot(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(testing.io, buf);
    return buf[0..n];
}

fn relPath(buf: []u8, key: Key) []const u8 {
    return std.fmt.bufPrint(buf, "cache/models/{s}.json", .{std.fmt.bytesToHex(key.digest, .lower)}) catch unreachable;
}

const AUTH: std.http.Header = .{ .name = "authorization", .value = "Bearer sk-one" };
const URL = "http://127.0.0.1:9/v1/messages";

test "models cache: a stored answer comes back for the same endpoint and credential while fresh" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const key = Key.of(URL, AUTH);
    try store(testing.allocator, root, key, URL, "{\"data\":[]}", 1000);
    const body = load(testing.allocator, root, key, URL, 1000 + TTL_SECONDS, TTL_SECONDS).?;
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"data\":[]}", body);
}

test "models cache: a miss: expired, from the future, another credential, another endpoint, another schema" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const key = Key.of(URL, AUTH);
    try store(testing.allocator, root, key, URL, "{\"data\":[]}", 1000);
    try testing.expect(load(testing.allocator, root, key, URL, 1001 + TTL_SECONDS, TTL_SECONDS) == null);
    try testing.expect(load(testing.allocator, root, key, URL, 999, TTL_SECONDS) == null);
    const other_key = Key.of(URL, .{ .name = "authorization", .value = "Bearer sk-two" });
    try testing.expect(!other_key.eql(key));
    try testing.expect(load(testing.allocator, root, other_key, URL, 1000, TTL_SECONDS) == null);
    // Same key file, but it names another endpoint (a digest collision would look like this).
    try testing.expect(load(testing.allocator, root, key, "http://other/v1/messages", 1000, TTL_SECONDS) == null);

    var rel_buf: [64]u8 = undefined;
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = relPath(&rel_buf, key),
        .data = "{\"schema_version\":2,\"fetched_at\":1000,\"base_url\":\"" ++ URL ++ "\",\"body\":\"{}\"}",
    });
    try testing.expect(load(testing.allocator, root, key, URL, 1000, TTL_SECONDS) == null);
}

test "models cache: the file never holds the credential" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const key = Key.of(URL, AUTH);
    try store(testing.allocator, root, key, URL, "{\"data\":[]}", 1000);
    const path = try pathFor(testing.allocator, root, key);
    defer testing.allocator.free(path);
    const bytes = try readFile(testing.allocator, path);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "sk-one") == null);
    try testing.expect(std.mem.indexOf(u8, path, "sk-one") == null);
}

test "models cache: a corrupt file is a miss, and the next store replaces it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const key = Key.of(URL, AUTH);
    try store(testing.allocator, root, key, URL, "{\"data\":[]}", 1000);
    var rel_buf: [64]u8 = undefined;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = relPath(&rel_buf, key), .data = "{\"schema_version\":1,\"fetch" });
    try testing.expect(load(testing.allocator, root, key, URL, 1000, TTL_SECONDS) == null);
    try store(testing.allocator, root, key, URL, "{\"data\":[1]}", 1000);
    const body = load(testing.allocator, root, key, URL, 1000, TTL_SECONDS).?;
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"data\":[1]}", body);
}
