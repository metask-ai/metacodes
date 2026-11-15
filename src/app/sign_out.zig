//! Signing out of Metask (#485, #499 part 2): both of its sign-ins, and the
//! remembered default when that is Metask's.
//!
//! Metask has two sign-ins that reach the same account: the browser one
//! (`metacodes login`, `/login`), stored in `<state root>/auth.json`, and the
//! device-code one (`metacodes login --provider metask`), stored in
//! `<state root>/oauth/metask.json` with its refresh token. Signing out
//! removes both, so no Metask credential stays on the machine; the CLI's
//! `metacodes logout` and the TUI's `/logout` share this.
//!
//! A stored `/model` default that resolves to Metask is forgotten with them:
//! the next plain start would otherwise try Metask without a sign-in. Keys of
//! other providers (`.env`, `keys/<provider>.json`) are not Metask's and are
//! never touched here.

const std = @import("std");
const pfs = @import("platform").fs;
const auth = @import("../core/auth.zig");
const provider_oauth = @import("../provider/oauth.zig");
const provider_ids = @import("../provider/ids.zig");
const config_store = @import("../provider/config_store.zig");
const selection_mod = @import("../provider/selection.zig");
const registry_mod = @import("../provider/registry.zig");

/// What was on disk and is gone.
pub const Removed = struct {
    /// `<state root>/auth.json` (or `METACODES_AUTH_FILE`): the browser sign-in.
    browser: bool = false,
    /// `<state root>/oauth/metask.json` (or `METACODES_OAUTH_DIR`): the
    /// device-code sign-in and its refresh token.
    device: bool = false,

    pub fn any(self: Removed) bool {
        return self.browser or self.device;
    }
};

pub const Error = error{ OutOfMemory, RemoveFailed };

/// Delete both Metask sign-ins. One that is not there is not an error.
pub fn removeMetaskSignIns(allocator: std.mem.Allocator, state_root: []const u8) Error!Removed {
    var removed: Removed = .{};
    browser: {
        const path = auth.authFilePath(allocator, state_root) catch |err| switch (err) {
            error.NoHome => break :browser,
            else => return error.OutOfMemory,
        };
        defer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        if (!pfs.exists(path_z)) break :browser;
        auth.clearDefault(allocator, state_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RemoveFailed,
        };
        removed.browser = true;
    }
    removed.device = try provider_oauth.Session.removeStored(allocator, state_root, provider_ids.Slug.lit("metask"));
    return removed;
}

/// Whether `selection` resolves, in `catalog`, to a Metask route. One that
/// does not resolve is not known to be Metask's.
pub fn isMetaskSelection(catalog: *const registry_mod.OfferCatalog, selection: selection_mod.RuntimeSelection) bool {
    const resolution = selection_mod.resolve(catalog, selection) catch return false;
    return resolution.primary().provider_id.eqlText("metask");
}

/// Forget `config.json`'s global selection when it is Metask's (resolved in
/// `catalog`). True when one was forgotten.
pub fn clearMetaskDefault(allocator: std.mem.Allocator, state_root: []const u8, catalog: *const registry_mod.OfferCatalog) config_store.StoreError!bool {
    var store = config_store.Store.initHome(allocator, state_root) catch |err| switch (err) {
        error.NoHome => return false,
        else => return err,
    };
    defer store.deinit();
    var document = store.load() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A config.json that cannot be read holds no default to forget here;
        // the start that reads it reports it.
        else => return false,
    };
    defer document.deinit();
    const selection = document.global_selection orelse return false;
    if (!isMetaskSelection(catalog, selection)) return false;
    return (try config_store.clearGlobalSelection(&store, null)).cleared;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "signing out removes both Metask sign-ins and says which were there" {
    // Either variable would point the removal at the developer's own files.
    if (std.c.getenv(auth.AUTH_FILE_ENV) != null or std.c.getenv("METACODES_OAUTH_DIR") != null) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    // Nothing stored: nothing removed, no error.
    try testing.expect(!(try removeMetaskSignIns(a, root)).any());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth.json", .data = "{\"api_key\":\"k\"}" });
    try tmp.dir.createDirPath(testing.io, "oauth");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "oauth/metask.json", .data = "{}" });
    // Another provider's login is not Metask's.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "oauth/openai.json", .data = "{}" });
    const removed = try removeMetaskSignIns(a, root);
    try testing.expect(removed.browser and removed.device);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "auth.json", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "oauth/metask.json", .{}));
    try tmp.dir.access(testing.io, "oauth/openai.json", .{});

    // Only the device sign-in.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "oauth/metask.json", .data = "{}" });
    const device_only = try removeMetaskSignIns(a, root);
    try testing.expect(!device_only.browser and device_only.device);
}
