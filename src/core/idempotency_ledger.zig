//! The idempotency keys a Session has accepted (#447), so that one key is
//! one Run however often it is delivered: while its submission is queued,
//! while it runs and, for `retention_ms` after its Run started, across a
//! Host restart.
//!
//! A key is held in one of two states. `accept` holds it as pending when its
//! submission is queued. A pending key lives only in memory: a delivery lost
//! with the queue (the Host stopped before its Run) may be delivered again.
//! `start` marks it started when its Run begins, and the Host `append`s it to
//! the ledger file before the Run does anything. From then on the key is a
//! duplicate even to a restarted Host, and a Run that failed or was
//! interrupted is not run again under it. A started key expires
//! `retention_ms` after its Run started; beyond `max_keys` started keys the
//! oldest is forgotten first.
//!
//! The file, `<session dir>/idempotency.jsonl`, holds one line per started
//! key: `{"key":"...","digest":"<sha256 hex>","started_ms":N}`, wall-clock
//! milliseconds. `load` keeps the last line of each key that has not expired,
//! skips a torn or unreadable line, and rewrites the file with what it kept;
//! the Host rewrites it again (`encodeStarted`, `replaceFile`) once it has
//! appended more than `max_keys` lines (at least 64) since it last wrote it.
//!
//! Not thread-safe. The caller serializes the calls that touch the entries
//! (`check`, `accept`, `start`, `forget`, `encodeStarted`); `load` runs before
//! any of them. `append` and `replaceFile` touch only the file and belong to
//! one thread (SessionHost: the Session's driver).

const std = @import("std");
const pfs = @import("platform").fs;
const typed_submission = @import("typed_submission.zig");
const log = @import("../util/log.zig");

pub const Digest = typed_submission.Digest;

/// The ledger's name inside a session directory.
pub const file_name = "idempotency.jsonl";

/// `load` refuses a larger file rather than read it into memory.
pub const max_file_bytes: usize = 64 * 1024 * 1024;

pub const Verdict = enum {
    /// Not held, or expired: the submission may be queued.
    new,
    /// Held with the same digest: a retry. Queue nothing.
    duplicate,
    /// Held for a different submission.
    reused,
};

pub const Entry = struct {
    digest: Digest,
    /// Wall-clock ms at which its Run started; null while queued.
    started_ms: ?i64 = null,
};

pub const Ledger = struct {
    gpa: std.mem.Allocator,
    retention_ms: u64,
    max_keys: usize,
    /// Owned keys. Started keys are in start order; pending keys sit among
    /// them in acceptance order.
    entries: std.array_hash_map.String(Entry) = .empty,
    started: usize = 0,
    /// The ledger file, owned; null keeps the keys in memory only.
    path: ?[:0]u8 = null,
    /// Lines in the file beyond the started keys it was last written with.
    stale_lines: usize = 0,

    pub fn init(gpa: std.mem.Allocator, retention_ms: u64, max_keys: usize) Ledger {
        return .{ .gpa = gpa, .retention_ms = retention_ms, .max_keys = max_keys };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.entries.keys()) |key| self.gpa.free(key);
        self.entries.deinit(self.gpa);
        if (self.path) |path| self.gpa.free(path);
        self.* = undefined;
    }

    /// What `key` is to a submission with `digest` at `now_ms`. An expired
    /// key is dropped here.
    pub fn check(self: *Ledger, key: []const u8, digest: Digest, now_ms: i64) Verdict {
        const index = self.entries.getIndex(key) orelse return .new;
        const entry = self.entries.values()[index];
        if (self.expired(entry, now_ms)) {
            self.removeAt(index);
            return .new;
        }
        return if (std.mem.eql(u8, &entry.digest, &digest)) .duplicate else .reused;
    }

    /// Holds `key` as pending. Only after `check` answered `.new`.
    pub fn accept(self: *Ledger, key: []const u8, digest: Digest) error{OutOfMemory}!void {
        std.debug.assert(!self.entries.contains(key));
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        try self.entries.putNoClobber(self.gpa, owned, .{ .digest = digest });
    }

    /// Marks pending `key` started at `now_ms`, last in start order, and
    /// forgets the oldest started keys beyond `max_keys`. Returns the entry
    /// to `append`, or null when `key` is not pending.
    pub fn start(self: *Ledger, key: []const u8, now_ms: i64) ?Entry {
        const index = self.entries.getIndex(key) orelse return null;
        const pending = self.entries.values()[index];
        if (pending.started_ms != null) return null;
        const owned = self.entries.keys()[index];
        const entry = Entry{ .digest = pending.digest, .started_ms = now_ms };
        // Move it last; the map keeps the capacity of the slot just freed.
        self.entries.orderedRemoveAt(index);
        self.entries.putAssumeCapacityNoClobber(owned, entry);
        self.started += 1;
        var oldest: usize = 0;
        while (self.started > self.max_keys and oldest < self.entries.count()) {
            if (self.entries.values()[oldest].started_ms != null) self.removeAt(oldest) else oldest += 1;
        }
        return entry;
    }

    /// Lets `key` go: its submission was not run after all (its record could
    /// not be written). A later delivery is new.
    pub fn forget(self: *Ledger, key: []const u8) void {
        const index = self.entries.getIndex(key) orelse return;
        self.removeAt(index);
    }

    pub fn count(self: *const Ledger) usize {
        return self.entries.count();
    }

    fn expired(self: *const Ledger, entry: Entry, now_ms: i64) bool {
        const started_ms = entry.started_ms orelse return false;
        // A clock that went back keeps the key.
        if (now_ms <= started_ms) return false;
        return @as(u64, @intCast(now_ms - started_ms)) > self.retention_ms;
    }

    fn removeAt(self: *Ledger, index: usize) void {
        if (self.entries.values()[index].started_ms != null) self.started -= 1;
        const key = self.entries.keys()[index];
        self.entries.orderedRemoveAt(index);
        self.gpa.free(key);
    }

    // ── file ──────────────────────────────────────────────────────────────

    /// Takes the ledger file at `<dir>/idempotency.jsonl` and the started
    /// keys it holds at `now_ms`. A missing file holds none. Call once,
    /// before anything else.
    pub fn load(self: *Ledger, dir: []const u8, now_ms: i64) !void {
        std.debug.assert(self.path == null and self.entries.count() == 0);
        self.path = try std.fmt.allocPrintSentinel(self.gpa, "{s}/" ++ file_name, .{dir}, 0);
        if (!pfs.exists(self.path.?.ptr)) return;
        const bytes = try readFile(self.gpa, self.path.?);
        defer self.gpa.free(bytes);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var skipped: usize = 0;
        var read: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            read += 1;
            const record = parseLine(arena.allocator(), line) orelse {
                skipped += 1;
                continue;
            };
            // The last line of a key wins: it was started last.
            if (self.entries.getIndex(record.key)) |index| self.removeAt(index);
            const entry = Entry{ .digest = record.digest, .started_ms = record.started_ms };
            if (self.expired(entry, now_ms)) continue;
            try self.accept(record.key, record.digest);
            _ = self.start(record.key, record.started_ms);
        }
        if (skipped != 0) log.warn("idempotency", "{s}: skipped {d} unreadable line(s)", .{ self.path.?, skipped });
        if (read != self.started) {
            const live = try self.encodeStarted(self.gpa);
            defer self.gpa.free(live);
            try self.replaceFile(live);
        }
    }

    /// Appends one started key. Durable when it returns: a Run started after
    /// it is a duplicate to a restarted Host too.
    pub fn append(self: *Ledger, key: []const u8, entry: Entry) !void {
        const path = self.path orelse return;
        var line_buf: [typed_submission.max_idempotency_key_bytes + 160]u8 = undefined;
        const line = try encodeLine(&line_buf, key, entry);
        const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.OpenFailed;
        defer pfs.close(fd);
        try writeAll(fd, line);
        try pfs.fsyncChecked(fd);
        self.stale_lines += 1;
    }

    /// Whether more than `max_keys` lines (at least 64) were appended since
    /// the file was last written whole: the Host should rewrite it
    /// (`encodeStarted`, then `replaceFile`).
    pub fn wantsRewrite(self: *const Ledger) bool {
        return self.path != null and self.stale_lines > @max(self.max_keys, 64);
    }

    /// The started keys as the file's lines, owned by `allocator`.
    pub fn encodeStarted(self: *const Ledger, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var line_buf: [typed_submission.max_idempotency_key_bytes + 160]u8 = undefined;
        for (self.entries.keys(), self.entries.values()) |key, entry| {
            if (entry.started_ms == null) continue;
            const line = encodeLine(&line_buf, key, entry) catch unreachable;
            try out.appendSlice(allocator, line);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Replaces the file with `contents` (`encodeStarted`) atomically.
    pub fn replaceFile(self: *Ledger, contents: []const u8) !void {
        const path = self.path orelse return;
        var tmp_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path});
        const fd = pfs.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.OpenFailed;
        var ok = true;
        writeAll(fd, contents) catch {
            ok = false;
        };
        if (ok) pfs.fsyncChecked(fd) catch {
            ok = false;
        };
        // Closed before the rename: Windows refuses to replace an open file.
        pfs.close(fd);
        if (!ok) return error.WriteFailed;
        if (pfs.renameReplace(tmp.ptr, path.ptr) != 0) return error.RenameFailed;
        self.stale_lines = 0;
    }
};

const Record = struct { key: []const u8, digest: Digest, started_ms: i64 };

fn parseLine(arena: std.mem.Allocator, line: []const u8) ?Record {
    const Shape = struct { key: []const u8, digest: []const u8, started_ms: i64 };
    const parsed = std.json.parseFromSliceLeaky(Shape, arena, line, .{ .ignore_unknown_fields = true }) catch return null;
    typed_submission.validate(.{ .text = "", .idempotency_key = parsed.key }) catch return null;
    var digest: Digest = undefined;
    if (parsed.digest.len != digest.len * 2) return null;
    _ = std.fmt.hexToBytes(&digest, parsed.digest) catch return null;
    return .{ .key = parsed.key, .digest = digest, .started_ms = parsed.started_ms };
}

fn encodeLine(buf: []u8, key: []const u8, entry: Entry) error{NoSpaceLeft}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var json: std.json.Stringify = .{ .writer = &w };
    json.beginObject() catch return error.NoSpaceLeft;
    json.objectField("key") catch return error.NoSpaceLeft;
    json.write(key) catch return error.NoSpaceLeft;
    json.objectField("digest") catch return error.NoSpaceLeft;
    json.write(&std.fmt.bytesToHex(entry.digest, .lower)) catch return error.NoSpaceLeft;
    json.objectField("started_ms") catch return error.NoSpaceLeft;
    json.write(entry.started_ms.?) catch return error.NoSpaceLeft;
    json.endObject() catch return error.NoSpaceLeft;
    w.writeByte('\n') catch return error.NoSpaceLeft;
    return w.buffered();
}

fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    defer pfs.close(fd);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n < 0) {
            if (comptime @import("builtin").os.tag != .windows) {
                if (pfs.lastErrnoIs(.INTR)) continue;
            }
            return error.ReadFailed;
        }
        if (n == 0) break;
        if (all.items.len + @as(usize, @intCast(n)) > max_file_bytes) return error.LedgerTooLarge;
        try all.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return all.toOwnedSlice(allocator);
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) error{WriteFailed}!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = pfs.write(fd, bytes[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn digestOf(text: []const u8) Digest {
    return typed_submission.digest(.{ .text = text });
}

test "Ledger: pending and started keys answer duplicate, another digest reused, an expired key new" {
    var ledger = Ledger.init(testing.allocator, 1000, 10);
    defer ledger.deinit();
    const a = digestOf("a");
    try testing.expectEqual(Verdict.new, ledger.check("k1", a, 0));
    try ledger.accept("k1", a);
    try testing.expectEqual(Verdict.duplicate, ledger.check("k1", a, 0));
    try testing.expectEqual(Verdict.reused, ledger.check("k1", digestOf("b"), 0));
    // Pending keys never expire.
    try testing.expectEqual(Verdict.duplicate, ledger.check("k1", a, 1_000_000));

    const entry = ledger.start("k1", 5000).?;
    try testing.expectEqual(@as(?i64, 5000), entry.started_ms);
    try testing.expect(ledger.start("k1", 5001) == null);
    try testing.expectEqual(Verdict.duplicate, ledger.check("k1", a, 6000));
    // A clock that went back keeps the key.
    try testing.expectEqual(Verdict.duplicate, ledger.check("k1", a, 10));
    try testing.expectEqual(Verdict.new, ledger.check("k1", a, 6001));
    try testing.expectEqual(@as(usize, 0), ledger.count());

    try ledger.accept("k2", a);
    ledger.forget("k2");
    try testing.expectEqual(Verdict.new, ledger.check("k2", a, 0));
}

test "Ledger: beyond max_keys the oldest started key goes first; pending keys stay" {
    var ledger = Ledger.init(testing.allocator, std.math.maxInt(u64), 2);
    defer ledger.deinit();
    const d = digestOf("x");
    for ([_][]const u8{ "k1", "k2", "k3" }) |key| try ledger.accept(key, d);
    try ledger.accept("queued", d);
    _ = ledger.start("k1", 1);
    _ = ledger.start("k2", 2);
    _ = ledger.start("k3", 3);
    try testing.expectEqual(Verdict.new, ledger.check("k1", d, 4));
    try testing.expectEqual(Verdict.duplicate, ledger.check("k2", d, 4));
    try testing.expectEqual(Verdict.duplicate, ledger.check("k3", d, 4));
    try testing.expectEqual(Verdict.duplicate, ledger.check("queued", d, 4));
}

test "Ledger file: started keys survive a reload, expired and torn lines do not, and the file is rewritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    const d = digestOf("x");
    {
        var ledger = Ledger.init(testing.allocator, 100, 10);
        defer ledger.deinit();
        try ledger.load(dir, 0);
        for ([_][]const u8{ "old", "kept", "queued" }) |key| try ledger.accept(key, d);
        try ledger.append("old", ledger.start("old", 0).?);
        try ledger.append("kept", ledger.start("kept", 90).?);
        // "queued" never started: memory only.
    }
    {
        // A torn last line and a line that is not a record.
        const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/" ++ file_name, .{dir}, 0);
        defer testing.allocator.free(path);
        const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true }, @as(c_uint, 0));
        try testing.expect(fd >= 0);
        defer pfs.close(fd);
        try writeAll(fd, "{\"key\":\"x y\",\"digest\":\"00\",\"started_ms\":1}\n{\"key\":\"torn\",\"dig");
    }
    var ledger = Ledger.init(testing.allocator, 100, 10);
    defer ledger.deinit();
    try ledger.load(dir, 150);
    try testing.expectEqual(Verdict.new, ledger.check("old", d, 150));
    try testing.expectEqual(Verdict.duplicate, ledger.check("kept", d, 150));
    try testing.expectEqual(Verdict.new, ledger.check("queued", d, 150));
    try testing.expectEqual(Verdict.new, ledger.check("torn", d, 150));
    const contents = try readFile(testing.allocator, ledger.path.?);
    defer testing.allocator.free(contents);
    const expected = try std.fmt.allocPrint(testing.allocator, "{{\"key\":\"kept\",\"digest\":\"{s}\",\"started_ms\":90}}\n", .{&std.fmt.bytesToHex(d, .lower)});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, contents);
}
