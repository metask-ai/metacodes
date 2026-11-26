//! OpenRouter provider profile.
//!
//! Integration notes — the request surface, reasoning, attribution and their
//! sources — live in `packages/ai/src/api/dialects/openrouter.zig`; this file is the route
//! data.
//!
//! OpenRouter is a router: one model is served by many upstream providers.
//! This profile is the router itself, the way Metask's profile is its gateway:
//! one channel, `auto`, whose requests leave the upstream to OpenRouter's
//! default routing (price, speed and uptime, with fallbacks). Which upstream
//! answered is the router's to report, and the route records it.
//!
//! The models a session can pick come from the account's own listing once a
//! key is known (`GET /api/v1/models/user`, ingested by
//! `Host.ingestOpenRouterBuiltin`). Compiled here is only OpenRouter's general
//! router model, so that the provider is listed — as not configured — before
//! a sign-in, and keeps one working route if the listing cannot be fetched.
//!
//! The key is the user's own: from the browser sign-in (`key_grant`, which
//! creates it on their account), pasted (`api_key_setup`), or
//! `OPENROUTER_API_KEY`.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");

const Slug = ids.Slug;

pub const ORIGIN = "https://openrouter.ai";
pub const API_BASE = ORIGIN ++ "/api/v1";

/// The router model: it picks a model for every request, so nothing about
/// limits or price can be declared for it.
const SEED_CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported);

const SEED_MODELS = [_]profile.ModelEntry{.{
    .request_model_id = "openrouter/auto",
    .display_name = "Auto Router",
    .canonical_model_id = "openrouter/auto",
    .capabilities = SEED_CAPABILITIES,
}};

const ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_chat,
    .dialect = .openrouter,
}};

pub const AUTO_CHANNEL = Slug.lit("auto");

const CHANNELS = [_]profile.ChannelDescriptor{.{
    .id = AUTO_CHANNEL,
    .display_name = "OpenRouter picks the provider",
    .base_url = API_BASE,
    .routes = &ROUTES,
}};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "OPENROUTER_API_KEY", .kind = .api_key, .canonical = true },
};

/// `GET /api/v1/key` answers 401 without a valid key (2026-11-18), describes
/// the key with one, and is not a model call.
const KEY_PAGES = [_]profile.KeyPage{.{
    .id = Slug.lit("keys"),
    .label = "OpenRouter API keys",
    .url = ORIGIN ++ "/keys",
    .check_url = API_BASE ++ "/key",
}};

/// https://openrouter.ai/docs/guides/overview/auth/oauth (2026-11-18).
pub const KEY_GRANT = profile.KeyGrant{
    .origin = ORIGIN,
    .authorize_path = "/auth",
    .exchange_path = "/api/v1/auth/keys",
    .key_info_path = "/api/v1/key",
    .manage_path = "/keys/",
    .key_label = "metacodes",
};

/// OpenRouter's statuses (https://openrouter.ai/docs/api_reference/errors-and-debugging,
/// 2026-11-18): 402 is an empty balance, and a 403 is not only a refusal — a
/// key or workspace whose spending limit is reached answers 403 with the
/// figures ("$X of $Y used; resets …"). A 401 is a key that no longer works
/// (deleted, expired); there is no token to refresh.
fn classifyError(status: u16, body: []const u8) profile.ErrorClass {
    return switch (status) {
        401 => .auth_invalid,
        402 => .quota_exceeded,
        403 => if (std.mem.indexOf(u8, body, " used; resets") != null) .quota_exceeded else .permission_denied,
        else => profile.defaultClassifyError(status, body),
    };
}

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("openrouter"),
    .implementation_id = Slug.lit("openrouter"),
    .display_name = "OpenRouter",
    .channels = &CHANNELS,
    .models = &SEED_MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = AUTO_CHANNEL,
    .classify_error = classifyError,
    .api_key_setup = .{ .kind = .api_key, .pages = &KEY_PAGES },
    .key_grant = KEY_GRANT,
};

test "openrouter profile: one router channel on the OpenRouter dialect, a key grant and a key page" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/api/v1/chat/completions",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, null, &buffer),
    );
    try std.testing.expectEqual(@import("../vendor.zig").Vendor.openrouter, ROUTES[0].dialect.?);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/key", KEY_PAGES[0].check_url.?);
    // The grant's key is stored as the key page's kind.
    try std.testing.expectEqual(profile.CredentialKind.api_key, PROFILE.api_key_setup.?.kind);
}

test "openrouter profile: a spent limit and an empty balance are quota, a 401 an invalid key" {
    try std.testing.expectEqual(profile.ErrorClass.auth_invalid, classifyError(401, "{}"));
    try std.testing.expectEqual(profile.ErrorClass.quota_exceeded, classifyError(402, "{}"));
    try std.testing.expectEqual(profile.ErrorClass.quota_exceeded, classifyError(403, "{\"error\":{\"code\":403,\"message\":\"Key limit exceeded: $5.00 of $5.00 used; resets 2026-12-01T00:00:00.000Z.\"}}"));
    try std.testing.expectEqual(profile.ErrorClass.permission_denied, classifyError(403, "{\"error\":{\"code\":403,\"message\":\"Blocked by guardrail\"}}"));
    try std.testing.expectEqual(profile.ErrorClass.rate_limited, classifyError(429, "{}"));
}

test "a key grant needs https, a bare origin, rooted paths, a label and a key setup" {
    var copy = PROFILE;
    var grant = KEY_GRANT;
    grant.origin = "http://openrouter.ai";
    copy.key_grant = grant;
    try std.testing.expectError(error.InvalidKeyGrant, profile.validateProfile(copy));
    grant = KEY_GRANT;
    grant.origin = "https://openrouter.ai/api";
    copy.key_grant = grant;
    try std.testing.expectError(error.InvalidKeyGrant, profile.validateProfile(copy));
    grant = KEY_GRANT;
    grant.exchange_path = "api/v1/auth/keys";
    copy.key_grant = grant;
    try std.testing.expectError(error.InvalidKeyGrant, profile.validateProfile(copy));
    grant = KEY_GRANT;
    grant.key_label = "";
    copy.key_grant = grant;
    try std.testing.expectError(error.InvalidKeyGrant, profile.validateProfile(copy));
    copy = PROFILE;
    copy.api_key_setup = null;
    try std.testing.expectError(error.InvalidKeyGrant, profile.validateProfile(copy));
}
