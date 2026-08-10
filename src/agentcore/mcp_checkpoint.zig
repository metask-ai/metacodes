//! Value-only MCP authority section stored inside a Session checkpoint.

const std = @import("std");
const canonical = @import("mcp_canonical.zig");
const mcp_session = @import("mcp_session.zig");

pub const STATE_REVISION: u16 = 2;
pub const MAX_ENTRIES: usize = (canonical.Limits{}).max_tools;
pub const MAX_STATE_BYTES: usize = 2 * 1024 * 1024;

const r6_magic = "R6MCP\x00\x00\x00";
const r7_magic = "R7MCP\x00\x00\x00";
const header_bytes: usize = 96;
const entry_bytes: usize = 72;

pub const Error = error{
    OutOfMemory,
    ResourceLimit,
    Corrupt,
    InvalidState,
};

pub const PersistedEntry = struct {
    server_binding_identity: [32]u8,
    schema_fingerprint: [32]u8,
    tool_name: []const u8,
    era: canonical.Era,
};

pub const StateView = struct {
    catalog_generation: u64,
    catalog_fingerprint: [32]u8,
    selection_fingerprint: [32]u8,
    entries: []const PersistedEntry,
};

pub const DecodedState = struct {
    arena: std.heap.ArenaAllocator,
    catalog_generation: u64,
    catalog_fingerprint: [32]u8,
    selection_fingerprint: [32]u8,
    entries: []PersistedEntry,

    pub fn deinit(self: *DecodedState) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn selectors(
        self: *const DecodedState,
        allocator: std.mem.Allocator,
    ) Error![]mcp_session.Selector {
        const result = allocator.alloc(mcp_session.Selector, self.entries.len) catch
            return error.OutOfMemory;
        for (self.entries, result) |entry, *selector| selector.* = .{
            .server_binding_identity = entry.server_binding_identity,
            .tool_name = entry.tool_name,
            .expected_schema_fingerprint = entry.schema_fingerprint,
        };
        return result;
    }
};

pub fn encodeView(
    allocator: std.mem.Allocator,
    optional_view: ?*const mcp_session.View,
) Error![]u8 {
    const source = optional_view orelse
        return allocator.alloc(u8, 0) catch error.OutOfMemory;
    const entries = allocator.alloc(PersistedEntry, source.entries.len) catch
        return error.OutOfMemory;
    defer allocator.free(entries);
    for (source.entries, entries) |entry, *persisted| persisted.* = .{
        .server_binding_identity = entry.tool.identity.server_binding_identity,
        .schema_fingerprint = entry.tool.identity.schema_fingerprint,
        .tool_name = entry.tool.identity.name,
        .era = entry.server.client.era,
    };
    return encode(allocator, .{
        .catalog_generation = source.catalog_generation,
        .catalog_fingerprint = source.catalog_fingerprint,
        .selection_fingerprint = source.selection_fingerprint,
        .entries = entries,
    });
}

pub fn encode(allocator: std.mem.Allocator, state: StateView) Error![]u8 {
    if (state.catalog_generation == 0 or state.entries.len > MAX_ENTRIES)
        return error.InvalidState;
    const derived = computeSelectionFingerprint(state.entries);
    if (!std.mem.eql(u8, &derived, &state.selection_fingerprint))
        return error.InvalidState;
    var total = header_bytes;
    for (state.entries, 0..) |entry, index| {
        canonical.validateToolName(entry.tool_name, .{}) catch |err| return switch (err) {
            error.OutOfMemory => unreachable,
            error.ResourceLimit => error.ResourceLimit,
            error.InvalidValue => error.InvalidState,
        };
        if (allZero(&entry.server_binding_identity) or allZero(&entry.schema_fingerprint))
            return error.InvalidState;
        for (state.entries[0..index]) |previous| {
            if (std.mem.eql(u8, &previous.server_binding_identity, &entry.server_binding_identity) and
                std.mem.eql(u8, previous.tool_name, entry.tool_name))
                return error.InvalidState;
        }
        total = std.math.add(usize, total, entry_bytes) catch return error.ResourceLimit;
        total = std.math.add(usize, total, entry.tool_name.len) catch return error.ResourceLimit;
        if (total > MAX_STATE_BYTES) return error.ResourceLimit;
    }
    const bytes = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..r7_magic.len], r7_magic);
    std.mem.writeInt(u16, bytes[8..10], STATE_REVISION, .little);
    std.mem.writeInt(u64, bytes[16..24], state.catalog_generation, .little);
    @memcpy(bytes[24..56], &state.catalog_fingerprint);
    @memcpy(bytes[56..88], &state.selection_fingerprint);
    std.mem.writeInt(u32, bytes[88..92], @intCast(state.entries.len), .little);
    var offset = header_bytes;
    for (state.entries) |entry| {
        @memcpy(bytes[offset..][0..32], &entry.server_binding_identity);
        @memcpy(bytes[offset + 32 ..][0..32], &entry.schema_fingerprint);
        std.mem.writeInt(u32, bytes[offset + 64 ..][0..4], @intCast(entry.tool_name.len), .little);
        bytes[offset + 68] = @intFromEnum(entry.era);
        offset += entry_bytes;
        @memcpy(bytes[offset..][0..entry.tool_name.len], entry.tool_name);
        offset += entry.tool_name.len;
    }
    std.debug.assert(offset == bytes.len);
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) Error!?DecodedState {
    if (encoded.len == 0) return null;
    if (encoded.len < header_bytes or encoded.len > MAX_STATE_BYTES)
        return error.Corrupt;
    const revision = std.mem.readInt(u16, encoded[8..10], .little);
    const known_pair = (std.mem.eql(u8, encoded[0..r6_magic.len], r6_magic) and revision == 1) or
        (std.mem.eql(u8, encoded[0..r7_magic.len], r7_magic) and revision == STATE_REVISION);
    if (!known_pair or
        !allZero(encoded[10..16]) or !allZero(encoded[92..96]))
        return error.Corrupt;
    const generation = std.mem.readInt(u64, encoded[16..24], .little);
    const count: usize = @intCast(std.mem.readInt(u32, encoded[88..92], .little));
    if (generation == 0 or count > MAX_ENTRIES) return error.Corrupt;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const entries = arena.allocator().alloc(PersistedEntry, count) catch
        return error.OutOfMemory;
    var offset = header_bytes;
    for (entries, 0..) |*entry, index| {
        const fixed_end = std.math.add(usize, offset, entry_bytes) catch return error.ResourceLimit;
        if (fixed_end > encoded.len) return error.Corrupt;
        const name_len: usize = @intCast(std.mem.readInt(u32, encoded[offset + 64 ..][0..4], .little));
        const era: canonical.Era = switch (encoded[offset + 68]) {
            0 => .modern_2026_07_28,
            1 => .classic_2025_11_25,
            2 => if (revision == STATE_REVISION) .classic_2025_06_18 else return error.Corrupt,
            else => return error.Corrupt,
        };
        if (!allZero(encoded[offset + 69 .. fixed_end])) return error.Corrupt;
        const name_end = std.math.add(usize, fixed_end, name_len) catch return error.ResourceLimit;
        if (name_end > encoded.len) return error.Corrupt;
        const name = arena.allocator().dupe(u8, encoded[fixed_end..name_end]) catch
            return error.OutOfMemory;
        canonical.validateToolName(name, .{}) catch return error.Corrupt;
        entry.* = .{
            .server_binding_identity = encoded[offset..][0..32].*,
            .schema_fingerprint = encoded[offset + 32 ..][0..32].*,
            .tool_name = name,
            .era = era,
        };
        if (allZero(&entry.server_binding_identity) or allZero(&entry.schema_fingerprint))
            return error.Corrupt;
        for (entries[0..index]) |previous| {
            if (std.mem.eql(u8, &previous.server_binding_identity, &entry.server_binding_identity) and
                std.mem.eql(u8, previous.tool_name, entry.tool_name))
                return error.Corrupt;
        }
        offset = name_end;
    }
    if (offset != encoded.len) return error.Corrupt;
    const selection_fingerprint = encoded[56..88].*;
    const derived = computeSelectionFingerprint(entries);
    if (!std.mem.eql(u8, &selection_fingerprint, &derived)) return error.Corrupt;
    return DecodedState{
        .arena = arena,
        .catalog_generation = generation,
        .catalog_fingerprint = encoded[24..56].*,
        .selection_fingerprint = selection_fingerprint,
        .entries = entries,
    };
}

pub fn computeSelectionFingerprint(entries: []const PersistedEntry) [32]u8 {
    var digests: [MAX_ENTRIES][32]u8 = undefined;
    std.debug.assert(entries.len <= digests.len);
    for (entries, digests[0..entries.len]) |entry, *digest| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&entry.server_binding_identity);
        hasher.update(entry.tool_name);
        hasher.update(&entry.schema_fingerprint);
        hasher.final(digest);
    }
    std.mem.sort([32]u8, digests[0..entries.len], {}, struct {
        fn lessThan(_: void, left: [32]u8, right: [32]u8) bool {
            return std.mem.order(u8, &left, &right) == .lt;
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Selection identity intentionally excludes era and remains stable when a
    // Revision 6 MCP section is decoded by Revision 7.
    hasher.update("agentcore-r6-mcp-session-selection\x00");
    for (digests[0..entries.len]) |digest| hasher.update(&digest);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

test "MCP checkpoint state is value-only deterministic and corruption checked" {
    const entries = [_]PersistedEntry{
        .{
            .server_binding_identity = [_]u8{1} ** 32,
            .schema_fingerprint = [_]u8{2} ** 32,
            .tool_name = "weather",
            .era = .modern_2026_07_28,
        },
        .{
            .server_binding_identity = [_]u8{3} ** 32,
            .schema_fingerprint = [_]u8{4} ** 32,
            .tool_name = "search",
            .era = .classic_2025_11_25,
        },
    };
    const encoded = try encode(std.testing.allocator, .{
        .catalog_generation = 7,
        .catalog_fingerprint = [_]u8{9} ** 32,
        .selection_fingerprint = computeSelectionFingerprint(&entries),
        .entries = &entries,
    });
    defer std.testing.allocator.free(encoded);
    var decoded = (try decode(std.testing.allocator, encoded)).?;
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 7), decoded.catalog_generation);
    try std.testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try std.testing.expectEqualStrings("weather", decoded.entries[0].tool_name);
    const selectors = try decoded.selectors(std.testing.allocator);
    defer std.testing.allocator.free(selectors);
    try std.testing.expectEqualSlices(u8, &entries[0].schema_fingerprint, &selectors[0].expected_schema_fingerprint.?);

    const corrupt = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupt);
    corrupt[56] ^= 1;
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, corrupt));

    const r7_revision_1 = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(r7_revision_1);
    std.mem.writeInt(u16, r7_revision_1[8..10], 1, .little);
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, r7_revision_1));

    const r6_revision_2 = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(r6_revision_2);
    @memcpy(r6_revision_2[0..r6_magic.len], r6_magic);
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, r6_revision_2));

    const unknown_magic = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(unknown_magic);
    unknown_magic[0] = 'X';
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, unknown_magic));

    const unknown_era = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(unknown_era);
    unknown_era[header_bytes + 68] = 3;
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, unknown_era));

    const r6 = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(r6);
    @memcpy(r6[0..r6_magic.len], r6_magic);
    std.mem.writeInt(u16, r6[8..10], 1, .little);
    var migrated = (try decode(std.testing.allocator, r6)).?;
    defer migrated.deinit();
    try std.testing.expectEqual(canonical.Era.classic_2025_11_25, migrated.entries[1].era);
}

test "R7 checkpoint appends 2025-06 era and encoder never emits R6" {
    const entries = [_]PersistedEntry{.{
        .server_binding_identity = [_]u8{5} ** 32,
        .schema_fingerprint = [_]u8{6} ** 32,
        .tool_name = "classic06",
        .era = .classic_2025_06_18,
    }};
    const encoded = try encode(std.testing.allocator, .{
        .catalog_generation = 1,
        .catalog_fingerprint = [_]u8{7} ** 32,
        .selection_fingerprint = computeSelectionFingerprint(&entries),
        .entries = &entries,
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(r7_magic, encoded[0..r7_magic.len]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, encoded[8..10], .little));
    var decoded = (try decode(std.testing.allocator, encoded)).?;
    defer decoded.deinit();
    try std.testing.expectEqual(canonical.Era.classic_2025_06_18, decoded.entries[0].era);

    const forged_r6 = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(forged_r6);
    @memcpy(forged_r6[0..r6_magic.len], r6_magic);
    std.mem.writeInt(u16, forged_r6[8..10], 1, .little);
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, forged_r6));
}
