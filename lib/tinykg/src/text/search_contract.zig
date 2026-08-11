const std = @import("std");
const tokenizer_mod = @import("tokenizer.zig");
const scoring_mod = @import("scoring.zig");

pub fn SearchContract(
    comptime core: type,
    comptime schema: type,
    comptime tokenizer: type,
    comptime scoring: type,
) type {
    return struct {
        pub const TextSearchOptions = struct {
            kind_filter: ?core.NodeKind = null,
            /// Multi-kind schema descendants. The pointed set only needs to live for
            /// the synchronous search call; keeping it by reference avoids copying a
            /// 4096-bit set through every posting callback context.
            kind_set_filter: ?*const schema.NodeTypeSet = null,
            /// Server-side membership filtering happens before top-k truncation.
            member_filter: ?*const std.AutoHashMap(u64, void) = null,
            limit: usize = 20,
            max_postings_scanned: usize = core.default_max_text_postings_scanned,
            min_score: f32 = 0,
            params: scoring.Bm25Params = .{},
            tokenizer: tokenizer.TokenizerOptions = .{},
            deadline: core.QueryDeadline = .none,
            /// Minimum CJK bigram coverage ratio. Zero still requires one matching
            /// bigram when a query contains bigrams; positive values tighten the gate.
            cjk_coverage_ratio: f32 = 0,
        };

        pub const TextSearchHit = struct {
            node_id: core.NodeId,
            kind: core.NodeKind,
            score: f32,
            /// CJK bigram coverage participates in ordering before BM25 score.
            match_count: u32 = 0,
        };

        /// Private-to-the-façade behavior grouped behind one bounded module entry.
        /// Zig requires these declarations to be public for the owning file to call
        /// them, but the stable `text.zig` façade does not re-export this namespace.
        pub const Internal = struct {
            pub fn hasNodeFilter(options: TextSearchOptions) bool {
                return options.kind_filter != null or options.kind_set_filter != null;
            }

            pub fn matchesNodeKind(options: TextSearchOptions, kind: core.NodeKind) bool {
                if (options.kind_filter) |expected| {
                    if (kind != expected) return false;
                }
                if (options.kind_set_filter) |set| {
                    if (!set.containsNodeKind(kind)) return false;
                }
                return true;
            }

            pub fn cjkBigramCoverageFloor(required: u32, ratio: f32) u32 {
                if (required == 0) return 0;
                if (ratio <= 0) return 1;
                const scaled = @ceil(@as(f32, @floatFromInt(required)) * ratio);
                const need: u32 = if (scaled < 1) 1 else @intFromFloat(scaled);
                return @min(need, required);
            }

            pub fn isCjkMultiCodepointTerm(term: []const u8) bool {
                var index: usize = 0;
                var count: usize = 0;
                while (index < term.len) {
                    const decoded = tokenizer.decodeUtf8(term, index);
                    if (!tokenizer.isCjk(decoded.codepoint)) return false;
                    count += 1;
                    index += decoded.len;
                }
                return count >= 2;
            }

            /// Mixed-language queries have an independent lexical recall
            /// signal, so pure-CJK bigram coverage must not exclude them.
            pub fn termHasNonCjkCodepoint(term: []const u8) bool {
                var index: usize = 0;
                while (index < term.len) {
                    const decoded = tokenizer.decodeUtf8(term, index);
                    if (!tokenizer.isCjk(decoded.codepoint)) return true;
                    index += decoded.len;
                }
                return false;
            }

            pub fn countQueryTermOccurrences(query_terms: []const []const u8, needle: []const u8) !u32 {
                var count: u32 = 0;
                for (query_terms) |term| {
                    if (std.mem.eql(u8, term, needle)) {
                        count = std.math.add(u32, count, 1) catch return error.RecordTooLarge;
                    }
                }
                return count;
            }

            pub fn validateOptions(options: TextSearchOptions) !void {
                try tokenizer.validateTokenizerOptions(options.tokenizer);
                if (!scoring.validBm25Params(options.params)) return core.Error.Unsupported;
                if (!std.math.isFinite(options.min_score)) return core.Error.Unsupported;
            }

            pub fn preallocCapacity(options: TextSearchOptions) usize {
                const max_prealloc: usize = 16 * 1024;
                return @min(options.max_postings_scanned, max_prealloc);
            }

            pub fn chargePostingScan(postings_scanned: *usize, options: TextSearchOptions) !void {
                if (postings_scanned.* >= options.max_postings_scanned) return core.Error.BudgetExceeded;
                postings_scanned.* += 1;
            }

            pub fn tokenizerOptionsEqual(lhs: tokenizer.TokenizerOptions, rhs: tokenizer.TokenizerOptions) bool {
                return lhs.max_token_bytes == rhs.max_token_bytes and
                    lhs.emit_original_compound == rhs.emit_original_compound and
                    lhs.emit_cjk_bigrams == rhs.emit_cjk_bigrams and
                    lhs.emit_cjk_unigrams == rhs.emit_cjk_unigrams;
            }

            pub fn hitLessThan(_: void, lhs: TextSearchHit, rhs: TextSearchHit) bool {
                const lhs_finite = std.math.isFinite(lhs.score);
                const rhs_finite = std.math.isFinite(rhs.score);
                if (lhs_finite != rhs_finite) return lhs_finite;
                if (lhs.match_count != rhs.match_count) return lhs.match_count > rhs.match_count;
                if (lhs_finite and lhs.score != rhs.score) return lhs.score > rhs.score;
                return lhs.node_id.toInt() < rhs.node_id.toInt();
            }

            pub fn appendTopHitBounded(
                allocator: std.mem.Allocator,
                hits: *std.ArrayList(TextSearchHit),
                limit: usize,
                hit: TextSearchHit,
            ) !void {
                var worst_index: ?usize = null;
                try appendTopHitBoundedCachedWorst(allocator, hits, limit, &worst_index, hit);
            }

            pub fn appendTopHitBoundedCachedWorst(
                allocator: std.mem.Allocator,
                hits: *std.ArrayList(TextSearchHit),
                limit: usize,
                worst_index: *?usize,
                hit: TextSearchHit,
            ) !void {
                if (limit == 0) return;
                if (hits.items.len < limit) {
                    try hits.append(allocator, hit);
                    if (hits.items.len == limit) worst_index.* = findWorstHitIndex(hits.items);
                    return;
                }
                const slot = worst_index.* orelse findWorstHitIndex(hits.items);
                if (hitLessThan({}, hit, hits.items[slot])) {
                    hits.items[slot] = hit;
                    worst_index.* = findWorstHitIndex(hits.items);
                } else {
                    worst_index.* = slot;
                }
            }

            pub fn worstTopHitScore(hits: []const TextSearchHit, limit: usize) ?f32 {
                if (limit == 0 or hits.len < limit) return null;
                return hits[findWorstHitIndex(hits)].score;
            }

            pub fn hitsContainNode(hits: []const TextSearchHit, node_id: core.NodeId) bool {
                for (hits) |hit| {
                    if (hit.node_id == node_id) return true;
                }
                return false;
            }

            fn findWorstHitIndex(hits: []const TextSearchHit) usize {
                std.debug.assert(hits.len > 0);
                var worst_index: usize = 0;
                for (hits[1..], 1..) |candidate, i| {
                    if (hitLessThan({}, hits[worst_index], candidate)) worst_index = i;
                }
                return worst_index;
            }
        };
    };
}

const TestCore = struct {
    pub const default_max_text_postings_scanned: usize = 100_000;
    pub const Error = error{ Unsupported, BudgetExceeded };
    pub const QueryDeadline = enum { none };
    pub const NodeKind = enum(u16) { task, observation };
    pub const NodeId = enum(u64) {
        _,

        pub fn fromInt(value: u64) NodeId {
            return @enumFromInt(value);
        }

        pub fn toInt(self: NodeId) u64 {
            return @intFromEnum(self);
        }
    };
};

const TestSchema = struct {
    pub const NodeTypeSet = struct {
        pub fn containsNodeKind(_: NodeTypeSet, _: TestCore.NodeKind) bool {
            return false;
        }
    };
};

const test_core = TestCore;
const test_contract = SearchContract(TestCore, TestSchema, tokenizer_mod, scoring_mod);
const TestTextSearchOptions = test_contract.TextSearchOptions;
const TestTextSearchHit = test_contract.TextSearchHit;
const TestInternal = test_contract.Internal;

test "text search options use bounded postings scan default" {
    const options = TestTextSearchOptions{};
    try std.testing.expectEqual(test_core.default_max_text_postings_scanned, options.max_postings_scanned);
    try std.testing.expectEqual(@as(usize, 16 * 1024), TestInternal.preallocCapacity(options));
}

test "text search contract rejects invalid scoring and tokenizer options" {
    try std.testing.expectError(test_core.Error.Unsupported, TestInternal.validateOptions(.{ .params = .{ .k1 = std.math.nan(f32) } }));
    try std.testing.expectError(test_core.Error.Unsupported, TestInternal.validateOptions(.{ .params = .{ .b = 1.1 } }));
    try std.testing.expectError(test_core.Error.Unsupported, TestInternal.validateOptions(.{ .min_score = std.math.inf(f32) }));
    try std.testing.expectError(test_core.Error.Unsupported, TestInternal.validateOptions(.{ .tokenizer = .{ .max_token_bytes = 0 } }));
}

test "text search filters and CJK coverage use bounded policy" {
    const options = TestTextSearchOptions{ .kind_filter = .task };
    try std.testing.expect(TestInternal.hasNodeFilter(options));
    try std.testing.expect(TestInternal.matchesNodeKind(options, .task));
    try std.testing.expect(!TestInternal.matchesNodeKind(options, .observation));
    try std.testing.expectEqual(@as(u32, 0), TestInternal.cjkBigramCoverageFloor(0, 0));
    try std.testing.expectEqual(@as(u32, 1), TestInternal.cjkBigramCoverageFloor(10, 0));
    try std.testing.expectEqual(@as(u32, 3), TestInternal.cjkBigramCoverageFloor(10, 0.3));
    try std.testing.expectEqual(@as(u32, 10), TestInternal.cjkBigramCoverageFloor(10, 2));
    try std.testing.expect(TestInternal.isCjkMultiCodepointTerm("错误"));
    try std.testing.expect(!TestInternal.isCjkMultiCodepointTerm("错"));
    try std.testing.expect(!TestInternal.isCjkMultiCodepointTerm("error"));
    try std.testing.expect(!TestInternal.termHasNonCjkCodepoint("错误"));
    try std.testing.expect(TestInternal.termHasNonCjkCodepoint("error"));
    try std.testing.expectEqual(@as(u32, 2), try TestInternal.countQueryTermOccurrences(&.{ "错误", "error", "错误" }, "错误"));
}

test "text search posting budget charge fails closed" {
    var scanned: usize = 0;
    const options = TestTextSearchOptions{ .max_postings_scanned = 1 };
    try TestInternal.chargePostingScan(&scanned, options);
    try std.testing.expectEqual(@as(usize, 1), scanned);
    try std.testing.expectError(test_core.Error.BudgetExceeded, TestInternal.chargePostingScan(&scanned, options));
}

test "text search bounded hit collector keeps best limited hits" {
    var hits = std.ArrayList(TestTextSearchHit).empty;
    defer hits.deinit(std.testing.allocator);

    try TestInternal.appendTopHitBounded(std.testing.allocator, &hits, 2, .{ .node_id = .fromInt(3), .kind = .observation, .score = 1.0 });
    try TestInternal.appendTopHitBounded(std.testing.allocator, &hits, 2, .{ .node_id = .fromInt(2), .kind = .observation, .score = 3.0 });
    try TestInternal.appendTopHitBounded(std.testing.allocator, &hits, 2, .{ .node_id = .fromInt(1), .kind = .observation, .score = 3.0 });
    try TestInternal.appendTopHitBounded(std.testing.allocator, &hits, 2, .{ .node_id = .fromInt(4), .kind = .observation, .score = 0.5 });

    std.mem.sort(TestTextSearchHit, hits.items, {}, TestInternal.hitLessThan);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expectEqual(@as(u64, 1), hits.items[0].node_id.toInt());
    try std.testing.expectEqual(@as(u64, 2), hits.items[1].node_id.toInt());
}

test "text search hit ordering handles non-finite scores deterministically" {
    var hits = [_]TestTextSearchHit{
        .{ .node_id = .fromInt(4), .kind = .observation, .score = std.math.nan(f32) },
        .{ .node_id = .fromInt(3), .kind = .observation, .score = 1.0 },
        .{ .node_id = .fromInt(2), .kind = .observation, .score = std.math.inf(f32) },
        .{ .node_id = .fromInt(1), .kind = .observation, .score = 1.0 },
    };

    std.mem.sort(TestTextSearchHit, &hits, {}, TestInternal.hitLessThan);
    try std.testing.expectEqual(test_core.NodeId.fromInt(1), hits[0].node_id);
    try std.testing.expectEqual(test_core.NodeId.fromInt(3), hits[1].node_id);
    try std.testing.expectEqual(test_core.NodeId.fromInt(2), hits[2].node_id);
    try std.testing.expectEqual(test_core.NodeId.fromInt(4), hits[3].node_id);
}
