//! The ChatGPT workspace inside OpenAI's OAuth tokens.
//!
//! An OpenAI sign-in's ID token and access token are JWTs whose payload holds
//! `https://api.openai.com/auth`, and in it `chatgpt_account_id`: the ChatGPT
//! workspace (personal account or team) the tokens are for. The Codex backend
//! wants it on every request (`chatgpt-account-id`). The Codex CLI reads it from
//! the ID token; pi and KWWK read it from the access token; OpenCode reads the
//! ID token and falls back to the access token, and also accepts it at the top
//! level of the payload. Both tokens of one grant name the same workspace.
//!
//! Nothing here verifies a signature. The claim only says which workspace the
//! server bound the token to, and the server checks the token it receives; a
//! forged claim gains nothing a forged header would not. What is checked is
//! that the value can travel in a header: printable ASCII, bounded.

const std = @import("std");

/// The claim namespace OpenAI's tokens use for ChatGPT.
pub const AUTH_CLAIM = "https://api.openai.com/auth";

/// Longest account id accepted. Real ones are a UUID; anything far longer is
/// not one, and a header has to carry it.
pub const MAX_ACCOUNT_ID_BYTES = 256;

/// The workspace `jwt` names, or null when it is not a JWT, its payload is not
/// JSON, it names none, or the value could not travel in a header. The slice
/// lives in `arena`.
pub fn accountId(arena: std.mem.Allocator, jwt: []const u8) ?[]const u8 {
    const payload = payloadJson(arena, jwt) orelse return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch return null;
    if (root != .object) return null;
    if (root.object.get(AUTH_CLAIM)) |auth| if (auth == .object) {
        if (headerSafe(stringField(auth.object, "chatgpt_account_id"))) |value| return value;
    };
    return headerSafe(stringField(root.object, "chatgpt_account_id"));
}

/// The account the first of `tokens` that names one names: the ID token
/// before the access token, as the Codex CLI and OpenCode read them.
pub fn firstAccountId(arena: std.mem.Allocator, tokens: []const ?[]const u8) ?[]const u8 {
    for (tokens) |candidate| {
        const token = candidate orelse continue;
        if (accountId(arena, token)) |value| return value;
    }
    return null;
}

/// The decoded payload segment of a compact JWS (`header.payload.signature`).
fn payloadJson(arena: std.mem.Allocator, jwt: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return null;
    const encoded_raw = parts.next() orelse return null;
    _ = parts.next() orelse return null;
    if (parts.next() != null) return null;
    // RFC 7515 encodes without padding; a token that carries it anyway is
    // still the same bytes.
    const encoded = std.mem.trimEnd(u8, encoded_raw, "=");
    if (encoded.len == 0) return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return null;
    const out = arena.alloc(u8, size) catch return null;
    decoder.decode(out, encoded) catch return null;
    return out;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

/// `value` when a request header can carry it as is.
fn headerSafe(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0 or text.len > MAX_ACCOUNT_ID_BYTES) return null;
    for (text) |byte| if (byte < 0x21 or byte > 0x7e) return null;
    return text;
}

// ── tests ────────────────────────────────────────────────────────────────────

/// A JWT whose payload is `payload` (header and signature are placeholders:
/// nothing here reads them).
pub fn testJwt(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(payload.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "eyJhbGciOiJSUzI1NiJ9.{s}.c2ln", .{encoded});
}

test "the workspace is read from the auth claim, then from the top level" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const namespaced = try testJwt(arena, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc-1\",\"chatgpt_plan_type\":\"plus\"},\"email\":\"x@example.com\"}");
    try std.testing.expectEqualStrings("acc-1", accountId(arena, namespaced).?);

    const flat = try testJwt(arena, "{\"chatgpt_account_id\":\"acc-flat\"}");
    try std.testing.expectEqualStrings("acc-flat", accountId(arena, flat).?);

    // The namespace wins over the top level.
    const both = try testJwt(arena, "{\"chatgpt_account_id\":\"top\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"ns\"}}");
    try std.testing.expectEqualStrings("ns", accountId(arena, both).?);
}

test "anything that is not a JWT naming a header-safe workspace yields none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An opaque token (Metask's, an API key) is not a JWT.
    try std.testing.expect(accountId(arena, "at-opaque-token") == null);
    try std.testing.expect(accountId(arena, "a.b") == null);
    try std.testing.expect(accountId(arena, "a.b.c.d") == null);
    try std.testing.expect(accountId(arena, "a.!!!.c") == null);
    try std.testing.expect(accountId(arena, try testJwt(arena, "not json")) == null);
    try std.testing.expect(accountId(arena, try testJwt(arena, "{\"sub\":\"user\"}")) == null);
    try std.testing.expect(accountId(arena, try testJwt(arena, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":7}}")) == null);
    // A value that would split a header, or is not one, is refused.
    try std.testing.expect(accountId(arena, try testJwt(arena, "{\"chatgpt_account_id\":\"a\\r\\nX-Injected: 1\"}")) == null);
    try std.testing.expect(accountId(arena, try testJwt(arena, "{\"chatgpt_account_id\":\"\"}")) == null);
}

test "the ID token is read before the access token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id_token = try testJwt(arena, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"from-id\"}}");
    const access = try testJwt(arena, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"from-access\"}}");
    try std.testing.expectEqualStrings("from-id", firstAccountId(arena, &.{ id_token, access }).?);
    try std.testing.expectEqualStrings("from-access", firstAccountId(arena, &.{ null, access }).?);
    try std.testing.expectEqualStrings("from-access", firstAccountId(arena, &.{ "opaque", access }).?);
    try std.testing.expect(firstAccountId(arena, &.{ null, "opaque" }) == null);
}
