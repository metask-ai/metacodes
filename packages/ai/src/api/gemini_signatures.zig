//! Gemini thought signatures.
//!
//! Gemini 3 and later attach an opaque `thoughtSignature` to the first
//! functionCall part of every model response that calls a function, and
//! validate it strictly: a request whose current turn sends a model
//! functionCall back without the signature it arrived with fails with 400
//! ("Function call ... is missing a thought_signature";
//! ai.google.dev/gemini-api/docs/generate-content/thought-signatures, 2026-10).
//!
//! The conversation stores tool calls in a provider-neutral shape, and the
//! Gemini client already mints the ids of the calls it receives, so the
//! signatures live with the client, keyed by those ids, and go back into the
//! part they came from. A call this client did not receive (history from
//! another model, a resumed session) has no signature; for exactly that case
//! the documentation gives a placeholder that skips validation.

const std = @import("std");

/// The documented stand-in for a signature the client does not have.
pub const PLACEHOLDER = "skip_thought_signature_validator";

/// Signatures kept at most. Only the current turn is validated, so the oldest
/// can go; a dropped one is sent as the placeholder.
pub const MAX_ENTRIES: usize = 1024;

pub const Store = struct {
    allocator: std.mem.Allocator,
    by_id: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Keys in insertion order, for eviction. Each key is owned once, here.
    order: std.ArrayList([]u8) = .empty,
    head: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        var it = self.by_id.valueIterator();
        while (it.next()) |value| self.allocator.free(value.*);
        self.by_id.deinit(self.allocator);
        for (self.order.items[self.head..]) |key| self.allocator.free(key);
        self.order.deinit(self.allocator);
        self.* = undefined;
    }

    /// Remember `signature` for the call `id` (both copied).
    pub fn put(self: *Store, id: []const u8, signature: []const u8) error{OutOfMemory}!void {
        if (self.by_id.getPtr(id)) |existing| {
            const copy = try self.allocator.dupe(u8, signature);
            self.allocator.free(existing.*);
            existing.* = copy;
            return;
        }
        const key = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, signature);
        errdefer self.allocator.free(value);
        try self.order.append(self.allocator, key);
        errdefer self.order.items.len -= 1;
        try self.by_id.put(self.allocator, key, value);
        if (self.order.items.len - self.head > MAX_ENTRIES) self.evictOldest();
    }

    pub fn get(self: *const Store, id: []const u8) ?[]const u8 {
        return self.by_id.get(id);
    }

    pub fn count(self: *const Store) usize {
        return self.by_id.count();
    }

    fn evictOldest(self: *Store) void {
        const key = self.order.items[self.head];
        self.head += 1;
        if (self.by_id.fetchRemove(key)) |entry| self.allocator.free(entry.value);
        self.allocator.free(key);
        // Compact once the dead prefix outgrows the live part.
        if (self.head > MAX_ENTRIES) {
            const live = self.order.items[self.head..];
            std.mem.copyForwards([]u8, self.order.items[0..live.len], live);
            self.order.items.len = live.len;
            self.head = 0;
        }
    }
};

/// The `thoughtSignature` of each functionCall part of one streamed chunk,
/// in part order (null where a part carries none). The k-th entry belongs to
/// the k-th functionCall the stream emits from this chunk. Owned by `gpa`
/// (`freeChunkSignatures`); null when the chunk is not a parseable response.
pub fn chunkSignatures(gpa: std.mem.Allocator, data: []const u8) error{OutOfMemory}!?[]?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const parts = partsOf(parsed.value) orelse return null;
    var out: std.ArrayList(?[]u8) = .empty;
    errdefer {
        for (out.items) |entry| if (entry) |value| gpa.free(value);
        out.deinit(gpa);
    }
    for (parts) |part| {
        if (part != .object) continue;
        if (part.object.get("functionCall") == null) continue;
        const signature: ?[]u8 = if (part.object.get("thoughtSignature")) |value| switch (value) {
            .string => |text| if (text.len > 0) try gpa.dupe(u8, text) else null,
            else => null,
        } else null;
        try out.append(gpa, signature);
    }
    return try out.toOwnedSlice(gpa);
}

pub fn freeChunkSignatures(gpa: std.mem.Allocator, signatures: []?[]u8) void {
    for (signatures) |entry| if (entry) |value| gpa.free(value);
    gpa.free(signatures);
}

fn partsOf(root: std.json.Value) ?[]const std.json.Value {
    if (root != .object) return null;
    const candidates = root.object.get("candidates") orelse return null;
    if (candidates != .array or candidates.array.items.len == 0) return null;
    const first = candidates.array.items[0];
    if (first != .object) return null;
    const content = first.object.get("content") orelse return null;
    if (content != .object) return null;
    const parts = content.object.get("parts") orelse return null;
    if (parts != .array) return null;
    return parts.array.items;
}

const testing = std.testing;

test "chunkSignatures lines signatures up with the functionCall parts" {
    const a = testing.allocator;
    const sigs = (try chunkSignatures(a,
        \\{"candidates":[{"content":{"role":"model","parts":[
        \\  {"text":"checking"},
        \\  {"functionCall":{"name":"read","args":{"p":"a"}},"thoughtSignature":"SIG-1"},
        \\  {"functionCall":{"name":"read","args":{"p":"b"}}}
        \\]}}]}
    )).?;
    defer freeChunkSignatures(a, sigs);
    try testing.expectEqual(@as(usize, 2), sigs.len);
    try testing.expectEqualStrings("SIG-1", sigs[0].?);
    try testing.expect(sigs[1] == null);
    try testing.expect(try chunkSignatures(a, "not json") == null);
    try testing.expect(try chunkSignatures(a, "{\"usageMetadata\":{}}") == null);
}

test "the store keeps the newest signatures and replaces a repeated id" {
    const a = testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    try store.put("call_1", "one");
    try store.put("call_1", "uno");
    try testing.expectEqualStrings("uno", store.get("call_1").?);
    var buf: [32]u8 = undefined;
    for (0..MAX_ENTRIES + 10) |i| try store.put(try std.fmt.bufPrint(&buf, "c{d}", .{i}), "s");
    try testing.expectEqual(MAX_ENTRIES, store.count());
    try testing.expect(store.get("call_1") == null);
    try testing.expect(store.get("c0") == null);
    try testing.expectEqualStrings("s", store.get(try std.fmt.bufPrint(&buf, "c{d}", .{MAX_ENTRIES + 9})).?);
}
