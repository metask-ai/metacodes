//! Moonshot Kimi provider profile.
//!
//! Integration notes — the three generations' thinking parameters, reasoning
//! passback, `prompt_cache_key`, and their sources — live in
//! `src/api/dialects/kimi.zig`; this file is the route data.
//!
//! China (`api.moonshot.cn`) and global (`api.moonshot.ai`) are separate
//! accounts with separate keys, each with an OpenAI-chat and an
//! Anthropic-compatible surface. China on the OpenAI wire is the default. The
//! Anthropic surface serves the K3 series only, so K2.7-code is offered on the
//! OpenAI channels alone.
//!
//! The Kimi Code subscription (`api.kimi.com/coding/v1`) is a different account
//! and quota and is not part of this profile. Quotes stay `unknown` until a
//! catalog supplies them.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const CN_OPENAI_BASE = "https://api.moonshot.cn/v1";
pub const GLOBAL_OPENAI_BASE = "https://api.moonshot.ai/v1";
pub const CN_ANTHROPIC_BASE = "https://api.moonshot.cn/anthropic";
pub const GLOBAL_ANTHROPIC_BASE = "https://api.moonshot.ai/anthropic";

/// K3 and K3.1 always think; `reasoning_effort` is low / high / max, default
/// max (platform.kimi.ai/docs/api/chat, 2026-11).
const K3_EFFORTS = [_][]const u8{ "low", "high", "max" };

const K3_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &K3_EFFORTS,
}};

const CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported)
    .with(.reasoning, .supported)
    .with(.reasoning_content, .supported)
    .with(.vision, .supported);

/// The K3 window is 1,048,576 tokens. Output is declared as 131,072, the
/// server default: this repository never sends `max_completion_tokens`, so the
/// default is the effective cap even though the API accepts up to 1,048,576.
const K3_LIMITS = offer.EffectiveLimits{
    .context_window = 1_048_576,
    .max_output_tokens = 131_072,
    .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
    .provenance = offer.Provenance.known(.builtin_profile, null),
};

/// K2.7-code: 262,144-token window (pricing page: every K2 model). It is closed
/// to accounts registered after 2026-11-01 and is expected to be retired in
/// late December 2026.
const K27_LIMITS = offer.EffectiveLimits{
    .context_window = 262_144,
    .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
    .provenance = offer.Provenance.known(.builtin_profile, null),
};

const MODELS = [_]profile.ModelEntry{
    .{
        .request_model_id = "kimi-k3.1-pro",
        .display_name = "Kimi K3.1 Pro",
        .canonical_model_id = "moonshotai/kimi-k3.1-pro",
        .limits = K3_LIMITS,
        .capabilities = CAPABILITIES,
        .controls = &K3_CONTROLS,
    },
    .{
        .request_model_id = "kimi-k3",
        .display_name = "Kimi K3",
        .canonical_model_id = "moonshotai/kimi-k3",
        .limits = K3_LIMITS,
        .capabilities = CAPABILITIES,
        .controls = &K3_CONTROLS,
    },
    .{
        // Thinking cannot be switched off and has no levels: no control.
        .request_model_id = "kimi-k2.7-code",
        .display_name = "Kimi K2.7 Code",
        .canonical_model_id = "moonshotai/kimi-k2.7-code",
        .limits = K27_LIMITS,
        .capabilities = CAPABILITIES,
        // The Anthropic surface serves the K3 series only.
        .protocols = &OPENAI_ONLY,
    },
};

const OPENAI_ONLY = [_]profile.Protocol{.openai_chat};

const OPENAI_REQUIRED = [_][]const u8{"/v1"};
const ANTHROPIC_REQUIRED = [_][]const u8{"/anthropic"};

const OPENAI_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_chat,
    .policy = .{ .required_path_fragments = &OPENAI_REQUIRED },
    .dialect = .kimi,
}};

const ANTHROPIC_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .anthropic_messages,
    .policy = .{ .required_path_fragments = &ANTHROPIC_REQUIRED },
    .dialect = .kimi,
}};

const CHANNELS = [_]profile.ChannelDescriptor{
    .{
        .id = Slug.lit("cn-openai"),
        .display_name = "Kimi · China · OpenAI wire",
        .base_url = CN_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "cn",
    },
    .{
        .id = Slug.lit("global-openai"),
        .display_name = "Kimi · Global · OpenAI wire",
        .base_url = GLOBAL_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "global",
    },
    .{
        .id = Slug.lit("cn-anthropic"),
        .display_name = "Kimi · China · Anthropic wire",
        .base_url = CN_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "cn",
    },
    .{
        .id = Slug.lit("global-anthropic"),
        .display_name = "Kimi · Global · Anthropic wire",
        .base_url = GLOBAL_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "global",
    },
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.api_key};

/// `MOONSHOT_API_KEY` is what the vendor's documentation uses.
const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "MOONSHOT_API_KEY", .kind = .api_key, .canonical = true },
    .{ .name = "KIMI_API_KEY", .kind = .api_key },
};

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("kimi"),
    .implementation_id = Slug.lit("kimi"),
    .display_name = "Moonshot Kimi",
    .aliases = &.{"moonshot"},
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    .default_channel = Slug.lit("cn-openai"),
};

test "kimi profile: four channels, every route declares the Kimi dialect" {
    try profile.validateProfile(PROFILE);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://api.moonshot.cn/v1/chat/completions",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, null, &buffer),
    );
    try std.testing.expectEqualStrings(
        "https://api.moonshot.ai/anthropic/v1/messages",
        try CHANNELS[3].endpointFor(PROFILE.endpoint_policy, .anthropic_messages, null, &buffer),
    );
    // An override cannot cross protocols: the Anthropic route needs its marker.
    try std.testing.expectError(
        error.MissingRequiredEndpointPath,
        CHANNELS[2].endpointFor(PROFILE.endpoint_policy, .anthropic_messages, "https://api.moonshot.cn/v1", &buffer),
    );
    for (CHANNELS) |channel| for (channel.routes) |route| {
        try std.testing.expectEqual(profile.Vendor.kimi, route.dialect.?);
    };
    // K2.7-code is not offered where the Anthropic surface cannot serve it.
    try std.testing.expect(MODELS[2].servesProtocol(.openai_chat));
    try std.testing.expect(!MODELS[2].servesProtocol(.anthropic_messages));
    try std.testing.expect(MODELS[0].servesProtocol(.anthropic_messages));
}
