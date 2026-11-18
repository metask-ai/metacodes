//! ChatGPT (Codex) provider profile: a ChatGPT plan's Codex quota, reached the
//! way the Codex CLI reaches it. Unofficial.
//!
//! OpenAI documents no third-party use of this. The sign-in reuses the Codex
//! CLI's public OAuth client, and requests go to the backend the Codex CLI
//! talks to; OpenCode, pi and KWWK do the same. OpenAI can change or block any
//! of it at any time, so the sign-in says so before it starts
//! (`oauth_support = .unofficial`), and nothing else depends on it: it is one
//! provider, and the others keep working when it stops.
//!
//! What is sent, and where it comes from (plan appendix B; read from the code
//! of `openai/codex`, OpenCode `packages/core/src/plugin/provider/openai.ts`,
//! pi `packages/ai/src/auth/oauth/openai-codex.ts`; implemented from that
//! protocol here, no code taken):
//!
//! - Sign-in: authorization code + PKCE at `auth.openai.com/oauth/authorize`,
//!   client `app_EMoamEEZ73f0CkXaXp7hrann`, scope `openid profile email
//!   offline_access`, redirect `http://localhost:<port>/auth/callback` where
//!   the port is 1455 or 1457 (the only ones the client registered), and three
//!   extra parameters: `id_token_add_organizations=true`,
//!   `codex_cli_simplified_flow=true`, and `originator=metacodes` (the Codex
//!   CLI says `codex_cli_rs`, OpenCode `opencode`, pi `pi`).
//! - Tokens: `auth.openai.com/oauth/token`, form-encoded, for the grant and
//!   for the refresh; the refresh rotates the refresh token. The ChatGPT
//!   workspace the tokens are for is in the ID token's
//!   `https://api.openai.com/auth` claim, stored as the login's account
//!   (`provider/chatgpt_claims.zig`).
//! - Sign-out: the refresh token is revoked at `auth.openai.com/oauth/revoke`
//!   (JSON), best effort, before the local login is deleted.
//! - Requests: the Responses wire at `chatgpt.com/backend-api/codex/responses`
//!   with the Codex request profile (`provider/request_profile.zig`):
//!   `originator`, `chatgpt-account-id`, `accept: text/event-stream`,
//!   `store:false`, `include:["reasoning.encrypted_content"]`, `instructions`
//!   always, no `max_output_tokens`.
//! - Limits: a used-up plan answers 429 with `error.type` `usage_limit_reached`
//!   and `resets_at` (unix seconds), or `usage_not_included` for a plan
//!   without Codex. Neither is retried (`api/openai_client.zig`).
//!
//! The model list is static (plan appendix B, 2026-11). The backend lists the
//! models it serves at `/models?client_version=<version>`, filtered by each
//! model's minimum client version; this client sends its own version, never
//! the Codex CLI's, so it may see fewer than the Codex CLI does. Context
//! windows are OpenCode's figures for ChatGPT-plan requests (272k, 500k from
//! GPT-6.1 on); the backend has not been asked. Every quote is `unknown`: the
//! plan is a monthly fee.
//!
//! Not done: the device-code sign-in the Codex CLI offers for SSH sessions
//! (`/api/accounts/deviceauth/*`, plan appendix B §7), the usage headers
//! (`x-codex-primary-used-percent` and friends), and zstd request bodies,
//! which the backend wants for bodies over about 1 MiB.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");
const request_profile = @import("../request_profile.zig");

const Slug = ids.Slug;

pub const BASE_URL = "https://chatgpt.com/backend-api/codex";

pub const AUTH_ORIGIN = "https://auth.openai.com";
pub const OAUTH_AUTHORIZE_URL = AUTH_ORIGIN ++ "/oauth/authorize";
pub const OAUTH_TOKEN_URL = AUTH_ORIGIN ++ "/oauth/token";
pub const OAUTH_REVOKE_URL = AUTH_ORIGIN ++ "/oauth/revoke";

/// The Codex CLI's public client (`openai/codex`,
/// `codex-rs/login/src/auth/manager.rs`).
pub const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const SCOPE = "openid profile email offline_access";

/// The redirect ports the client registered, in the order the Codex CLI and
/// OpenCode try them. Metask's own sign-in listens on the same two.
pub const CALLBACK_PORTS = [_]u16{ 1455, 1457 };

const AUTHORIZE_PARAMS = [_]profile.OAuthParam{
    .{ .name = "id_token_add_organizations", .value = "true" },
    .{ .name = "codex_cli_simplified_flow", .value = "true" },
    .{ .name = "originator", .value = request_profile.ORIGINATOR },
};

/// Reasoning levels offered: the ones the GPT-5.6 and GPT-6 models share.
/// `max`, which the API takes on GPT-6, is left out until the backend has been
/// seen to take it.
const EFFORTS = [_][]const u8{ "low", "medium", "high", "xhigh" };

const EFFORT_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &EFFORTS,
    .cost_latency_warning = "xhigh uses more of the plan and answers slower",
}};

const CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported)
    .with(.reasoning, .supported);

const WINDOW_272K: u32 = 272_000;
const WINDOW_500K: u32 = 500_000;

fn model(comptime request_model_id: []const u8, comptime display_name: []const u8, comptime window: u32) profile.ModelEntry {
    return .{
        .request_model_id = request_model_id,
        .display_name = display_name,
        .canonical_model_id = "openai/" ++ request_model_id,
        .limits = .{
            .context_window = window,
            .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
            .provenance = offer.Provenance.known(.builtin_profile, null),
        },
        .capabilities = CAPABILITIES,
        .controls = &EFFORT_CONTROLS,
    };
}

/// Plan appendix B (2026-11), newest first.
const MODELS = [_]profile.ModelEntry{
    model("gpt-6.1-sol", "GPT-6.1 Sol", WINDOW_500K),
    model("gpt-6.1-terra", "GPT-6.1 Terra", WINDOW_500K),
    model("gpt-6-astra", "GPT-6 Astra", WINDOW_272K),
    model("gpt-6-sol", "GPT-6 Sol", WINDOW_272K),
    model("gpt-6-luna", "GPT-6 Luna", WINDOW_272K),
    model("gpt-5.6-sol", "GPT-5.6 Sol", WINDOW_272K),
    model("gpt-5.6-terra", "GPT-5.6 Terra", WINDOW_272K),
    model("gpt-5.6-luna", "GPT-5.6 Luna", WINDOW_272K),
};

const ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_responses,
    .dialect = .openai,
    .request_profile = .chatgpt_codex,
}};

const CHANNELS = [_]profile.ChannelDescriptor{.{
    .id = Slug.lit("default"),
    .display_name = "ChatGPT (Codex)",
    .base_url = BASE_URL,
    .routes = &ROUTES,
    .plan = "chatgpt",
}};

/// The Codex token is its own kind: an OpenAI API key cannot stand in for it,
/// and it is never offered to the `openai` profile's endpoint.
const CREDENTIAL_KINDS = [_]profile.CredentialKind{.openai_codex_oauth};

/// The backend's answers, as the Codex CLI reads them
/// (`codex-rs/codex-api/src/api_bridge.rs`): a used-up plan and a plan without
/// Codex are 429s that waiting a few seconds does not change.
pub fn classifyError(status: u16, body: []const u8) profile.ErrorClass {
    if (status == 429) {
        if (std.mem.indexOf(u8, body, "usage_limit_reached") != null) return .quota_exceeded;
        if (std.mem.indexOf(u8, body, "usage_not_included") != null) return .permission_denied;
        return .rate_limited;
    }
    return profile.defaultClassifyError(status, body);
}

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("chatgpt-codex"),
    .implementation_id = Slug.lit("chatgpt-codex"),
    .display_name = "ChatGPT (Codex)",
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .auth = .bearer,
    .default_channel = Slug.lit("default"),
    .classify_error = classifyError,
    .oauth_token_url = OAUTH_TOKEN_URL,
    .oauth_authorize_url = OAUTH_AUTHORIZE_URL,
    .oauth_redirect_host = "localhost",
    .oauth_callback_ports = &CALLBACK_PORTS,
    .oauth_authorize_params = &AUTHORIZE_PARAMS,
    .oauth_revocation = .{ .url = OAUTH_REVOKE_URL, .body = .json },
    .oauth_support = .unofficial,
    .oauth_client_id = CLIENT_ID,
    .oauth_scope = SCOPE,
    // A ChatGPT plan, billed by the month (plan §3.2): an unattended start
    // on it says so once.
    .subscription_plan = true,
};

// ── tests ────────────────────────────────────────────────────────────────────

test "chatgpt-codex profile is structurally valid" {
    try profile.validateProfile(PROFILE);
}

test "chatgpt-codex: the Responses wire on the Codex backend, with the Codex request profile" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://chatgpt.com/backend-api/codex/responses",
        try CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_responses, null, &buffer),
    );
    try std.testing.expectError(error.ProtocolNotSupportedByChannel, CHANNELS[0].endpointFor(PROFILE.endpoint_policy, .openai_chat, null, &buffer));
    try std.testing.expectEqual(request_profile.RequestProfile.chatgpt_codex, ROUTES[0].request_profile.?);
}

test "chatgpt-codex: the sign-in is the Codex client's, on its two ports, and says it is unofficial" {
    try std.testing.expect(PROFILE.declaresInteractiveOAuth());
    try std.testing.expectEqualStrings("app_EMoamEEZ73f0CkXaXp7hrann", PROFILE.oauth_client_id.?);
    try std.testing.expectEqualSlices(u16, &.{ 1455, 1457 }, PROFILE.oauth_callback_ports);
    try std.testing.expectEqualStrings("localhost", PROFILE.oauth_redirect_host);
    try std.testing.expectEqual(profile.SupportLevel.unofficial, PROFILE.oauth_support);
    try std.testing.expectEqualStrings("metacodes", AUTHORIZE_PARAMS[2].value);
    // Only the Codex token kind, and no variable a key could come from: it
    // takes no key, so there is no key page to paste one from either.
    try std.testing.expectEqualSlices(profile.CredentialKind, &.{.openai_codex_oauth}, PROFILE.accepted_credential_kinds);
    try std.testing.expectEqual(@as(usize, 0), PROFILE.env_aliases.len);
    try std.testing.expect(!PROFILE.takesApiKey());
    try std.testing.expect(PROFILE.api_key_setup == null);
    try std.testing.expect(PROFILE.subscription_plan);
}

test "chatgpt-codex: a used-up plan and a plan without Codex are not retried" {
    const used_up = classifyError(429, "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_at\":1}}");
    try std.testing.expectEqual(profile.ErrorClass.quota_exceeded, used_up);
    try std.testing.expect(!used_up.isRetryableTransport());
    const excluded = classifyError(429, "{\"error\":{\"type\":\"usage_not_included\"}}");
    try std.testing.expectEqual(profile.ErrorClass.permission_denied, excluded);
    try std.testing.expect(!excluded.isRetryableTransport());
    try std.testing.expect(classifyError(429, "{\"error\":{\"type\":\"rate_limit_exceeded\"}}").isRetryableTransport());
    try std.testing.expectEqual(profile.ErrorClass.auth_expired, classifyError(401, ""));
}

test "chatgpt-codex: every model is a Responses model with reasoning levels the neutral type carries" {
    try std.testing.expectEqual(@as(usize, 8), MODELS.len);
    for (MODELS) |entry| {
        const spec = controls.findSpec(entry.controls, "reasoning_effort").?;
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
        try std.testing.expect(entry.limits.context_window.? >= WINDOW_272K);
    }
}
