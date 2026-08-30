//! Google Gemini provider profile.
//!
//! Gemini is the reason `EndpointShape` exists: its transport receives an
//! origin and appends `/v1beta/models/{model}:streamGenerateContent` itself.
//! Declaring that shape keeps endpoint construction truthful instead of
//! special-casing the vendor at the call site. Authentication is the
//! `x-goog-api-key` header, which is exactly what the existing client sends.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");

const Slug = ids.Slug;

pub const BASE_URL = "https://generativelanguage.googleapis.com";

fn entry(
    comptime request_model_id: []const u8,
    comptime display_name: []const u8,
) profile.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = "google/" ++ request_model_id,
        .capabilities = (offer.CapabilityMatrix{
            .provenance = offer.Provenance.known(.builtin_profile, null),
        })
            .with(.tools, .supported)
            .with(.streaming, .supported)
            .with(.vision, .supported),
    };
}

const MODELS = [_]profile.ModelEntry{
    entry("gemini-2.5-pro", "Gemini 2.5 Pro"),
    entry("gemini-2.5-flash", "Gemini 2.5 Flash"),
};

const ROUTES = [_]profile.ProtocolRoute{.{ .protocol = .gemini_generate_content }};

const CHANNELS = [_]profile.ChannelDescriptor{.{
    .id = Slug.lit("default"),
    .display_name = "Google AI",
    .base_url = BASE_URL,
    .routes = &ROUTES,
}};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "GEMINI_API_KEY", .kind = .api_key, .canonical = true },
    .{ .name = "GOOGLE_API_KEY", .kind = .api_key },
};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("gemini"),
    .implementation_id = Slug.lit("gemini"),
    .display_name = "Google Gemini",
    .aliases = &.{"google"},
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .{ .custom_header = .{ .name = "x-goog-api-key" } },
    .default_channel = Slug.lit("default"),
};

test "gemini profile keeps the origin-shaped endpoint and its own auth header" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .gemini_generate_content, null, &buffer),
    );
    var auth_buffer: [64]u8 = undefined;
    const auth = try @import("../credential.zig").materialize(PROFILE.auth, "gk-secret", &auth_buffer);
    try std.testing.expectEqualStrings("x-goog-api-key", auth.name);
    try std.testing.expectEqualStrings("gk-secret", auth.value);
}
