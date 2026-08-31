//! Transport-side authentication materialization.
//!
//! Before issue #16 the Anthropic and OpenAI transports hard-coded
//! `authorization: Bearer <key>`. That is correct for Metask, OpenAI, and the
//! Z.AI Coding Plan, and wrong for every provider that signs, uses `x-api-key`,
//! or uses a vendor header — which the requirement lists as a transport
//! capability rather than a per-vendor branch in `AgentLoop`.
//!
//! `scheme == null` reproduces the historical bytes exactly, so existing
//! sessions and recorded cassettes are unaffected.

const std = @import("std");
const credential = @import("../provider/credential.zig");

pub const AuthScheme = credential.AuthScheme;

pub const Error = error{
    SignedAdapterRequired,
    EmptyCredentialMaterial,
    OutOfMemory,
};

pub const Header = struct {
    name: []const u8,
    /// Allocated; the caller must `secureFree` it after request setup.
    value: []u8,
};

/// Build the request header for `secret` under `scheme`.
/// The default (`null`) is `authorization: Bearer <secret>`.
pub fn build(
    allocator: std.mem.Allocator,
    scheme: ?AuthScheme,
    secret: []const u8,
) Error!Header {
    const selected = scheme orelse AuthScheme.bearer;
    if (secret.len == 0) return error.EmptyCredentialMaterial;
    return switch (selected) {
        .bearer => .{
            .name = "authorization",
            .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{secret}),
        },
        .api_key_header => |name| .{
            .name = name,
            .value = try allocator.dupe(u8, secret),
        },
        .custom_header => |custom| .{
            .name = custom.name,
            .value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ custom.value_prefix, secret }),
        },
        .signed_adapter => error.SignedAdapterRequired,
    };
}

test "the default scheme reproduces the historical bearer header" {
    const a = std.testing.allocator;
    const header = try build(a, null, "sk-test");
    defer a.free(header.value);
    try std.testing.expectEqualStrings("authorization", header.name);
    try std.testing.expectEqualStrings("Bearer sk-test", header.value);
}

test "provider schemes change the actual header name and value" {
    const a = std.testing.allocator;
    const api_key = try build(a, .{ .api_key_header = "x-api-key" }, "sk-test");
    defer a.free(api_key.value);
    try std.testing.expectEqualStrings("x-api-key", api_key.name);
    try std.testing.expectEqualStrings("sk-test", api_key.value);

    const custom = try build(a, .{ .custom_header = .{ .name = "x-goog-api-key" } }, "gk-test");
    defer a.free(custom.value);
    try std.testing.expectEqualStrings("x-goog-api-key", custom.name);
    try std.testing.expectEqualStrings("gk-test", custom.value);

    const prefixed = try build(a, .{ .custom_header = .{ .name = "x-vendor", .value_prefix = "Token " } }, "abc");
    defer a.free(prefixed.value);
    try std.testing.expectEqualStrings("Token abc", prefixed.value);
}

test "unsupported placements fail instead of sending nothing" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.SignedAdapterRequired, build(a, .{ .signed_adapter = "sigv4" }, "sk"));
    try std.testing.expectError(error.EmptyCredentialMaterial, build(a, null, ""));
}
