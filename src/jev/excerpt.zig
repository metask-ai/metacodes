//! Query-focused excerpts for System-One judgments.
//!
//! A judge that sees only the head of a long memory cannot tell whether the
//! part the request is about is in it. On the pinned LongMemEval-S dev split,
//! under the recall policy of `kg/scoped_recall.zig`, the query-focused window
//! below raised the gold-evidence hit rate on whole-session memories (median
//! 13.7 KB) from 0.750 with the head to 0.790, and was neutral on turn-sized
//! memories (median 2.2 KB: 0.685 vs 0.700, within noise).
//!
//! The window is a sub-slice of the input (no allocation): the `budget`-byte
//! span holding the most query-term occurrences, started a little before the
//! first of them, cut on UTF-8 boundaries. Terms are ASCII words longer than
//! two bytes minus generic English function words; a query without such
//! terms (for example CJK text) falls back to the head, which is what a judge
//! saw before this module existed.

const std = @import("std");

/// Bytes of each candidate a recall judge sees (eight of them keep the state
/// far below the service's 4096-token prompt limit).
pub const JUDGE_WINDOW_BYTES: usize = 480;

/// Generic English function words only. It must never learn a benchmark's
/// prompt boilerplate; that would tune production to an evaluation set.
const STOP_WORDS = [_][]const u8{
    "the",    "and",  "but",   "for",  "with",  "from",  "are",    "was",   "were",  "been",
    "being",  "mine", "you",   "your", "yours", "our",   "ours",   "they",  "their", "them",
    "she",    "his",  "her",   "its",  "this",  "that",  "these",  "those", "what",  "which",
    "who",    "whom", "whose", "how",  "when",  "where", "why",    "many",  "much",  "did",
    "does",   "done", "doing", "have", "has",   "had",   "having", "can",   "could", "would",
    "should", "will", "shall", "may",  "might", "must",  "not",    "yes",   "then",  "than",
    "too",    "very", "just",  "also", "about", "into",  "over",   "under", "again", "there",
    "here",   "all",  "any",   "some", "each",  "both",  "few",    "more",  "most",  "other",
    "such",   "only", "own",   "same",
};

const MAX_TERMS = 32;
const MAX_TERM_BYTES = 48;
const MAX_POSITIONS = 512;

/// The most query-relevant `budget`-byte window of `text`.
pub fn focusedWindow(text: []const u8, query: []const u8, budget: usize) []const u8 {
    if (text.len <= budget) return text;
    var term_storage: [MAX_TERMS][MAX_TERM_BYTES]u8 = undefined;
    var terms: [MAX_TERMS][]const u8 = undefined;
    const term_count = collectTerms(query, &term_storage, &terms);
    if (term_count == 0) return utf8Prefix(text, budget);

    var positions: [MAX_POSITIONS]usize = undefined;
    var position_count: usize = 0;
    var offset: usize = 0;
    while (offset < text.len and position_count < MAX_POSITIONS) : (offset += 1) {
        if (offset > 0 and isWordByte(text[offset - 1])) continue;
        for (terms[0..term_count]) |term| {
            if (matchesWord(text, offset, term)) {
                positions[position_count] = offset;
                position_count += 1;
                break;
            }
        }
    }
    if (position_count == 0) return utf8Prefix(text, budget);

    // Densest span of positions no wider than most of the budget, so the
    // lead-in below still fits the matches that chose the window.
    const span = budget - budget / 10;
    var best_start = positions[0];
    var best_count: usize = 0;
    var end_index: usize = 0;
    for (positions[0..position_count], 0..) |start, index| {
        if (end_index < index) end_index = index;
        while (end_index < position_count and positions[end_index] - start <= span) end_index += 1;
        if (end_index - index > best_count) {
            best_count = end_index - index;
            best_start = start;
        }
    }
    var begin = best_start -| budget / 8;
    while (begin > 0 and (text[begin] & 0xC0) == 0x80) begin -= 1;
    return utf8Prefix(text[begin..], budget);
}

fn collectTerms(
    query: []const u8,
    storage: *[MAX_TERMS][MAX_TERM_BYTES]u8,
    terms: *[MAX_TERMS][]const u8,
) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < query.len and count < MAX_TERMS) {
        while (index < query.len and !isWordByte(query[index])) index += 1;
        const start = index;
        while (index < query.len and isWordByte(query[index])) index += 1;
        const word = query[start..index];
        if (word.len <= 2 or word.len > MAX_TERM_BYTES) continue;
        var lowered: [MAX_TERM_BYTES]u8 = undefined;
        for (word, 0..) |byte, position| lowered[position] = std.ascii.toLower(byte);
        const candidate = lowered[0..word.len];
        if (isStopWord(candidate)) continue;
        var duplicate = false;
        for (terms[0..count]) |existing| {
            if (std.mem.eql(u8, existing, candidate)) duplicate = true;
        }
        if (duplicate) continue;
        @memcpy(storage[count][0..word.len], candidate);
        terms[count] = storage[count][0..word.len];
        count += 1;
    }
    return count;
}

fn isStopWord(word: []const u8) bool {
    for (STOP_WORDS) |stop| {
        if (std.mem.eql(u8, stop, word)) return true;
    }
    return false;
}

/// ASCII letters, digits and the apostrophe; every non-ASCII byte is a
/// boundary, so CJK text never yields a term.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '\'';
}

fn matchesWord(text: []const u8, offset: usize, term: []const u8) bool {
    if (offset + term.len > text.len) return false;
    for (term, text[offset .. offset + term.len]) |expected, actual| {
        if (std.ascii.toLower(actual) != expected) return false;
    }
    const after = offset + term.len;
    return after == text.len or !isWordByte(text[after]);
}

fn utf8Prefix(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var n = max_bytes;
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    return text[0..n];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "focusedWindow returns short text whole" {
    try testing.expectEqualStrings("short", focusedWindow("short", "anything here", 480));
}

test "focusedWindow finds the span the request is about" {
    const filler = "x" ** 900;
    const text = "Session opening chatter about the weather. " ++ filler ++
        " I finally planted twelve tomato seedlings and four chili pepper plants in May. " ++ filler;
    const window = focusedWindow(text, "How many tomato and chili pepper plants did I plant?", 120);
    try testing.expect(window.len <= 120);
    try testing.expect(std.mem.indexOf(u8, window, "tomato") != null);
    try testing.expect(std.mem.indexOf(u8, window, "chili pepper") != null);
    try testing.expect(std.mem.indexOf(u8, window, "weather") == null);
}

test "focusedWindow ignores function words and matches whole words only" {
    const filler = "y" ** 400;
    // "the" and "did" are stop words; "cat" must not match "category".
    const text = "the category list " ++ filler ++ " my cat sleeps on the mat " ++ filler;
    const window = focusedWindow(text, "What did the cat do?", 60);
    try testing.expect(std.mem.indexOf(u8, window, "my cat sleeps") != null);
}

test "focusedWindow falls back to the head without ASCII terms and cuts on UTF-8 boundaries" {
    const text = "开头内容" ++ "中" ** 200;
    const window = focusedWindow(text, "我去过哪些城市？", 20);
    try testing.expect(std.mem.startsWith(u8, text, window));
    try testing.expect(std.unicode.utf8ValidateSlice(window));
    try testing.expect(window.len <= 20);
}
