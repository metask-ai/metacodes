//! Google Gemini provider profile.
//!
//! Integration notes live in `src/api/dialects/gemini.zig`; this file is the
//! route data.
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
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const BASE_URL = "https://generativelanguage.googleapis.com";

/// `thinkingLevel` values both models accept; neither takes `minimal`, and
/// neither can switch thinking off (ai.google.dev/gemini-api/docs/
/// generate-content/thinking, 2026-10). The request carries the level as
/// `generation_config.thinking_level` (`dialects/gemini.zig`).
const THINKING_LEVELS = [_][]const u8{ "low", "medium", "high" };

const THINKING_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Thinking level",
    .kind = .enumeration,
    .allowed_values = &THINKING_LEVELS,
}};

fn entry(
    comptime request_model_id: []const u8,
    comptime display_name: []const u8,
    comptime limits: offer.EffectiveLimits,
) profile.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = "google/" ++ request_model_id,
        .limits = limits,
        .capabilities = (offer.CapabilityMatrix{
            .provenance = offer.Provenance.known(.builtin_profile, null),
        })
            .with(.tools, .supported)
            .with(.streaming, .supported)
            .with(.reasoning, .supported)
            .with(.vision, .supported),
        .controls = &THINKING_CONTROLS,
    };
}

/// The current frontier models (ai.google.dev/gemini-api/docs/models, 2026-10):
/// Gemini 4 Argon (stable since 2026-10-13) and Gemini 3.8 Flash (stable since
/// 2026-09-02). Argon's 1,048,576 tokens are one window shared by input,
/// thinking and output; a streamed response carries at most 65,536 output
/// tokens. Gemini 2.5 is no longer offered to new users; `--model` still
/// names any model.
const MODELS = [_]profile.ModelEntry{
    entry("gemini-4-argon", "Gemini 4 Argon", .{
        .context_window = 1_048_576,
        .max_output_tokens = 65_536,
        .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
        .provenance = offer.Provenance.known(.builtin_profile, null),
    }),
    entry("gemini-3.8-flash", "Gemini 3.8 Flash", .{
        .context_window = 1_048_576,
        .max_input_tokens = 1_048_576,
        .max_output_tokens = 65_536,
        .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
        .provenance = offer.Provenance.known(.builtin_profile, null),
    }),
};

const ROUTES = [_]profile.ProtocolRoute{.{ .protocol = .gemini_generate_content, .dialect = .gemini }};

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

/// Where a Gemini API key is created (aistudio.google.com/apikey, opened
/// 2026-11-17: Google's sign-in returns there). The model listing is not a
/// model call; the check sends the key as requests do, in `x-goog-api-key`
/// (as a bearer token Google reads it as an OAuth token and answers 401
/// whatever the key).
const KEY_PAGES = [_]profile.KeyPage{.{
    .id = Slug.lit("aistudio"),
    .label = "Google AI Studio",
    .url = "https://aistudio.google.com/apikey",
    .check_url = BASE_URL ++ "/v1beta/models",
}};

/// Gemini's answers, as Google words them (2026-11-17, against the model
/// listing): no key is 403 `PERMISSION_DENIED`, and a wrong key is 400
/// `INVALID_ARGUMENT` with the reason `API_KEY_INVALID` — a refused key under
/// the status of a malformed request. An expired key (`API_KEY_EXPIRED`) has
/// no refresh, so it is as final as an invalid one. Everything else is the
/// default reading; a 400 for any other reason (an unsupported location, a
/// bad field) says nothing about the key.
pub fn classifyError(status: u16, body: []const u8) profile.ErrorClass {
    if (status == 400) {
        for ([_][]const u8{ "API_KEY_INVALID", "API_KEY_EXPIRED" }) |reason| {
            if (std.mem.indexOf(u8, body, reason) != null) return .auth_invalid;
        }
    }
    return profile.defaultClassifyError(status, body);
}

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
    .classify_error = classifyError,
    .api_key_setup = .{ .kind = .api_key, .pages = &KEY_PAGES },
};

test "gemini profile: a pasted key is checked against the model listing, in x-goog-api-key" {
    try profile.validateProfile(PROFILE);
    const page = PROFILE.defaultKeyPage(PROFILE.default_channel).?;
    try std.testing.expectEqualStrings("https://aistudio.google.com/apikey", page.url);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models", page.check_url.?);
    try std.testing.expectEqualStrings("x-goog-api-key", PROFILE.auth.custom_header.name);
}

test "gemini classifies a refused key's 400 as invalid, and other 400s as bad requests" {
    // Google's answer to a made-up key on the model listing (2026-11-17).
    const refused =
        \\{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT",
        \\"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}
    ;
    try std.testing.expectEqual(profile.ErrorClass.auth_invalid, classifyError(400, refused));
    try std.testing.expectEqual(profile.ErrorClass.auth_invalid, classifyError(400, "{\"error\":{\"details\":[{\"reason\":\"API_KEY_EXPIRED\"}]}}"));
    try std.testing.expectEqual(profile.ErrorClass.bad_request, classifyError(400, "{\"error\":{\"status\":\"FAILED_PRECONDITION\",\"message\":\"User location is not supported for the API use.\"}}"));
    try std.testing.expectEqual(profile.ErrorClass.permission_denied, classifyError(403, "{\"error\":{\"status\":\"PERMISSION_DENIED\"}}"));
    try std.testing.expectEqual(profile.ErrorClass.rate_limited, classifyError(429, ""));
    try std.testing.expect(!classifyError(400, refused).isRetryableTransport());
}

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

test "the current Gemini models are bounded and offer their thinking levels" {
    try profile.validateProfile(PROFILE);
    for (MODELS) |model| {
        try std.testing.expectEqual(@as(?u32, 1_048_576), model.limits.context_window);
        try std.testing.expectEqual(@as(?u32, 65_536), model.limits.max_output_tokens);
        const spec = controls.findSpec(model.controls, "reasoning_effort").?;
        try std.testing.expectEqual(@as(usize, 3), spec.allowed_values.len);
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
    }
}
