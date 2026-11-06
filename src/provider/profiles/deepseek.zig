//! DeepSeek provider profile.
//!
//! Integration notes — dialect, thinking parameters, reasoning passback, the
//! Anthropic-wire differences and their sources — live in
//! `src/api/dialects/deepseek.zig`; this file is the route data.
//!
//! Two channels on one host: the OpenAI chat surface (default) and the
//! Anthropic-compatible surface under `/anthropic`. Both declare the DeepSeek
//! dialect, so a model id the user names on either channel is written in
//! DeepSeek's dialect whatever it is called.
//!
//! Quotes stay `unknown`: DeepSeek bills peak and off-peak hours at different
//! rates (api-docs.deepseek.com/quick_start/pricing, 2026-11), and a single
//! per-token quote would be wrong for half of every week.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const OPENAI_BASE = "https://api.deepseek.com";
pub const ANTHROPIC_BASE = "https://api.deepseek.com/anthropic";

/// `none` switches thinking off; the rest are DeepSeek's three levels.
const EFFORTS = [_][]const u8{ "none", "low", "high", "max" };

const CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &EFFORTS,
}};

/// 1M window as the official `/models` listing declares it (1,048,576), and
/// at most 384K output, for both models (pricing page, 2026-11).
const LIMITS = offer.EffectiveLimits{
    .context_window = 1_048_576,
    .max_output_tokens = 393_216,
    .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
    .provenance = offer.Provenance.known(.builtin_profile, null),
};

const CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported)
    .with(.reasoning, .supported)
    .with(.reasoning_content, .supported);

const MODELS = [_]profile.ModelEntry{
    .{
        .request_model_id = "deepseek-v4-pro",
        .display_name = "DeepSeek V4 Pro",
        .canonical_model_id = "deepseek/deepseek-v4-pro",
        .limits = LIMITS,
        // v4-pro replaces images with "[Unsupported Image]".
        .capabilities = CAPABILITIES.with(.vision, .unsupported),
        .controls = &CONTROLS,
    },
    .{
        .request_model_id = "deepseek-flash",
        .display_name = "DeepSeek V4.1 Flash",
        .canonical_model_id = "deepseek/deepseek-flash",
        .limits = LIMITS,
        .capabilities = CAPABILITIES.with(.vision, .supported),
        .controls = &CONTROLS,
    },
};

const OPENAI_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_chat,
    .dialect = .deepseek,
}};

const ANTHROPIC_REQUIRED = [_][]const u8{"/anthropic"};

const ANTHROPIC_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .anthropic_messages,
    .policy = .{ .required_path_fragments = &ANTHROPIC_REQUIRED },
    .dialect = .deepseek,
}};

const CHANNELS = [_]profile.ChannelDescriptor{
    .{
        .id = Slug.lit("default"),
        .display_name = "DeepSeek · OpenAI wire",
        .base_url = OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
    },
    .{
        .id = Slug.lit("anthropic"),
        .display_name = "DeepSeek · Anthropic wire",
        .base_url = ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
    },
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "DEEPSEEK_API_KEY", .kind = .api_key, .canonical = true },
};

/// The model listing answers 401 without a valid key and is not a model call.
const KEY_PAGES = [_]profile.KeyPage{.{
    .id = Slug.lit("platform"),
    .label = "DeepSeek Platform",
    .url = "https://platform.deepseek.com/api_keys",
    .check_url = OPENAI_BASE ++ "/models",
}};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("deepseek"),
    .implementation_id = Slug.lit("deepseek"),
    .display_name = "DeepSeek",
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("default"),
    .api_key_setup = .{ .kind = .api_key, .pages = &KEY_PAGES },
};

test "deepseek profile: both wires, both declaring the DeepSeek dialect" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com/chat/completions",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, null, &buffer),
    );
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com/anthropic/v1/messages",
        try CHANNELS[1].endpointFor(PROFILE.endpoint_policy, .anthropic_messages, null, &buffer),
    );
    for (CHANNELS) |channel| for (channel.routes) |route| {
        try std.testing.expectEqual(profile.Vendor.deepseek, route.dialect.?);
    };
    for (MODELS) |model| {
        const spec = controls.findSpec(model.controls, "reasoning_effort").?;
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
    }
}
