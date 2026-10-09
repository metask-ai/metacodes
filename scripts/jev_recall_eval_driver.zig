//! Zero-provider evaluation driver for the System-One recall policies.
//!
//! Replays rank-ordered TinyKG BM25 candidate pools through the production
//! policies of `src/kg/scoped_recall.zig`: the BM25 floor baseline
//! (`baselineSelection`), the judged gate (`Advisor.judgeRecallRelevance`
//! followed by `judgedSelection`) and, from the same judgment, the judged
//! KgRecall order (`judgedOrder`). Every candidate is cut with the same
//! query-focused window KgClient hands the judge, so the judge sees the bytes
//! a live recall would show it.
//! No provider is contacted; the only network peer is the METACODES_JEV_URL
//! judge (mode is irrelevant here: both policies are computed on every case).
//!
//! usage: metacodes-jev-recall-eval --input cases.jsonl --output results.jsonl [--surface gate|kgrecall]
//!   input:  {"case_id":s,"query":s,"user_request":s?,"candidates":[{"node_id":u,"kind":s,"schema_type":s,"score":f,"text":s}]}
//!           candidates rank-ordered by BM25 score, already filtered to recallable kinds
//!   --surface gate (default): the injection gate. The judge reads `query` as
//!           the request (`judgeRecallRelevance`); output carries baseline,
//!           judged and order.
//!   --surface kgrecall: a model-issued KgRecall. `query` is the recall query
//!           and `user_request` the request it serves; the judge reads
//!           `recallToolRequest(query, user_request)` (`judgeRecallOrder`),
//!           as `KgRecall` does. Output carries order only (baseline and
//!           judged are gate policies and stay empty).
//!   output: {"case_id":s,"status":s,"baseline":[u],"judged":[u],"order":[u],"percents":[u],"outcome":s,
//!            "elapsed_ms":u,"model":s,"question_set":s,"request_sha256":s}

const std = @import("std");
const cc = @import("cc");

const scoped_recall = cc.scoped_recall;
const advisor_mod = cc.jev_advisor;

const Candidate = struct {
    node_id: u64,
    kind: []const u8,
    schema_type: []const u8 = "",
    score: f64,
    text: []const u8,
};

const Case = struct {
    case_id: []const u8,
    query: []const u8,
    user_request: []const u8 = "",
    candidates: []const Candidate,
};

const Surface = enum { gate, kgrecall };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var surface: Surface = .gate;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (index + 1 >= args.len) return error.MissingFlagValue;
        if (std.mem.eql(u8, flag, "--input")) {
            input_path = args[index + 1];
        } else if (std.mem.eql(u8, flag, "--output")) {
            output_path = args[index + 1];
        } else if (std.mem.eql(u8, flag, "--surface")) {
            surface = std.meta.stringToEnum(Surface, args[index + 1]) orelse return error.UnknownSurface;
        } else return error.UnknownFlag;
        index += 1;
    }
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path orelse return error.MissingInput, arena, .limited(1024 * 1024 * 1024));
    // The judge comes from METACODES_JEV_* alone: no state root, no default,
    // so a run always names the service it measured.
    const runtime = cc.jev_runtime.load(init.gpa, init.io, "", "", false) orelse return error.JudgeNotConfigured;
    defer runtime.destroy(init.gpa);

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var case_arena = std.heap.ArenaAllocator.init(init.gpa);
        defer case_arena.deinit();
        const a = case_arena.allocator();
        const case = try std.json.parseFromSliceLeaky(Case, a, line, .{ .allocate = .alloc_always });
        try evaluateCase(a, &runtime.advisor, surface, case, &out, arena);
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path orelse return error.MissingOutput, .data = out.items });
}

fn evaluateCase(
    a: std.mem.Allocator,
    advisor: *advisor_mod.Advisor,
    surface: Surface,
    case: Case,
    out: *std.ArrayList(u8),
    out_allocator: std.mem.Allocator,
) !void {
    const query = case.query[0..@min(case.query.len, scoped_recall.MAX_QUERY_LEN)];
    const n = @min(case.candidates.len, advisor_mod.MAX_RECALL_CANDIDATES);
    // The gate skips trivial turns; KgRecall judges any valid recall query.
    const status: []const u8 = if (surface == .gate and query.len < scoped_recall.MIN_QUERY_LEN)
        "query_too_short"
    else if (n == 0)
        "no_hits"
    else
        "judged";
    if (!std.mem.eql(u8, status, "judged")) {
        try out.print(out_allocator, "{{\"case_id\":{f},\"status\":\"{s}\",\"baseline\":[],\"judged\":[],\"order\":[],\"percents\":[],\"outcome\":\"skipped\",\"elapsed_ms\":0,\"model\":\"\",\"question_set\":\"\",\"request_sha256\":\"\"}}\n", .{ std.json.fmt(case.case_id, .{}), status });
        return;
    }

    var scores: [advisor_mod.MAX_RECALL_CANDIDATES]f64 = undefined;
    var candidates: [advisor_mod.MAX_RECALL_CANDIDATES]advisor_mod.RecallCandidate = undefined;
    for (case.candidates[0..n], 0..) |candidate, position| {
        scores[position] = candidate.score;
        candidates[position] = .{
            .type_label = if (candidate.schema_type.len > 0) candidate.schema_type else candidate.kind,
            // Exactly the window KgClient cuts for the judge from the full text.
            .text = cc.jev_excerpt.focusedWindow(candidate.text, query, cc.jev_excerpt.JUDGE_WINDOW_BYTES),
        };
    }
    const judgment = switch (surface) {
        .gate => try advisor.judgeRecallRelevance(a, null, query, candidates[0..n]),
        .kgrecall => try advisor.judgeRecallOrder(a, null, try advisor_mod.recallToolRequest(a, query, case.user_request), candidates[0..n]),
    };
    const baseline = switch (surface) {
        .gate => scoped_recall.baselineSelection(scores[0..n], scoped_recall.DEFAULT_ABS_FLOOR),
        .kgrecall => scoped_recall.Selection{},
    };
    const judged = if (surface == .gate and judgment.answered()) scoped_recall.judgedSelection(judgment.percents[0..judgment.count], scores[0..judgment.count], baseline) else scoped_recall.Selection{};
    const order = if (judgment.answered()) scoped_recall.judgedOrder(judgment.percents[0..judgment.count], scores[0..judgment.count]) else scoped_recall.Order{};

    try out.print(out_allocator, "{{\"case_id\":{f},\"status\":\"judged\",\"baseline\":[", .{std.json.fmt(case.case_id, .{})});
    try appendNodeIds(out, out_allocator, case.candidates, baseline.slice());
    try out.appendSlice(out_allocator, "],\"judged\":[");
    try appendNodeIds(out, out_allocator, case.candidates, judged.slice());
    try out.appendSlice(out_allocator, "],\"order\":[");
    try appendNodeIds(out, out_allocator, case.candidates, order.slice());
    try out.appendSlice(out_allocator, "],\"percents\":[");
    for (judgment.percents[0..judgment.count], 0..) |percent, position| {
        if (position > 0) try out.append(out_allocator, ',');
        try out.print(out_allocator, "{d}", .{percent});
    }
    try out.print(out_allocator, "],\"outcome\":\"{s}\",\"elapsed_ms\":{d},\"model\":{f},\"question_set\":\"{s}\",\"request_sha256\":\"{s}\"}}\n", .{
        @tagName(judgment.audit.outcome),
        judgment.audit.elapsed_ms,
        std.json.fmt(judgment.audit.model(), .{}),
        judgment.audit.question_set,
        judgment.audit.request_sha256,
    });
}

fn appendNodeIds(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    positions: []const u8,
) !void {
    for (positions, 0..) |position, emitted| {
        if (emitted > 0) try out.append(allocator, ',');
        try out.print(allocator, "{d}", .{candidates[position].node_id});
    }
}
