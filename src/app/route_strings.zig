//! The strings a committed provider route lends to the live clients
//! (issue #16).
//!
//! `Client.base_url` and `Client.api_key` are plain `[]const u8` fields with no
//! mutex, and a background subagent that fell back to the shared client reads
//! them while the main thread may be switching routes — the same hazard
//! `Client.model` documents and serializes with `model_mutex`.
//!
//! Freeing the previous buffer at switch time makes a torn `{new_ptr, old_len}`
//! read run off the end of freed memory. Keeping one generation alive makes the
//! worst case a wrong-but-in-bounds string, which fails a request instead of
//! corrupting the process — the same trade the offer catalog's retirement
//! makes, for the same reason.
//!
//! A reader two switches behind would already have failed its request, so one
//! retained generation is the bound.

const std = @import("std");

pub const RouteStrings = struct {
    allocator: std.mem.Allocator,
    /// What the clients currently point at.
    endpoint: ?[]u8 = null,
    secret: ?[]u8 = null,
    /// The generation before, still readable.
    retired_endpoint: ?[]u8 = null,
    retired_secret: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) RouteStrings {
        return .{ .allocator = allocator };
    }

    /// Install a new generation, retiring the current one and releasing the one
    /// before it. Takes ownership of both arguments.
    pub fn install(self: *RouteStrings, endpoint: []u8, secret: []u8) void {
        self.retire();
        self.endpoint = endpoint;
        self.secret = secret;
    }

    /// Install a new secret only — an OAuth refresh moves the credential
    /// without moving the route.
    pub fn installSecret(self: *RouteStrings, secret: []u8) void {
        self.releaseRetiredSecret();
        self.retired_secret = self.secret;
        self.secret = secret;
    }

    fn retire(self: *RouteStrings) void {
        if (self.retired_endpoint) |old| self.allocator.free(old);
        self.releaseRetiredSecret();
        self.retired_endpoint = self.endpoint;
        self.retired_secret = self.secret;
        self.endpoint = null;
        self.secret = null;
    }

    fn releaseRetiredSecret(self: *RouteStrings) void {
        const old = self.retired_secret orelse return;
        // Zeroed before release, like every other place credential material is
        // returned to the allocator.
        std.crypto.secureZero(u8, old);
        self.allocator.free(old);
        self.retired_secret = null;
    }

    /// Teardown is the one point at which no reader can be in flight, so both
    /// generations go.
    pub fn deinit(self: *RouteStrings) void {
        if (self.endpoint) |value| self.allocator.free(value);
        if (self.retired_endpoint) |value| self.allocator.free(value);
        for ([_]?[]u8{ self.secret, self.retired_secret }) |value| {
            if (value) |owned| {
                std.crypto.secureZero(u8, owned);
                self.allocator.free(owned);
            }
        }
        self.* = undefined;
    }
};

const testing = std.testing;

test "the previous generation stays readable after a switch" {
    const a = testing.allocator;
    var strings = RouteStrings.init(a);
    defer strings.deinit();

    strings.install(
        try a.dupe(u8, "https://first.example.com/v1/messages"),
        try a.dupe(u8, "sk-first"),
    );
    const first = strings.endpoint.?;

    strings.install(
        try a.dupe(u8, "https://second.example.com/v1"),
        try a.dupe(u8, "sk-second"),
    );

    // A background request that read the pointer before the switch still reads
    // valid memory. Freeing here is what turns a torn read into an out-of-bounds
    // one.
    try testing.expectEqual(first.ptr, strings.retired_endpoint.?.ptr);
    try testing.expectEqualStrings("https://first.example.com/v1/messages", strings.retired_endpoint.?);
    try testing.expectEqualStrings("sk-first", strings.retired_secret.?);
    try testing.expectEqualStrings("https://second.example.com/v1", strings.endpoint.?);
}

test "a third switch releases the first generation" {
    const a = testing.allocator;
    var strings = RouteStrings.init(a);
    defer strings.deinit();

    strings.install(try a.dupe(u8, "one"), try a.dupe(u8, "sk-1"));
    strings.install(try a.dupe(u8, "two"), try a.dupe(u8, "sk-2"));
    strings.install(try a.dupe(u8, "three"), try a.dupe(u8, "sk-3"));

    // One generation is the bound: a reader two switches behind would already
    // have failed its request. The testing allocator catches the release.
    try testing.expectEqualStrings("three", strings.endpoint.?);
    try testing.expectEqualStrings("two", strings.retired_endpoint.?);
}

test "a credential refresh moves the secret without moving the route" {
    const a = testing.allocator;
    var strings = RouteStrings.init(a);
    defer strings.deinit();

    strings.install(try a.dupe(u8, "https://api.example.com/v1"), try a.dupe(u8, "at-1"));
    const endpoint = strings.endpoint.?;

    strings.installSecret(try a.dupe(u8, "at-2"));
    // An OAuth refresh changes the credential only; repointing the endpoint
    // would retire a route that never changed.
    try testing.expectEqual(endpoint.ptr, strings.endpoint.?.ptr);
    try testing.expectEqualStrings("at-2", strings.secret.?);
    try testing.expectEqualStrings("at-1", strings.retired_secret.?);
}

test "an empty holder tears down cleanly" {
    const a = testing.allocator;
    var strings = RouteStrings.init(a);
    strings.deinit();
}
