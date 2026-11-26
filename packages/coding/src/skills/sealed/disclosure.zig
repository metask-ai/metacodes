//! §8.5 — the disclosure screen.
//!
//! The Skill's text never leaves the gateway as bytes, but the model that
//! runs it can restate it: in its final answer, in a tool input it asks the
//! client to execute, in a question it asks the user. This module is the
//! gateway's check on everything the brain is about to show the client:
//! every run of `NGRAM` consecutive tokens that also occurs in the Skill's
//! sealed material (the body and the `sealed/` files) is replaced by
//! `MARKER`, and the Step says how many passages were.
//!
//! What it catches: verbatim and near-verbatim quotation of eight words or
//! more, whatever the casing, spacing or punctuation around them; CJK text
//! per character, so eight characters of a sealed sentence. What it does not
//! catch, stated plainly: a number, a name, a short phrase, a paraphrase. A
//! threshold restated as "under 5000.00" passes; the rule it belongs to,
//! quoted, does not. Operators layer their own detection on top (§8.5);
//! this is the floor the reference gateway guarantees.

const std = @import("std");

/// Tokens in a window; a quotation shorter than this passes.
pub const NGRAM: usize = 8;
/// What a redacted passage becomes.
pub const MARKER = "[sealed]";

/// The manifest's `egress.disclosure` (§5): what the gateway does on a hit.
pub const Policy = enum {
    /// Replace the passage with `MARKER` and say so in the Step (default).
    redact,
    /// End the run as `failed` / `disclosure`; nothing of the Step reaches the client.
    fail,
    /// No screen (a creator who ships public prose and accepts the channel).
    off,

    pub fn parse(text: []const u8) ?Policy {
        return std.meta.stringToEnum(Policy, text);
    }
};

const Token = struct { start: usize, end: usize, hash: u64 };

/// Word-level tokens: a run of ASCII letters and digits is one token,
/// compared without case; every non-ASCII code point is one token; anything
/// else separates. Positions are byte offsets into the original text, so a
/// match maps back to the bytes it covers.
fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isAlphanumeric(c)) {
            const start = i;
            var hasher = std.hash.Wyhash.init(0);
            while (i < text.len and std.ascii.isAlphanumeric(text[i])) : (i += 1) {
                const lower = [_]u8{std.ascii.toLower(text[i])};
                hasher.update(&lower);
            }
            try tokens.append(allocator, .{ .start = start, .end = i, .hash = hasher.final() });
        } else if (c >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const end = @min(i + len, text.len);
            try tokens.append(allocator, .{ .start = i, .end = end, .hash = std.hash.Wyhash.hash(1, text[i..end]) });
            i = end;
        } else {
            i += 1;
        }
    }
    return tokens.toOwnedSlice(allocator);
}

fn windowHash(tokens: []const Token, start: usize) u64 {
    var hasher = std.hash.Wyhash.init(2);
    for (tokens[start .. start + NGRAM]) |token| hasher.update(std.mem.asBytes(&token.hash));
    return hasher.final();
}

/// The sealed material, as the set of hashes of its token windows. Built
/// once per package; a few bytes per word of sealed text.
pub const Corpus = struct {
    grams: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn deinit(self: *Corpus, allocator: std.mem.Allocator) void {
        self.grams.deinit(allocator);
    }

    pub fn isEmpty(self: *const Corpus) bool {
        return self.grams.count() == 0;
    }

    /// Add every `NGRAM`-token window of `text`.
    pub fn add(self: *Corpus, allocator: std.mem.Allocator, text: []const u8) !void {
        const tokens = try tokenize(allocator, text);
        defer allocator.free(tokens);
        if (tokens.len < NGRAM) return;
        var i: usize = 0;
        while (i + NGRAM <= tokens.len) : (i += 1) {
            try self.grams.put(allocator, windowHash(tokens, i), {});
        }
    }
};

pub const Redacted = struct {
    /// The text with every matching passage replaced; always owned by the
    /// caller's allocator, unchanged text included.
    text: []u8,
    /// How many passages were replaced (adjacent and overlapping matches
    /// merge into one).
    spans: usize,
};

/// Replace every passage of `text` that quotes the corpus with `MARKER`.
pub fn redactText(allocator: std.mem.Allocator, corpus: *const Corpus, text: []const u8) !Redacted {
    if (corpus.isEmpty()) return .{ .text = try allocator.dupe(u8, text), .spans = 0 };
    const tokens = try tokenize(allocator, text);
    defer allocator.free(tokens);
    if (tokens.len < NGRAM) return .{ .text = try allocator.dupe(u8, text), .spans = 0 };
    const marked = try allocator.alloc(bool, tokens.len);
    defer allocator.free(marked);
    @memset(marked, false);
    var any = false;
    var i: usize = 0;
    while (i + NGRAM <= tokens.len) : (i += 1) {
        if (corpus.grams.contains(windowHash(tokens, i))) {
            @memset(marked[i .. i + NGRAM], true);
            any = true;
        }
    }
    if (!any) return .{ .text = try allocator.dupe(u8, text), .spans = 0 };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var spans: usize = 0;
    var cursor: usize = 0;
    i = 0;
    while (i < tokens.len) {
        if (!marked[i]) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < tokens.len and marked[j]) : (j += 1) {}
        try out.appendSlice(allocator, text[cursor..tokens[i].start]);
        try out.appendSlice(allocator, MARKER);
        spans += 1;
        cursor = tokens[j - 1].end;
        i = j;
    }
    try out.appendSlice(allocator, text[cursor..]);
    return .{ .text = try out.toOwnedSlice(allocator), .spans = spans };
}

/// Replace every quoting passage inside the string values of a JSON
/// document (a tool input, an `AskUserQuestion` call) and re-serialize it;
/// keys, numbers and structure are untouched, so the client's tool still
/// gets a valid input. `allocator` should be an arena: the parse and the
/// replaced strings live until the document is written out.
pub fn redactJsonStrings(allocator: std.mem.Allocator, corpus: *const Corpus, json: []const u8) !Redacted {
    if (corpus.isEmpty()) return .{ .text = try allocator.dupe(u8, json), .spans = 0 };
    var value = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch
        return .{ .text = try allocator.dupe(u8, json), .spans = 0 };
    const spans = try redactValue(allocator, corpus, &value);
    if (spans == 0) return .{ .text = try allocator.dupe(u8, json), .spans = 0 };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return .{ .text = try out.toOwnedSlice(), .spans = spans };
}

fn redactValue(allocator: std.mem.Allocator, corpus: *const Corpus, value: *std.json.Value) !usize {
    switch (value.*) {
        .string => |text| {
            const redacted = try redactText(allocator, corpus, text);
            if (redacted.spans != 0) value.* = .{ .string = redacted.text };
            return redacted.spans;
        },
        .array => |*items| {
            var total: usize = 0;
            for (items.items) |*item| total += try redactValue(allocator, corpus, item);
            return total;
        },
        .object => |*object| {
            var total: usize = 0;
            var it = object.iterator();
            while (it.next()) |entry| total += try redactValue(allocator, corpus, entry.value_ptr);
            return total;
        },
        else => return 0,
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

const SEALED_RULE = "R5: every invoice above the threshold needs a second approver before posting, no exceptions for recurring vendors.\n";

test "a quoted sealed passage is replaced, whatever its casing and punctuation; a short fragment passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var corpus: Corpus = .{};
    try corpus.add(a, SEALED_RULE);
    try std.testing.expect(!corpus.isEmpty());

    const quoted = try redactText(a, &corpus, "Posted. Note that EVERY invoice above the threshold, needs a second approver before posting -- so I waited.");
    try std.testing.expectEqual(@as(usize, 1), quoted.spans);
    try std.testing.expectEqualStrings("Posted. Note that [sealed] -- so I waited.", quoted.text);

    const fragment = try redactText(a, &corpus, "a second approver before posting");
    try std.testing.expectEqual(@as(usize, 0), fragment.spans);
    try std.testing.expectEqualStrings("a second approver before posting", fragment.text);

    const paraphrase = try redactText(a, &corpus, "Invoices over the limit need someone else to approve them first.");
    try std.testing.expectEqual(@as(usize, 0), paraphrase.spans);

    // Two separate quotations are two passages.
    const twice = try redactText(a, &corpus, "every invoice above the threshold needs a second approver before posting. Then: no exceptions for recurring vendors, every invoice above the threshold needs a second approver.");
    try std.testing.expectEqual(@as(usize, 2), twice.spans);
}

test "CJK sealed text is matched per character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var corpus: Corpus = .{};
    try corpus.add(a, "规则五：超过阈值的每张发票都需要第二位审批人。");
    const quoted = try redactText(a, &corpus, "已处理。按规则，超过阈值的每张发票都需要第二位审批人，所以我等了。");
    try std.testing.expectEqual(@as(usize, 1), quoted.spans);
    try std.testing.expect(std.mem.indexOf(u8, quoted.text, "[sealed]") != null);
    try std.testing.expect(std.mem.indexOf(u8, quoted.text, "每张发票") == null);
    const short = try redactText(a, &corpus, "超过阈值的发票");
    try std.testing.expectEqual(@as(usize, 0), short.spans);
}

test "a tool input keeps its shape: only the quoting string values change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var corpus: Corpus = .{};
    try corpus.add(a, SEALED_RULE);
    const input = "{\"file_path\":\"C:/work/notes.md\",\"content\":\"Reminder: every invoice above the threshold needs a second approver before posting.\",\"append\":true,\"tags\":[\"needs a second approver before posting, no exceptions for recurring vendors\"]}";
    const redacted = try redactJsonStrings(a, &corpus, input);
    try std.testing.expectEqual(@as(usize, 2), redacted.spans);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, redacted.text, .{});
    try std.testing.expectEqualStrings("C:/work/notes.md", parsed.object.get("file_path").?.string);
    try std.testing.expectEqualStrings("Reminder: [sealed].", parsed.object.get("content").?.string);
    try std.testing.expect(parsed.object.get("append").?.bool);
    try std.testing.expectEqualStrings("[sealed]", parsed.object.get("tags").?.array.items[0].string);
    // Nothing quoting: the document comes back as it was.
    const clean = try redactJsonStrings(a, &corpus, "{\"file_path\":\"x\",\"content\":\"hello\"}");
    try std.testing.expectEqual(@as(usize, 0), clean.spans);
    try std.testing.expectEqualStrings("{\"file_path\":\"x\",\"content\":\"hello\"}", clean.text);
}

test "an empty corpus screens nothing; the policy names parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: Corpus = .{};
    const out = try redactText(a, &empty, "anything at all, however long it is, passes through unchanged");
    try std.testing.expectEqual(@as(usize, 0), out.spans);
    try std.testing.expectEqual(Policy.redact, Policy.parse("redact").?);
    try std.testing.expectEqual(Policy.fail, Policy.parse("fail").?);
    try std.testing.expectEqual(Policy.off, Policy.parse("off").?);
    try std.testing.expect(Policy.parse("loud") == null);
}
