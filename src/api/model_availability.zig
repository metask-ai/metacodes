//! How a model name someone asks for becomes a model the current provider
//! takes: tier-name resolution, then the provider guard.
//!
//! One rule for every surface that switches a Session's model by name: the
//! TUI and `--web`/`serve` (`SessionService.setModel`/`setTurnModel`, the
//! REPL's `/model use`) and the library's `SessionHost` (#445). A tier name
//! (`low`/`mid`/`high`, or `haiku`/`sonnet`/`opus`) resolves through the
//! provider's tier table; a tier the table leaves unset stays the literal
//! name, which the guard then refuses, so a tier never becomes another
//! provider's hard-coded id. The guard takes a model the provider's catalog
//! lists, or one whose id names the provider (`claude-`, `gpt`/`o1`/`o3`,
//! `gemini`).

const std = @import("std");
const types = @import("../types.zig");
const model_name = @import("model_name.zig");
const model_tiers = @import("model_tiers.zig");

/// What a refusal of the guard says, on every surface.
pub const unavailable_reason = "model not available for current provider";

/// The provider a model id names by its prefix, or null when it names none.
pub fn providerForModel(model: []const u8) ?types.ProviderKind {
    if (model_name.startsWithIgnoreCase(model, "claude-")) return .anthropic;
    if (model_name.startsWithIgnoreCase(model, "gpt") or model_name.startsWithIgnoreCase(model, "o1") or model_name.startsWithIgnoreCase(model, "o3")) return .openai;
    if (model_name.startsWithIgnoreCase(model, "gemini")) return .gemini;
    return null;
}

/// The model `requested` names: trimmed, and a tier name resolved through
/// `tiers` (the current provider's table). A tier `tiers` leaves unset, or
/// any tier without a table, stays the literal name. Borrowed from
/// `requested` or `tiers`.
pub fn resolveTierName(tiers: ?*const model_tiers.ProviderTiers, requested: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, requested, " \t");
    return model_tiers.resolveName(tiers, trimmed).model orelse trimmed;
}

/// The provider guard: whether `provider` takes `model`. `listed` = the
/// provider's catalog lists it (matched ignoring case).
pub fn available(provider: types.ProviderKind, listed: bool, model: []const u8) bool {
    if (listed) return true;
    const named = providerForModel(model) orelse return false;
    return named == provider;
}

test "resolveTierName resolves a configured tier and leaves the rest literal" {
    var tiers = model_tiers.ProviderTiers{};
    var high = "gpt-5.6-sol".*;
    tiers.high.model = &high;
    try std.testing.expectEqualStrings("gpt-5.6-sol", resolveTierName(&tiers, " high "));
    try std.testing.expectEqualStrings("gpt-5.6-sol", resolveTierName(&tiers, "opus"));
    // Unset tier, no table: the literal name, for the guard to refuse.
    try std.testing.expectEqualStrings("low", resolveTierName(&tiers, "low"));
    try std.testing.expectEqualStrings("mid", resolveTierName(null, "mid"));
    try std.testing.expectEqualStrings("gpt-4o", resolveTierName(&tiers, "gpt-4o"));
    try std.testing.expectEqualStrings("", resolveTierName(&tiers, "  "));
    try std.testing.expectEqualStrings("inherit", resolveTierName(&tiers, "inherit"));
}

test "available takes a listed model or one whose id names the provider" {
    try std.testing.expect(available(.anthropic, false, "claude-opus-4-6"));
    try std.testing.expect(!available(.anthropic, false, "gpt-4o"));
    try std.testing.expect(available(.openai, false, "o3-mini"));
    try std.testing.expect(!available(.openai, false, "high"));
    try std.testing.expect(!available(.bedrock, false, "claude-opus-4-6"));
    try std.testing.expect(available(.openai, true, "deepseek-chat"));
    try std.testing.expect(!available(.gemini, false, ""));
}
