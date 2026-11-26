//! Provider-scoped API keys at rest.
//!
//! `<state_root>/keys/<provider>.json`, mode 0600, written atomically like an
//! OAuth login (`oauth.writeAtomicPrivate`). One file per provider is the
//! scope: the resolver is handed a provider's own file and nothing else, so a
//! key stored for one vendor cannot satisfy another. `config.json` stays free
//! of secrets — it may only name environment variables.
//!
//! ```json
//! {"schema_version":1,"kind":"zai_coding_plan_api_key","key":"…","page":"cn-personal","stored_at":1793000000}
//! ```
//!
//! A key a provider's own sign-in handed back (OpenRouter's key grant) also
//! says so, and what the provider said about it then — none of it secret:
//!
//! ```json
//! {"schema_version":1,"kind":"api_key","key":"…","obtained":"browser_sign_in","described":true,
//!  "label":"sk-or-v1-0e6...1c96","limit_usd":null,"expires_at":null,"free_tier":false,"stored_at":1795000000}
//! ```
//!
//! A build that predates these fields reads such a file the same way: `load`
//! takes the fields it knows and ignores the rest.

const std = @import("std");
const ids = @import("ids.zig");
const credential = @import("credential.zig");
const oauth = @import("oauth.zig");
const pfs = @import("platform").fs;

const Slug = ids.Slug;

pub const SCHEMA_VERSION: u32 = 1;

pub const LoadError = error{ OutOfMemory, InvalidKeyFile, ReadFailed };

/// How a key came to be stored.
pub const Obtained = enum {
    /// The provider's own sign-in created it (`ProviderProfile.key_grant`).
    browser_sign_in,
    /// The user pasted it.
    pasted,
};

/// What is known about a stored key besides the key: where it came from and
/// what the provider said about it when it was stored. Nothing here is a
/// secret. Borrowed when saving; owned by `Stored` when loaded.
pub const Meta = struct {
    obtained: ?Obtained = null,
    /// The provider was asked about the key (`KeyGrant.key_info_path`) and
    /// answered: a null `limit_usd` or `expires_at` then means "none", not
    /// "unknown".
    described: bool = false,
    /// What the provider calls the key: for OpenRouter, the short form of
    /// the key (`sk-or-v1-0e6...1c96`), the line under the key's name on its
    /// keys page. The name itself is not given.
    label: ?[]const u8 = null,
    /// Its spending limit in US dollars.
    limit_usd: ?f64 = null,
    /// When it stops working (ISO 8601, as the provider wrote it).
    expires_at: ?[]const u8 = null,
    /// The account has no paid credits: only free models answer.
    free_tier: ?bool = null,
};

/// A stored key, owned. `deinit` zeroes the secret before freeing it.
pub const Stored = struct {
    allocator: std.mem.Allocator,
    kind: credential.CredentialKind,
    secret: []u8,
    /// The key page it was created on (`KeyPage.id`), when known.
    page: ?[]u8 = null,
    /// Owned strings (`label`, `expires_at`), freed by `deinit`.
    meta: Meta = .{},
    /// When it was stored (unix seconds), when the file says.
    stored_at: ?i64 = null,

    pub fn deinit(self: *Stored) void {
        oauth.secureFree(self.allocator, self.secret);
        if (self.page) |page| self.allocator.free(page);
        if (self.meta.label) |text| self.allocator.free(text);
        if (self.meta.expires_at) |text| self.allocator.free(text);
        self.* = undefined;
    }

    /// The resolver's view: borrowed, valid while `self` is.
    pub fn entry(self: *const Stored) credential.StoredEntry {
        return .{ .kind = self.kind, .secret = self.secret };
    }
};

/// Where `provider_id`'s key lives (owned).
pub fn pathFor(allocator: std.mem.Allocator, state_root: []const u8, provider_id: Slug) error{ OutOfMemory, NoHome }![]u8 {
    if (state_root.len == 0) return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/keys/{s}.json", .{ state_root, provider_id.slice() });
}

pub fn save(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    provider_id: Slug,
    kind: credential.CredentialKind,
    secret: []const u8,
    page: ?[]const u8,
    now_seconds: i64,
) !void {
    return saveWithMeta(allocator, state_root, provider_id, kind, secret, page, .{}, now_seconds);
}

/// `save`, recording what is known about the key besides the key (`Meta`).
pub fn saveWithMeta(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    provider_id: Slug,
    kind: credential.CredentialKind,
    secret: []const u8,
    page: ?[]const u8,
    meta: Meta,
    now_seconds: i64,
) !void {
    if (secret.len == 0) return error.EmptyKey;
    const path = try pathFor(allocator, state_root, provider_id);
    defer allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    // The document holds the key: zero it whatever happens to the write.
    defer {
        std.crypto.secureZero(u8, out.writer.buffer[0..out.writer.end]);
        out.deinit();
    }
    const w = &out.writer;
    try w.print("{{\"schema_version\":{d},\"kind\":", .{SCHEMA_VERSION});
    try std.json.Stringify.value(kind.id(), .{}, w);
    try w.writeAll(",\"key\":");
    try std.json.Stringify.value(secret, .{}, w);
    if (page) |value| {
        try w.writeAll(",\"page\":");
        try std.json.Stringify.value(value, .{}, w);
    }
    if (meta.obtained) |obtained| {
        try w.writeAll(",\"obtained\":");
        try std.json.Stringify.value(@tagName(obtained), .{}, w);
    }
    if (meta.described) {
        // Written only when the provider answered, so "none" and "unknown"
        // stay apart: an undescribed key carries none of these.
        try w.writeAll(",\"described\":true,\"label\":");
        try std.json.Stringify.value(meta.label, .{}, w);
        try w.writeAll(",\"limit_usd\":");
        try std.json.Stringify.value(meta.limit_usd, .{}, w);
        try w.writeAll(",\"expires_at\":");
        try std.json.Stringify.value(meta.expires_at, .{}, w);
        try w.writeAll(",\"free_tier\":");
        try std.json.Stringify.value(meta.free_tier, .{}, w);
    }
    try w.print(",\"stored_at\":{d}}}\n", .{now_seconds});
    try oauth.writeAtomicPrivate(allocator, path, out.writer.buffer[0..out.writer.end]);
}

/// `provider_id`'s stored key, or null when none is stored. A file that does
/// not parse, carries a newer schema, or names a kind this build does not know
/// is an error rather than "no key": the user stored something and should
/// hear that it cannot be used.
pub fn load(allocator: std.mem.Allocator, state_root: []const u8, provider_id: Slug) LoadError!?Stored {
    const path = pathFor(allocator, state_root, provider_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoHome => return null,
    };
    defer allocator.free(path);
    const bytes = oauth.readFile(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Classified right after the failed open, before anything else can
        // set errno.
        error.OpenFailed => return if (pfs.lastErrnoIs(.NOENT)) null else error.ReadFailed,
        else => return error.ReadFailed,
    };
    defer oauth.secureFree(allocator, bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidKeyFile,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidKeyFile;
    const object = parsed.value.object;
    const version = object.get("schema_version") orelse return error.InvalidKeyFile;
    if (version != .integer or version.integer != SCHEMA_VERSION) return error.InvalidKeyFile;
    const kind_text = stringOf(object.get("kind")) orelse return error.InvalidKeyFile;
    const kind = credential.CredentialKind.parse(kind_text) orelse return error.InvalidKeyFile;
    const key = stringOf(object.get("key")) orelse return error.InvalidKeyFile;
    if (key.len == 0) return error.InvalidKeyFile;

    const secret = try allocator.dupe(u8, key);
    errdefer oauth.secureFree(allocator, secret);
    const page = if (stringOf(object.get("page"))) |text| try allocator.dupe(u8, text) else null;
    errdefer if (page) |text| allocator.free(text);
    var meta: Meta = .{};
    if (stringOf(object.get("obtained"))) |text| meta.obtained = std.meta.stringToEnum(Obtained, text);
    if (object.get("described")) |value| meta.described = value == .bool and value.bool;
    if (meta.described) {
        if (stringOf(object.get("label"))) |text| meta.label = try allocator.dupe(u8, text);
        errdefer if (meta.label) |text| allocator.free(text);
        if (stringOf(object.get("expires_at"))) |text| meta.expires_at = try allocator.dupe(u8, text);
        meta.limit_usd = numberOf(object.get("limit_usd"));
        if (object.get("free_tier")) |value| meta.free_tier = if (value == .bool) value.bool else null;
    }
    // The parse tree held the key too.
    zeroStrings(parsed.value);
    const stored_at: ?i64 = if (object.get("stored_at")) |value| (if (value == .integer) value.integer else null) else null;
    return .{ .allocator = allocator, .kind = kind, .secret = secret, .page = page, .meta = meta, .stored_at = stored_at };
}

fn numberOf(value: ?std.json.Value) ?f64 {
    const found = value orelse return null;
    return switch (found) {
        .float => |number| if (std.math.isFinite(number)) number else null,
        .integer => |number| @floatFromInt(number),
        else => null,
    };
}

/// Forget `provider_id`'s key. True when one was removed.
pub fn remove(allocator: std.mem.Allocator, state_root: []const u8, provider_id: Slug) !bool {
    const path = pathFor(allocator, state_root, provider_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoHome => return false,
    };
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (!pfs.exists(path_z)) return false;
    pfs.unlinkPath(path_z) catch return error.RemoveFailed;
    return true;
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn zeroStrings(value: std.json.Value) void {
    switch (value) {
        .string => |text| std.crypto.secureZero(u8, @constCast(text)),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |pair| zeroStrings(pair.value_ptr.*);
        },
        .array => |array| for (array.items) |item| zeroStrings(item),
        else => {},
    }
}

const testing = std.testing;

fn testRoot(buffer: []u8, tmp: *std.testing.TmpDir) ![]const u8 {
    return buffer[0..try tmp.dir.realPath(std.testing.io, buffer)];
}

test "a stored key round-trips with its kind and page, in a private file" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try testRoot(&root_buf, &tmp);
    const zai = Slug.lit("zai-coding-plan");

    try testing.expect(try load(a, root, zai) == null);
    try save(a, root, zai, .zai_coding_plan_api_key, "plan-key-123", "cn-personal", 1_793_000_000);
    var stored = (try load(a, root, zai)).?;
    defer stored.deinit();
    try testing.expectEqual(credential.CredentialKind.zai_coding_plan_api_key, stored.kind);
    try testing.expectEqualStrings("plan-key-123", stored.secret);
    try testing.expectEqualStrings("cn-personal", stored.page.?);
    try testing.expectEqualStrings("plan-key-123", stored.entry().secret);

    // Another provider sees none of it.
    try testing.expect(try load(a, root, Slug.lit("openai")) == null);

    if (@import("builtin").os.tag != .windows) {
        const path = try pathFor(a, root, zai);
        defer a.free(path);
        const path_z = try a.dupeZ(u8, path);
        defer a.free(path_z);
        const fd = try pfs.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0);
        defer pfs.close(fd);
        const info = try pfs.fileInfo(fd);
        try testing.expectEqual(@as(u32, 0o600), info.mode & 0o777);
    }

    try testing.expect(try remove(a, root, zai));
    try testing.expect(try load(a, root, zai) == null);
    try testing.expect(!try remove(a, root, zai));
}

test "what a sign-in learned about a key round-trips beside it; a pasted key carries none of it" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try testRoot(&root_buf, &tmp);
    const openrouter = Slug.lit("openrouter");

    try saveWithMeta(a, root, openrouter, .api_key, "sk-or-v1-abc", null, .{
        .obtained = .browser_sign_in,
        .described = true,
        .label = "metacodes",
        .limit_usd = 25.5,
        .expires_at = "2027-02-16T00:00:00Z",
        .free_tier = false,
    }, 1_795_000_000);
    {
        var stored = (try load(a, root, openrouter)).?;
        defer stored.deinit();
        try testing.expectEqualStrings("sk-or-v1-abc", stored.secret);
        try testing.expectEqual(Obtained.browser_sign_in, stored.meta.obtained.?);
        try testing.expect(stored.meta.described);
        try testing.expectEqualStrings("metacodes", stored.meta.label.?);
        try testing.expectEqual(@as(f64, 25.5), stored.meta.limit_usd.?);
        try testing.expectEqualStrings("2027-02-16T00:00:00Z", stored.meta.expires_at.?);
        try testing.expectEqual(false, stored.meta.free_tier.?);
        try testing.expectEqual(@as(i64, 1_795_000_000), stored.stored_at.?);
    }

    // Described with no limit and no expiry: both null, and still described.
    try saveWithMeta(a, root, openrouter, .api_key, "sk-or-v1-def", null, .{ .obtained = .browser_sign_in, .described = true, .label = "metacodes" }, 1);
    {
        var stored = (try load(a, root, openrouter)).?;
        defer stored.deinit();
        try testing.expect(stored.meta.described);
        try testing.expect(stored.meta.limit_usd == null and stored.meta.expires_at == null);
    }

    // `save` writes none of these fields: what an older file looks like.
    try save(a, root, openrouter, .api_key, "sk-or-v1-ghi", "keys", 1);
    {
        var stored = (try load(a, root, openrouter)).?;
        defer stored.deinit();
        try testing.expect(stored.meta.obtained == null and !stored.meta.described and stored.meta.label == null);
        const path = try pathFor(a, root, openrouter);
        defer a.free(path);
        const text = try tmp.dir.readFileAlloc(std.testing.io, "keys/openrouter.json", a, .limited(4096));
        defer a.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "described") == null);
    }
}

test "a stored file that cannot be used is an error, not a missing key" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try testRoot(&root_buf, &tmp);
    try tmp.dir.createDirPath(std.testing.io, "keys");
    for ([_][]const u8{
        "not json",
        "{\"schema_version\":2,\"kind\":\"api_key\",\"key\":\"k\"}",
        "{\"schema_version\":1,\"kind\":\"martian_key\",\"key\":\"k\"}",
        "{\"schema_version\":1,\"kind\":\"api_key\",\"key\":\"\"}",
    }) |document| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keys/openai.json", .data = document });
        try testing.expectError(error.InvalidKeyFile, load(a, root, Slug.lit("openai")));
    }
}
