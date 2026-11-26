//! Local bindings for sealed-Skill credential references
//! (doc/SEALED_SKILL_PROTOCOL.md §6.4).
//!
//! A manifest declares references (`erp-main`); the user binds each one to a
//! secret on this machine. The binding is scoped to the Skill that declared
//! it (`skill_id` + `ref`), so a second Skill that names the same reference
//! gets nothing until the user binds it for that Skill too: a reference is a
//! consent, not a shared variable.
//!
//! Bindings live in `<state root>/sealed-credentials.json` with mode 0600,
//! not inside `auth.json`: every writer of `auth.json` rebuilds the whole
//! document from `StoredCredentials` (an OAuth refresh does so without user
//! involvement), and a section those writers do not know would be dropped by
//! the first refresh. A file of its own has one writer, this module.
//!
//! The provider loads the file once per run into a `Store`; `lookup` hands
//! out borrowed secrets, `deinit` zeroes them.

const std = @import("std");
const pfs = @import("platform").fs;
const util_fs = @import("metacodes-base").util.fs;
const util_time = @import("metacodes-base").util.time;
const auth = @import("metacodes-ai").core.auth;

pub const FILE_NAME = "sealed-credentials.json";
pub const SCHEMA = "metacodes.sealed-credentials/v1";
/// The placeholder a gateway writes into a call's input (§6.4): `${SEALED_CRED:<ref>}`.
pub const PLACEHOLDER_PREFIX = "${SEALED_CRED:";
pub const PLACEHOLDER_SUFFIX = "}";
pub const MAX_FILE_BYTES: usize = 1024 * 1024;
pub const MAX_SECRET_BYTES: usize = 16 * 1024;

pub const Error = error{
    OutOfMemory,
    NoStateRoot,
    InvalidRef,
    InvalidSecret,
    ReadFailed,
    WriteFailed,
    /// The file exists but is not a document this module wrote.
    InvalidFile,
};

pub const Binding = struct {
    skill_id: []const u8,
    ref: []const u8,
    secret: []const u8,
    bound_at_ms: i64,
};

/// Every binding of the state root, in memory. Secrets are zeroed on `deinit`.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []const Binding = &.{},

    pub fn empty(allocator: std.mem.Allocator) Store {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        for (self.bindings) |binding| @memset(@constCast(binding.secret), 0);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The secret bound to `ref` for `skill_id`, borrowed from the store.
    pub fn lookup(self: *const Store, skill_id: []const u8, ref: []const u8) ?[]const u8 {
        for (self.bindings) |binding| {
            if (std.mem.eql(u8, binding.skill_id, skill_id) and std.mem.eql(u8, binding.ref, ref)) return binding.secret;
        }
        return null;
    }

    pub fn isBound(self: *const Store, skill_id: []const u8, ref: []const u8) bool {
        return self.lookup(skill_id, ref) != null;
    }
};

/// `<state root>/sealed-credentials.json`.
pub fn filePath(allocator: std.mem.Allocator, state_root: []const u8) Error![]u8 {
    if (state_root.len == 0) return error.NoStateRoot;
    return std.fs.path.join(allocator, &.{ state_root, FILE_NAME }) catch return error.OutOfMemory;
}

/// Load every binding under `state_root`. A missing file, or an empty state
/// root, is an empty store; a file this module cannot parse is `InvalidFile`
/// (never silently treated as "nothing bound", which would make a corrupted
/// file indistinguishable from an unbound reference).
pub fn load(allocator: std.mem.Allocator, state_root: []const u8) Error!Store {
    var store = Store.empty(allocator);
    errdefer store.deinit();
    if (state_root.len == 0) return store;
    const path = try filePath(allocator, state_root);
    defer allocator.free(path);
    const bytes = readFile(allocator, path) catch |err| switch (err) {
        error.NotFound => return store,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    defer auth.secureFree(allocator, bytes);
    store.bindings = try parseBindings(store.arena.allocator(), bytes);
    return store;
}

/// Bind (or rebind) `ref` for `skill_id` to `secret`. The file is rewritten
/// in full with mode 0600.
pub fn bind(allocator: std.mem.Allocator, state_root: []const u8, skill_id: []const u8, ref: []const u8, secret: []const u8) Error!void {
    if (!validRef(ref)) return error.InvalidRef;
    if (secret.len == 0 or secret.len > MAX_SECRET_BYTES) return error.InvalidSecret;
    var store = try load(allocator, state_root);
    defer store.deinit();
    const scratch = store.arena.allocator();
    var next: std.ArrayList(Binding) = .empty;
    for (store.bindings) |binding| {
        if (std.mem.eql(u8, binding.skill_id, skill_id) and std.mem.eql(u8, binding.ref, ref)) continue;
        next.append(scratch, binding) catch return error.OutOfMemory;
    }
    next.append(scratch, .{
        .skill_id = skill_id,
        .ref = ref,
        .secret = secret,
        .bound_at_ms = @intCast(@divTrunc(util_time.nowWallNs(), std.time.ns_per_ms)),
    }) catch return error.OutOfMemory;
    try writeBindings(allocator, state_root, next.items);
}

/// Remove the binding; returns whether one existed.
pub fn unbind(allocator: std.mem.Allocator, state_root: []const u8, skill_id: []const u8, ref: []const u8) Error!bool {
    var store = try load(allocator, state_root);
    defer store.deinit();
    const scratch = store.arena.allocator();
    var next: std.ArrayList(Binding) = .empty;
    var removed = false;
    for (store.bindings) |binding| {
        if (std.mem.eql(u8, binding.skill_id, skill_id) and std.mem.eql(u8, binding.ref, ref)) {
            removed = true;
            continue;
        }
        next.append(scratch, binding) catch return error.OutOfMemory;
    }
    if (removed) try writeBindings(allocator, state_root, next.items);
    return removed;
}

/// A reference is a short token: letters, digits, `-`, `_`, `.`; it is written
/// into placeholders and shell-visible hints, so nothing else is accepted.
pub fn validRef(ref: []const u8) bool {
    if (ref.len == 0 or ref.len > 64) return false;
    for (ref) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

/// `${SEALED_CRED:<ref>}` for `ref`, in `allocator`.
pub fn placeholder(allocator: std.mem.Allocator, ref: []const u8) error{OutOfMemory}![]u8 {
    return std.mem.concat(allocator, u8, &.{ PLACEHOLDER_PREFIX, ref, PLACEHOLDER_SUFFIX });
}

/// Every distinct reference named by a placeholder in `text`, in order of
/// first appearance; only syntactically valid references count.
pub fn placeholderRefs(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer refs.deinit(allocator);
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, PLACEHOLDER_PREFIX)) |start| {
        const name_start = start + PLACEHOLDER_PREFIX.len;
        const end = std.mem.indexOfPos(u8, text, name_start, PLACEHOLDER_SUFFIX) orelse break;
        const ref = text[name_start..end];
        index = end + 1;
        if (!validRef(ref)) continue;
        var seen = false;
        for (refs.items) |known| if (std.mem.eql(u8, known, ref)) {
            seen = true;
        };
        if (!seen) try refs.append(allocator, ref);
    }
    return refs.toOwnedSlice(allocator);
}

/// `text` with every occurrence of `needle` replaced by `replacement`.
pub fn replaceAll(allocator: std.mem.Allocator, text: []const u8, needle: []const u8, replacement: []const u8) error{OutOfMemory}![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, text);
    return std.mem.replaceOwned(u8, allocator, text, needle, replacement);
}

/// `secret` as the body of a JSON string (no quotes), so that it can replace a
/// placeholder inside serialized JSON without breaking the document.
pub fn jsonEscaped(allocator: std.mem.Allocator, secret: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    std.json.Stringify.value(secret, .{}, &out.writer) catch return error.OutOfMemory;
    const quoted = out.written();
    const body = quoted[1 .. quoted.len - 1];
    const owned = try allocator.dupe(u8, body);
    out.deinit();
    return owned;
}

// ── File format ───────────────────────────────────────────────────────────

fn parseBindings(arena: std.mem.Allocator, bytes: []const u8) Error![]const Binding {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFile,
    };
    if (parsed != .object) return error.InvalidFile;
    const schema = parsed.object.get("schema") orelse return error.InvalidFile;
    if (schema != .string or !std.mem.eql(u8, schema.string, SCHEMA)) return error.InvalidFile;
    const list = parsed.object.get("bindings") orelse return error.InvalidFile;
    if (list != .array) return error.InvalidFile;
    const out = arena.alloc(Binding, list.array.items.len) catch return error.OutOfMemory;
    for (list.array.items, out) |item, *slot| {
        if (item != .object) return error.InvalidFile;
        const skill_id = item.object.get("skill_id") orelse return error.InvalidFile;
        const ref = item.object.get("ref") orelse return error.InvalidFile;
        const secret = item.object.get("secret") orelse return error.InvalidFile;
        if (skill_id != .string or ref != .string or secret != .string) return error.InvalidFile;
        if (!validRef(ref.string)) return error.InvalidFile;
        var bound_at: i64 = 0;
        if (item.object.get("bound_at_ms")) |v| if (v == .integer) {
            bound_at = v.integer;
        };
        slot.* = .{
            .skill_id = skill_id.string,
            .ref = ref.string,
            .secret = secret.string,
            .bound_at_ms = bound_at,
        };
    }
    return out;
}

fn writeBindings(allocator: std.mem.Allocator, state_root: []const u8, bindings: []const Binding) Error!void {
    const path = try filePath(allocator, state_root);
    defer allocator.free(path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer {
        @memset(out.written(), 0);
        out.deinit();
    }
    const w = &out.writer;
    w.writeAll("{\"schema\":\"" ++ SCHEMA ++ "\",\"bindings\":[") catch return error.OutOfMemory;
    for (bindings, 0..) |binding, index| {
        if (index != 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("{\"skill_id\":") catch return error.OutOfMemory;
        writeString(w, binding.skill_id) catch return error.OutOfMemory;
        w.writeAll(",\"ref\":") catch return error.OutOfMemory;
        writeString(w, binding.ref) catch return error.OutOfMemory;
        w.writeAll(",\"secret\":") catch return error.OutOfMemory;
        writeString(w, binding.secret) catch return error.OutOfMemory;
        w.print(",\"bound_at_ms\":{d}}}", .{binding.bound_at_ms}) catch return error.OutOfMemory;
    }
    w.writeAll("]}\n") catch return error.OutOfMemory;

    util_fs.mkdirParents(state_root) catch return error.WriteFailed;
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.WriteFailed;
    defer _ = pfs.close(fd);
    _ = pfs.chmod(path_z.ptr, 0o600);
    const bytes = out.written();
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pfs.write(fd, bytes[pos..]);
        if (n <= 0) return error.WriteFailed;
        pos += @intCast(n);
    }
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.NotFound;
    defer _ = pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer {
        @memset(out.items, 0);
        out.deinit(allocator);
    }
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
        if (out.items.len > MAX_FILE_BYTES) return error.TooLarge;
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "placeholders: refs are extracted once each, invalid names skipped" {
    const a = std.testing.allocator;
    const refs = try placeholderRefs(a, "x=${SEALED_CRED:erp-main} y=${SEALED_CRED:erp-main} z=${SEALED_CRED:bad name} w=${SEALED_CRED:second}");
    defer a.free(refs);
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("erp-main", refs[0]);
    try std.testing.expectEqualStrings("second", refs[1]);
    const none = try placeholderRefs(a, "no placeholders ${SEALED_CRED:unterminated");
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "jsonEscaped keeps a secret valid inside a JSON string" {
    const a = std.testing.allocator;
    const escaped = try jsonEscaped(a, "p\"w\\d\n");
    defer a.free(escaped);
    try std.testing.expectEqualStrings("p\\\"w\\\\d\\n", escaped);
}

test "bind, load, lookup and unbind round trip through the 0600 file" {
    const a = std.testing.allocator;
    var root_buf: [512]u8 = undefined;
    const root = util_fs.testing.perPidDir(&root_buf, "cc-zig-sealed-cred");
    defer util_fs.testing.rmrfBestEffort(root);
    try util_fs.mkdirParents(root);

    var missing = try load(a, root);
    try std.testing.expectEqual(@as(usize, 0), missing.bindings.len);
    missing.deinit();

    try bind(a, root, "ssk_a", "erp-main", "s3cr3t");
    try bind(a, root, "ssk_b", "erp-main", "other");
    try bind(a, root, "ssk_a", "erp-main", "s3cr3t-v2");
    var store = try load(a, root);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 2), store.bindings.len);
    try std.testing.expectEqualStrings("s3cr3t-v2", store.lookup("ssk_a", "erp-main").?);
    try std.testing.expectEqualStrings("other", store.lookup("ssk_b", "erp-main").?);
    try std.testing.expect(store.lookup("ssk_c", "erp-main") == null);
    try std.testing.expect(store.lookup("ssk_a", "ldap") == null);

    try std.testing.expect(try unbind(a, root, "ssk_a", "erp-main"));
    try std.testing.expect(!(try unbind(a, root, "ssk_a", "erp-main")));
    var after = try load(a, root);
    defer after.deinit();
    try std.testing.expect(after.lookup("ssk_a", "erp-main") == null);
    try std.testing.expect(after.lookup("ssk_b", "erp-main") != null);

    try std.testing.expectError(error.InvalidRef, bind(a, root, "ssk_a", "bad ref", "x"));
    try std.testing.expectError(error.InvalidSecret, bind(a, root, "ssk_a", "ok", ""));
}
