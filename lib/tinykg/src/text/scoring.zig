const std = @import("std");

pub const Bm25Params = struct {
    k1: f32 = 1.2,
    b: f32 = 0.75,
};

pub fn validBm25Params(params: Bm25Params) bool {
    return std.math.isFinite(params.k1) and
        std.math.isFinite(params.b) and
        params.k1 > 0 and
        params.b >= 0 and
        params.b <= 1;
}

pub fn bm25Idf(doc_count: u64, doc_freq: u64) f32 {
    if (doc_count == 0 or doc_freq == 0) return 0;
    const n: f32 = @floatFromInt(doc_count);
    const df: f32 = @floatFromInt(@min(doc_freq, doc_count));
    return @log(1.0 + (n - df + 0.5) / (df + 0.5));
}

pub fn bm25TermScore(
    term_freq: u32,
    doc_len: u32,
    avg_doc_len: f32,
    doc_count: u64,
    doc_freq: u64,
    params: Bm25Params,
) f32 {
    if (!validBm25Params(params) or term_freq == 0 or doc_len == 0 or !std.math.isFinite(avg_doc_len) or avg_doc_len <= 0) return 0;
    const tf: f32 = @floatFromInt(term_freq);
    const len: f32 = @floatFromInt(doc_len);
    const norm = (1.0 - params.b) + params.b * (len / avg_doc_len);
    const numerator = tf * (params.k1 + 1.0);
    const denominator = tf + params.k1 * norm;
    const score = bm25Idf(doc_count, doc_freq) * numerator / denominator;
    return if (std.math.isFinite(score)) score else 0;
}

pub fn bm25WeightedTermScore(
    weighted_term_freq: f32,
    doc_len: f32,
    avg_doc_len: f32,
    doc_count: u64,
    doc_freq: u64,
    params: Bm25Params,
) f32 {
    if (!validBm25Params(params) or
        !std.math.isFinite(weighted_term_freq) or
        !std.math.isFinite(doc_len) or
        !std.math.isFinite(avg_doc_len) or
        weighted_term_freq <= 0 or
        doc_len <= 0 or
        avg_doc_len <= 0) return 0;
    const norm = (1.0 - params.b) + params.b * (doc_len / avg_doc_len);
    const numerator = weighted_term_freq * (params.k1 + 1.0);
    const denominator = weighted_term_freq + params.k1 * norm;
    const score = bm25Idf(doc_count, doc_freq) * numerator / denominator;
    return if (std.math.isFinite(score)) score else 0;
}

test "bm25 scores increase with term frequency and rarity" {
    const params = Bm25Params{};
    const one_hit = bm25TermScore(1, 10, 10.0, 1000, 10, params);
    const two_hits = bm25TermScore(2, 10, 10.0, 1000, 10, params);
    const common = bm25TermScore(1, 10, 10.0, 1000, 500, params);

    try std.testing.expect(two_hits > one_hit);
    try std.testing.expect(one_hit > common);
}

test "bm25 scoring rejects non-finite and out-of-range parameters" {
    try std.testing.expectEqual(@as(f32, 0), bm25TermScore(1, 10, 10.0, 1000, 10, .{ .k1 = std.math.nan(f32) }));
    try std.testing.expectEqual(@as(f32, 0), bm25WeightedTermScore(1.0, 10.0, 10.0, 1000, 10, .{ .b = std.math.inf(f32) }));
    try std.testing.expectEqual(@as(f32, 0), bm25WeightedTermScore(1.0, 10.0, 10.0, 1000, 10, .{ .b = -0.1 }));
    try std.testing.expectEqual(@as(f32, 0), bm25WeightedTermScore(1.0, 10.0, 10.0, 1000, 10, .{ .b = 1.1 }));
}

test "bm25 scoring rejects non-finite scoring inputs" {
    try std.testing.expectEqual(@as(f32, 0), bm25TermScore(1, 10, std.math.nan(f32), 1000, 10, .{}));
    try std.testing.expectEqual(@as(f32, 0), bm25WeightedTermScore(std.math.inf(f32), 10.0, 10.0, 1000, 10, .{}));
    try std.testing.expectEqual(@as(f32, 0), bm25WeightedTermScore(1.0, std.math.inf(f32), 10.0, 1000, 10, .{}));
    try std.testing.expectEqual(@as(f32, 0), bm25WeightedTermScore(1.0, 10.0, std.math.nan(f32), 1000, 10, .{}));
}

test "bm25 scoring rejects finite inputs that overflow intermediate score math" {
    const score = bm25WeightedTermScore(std.math.floatMax(f32), 1.0, std.math.floatMin(f32), 1000, 10, .{});
    try std.testing.expectEqual(@as(f32, 0), score);
}

test "bm25 same-term ordering can depend on final average document length" {
    const doc_count: u64 = 1000;
    const doc_freq: u64 = 100;
    const high_tf_long_doc_tf: f32 = 8.0;
    const high_tf_long_doc_len: f32 = 100.0;
    const low_tf_short_doc_tf: f32 = 4.0;
    const low_tf_short_doc_len: f32 = 10.0;

    const low_avg_high_tf_long = bm25WeightedTermScore(high_tf_long_doc_tf, high_tf_long_doc_len, 10.0, doc_count, doc_freq, .{});
    const low_avg_low_tf_short = bm25WeightedTermScore(low_tf_short_doc_tf, low_tf_short_doc_len, 10.0, doc_count, doc_freq, .{});
    try std.testing.expect(low_avg_low_tf_short > low_avg_high_tf_long);

    const high_avg_high_tf_long = bm25WeightedTermScore(high_tf_long_doc_tf, high_tf_long_doc_len, 1000.0, doc_count, doc_freq, .{});
    const high_avg_low_tf_short = bm25WeightedTermScore(low_tf_short_doc_tf, low_tf_short_doc_len, 1000.0, doc_count, doc_freq, .{});
    try std.testing.expect(high_avg_high_tf_long > high_avg_low_tf_short);
}
