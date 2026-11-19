//! Ask an endpoint which models it serves (`metacodes providers probe`,
//! `providers add --probe`). Nothing is stored here: the answer is for a
//! person to read and pick from.
//!
//! Where each wire lists its models, and how an answer is read, is
//! `provider/model_listing.zig`; this file is the GET. It goes through
//! `catalog_fetch`, so a request that carries a key never follows a redirect
//! (`catalog_fetch.fetchAnswer`), and the key is placed the way the
//! provider's own requests place it — a listing that accepts a key sent
//! differently would say nothing about the requests that follow.

const std = @import("std");
const catalog_fetch = @import("catalog_fetch.zig");
const model_listing = @import("../provider/model_listing.zig");
const credential = @import("../provider/credential.zig");

pub const Wire = model_listing.Wire;

pub const Request = struct {
    /// The channel's base as stored (`model_listing.channelBase`) or as typed.
    base_url: []const u8,
    wire: Wire,
    /// Null asks without a key: a local server may want none.
    secret: ?[]const u8 = null,
    auth: credential.AuthScheme = .bearer,
};

pub const Outcome = union(enum) {
    listed: model_listing.Listing,
    /// The wire has no model listing (Bedrock Converse).
    no_listing,
    /// 401 or 403: the key was refused, or one is wanted.
    refused: u16,
    /// Any other status but 2xx. A 3xx is one: with a key it is not followed.
    status: u16,
    /// A 2xx that is not a listing this reads.
    unreadable: model_listing.ParseError,
    /// No answer at all (connection, TLS, a body past the size bound).
    failed: catalog_fetch.FetchError,
};

pub const Probe = struct {
    /// The GET that was sent, null when there is none to send.
    url: ?[]const u8,
    outcome: Outcome,
};

/// The headers a listing of `wire` needs besides the key, in `buffer`.
pub fn headersFor(wire: ?Wire, buffer: *[1]std.http.Header) []const std.http.Header {
    const header = model_listing.listingHeader(wire orelse return &.{}) orelse return &.{};
    buffer[0] = .{ .name = header.name, .value = header.value };
    return buffer[0..1];
}

/// List the models at `request`. Everything returned lives in `arena`.
pub fn probe(arena: std.mem.Allocator, io: std.Io, request: Request) error{OutOfMemory}!Probe {
    const url = (try model_listing.listingUrl(arena, request.base_url, request.wire)) orelse
        return .{ .url = null, .outcome = .no_listing };
    var buffer: [1]std.http.Header = undefined;
    const answer = catalog_fetch.fetchAnswer(arena, io, .{
        .url = url,
        .credential = if (request.secret) |secret| .{ .scheme = request.auth, .secret = secret } else null,
        .extra_headers = headersFor(request.wire, &buffer),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .url = url, .outcome = .{ .failed = err } },
    };
    if (answer.status == 401 or answer.status == 403) return .{ .url = url, .outcome = .{ .refused = answer.status } };
    if (answer.status < 200 or answer.status >= 300) return .{ .url = url, .outcome = .{ .status = answer.status } };
    const listing = model_listing.parse(arena, answer.body, request.wire) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .url = url, .outcome = .{ .unreadable = err } },
    };
    return .{ .url = url, .outcome = .{ .listed = listing } };
}

test "a wire without a listing is answered without a request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try probe(arena_state.allocator(), undefined, .{ .base_url = "https://bedrock.example.com", .wire = .bedrock_converse });
    try std.testing.expect(result.url == null);
    try std.testing.expect(result.outcome == .no_listing);
    var buffer: [1]std.http.Header = undefined;
    try std.testing.expectEqualStrings("anthropic-version", headersFor(.anthropic_messages, &buffer)[0].name);
    try std.testing.expectEqual(@as(usize, 0), headersFor(.openai_chat, &buffer).len);
    try std.testing.expectEqual(@as(usize, 0), headersFor(null, &buffer).len);
}
