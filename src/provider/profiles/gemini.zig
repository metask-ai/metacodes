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
