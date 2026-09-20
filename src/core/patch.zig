//! 行级结构化 diff（unified-diff 风格 hunk）。
//!
//! 用于 Write/Edit 返回 structuredPatch + gitDiff，让上层（IDE/UI/模型）看到具体改了什么，
//! 而不是只有 {"success":true}。
//!
//! 算法：经典 LCS（最长公共子序列）按行对比 → 合并连续变更为 hunk（带 3 行上下文）。
//! 复杂度 O(n*m)；对常见编辑（几百行）足够。超大文件由调用方的 size 上限挡住。
//!
//! 输出：
//! - structuredPatch JSON：[{"oldStart":N,"oldLines":N,"newStart":N,"newLines":N,
//!     "lines":["-old","+new"," ctx"]}]
//! - gitDiff 文本：标准 `--- a/x` / `+++ b/x` / `@@ -a,b +c,d @@` 格式

const std = @import("std");
const util_json = @import("../util/json.zig");

const CONTEXT_LINES: usize = 3;

/// 一条 diff 行：类型 + 内容（不含换行）。
const DiffOp = enum { keep, del, add };
const DiffLine = struct { op: DiffOp, text: []const u8 };

/// 把文本切成行（不含 '\n'）。尾部若以 '\n' 结尾不产生空末行。
fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0 and it.peek() == null) break; // 尾随 \n
        try lines.append(allocator, ln);
    }
    return try lines.toOwnedSlice(allocator);
}

/// LCS 表 → diff op 序列。
fn diffLines(allocator: std.mem.Allocator, a: [][]const u8, b: [][]const u8) ![]DiffLine {
    const n = a.len;
    const m = b.len;
    // dp[(n+1)*(m+1)]
    const dp = try allocator.alloc(usize, (n + 1) * (m + 1));
    defer allocator.free(dp);
    @memset(dp, 0);
    const idx = struct {
        fn at(i: usize, j: usize, cols: usize) usize {
            return i * cols + j;
        }
    };
    const cols = m + 1;
    // 自底向上填 LCS 表
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        var j: usize = m;
        while (j > 0) : (j -= 1) {
            if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
                dp[idx.at(i - 1, j - 1, cols)] = dp[idx.at(i, j, cols)] + 1;
            } else {
                dp[idx.at(i - 1, j - 1, cols)] = @max(dp[idx.at(i, j - 1, cols)], dp[idx.at(i - 1, j, cols)]);
            }
        }
    }

    var ops = std.ArrayList(DiffLine).empty;
    errdefer ops.deinit(allocator);
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (std.mem.eql(u8, a[i], b[j])) {
            try ops.append(allocator, .{ .op = .keep, .text = a[i] });
            i += 1;
            j += 1;
        } else if (dp[idx.at(i + 1, j, cols)] >= dp[idx.at(i, j + 1, cols)]) {
            try ops.append(allocator, .{ .op = .del, .text = a[i] });
            i += 1;
        } else {
            try ops.append(allocator, .{ .op = .add, .text = b[j] });
            j += 1;
        }
    }
    while (i < n) : (i += 1) try ops.append(allocator, .{ .op = .del, .text = a[i] });
    while (j < m) : (j += 1) try ops.append(allocator, .{ .op = .add, .text = b[j] });
    return try ops.toOwnedSlice(allocator);
}

pub const Hunk = struct {
    old_start: usize,
    old_lines: usize,
    new_start: usize,
    new_lines: usize,
    /// 借用 ops 里的 text 切片；带前缀字符（' '/'-'/'+'）在序列化时加。
    ops: []DiffLine,
};

/// 把连续的非 keep 变更合并成 hunk（带 CONTEXT_LINES 上下文）。
fn buildHunks(allocator: std.mem.Allocator, ops: []DiffLine) ![]Hunk {
    var hunks = std.ArrayList(Hunk).empty;
    errdefer hunks.deinit(allocator);

    var old_ln: usize = 1;
    var new_ln: usize = 1;
    var k: usize = 0;
    while (k < ops.len) {
        if (ops[k].op == .keep) {
            old_ln += 1;
            new_ln += 1;
            k += 1;
            continue;
        }
        // 变更块起点：回退最多 CONTEXT_LINES 个 keep 作为前置上下文
        var ctx_back: usize = 0;
        var p = k;
        while (p > 0 and ops[p - 1].op == .keep and ctx_back < CONTEXT_LINES) {
            p -= 1;
            ctx_back += 1;
        }
        const hunk_start = p;
        const h_old_start = old_ln - ctx_back;
        const h_new_start = new_ln - ctx_back;

        // 向后扫描直到出现 > CONTEXT_LINES 连续 keep 或结束
        var q = k;
        var trailing_keep: usize = 0;
        var o_cnt: usize = ctx_back; // 已纳入的前置上下文都计入 old
        var n_cnt: usize = ctx_back;
        while (q < ops.len) {
            const op = ops[q];
            if (op.op == .keep) {
                trailing_keep += 1;
                o_cnt += 1;
                n_cnt += 1;
                if (trailing_keep > CONTEXT_LINES) break;
            } else {
                trailing_keep = 0;
                if (op.op == .del) o_cnt += 1;
                if (op.op == .add) n_cnt += 1;
            }
            q += 1;
        }
        // 去掉多扫的尾部 keep（保留至多 CONTEXT_LINES）
        var hunk_end = q;
        var extra = trailing_keep;
        while (extra > CONTEXT_LINES) : (extra -= 1) {
            hunk_end -= 1;
            o_cnt -= 1;
            n_cnt -= 1;
        }

        try hunks.append(allocator, .{
            .old_start = h_old_start,
            .old_lines = o_cnt,
            .new_start = h_new_start,
            .new_lines = n_cnt,
            .ops = ops[hunk_start..hunk_end],
        });

        // 推进行号到 hunk_end（按 hunk 内 op 统计）
        for (ops[k..hunk_end]) |op| {
            switch (op.op) {
                .keep => {
                    old_ln += 1;
                    new_ln += 1;
                },
                .del => old_ln += 1,
                .add => new_ln += 1,
            }
        }
        k = hunk_end;
    }
    return try hunks.toOwnedSlice(allocator);
}

/// 计算结果：拥有 ops 底层数组 + hunks 数组。hunks[].ops 借用 ops 的子切片。
/// hunks[].ops[].text 借用调用方传入的 old_text/new_text 字节——调用方须保证其存活到
/// 本结构 deinit + 所有序列化完成。
pub const Patch = struct {
    ops: []DiffLine,
    hunks: []Hunk,

    pub fn deinit(self: *Patch, allocator: std.mem.Allocator) void {
        allocator.free(self.ops);
        allocator.free(self.hunks);
    }
};

/// 计算 old→new 的 diff。调用方负责 `patch.deinit(allocator)`。
pub fn compute(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8) !Patch {
    const a = try splitLines(allocator, old_text);
    defer allocator.free(a);
    const b = try splitLines(allocator, new_text);
    defer allocator.free(b);
    const ops = try diffLines(allocator, a, b);
    errdefer allocator.free(ops);
    const hunks = try buildHunks(allocator, ops);
    return .{ .ops = ops, .hunks = hunks };
}

/// 序列化为 structuredPatch JSON 数组。
pub fn toStructuredJson(allocator: std.mem.Allocator, hunks: []const Hunk) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (hunks, 0..) |h, hi| {
        if (hi > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"oldStart\":{d},\"oldLines\":{d},\"newStart\":{d},\"newLines\":{d},\"lines\":[",
            .{ h.old_start, h.old_lines, h.new_start, h.new_lines },
        );
        for (h.ops, 0..) |op, oi| {
            if (oi > 0) try out.writer.writeByte(',');
            const prefix: u8 = switch (op.op) {
                .keep => ' ',
                .del => '-',
                .add => '+',
            };
            var line_buf: std.Io.Writer.Allocating = .init(allocator);
            defer line_buf.deinit();
            try line_buf.writer.writeByte(prefix);
            try line_buf.writer.writeAll(op.text);
            try util_json.writeJsonString(&out.writer, line_buf.written());
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

/// 序列化为 git unified diff 文本。
pub fn toGitDiff(allocator: std.mem.Allocator, path: []const u8, hunks: []const Hunk) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (hunks.len == 0) return try out.toOwnedSlice();
    try out.writer.print("--- a/{s}\n+++ b/{s}\n", .{ path, path });
    for (hunks) |h| {
        try out.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ h.old_start, h.old_lines, h.new_start, h.new_lines });
        for (h.ops) |op| {
            const prefix: u8 = switch (op.op) {
                .keep => ' ',
                .del => '-',
                .add => '+',
            };
            try out.writer.writeByte(prefix);
            try out.writer.writeAll(op.text);
            try out.writer.writeByte('\n');
        }
    }
    return try out.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "splitLines basic" {
    const a = std.testing.allocator;
    const lines = try splitLines(a, "x\ny\nz\n");
    defer a.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("y", lines[1]);
}

test "compute + structured json single change" {
    const a = std.testing.allocator;
    var patch = try compute(a, "a\nb\nc\n", "a\nB\nc\n");
    defer patch.deinit(a);
    try std.testing.expect(patch.hunks.len >= 1);
    const j = try toStructuredJson(a, patch.hunks);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"+B\"") != null);
}

test "git diff format" {
    const a = std.testing.allocator;
    var patch = try compute(a, "one\ntwo\n", "one\ntwo\nthree\n");
    defer patch.deinit(a);
    const d = try toGitDiff(a, "f.txt", patch.hunks);
    defer a.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "--- a/f.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "+++ b/f.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "+three") != null);
}

test "no change yields no hunks" {
    const a = std.testing.allocator;
    var patch = try compute(a, "same\n", "same\n");
    defer patch.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), patch.hunks.len);
}
