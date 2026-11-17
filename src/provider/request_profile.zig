//! What one endpoint requires of every request on a route, beyond its wire
//! and its model vendor's dialect.
//!
//! A wire (`Protocol.Wire`) says how the bytes are framed; a dialect
//! (`vendor.zig`) says what the vendor behind the model expects inside them.
//! Some endpoints add requirements of their own that neither covers. ChatGPT's
//! Codex backend speaks the OpenAI Responses wire to OpenAI's models, yet it
//! wants headers the public Responses API does not, and refuses requests that
//! API takes. Those requirements belong to the endpoint: the same GPT model on
//! `api.openai.com` must not get them, so they cannot live in the dialect.
//!
//! A profile is a reviewed, named value, never configuration: it decides which
//! headers and fields reach the network, and a config file that could name
//! arbitrary headers could send a token's account anywhere. A route names one
//! (`ProtocolRoute.request_profile`); the offer's dialect declaration carries
//! it to every client built on the route, subagents and teammates included
//! (`vendor.Declaration.request_profile`); the transport applies it.

const std = @import("std");

pub const RequestProfile = enum {
    /// ChatGPT's Codex backend (`https://chatgpt.com/backend-api/codex`), the
    /// unofficial `chatgpt-codex` sign-in. Nothing here is documented; it is
    /// what the Codex CLI (`openai/codex`), OpenCode and pi send, and OpenAI
    /// may change it at any time:
    /// - `originator` names the client. The Codex CLI writes `codex_cli_rs`,
    ///   OpenCode `opencode`, pi `pi`; this one is `metacodes`.
    /// - `chatgpt-account-id` names the ChatGPT workspace the token is for.
    /// - The answer is an event stream, said so in `accept`.
    /// - With `store:false` (the only value it takes) the server keeps no
    ///   reasoning between turns, and returns it encrypted only when asked
    ///   (`include`); the transport already sends such items back verbatim.
    /// - `instructions` must be present, even empty.
    /// - A requested output limit is refused; the Responses serializer never
    ///   sends `max_output_tokens`.
    chatgpt_codex,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Fixed headers every request on the route carries, in this order.
    pub fn headers(self: RequestProfile) []const Header {
        return switch (self) {
            .chatgpt_codex => &.{
                .{ .name = "originator", .value = ORIGINATOR },
                .{ .name = "accept", .value = "text/event-stream" },
            },
        };
    }

    /// Whether a request names the ChatGPT workspace its access token is for
    /// (`chatgpt-account-id`, read from the token: `chatgpt_claims.zig`).
    pub fn sendsChatgptAccount(self: RequestProfile) bool {
        return switch (self) {
            .chatgpt_codex => true,
        };
    }

    /// Entries of the Responses `include` array; empty sends none.
    pub fn responsesInclude(self: RequestProfile) []const []const u8 {
        return switch (self) {
            .chatgpt_codex => &.{"reasoning.encrypted_content"},
        };
    }

    /// Whether the Responses body carries `instructions` even when there is
    /// no system prompt (as `""`).
    pub fn requiresInstructions(self: RequestProfile) bool {
        return switch (self) {
            .chatgpt_codex => true,
        };
    }
};

/// What `originator` says this client is, on the authorization request and on
/// every request: the plan's honest-identity rule (plan §3.5 item 5).
pub const ORIGINATOR = "metacodes";

test "the Codex profile names metacodes as its originator and asks for encrypted reasoning" {
    const profile = RequestProfile.chatgpt_codex;
    try std.testing.expectEqualStrings("originator", profile.headers()[0].name);
    try std.testing.expectEqualStrings("metacodes", profile.headers()[0].value);
    try std.testing.expectEqualStrings("text/event-stream", profile.headers()[1].value);
    try std.testing.expect(profile.sendsChatgptAccount());
    try std.testing.expect(profile.requiresInstructions());
    try std.testing.expectEqualStrings("reasoning.encrypted_content", profile.responsesInclude()[0]);
}
