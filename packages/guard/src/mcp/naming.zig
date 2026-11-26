//! Model-visible MCP tool names: `mcp__<server>__<tool>`, the form Claude Code
//! exposes and its permission rules, Skill `allowed-tools` and subagent
//! `tools:` lists use (Codex flattens to the same shape).
//!
//! Provider tool names must match `^[a-zA-Z0-9_-]{1,64}$`, while MCP allows
//! dots, colons, slashes and up to 128 characters (SEP-986), and server names
//! may contain `.:@/`. Every other character becomes `_`, keeping hyphens as
//! Claude Code does. A name that is too long, or that collides with one
//! already issued, keeps a readable prefix and ends in `_` plus eight hex
//! digits of a SHA-256 over the raw server and tool names — stable across
//! sessions, so permission rules and transcripts keep matching.

const std = @import("std");

pub const PREFIX = "mcp__";
pub const SEPARATOR = "__";
pub const MAX_NAME_BYTES: usize = 64;
const SUFFIX_BYTES: usize = 9; // "_" + 8 hex digits

/// Sanitized `mcp__<server>__<tool>` within `MAX_NAME_BYTES`. `taken` reports
/// whether a candidate is already in use; a collision gets the hash suffix.
pub fn modelToolName(
    allocator: std.mem.Allocator,
    server: []const u8,
    tool: []const u8,
    taken: anytype,
) error{OutOfMemory}![]u8 {
    var buffer: [256]u8 = undefined;
    var length: usize = 0;
    appendSanitized(&buffer, &length, PREFIX, false);
    appendSanitized(&buffer, &length, server, true);
    appendSanitized(&buffer, &length, SEPARATOR, false);
    appendSanitized(&buffer, &length, tool, true);
    const plain = buffer[0..length];
    if (plain.len <= MAX_NAME_BYTES and !taken.contains(plain)) return allocator.dupe(u8, plain);

    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(server);
        hash.update("\x00");
        hash.update(tool);
        if (attempt != 0) {
            var counter: [4]u8 = undefined;
            std.mem.writeInt(u32, &counter, attempt, .big);
            hash.update(&counter);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        const hex = std.fmt.bytesToHex(digest[0..4], .lower);
        const keep = @min(plain.len, MAX_NAME_BYTES - SUFFIX_BYTES);
        var out: [MAX_NAME_BYTES]u8 = undefined;
        @memcpy(out[0..keep], plain[0..keep]);
        out[keep] = '_';
        @memcpy(out[keep + 1 .. keep + SUFFIX_BYTES], &hex);
        const candidate = out[0 .. keep + SUFFIX_BYTES];
        if (!taken.contains(candidate)) return allocator.dupe(u8, candidate);
    }
}

fn appendSanitized(buffer: []u8, length: *usize, text: []const u8, sanitize: bool) void {
    for (text) |byte| {
        if (length.* == buffer.len) return;
        const keep = !sanitize or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        buffer[length.*] = if (keep) byte else '_';
        length.* += 1;
    }
}

/// Whether `name` is a valid provider tool name.
pub fn isProviderSafe(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_BYTES) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

/// Whether `listed` is the pre-`mcp__` metacodes name (`<server>__<tool>`) of
/// the model-visible `model_name`. Tool lists and rules written for that
/// naming keep selecting the same tool; a name without `__` (a built-in tool)
/// never aliases.
pub fn isLegacyAlias(listed: []const u8, model_name: []const u8) bool {
    if (std.mem.startsWith(u8, listed, PREFIX)) return false;
    if (std.mem.indexOf(u8, listed, SEPARATOR) == null) return false;
    if (!std.mem.startsWith(u8, model_name, PREFIX)) return false;
    return std.mem.eql(u8, model_name[PREFIX.len..], listed);
}

/// A name set backed by a string hash map (any type with `contains` works).
pub const NameSet = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    pub fn contains(self: *const NameSet, name: []const u8) bool {
        return self.map.contains(name);
    }

    pub fn put(self: *NameSet, allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}!void {
        try self.map.put(allocator, name, {});
    }

    pub fn deinit(self: *NameSet, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }
};

const testing = std.testing;

const NoneTaken = struct {
    fn contains(_: NoneTaken, _: []const u8) bool {
        return false;
    }
};

test "readable names follow Claude Code's mcp__server__tool form" {
    const name = try modelToolName(testing.allocator, "github", "create_issue", NoneTaken{});
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("mcp__github__create_issue", name);
    const hyphen = try modelToolName(testing.allocator, "cloudflare-api", "list-zones", NoneTaken{});
    defer testing.allocator.free(hyphen);
    try testing.expectEqualStrings("mcp__cloudflare-api__list-zones", hyphen);
}

test "invalid characters are replaced and long names get a stable hash suffix" {
    const dotted = try modelToolName(testing.allocator, "my.server", "browser.navigate", NoneTaken{});
    defer testing.allocator.free(dotted);
    try testing.expectEqualStrings("mcp__my_server__browser_navigate", dotted);
    try testing.expect(isProviderSafe(dotted));

    const long_tool = "x" ** 100;
    const first = try modelToolName(testing.allocator, "srv", long_tool, NoneTaken{});
    defer testing.allocator.free(first);
    const second = try modelToolName(testing.allocator, "srv", long_tool, NoneTaken{});
    defer testing.allocator.free(second);
    try testing.expectEqual(MAX_NAME_BYTES, first.len);
    try testing.expect(isProviderSafe(first));
    try testing.expectEqualStrings(first, second);
}

test "collisions after sanitizing get distinct suffixes" {
    var taken = NameSet{};
    defer taken.deinit(testing.allocator);
    const a = try modelToolName(testing.allocator, "srv", "a.b", &taken);
    defer testing.allocator.free(a);
    try taken.put(testing.allocator, a);
    const b = try modelToolName(testing.allocator, "srv", "a_b", &taken);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("mcp__srv__a_b", a);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(isProviderSafe(b));
}

test "legacy server__tool names alias the mcp__ form only" {
    try testing.expect(isLegacyAlias("github__create_issue", "mcp__github__create_issue"));
    try testing.expect(!isLegacyAlias("github__create_issue", "mcp__github__create_issue_comment"));
    try testing.expect(!isLegacyAlias("mcp__github__create_issue", "mcp__github__create_issue"));
    try testing.expect(!isLegacyAlias("Read", "mcp__Read"));
    try testing.expect(!isLegacyAlias("github__create_issue", "github__create_issue"));
}
