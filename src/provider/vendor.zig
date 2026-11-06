//! The vendors that have a dialect of their own.
//!
//! A wire protocol (`Protocol.Wire`) says how the bytes are framed — OpenAI
//! chat, Anthropic messages, Gemini. A *dialect* says what the vendor behind
//! that wire expects inside it: how thinking is switched on, which effort words
//! exist, which non-standard fields are accepted. Two routes on the same wire
//! can need different dialects (DeepSeek's own endpoint versus the same model
//! through OpenRouter), and one vendor can be reached over several wires.
//!
//! Today the vendor is recognised from the model name
//! (`src/api/dialects/registry.zig`). The type lives in the provider kernel so
//! that a route can name its vendor without reaching into the transport layer.
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

test "Vendor.parse accepts exactly the tag names" {
    try std.testing.expectEqual(Vendor.deepseek, Vendor.parse("deepseek").?);
    try std.testing.expectEqual(Vendor.mistral, Vendor.parse("mistral").?);
    try std.testing.expect(Vendor.parse("DeepSeek") == null);
    try std.testing.expect(Vendor.parse("") == null);
    inline for (@typeInfo(Vendor).@"enum".fields) |field| {
        try std.testing.expectEqual(@field(Vendor, field.name), Vendor.parse(field.name).?);
    }
}
