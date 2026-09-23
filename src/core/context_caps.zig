//! Learned context caps: what each (endpoint, model) pair actually accepts.
//!
//! The catalog's `max_input_tokens` is a claim; the wall is wherever the
//! server starts rejecting. The two disagreed by ~34K tokens on the Metask
//! glm-5.3-flash route (2026-09-22): every auto-compact threshold sat above
//! the real wall, so summary compaction never fired and the loop pinned the
//! session at the edge, shaving two messages per turn. This registry turns
//! each rejection into a measurement and keeps it across sessions, so the
//! threshold lands inside the wall from the first turn next time.
//!
//! Provider-neutral by construction (see the "supports every model" rule):
//!   - a rejection that carries numbers (`error_class.ContextWindowNumbers`)
//!     records the server's own limit (`.server_message`);
//!   - a rejection without numbers records the last size the server accepted
//!     (`.observed`) — a lower bound on the wall that any backend provides;
//!   - a later accepted prompt larger than the cap either invalidates a stale
//!     server claim or raises an observed bound; nothing here assumes how a
//!     provider counts or whether it reports usage at all.
//!
//! Keys: endpoint (base URL) + model, model compared case-insensitively. The
//! same model behind two gateways is two walls.
//!
//! Persistence: `$HOME/.metacodes/context_caps.json` (override with
//! `METACODES_CONTEXT_CAPS_FILE`; set it empty to disable). Test builds never
//! touch the home directory unless a test opts in via `setPersistPathForTest`.
//! Writes are whole-file, temp + rename. A file that cannot be read or written
//! degrades to an in-memory registry; it never fails a request.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("platform").sync;
const pfs = @import("platform").fs;
const paths = @import("platform").paths;
const util_json = @import("../util/json.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const model_name = @import("../api/model_name.zig");

pub const SCHEMA = "metacodes.context-caps/v1";
pub const ENV_FILE = "METACODES_CONTEXT_CAPS_FILE";

pub const Source = enum {
    /// The server stated its limit in the rejection body.
    server_message,
    /// Derived from sizes the server accepted; a lower bound on the wall.
    observed,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .server_message => "server_message",
            .observed => "observed",
        };
    }

    fn parse(text: []const u8) ?Source {
        if (std.mem.eql(u8, text, "server_message")) return .server_message;
        if (std.mem.eql(u8, text, "observed")) return .observed;
        return null;
    }
};

pub const LearnOutcome = enum { inserted, replaced, tightened, unchanged, rejected_key };
pub const AcceptOutcome = enum { none, raised, invalidated };

pub const Snapshot = struct {
    input_cap: u64,
    source: Source,
    learned_at_ms: i64,
};

const MAX_ENTRIES = 32;
const MAX_ENDPOINT = 256;
const MAX_MODEL = 128;
const MAX_FILE_BYTES = 256 * 1024;

const Entry = struct {
    endpoint_buf: [MAX_ENDPOINT]u8 = undefined,
    endpoint_len: usize = 0,
    model_buf: [MAX_MODEL]u8 = undefined,
    model_len: usize = 0,
    input_cap: u64 = 0,
    source: Source = .observed,
    learned_at_ms: i64 = 0,

    fn endpoint(self: *const Entry) []const u8 {
        return self.endpoint_buf[0..self.endpoint_len];
    }
    fn model(self: *const Entry) []const u8 {
        return self.model_buf[0..self.model_len];
    }
    fn matches(self: *const Entry, ep: []const u8, m: []const u8) bool {
        return std.mem.eql(u8, self.endpoint(), ep) and model_name.eqlIgnoreCase(self.model(), m);
    }
};

var mutex: sync.Mutex = .{};
var entries: [MAX_ENTRIES]Entry = undefined;
var count: usize = 0;
var loaded: bool = false;
/// null = persistence disabled. Owned static buffer; set once at load.
var persist_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var persist_path_len: usize = 0;
var persist_enabled: bool = false;
var test_path_override: ?[]const u8 = null;

fn lock() void {
    _ = mutex.lock();
}
fn unlock() void {
    _ = mutex.unlock();
}

/// The cap learned for this endpoint+model, if any.
pub fn learnedInputCap(endpoint: []const u8, model: []const u8) ?u64 {
    const snap = lookup(endpoint, model) orelse return null;
    return snap.input_cap;
}

pub fn lookup(endpoint: []const u8, model: []const u8) ?Snapshot {
    lock();
    defer unlock();
    ensureLoadedLocked();
    const e = findLocked(endpoint, model) orelse return null;
    return .{ .input_cap = e.input_cap, .source = e.source, .learned_at_ms = e.learned_at_ms };
}

/// Record a measurement taken from a rejection.
///   - `.server_message` is authoritative: it replaces whatever was known,
///     upward or downward (a gateway may have raised its limit);
///   - `.observed` only ever tightens. A rejection is evidence that the wall
///     is at or below what was just sent, so an observed bound below an older
///     server statement wins too: compacting a little early is cheap, hitting
///     the wall again is not. A later accepted prompt raises it back (see
///     `noteAccepted`).
pub fn learnInputCap(endpoint: []const u8, model: []const u8, cap: u64, source: Source) LearnOutcome {
    if (cap == 0) return .unchanged;
    lock();
    defer unlock();
    ensureLoadedLocked();
    const now_ms = nowMs();
    if (findLocked(endpoint, model)) |e| {
        const outcome: LearnOutcome = switch (source) {
            .server_message => if (e.input_cap == cap and e.source == .server_message) .unchanged else .replaced,
            .observed => if (cap < e.input_cap) .tightened else .unchanged,
        };
        if (outcome == .unchanged) return .unchanged;
        e.input_cap = cap;
        e.source = source;
        e.learned_at_ms = now_ms;
        saveLocked();
        return outcome;
    }
    const slot = allocateLocked(endpoint, model) orelse return .rejected_key;
    slot.input_cap = cap;
    slot.source = source;
    slot.learned_at_ms = now_ms;
    saveLocked();
    return .inserted;
}

/// The server accepted a prompt of `prompt_tokens`. A stated limit below that
/// size was wrong (or has since been raised): forget it and let the catalog
/// take over until the next rejection re-learns. An observed bound below it is
/// simply raised; it was only ever a lower bound.
pub fn noteAccepted(endpoint: []const u8, model: []const u8, prompt_tokens: u64) AcceptOutcome {
    if (prompt_tokens == 0) return .none;
    lock();
    defer unlock();
    ensureLoadedLocked();
    const e = findLocked(endpoint, model) orelse return .none;
    if (prompt_tokens <= e.input_cap) return .none;
    switch (e.source) {
        .server_message => {
            removeLocked(e);
            saveLocked();
            return .invalidated;
        },
        .observed => {
            e.input_cap = prompt_tokens;
            e.learned_at_ms = nowMs();
            saveLocked();
            return .raised;
        },
    }
}

/// Test hook: empty the registry and disable persistence until
/// `setPersistPathForTest` opts back in. Restores the same state on exit.
pub fn resetForTest() void {
    lock();
    defer unlock();
    count = 0;
    loaded = true;
    persist_enabled = false;
    persist_path_len = 0;
    test_path_override = null;
}

/// Test hook: persist to `path` (null disables) and reload from it.
pub fn setPersistPathForTest(path: ?[]const u8) void {
    lock();
    defer unlock();
    count = 0;
    loaded = false;
    test_path_override = path;
    ensureLoadedLocked();
}

// ── internals (all callers hold the lock) ──────────────────────────────────

fn nowMs() i64 {
    const ns = util_time.nowWallNs();
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn findLocked(endpoint: []const u8, model: []const u8) ?*Entry {
    for (entries[0..count]) |*e| {
        if (e.matches(endpoint, model)) return e;
    }
    return null;
}

fn removeLocked(e: *Entry) void {
    const idx = (@intFromPtr(e) - @intFromPtr(&entries[0])) / @sizeOf(Entry);
    std.debug.assert(idx < count);
    var i = idx;
    while (i + 1 < count) : (i += 1) entries[i] = entries[i + 1];
    count -= 1;
}

fn allocateLocked(endpoint: []const u8, model: []const u8) ?*Entry {
    if (endpoint.len > MAX_ENDPOINT or model.len > MAX_MODEL or model.len == 0) return null;
    if (count == MAX_ENTRIES) {
        // Evict the oldest measurement; a registry this full is a fleet of
        // gateways, and the stalest entry is the least likely to be used.
        var oldest: usize = 0;
        for (entries[0..count], 0..) |e, i| {
            if (e.learned_at_ms < entries[oldest].learned_at_ms) oldest = i;
        }
        removeLocked(&entries[oldest]);
    }
    const slot = &entries[count];
    slot.* = .{};
    @memcpy(slot.endpoint_buf[0..endpoint.len], endpoint);
    slot.endpoint_len = endpoint.len;
    @memcpy(slot.model_buf[0..model.len], model);
    slot.model_len = model.len;
    count += 1;
    return slot;
}

fn resolvePersistPathLocked() void {
    persist_enabled = false;
    persist_path_len = 0;
    if (test_path_override) |p| {
        if (p.len == 0 or p.len >= persist_path_buf.len) return;
        @memcpy(persist_path_buf[0..p.len], p);
        persist_path_len = p.len;
        persist_enabled = true;
        return;
    }
    if (builtin.is_test) return;
    if (std.c.getenv(ENV_FILE)) |raw| {
        const p = std.mem.span(raw);
        if (p.len == 0 or p.len >= persist_path_buf.len) return; // empty = explicitly disabled
        @memcpy(persist_path_buf[0..p.len], p);
        persist_path_len = p.len;
        persist_enabled = true;
        return;
    }
    const home = paths.homeDir() orelse return;
    const written = std.fmt.bufPrint(&persist_path_buf, "{s}/.metacodes/context_caps.json", .{home}) catch return;
    persist_path_len = written.len;
    persist_enabled = true;
}

fn ensureLoadedLocked() void {
    if (loaded) return;
    loaded = true;
    count = 0;
    resolvePersistPathLocked();
    if (!persist_enabled) return;
    loadLocked() catch |err| {
        log.debug("context_caps", "load {s} failed: {s} (starting empty)", .{ persist_path_buf[0..persist_path_len], @errorName(err) });
    };
}

fn loadLocked() !void {
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const p = persist_path_buf[0..persist_path_len];
    @memcpy(path_z[0..p.len], p);
    path_z[p.len] = 0;
    const fd = pfs.openZ(path_z[0..p.len :0], .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer pfs.close(fd);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try pfs.readZ(fd, &buf);
        if (n == 0) break;
        if (text.items.len + n > MAX_FILE_BYTES) return error.TooLarge;
        try text.appendSlice(a, buf[0..n]);
    }
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text.items, .{}) catch return error.Malformed;
    if (root != .object) return error.Malformed;
    const schema = root.object.get("schema") orelse return error.Malformed;
    if (schema != .string or !std.mem.eql(u8, schema.string, SCHEMA)) return error.SchemaMismatch;
    const list = root.object.get("entries") orelse return;
    if (list != .array) return error.Malformed;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const endpoint = stringOf(item.object.get("endpoint")) orelse continue;
        const model = stringOf(item.object.get("model")) orelse continue;
        const cap = uintOf(item.object.get("input_cap")) orelse continue;
        const source = Source.parse(stringOf(item.object.get("source")) orelse "") orelse continue;
        const at = intOf(item.object.get("learned_at_ms")) orelse 0;
        if (cap == 0) continue;
        const slot = allocateLocked(endpoint, model) orelse continue;
        slot.input_cap = cap;
        slot.source = source;
        slot.learned_at_ms = at;
    }
}

fn saveLocked() void {
    if (!persist_enabled) return;
    saveLockedInner() catch |err| {
        log.debug("context_caps", "save {s} failed: {s}", .{ persist_path_buf[0..persist_path_len], @errorName(err) });
    };
}

fn saveLockedInner() !void {
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    try aw.writer.print("{{\"schema\":\"{s}\",\"entries\":[", .{SCHEMA});
    for (entries[0..count], 0..) |e, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll("{\"endpoint\":");
        try util_json.writeJsonString(&aw.writer, e.endpoint());
        try aw.writer.writeAll(",\"model\":");
        try util_json.writeJsonString(&aw.writer, e.model());
        try aw.writer.print(",\"input_cap\":{d},\"source\":\"{s}\",\"learned_at_ms\":{d}}}", .{ e.input_cap, e.source.label(), e.learned_at_ms });
    }
    try aw.writer.writeAll("]}\n");

    const p = persist_path_buf[0..persist_path_len];
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_z[0..p.len], p);
    path_z[p.len] = 0;
    var tmp_z: [std.fs.max_path_bytes + 8]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_z, "{s}.tmp\x00", .{p});
    // Best effort: the parent usually exists (transcripts live beside it).
    if (std.mem.lastIndexOfAny(u8, p, "/\\")) |slash| {
        var dir_z: [std.fs.max_path_bytes + 1]u8 = undefined;
        @memcpy(dir_z[0..slash], p[0..slash]);
        dir_z[slash] = 0;
        _ = pfs.mkdir(dir_z[0..slash :0], 0o700);
    }
    const fd = pfs.open(tmp_z[0 .. tmp.len - 1 :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.OpenFailed;
    var written: usize = 0;
    const bytes = aw.writer.buffered();
    while (written < bytes.len) {
        const n = pfs.write(fd, bytes[written..]);
        if (n <= 0) {
            pfs.close(fd);
            return error.WriteFailed;
        }
        written += @intCast(n);
    }
    pfs.close(fd);
    if (pfs.renameReplace(tmp_z[0 .. tmp.len - 1 :0], path_z[0..p.len :0]) != 0) return error.RenameFailed;
}

fn stringOf(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}
fn uintOf(v: ?std.json.Value) ?u64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}
fn intOf(v: ?std.json.Value) ?i64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

// ── tests ─────────────────────────────────────────────────────────────────

test "context caps: server statement replaces, observation only tightens" {
    resetForTest();
    defer resetForTest();
    try std.testing.expectEqual(@as(?u64, null), learnedInputCap("https://a", "m"));
    try std.testing.expectEqual(LearnOutcome.inserted, learnInputCap("https://a", "m", 900_000, .observed));
    try std.testing.expectEqual(LearnOutcome.unchanged, learnInputCap("https://a", "m", 950_000, .observed));
    try std.testing.expectEqual(LearnOutcome.tightened, learnInputCap("https://a", "M", 880_000, .observed));
    try std.testing.expectEqual(@as(?u64, 880_000), learnedInputCap("https://a", "m"));
    // A stated limit wins in either direction.
    try std.testing.expectEqual(LearnOutcome.replaced, learnInputCap("https://a", "m", 883_000, .server_message));
    try std.testing.expectEqual(LearnOutcome.unchanged, learnInputCap("https://a", "m", 883_000, .server_message));
    try std.testing.expectEqual(LearnOutcome.unchanged, learnInputCap("https://a", "m", 890_000, .observed));
    try std.testing.expectEqual(@as(?u64, 883_000), learnedInputCap("https://a", "m"));
    // A rejection observed below the statement tightens it: being rejected is
    // stronger evidence than a claim.
    try std.testing.expectEqual(LearnOutcome.tightened, learnInputCap("https://a", "m", 870_000, .observed));
    try std.testing.expectEqual(@as(?u64, 870_000), learnedInputCap("https://a", "m"));
    try std.testing.expectEqual(Source.observed, lookup("https://a", "m").?.source);
    // Different endpoint, same model: a different wall.
    try std.testing.expectEqual(@as(?u64, null), learnedInputCap("https://b", "m"));
    try std.testing.expectEqual(LearnOutcome.unchanged, learnInputCap("https://a", "m", 0, .server_message));
}

test "context caps: an accepted prompt above the cap invalidates a claim and raises a bound" {
    resetForTest();
    defer resetForTest();
    _ = learnInputCap("e", "m", 100_000, .server_message);
    try std.testing.expectEqual(AcceptOutcome.none, noteAccepted("e", "m", 100_000));
    try std.testing.expectEqual(AcceptOutcome.invalidated, noteAccepted("e", "m", 100_001));
    try std.testing.expectEqual(@as(?u64, null), learnedInputCap("e", "m"));
    _ = learnInputCap("e", "m", 100_000, .observed);
    try std.testing.expectEqual(AcceptOutcome.raised, noteAccepted("e", "m", 120_000));
    try std.testing.expectEqual(@as(?u64, 120_000), learnedInputCap("e", "m"));
    try std.testing.expectEqual(AcceptOutcome.none, noteAccepted("e", "other", 1));
    try std.testing.expectEqual(AcceptOutcome.none, noteAccepted("e", "m", 0));
}

test "context caps: table is bounded and evicts the stalest entry" {
    resetForTest();
    defer resetForTest();
    var i: usize = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "m{d}", .{i});
        try std.testing.expectEqual(LearnOutcome.inserted, learnInputCap("e", name, 1000 + i, .observed));
        // Make learned_at strictly increasing regardless of clock resolution.
        lock();
        entries[count - 1].learned_at_ms = @intCast(i);
        unlock();
    }
    try std.testing.expectEqual(LearnOutcome.inserted, learnInputCap("e", "overflow", 5, .observed));
    try std.testing.expectEqual(@as(?u64, null), learnedInputCap("e", "m0"));
    try std.testing.expectEqual(@as(?u64, 1001), learnedInputCap("e", "m1"));
    try std.testing.expectEqual(@as(?u64, 5), learnedInputCap("e", "overflow"));
    const long_model = "x" ** (MAX_MODEL + 1);
    try std.testing.expectEqual(LearnOutcome.rejected_key, learnInputCap("e", long_model, 1, .observed));
}

test "context caps: persistence round-trips through the file and ignores foreign schemas" {
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/caps/context_caps.json", .{dir});

    setPersistPathForTest(path);
    try std.testing.expectEqual(LearnOutcome.inserted, learnInputCap("https://napi", "glm-5.3-flash", 883_000, .server_message));
    try std.testing.expectEqual(LearnOutcome.inserted, learnInputCap("https://other", "m", 50_000, .observed));

    // A fresh registry reading the same file sees both entries.
    setPersistPathForTest(path);
    const a = lookup("https://napi", "GLM-5.3-FLASH") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 883_000), a.input_cap);
    try std.testing.expectEqual(Source.server_message, a.source);
    try std.testing.expect(a.learned_at_ms > 0);
    const b = lookup("https://other", "m") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Source.observed, b.source);

    // Invalidation is persisted too.
    try std.testing.expectEqual(AcceptOutcome.invalidated, noteAccepted("https://napi", "glm-5.3-flash", 900_000));
    setPersistPathForTest(path);
    try std.testing.expectEqual(@as(?u64, null), learnedInputCap("https://napi", "glm-5.3-flash"));
    try std.testing.expectEqual(@as(?u64, 50_000), learnedInputCap("https://other", "m"));

    // Foreign schema: start empty, do not crash, do not adopt entries.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "caps/context_caps.json", .data = "{\"schema\":\"someone-else/v9\",\"entries\":[{\"endpoint\":\"e\",\"model\":\"m\",\"input_cap\":1,\"source\":\"observed\"}]}" });
    setPersistPathForTest(path);
    try std.testing.expectEqual(@as(?u64, null), learnedInputCap("e", "m"));
    try std.testing.expectEqual(@as(?u64, null), learnedInputCap("https://other", "m"));
}
