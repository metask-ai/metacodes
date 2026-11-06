//! Which vendor dialect a route speaks.
//!
//! A wire protocol (`Protocol.Wire`) says how the bytes are framed — OpenAI
//! chat, Anthropic messages, Gemini. A *dialect* says what the vendor behind
//! that wire expects inside it: how thinking is switched on, which effort words
//! exist, which non-standard fields are accepted. Two routes on the same wire
//! can need different dialects (DeepSeek's own endpoint versus the same model
//! through OpenRouter), and one vendor can be reached over several wires.
//!
//! Routes declare their dialect (`ProtocolRoute.dialect`, `ModelEntry.dialect`)
//! the way an OpenRouter endpoint declares its upstream provider. A route that
//! declares none falls back to guessing from the model name — the behaviour
//! every route had before this type existed, kept so custom providers written
//! for it keep working.
//!
//! A declaration has a scope (`Declaration`): a route's covers every model the
//! route serves, a model entry's covers only that model. A provider bound to
//! another model of the same route — a child agent's `model_override`, a
//! teammate, a `/model` switch inside a Session — inherits only the route's.
//!
//! Each value has one integration file, `src/api/dialects/<tag>.zig`, whose
//! header is the integration document for that vendor; the registry
//! (`src/api/dialects/registry.zig`) proves at compile time that every value
//! has one.

const std = @import("std");

pub const Vendor = enum {
    /// OpenAI's own models (GPT, o-series) and the generic OpenAI-compatible
    /// fallback.
    openai,
    /// Anthropic Claude.
    claude,
    /// Google Gemini.
    gemini,
    /// Zhipu / Z.AI GLM.
    glm,
    /// Moonshot Kimi.
    kimi,
    /// DeepSeek.
    deepseek,
    /// Alibaba Qwen (DashScope / Model Studio).
    qwen,
    /// MiniMax.
    minimax,
    /// Mistral.
    mistral,
    /// OpenRouter's normalized request surface, whatever the upstream model.
    openrouter,

    pub fn parse(text: []const u8) ?Vendor {
        inline for (@typeInfo(Vendor).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @field(Vendor, field.name);
        }
        return null;
    }

    pub fn name(self: Vendor) []const u8 {
        return @tagName(self);
    }
};

/// A route's dialect declaration, split by what it covers. `route` comes from
/// `ProtocolRoute.dialect` and covers every model on the route; `model` comes
/// from the bound model's `ModelEntry.dialect` (a gateway serving several
/// vendors' models over one wire) and covers that model only. Both null infers
/// the dialect from the model name.
pub const Declaration = struct {
    route: ?Vendor = null,
    model: ?Vendor = null,

    /// The bound model's own declaration: the entry's, else the route's.
    pub fn bound(self: Declaration) ?Vendor {
        return self.model orelse self.route;
    }

    /// The dialect of a request for `requested` on a provider bound to
    /// `bound_model`: the entry's declaration only for the model it was made
    /// for, the route's for any other model.
    pub fn vendorFor(self: Declaration, bound_model: []const u8, requested: []const u8) ?Vendor {
        if (self.model) |v| if (std.mem.eql(u8, bound_model, requested)) return v;
        return self.route;
    }

    /// What a provider bound to `model` inherits from one bound to
    /// `bound_model` on the same route.
    pub fn rebind(self: Declaration, bound_model: []const u8, model: []const u8) Declaration {
        if (std.mem.eql(u8, bound_model, model)) return self;
        return .{ .route = self.route };
    }
};

test "Declaration: a model entry's dialect covers its model only, the route's every model" {
    const gateway = Declaration{ .model = .claude };
    try std.testing.expectEqual(Vendor.claude, gateway.bound().?);
    try std.testing.expectEqual(Vendor.claude, gateway.vendorFor("claude-sonnet-4-6", "claude-sonnet-4-6").?);
    try std.testing.expect(gateway.vendorFor("claude-sonnet-4-6", "glm-5.2") == null);
    try std.testing.expect(gateway.rebind("claude-sonnet-4-6", "glm-5.2").bound() == null);
    try std.testing.expectEqual(Vendor.claude, gateway.rebind("claude-sonnet-4-6", "claude-sonnet-4-6").bound().?);

    const relay = Declaration{ .route = .deepseek, .model = .kimi };
    try std.testing.expectEqual(Vendor.kimi, relay.vendorFor("m", "m").?);
    try std.testing.expectEqual(Vendor.deepseek, relay.vendorFor("m", "other").?);
    try std.testing.expectEqual(Vendor.deepseek, relay.rebind("m", "other").bound().?);
    try std.testing.expect((Declaration{}).bound() == null);
}

test "Vendor.parse accepts exactly the tag names" {
    try std.testing.expectEqual(Vendor.deepseek, Vendor.parse("deepseek").?);
    try std.testing.expectEqual(Vendor.openrouter, Vendor.parse("openrouter").?);
    try std.testing.expect(Vendor.parse("DeepSeek") == null);
    try std.testing.expect(Vendor.parse("") == null);
    inline for (@typeInfo(Vendor).@"enum".fields) |field| {
        try std.testing.expectEqual(@field(Vendor, field.name), Vendor.parse(field.name).?);
    }
}
