//! API key catalog for OAuth-backed model selection.
//!
//! `/models` first shows the current account's API keys, then uses the chosen
//! key to query `/v1/models`. The endpoint is Metask-specific, so the URL is
//! env-overridable while the parser accepts a few common response shapes.

const std = @import("std");
const ResponseStatus = @import("http_status.zig").ResponseStatus;

pub const API_KEYS_URL_ENV = "METACODE_API_KEYS_URL";

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        id: []u8,
        label: []u8,
        group: []u8,
        secret: []u8,
        suffix: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *Catalog) void {
        self.clear();
        self.entries.deinit(self.allocator);
    }

    pub fn clear(self: *Catalog) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.id);
            self.allocator.free(e.label);
            self.allocator.free(e.group);
            secureFree(self.allocator, e.secret);
            self.allocator.free(e.suffix);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn loadFromJson(self: *Catalog, body: []const u8) !void {
        self.clear();
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const arr = findArray(parsed.value) orelse return;
        for (arr.items, 0..) |item, i| {
            if (item != .object) continue;
            if (!isUsableStatus(item)) continue;
            const secret = stringField(item, &.{ "api_key", "key", "token", "secret", "value" }) orelse continue;
            if (secret.len == 0) continue;
            const id_raw = stringField(item, &.{ "id", "uuid", "name", "label" }) orelse secret;
            const label_raw = stringField(item, &.{ "name", "label", "display_name", "id" }) orelse id_raw;
            const group_raw = groupField(item) orelse "";

            const id = try self.allocator.dupe(u8, id_raw);
            errdefer self.allocator.free(id);
            const label = try self.allocator.dupe(u8, label_raw);
            errdefer self.allocator.free(label);
            const group = try self.allocator.dupe(u8, group_raw);
            errdefer self.allocator.free(group);
            const secret_owned = try self.allocator.dupe(u8, secret);
            errdefer secureFree(self.allocator, secret_owned);
            const suffix = try suffixFor(self.allocator, secret, i);
            errdefer self.allocator.free(suffix);

            try self.entries.append(self.allocator, .{
                .id = id,
                .label = label,
                .group = group,
                .secret = secret_owned,
                .suffix = suffix,
            });
        }
    }

    pub fn addCurrentKeyFallback(self: *Catalog, secret: []const u8) !void {
        if (secret.len == 0) return;
        const id = try self.allocator.dupe(u8, "current");
        errdefer self.allocator.free(id);
        const label = try self.allocator.dupe(u8, "Current API key");
        errdefer self.allocator.free(label);
        const group = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(group);
        const secret_owned = try self.allocator.dupe(u8, secret);
        errdefer secureFree(self.allocator, secret_owned);
        const suffix = try suffixFor(self.allocator, secret, 0);
        errdefer self.allocator.free(suffix);
        try self.entries.append(self.allocator, .{
            .id = id,
            .label = label,
            .group = group,
            .secret = secret_owned,
            .suffix = suffix,
        });
    }
};

fn findArray(v: std.json.Value) ?std.json.Array {
    switch (v) {
        .array => |a| return a,
        .object => |o| {
            for ([_][]const u8{ "data", "api_keys", "keys" }) |name| {
                if (o.get(name)) |field| {
                    if (field == .array) return field.array;
                    if (field == .object) {
                        if (field.object.get("items")) |items| {
                            if (items == .array) return items.array;
                        }
                    }
                }
            }
            if (o.get("items")) |items| {
                if (items == .array) return items.array;
            }
            return null;
        },
        else => return null,
    }
}

fn stringField(v: std.json.Value, names: []const []const u8) ?[]const u8 {
    if (v != .object) return null;
    for (names) |name| {
        if (v.object.get(name)) |field| {
            if (field == .string) return field.string;
        }
    }
    return null;
}

fn groupField(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    if (stringField(v, &.{ "group_name", "model_group", "profile", "team" })) |s| return s;
    if (v.object.get("group")) |field| {
        if (field == .string) return field.string;
        if (field == .object) {
            if (stringField(field, &.{ "name", "label", "display_name", "id" })) |s| return s;
        }
    }
    return null;
}

fn isUsableStatus(v: std.json.Value) bool {
    const status = stringField(v, &.{"status"}) orelse return true;
    return std.ascii.eqlIgnoreCase(status, "active") or
        std.ascii.eqlIgnoreCase(status, "enabled") or
        std.ascii.eqlIgnoreCase(status, "available");
}

fn suffixFor(allocator: std.mem.Allocator, secret: []const u8, idx: usize) ![]u8 {
    if (secret.len >= 4) return allocator.dupe(u8, secret[secret.len - 4 ..]);
    return std.fmt.allocPrint(allocator, "#{d}", .{idx + 1});
}

pub fn endpointForMessagesUrl(allocator: std.mem.Allocator, messages_url: []const u8) ![]u8 {
    if (std.c.getenv(API_KEYS_URL_ENV)) |u| return allocator.dupe(u8, std.mem.span(u));
    const suffix = "/v1/messages";
    if (!std.mem.endsWith(u8, messages_url, suffix)) return error.UnexpectedUrl;
    const base = messages_url[0 .. messages_url.len - suffix.len];
    return std.fmt.allocPrint(allocator, "{s}/api/v1/keys?page=1&page_size=100", .{base});
}

pub fn fetchInto(
    catalog: *Catalog,
    allocator: std.mem.Allocator,
    io: std.Io,
    messages_url: []const u8,
    bearer_token: []const u8,
) !void {
    const url = try endpointForMessagesUrl(allocator, messages_url);
    defer allocator.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var http_client = std.http.Client{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{bearer_token}) catch return error.RequestFailed;
    defer secureFree(allocator, auth_header);
    var req = http_client.request(.GET, uri, .{
        .extra_headers = &.{.{ .name = "authorization", .value = auth_header }},
    }) catch return error.RequestFailed;
    defer req.deinit();

    req.sendBodiless() catch return error.RequestFailed;
    var redirect_buf: [4096]u8 = undefined;
    const resp = req.receiveHead(&redirect_buf) catch return error.RequestFailed;
    const status = ResponseStatus.capture(&resp);
    if (!status.isOk()) return error.HttpError;

    var transfer_buf: [8192]u8 = undefined;
    const body_reader = req.reader.bodyReader(&transfer_buf, resp.head.transfer_encoding, resp.head.content_length);
    const body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.RequestFailed;
    defer allocator.free(body);
    try catalog.loadFromJson(body);
}

fn secureFree(allocator: std.mem.Allocator, buf: []u8) void {
    @memset(buf, 0);
    allocator.free(buf);
}

test "api key catalog parses data array without leaking secret into label" {
    var c = Catalog.init(std.testing.allocator);
    defer c.deinit();
    try c.loadFromJson(
        \\{"data":[{"id":"k1","name":"prod","api_key":"sk-metask-abcdef"},{"label":"dev","key":"short"}]}
    );
    try std.testing.expectEqual(@as(usize, 2), c.entries.items.len);
    try std.testing.expectEqualStrings("prod", c.entries.items[0].label);
    try std.testing.expectEqualStrings("cdef", c.entries.items[0].suffix);
    try std.testing.expectEqualStrings("short", c.entries.items[1].secret);
}

test "api key catalog parses metask data items and skips inactive keys" {
    var c = Catalog.init(std.testing.allocator);
    defer c.deinit();
    try c.loadFromJson(
        \\{"code":0,"message":"success","data":{"items":[
        \\{"id":325,"name":"Prod key","key":"sk-metask-active-1234","status":"active","group":{"name":"MiniMax-M3"}},
        \\{"id":326,"name":"Disabled key","key":"sk-metask-disabled-5678","status":"disabled"}
        \\]}}
    );
    try std.testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try std.testing.expectEqualStrings("Prod key", c.entries.items[0].label);
    try std.testing.expectEqualStrings("MiniMax-M3", c.entries.items[0].group);
    try std.testing.expectEqualStrings("1234", c.entries.items[0].suffix);
}

test "api key catalog current-key fallback masks secret in display fields" {
    var c = Catalog.init(std.testing.allocator);
    defer c.deinit();
    try c.addCurrentKeyFallback("sk-metask-current-9999");
    try std.testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try std.testing.expectEqualStrings("Current API key", c.entries.items[0].label);
    try std.testing.expectEqualStrings("", c.entries.items[0].group);
    try std.testing.expectEqualStrings("9999", c.entries.items[0].suffix);
    try std.testing.expect(std.mem.indexOf(u8, c.entries.items[0].label, "sk-metask") == null);
}
