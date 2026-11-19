//! The built-in OpenRouter profile's model list: the account's own listing,
//! kept between starts.
//!
//! `GET /api/v1/models/user` with the key lists the models the account can
//! use, filtered by its provider preferences, privacy settings and guardrails
//! (https://openrouter.ai/docs/api/api-reference/models, checked 2026-11-18).
//! Of those, a coding session can use the ones that take tools over chat
//! completions; `trim` keeps those, with the fields a route reads, and the
//! result is what the host ingests (`Host.ingestOpenRouterBuiltin`) and what
//! is kept in `<state root>/cache/models/` (`models_cache.zig`, no key in it).
//!
//! When it is fetched: after a sign-in or a pasted key (both front ends),
//! on `/providers refresh`, and, in the REPL, in the background when the kept
//! copy is missing or a day old and a key is set (a key in `.env` signs in
//! nowhere). A start reads the kept copy whatever its age: a stale list is a
//! far better answer than none, and it is what a stored `/model` default on
//! an OpenRouter model resolves against.

const std = @import("std");
const platform = @import("platform");
const catalog_fetch = @import("catalog_fetch.zig");
const models_cache = @import("models_cache.zig");
const openrouter_login = @import("openrouter_login.zig");
const provider_host = @import("../provider/host.zig");
const provider_profile = @import("../provider/profile.zig");
const openrouter_profile = @import("../provider/profiles/openrouter.zig");
const time = @import("../util/time.zig");
const log = @import("../util/log.zig");

pub const LISTING_PATH = "/api/v1/models/user";

/// A kept listing older than this is fetched again in the background.
pub const STALE_SECONDS: i64 = 24 * std.time.s_per_hour;

/// A start takes the kept listing whatever its age.
const ANY_AGE: i64 = std.math.maxInt(i32);

/// `<origin>/api/v1/models/user`, owned: the profile's origin, or the
/// development override's.
pub fn listingUrl(allocator: std.mem.Allocator) ![]u8 {
    return openrouter_login.address(allocator, openrouter_login.origin(openrouter_profile.KEY_GRANT), LISTING_PATH);
}

/// Where the listing is kept: one copy per address. Not per key: a sign-in
/// with another key fetches and replaces it, and a list from a key the
/// machine had before is still a list of OpenRouter's models.
fn cacheKey(url: []const u8) models_cache.Key {
    return models_cache.Key.of(url, .{ .name = "openrouter-listing", .value = "" });
}

/// The models of `body` a coding session can use — the ones that take tools
/// and are served over chat completions — with the fields a route reads, as
/// a `{"data": [...]}` document. Owned. A model whose `endpoints` (the API
/// paths it serves) leave out chat completions is a batch-only, embedding or
/// image model; one whose `supported_parameters` leave out `tools` cannot run
/// an agent's turn.
pub fn trim(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{}) catch return error.InvalidListing;
    if (root != .object) return error.InvalidListing;
    const data = root.object.get("data") orelse return error.InvalidListing;
    if (data != .array) return error.InvalidListing;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"data\":[");
    var kept: usize = 0;
    for (data.array.items) |item| {
        if (item != .object) continue;
        const model = item.object;
        const id = model.get("id") orelse continue;
        if (id != .string) continue;
        if (!listsString(model.get("supported_parameters"), "tools")) continue;
        if (model.get("endpoints")) |paths| if (paths == .array and !listsString(paths, "/api/v1/chat/completions")) continue;
        if (kept > 0) try w.writeByte(',');
        kept += 1;
        try w.writeByte('{');
        var first = true;
        for ([_][]const u8{ "id", "name", "context_length", "pricing", "supported_parameters" }) |field| {
            const value = model.get(field) orelse continue;
            try writeField(w, &first, field, value);
        }
        if (model.get("top_provider")) |top| if (top == .object) if (top.object.get("max_completion_tokens")) |max| {
            try writeNested(w, &first, "top_provider", "max_completion_tokens", max);
        };
        if (model.get("architecture")) |architecture| if (architecture == .object) if (architecture.object.get("input_modalities")) |modalities| {
            try writeNested(w, &first, "architecture", "input_modalities", modalities);
        };
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    if (kept == 0) return error.NoUsableModels;
    return out.toOwnedSlice();
}

fn writeField(w: *std.Io.Writer, first: *bool, name: []const u8, value: std.json.Value) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(name, .{}, w);
    try w.writeByte(':');
    try std.json.Stringify.value(value, .{}, w);
}

/// `"<outer>":{"<inner>":<value>}`: one field of a nested object.
fn writeNested(w: *std.Io.Writer, first: *bool, outer: []const u8, inner: []const u8, value: std.json.Value) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(outer, .{}, w);
    try w.writeAll(":{");
    try std.json.Stringify.value(inner, .{}, w);
    try w.writeByte(':');
    try std.json.Stringify.value(value, .{}, w);
    try w.writeByte('}');
}

fn listsString(value: ?std.json.Value, wanted: []const u8) bool {
    const list = value orelse return false;
    if (list != .array) return false;
    for (list.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, wanted)) return true;
    }
    return false;
}

/// What a start found kept.
pub const Kept = enum { none, stale, fresh };

/// Ingest the kept listing into `host`, whatever its age, and say how old it
/// is. Nothing kept, or nothing the host takes, leaves its models as they
/// are.
pub fn adoptKept(host: *provider_host.Host, allocator: std.mem.Allocator, state_root: []const u8) Kept {
    const url = listingUrl(allocator) catch return .none;
    defer allocator.free(url);
    const key = cacheKey(url);
    const now = time.nowUnix();
    const kept = models_cache.load(allocator, state_root, key, url, now, ANY_AGE) orelse return .none;
    defer allocator.free(kept);
    _ = host.ingestOpenRouterBuiltin(kept) catch |err| {
        log.debug("catalog", "the kept OpenRouter listing was not taken: {s}", .{@errorName(err)});
        return .none;
    };
    const fresh = models_cache.load(allocator, state_root, key, url, now, STALE_SECONDS);
    defer if (fresh) |copy| allocator.free(copy);
    return if (fresh != null) .fresh else .stale;
}

/// Fetch the account's listing with `key`, keep it trimmed, and, given a
/// host, ingest it there. Returns how many models it lists.
pub fn refresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    key: []const u8,
    host: ?*provider_host.Host,
) !usize {
    const url = try listingUrl(allocator);
    defer allocator.free(url);
    const answer = try catalog_fetch.fetch(allocator, io, .{ .url = url, .bearer = key });
    defer allocator.free(answer.body);
    const trimmed = try trim(allocator, answer.body);
    defer allocator.free(trimmed);
    models_cache.store(allocator, state_root, cacheKey(url), url, trimmed, time.nowUnix()) catch |err| {
        log.debug("catalog", "the OpenRouter listing was not kept: {s}", .{@errorName(err)});
    };
    if (host) |live| return live.ingestOpenRouterBuiltin(trimmed);
    var count_arena = std.heap.ArenaAllocator.init(allocator);
    defer count_arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, count_arena.allocator(), trimmed, .{}) catch return 0;
    return parsed.object.get("data").?.array.items.len;
}

/// One background fetch of the listing, for a start that found none kept or
/// a day-old one. Detached, on copies it owns, `std.heap.c_allocator` and an
/// I/O runtime of its own; it only writes the kept copy, which the REPL takes
/// at an idle point (`App.adoptOpenRouterRefresh`). The session and the
/// thread each hold a reference; the last to let go frees it.
pub const Refresh = struct {
    refs: std.atomic.Value(u8) = .init(2),
    state: std.atomic.Value(State) = .init(.running),
    key: []u8,
    state_root: []u8,

    pub const State = enum(u8) { running, kept, failed };

    const gpa = std.heap.c_allocator;

    pub fn start(key: []const u8, state_root: []const u8) !*Refresh {
        const self = try gpa.create(Refresh);
        errdefer gpa.destroy(self);
        self.* = .{ .key = try gpa.dupe(u8, key), .state_root = undefined };
        errdefer secureFree(self.key);
        self.state_root = try gpa.dupe(u8, state_root);
        errdefer gpa.free(self.state_root);
        const thread = try platform.thread.spawn(.full, run, .{self});
        thread.detach();
        return self;
    }

    pub fn finished(self: *const Refresh) bool {
        return self.state.load(.acquire) != .running;
    }

    /// Whether a new copy was kept.
    pub fn kept(self: *const Refresh) bool {
        return self.state.load(.acquire) == .kept;
    }

    pub fn release(self: *Refresh) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        secureFree(self.key);
        gpa.free(self.state_root);
        gpa.destroy(self);
    }

    fn run(self: *Refresh) void {
        defer self.release();
        var threaded = platform.signal.threadedIo(gpa, .{});
        defer threaded.deinit();
        _ = refresh(gpa, threaded.io(), self.state_root, self.key, null) catch |err| {
            log.debug("catalog", "background OpenRouter listing refresh failed: {s}", .{@errorName(err)});
            self.state.store(.failed, .release);
            return;
        };
        self.state.store(.kept, .release);
    }

    fn secureFree(bytes: []u8) void {
        std.crypto.secureZero(u8, bytes);
        gpa.free(bytes);
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the kept listing holds the models a session can use, with the fields a route reads" {
    const a = testing.allocator;
    const listing =
        \\{"data": [
        \\  {"id": "deepseek/deepseek-v4.1-flash", "name": "DeepSeek: DeepSeek V4.1 Flash", "context_length": 1048576,
        \\   "description": "a long description nobody needs here", "created": 1790000000,
        \\   "top_provider": {"max_completion_tokens": 65536, "is_moderated": false},
        \\   "architecture": {"input_modalities": ["text", "image"], "tokenizer": "Other"},
        \\   "pricing": {"prompt": "0.0000001", "completion": "0.0000004"},
        \\   "supported_parameters": ["tools", "reasoning"],
        \\   "endpoints": ["/api/v1/chat/completions", "/api/v1/messages"]},
        \\  {"id": "openai/gpt-6.2-sol:batch", "supported_parameters": ["tools"], "endpoints": ["/api/v1/batches"]},
        \\  {"id": "some/no-tools", "supported_parameters": ["temperature"], "endpoints": ["/api/v1/chat/completions"]},
        \\  {"id": "older/no-endpoints-field", "supported_parameters": ["tools"]}
        \\]}
    ;
    const trimmed = try trim(a, listing);
    defer a.free(trimmed);
    try testing.expectEqualStrings(
        "{\"data\":[{\"id\":\"deepseek/deepseek-v4.1-flash\",\"name\":\"DeepSeek: DeepSeek V4.1 Flash\",\"context_length\":1048576," ++
            "\"pricing\":{\"prompt\":\"0.0000001\",\"completion\":\"0.0000004\"},\"supported_parameters\":[\"tools\",\"reasoning\"]," ++
            "\"top_provider\":{\"max_completion_tokens\":65536},\"architecture\":{\"input_modalities\":[\"text\",\"image\"]}}," ++
            "{\"id\":\"older/no-endpoints-field\",\"supported_parameters\":[\"tools\"]}]}",
        trimmed,
    );
    try testing.expectError(error.NoUsableModels, trim(a, "{\"data\": [{\"id\": \"x\", \"supported_parameters\": []}]}"));
    try testing.expectError(error.InvalidListing, trim(a, "<html></html>"));
}
