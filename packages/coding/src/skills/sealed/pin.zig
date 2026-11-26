//! Pinned sealed Skills (doc/SEALED_SKILL_PROTOCOL.md §6.1, §9 "Catalog").
//!
//! A pin is the user's consent to exactly one manifest digest. It lives under
//! `<state root>/sealed-skills/<name>/` as two files:
//!
//! - `sealed.json` — the gateway URL, the token environment variable, and the
//!   Entry exactly as the gateway served it (manifest, digest, signature).
//!   This is the authority: activation re-reads and re-verifies it.
//! - `SKILL.md` — a projection for the ordinary Skill catalog: frontmatter
//!   with the manifest's listing fields, the allowlist as `allowed-tools`,
//!   the three `sealed-*` binding keys, and a body of `$ARGUMENTS` so the
//!   rendered body of an activation is the user's arguments and nothing else.
//!
//! No Skill content ever enters this directory; the gateway never sends any.

const std = @import("std");
const protocol = @import("protocol.zig");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const fs_util = @import("metacodes-base").util.fs;
const catalog = @import("../runtime/catalog.zig");
const util_time = @import("metacodes-base").util.time;

pub const PIN_SCHEMA = "metacodes.sealed-pin/v1";
pub const PIN_DIR_NAME = "sealed-skills";
pub const PIN_FILE_NAME = "sealed.json";
pub const DEFAULT_TOKEN_ENV = "METACODES_SEALED_TOKEN";
/// Always in a sealed Skill's frame: the user answering their own Skill.
pub const ASK_USER_TOOL = "AskUserQuestion";
pub const MAX_PIN_BYTES: usize = 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    NoStateRoot,
    PathTooLong,
    InvalidSkillName,
    WriteFailed,
    ReadFailed,
    NotFound,
    InvalidPin,
    /// The pin's recorded digest does not match the manifest it carries.
    DigestMismatch,
};

pub const Pin = struct {
    gateway_url: []const u8,
    token_env: []const u8,
    installed_at_ms: i64,
    entry: protocol.Entry,
};

pub const ParsedPin = struct {
    arena: std.heap.ArenaAllocator,
    pin: Pin,

    pub fn deinit(self: *ParsedPin) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// `<state root>/sealed-skills`.
pub fn pinRoot(allocator: std.mem.Allocator, state_root: []const u8) Error![]u8 {
    if (state_root.len == 0) return error.NoStateRoot;
    return std.fs.path.join(allocator, &.{ state_root, PIN_DIR_NAME }) catch return error.OutOfMemory;
}

/// Write (or replace) the pin for `entry` served by `gateway_url`.
/// `entry_json` is the gateway's Entry object verbatim; `entry` is its parsed
/// form (already digest-verified by `protocol.parseEntry`).
pub fn write(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    gateway_url: []const u8,
    token_env: []const u8,
    entry_json: []const u8,
    entry: *const protocol.Entry,
) Error!void {
    const name = entry.manifest.name;
    if (!catalog.validCompatInvocationName(name) or std.mem.indexOfAny(u8, name, "/\\") != null)
        return error.InvalidSkillName;
    const root = try pinRoot(allocator, state_root);
    defer allocator.free(root);
    const dir = std.fs.path.join(allocator, &.{ root, name }) catch return error.OutOfMemory;
    defer allocator.free(dir);
    fs_util.mkdirParents(dir) catch return error.WriteFailed;

    const pin_json = try renderPinJson(allocator, gateway_url, token_env, entry_json);
    defer allocator.free(pin_json);
    const pin_path = std.fs.path.join(allocator, &.{ dir, PIN_FILE_NAME }) catch return error.OutOfMemory;
    defer allocator.free(pin_path);
    try writeFile(allocator, pin_path, pin_json);

    const skill_md = try renderSkillMd(allocator, gateway_url, entry);
    defer allocator.free(skill_md);
    const md_path = std.fs.path.join(allocator, &.{ dir, "SKILL.md" }) catch return error.OutOfMemory;
    defer allocator.free(md_path);
    try writeFile(allocator, md_path, skill_md);
}

/// Write one public asset of the Skill (§5 `assets`) under the pin directory
/// at its package-relative `/`-separated path. The caller verified the bytes
/// against the Entry's digest; the path was validated by `protocol.validAssetPath`.
pub fn writeAsset(allocator: std.mem.Allocator, state_root: []const u8, name: []const u8, relative: []const u8, bytes: []const u8) Error!void {
    if (!protocol.validAssetPath(relative)) return error.InvalidPin;
    const root = try pinRoot(allocator, state_root);
    defer allocator.free(root);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    parts.append(allocator, root) catch return error.OutOfMemory;
    parts.append(allocator, name) catch return error.OutOfMemory;
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| parts.append(allocator, segment) catch return error.OutOfMemory;
    const path = std.fs.path.join(allocator, parts.items) catch return error.OutOfMemory;
    defer allocator.free(path);
    fs_util.mkdirParentsOf(path) catch return error.WriteFailed;
    try writeFile(allocator, path, bytes);
}

/// Read and verify the pin in `skill_dir` (a catalog record's `live_dir`).
pub fn read(allocator: std.mem.Allocator, skill_dir: []const u8) Error!ParsedPin {
    const path = std.fs.path.join(allocator, &.{ skill_dir, PIN_FILE_NAME }) catch return error.OutOfMemory;
    defer allocator.free(path);
    const bytes = try readFile(allocator, path);
    defer allocator.free(bytes);
    return parsePin(allocator, bytes);
}

pub fn parsePin(allocator: std.mem.Allocator, bytes: []const u8) Error!ParsedPin {
    var result: ParsedPin = .{ .arena = std.heap.ArenaAllocator.init(allocator), .pin = undefined };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPin,
    };
    if (value != .object) return error.InvalidPin;
    const schema = value.object.get("schema") orelse return error.InvalidPin;
    if (schema != .string or !std.mem.eql(u8, schema.string, PIN_SCHEMA)) return error.InvalidPin;
    const gateway = value.object.get("gateway") orelse return error.InvalidPin;
    if (gateway != .string or gateway.string.len == 0) return error.InvalidPin;
    const token_env = value.object.get("token_env") orelse return error.InvalidPin;
    if (token_env != .string) return error.InvalidPin;
    var installed_at: i64 = 0;
    if (value.object.get("installed_at_ms")) |ts| {
        if (ts != .integer) return error.InvalidPin;
        installed_at = ts.integer;
    }
    const entry_value = value.object.get("entry") orelse return error.InvalidPin;
    const entry = protocol.entryFromValue(arena, entry_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DigestMismatch,
    };
    result.pin = .{
        .gateway_url = gateway.string,
        .token_env = token_env.string,
        .installed_at_ms = installed_at,
        .entry = entry,
    };
    return result;
}

pub const Summary = struct {
    name: []const u8,
    skill_id: []const u8,
    version: []const u8,
    gateway_url: []const u8,
    manifest_digest: []const u8,
    creator: []const u8,
    /// Set when the directory holds a `sealed.json` that fails to verify.
    broken: ?Error = null,
};

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    pins: []const Summary,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Every pin directory under the state root, sorted by name. A missing pin
/// root is an empty listing.
pub fn list(allocator: std.mem.Allocator, state_root: []const u8) Error!Listing {
    var result: Listing = .{ .arena = std.heap.ArenaAllocator.init(allocator), .pins = &.{} };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();
    const root = try pinRoot(arena, state_root);
    const root_z = arena.dupeZ(u8, root) catch return error.OutOfMemory;
    var pins: std.ArrayList(Summary) = .empty;
    var iterator = pdir.open(root_z) orelse {
        result.pins = &.{};
        return result;
    };
    defer pdir.close(&iterator);
    while (pdir.next(&iterator)) |entry| {
        if (!entry.is_dir) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const name = arena.dupe(u8, entry.name) catch return error.OutOfMemory;
        const dir = std.fs.path.join(arena, &.{ root, name }) catch return error.OutOfMemory;
        var parsed = read(arena, dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotFound => continue,
            else => {
                pins.append(arena, .{
                    .name = name,
                    .skill_id = "",
                    .version = "",
                    .gateway_url = "",
                    .manifest_digest = "",
                    .creator = "",
                    .broken = err,
                }) catch return error.OutOfMemory;
                continue;
            },
        };
        // The parsed pin's arena is a child of `arena`; keep it alive by
        // copying the strings we expose and dropping the rest.
        const summary: Summary = .{
            .name = name,
            .skill_id = arena.dupe(u8, parsed.pin.entry.skill_id) catch return error.OutOfMemory,
            .version = arena.dupe(u8, parsed.pin.entry.version) catch return error.OutOfMemory,
            .gateway_url = arena.dupe(u8, parsed.pin.gateway_url) catch return error.OutOfMemory,
            .manifest_digest = arena.dupe(u8, parsed.pin.entry.manifest_digest) catch return error.OutOfMemory,
            .creator = arena.dupe(u8, parsed.pin.entry.manifest.creator_display_name) catch return error.OutOfMemory,
        };
        parsed.deinit();
        pins.append(arena, summary) catch return error.OutOfMemory;
    }
    std.mem.sort(Summary, pins.items, {}, summaryLessThan);
    result.pins = pins.toOwnedSlice(arena) catch return error.OutOfMemory;
    return result;
}

fn summaryLessThan(_: void, lhs: Summary, rhs: Summary) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

fn renderPinJson(allocator: std.mem.Allocator, gateway_url: []const u8, token_env: []const u8, entry_json: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"schema\":\"" ++ PIN_SCHEMA ++ "\",\"gateway\":") catch return error.OutOfMemory;
    protocol.writeString(w, gateway_url) catch return error.OutOfMemory;
    w.writeAll(",\"token_env\":") catch return error.OutOfMemory;
    protocol.writeString(w, token_env) catch return error.OutOfMemory;
    w.print(",\"installed_at_ms\":{d},\"entry\":", .{@as(i64, @intCast(@divTrunc(util_time.nowWallNs(), std.time.ns_per_ms)))}) catch return error.OutOfMemory;
    w.writeAll(entry_json) catch return error.OutOfMemory;
    w.writeAll("}\n") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// The catalog projection of a pin. Every scalar is a YAML double-quoted
/// string so descriptions with colons, hashes or quotes parse unchanged.
pub fn renderSkillMd(allocator: std.mem.Allocator, gateway_url: []const u8, entry: *const protocol.Entry) Error![]u8 {
    const m = &entry.manifest;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    render(w, m, entry, gateway_url) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn render(w: *std.Io.Writer, m: *const protocol.Manifest, entry: *const protocol.Entry, gateway_url: []const u8) !void {
    try w.writeAll("---\n");
    try yamlScalar(w, "name", m.name);
    try yamlScalar(w, "description", m.description);
    if (m.when_to_use.len != 0) try yamlScalar(w, "when_to_use", m.when_to_use);
    if (m.argument_hint.len != 0) try yamlScalar(w, "argument-hint", m.argument_hint);
    if (m.arguments.len != 0) try yamlList(w, "arguments", m.arguments);
    // The frame derived from `allowed-tools` also decides which definitions
    // the fork advertises to its model — here, to the gateway's shadow. A lone
    // `*` is the whole tool set (no key: an unrestricted frame, as a local
    // Skill without the key has); otherwise the list plus `AskUserQuestion`,
    // which every sealed Skill may ask through (§4.3) and which never
    // dispatches through the frame.
    const unrestricted = for (m.tools_allow) |rule| {
        if (std.mem.eql(u8, rule, "*")) break true;
    } else false;
    if (!unrestricted) {
        const asks = for (m.tools_allow) |rule| {
            if (std.mem.eql(u8, rule, ASK_USER_TOOL)) break true;
        } else false;
        try w.writeAll("allowed-tools:\n");
        for (m.tools_allow) |value| {
            try w.writeAll("  - ");
            try yamlQuoted(w, value);
            try w.writeByte('\n');
        }
        if (!asks) try w.writeAll("  - \"" ++ ASK_USER_TOOL ++ "\"\n");
    }
    if (m.tools_deny.len != 0) try yamlList(w, "disallowed-tools", m.tools_deny);
    try w.writeAll("context: fork\n");
    try yamlScalar(w, "sealed-gateway", gateway_url);
    try yamlScalar(w, "sealed-skill-id", entry.skill_id);
    try yamlScalar(w, "sealed-manifest-digest", entry.manifest_digest);
    try w.writeAll("---\n$ARGUMENTS\n");
}

fn yamlScalar(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(": ");
    try yamlQuoted(w, value);
    try w.writeByte('\n');
}

fn yamlList(w: *std.Io.Writer, key: []const u8, values: []const []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(":\n");
    for (values) |value| {
        try w.writeAll("  - ");
        try yamlQuoted(w, value);
        try w.writeByte('\n');
    }
}

/// YAML double-quoted scalar: `\\`, `\"`, and C-style control escapes.
fn yamlQuoted(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try w.print("\\x{x:0>2}", .{byte}),
        else => try w.writeByte(byte),
    };
    try w.writeByte('"');
}

fn writeFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) Error!void {
    const z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.WriteFailed;
    defer pfs.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const n = pfs.write(fd, bytes[written..]);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    const z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(z);
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return error.NotFound;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        out.appendSlice(allocator, chunk[0..@intCast(n)]) catch return error.OutOfMemory;
        if (out.items.len > MAX_PIN_BYTES) return error.InvalidPin;
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

test "pin projection renders quoted frontmatter the definition parser accepts" {
    const a = std.testing.allocator;
    const entry_json = try protocol.testEntryJson(a, protocol.TEST_MANIFEST_JSON);
    defer a.free(entry_json);
    var parsed = try protocol.parseEntry(a, entry_json);
    defer parsed.deinit();
    const md = try renderSkillMd(a, "http://127.0.0.1:1/ssp", &parsed.entry);
    defer a.free(md);
    const definition = @import("../runtime/definition.zig");
    const skill = try definition.parseSkillMdWithFallback(a, md, "", "erp-post");
    defer skill.deinit(a);
    try std.testing.expect(skill.isSealed());
    try std.testing.expectEqual(definition.ExecContext.fork, skill.context);
    try std.testing.expectEqualStrings("erp-post", skill.name);
    try std.testing.expectEqualStrings(parsed.entry.manifest.description, skill.description);
    // The manifest's three rules plus AskUserQuestion, which every sealed
    // Skill may ask through.
    try std.testing.expectEqual(@as(usize, 4), skill.allowed_tools.len);
    try std.testing.expectEqualStrings("Bash(python3 *)", skill.allowed_tools[2]);
    try std.testing.expectEqualStrings(ASK_USER_TOOL, skill.allowed_tools[3]);
    try std.testing.expectEqualStrings("Bash(rm *)", skill.disallowed_tools[0]);
    try std.testing.expectEqualStrings(parsed.entry.manifest_digest, skill.sealed_manifest_digest);
    try std.testing.expectEqualStrings("$ARGUMENTS\n", skill.body);
}

test "pin json round-trips and a tampered manifest is refused" {
    const a = std.testing.allocator;
    const entry_json = try protocol.testEntryJson(a, protocol.TEST_MANIFEST_JSON);
    defer a.free(entry_json);
    const pin_json = try renderPinJson(a, "http://127.0.0.1:1/ssp", DEFAULT_TOKEN_ENV, entry_json);
    defer a.free(pin_json);
    var pin = try parsePin(a, pin_json);
    defer pin.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:1/ssp", pin.pin.gateway_url);
    try std.testing.expectEqualStrings("ssk_test", pin.pin.entry.skill_id);
    try std.testing.expect(pin.pin.installed_at_ms > 0);

    const tampered = try std.mem.replaceOwned(u8, a, pin_json, "\"allow\":[\"Read\"", "\"allow\":[\"Bash\"");
    defer a.free(tampered);
    try std.testing.expect(!std.mem.eql(u8, tampered, pin_json));
    try std.testing.expectError(error.DigestMismatch, parsePin(a, tampered));
}
