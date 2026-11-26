//! Per-route provider cache for the gateway (doc/SEALED_GATEWAY_SCALE_DESIGN.md §4).
//!
//! A Step's model call is made on the client's own route and credential
//! (§8.1). Building a provider per request also builds a fresh HTTP client,
//! so every Step paid a TLS handshake to the upstream. This pool keeps a
//! built provider — and with it `std.http.Client`'s connection pool — for a
//! short idle window, keyed by a fingerprint of everything that shapes the
//! route: provider kind, base URL, protocol, auth scheme, model, token
//! limits, and the credential itself.
//!
//! An entry is lent to exactly one request at a time (provider clients are
//! not shared across threads); a second concurrent request with the same
//! fingerprint builds a second entry. Idle entries expire after
//! `idle_ttl_ms` and the pool holds at most `max_entries`; expiry is checked
//! on every borrow and give-back, so a credential is never kept longer than
//! one idle window after its last use. `idle_ttl_ms = 0` disables caching:
//! every borrow builds, every give-back destroys, which is the per-request
//! behaviour the protocol describes.

const std = @import("std");
const psync = @import("platform").sync;
const util_time = @import("metacodes-base").util.time;
const provider_factory = @import("metacodes-ai").api.provider_factory;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const DEFAULT_IDLE_TTL_MS: u64 = 60_000;
pub const DEFAULT_MAX_ENTRIES: usize = 256;

pub const Key = [Sha256.digest_length]u8;

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    expired: u64 = 0,
    evicted: u64 = 0,
    /// Entries present (lent or idle) at the last operation.
    size: usize = 0,
};

/// What a builder returns: the provider, and the copy of the credential it
/// made with the entry's allocator (zeroed when the entry dies). Everything
/// the provider borrows (model, base URL, auth strings, the credential) must
/// be allocated from the entry allocator the builder is given, because the
/// request that triggered the build is gone by the next lease.
pub const Built = struct {
    owned: provider_factory.OwnedProvider,
    secret: []u8 = &.{},
};

pub const Entry = struct {
    key: Key,
    owned: provider_factory.OwnedProvider,
    in_use: bool,
    last_used_ms: i64,
    /// Owns every string the provider borrows for as long as it is cached.
    arena: std.heap.ArenaAllocator,
    secret: []u8,
};

pub const Lease = struct {
    pool: *Pool,
    entry: *Entry,

    pub fn provider(self: *const Lease) @import("metacodes-ai").api.provider.Provider {
        return self.entry.owned.provider();
    }

    /// Return the provider to the pool (or destroy it when caching is off).
    pub fn release(self: Lease) void {
        self.pool.giveBack(self.entry);
    }
};

/// Hash the route-shaping inputs. `parts` are concatenated with length
/// prefixes so no two part lists collide.
pub fn fingerprint(parts: []const []const u8) Key {
    var hash = Sha256.init(.{});
    hash.update("metacodes.sealed.provider-pool/v1");
    for (parts) |part| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, part.len, .big);
        hash.update(&length);
        hash.update(part);
    }
    var digest: Key = undefined;
    hash.final(&digest);
    return digest;
}

pub const Pool = struct {
    allocator: std.mem.Allocator,
    mutex: psync.Mutex = .{},
    entries: std.ArrayList(*Entry) = .empty,
    idle_ttl_ms: u64,
    max_entries: usize,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, idle_ttl_ms: u64, max_entries: usize) Pool {
        return .{ .allocator = allocator, .idle_ttl_ms = idle_ttl_ms, .max_entries = @max(max_entries, 1) };
    }

    /// Destroy every entry. Callers must have released all leases.
    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        for (self.entries.items) |entry| destroyEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn snapshot(self: *Pool) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        var stats = self.stats;
        stats.size = self.entries.items.len;
        return stats;
    }

    /// Lend an idle provider for `key`, or build one with `build` when none
    /// is idle. `build` runs outside the lock and receives the entry's own
    /// allocator for everything the provider must keep borrowing.
    pub fn borrow(
        self: *Pool,
        key: Key,
        context: anytype,
        comptime build: fn (@TypeOf(context), std.mem.Allocator) anyerror!Built,
    ) anyerror!Lease {
        const now = nowMs();
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.expireLocked(now);
            for (self.entries.items) |entry| {
                if (entry.in_use or !std.mem.eql(u8, &entry.key, &key)) continue;
                entry.in_use = true;
                entry.last_used_ms = now;
                self.stats.hits += 1;
                return .{ .pool = self, .entry = entry };
            }
            self.stats.misses += 1;
        }
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .key = key,
            .owned = undefined,
            .in_use = true,
            .last_used_ms = now,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .secret = &.{},
        };
        errdefer entry.arena.deinit();
        const built = try build(context, entry.arena.allocator());
        entry.owned = built.owned;
        entry.secret = built.secret;
        errdefer entry.owned.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.entries.append(self.allocator, entry);
        return .{ .pool = self, .entry = entry };
    }

    fn giveBack(self: *Pool, entry: *Entry) void {
        const now = nowMs();
        var to_destroy: ?*Entry = null;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            entry.in_use = false;
            entry.last_used_ms = now;
            if (self.idle_ttl_ms == 0) {
                self.removeLocked(entry);
                to_destroy = entry;
            } else {
                self.expireLocked(now);
                // Over capacity: evict the idle entry least recently used.
                while (self.entries.items.len > self.max_entries) {
                    const victim = self.oldestIdleLocked() orelse break;
                    self.removeLocked(victim);
                    self.stats.evicted += 1;
                    if (victim == entry) {
                        to_destroy = entry;
                    } else {
                        destroyEntry(self.allocator, victim);
                    }
                }
            }
        }
        if (to_destroy) |victim| destroyEntry(self.allocator, victim);
    }

    fn expireLocked(self: *Pool, now: i64) void {
        if (self.idle_ttl_ms == 0) return;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (!entry.in_use and now - entry.last_used_ms > @as(i64, @intCast(self.idle_ttl_ms))) {
                _ = self.entries.swapRemove(index);
                destroyEntry(self.allocator, entry);
                self.stats.expired += 1;
                continue;
            }
            index += 1;
        }
    }

    fn oldestIdleLocked(self: *Pool) ?*Entry {
        var oldest: ?*Entry = null;
        for (self.entries.items) |entry| {
            if (entry.in_use) continue;
            if (oldest == null or entry.last_used_ms < oldest.?.last_used_ms) oldest = entry;
        }
        return oldest;
    }

    fn removeLocked(self: *Pool, entry: *Entry) void {
        for (self.entries.items, 0..) |candidate, index| {
            if (candidate == entry) {
                _ = self.entries.swapRemove(index);
                return;
            }
        }
    }
};

fn destroyEntry(allocator: std.mem.Allocator, entry: *Entry) void {
    entry.owned.deinit();
    // The credential copy lives in the arena; wipe it before the arena goes.
    @memset(entry.secret, 0);
    entry.arena.deinit();
    allocator.destroy(entry);
}

fn nowMs() i64 {
    return @intCast(util_time.nowMs());
}

test "fingerprint separates parts by length, not by content" {
    const a = fingerprint(&.{ "ab", "c" });
    const b = fingerprint(&.{ "a", "bc" });
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(std.mem.eql(u8, &fingerprint(&.{ "ab", "c" }), &a));
}

const FakeBuild = struct {
    builds: *u32,

    fn build(self: FakeBuild, allocator: std.mem.Allocator) anyerror!Built {
        self.builds.* += 1;
        const secret = try allocator.dupe(u8, "k");
        const model = try allocator.dupe(u8, "claude-sonnet-4-20250514");
        return .{ .owned = try provider_factory.makeProvider(std.testing.allocator, .anthropic, secret, model, "http://127.0.0.1:1"), .secret = secret };
    }
};

test "pool lends an idle entry again and builds a second for a concurrent borrow" {
    var pool = Pool.init(std.testing.allocator, DEFAULT_IDLE_TTL_MS, 4);
    defer pool.deinit();
    var builds: u32 = 0;
    const key = fingerprint(&.{"route"});
    const first = try pool.borrow(key, FakeBuild{ .builds = &builds }, FakeBuild.build);
    const second = try pool.borrow(key, FakeBuild{ .builds = &builds }, FakeBuild.build);
    try std.testing.expectEqual(@as(u32, 2), builds);
    first.release();
    second.release();
    const third = try pool.borrow(key, FakeBuild{ .builds = &builds }, FakeBuild.build);
    try std.testing.expectEqual(@as(u32, 2), builds);
    third.release();
    const stats = pool.snapshot();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 2), stats.misses);
    try std.testing.expectEqual(@as(usize, 2), stats.size);
}

test "ttl zero caches nothing and capacity evicts the least recently used idle entry" {
    var builds: u32 = 0;
    var off = Pool.init(std.testing.allocator, 0, 4);
    defer off.deinit();
    const key = fingerprint(&.{"route"});
    const lease = try off.borrow(key, FakeBuild{ .builds = &builds }, FakeBuild.build);
    lease.release();
    try std.testing.expectEqual(@as(usize, 0), off.snapshot().size);

    var small = Pool.init(std.testing.allocator, DEFAULT_IDLE_TTL_MS, 1);
    defer small.deinit();
    const a = try small.borrow(fingerprint(&.{"a"}), FakeBuild{ .builds = &builds }, FakeBuild.build);
    const b = try small.borrow(fingerprint(&.{"b"}), FakeBuild{ .builds = &builds }, FakeBuild.build);
    a.release();
    b.release();
    const stats = small.snapshot();
    try std.testing.expectEqual(@as(usize, 1), stats.size);
    try std.testing.expectEqual(@as(u64, 1), stats.evicted);
}
