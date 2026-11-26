//! Asking an endpoint which models it serves: where each wire lists them,
//! and how to read the answer (`metacodes providers probe`, the key check of
//! a configured provider).
//!
//! Pure on purpose — the provider subsystem has no transport. The GET is
//! `api/model_probe.zig`'s; the URL it sends and the reading of what comes
//! back are here, where `custom_provider.zig` can derive a key check from a
//! channel without reaching the network layer.
//!
//! | wire | listing | key |
//! |---|---|---|
//! | `openai_chat`, `openai_responses` | `GET {base}/models` | the provider's scheme |
//! | `anthropic_messages` | `GET {root}/v1/models?limit=1000` (`anthropic-version`) | the provider's scheme |
//! | `gemini_generate_content` | `GET {root}/v1beta/models?pageSize=1000` | the provider's scheme |
//! | `bedrock_converse` | none | — |
//!
//! The root of an Anthropic or Gemini channel is its base without the version
//! segment the transport appends itself (`channelBase`): relay documentation
//! publishes both `https://relay.example` and `https://relay.example/v1` for
//! the same Anthropic root, and a channel stored with the segment would send
//! `/v1/v1/messages`.
//!
//! An answer is read in the shapes model listings come in: the standard
//! `data` array (OpenAI, Anthropic, most gateways), the enriched `models`
//! map some gateways serve (`{"models": {"<id>": {...}}}`), and Gemini's own
//! `models` array of resource names. One page is read; nothing follows a
//! cursor — the page sizes above are the providers' maxima.

const std = @import("std");
const profile_mod = @import("profile.zig");

pub const Wire = profile_mod.Protocol.Wire;

/// Required by Anthropic's model listing; the transport sends the same.
pub const ANTHROPIC_VERSION = "2023-06-01";
/// The largest page each listing accepts.
pub const ANTHROPIC_PAGE_LIMIT = 1000;
pub const GEMINI_PAGE_SIZE = 1000;

/// Entries read from one answer at most. A listing is read to show and to
/// pick from, and a provider holds far fewer (`custom_provider.MAX_MODELS`);
/// past this the rest are counted, not kept.
pub const MAX_LISTED: usize = 4096;

/// The base a channel speaking `wire` stores: without trailing slashes, and
/// for the wires whose transport appends a version segment itself (Anthropic
/// Messages `/v1/messages`, Gemini `/v1beta/models/...`), without that
/// segment either.
pub fn channelBase(base_url: []const u8, wire: Wire) []const u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    const segment: []const u8 = switch (wire) {
        .anthropic_messages => "/v1",
        .gemini_generate_content => "/v1beta",
        else => return base,
    };
    if (std.mem.endsWith(u8, base, segment)) return std.mem.trimEnd(u8, base[0 .. base.len - segment.len], "/");
    return base;
}

/// The GET that lists the models of a channel at `base_url` speaking `wire`,
/// or null for a wire without a listing (Bedrock Converse).
pub fn listingUrl(allocator: std.mem.Allocator, base_url: []const u8, wire: Wire) error{OutOfMemory}!?[]u8 {
    const root = channelBase(base_url, wire);
    return switch (wire) {
        .openai_chat, .openai_responses => try std.fmt.allocPrint(allocator, "{s}/models", .{root}),
        .anthropic_messages => try std.fmt.allocPrint(allocator, "{s}/v1/models?limit={d}", .{ root, ANTHROPIC_PAGE_LIMIT }),
        .gemini_generate_content => try std.fmt.allocPrint(allocator, "{s}/v1beta/models?pageSize={d}", .{ root, GEMINI_PAGE_SIZE }),
        .bedrock_converse => null,
    };
}

/// A header the listing of `wire` needs besides the credential.
pub const Header = struct { name: []const u8, value: []const u8 };

pub fn listingHeader(wire: Wire) ?Header {
    return switch (wire) {
        .anthropic_messages => .{ .name = "anthropic-version", .value = ANTHROPIC_VERSION },
        else => null,
    };
}

/// One model an endpoint lists. Strings are in the arena `parse` was given.
pub const Listed = struct {
    /// What a request names (`request_model_id`).
    id: []const u8,
    /// The listing's own name for it, when it gives one other than the id.
    name: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const Listing = struct {
    models: []const Listed,
    /// Entries past `MAX_LISTED`, counted.
    dropped: usize = 0,
};

pub const ParseError = error{
    OutOfMemory,
    /// The body is not JSON.
    NotJson,
    /// JSON, but no model listing this reads: no `data` array, no `models`
    /// map, and for Gemini no `models` array.
    NotAListing,
};

/// Read one listing answer. Entries without a usable id are skipped rather
/// than failing the whole answer: one malformed row should not hide the rest
/// of a working endpoint's models. A Gemini entry whose methods leave out
/// `generateContent` (an embedding model) cannot hold a conversation and is
/// skipped too.
pub fn parse(arena: std.mem.Allocator, body: []const u8, wire: Wire) ParseError!Listing {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    if (root != .object) return error.NotAListing;
    var out: std.ArrayList(Listed) = .empty;
    var dropped: usize = 0;
    if (wire == .gemini_generate_content) {
        const list = root.object.get("models") orelse return error.NotAListing;
        if (list != .array) return error.NotAListing;
        for (list.array.items) |raw| {
            if (raw != .object) continue;
            const entry = raw.object;
            if (entry.get("supportedGenerationMethods")) |methods| if (methods == .array) {
                const serves = for (methods.array.items) |method| {
                    if (method == .string and std.mem.eql(u8, method.string, "generateContent")) break true;
                } else false;
                if (!serves) continue;
            };
            const name = stringOf(entry.get("name")) orelse continue;
            const id = if (std.mem.startsWith(u8, name, "models/")) name["models/".len..] else name;
            if (id.len == 0) continue;
            if (out.items.len == MAX_LISTED) {
                dropped += 1;
                continue;
            }
            try out.append(arena, .{
                .id = id,
                .name = otherName(id, stringOf(entry.get("displayName"))),
                .context_window = positive(entry.get("inputTokenLimit")),
                .max_output_tokens = positive(entry.get("outputTokenLimit")),
            });
        }
        return .{ .models = out.items, .dropped = dropped };
    }

    // The standard array wins when an answer carries both shapes.
    if (root.object.get("data")) |data| if (data == .array) {
        for (data.array.items) |raw| {
            if (raw != .object) continue;
            const id = stringOf(raw.object.get("id")) orelse continue;
            if (id.len == 0) continue;
            if (out.items.len == MAX_LISTED) {
                dropped += 1;
                continue;
            }
            try out.append(arena, entryOf(id, raw.object));
        }
        return .{ .models = out.items, .dropped = dropped };
    };
    const map = root.object.get("models") orelse return error.NotAListing;
    if (map != .object) return error.NotAListing;
    var it = map.object.iterator();
    while (it.next()) |pair| {
        // A primitive property is directory metadata, not a model.
        if (pair.value_ptr.* != .object) continue;
        // The key is what the gateway accepts on requests; a nested `id` may
        // name a canonical model instead, so it stands in only for an empty
        // key.
        const id = if (pair.key_ptr.*.len > 0) pair.key_ptr.* else stringOf(pair.value_ptr.object.get("id")) orelse continue;
        if (id.len == 0) continue;
        if (out.items.len == MAX_LISTED) {
            dropped += 1;
            continue;
        }
        try out.append(arena, entryOf(id, pair.value_ptr.object));
    }
    return .{ .models = out.items, .dropped = dropped };
}

/// The name and limits an entry reports, under the spellings gateways use.
fn entryOf(id: []const u8, entry: std.json.ObjectMap) Listed {
    const limit = if (entry.get("limit")) |value| (if (value == .object) value.object else null) else null;
    const top = if (entry.get("top_provider")) |value| (if (value == .object) value.object else null) else null;
    return .{
        .id = id,
        .name = otherName(id, stringOf(entry.get("name")) orelse stringOf(entry.get("display_name")) orelse stringOf(entry.get("displayName"))),
        .context_window = positive(entry.get("contextWindow")) orelse
            positive(entry.get("context_window")) orelse
            positive(entry.get("context_length")) orelse
            positive(entry.get("max_input_tokens")) orelse
            (if (limit) |object| positive(object.get("context")) else null),
        .max_output_tokens = positive(entry.get("maxOutputTokens")) orelse
            positive(entry.get("max_output_tokens")) orelse
            positive(entry.get("maxTokens")) orelse
            positive(entry.get("max_tokens")) orelse
            (if (limit) |object| positive(object.get("output")) else null) orelse
            (if (top) |object| positive(object.get("max_completion_tokens")) else null),
    };
}

/// A name worth showing: present, and not the id again.
fn otherName(id: []const u8, name: ?[]const u8) ?[]const u8 {
    const text = name orelse return null;
    if (text.len == 0 or std.mem.eql(u8, text, id)) return null;
    return text;
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

/// A positive integer that fits a `u32` (what a configured limit holds).
fn positive(value: ?std.json.Value) ?u32 {
    const found = value orelse return null;
    return switch (found) {
        .integer => |number| if (number > 0 and number <= std.math.maxInt(u32)) @intCast(number) else null,
        else => null,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "each wire lists its models where its API does, and a channel base drops the segment its transport appends" {
    const a = testing.allocator;
    const cases = [_]struct { base: []const u8, wire: Wire, want: ?[]const u8 }{
        .{ .base = "https://relay.example.com/v1/", .wire = .openai_chat, .want = "https://relay.example.com/v1/models" },
        .{ .base = "http://127.0.0.1:11434/v1", .wire = .openai_responses, .want = "http://127.0.0.1:11434/v1/models" },
        // Both spellings of an Anthropic root list in the same place.
        .{ .base = "https://relay.example.com", .wire = .anthropic_messages, .want = "https://relay.example.com/v1/models?limit=1000" },
        .{ .base = "https://relay.example.com/v1", .wire = .anthropic_messages, .want = "https://relay.example.com/v1/models?limit=1000" },
        .{ .base = "https://coding.dashscope.aliyuncs.com/apps/anthropic", .wire = .anthropic_messages, .want = "https://coding.dashscope.aliyuncs.com/apps/anthropic/v1/models?limit=1000" },
        .{ .base = "https://gateway.example/v1beta", .wire = .gemini_generate_content, .want = "https://gateway.example/v1beta/models?pageSize=1000" },
        .{ .base = "https://gateway.example", .wire = .gemini_generate_content, .want = "https://gateway.example/v1beta/models?pageSize=1000" },
        .{ .base = "https://bedrock-runtime.us-east-1.amazonaws.com", .wire = .bedrock_converse, .want = null },
    };
    for (cases) |case| {
        const got = try listingUrl(a, case.base, case.wire);
        defer if (got) |url| a.free(url);
        if (case.want) |want| try testing.expectEqualStrings(want, got.?) else try testing.expect(got == null);
    }
    try testing.expectEqualStrings("https://relay.example.com", channelBase("https://relay.example.com/v1/", .anthropic_messages));
    try testing.expectEqualStrings("https://gateway.example", channelBase("https://gateway.example/v1beta", .gemini_generate_content));
    // Only the wires whose transport appends a version lose one.
    try testing.expectEqualStrings("https://relay.example.com/v1", channelBase("https://relay.example.com/v1/", .openai_chat));
    try testing.expectEqualStrings("anthropic-version", listingHeader(.anthropic_messages).?.name);
    try testing.expect(listingHeader(.openai_chat) == null);
}

test "a listing is read as a data array, an enriched models map, or Gemini's models array" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const openai = try parse(arena,
        \\{"object":"list","data":[{"id":"gpt-5","object":"model"},{"id":""},{"object":"model"},
        \\ {"id":"or/model","name":"OR Model","context_length":200000,"top_provider":{"max_completion_tokens":32000}},
        \\ {"id":"glm-5","max_input_tokens":200000,"max_tokens":128000,"display_name":"glm-5"}]}
    , .openai_chat);
    try testing.expectEqual(@as(usize, 3), openai.models.len);
    try testing.expectEqualStrings("gpt-5", openai.models[0].id);
    try testing.expect(openai.models[0].name == null);
    try testing.expectEqualStrings("OR Model", openai.models[1].name.?);
    try testing.expectEqual(@as(?u32, 200_000), openai.models[1].context_window);
    try testing.expectEqual(@as(?u32, 32_000), openai.models[1].max_output_tokens);
    // A name that only repeats the id is not a name.
    try testing.expect(openai.models[2].name == null);
    try testing.expectEqual(@as(?u32, 128_000), openai.models[2].max_output_tokens);

    const anthropic = try parse(arena,
        \\{"data":[{"type":"model","id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6"}],"has_more":false}
    , .anthropic_messages);
    try testing.expectEqualStrings("Claude Sonnet 4.6", anthropic.models[0].name.?);

    const map = try parse(arena,
        \\{"models":{"fast":{"id":"vendor/canonical-fast","limit":{"context":64000,"output":8000}},"version":"3","":{"id":"named-inside"}}}
    , .openai_chat);
    try testing.expectEqual(@as(usize, 2), map.models.len);
    // The key is what a request names; the inner id only fills an empty key.
    try testing.expectEqualStrings("fast", map.models[0].id);
    try testing.expectEqual(@as(?u32, 64_000), map.models[0].context_window);
    try testing.expectEqualStrings("named-inside", map.models[1].id);

    const gemini = try parse(arena,
        \\{"models":[{"name":"models/gemini-4-argon","displayName":"Gemini 4 Argon","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent","countTokens"]},
        \\ {"name":"models/text-embedding-005","supportedGenerationMethods":["embedContent"]},
        \\ {"name":"models/no-methods"}],"nextPageToken":"x"}
    , .gemini_generate_content);
    try testing.expectEqual(@as(usize, 2), gemini.models.len);
    try testing.expectEqualStrings("gemini-4-argon", gemini.models[0].id);
    try testing.expectEqual(@as(?u32, 1_048_576), gemini.models[0].context_window);
    try testing.expectEqualStrings("no-methods", gemini.models[1].id);
}

test "an answer that is no listing says which way it is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.NotJson, parse(arena, "<html>Sign in to the Wi-Fi</html>", .openai_chat));
    try testing.expectError(error.NotAListing, parse(arena, "[1,2]", .openai_chat));
    try testing.expectError(error.NotAListing, parse(arena, "{\"error\":{\"message\":\"x\"}}", .openai_chat));
    // A Gemini answer must be Gemini's array; a map is not one.
    try testing.expectError(error.NotAListing, parse(arena, "{\"models\":{\"m\":{}}}", .gemini_generate_content));
    // An empty listing is a listing.
    try testing.expectEqual(@as(usize, 0), (try parse(arena, "{\"data\":[]}", .openai_chat)).models.len);
}
