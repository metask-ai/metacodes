//! Z.AI / 智谱 GLM Coding Plan provider profile.
//!
//! Integration notes — the GLM dialect, thinking parameters per generation, and
//! their sources — live in `src/api/dialects/glm.zig`; this file is the route
//! data.
//!
//! The Coding Plan is a separate product surface from the general Z.AI API: it
//! has its own credentials, quota, and billing, and its own endpoints. Four
//! channels cover the documented region × protocol matrix:
//!
//! ```text
//! cn-openai         https://open.bigmodel.cn/api/coding/paas/v4   openai_chat
//! cn-anthropic      https://open.bigmodel.cn/api/anthropic        anthropic_messages
//! global-openai     https://api.z.ai/api/coding/paas/v4           openai_chat
//! global-anthropic  https://api.z.ai/api/anthropic                anthropic_messages
//! ```
//!
//! China is the default launch path; "global" is a channel, not a core switch.
//!
//! The endpoint policy is the load-bearing part. A profile-level forbidden
//! fragment (`/api/paas/v4`) makes it impossible for an explicit `base_url`
//! override to fall back to the general Z.AI surface, and each route requires
//! its own path marker so an override cannot cross protocols either. Both
//! checks run before a request URL is constructed.
//!
//! Model metadata is conservative on purpose: only limits the vendor documents
//! are declared.
//!
//! Every quote here stays `unknown`, and that is the correct value rather than
//! a gap. The Coding Plan is a **subscription**: the user pays a plan fee, and
//! the per-token list price of the general API is not what they are billed.
//! Publishing a per-token number for these channels would be a fabricated
//! price wearing the same type as a real one — precisely what "unknown, never
//! zero" exists to prevent. A plan-aware quote needs the account's plan and
//! remaining quota, which only a catalog/quota refresh can supply.

const std = @import("std");
const ids = @import("../ids.zig");
const offer = @import("../offer.zig");
const profile = @import("../profile.zig");
const controls = @import("../controls.zig");

const Slug = ids.Slug;

pub const CN_OPENAI_BASE = "https://open.bigmodel.cn/api/coding/paas/v4";
pub const CN_ANTHROPIC_BASE = "https://open.bigmodel.cn/api/anthropic";
pub const GLOBAL_OPENAI_BASE = "https://api.z.ai/api/coding/paas/v4";
pub const GLOBAL_ANTHROPIC_BASE = "https://api.z.ai/api/anthropic";

/// The general (non-Coding-Plan) Z.AI surface. Never a valid Coding Plan route.
pub const GENERAL_SURFACE_FRAGMENT = "/api/paas/v4";

const CODING_CAPABILITIES = (offer.CapabilityMatrix{
    .provenance = offer.Provenance.known(.builtin_profile, null),
})
    .with(.tools, .supported)
    .with(.streaming, .supported)
    .with(.reasoning, .supported)
    // GLM returns a peer `reasoning_content` field rather than a thinking block.
    .with(.reasoning_content, .supported);

/// GLM-5.3 always reasons; `reasoning_effort` picks how much (default
/// `max`). Disabling thinking fails the request (docs.z.ai guides/llm/glm-5.3,
/// 2026-10), so there is no "off" here.
const GLM53_EFFORTS = [_][]const u8{ "low", "high", "max" };

const GLM53_CONTROLS = [_]controls.ControlSpec{.{
    .id = "reasoning_effort",
    .label = "Reasoning effort",
    .kind = .enumeration,
    .allowed_values = &GLM53_EFFORTS,
}};

/// 1M-token window, 128K output (docs.z.ai guides/llm/glm-5.3 and
/// guides/vlm/glm-5.3-flash). Declared as the round numbers the vendor
/// states, so a request never asks for more than it documents.
const GLM53_LIMITS = offer.EffectiveLimits{
    .context_window = 1_000_000,
    .max_output_tokens = 128_000,
    .token_counting = .{ .mode = .provider_reported, .unit = .tokens },
    .provenance = offer.Provenance.known(.builtin_profile, null),
};

/// The models the Coding Plan serves (docs.z.ai devpack/overview, 2026-10):
/// GLM-5.3, the flagship, and GLM-5.3-Flash, its multimodal sibling. Older
/// ids are re-routed by the plan itself (GLM-5.2/5.1 to 5.3, GLM-4.7 to
/// 5.3-Flash), and `--model` still sends any id the user names.
const MODELS = [_]profile.ModelEntry{
    .{
        .request_model_id = "glm-5.3",
        .display_name = "GLM-5.3",
        .canonical_model_id = "zai/glm-5.3",
        .limits = GLM53_LIMITS,
        .capabilities = CODING_CAPABILITIES,
        .controls = &GLM53_CONTROLS,
    },
    .{
        .request_model_id = "glm-5.3-flash",
        .display_name = "GLM-5.3-Flash",
        .canonical_model_id = "zai/glm-5.3-flash",
        .limits = GLM53_LIMITS,
        .capabilities = CODING_CAPABILITIES.with(.vision, .supported),
        .controls = &GLM53_CONTROLS,
    },
};

const OPENAI_REQUIRED = [_][]const u8{"/coding/"};
const ANTHROPIC_REQUIRED = [_][]const u8{"/anthropic"};
const FORBIDDEN = [_][]const u8{GENERAL_SURFACE_FRAGMENT};

// Both wires speak the GLM dialect (`src/api/dialects/glm.zig`).
const OPENAI_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .openai_chat,
    .policy = .{ .required_path_fragments = &OPENAI_REQUIRED },
    .dialect = .glm,
}};

const ANTHROPIC_ROUTES = [_]profile.ProtocolRoute{.{
    .protocol = .anthropic_messages,
    .policy = .{ .required_path_fragments = &ANTHROPIC_REQUIRED },
    .dialect = .glm,
}};

const CHANNELS = [_]profile.ChannelDescriptor{
    .{
        .id = Slug.lit("cn-anthropic"),
        .display_name = "GLM Coding Plan · China · Anthropic wire",
        .base_url = CN_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "cn",
        .plan = "coding",
    },
    .{
        .id = Slug.lit("cn-openai"),
        .display_name = "GLM Coding Plan · China · OpenAI wire",
        .base_url = CN_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "cn",
        .plan = "coding",
    },
    .{
        .id = Slug.lit("global-anthropic"),
        .display_name = "GLM Coding Plan · Global · Anthropic wire",
        .base_url = GLOBAL_ANTHROPIC_BASE,
        .routes = &ANTHROPIC_ROUTES,
        .region = "global",
        .plan = "coding",
    },
    .{
        .id = Slug.lit("global-openai"),
        .display_name = "GLM Coding Plan · Global · OpenAI wire",
        .base_url = GLOBAL_OPENAI_BASE,
        .routes = &OPENAI_ROUTES,
        .region = "global",
        .plan = "coding",
    },
};

const CREDENTIAL_KINDS = [_]profile.CredentialKind{.zai_coding_plan_api_key};

/// Where a Coding Plan key is created (docs.bigmodel.cn/cn/coding-plan/notice/
/// api-key-management, docs.z.ai/devpack/notice/api-key-management, 2026-10).
/// Since 2026-10-16 standard and plan keys are separate: a key from the
/// standard API-key page bills the account balance even on these endpoints,
/// which is why every page here is a plan page. The check lists the plan's
/// models over the OpenAI wire: it answers 401 without a valid key and is not
/// a model call.
const KEY_PAGES = [_]profile.KeyPage{
    .{
        .id = Slug.lit("cn-personal"),
        .label = "China · Personal Coding Plan",
        .url = "https://bigmodel.cn/coding-plan/personal/overview",
        .check_url = CN_OPENAI_BASE ++ "/models",
        .region = "cn",
    },
    .{
        .id = Slug.lit("cn-team"),
        .label = "China · Team Coding Plan",
        .url = "https://bigmodel.cn/coding-plan?z_plan=team",
        .check_url = CN_OPENAI_BASE ++ "/models",
        .region = "cn",
    },
    .{
        .id = Slug.lit("global-personal"),
        .label = "Global · Personal Coding Plan",
        .url = "https://z.ai/manage-apikey/apikey-list",
        .check_url = GLOBAL_OPENAI_BASE ++ "/models",
        .region = "global",
    },
    .{
        .id = Slug.lit("global-team"),
        .label = "Global · Team Coding Plan",
        .url = "https://z.ai/manage-apikey/coding-plan/team/my-plan",
        .check_url = GLOBAL_OPENAI_BASE ++ "/models",
        .region = "global",
    },
};

const KEY_SETUP = profile.ApiKeySetup{
    .kind = .zai_coding_plan_api_key,
    .pages = &KEY_PAGES,
    .note = "Create the key on your Coding Plan page. A key from the standard API Key page is billed to your balance, not your plan.",
};

/// `ZAI_API_KEY` is the documented canonical name; the other two are accepted
/// aliases. Adding an alias is a change to this list, not to the resolver.
const ENV_ALIASES = [_]profile.EnvAlias{
    .{ .name = "ZAI_API_KEY", .kind = .zai_coding_plan_api_key, .canonical = true },
    .{ .name = "GLM_API_KEY", .kind = .zai_coding_plan_api_key },
    .{ .name = "Z_AI_API_KEY", .kind = .zai_coding_plan_api_key },
};

/// Coding Plan error classification.
///
/// Only genuine capacity pressure is retryable. An invalid key, a request that
/// landed on the wrong surface, an exhausted plan quota, and a permission
/// failure all fail immediately: retrying them burns the backoff budget and
/// hides the real cause.
pub fn classifyError(status: u16, body: []const u8) profile.ErrorClass {
    if (status == 429) {
        // The plan reports exhausted quota with the same status as throttling;
        // only the throttling case may back off and retry.
        if (containsAny(body, &.{ "quota", "insufficient", "余额", "配额" })) return .quota_exceeded;
        return .rate_limited;
    }
    if (status == 401) {
        if (containsAny(body, &.{ "expired", "过期" })) return .auth_expired;
        return .auth_invalid;
    }
    if (status == 403) return .permission_denied;
    if (status == 404) return .wrong_endpoint;
    if (status == 400 or status == 422) {
        if (containsAny(body, &.{ "model", "not found", "不存在" })) return .wrong_endpoint;
        return .bad_request;
    }
    if (status >= 500 and status <= 599) return .transient_overload;
    return .unknown;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

pub const PROFILE = profile.ProviderProfile{
    .id = Slug.lit("zai-coding-plan"),
    .implementation_id = Slug.lit("zai"),
    .display_name = "Z.AI GLM Coding Plan",
    .aliases = &.{ "glm-coding-plan", "zai", "glm" },
    .channels = &CHANNELS,
    .models = &MODELS,
    .accepted_credential_kinds = &CREDENTIAL_KINDS,
    .env_aliases = &ENV_ALIASES,
    .auth = .bearer,
    // China is the launch default; the Anthropic wire is the better-exercised
    // transport in this codebase, so it is the default channel.
    .default_channel = Slug.lit("cn-anthropic"),
    .api_key_setup = KEY_SETUP,
    .endpoint_policy = .{ .forbidden_path_fragments = &FORBIDDEN },
    .classify_error = classifyError,
};

// ── tests ────────────────────────────────────────────────────────────────────

fn channelById(comptime id: []const u8) profile.ChannelDescriptor {
    return PROFILE.channel(Slug.lit(id)).?;
}

test "coding plan profile is structurally valid" {
    try profile.validateProfile(PROFILE);
}

test "all four documented region/protocol routes build the expected endpoint" {
    var buffer: [256]u8 = undefined;
    const cases = [_]struct {
        channel: []const u8,
        protocol: profile.Protocol,
        expected: []const u8,
    }{
        .{
            .channel = "cn-openai",
            .protocol = .openai_chat,
            .expected = "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions",
        },
        .{
            .channel = "cn-anthropic",
            .protocol = .anthropic_messages,
            .expected = "https://open.bigmodel.cn/api/anthropic/v1/messages",
        },
        .{
            .channel = "global-openai",
            .protocol = .openai_chat,
            .expected = "https://api.z.ai/api/coding/paas/v4/chat/completions",
        },
        .{
            .channel = "global-anthropic",
            .protocol = .anthropic_messages,
            .expected = "https://api.z.ai/api/anthropic/v1/messages",
        },
    };
    inline for (cases) |case| {
        const descriptor = channelById(case.channel);
        const url = try descriptor.endpointFor(PROFILE.endpoint_policy, case.protocol, null, &buffer);
        try std.testing.expectEqualStrings(case.expected, url);
    }
}

test "an override can never reach the general Z.AI surface" {
    var buffer: [256]u8 = undefined;
    const openai_channel = channelById("cn-openai");
    try std.testing.expectError(error.ForbiddenEndpointPath, openai_channel.endpointFor(
        PROFILE.endpoint_policy,
        .openai_chat,
        "https://open.bigmodel.cn/api/paas/v4",
        &buffer,
    ));
    const anthropic_channel = channelById("cn-anthropic");
    try std.testing.expectError(error.ForbiddenEndpointPath, anthropic_channel.endpointFor(
        PROFILE.endpoint_policy,
        .anthropic_messages,
        "https://open.bigmodel.cn/api/paas/v4",
        &buffer,
    ));
}

test "an override must keep the selected protocol's path contract" {
    var buffer: [256]u8 = undefined;
    const openai_channel = channelById("cn-openai");
    // The Anthropic base is a valid Coding Plan URL but not for this route.
    try std.testing.expectError(error.MissingRequiredEndpointPath, openai_channel.endpointFor(
        PROFILE.endpoint_policy,
        .openai_chat,
        CN_ANTHROPIC_BASE,
        &buffer,
    ));
    // A private relay that keeps the contract is accepted.
    const relayed = try openai_channel.endpointFor(
        PROFILE.endpoint_policy,
        .openai_chat,
        "https://relay.internal/api/coding/paas/v4",
        &buffer,
    );
    try std.testing.expectEqualStrings("https://relay.internal/api/coding/paas/v4/chat/completions", relayed);
}

test "all three environment aliases are accepted with one canonical name" {
    try std.testing.expectEqualStrings(
        "ZAI_API_KEY",
        PROFILE.canonicalEnvAlias(.zai_coding_plan_api_key).?,
    );
    var seen: usize = 0;
    for (PROFILE.env_aliases) |alias| {
        if (std.mem.eql(u8, alias.name, "ZAI_API_KEY") or
            std.mem.eql(u8, alias.name, "GLM_API_KEY") or
            std.mem.eql(u8, alias.name, "Z_AI_API_KEY")) seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    // Coding Plan credentials are their own kind, never a general Z.AI key.
    try std.testing.expectEqual(@as(usize, 1), PROFILE.accepted_credential_kinds.len);
    try std.testing.expectEqual(
        profile.CredentialKind.zai_coding_plan_api_key,
        PROFILE.accepted_credential_kinds[0],
    );
}

test "error classification bounds retries to genuine capacity pressure" {
    try std.testing.expectEqual(profile.ErrorClass.rate_limited, classifyError(429, "{\"error\":\"too many requests\"}"));
    try std.testing.expect(classifyError(429, "{\"error\":\"too many requests\"}").isRetryableTransport());

    try std.testing.expectEqual(profile.ErrorClass.quota_exceeded, classifyError(429, "{\"error\":\"quota exhausted\"}"));
    try std.testing.expect(!classifyError(429, "{\"error\":\"quota exhausted\"}").isRetryableTransport());

    try std.testing.expectEqual(profile.ErrorClass.auth_invalid, classifyError(401, "{\"error\":\"invalid api key\"}"));
    try std.testing.expect(!classifyError(401, "{\"error\":\"invalid api key\"}").isRetryableTransport());
    try std.testing.expectEqual(profile.ErrorClass.auth_expired, classifyError(401, "{\"error\":\"token expired\"}"));

    try std.testing.expectEqual(profile.ErrorClass.wrong_endpoint, classifyError(404, ""));
    try std.testing.expectEqual(profile.ErrorClass.permission_denied, classifyError(403, ""));
    try std.testing.expectEqual(profile.ErrorClass.transient_overload, classifyError(503, ""));
    try std.testing.expect(classifyError(503, "").isRetryableTransport());
}

test "every Coding Plan model declares its limits and its reasoning levels" {
    for (MODELS) |entry| {
        try std.testing.expectEqual(@as(?u32, 1_000_000), entry.limits.context_window);
        try std.testing.expectEqual(@as(?u32, 128_000), entry.limits.max_output_tokens);
        try std.testing.expect(entry.limits.admit(.{ .input_tokens = 10, .requested_output_tokens = 10 }, .{}).isAdmitted());
        const spec = controls.findSpec(entry.controls, "reasoning_effort").?;
        try std.testing.expectEqual(@as(usize, 3), spec.allowed_values.len);
        for (spec.allowed_values) |value| try std.testing.expect(@import("../../types.zig").ReasoningEffort.parse(value) != null);
    }
    // Unknown limits would still fail closed; nothing here relies on that.
    const unknown = offer.EffectiveLimits{};
    const decision = unknown.admit(.{ .input_tokens = 10, .requested_output_tokens = 10 }, .{});
    try std.testing.expect(!decision.isAdmitted());
    try std.testing.expectEqual(offer.RejectionReason.unknown_limit_fail_closed, decision.rejected.reason);
}

test "coding-plan quotes stay unknown because the plan is not billed per token" {
    for (MODELS) |entry| {
        try std.testing.expect(!entry.quote.isKnown());
        // Unknown must also mean "no estimate", not "an estimate of zero".
        try std.testing.expectEqual(
            @as(?u64, null),
            entry.quote.estimateMicros(.{ .input_tokens = 1_000_000, .output_tokens = 1_000_000 }),
        );
    }
    try std.testing.expect(PROFILE.quote_hook == null);
}

test "the Coding Plan key pages are plan pages, checked on the plan's own endpoint" {
    try profile.validateProfile(PROFILE);
    const setup = PROFILE.api_key_setup.?;
    try std.testing.expectEqual(@as(usize, 4), setup.pages.len);
    for (setup.pages) |page| {
        // Never the standard API-key page, whose keys bill the balance.
        try std.testing.expect(std.mem.indexOf(u8, page.url, "usercenter/proj-mgmt/apikeys") == null);
        try std.testing.expect(std.mem.indexOf(u8, page.check_url.?, "/api/coding/paas/v4/models") != null);
    }
    // The default page follows the channel's region.
    try std.testing.expectEqualStrings("cn-personal", PROFILE.defaultKeyPage(Slug.lit("cn-anthropic")).?.id.slice());
    try std.testing.expectEqualStrings("global-personal", PROFILE.defaultKeyPage(Slug.lit("global-openai")).?.id.slice());
    try std.testing.expectEqualStrings("cn-personal", PROFILE.defaultKeyPage(null).?.id.slice());
    try std.testing.expectEqualStrings("Global · Team Coding Plan", PROFILE.keyPage("global-team").?.label);
}
