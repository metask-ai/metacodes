//! `/model` command helpers.
//!
//! This module keeps model grouping/capability logic pure enough to test. The
//! REPL layer is responsible for rendering and mutating App state.

const std = @import("std");
const types = @import("../types.zig");
const catalog_mod = @import("../api/catalog.zig");
const capability_mod = @import("../api/capability.zig");
const provider_mod = @import("../api/provider.zig");

pub const Capability = provider_mod.Capability;

pub const Source = enum { server, builtin };

pub const Candidate = struct {
    id: []const u8,
    provider: types.ProviderKind,
    group: []const u8,
    max_tokens: ?u32 = null,
    max_input_tokens: ?u32 = null,
    source: Source,
};

pub const Query = union(enum) {
    list,
    help,
    group: []const u8,
    capability: Capability,
    use_model: []const u8,
    unknown: []const u8,
};

const Builtin = struct {
    id: []const u8,
    provider: types.ProviderKind,
};

const BUILTINS = [_]Builtin{
    .{ .id = "claude-opus-4-6", .provider = .anthropic },
    .{ .id = "claude-opus-4-5", .provider = .anthropic },
    .{ .id = "claude-opus-4-1-20250805", .provider = .anthropic },
    .{ .id = "claude-sonnet-4-6", .provider = .anthropic },
    .{ .id = "claude-sonnet-4-20250514", .provider = .anthropic },
    .{ .id = "claude-haiku-4-5-20251001", .provider = .anthropic },
    .{ .id = "claude-3-5-haiku-20241022", .provider = .anthropic },
    .{ .id = "gpt-4o", .provider = .openai },
    .{ .id = "gpt-4o-mini", .provider = .openai },
    .{ .id = "o3", .provider = .openai },
    .{ .id = "o3-mini", .provider = .openai },
    .{ .id = "gemini-2.5-pro", .provider = .gemini },
    .{ .id = "gemini-2.5-flash", .provider = .gemini },
};

pub fn parseQuery(rest_raw: []const u8) Query {
    const rest = std.mem.trim(u8, rest_raw, " \t\r\n");
    if (rest.len == 0) return .list;
    if (std.mem.eql(u8, rest, "help") or std.mem.eql(u8, rest, "--help") or std.mem.eql(u8, rest, "-h")) return .help;

    if (takeWord(rest, "group")) |arg| return .{ .group = arg };
    if (takeWord(rest, "family")) |arg| return .{ .group = arg };
    if (takeWord(rest, "provider")) |arg| return .{ .group = arg };
    if (takeWord(rest, "cap")) |arg| {
        return if (parseCapability(arg)) |cap| .{ .capability = cap } else .{ .unknown = rest };
    }
    if (takeWord(rest, "capability")) |arg| {
        return if (parseCapability(arg)) |cap| .{ .capability = cap } else .{ .unknown = rest };
    }
    if (takeWord(rest, "use")) |arg| return .{ .use_model = arg };
    if (takeWord(rest, "select")) |arg| return .{ .use_model = arg };

    if (parseCapability(rest)) |cap| return .{ .capability = cap };
    if (looksLikeModelId(rest)) return .{ .use_model = rest };
    if (isKnownGroup(rest)) return .{ .group = rest };
    return .{ .unknown = rest };
}

fn takeWord(rest: []const u8, word: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rest, word)) return null;
    if (rest.len == word.len) return "";
    if (rest[word.len] != ' ' and rest[word.len] != '\t') return null;
    return std.mem.trim(u8, rest[word.len + 1 ..], " \t\r\n");
}

pub fn parseCapability(s_raw: []const u8) ?Capability {
    const s = std.mem.trim(u8, s_raw, " \t\r\n");
    if (eqAny(s, &.{ "web_search", "web-search", "websearch", "web" })) return .web_search;
    if (eqAny(s, &.{ "server_tool", "server-tool", "servertool", "server" })) return .server_tool;
    if (eqAny(s, &.{ "extended_thinking", "extended-thinking", "extendedthinking", "thinking", "reasoning" })) return .extended_thinking;
    if (eqAny(s, &.{ "prompt_cache", "prompt-cache", "promptcache", "cache", "caching" })) return .prompt_cache;
    if (eqAny(s, &.{ "structured_output", "structured-output", "structuredoutput", "structured", "json" })) return .structured_output;
    return null;
}

fn eqAny(s: []const u8, values: []const []const u8) bool {
    for (values) |v| {
        if (std.mem.eql(u8, s, v)) return true;
    }
    return false;
}

pub fn capabilityLabel(cap: Capability) []const u8 {
    return switch (cap) {
        .web_search => "web_search",
        .server_tool => "server_tool",
        .extended_thinking => "thinking",
        .prompt_cache => "prompt_cache",
        .structured_output => "structured_output",
    };
}

pub fn providerForModel(model: []const u8) ?types.ProviderKind {
    if (std.mem.startsWith(u8, model, "claude-")) return .anthropic;
    if (std.mem.startsWith(u8, model, "gpt") or std.mem.startsWith(u8, model, "o1") or std.mem.startsWith(u8, model, "o3")) return .openai;
    if (std.mem.startsWith(u8, model, "gemini")) return .gemini;
    return null;
}

pub fn looksLikeModelId(model: []const u8) bool {
    return providerForModel(model) != null or std.mem.indexOfScalar(u8, model, '-') != null;
}

pub fn collectCandidates(
    allocator: std.mem.Allocator,
    current_provider: types.ProviderKind,
    catalog_entries: []const catalog_mod.Catalog.Entry,
) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer out.deinit(allocator);

    for (catalog_entries) |e| {
        try appendIfMissing(allocator, &out, .{
            .id = e.model_id,
            .provider = current_provider,
            .group = groupForModel(e.model_id),
            .max_tokens = e.max_tokens,
            .max_input_tokens = e.max_input_tokens,
            .source = .server,
        });
    }
    for (BUILTINS) |b| {
        if (b.provider != current_provider) continue;
        try appendIfMissing(allocator, &out, .{
            .id = b.id,
            .provider = b.provider,
            .group = groupForModel(b.id),
            .source = .builtin,
        });
    }
    return try out.toOwnedSlice(allocator);
}

fn appendIfMissing(allocator: std.mem.Allocator, out: *std.ArrayList(Candidate), c: Candidate) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing.id, c.id)) return;
    }
    try out.append(allocator, c);
}

pub fn groupForModel(model: []const u8) []const u8 {
    if (std.mem.indexOf(u8, model, "opus") != null) return "opus";
    if (std.mem.indexOf(u8, model, "sonnet") != null) return "sonnet";
    if (std.mem.indexOf(u8, model, "haiku") != null) return "haiku";
    if (std.mem.startsWith(u8, model, "gpt") or std.mem.startsWith(u8, model, "o1") or std.mem.startsWith(u8, model, "o3")) return "openai";
    if (std.mem.startsWith(u8, model, "gemini")) return "gemini";
    if (std.mem.startsWith(u8, model, "claude-")) return "claude";
    return "other";
}

pub fn isKnownGroup(s: []const u8) bool {
    return std.mem.eql(u8, s, "anthropic") or
        std.mem.eql(u8, s, "claude") or
        std.mem.eql(u8, s, "opus") or
        std.mem.eql(u8, s, "sonnet") or
        std.mem.eql(u8, s, "haiku") or
        std.mem.eql(u8, s, "openai") or
        std.mem.eql(u8, s, "gpt") or
        std.mem.eql(u8, s, "gemini") or
        std.mem.eql(u8, s, "other");
}

pub fn matchesGroup(c: Candidate, group: []const u8) bool {
    if (std.mem.eql(u8, group, @tagName(c.provider))) return true;
    if (std.mem.eql(u8, group, c.group)) return true;
    if (std.mem.eql(u8, group, "claude")) return c.provider == .anthropic;
    if (std.mem.eql(u8, group, "gpt")) return c.provider == .openai;
    return false;
}

pub fn supports(provider: types.ProviderKind, model: []const u8, cap: Capability) bool {
    const kind: capability_mod.ProviderKind = switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
        .gemini => .gemini,
    };
    return capability_mod.supports(kind, model, cap);
}

pub fn isKnownCandidate(candidates: []const Candidate, model: []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, c.id, model)) return true;
    }
    return false;
}

pub fn canUseInCurrentProvider(current_provider: types.ProviderKind, candidates: []const Candidate, model: []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, c.id, model)) return c.provider == current_provider;
    }
    const inferred = providerForModel(model) orelse return false;
    return inferred == current_provider;
}

test "parseQuery supports group capability and model selection" {
    try std.testing.expect(parseQuery("") == .list);
    try std.testing.expect(parseQuery("sonnet") == .group);
    try std.testing.expect(parseQuery("capability structured-output") == .capability);
    try std.testing.expect(parseQuery("thinking") == .capability);
    try std.testing.expect(parseQuery("use claude-sonnet-4-20250514") == .use_model);
    try std.testing.expect(parseQuery("claude-sonnet-4-20250514") == .use_model);
}

test "collectCandidates merges server catalog with current provider builtins" {
    const Entry = catalog_mod.Catalog.Entry;
    const entries = [_]Entry{
        .{ .model_id = @constCast("claude-custom-1"), .max_tokens = 123, .max_input_tokens = 456 },
        .{ .model_id = @constCast("claude-sonnet-4-20250514"), .max_tokens = 32_000, .max_input_tokens = null },
    };
    const list = try collectCandidates(std.testing.allocator, .anthropic, &entries);
    defer std.testing.allocator.free(list);
    try std.testing.expect(isKnownCandidate(list, "claude-custom-1"));
    try std.testing.expect(isKnownCandidate(list, "claude-opus-4-6"));
    var sonnet_count: usize = 0;
    for (list) |c| {
        if (std.mem.eql(u8, c.id, "claude-sonnet-4-20250514")) sonnet_count += 1;
    }
    try std.testing.expect(sonnet_count == 1);
}

test "capability and provider checks are derived from the central matrix" {
    try std.testing.expect(supports(.anthropic, "claude-sonnet-4-20250514", .structured_output));
    try std.testing.expect(!supports(.anthropic, "claude-3-5-haiku-20241022", .structured_output));
    try std.testing.expect(supports(.gemini, "gemini-2.5-flash", .prompt_cache));
    try std.testing.expect(!supports(.openai, "gpt-4o", .web_search));
    try std.testing.expect(providerForModel("gpt-4o").? == .openai);
    try std.testing.expect(providerForModel("gemini-2.5-pro").? == .gemini);
}
